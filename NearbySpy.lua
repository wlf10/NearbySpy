--[[
    NearbySpy 1.6.4
    Records players near you into SavedVariables (NearbySpy.lua).

    Data sources — passive, main mode (no user action required):
      - target, focus, mouseover (UPDATE_MOUSEOVER_UNIT);
      - nameplate1..nameplate40 (NAME_PLATE_UNIT_ADDED + 2 sec tick) — in the
        beta nameplates are silent (lastPlates=0), kept in case they get enabled;
      - party/raid (GROUP_ROSTER_UPDATE);
      - guild roster (GUILD_ROSTER_UPDATE) — level/class/zone of all guildmates;
      - combat log (COMBAT_LOG_EVENT_UNFILTERED) — name+class+race by GUID, 2 min dedup;
      - chat (CHAT_MSG_SAY/YELL/CHANNEL) — only the speaker's name (class/level
        unknown → empty fields are not passed), source='chat': city channels
        show players that nameplate scans and rosters never reach;
      - /who — ASSISTED manual mode /nspy suggest: since build 1.60.1.70291 the
        server answers only a hardware click (hardware gate in C++, programmatic
        who is dead), so the addon types the query into the box and the user
        clicks the search button.
    Commands: /nearbyspy (or /nspy) — window with the list; suggest/who/
              whoclass/whorace — assisted /who (you click the search button),
              who speed — surface layer: level bands of 10 from the top, a band
              that hits the 50-row cap expands into classes, then into races
              (~20-30 queries instead of ~110; capping is by design),
              count | announce | debug | peer | reset | world (world data
              counters)

]]

local ADDON_NAME = ...











-- ============ UI localization (enUS fallback, ruRU, zhCN) ============
-- Only user-facing strings (P/windows). Debug D() messages and
-- FinishZoneScan reasons are technical — kept in English outside the table.
-- UI localization table lives in NearbySpy_Locale.lua (loaded first via the
-- TOC): the main chunk was one top-level local away from the Lua 5.1 limit
-- of 200, and every new UI feature needs a local of its own.
local LOCALE = NSP_LOCALE or {}
local function L(key)
    -- settings override (db.locale) beats the client locale; NearbySpy is the
    -- SV global, nil until ADDON_LOADED — early L() calls just use the client
    local ov = (type(NearbySpy) == "table") and NearbySpy.locale or nil
    local t = (ov and LOCALE[ov]) or LOCALE[GetLocale()] or LOCALE.enUS
    return t[key] or LOCALE.enUS[key] or key
end

local newThisSession = 0
local whoScan = nil           -- active layered scan {zone, sent, results, added, current, suggest}
local whoQueue = {}           -- queue of ranges {lo, hi}
local SaveScanState           -- forward: the scan queue is mirrored into SV (defined below)
local whoTest = nil           -- active /nspy whotest probe (defined with the probe)
local WHO_TEST_BOX_TEXT = nil -- what the search box actually contained at click time
local WHO_TEST_REOPEN_LOG = nil -- what the forced reopen did (hid/showed counts)

local GetDB   -- forward: P's body writes the ring into db through this reference

local function P(msg)
    -- timestamp on every line (08.10): without time in the ring you can't
    -- tell an instant reply from a server cooldown
    local stamped = ("[%s] %s"):format(date("%H:%M:%S"), tostring(msg))
    print(NSP_CONST.PREFIX .. stamped)
    -- duplicate prints into a SavedVariables ring (last 200 lines): the chat
    -- cache is empty, command output is read after logout straight from SV
    local ok, db2 = pcall(GetDB)
    if ok and type(db2) == "table" and type(db2.debug) == "table" then
        local ring = db2.debug.printRing
        if type(ring) ~= "table" then ring = {}; db2.debug.printRing = ring end
        ring[#ring + 1] = NspCut(stamped, 500)
        if #ring > 200 then table.remove(ring, 1) end
    end
end

GetDB = function()
    if type(NearbySpy) ~= "table" then
        NearbySpy = { players = {}, announce = false, created = time() }
    end
    if type(NearbySpy.players) ~= "table" then
        NearbySpy.players = {}
    end
    if type(NearbySpy.debug) ~= "table" then
        NearbySpy.debug = {}
    end
    -- peer sharing is ON by default for new/untouched installs (18.10.2026);
    -- an explicit "/nspy peer off" (false) is respected, nil means "never set"
    if NearbySpy.peerEnabled == nil then
        NearbySpy.peerEnabled = true
    end
    -- Accept records from other realms of the cluster (the channel is shared).
    -- On by default: the whole point of the channel is coverage. Turning it off
    -- drops foreign packets AND hides already-stored foreign rows.
    if NearbySpy.peerAllRealms == nil then
        NearbySpy.peerAllRealms = true
    end
    -- Retention: записи игроков старше срока удаляются при входе в игру и при
    -- выходе. Настройка живёт в SavedVariables, поэтому работает и после
    -- /reload. nil = «не настраивали» → берём умолчание из NSP_CONST;
    -- 0 = чистка явно выключена (/nspy retain off) и умолчание НЕ возвращается.
    if NearbySpy.retainDays == nil then
        NearbySpy.retainDays = (type(NSP_CONST) == "table" and NSP_CONST.RETAIN_DAYS) or 7
    end
    -- Позиционная схема: метатаблица НЕ сохраняется в SavedVariables, поэтому
    -- после загрузки записи приходят голыми массивами и p.name вернёт nil.
    -- Проход обязан идти ЗДЕСЬ, до любого кода ниже: миграция имён читает
    -- p.name/p.realm и, не найдя их, выбросила бы все записи как «unusable».
    -- Защёлка в памяти (не в SV) — GetDB зовут на каждое событие, а проход по
    -- десяткам тысяч записей нужен один раз за сессию.
    if not NSP_REC.ready then
        NSP_REC.ready = true
        if type(NspMigrateRecords) == "function" then
            local okM, conv, att = pcall(NspMigrateRecords, NearbySpy)
            if not okM then
                NSP_REC.ready = false      -- повторим на следующем вызове
                NearbySpy.debug = NearbySpy.debug or {}
                NearbySpy.debug.recMigrateErr = tostring(conv)
            elseif (tonumber(conv) or 0) + (tonumber(att) or 0) > 0 then
                NearbySpy.debug = NearbySpy.debug or {}
                NearbySpy.debug.recMigrated = (NearbySpy.debug.recMigrated or 0) + (tonumber(conv) or 0)
            end
        end
    end
    local db = NearbySpy
    -- game tag for the site (14.10.2026): retail / classic_era / forever.
    -- GetBuildInfo: 1.60.x — Forever beta; other 1.x — classic live;
    -- >=11 — retail. Written once; no API → skip (the site fills in
    -- the default forever itself).
    -- realm: the world tag for the site's world directory (vendors, fishing).
    -- The file is account-level, so this is the realm of the LAST character
    -- played — that is exactly the realm the world data of this session came
    -- from. Player records carry their own realm, so they never rely on this.
    if not db.realm then
        local r = GetRealmName and GetRealmName() or nil
        if type(r) == "string" and r ~= "" then db.realm = r end
    end
    if not db.game then
        local v = GetBuildInfo and GetBuildInfo() or ""
        local major = tonumber(tostring(v):match("^(%d+)")) or 0
        local minor = tonumber(tostring(v):match("^%d+%.(%d+)")) or 0
        if major >= 11 then
            db.game = "retail"
        elseif major == 1 and minor >= 60 then
            db.game = "forever"
        elseif major >= 1 then
            db.game = "classic_era"
        end
    end
    -- one-time migration: merge two-word Camelot names split by the old
    -- parsing (the surname landed in realm), + replace realm with the real one
    if not db.migratedNames then
        local realRealm = GetRealmName()
        if realRealm and realRealm ~= "" then
            db.migratedNames = true
            local merged = {}
            for _, p in pairs(db.players) do
                if type(p) == "table" and p.name and p.name ~= "" then
                    -- A surname landed in realm only via unit-ish sources
                    -- (UnitName's second return). Chat records may carry a
                    -- genuine foreign realm ("Name-Realm") — never merge or
                    -- rewrite those.
                    local foreignSource = (p.source == "chat" or p.source == "peer")
                    if p.realm and p.realm ~= "" and p.realm ~= "?"
                        and p.realm ~= realRealm and not foreignSource
                        and not p.name:find(" ") then
                        -- surname got stuck in realm — move it back into the name
                        p.name = p.name .. " " .. p.realm
                        p.realm = realRealm
                    elseif not p.realm or p.realm == "" or p.realm == "?" then
                        p.realm = realRealm
                    end
                    local nk = p.name .. "-" .. p.realm
                    local ex = merged[nk]
                    if ex then
                        ex.count = (ex.count or 1) + (p.count or 1)
                        if (p.firstSeen or math.huge) < (ex.firstSeen or math.huge) then
                            ex.firstSeen = p.firstSeen
                        end
                        ex.lastSeen = math.max(ex.lastSeen or 0, p.lastSeen or 0)
                        for _, f in ipairs({"class", "race", "faction", "zone", "zoneId"}) do
                            if (ex[f] == nil or ex[f] == "") and p[f] ~= nil and p[f] ~= "" then
                                ex[f] = p[f]
                            end
                        end
                    else
                        merged[nk] = p
                    end
                else
                    -- unusable record (no name): drop it, keep a counter
                    db.debug.migrationDropped = (db.debug.migrationDropped or 0) + 1
                end
            end
            db.players = merged
        end
    end
    -- Чистка мусора в поле расы (15.11.2026): 384 записи с именем зоны вместо
    -- расы. Глобал может быть ещё не объявлен, если GetDB позвали во время
    -- загрузки файла — проверка на nil это покрывает.
    if NspMigrateRaces then NspMigrateRaces(db) end
    -- Мир у записей без него (22.11.2026). Глобал объявлен ниже по файлу —
    -- проверка на nil покрывает вызов во время загрузки.
    if NspMigrateRealms then NspMigrateRealms(db) end
    -- Проба-диагностика из SV (23.11.2026). Глобал объявлен ниже по файлу —
    -- проверка на nil покрывает вызов во время загрузки.
    if NspPruneDebug then NspPruneDebug(db) end
    -- След снятой пробы (верхний уровень SV) и приведение zoneId к тексту зоны
    -- (25.11.2026). Глобал объявлен ниже по файлу — проверка на nil покрывает
    -- вызов во время загрузки.
    if NspFixZoneIds then NspFixZoneIds(db) end
    return db
end

-- Keep a bounded sample of Blizzard HC broadcasts for future parsing.
-- This is not a death database: older messages are dropped after 200 entries.
local function RecordHardcoreDeath(message)
    if type(message) ~= "string" or (canaccessvalue and not canaccessvalue(message)) then return end
    if message == "" then return end
    local db = GetDB()
    db.debug.hardcoreDeathCount = (db.debug.hardcoreDeathCount or 0) + 1
    local samples = db.debug.hardcoreDeathSamples
    if type(samples) ~= "table" then samples = {}; db.debug.hardcoreDeathSamples = samples end
    samples[#samples + 1] = { at = time(), realm = GetRealmName(), message = NspCut(message, 500) }
    if #samples > 200 then table.remove(samples, 1) end
end

-- ring without chat (digests every 5 min — don't spam the player)
local function R(msg)
    local ok, db2 = pcall(GetDB)
    if ok and type(db2) == "table" and type(db2.debug) == "table" then
        local ring = db2.debug.printRing
        if type(ring) ~= "table" then ring = {}; db2.debug.printRing = ring end
        ring[#ring + 1] = NspCut(("[%s] %s"):format(date("%H:%M:%S"), tostring(msg)), 500)
        if #ring > 200 then table.remove(ring, 1) end
    end
end

-- LOG (debug mode): always to the SV ring, to chat ONLY when
-- db.debugMode is on (/nspy debug). With debug off the addon is "stealthy":
-- chat shows only command replies, announcements and errors; technical lines
-- (scan progress, digests, gate blocks) are read from the ring after logout.
local function D(msg)
    local ok, db2 = pcall(GetDB)
    if ok and type(db2) == "table" and db2.debugMode then
        P(msg)   -- P prints to chat and duplicates into the ring
    else
        R(msg)   -- quiet: ring only
    end
end

-- first error per source goes to debug (pcall used to swallow it silently, 1.5.1)
-- ⚠️ 15.11.2026: запись в err делалась ТОЛЬКО если для источника ещё нет строки —
-- одна старая ошибка навсегда прятала все последующие («в логе была ошибка»
-- превращалось в недоказуемое: err.chat держал запись от 09.11, а новая ошибка
-- того же источника не попадала никуда). Теперь СЧЁТЧИК и ПОСЛЕДНЯЯ строка
-- обновляются всегда, err[src] остаётся первой за всё время для истории, а в
-- кольцо пишется не чаще раза в минуту на источник, чтобы поток ошибок не
-- вытеснял из кольца остальное.
local function DbgErr(src, err)
    local ok, db = pcall(GetDB)
    if not ok or type(db) ~= "table" or type(db.debug) ~= "table" then return end
    local now = time()
    local text = tostring(err):sub(1, 200)
    db.debug.err = db.debug.err or {}
    db.debug.errAt = db.debug.errAt or {}
    db.debug.errCount = db.debug.errCount or {}
    db.debug.errLast = db.debug.errLast or {}
    db.debug.errCount[src] = (db.debug.errCount[src] or 0) + 1
    db.debug.errLast[src] = text
    local prev = db.debug.errAt[src]
    db.debug.errAt[src] = now
    if not db.debug.err[src] then db.debug.err[src] = text end
    if not prev or now - prev > 60 then
        D(("DEBUG error [%s] #%d: %s"):format(src, db.debug.errCount[src], text:sub(1, 120)))
    end
end

-- Последнее НЕПУСТОЕ имя мира, увиденное в этой сессии (или взятое из SV).
-- GetRealmName() в клиенте Forever иногда возвращает "" — и `GetRealmName() or "?"`
-- этого не ловит, потому что пустая строка в Lua истинна. Живой SV 22.11.2026:
-- 729 записей с ключом "Имя-" и realm="" (628 из них снимались инспектом), и
-- 54 имени задвоены — одна строка с пустым миром, другая с настоящим. Отсюда же
-- шли битые peer-пакеты "G7;f;;Имя;…", которые отбивал каждый получатель.
NSP_REALM_LAST = nil
local function PlayerRealm()
    -- Camelot: two-word names — UnitName returns the SURNAME as the
    -- "realm", so the real realm is taken only from GetRealmName().
    local r = GetRealmName()
    if type(r) == "string" and r ~= "" then
        NSP_REALM_LAST = r
        return r
    end
    -- Клиент ответил пусто: держимся за последнее известное значение, затем за
    -- мир из SV (account-level, пишется при первом успешном чтении).
    if NSP_REALM_LAST then return NSP_REALM_LAST end
    local ok, db = pcall(GetDB)
    if ok and type(db) == "table" and type(db.realm) == "string" and db.realm ~= "" then
        NSP_REALM_LAST = db.realm
        return db.realm
    end
    -- "?" — честное «не знаю»: запись с таким миром не станет ключом "Имя-".
    return "?"
end

-- zone by player name (another unit in the beta returns mapID=0, zone name unavailable)
--
-- GetRealZoneText, а не GetZoneText: GetZoneText отдаёт ПОДзону («Тихий Омут»,
-- «Ферма Гаррена»), а PlayerZoneId() — зону (GetBestMapForUnit). Из-за этого
-- текст и id в одной записи описывали разное, и обратный поиск по имени не
-- находил id. В живом SV до правки: zoneId=1420 соседствовал с текстами
-- «Тирисфальские леса» ×1732, «Тихий Омут» ×4, «Ферма Гаррена» ×3.
-- GetRealZoneText в клиенте есть (проверено пробой API: db.api.GetRealZoneText=1).
local function PlayerZone()
    local zone
    if GetRealZoneText then zone = GetRealZoneText() end
    if not zone or zone == "" then
        -- фолбэк: в другой сборке API может не быть, а зону терять нельзя
        zone = GetZoneText()
    end
    if zone == "" then zone = nil end
    return zone
end

-- approximate coordinates: player position (whoever is nearby is in the same zone)
local function PlayerXY()
    local ok, mapID = pcall(C_Map.GetBestMapForUnit, "player")
    if not ok or not mapID then return nil, nil end
    local ok2, pos = pcall(C_Map.GetPlayerMapPosition, mapID, "player")
    if not ok2 or not pos then return nil, nil end
    local x, y = pos:GetXY()
    return x, y
end

-- uiMapID of the current zone — a number, identical in any client language
local function PlayerZoneId()
    local ok, mapID = pcall(C_Map.GetBestMapForUnit, "player")
    if ok and mapID and mapID > 0 then return mapID end
    return nil
end

-- ── Словарь зон: имя (на языке клиента) <-> UiMap id ───────────────────────
-- Зачем: /who отдаёт зону ТЕКСТОМ на языке клиента и не даёт её id, поэтому id
-- был известен только для нашей собственной зоны (23.5% записей). В пакете зона
-- занимает ~26 байт текста против 4 у числа, и на приёме русский текст не
-- читается enUS-клиентом.
--
-- Клиент умеет C_Map.GetMapInfo(id) -> { name, mapType, mapID, parentMapID }.
-- Перебираем id один раз (лениво, при первом обращении) и строим обе карты.
-- Несуществующий id даёт nil — этот контракт использует сам клиент
-- (Blizzard_SharedMapDataProviders/VehicleDataProvider.lua: "if not mapInfo").
NSP_ZONE_BY_NAME = nil      -- имя -> id
NSP_ZONE_NAME_BY_ID = nil   -- id -> имя

-- Диапазон для поиска КОРНЕВЫХ карт. Обход дерева начинается с них, поэтому
-- скан здесь маленький и грубый — точность не нужна, лишние id просто не
-- ответят. Живой прогон 10.11.2026: ниже 1412 C_Map не отвечает вообще,
-- поэтому начинаем с 1000.
local ZONE_ROOT_FROM, ZONE_ROOT_TO = 1000, 6000
-- Порог «словарь полон». В базе 821 уникальная зона; при обходе дерева
-- ожидаем заметно больше. Ниже — пересканируем.
local ZONE_MAP_MIN = 400
local zoneMapLastScan = 0

-- ZonePreload — запросить загрузку карты. В C_Map карты грузятся по требованию
-- (Blizzard: RequestPreloadMap в Blizzard_WorldMap/MapTexturePreloader.lua), и
-- до запроса GetMapChildrenInfo может честно вернуть пусто — именно это мы и
-- наблюдали: roots=59, добавлено 58, поддеревья пустые.
local function ZonePreload(id)
    if C_Map and C_Map.RequestPreloadMap then
        pcall(C_Map.RequestPreloadMap, id)
    end
end

-- ZoneChildren — дети карты. Тип карты передаётся ЯВНО, как это делает сам
-- Blizzard (ZoneLabelDataProvider.lua: C_Map.GetMapChildrenInfo(mapID,
-- Enum.UIMapType.Zone)). С nil вместо типа клиент отдавал почти пустой список.
-- Пробуем несколько типов: поддерево может содержать зоны, пещеры и мир.
local ZONE_MAP_TYPES = nil   -- заполняется лениво из Enum
local function ZoneTypes()
    if ZONE_MAP_TYPES then return ZONE_MAP_TYPES end
    local t = {}
    local e = Enum and Enum.UIMapType
    if e then
        for _, key in ipairs({ "Cosmic", "World", "Continent", "Zone", "Dungeon",
                               "Micro", "Orphan" }) do
            if e[key] then t[#t + 1] = e[key] end
        end
    end
    -- без Enum — хотя бы nil (как было), чтобы поведение не пропало совсем
    if #t == 0 then t[1] = nil end
    ZONE_MAP_TYPES = t
    return t
end

local function ZoneChildren(id)
    if not (C_Map and C_Map.GetMapChildrenInfo) then return nil end
    local merged, seen = {}, {}
    local got = false
    for _, mapType in ipairs(ZoneTypes()) do
        local ok, children = pcall(C_Map.GetMapChildrenInfo, id, mapType, true)
        if ok and type(children) == "table" then
            for i = 1, #children do
                local c = children[i]
                local cid = type(c) == "table" and tonumber(c.mapID)
                if cid and not seen[cid] then
                    seen[cid] = true
                    merged[#merged + 1] = c
                    got = true
                end
            end
        end
    end
    return got and merged or nil
end

-- ZoneCollect — добавить карту и рекурсивно её детей в словари.
-- Дети берутся через ZoneChildren (явный тип карты + preload), потому что
-- запрос с nil вместо типа на этом клиенте отдавал пустое поддерево.
local function ZoneCollect(byName, byId, info, depth)
    if type(info) ~= "table" then return 0 end
    local id = tonumber(info.mapID)
    local name = info.name
    if not id or id <= 0 then return 0 end
    -- секретные строки (combat) не индексируем: они не читаются
    if canaccessvalue and type(name) == "string" and not canaccessvalue(name) then
        return 0
    end
    local added = 0
    if type(name) == "string" and name ~= "" then
        byId[id] = name
        local prev = byName[name]
        -- при дубле имени оставляем ЗОНУ (mapType == 3), а не континент
        if not prev or (info.mapType == 3) then
            byName[name] = id
        end
        added = added + 1
    end
    if depth < 12 then
        ZonePreload(id)
        local children = ZoneChildren(id)
        if children then
            for i = 1, #children do
                local child = children[i]
                if type(child) == "table" then
                    local cid = tonumber(child.mapID)
                    if cid and byId[cid] then
                        -- уже проиндексирован этим же обходом: имя обновляем,
                        -- дальше не спускаемся
                        if type(child.name) == "string" and child.name ~= "" then
                            local prev = byName[child.name]
                            if not prev or (child.mapType == 3) then
                                byName[child.name] = cid
                            end
                            byId[cid] = child.name
                            added = added + 1
                        end
                    else
                        added = added + ZoneCollect(byName, byId, child, depth + 1)
                    end
                end
            end
        end
    end
    return added
end

-- ZoneMapInit — построить словари обходом дерева карт.
-- Возвращает карты (пустые, если API нет).
function ZoneMapInit()
    if NSP_ZONE_BY_NAME then return NSP_ZONE_BY_NAME, NSP_ZONE_NAME_BY_ID end
    local byName, byId = {}, {}
    NSP_ZONE_BY_NAME, NSP_ZONE_NAME_BY_ID = byName, byId
    if not (C_Map and C_Map.GetMapInfo) then return byName, byId end
    local roots, found = 0, 0
    for id = ZONE_ROOT_FROM, ZONE_ROOT_TO do
        local ok, info = pcall(C_Map.GetMapInfo, id)
        if ok and type(info) == "table" and tonumber(info.mapID) then
            found = found + ZoneCollect(byName, byId, info, 1)
            roots = roots + 1
        end
    end
    local okDb, db = pcall(GetDB)
    if okDb and type(db) == "table" then
        db.debug = db.debug or {}
        -- Диагностика: сколько записей, сколько корней, какие типы карт
        -- запрашивались и есть ли они в клиенте — без этого не отличить
        -- «дерево пустое» от «Enum.UIMapType отсутствует».
        local ids, shown = {}, 0
        for id, name in pairs(byId) do
            shown = shown + 1
            if shown <= 40 then ids[#ids + 1] = tostring(id) .. "=" .. name end
        end
        table.sort(ids)
        local types = {}
        for _, v in ipairs(ZoneTypes()) do types[#types + 1] = tostring(v) end
        db.debug.zoneMap = {
            from = ZONE_ROOT_FROM, to = ZONE_ROOT_TO,
            found = found, roots = roots,
            hasPreload = (C_Map and C_Map.RequestPreloadMap) and true or false,
            hasEnum = (Enum and Enum.UIMapType) and true or false,
            types = types,
            sample = ids,
        }
    end
    return byName, byId
end

-- ZoneMapReady — словарь достаточно полон? На кастомном клиенте C_Map может
-- отдать данные не сразу после входа, поэтому первый обход способен собрать
-- огрызок. Если он подозрительно мал, разрешаем ПОВТОРНЫЙ обход.
function ZoneMapReady()
    ZoneMapInit()
    local n = 0
    for _ in pairs(NSP_ZONE_NAME_BY_ID or {}) do n = n + 1 end
    return n >= ZONE_MAP_MIN
end

function ZoneMapRefresh()
    -- Пересканируем ТОЛЬКО если словарь заведомо неполон.
    if ZoneMapReady() then return end
    local nowT = time()
    if nowT - zoneMapLastScan < 60 then return end
    zoneMapLastScan = nowT
    NSP_ZONE_BY_NAME, NSP_ZONE_NAME_BY_ID = nil, nil
    ZoneMapInit()
end

-- ZoneIdByName — id по тексту зоны из /who. nil, если зоны нет ни в словаре
-- клиента, ни во вшитой таблице (тогда вызывающий шлёт текст, как раньше, —
-- молча терять зону нельзя).
--
-- Порядок источников важен:
--   1) словарь клиента (C_Map) — «своё» написание в текущем языке, точнее
--      всего; но он КУЦЫЙ: 117 карт против 821 зоны в базе, потому что отдаёт
--      только уже загруженные карты, а обход дерева на этом клиенте не работает;
--   2) NSP_ZONE_BY_NAME — вшитая таблица из DB2 ТОЧНОГО билда (7749 имён в 10
--      локалях, генерируется scripts/gen_zones.py). Она разрешает 1131 название
--      из 1189 в живом SV, поднимая покрытие zoneId с 82% до 97%.
-- Таблица необязательна: без файла аддон работает как раньше (pcall-гейт).
function ZoneIdByName(name)
    if type(name) ~= "string" or name == "" then return nil end
    ZoneMapRefresh()          -- если прошлый обход собрал огрызок — попробуем ещё
    local byName = ZoneMapInit()
    local hit = byName[name]
    if hit then return hit end
    local t = NSP_ZONE_TABLE
    if type(t) == "table" then
        -- ключи в таблице в нижнем регистре; string.lower в Lua 5.1 работает
        -- по байтам и для UTF-8 безопасен (меняет только ASCII-регистр),
        -- поэтому русские/немецкие имена остаются нетронутыми.
        local key = name:lower()
        local exact = t[key]
        if exact then return exact end
        -- лишние пробелы по краям в /who случаются редко, но стоят дешевле
        -- одного потерянного zoneId
        local trimmed = key:match("^%s*(.-)%s*$")
        if trimmed and trimmed ~= key then
            local v = t[trimmed]
            if v then return v end
        end
    end
    return nil
end

-- ZoneNameById — имя зоны на языке ТЕКУЩЕГО клиента по id из пакета.
-- Словарь тут не обязателен: достаточно одного C_Map.GetMapInfo, поэтому
-- при отсутствии словаря всё равно отвечаем.
function ZoneNameById(id)
    local n = tonumber(id)
    if not n or n <= 0 then return nil end
    -- Сначала прямой запрос: он не требует обхода и работает всегда.
    if C_Map and C_Map.GetMapInfo then
        local ok, info = pcall(C_Map.GetMapInfo, n)
        -- Гейт секретной строки идёт ПЕРЕД `info.name ~= ""`: сравнение с
        -- пустой строкой — строковая операция и на секретном значении бросает
        -- (тот же класс дефекта, что был в обработчике чата).
        if ok and type(info) == "table" and type(info.name) == "string" then
            local secret = canaccessvalue and not canaccessvalue(info.name)
            if not secret and info.name ~= "" then return info.name end
        end
    end
    local _, byId = ZoneMapInit()
    return byId[n]
end

local function Round4(v)
    if type(v) ~= "number" then return nil end
    return math.floor(v * 10000 + 0.5) / 10000
end

-- ZoneDisplay — имя зоны В ЯЗЫКЕ ТЕКУЩЕГО КЛИЕНТА.
--
-- Записи накапливаются годами: у встречи, снятой на русском клиенте, в слоте
-- zone лежит «Нагорье Арати», у немецкой — «Arathihochland», у англоязычной
-- приёма из канала — что-то третье. В окне это выглядело смешанным набором
-- языков. uiMapID одинаков в любой локали, поэтому имя берём по нему:
-- C_Map.GetMapInfo(id).name клиент отдаёт уже на своём языке (проверено на
-- deDE: 1417→Arathihochland, 1429→Wald von Elwynn).
--
-- Фолбэк на сохранённый текст обязателен:
--   • zoneId есть у 82% записей базы (замер по живому SV 24.11.2026);
--   • у записи из канала зоны нет вовсе — честно покажем «?».
-- Глобальная функция, а не local: главный чанк на 197 локалах из 200 у Lua 5.1.
function ZoneDisplay(zoneId, zoneText)
    local n = tonumber(zoneId)
    if n and n > 0 then
        local name = ZoneNameById(n)
        if name and name ~= "" then return name end
    end
    if type(zoneText) == "string" and zoneText ~= "" and zoneText ~= "?" then
        return zoneText
    end
    return "?"
end

-- NspResolveZoneId — досстановить zoneId по тексту зоны в записи.
--
-- ⚠️ ПЕРЕХОДНЫЙ МЕХАНИЗМ (решение пользователя 24.11.2026): «пока оставим на
-- переходный период, потом будем убирать». Убирать, когда в базе не останется
-- записей без zoneId от старых клиентов — то есть после того, как парк
-- обновится на версию, которая id шлёт всегда.
--
-- Зачем нужен сейчас: зона приходит текстом из трёх путей, где id взять негде —
--   • peer-пакет с zoneId=0 (пир не знал id и прислал имя в хвосте);
--   • chat (спикер в чате: ни зоны, ни id — зона появляется позже из другого
--     источника, а id при этом никто не проставлял);
--   • записи, сделанные ДО появления таблицы: у них в SV только название
--     («Тирисфальские леса») и zoneId = false.
-- Досстановленный id — второсортный по сравнению с наблюдённым: он выведен из
-- текста, а не пришёл от клиента. Поэтому здесь существующий id не трогается,
-- а в peer-сравнении (UpsertPlayer) такой id уже не даёт отправить пустое
-- обновление — см. блок «смена зоны решается по ID». Исключение — случай,
-- когда ТЕКСТ зоны обновился, а id от источника не пришёл: там id
-- пересчитывается и перезаписывается (см. UpsertPlayer и NspFixZoneIds).
--
-- Счётчик, по которому видно, что механизм отработал своё: db.debug.zoneResolved.
-- Когда он перестанет расти между сессиями — переходный период закончен.
function NspResolveZoneId(entry)
    if type(entry) ~= "table" then return end
    local zid = entry.zoneId
    if zid and zid ~= 0 then return end          -- id уже есть — не трогаем
    local zone = entry.zone
    if type(zone) ~= "string" or zone == "" or zone == "?" then return end
    local resolved = ZoneIdByName(zone)
    if resolved and resolved > 0 then
        entry.zoneId = resolved
        local db = GetDB and GetDB()
        if type(db) == "table" then
            db.debug = db.debug or {}
            db.debug.zoneResolved = (db.debug.zoneResolved or 0) + 1
        end
    end
end

-- Версия разового прохода «zoneId по тексту зоны» (25.11.2026).
NSP_ZONE_FIX_VERSION = 1

-- NspFixZoneIds — привести zoneId записи в соответствие с её текстом зоны.
--
-- БАГ, ради которого написан (живой SavedVariables 25.11.2026): у 361 записи
-- из 59 375 текст описывал одну зону, а zoneId — другую. Причина в
-- UpsertPlayer: ростер гильдии отдаёт зону ТЕКСТОМ и вообще без id
-- (HandleGuildRoster), /who до появления вшитой таблицы резолвил не всякое
-- имя — текст обновлялся, а id оставался от прежнего наблюдения. До 1.6.3
-- этого не было видно (окно показывало текст), после перехода на
-- ZoneDisplay(id) стало видно: игрок в Штормграде показывался под чужим id,
-- и на сайт уходил неверный zoneId.
--
-- Решение всегда в пользу ТЕКСТА: он пишется при каждом наблюдении, а id —
-- только когда источник его прислал. Тем же проходом досстанавливается id у
-- записей, которые его так и не получили (это разовый NspResolveZoneId по
-- всей базе, а не по одной встрече).
--
-- Разовость — по флагу db.zoneIdFixed: гонять 59 тыс. записей на каждом входе
-- не нужно, а новые расхождения закрывает сам UpsertPlayer.
function NspFixZoneIds(db)
    if type(db) ~= "table" then return end
    -- След снятой API-пробы (NearbySpy_Probe.lua удалён 23.11.2026): в коде
    -- этих ключей нет, а в SV они лежали с 08.11 — ~130 КБ неймспейсов и
    -- образцов торговцев. NspPruneDebug чистит только db.debug, верхний
    -- уровень оставался нетронутым.
    if db.probe ~= nil or db.probeOn ~= nil then
        db.probe, db.probeOn = nil, nil
        db.debug = db.debug or {}
        db.debug.probePruned = true
    end
    if db.zoneIdFixed == NSP_ZONE_FIX_VERSION then return end
    local players = db.players
    if type(players) ~= "table" then
        db.zoneIdFixed = NSP_ZONE_FIX_VERSION
        return
    end
    local fixed, added = 0, 0
    for _, rec in pairs(players) do
        if type(rec) == "table" then
            local zone = rec.zone
            if type(zone) == "string" and zone ~= "" and zone ~= "?" then
                local resolved = ZoneIdByName(zone)
                if resolved and resolved > 0 then
                    local zid = rec.zoneId
                    if not zid or zid == 0 then
                        rec.zoneId = resolved
                        added = added + 1
                    elseif resolved ~= zid then
                        rec.zoneId = resolved
                        fixed = fixed + 1
                    end
                end
            end
        end
    end
    db.zoneIdFixed = NSP_ZONE_FIX_VERSION
    db.debug = db.debug or {}
    db.debug.zoneIdFixed = (db.debug.zoneIdFixed or 0) + fixed
    db.debug.zoneIdAdded = (db.debug.zoneIdAdded or 0) + added
    if fixed > 0 or added > 0 then
        R(("zoneId fix: %d corrected by zone text, %d restored"):format(fixed, added))
    end
end

-- ============ helpers shared with world collection ============
-- ProbeText и ProbeTip остались после вырезания probe-блоков: ими
-- пользуется сбор мира (имя предмета из тултипа, чтение торговой позиции).
local function ProbeText(fs)
    if not fs or type(fs.GetText) ~= "function" then return nil end
    local ok, txt = pcall(fs.GetText, fs)
    if not ok or txt == nil then return nil end
    if type(txt) ~= "string" then return "[secret]" end
    if canaccessvalue and not canaccessvalue(txt) then return "[secret]" end
    return NspCut(txt, 120)
end

local probeTip
-- ProbeTip — тултип для чтения торговой позиции. Свой, чтобы не трогать
-- подсказку пользователя; шаблон может отсутствовать — тогда пробуем
-- GameTooltip, и только если нет и его, проба сдаётся.
function ProbeTip()
    if probeTip then return probeTip end
    local ok, tip = pcall(CreateFrame, "GameTooltip", "NearbySpyProbeTip", UIParent, "GameTooltipTemplate")
    if ok and tip then
        pcall(tip.SetOwner, tip, UIParent, "ANCHOR_NONE")
        probeTip = tip
        return probeTip
    end
    if GameTooltip then
        probeTip = GameTooltip
        return probeTip
    end
    return nil
end

-- ============ world data: vendors and fishing (сбор, 08.11.2026) ============


-- Хелперы мира — поля одной таблицы: в Lua 5.1 на главный чанк приходится
-- не больше 200 локалов, а каждая отдельная local function съедает один.
local WR = {}

-- WR.TipName — имя предмета из тултипа торговой позиции, но ТОЛЬКО когда
-- клиент действительно знает предмет.
--
-- Проблема (живые данные 09.11.2026): для предметов, которых нет в кэше
-- клиента, тултип показывает ОДНУ служебную строку «Получение сведений о
-- предмете» / «Retrieving item information». Она уезжала в базу как имя
-- (13 позиций у четырёх торговцев). Признак заглушки структурный, а не
-- текстовый: у известного предмета тултип всегда многострочный (имя +
-- тип/применение/цена), у заглушки вторая строка пуста. Список локализованных
-- строк не нужен и был бы хрупким.
function WR.TipName(tip)
    if not tip then return nil end
    local base = (tip.GetName and tip:GetName()) or "GameTooltip"
    local first = ProbeText(_G[base .. "TextLeft1"])
    if not first or first == "" or first == "[secret]" then return nil end
    local second = ProbeText(_G[base .. "TextLeft2"])
    if not second or second == "" or second == "[secret]" then return nil end
    return first
end

-- UnitMapXY — координаты юнита в системе карты (0..1), как у игроков:
-- C_Map.GetPlayerMapPosition принимает любой юнит, поэтому у торговца берётся
-- его собственная точка, а не позиция игрока. Если клиент отказал — nil, и
-- вызывающий код откатывается на PlayerXY.
function WR.UnitMapXY(unit)
    local ok, mapID = pcall(C_Map.GetBestMapForUnit, unit)
    if not ok or not mapID or mapID == 0 then return nil, nil end
    local ok2, pos = pcall(C_Map.GetPlayerMapPosition, mapID, unit)
    if not ok2 or not pos then return nil, nil end
    local x, y = pos:GetXY()
    if not x or not y or (x == 0 and y == 0) then return nil, nil end
    return Round4(x), Round4(y)
end

-- API снят с живого клиента 1.60.1 (пробы 08.11.2026), не из документации:
--   GetItemInfo / GetMerchantItemInfo / GetLootSlot — ОТСУТСТВУЮТ;
--   C_Item.GetItemInfoInstant(id) -> id, class, subclass, invType, icon,
--                                   classID, subclassID (числа, не зависят от языка);
--   C_Item.GetItemNameByID(id)    -> локализованное имя;
--   C_Item.GetItemInfo(id)        -> name, link, quality, iLvl, reqLevel, ...
--   GetMerchantNumItems / GetMerchantItemID / GetMerchantItemMaxStack — работают;
--   GetMerchantItemLink отдаёт nil, пока позиция не отрисована тултипом —
--   поэтому линки не нужны: itemID берём из GetMerchantItemID.
-- Цена: C_MerchantFrame (проба v3) либо MoneyFrame окна торговца; если нет ни
-- того ни другого — цена не пишется (не выдумываем).
--
-- Классы предметов числовые и одинаковы во всех локалях: 9 = Recipe
-- (рецепты), 7 = Tradeskill (материалы), 0 = Consumable. Фильтр «показать
-- рецепты» делает сайт по classID, поэтому в SV едут все позиции вендора.
-- Лимиты SV: растущий SavedVariables замедляет выход из игры, поэтому потолки
-- жёсткие, а отброшенное считается в debug. Одна таблица — экономия локалов
-- (в Lua 5.1 их не больше 200 на функцию, а основной чанк уже близок к лимиту).
local WORLD_LIM = {
    vendors = 300,   -- вендоров
    perVendor = 200, -- позиций на вендора
    items = 4000,    -- позиций всего
    fish = 3000,     -- строк рыбалки
    -- сколько позиций вендора догадывать именем через тултип (каждая
    -- отрисовка небесплатна; на практике безымянных единицы)
    nameLookup = 40,
}

-- WorldItem — имя и классы предмета по itemID. Все вызовы под pcall:
-- в этом клиенте есть secret-значения и защищённые функции.
function WR.Item(itemID)
    if not itemID then return nil end
    local out = { id = itemID }
    local ci = _G.C_Item
    if type(ci) == "table" then
        if type(ci.GetItemInfoInstant) == "function" then
            -- pcall добавляет флаг успеха первым, поэтому индексы сдвинуты на 1:
            -- r[2]=itemID, r[3]=class(loc), r[4]=subclass(loc), r[5]=invType,
            -- r[6]=icon, r[7]=classID, r[8]=subclassID (проверено пробой 08.11.2026)
            local r = { pcall(ci.GetItemInfoInstant, itemID) }
            if r[1] then
                local cid, sid = tonumber(r[7]), tonumber(r[8])
                if cid then out.c = cid end
                if sid then out.s = sid end
            end
        end
        if type(ci.GetItemNameByID) == "function" then
            local ok, name = pcall(ci.GetItemNameByID, itemID)
            if ok and type(name) == "string" and name ~= "" then out.n = name end
        end
        if type(ci.GetItemInfo) == "function" then
            local r = { pcall(ci.GetItemInfo, itemID) }
            if r[1] then
                -- r[2] — имя; у части предметов GetItemNameByID молчит,
                -- а GetItemInfo имя отдаёт (проверено на 159 и 2678)
                if not out.n and type(r[2]) == "string" and r[2] ~= "" then out.n = r[2] end
                local q, stack = tonumber(r[4]), tonumber(r[9])
                if q then out.q = q end
                if stack then out.st = stack end
            end
        end
    end
    return out
end

-- WorldVendorPrice — цена позиции в меди. Порядок источников:
-- MoneyFrame окна торговца (то, что видит игрок) → C_MerchantFrame.GetItemInfo.
function WR.Price(idx)
    -- Основной путь: C_MerchantFrame.GetItemInfo(idx) возвращает ОДНУ таблицу
    -- { name, texture, price, stackCount, numAvailable, ... } — цена в меди.
    -- Проверено пробой 08.11.2026: price=25 у «Освежающей ключевой воды».
    local cmf = _G.C_MerchantFrame
    if type(cmf) == "table" and type(cmf.GetItemInfo) == "function" then
        local ok, info = pcall(cmf.GetItemInfo, idx)
        if ok and type(info) == "table" then
            local price = tonumber(info.price)
            if price and price > 0 then return price, tonumber(info.stackCount) end
        end
    end
    -- Резерв: деньги на кнопке позиции (в части клиентов price не отдаётся)
    local mf = _G["MerchantItem" .. idx .. "MoneyFrame"]
    if mf then
        if type(mf.GetMoney) == "function" then
            local ok, money = pcall(mf.GetMoney, mf)
            if ok and tonumber(money) then return tonumber(money) end
        end
        if type(mf.GetAmount) == "function" then
            local ok, money = pcall(mf.GetAmount, mf)
            if ok and tonumber(money) then return tonumber(money) end
        end
    end
end

-- WorldVendorKey — идентичность вендора: GUID существа, иначе имя+зона
function WR.VendorKey(guid, name, zoneId)
    if guid and guid ~= "" then return guid end
    return tostring(name) .. "@" .. tostring(zoneId or 0)
end

-- WR.NpcIDFromGUID — id NPC из GUID вида
-- "Creature-0-7090-2991-2-257008-A222425F2A" -> 257008.
-- Пятое поле после дефиса и есть npcID; в базе MasterCraft ключи — ровно эти
-- числа, поэтому сравнивать надо по ним, а не по имени: имена локализованы
-- (ruRU-клиент отдаёт «Баэланн Быстрый Поток», в базе — английское написание).
function WR.NpcIDFromGUID(guid)
    if type(guid) ~= "string" then return nil end
    local id = guid:match("^Creature%-%d+%-%d+%-%d+%-%d+%-(%d+)%-")
    return id and tonumber(id) or nil
end

-- WR.NoteMastercraftGap — торговец, которого нет в базе MasterCraft.
--
-- Зачем: NearbySpy продолжает пассивно записывать торговцев, а MasterCraft
-- держит статическую базу из Wowhead Forever. Наш интерес — именно разница:
-- сервер кастомный, и его торговцы в дампе Wowhead отсутствуют. Нотис
-- превращает это из «данных, которые никто не смотрит» в сигнал.
--
-- Один нотис на торговца за сессию (world.mcNotified), счётчик — в /nspy world.
function WR.NoteMastercraftGap(db, guid, name, zoneId)
    if type(NSP_MC) ~= "table" then return end          -- снимка нет: молчим
    local npcID = WR.NpcIDFromGUID(guid)
    if not npcID then return end                        -- без id сравнить нечем
    local known = false
    local list = NSP_MC.vendors
    if type(list) == "table" then
        for i = 1, #list do
            if list[i] == npcID then known = true break end
        end
    end
    if known then return end

    local world = db.world
    world.mcNotified = world.mcNotified or {}
    if world.mcNotified[npcID] then return end          -- уже сообщали
    world.mcNotified[npcID] = true
    world.mcNewTotal = (world.mcNewTotal or 0) + 1

    P(L("MC_NEW_VENDOR"):format(
        name ~= "" and name or ("#" .. npcID),
        PlayerZone() or "?",
        tostring(NSP_MC.version or "?")))
end

-- CollectVendor — снимок окна торговца в db.world.vendors.
-- Вызывается на MERCHANT_SHOW (сбор пассивный, кликов не требует).
function WR.CollectVendor()
    local okNum, num = pcall(GetMerchantNumItems)
    num = okNum and tonumber(num) or 0
    if num <= 0 then return end
    local db = GetDB()
    local world = db.world
    if type(world) ~= "table" then world = { vendors = {}, fish = {} }; db.world = world end
    world.vendors = world.vendors or {}
    local guid = pcall(UnitGUID, "npc") and select(1, UnitGUID("npc")) or nil
    local name = pcall(UnitName, "npc") and select(1, UnitName("npc")) or ""
    local zoneId = PlayerZoneId()
    local key = WR.VendorKey(type(guid) == "string" and guid or nil, name, zoneId)
    local v = world.vendors[key]
    if not v then
        local count = 0
        for _ in pairs(world.vendors) do count = count + 1 end
        if count >= WORLD_LIM.vendors then
            db.debug = db.debug or {}
            db.debug.vendorsDropped = (db.debug.vendorsDropped or 0) + 1
            return
        end
        v = { items = {}, first = time() }
        world.vendors[key] = v
        -- НОВЫЙ торговец: сверяем с базой MasterCraft. У него статическая база
        -- из Wowhead (331 вендор), но кастомный сервер её не покрывает — на
        -- живых данных 10.11.2026 из десяти пойманных торговцев семь в его базе
        -- отсутствовали. Нотис показывает именно такие находки.
        WR.NoteMastercraftGap(db, guid, name, zoneId)
    end
    v.guid = type(guid) == "string" and guid or nil
    v.n = (name ~= "" and name) or v.n
    v.z = zoneId
    v.zn = PlayerZone()
    -- точка вендора: сначала собственная позиция NPC, затем позиция игрока
    -- (он стоит у прилавка — это ближайшее приближение, если клиент не отдал
    -- координаты не-игрового юнита)
    local nx, ny = WR.UnitMapXY("npc")
    if not nx then nx, ny = PlayerXY() end
    if nx then v.x, v.y = nx, ny end
    v.last = time()
    v.seen = (v.seen or 0) + 1
    local total = 0
    for _, vv in pairs(world.vendors) do
        for _ in pairs(vv.items or {}) do total = total + 1 end
    end
    for i = 1, num do
        local okID, itemID = pcall(GetMerchantItemID, i)
        itemID = okID and tonumber(itemID) or nil
        if itemID then
            local it = v.items[itemID]
            if not it then
                local n = 0
                for _ in pairs(v.items) do n = n + 1 end
                if n < WORLD_LIM.perVendor and total < WORLD_LIM.items then
                    it = WR.Item(itemID) or { id = itemID }
                    it.first = time()
                    v.items[itemID] = it
                    total = total + 1
                end
            end
            if it then
                it.last = time()
                it.seen = (it.seen or 0) + 1
                local price, buyStack = WR.Price(i)
                if price then it.p = price end
                -- price относится к лоту покупки (stackCount), а не к единице:
                -- без этого цена за штуку считается неверно при stackCount > 1
                if buyStack and buyStack > 0 then it.bs = buyStack end
                if not it.st then
                    local okS, stack = pcall(GetMerchantItemMaxStack, i)
                    if okS and tonumber(stack) then it.st = tonumber(stack) end
                end
            end
        end
    end
    -- безымянные позиции: имя не пришло из C_Item — добираем тултипом.
    -- Окно торговца открыто (мы в MERCHANT_SHOW), поэтому SetMerchantItem
    -- работает; ограничено лимитом, чтобы открытие торговца не превращалось
    -- в сотню отрисовок.
    local tip, looked = nil, 0
    for i = 1, num do
        if looked >= WORLD_LIM.nameLookup then break end
        local okID, itemID = pcall(GetMerchantItemID, i)
        itemID = okID and tonumber(itemID) or nil
        local row = itemID and v.items[itemID]
        if row and not row.n then
            if not tip then tip = ProbeTip() end
            if tip then
                looked = looked + 1
                if pcall(tip.SetMerchantItem, tip, i) then
                    -- WR.TipName отсекает служебную заглушку «Получение
                    -- сведений о предмете»: имя остаётся пустым и запишется
                    -- при следующем визите, когда кэш клиента прогрет
                    local line = WR.TipName(tip)
                    if line then row.n = line end
                end
            end
        end
    end
end

-- CollectFishing — улов в db.world.fish, ключ «зона:предмет».
-- Пишется только когда IsFishingLoot() истинно: обычный лут с трупов
-- в базу не попадает.
function WR.CollectFishing()
    local okFlag, isFish = pcall(IsFishingLoot)
    if not okFlag or not isFish then return end
    local okNum, num = pcall(GetNumLootItems)
    num = okNum and tonumber(num) or 0
    if num <= 0 then return end
    local db = GetDB()
    local world = db.world
    if type(world) ~= "table" then world = { vendors = {}, fish = {} }; db.world = world end
    world.fish = world.fish or {}
    local zoneId = PlayerZoneId() or 0
    local ok, err = pcall(function()
        for i = 1, num do
            local okLink, link = pcall(GetLootSlotLink, i)
            local itemID
            if okLink and type(link) == "string" then
                itemID = tonumber(link:match("item:(%d+)"))
            end
            if itemID then
                local key = zoneId .. ":" .. itemID
                local row = world.fish[key]
                if not row then
                    local count = 0
                    for _ in pairs(world.fish) do count = count + 1 end
                    if count >= WORLD_LIM.fish then
                        db.debug = db.debug or {}
                        db.debug.fishDropped = (db.debug.fishDropped or 0) + 1
                        return
                    end
                    row = WR.Item(itemID) or { id = itemID }
                    row.z = zoneId
                    row.zn = PlayerZone()
                    row.first = time()
                    row.cnt = 0
                    world.fish[key] = row
                end
                row.cnt = (row.cnt or 0) + 1
                row.last = time()
                -- последняя точка, где поймано: строки агрегированы по зоне,
                -- поэтому храним свежую координату, а не список всех уловов
                local px, py = PlayerXY()
                if px then row.x, row.y = px, py end
            end
        end
    end)
    if not ok then DbgErr("fishing", err) end
end

-- WorldCounts — сколько собрано (для /nspy world)
function WR.Counts()
    local db = GetDB()
    local world = db.world or {}
    local vendors, items, fish = 0, 0, 0
    for _ in pairs(world.vendors or {}) do vendors = vendors + 1 end
    for _, v in pairs(world.vendors or {}) do
        for _ in pairs(v.items or {}) do items = items + 1 end
    end
    for _ in pairs(world.fish or {}) do fish = fish + 1 end
    return vendors, items, fish, world.mcNewTotal or 0
end

-- file key -> localized class name, for the window: peer packets carry only the
-- file key ("DRUID"), so a row received from another player printed "DRUID" while
-- a locally recorded row printed "Друид". Fixed at DISPLAY time, so records
-- already stored in SavedVariables get localized too — no rewrite needed.
-- Global on purpose: the main chunk is at the Lua 5.1 ceiling of 200 locals.
-- Отображаемое имя класса — ВСЕГДА на языке КЛИЕНТА, как и названия зон.
-- Решение пользователя 09.11.2026: названия из игры (класс, зона) не переводим
-- своей таблицей — аддон показывает то же, что игрок видит в игре. Поэтому
-- переключение языка интерфейса меняет надписи аддона, но не имена из игры.
--
-- Зачем обёртка вообще нужна: peer-пакеты несут ТОЛЬКО файл-ключ класса
-- ("DRUID"), поэтому без перевода ключа в клиентскую строку чужая запись
-- показывала "DRUID" рядом с "Друид" у своей. ClassLocFromFile — это перевод
-- ключа в строку ЯЗЫКА КЛИЕНТА, а не наш перевод.
function ClassDisplayName(file, fallback)
    -- Никогда не nil: результат идёт прямо в format("%s")
    return fallback or ClassLocFromFile(file) or file or "?"
end

function ClassLocFromFile(file)
    if type(file) ~= "string" or file == "" then return nil end
    local male = LOCALIZED_CLASS_NAMES_MALE
    if male and male[file] then return male[file] end
    local female = LOCALIZED_CLASS_NAMES_FEMALE
    if female and female[file] then return female[file] end
    return nil
end

-- localized class name -> file key (for UI color)
local function ClassFileFromLocalized(classStr)
    if not classStr or classStr == "" then return nil end
    for _, tbl in ipairs({ LOCALIZED_CLASS_NAMES_MALE, LOCALIZED_CLASS_NAMES_FEMALE }) do
        if tbl then
            for file, loc in pairs(tbl) do
                if loc == classStr then return file end
            end
        end
    end
    return nil
end

-- ===================== записи игроков: позиционная схема =====================
-- Раскладка слотов и метатаблица живут в NearbySpy_Locale.lua (NSP_REC): главный
-- чанк стоит у потолка Lua 5.1 в 200 top-level locals, поэтому здесь только
-- глобальные функции. Обе объявлены глобальными намеренно.

-- Новая запись в позиционной схеме v4 (16 слотов). Все слоты заполняются сразу
-- (`false` вместо nil): дырка в array-части ломает и `#`, и запись SavedVariables.
--
-- v4 держит 16 слотов не случайно: array-часть таблицы в Lua 5.1 выделяется под
-- степень двойки, поэтому 17–32 слота занимают одинаково (замер на 53 570
-- записях: 21 слот = 30.43 МБ, 16 = 17.35 МБ). Отсюда упаковка:
--   class + faction + source → слот cfs (маска), peerNew + peerForeign → peerFlags;
--   x, y удалены — это была позиция наблюдателя, приёмники её не читали.
-- Наружу поля отдаёт метатаблица, поэтому `p.class` и `p.source` не изменились.
function NspNewPlayerRec(key, data, observed, nowT)
    local peer = (data.source == "peer")
    local place = observed or peer
    local rec = {
        data.name or false,                                     -- 1  name
        0,                                                      -- 2  cfs (маска)
        data.level or false,                                    -- 3  level
        data.realm or false,                                    -- 4  realm
        (place and data.zone) or false,                         -- 5  zone
        (place and data.zoneId) or false,                       -- 6  zoneId
        observed and nowT or 0,                                 -- 7  lastSeen
        observed and nowT or 0,                                 -- 8  firstSeen
        observed and 1 or 0,                                    -- 9  count
        data.race or false,                                     -- 10 race
        data.guid or false,                                     -- 11 guid
        peer and nowT or false,                                 -- 12 peerAt
        0,                                                      -- 13 peerFlags
        data.peerRealm or false,                                -- 14 peerRealm
        data.peerFrom or false,                                 -- 15 peerFrom
        false,                                                  -- 16 gear
    }
    setmetatable(rec, NSP_REC.MT)
    -- маски заполняем через метатаблицу: она знает коды и не затирает соседей
    rec.class = data.class
    rec.faction = data.faction
    rec.source = data.source
    rec.peerNew = peer or nil
    rec.peerForeign = data.peerForeign
    return rec
end

-- Приведение базы к позиционной схеме.
--
-- Метатаблица НЕ сохраняется в SavedVariables: клиент пишет только данные, и
-- после перезапуска игры записи приходят голыми массивами. Поэтому проход нужен
-- при КАЖДОЙ загрузке, даже когда db.recSchema уже равен текущей версии — он
-- навешивает метатаблицу и добивает недостающие слоты.
--
-- Схем четыре, и все обязаны читаться:
--   hash (совсем старые файлы) — поля по именам, позиций нет;
--   v2 (recSchema=2)           — 23 слота, с classLoc и key;
--   v3 (recSchema=3)           — 21 слот, без них;
--   v4 (recSchema=4, текущая)  — 16 слотов, class/faction/source в маске cfs,
--                                peerNew/peerForeign в peerFlags, x/y удалены.
-- Таблицу нельзя подменить прямо в pairs(), поэтому ключи собираются заранее.
--
-- Список полей и числовые слоты живут в NSP_REC (NSP_REC.FIELDS/NUMERIC): этот
-- чанк стоит у потолка Lua 5.1 в 200 top-level locals, и лишние local'ы могли бы
-- выбить именно его — с падением «too many local variables» при загрузке, то есть
-- аддон просто не появился бы.
function NspMigrateRecords(db)
    if type(db) ~= "table" or type(db.players) ~= "table" then return 0, 0 end
    local SLOTS = NSP_REC.SLOTS
    local FIELDS = NSP_REC.FIELDS
    local NUMERIC = NSP_REC.NUMERIC
    local attached, converted = 0, 0
    -- Файл без метки recSchema — это hash либо v2; различает IsPositional.
    local fromSchema = tonumber(db.recSchema) or 2
    local todoHash, todoOld = nil, nil
    for k, p in pairs(db.players) do
        if type(p) == "table" then
            if not NSP_REC.IsPositional(p) then
                todoHash = todoHash or {}
                todoHash[#todoHash + 1] = k
            elseif fromSchema < NSP_REC.SCHEMA then
                -- метка версии младше текущей: записи ещё в прежней раскладке.
                -- Длину записи здесь не проверяем — её определяет SourceLayout,
                -- потому что короткая v2 (без снимка экипировки) короче v3.
                todoOld = todoOld or {}
                todoOld[#todoOld + 1] = k
            else
                -- добить недостающие слоты (база, сохранённая версией с меньшим
                -- числом полей) и навесить метатаблицу
                for i = 1, SLOTS do
                    if rawget(p, i) == nil then rawset(p, i, false) end
                end
                if getmetatable(p) ~= NSP_REC.MT then
                    setmetatable(p, NSP_REC.MT)
                    attached = attached + 1
                end
            end
        end
    end

    -- Раскладка источника: v2 (23), v3 (21). Определяем по длине записи, а не
    -- только по метке: файл без recSchema — это v2, а короткая v2-запись (без
    -- снимка экипировки) не должна разложиться по v3 — иначе поля после level
    -- поедут молча.
    local function SourceLayout(p)
        local n = #p
        if n >= 23 or rawget(p, NSP_REC.V2.key) ~= nil then return NSP_REC.V2 end
        return NSP_REC.V3
    end

    -- Пересборка одной записи по именам полей.
    -- srcIndex — таблица «имя поля -> позиция» в источнике (nil для hash-схемы).
    -- Поле, у которого в v4 нет своего слота (class/faction/source/peerNew/
    -- peerForeign), пишется по имени — метатаблица кладёт его в маску.
    local function Rebuild(src, srcIndex)
        local rec = {}
        for i = 1, SLOTS do rec[i] = false end
        -- маски начинаются с нуля: иначе первое же присваивание в пустую
        -- array-ячейку дало бы nil и метатаблица упала бы на арифметике
        rec[NSP_REC.cfs] = 0
        rec[NSP_REC.peerFlags] = 0
        setmetatable(rec, NSP_REC.MT)
        for _, f in ipairs(FIELDS) do
            local v
            if srcIndex then
                local srcPos = srcIndex[f]
                v = srcPos and rawget(src, srcPos) or nil
            else
                v = src[f]
            end
            if v == nil or v == false then
                v = NUMERIC[f] and 0 or nil
            end
            local slot = NSP_REC[f]
            if slot then
                -- ⚠️ НЕ `(v == nil) and false or v`: в Lua `false or nil` = nil,
                -- поэтому такая идиома записывает в слот nil вместо false и рвёт
                -- array-часть (проверено: 10 слотов из 16 оказывались nil).
                if v == nil then
                    rec[slot] = false
                else
                    rec[slot] = v
                end
            else
                -- поле из маски: nil очищает биты, значение — ставит код
                rec[f] = v
            end
        end
        return rec
    end

    if todoHash then
        for _, k in ipairs(todoHash) do
            db.players[k] = Rebuild(db.players[k], nil)
            converted = converted + 1
        end
    end
    if todoOld then
        for _, k in ipairs(todoOld) do
            -- classLoc и key из v2, x/y из v3 НЕ переносятся: первые два
            -- выводимы, координаты были позицией наблюдателя и не читались.
            db.players[k] = Rebuild(db.players[k], SourceLayout(db.players[k]))
            converted = converted + 1
        end
    end
    db.recSchema = NSP_REC.SCHEMA
    return converted, attached
end

-- shared record/upsert
-- data.observe == false marks a profile-only update: the source knows who the
-- player is, but nobody actually saw them in the world. Such updates enrich
-- class/level/guid and never touch lastSeen/count/zone — a guild roster row is
-- not proof of presence (the roster lists offline guildmates too).
local QueuePeerNew -- assigned below; only local discoveries may call it
local function UpsertPlayer(db, data)
    local key = data.key
    if not key then return false end
    local nowT = time()
    local observed = data.observe ~= false
    local entry = db.players[key]
    if not entry then
        -- Позиционная схема (NSP_REC): запись — массив из 23 слотов, а имена
        -- полей отдаёт общая метатаблица. Правила заполнения:
        --   • место (zone/zoneId/x/y) пишется только для НАШЕЙ встречи или
        --     peer-пакета (протокол N3): для записи, которую мы никогда не
        --     видели сами, это единственный источник места;
        --   • lastSeen/count остаются 0 у профиля без встречи (сентинел
        --     «профиль, а не встреча», см. NspPrune и парсеры);
        --   • peerAt/peerNew живут в SV, чтобы фильтр Peer и /nspy peer new
        --     отвечали после перелогина (счётчики в памяти умирают на логауте);
        --   • peerRealm/peerForeign — канал общий на кластер (CAMWOW EU4/EU5),
        --     поэтому выгрузка обязана отличать своё наблюдение от чужого;
        --   • peerFrom — провенанс: peer-записи никогда не пересылаются
        --     повторно, значит отправитель и есть первооткрыватель.
        db.players[key] = NspNewPlayerRec(key, data, observed, nowT)
        newThisSession = newThisSession + 1
        -- Буфер окна (26.11.2026): НОВАЯ запись тоже встаёт в список последних.
        -- Без этого строка появлялась бы в окне только со второго раза
        -- (catch: тест test_touch_is_called_from_the_single_write_point).
        if observed and NspRecentTouch then NspRecentTouch(key, db.players[key]) end
        -- Зона пришла ТЕКСТОМ без id (peer с zoneId=0, чат, чужой клиент) —
        -- восстанавливаем id вшитой таблицей билда. Без этого такие записи
        -- нельзя ни показать на языке интерфейса, ни фильтровать по зоне:
        -- замер по живому SV 24.11.2026 — 72 из 209 записей /who остались без
        -- zoneId, хотя все их названия есть в таблице.
        NspResolveZoneId(db.players[key])
        -- Усыновление отложенного peer-снапшота (25.11.2026): пакет G7 мог
        -- прийти РАНЬШЕ этой записи и лежать в orphan-буфере (NSP_INSPECT).
        -- Прикрепляем здесь: строка только что появилась и она уже полная —
        -- класс, уровень и мир есть, значит на сайт снапшот уйдёт осмысленным.
        if NSP_INSPECT and type(NSP_INSPECT.AdoptPeerGear) == "function" then
            pcall(NSP_INSPECT.AdoptPeerGear, key, data.name or db.players[key].name)
        end
        -- Journal (1.5.7): a player that entered the database is a real
        -- encounter. Peer packets are excluded — someone else reporting a
        -- sighting is not our meeting (same contract as the alert feature).
        if observed and data.source ~= "peer" and NSP_JOURNAL then
            pcall(NSP_JOURNAL.Encounter, db, key, true)
        end
        -- per-source counter (1.5.1, full debug): who actually feeds the database
        local src = data.source or "?"
        db.debug.src = db.debug.src or {}
        db.debug.src[src] = (db.debug.src[src] or 0) + 1
        if db.announce and not data.silent then
            P(L("FIRST_SEEN"):format(
                data.name,
                data.class and (data.class .. ", ") or "",
                data.level and (L("LVL_PREFIX") .. data.level) or "?",
                data.zone or "?"))
        end
        if data.source ~= "peer" and observed and QueuePeerNew then QueuePeerNew(db, data) end
        return true
    end
    -- Значения ДО обновления: по ним видно, изменилось ли что-то, что стоит
    -- сообщить в канал (/who увидел знакомого с новым уровнем/в новой зоне).
    local prevLevel, prevZoneId, prevZone = entry.level, entry.zoneId, entry.zone
    if observed then
        if nowT - (entry.lastSeen or 0) > NSP_CONST.REAP_SECONDS then
            entry.count = (entry.count or 1) + 1
        end
        entry.lastSeen = nowT
        -- Буфер окна (26.11.2026): запись встаёт в список последних по времени.
        -- Единственная точка записи игрока — здесь и поддерживаем порядок, тогда
        -- окно показывает список без единой сортировки.
        if NspRecentTouch then NspRecentTouch(key, entry) end
        -- Источник: НАША наблюденная встреча вытесняет "peer". Раньше source
        -- не обновлялся вовсе, и игрок, которого мы встретили лично, оставался
        -- с source="peer" навсегда — а по нему приёмник считал запись чужой.
        -- Теперь source честно отражает последнее, ЧТО мы знаем: видели мы его
        -- сами (who/unit/chat/guild) или только слышали о нём от другого.
        if data.source and data.source ~= "peer" then entry.source = data.source end
        -- Place from OUR OWN sighting only. `observed` is true for peer packets
        -- too (it means "not a profile-only row"), so without this guard a peer
        -- packet overwrote the zone we had seen ourselves — caught by
        -- test_peer_place_does_not_overwrite_our_own_sighting.
        if data.zone and data.source ~= "peer" then
            entry.zone = data.zone
            -- Текст зоны обновился, а id источник не прислал (ростер гильдии
            -- отдаёт только текст; /who — когда имя не резолвится). Оставлять
            -- старый id нельзя: он описывает ДРУГУЮ зону, и ZoneDisplay по нему
            -- покажет чужую зону, а на сайт уйдёт неверный zoneId. Текст всегда
            -- свежее id — он пишется каждым наблюдением.
            if not data.zoneId then
                local resolved = ZoneIdByName(data.zone)
                if resolved and resolved > 0 then entry.zoneId = resolved end
            end
        end
        if data.zoneId and data.source ~= "peer" then entry.zoneId = data.zoneId end
        -- x/y больше не храним (v4): это была позиция НАБЛЮДАТЕЛЯ, а не цели,
        -- и приёмники её не читали. Слоты убраны ради перехода в блок на 16
        -- ячеек — именно он даёт −13 МБ памяти клиента.
    end
    -- Journal (1.5.7): a known player seen again is an encounter too, but only
    -- our own sighting counts (peer rows also carry observe=true).
    if observed and data.source ~= "peer" and NSP_JOURNAL then
        pcall(NSP_JOURNAL.Encounter, db, key, false)
    end
    -- Identity fields: peer data can only fill gaps, a real observation may
    -- correct it (a peer record is not proof of race/faction).
    --
    -- Исключение — пакет N4 со временем: если он СВЕЖЕЕ всего, что мы знаем об
    -- игроке, то его level/zone достоверны на момент наблюдения и должны
    -- обновлять запись. Иначе обмен обновлениями бессмысленен: /who увидел
    -- знакомого с новым уровнем, пакет ушёл, а получатель проигнорировал бы
    -- его как «peer не доказывает». Раса и фракция остаются как были — их
    -- пакет по-прежнему не доказывает, они меняются только с нашей встречи.
    local peerFresh = false
    if data.source == "peer" and data.peerObservedAt then
        local known = math.max(entry.lastSeen or 0, entry.peerAt or 0)
        peerFresh = (data.peerObservedAt > known)
    end
    if data.level and (data.source ~= "peer" or not entry.level or peerFresh) then
        entry.level = data.level
    end
    if data.class and (data.source ~= "peer" or not entry.class) then entry.class = data.class end
    if data.faction and data.faction ~= "Unknown"
        and (data.source ~= "peer" or not entry.faction or entry.faction == "Unknown") then
        entry.faction = data.faction
    end
    if data.race and data.race ~= "Unknown"
        and (data.source ~= "peer" or not entry.race or entry.race == "Unknown") then
        entry.race = data.race
    end
    entry.guid = entry.guid or data.guid
    if data.source == "peer" then
        -- The row already existed: remember when a peer last reported it. This
        -- keeps peerNew untouched (the player was first known from a real
        -- sighting) while the Peer filter still shows the record.
        entry.peerAt = nowT
        -- Буфер окна: время пакета — единственное время такой записи, поэтому
        -- без этого вызова вкладка «Обмен новые» оставалась пустой до пересборки
        -- (26.11.2026).
        if NspRecentTouch then NspRecentTouch(key, entry) end
        if data.peerRealm then entry.peerRealm = data.peerRealm end
        if data.peerForeign then entry.peerForeign = true end
        -- the latest sender wins: the row is "last corroborated by" this character
        if data.peerFrom then entry.peerFrom = data.peerFrom end
        -- Place from a peer only fills a gap — unless the packet is FRESHER than
        -- everything we know (N4 with a time): then it is the newest snapshot
        -- available and should replace a stale zone. Our own fresh sighting
        -- still wins, because peerFresh compares against lastSeen too.
        if peerFresh then
            if data.zone then entry.zone = data.zone end
            if data.zoneId and data.zoneId > 0 then entry.zoneId = data.zoneId end
        else
            if not entry.zone and data.zone then entry.zone = data.zone end
            if not entry.zoneId and data.zoneId then entry.zoneId = data.zoneId end
        end
    end
    -- Обновление для канала: /who (или другая наша встреча) показала знакомого
    -- с ДРУГИМ уровнем или в другой зоне. Раньше такие изменения оседали только
    -- в локальной базе — в канал уходило лишь создание записи, поэтому чужие
    -- уровни у нас устаревали навсегда.
    --
    -- Условия: это наша встреча (не peer — иначе бесконечная ретрансляция),
    -- и в записи действительно что-то поменялось. Дедуп в QueuePeerNew держит
    -- ключ с самими значениями, так что одно и то же изменение уйдёт один раз.
    -- Зона обновлена текстом без id (новая встреча в другой зоне, peer-пакет
    -- с zoneId=0) — досстанавливаем id по имени. Здесь, а не только в ветке
    -- создания: запись могла существовать, а зона прийти впервые.
    NspResolveZoneId(entry)
    if observed and data.source ~= "peer" and QueuePeerNew then
        local changedLevel = data.level and prevLevel and data.level ~= prevLevel
        -- Смена зоны решается ПО ID, а не по тексту (24.11.2026).
        --
        -- Название зоны локализовано и приходит на языке той сессии, которой
        -- сделана запись: в базе рядом лежат «Тирисфальские леса» (старый
        -- ruRU-клиент) и «Tirisfal» (deDE) — это ОДНА зона с одним id. Текстовое
        -- сравнение объявляло такие записи сменой зоны и слало в канал пустое
        -- обновление при каждой повторной встрече.
        --
        -- Старый id досстанавливаем из текста той же вшитой таблицей: иначе
        -- «id появился впервые» выглядело бы как смена зоны. Текст остаётся
        -- сравнением только когда id нет ни с одной стороны (старые записи).
        local newZoneId = tonumber(data.zoneId) or 0
        local oldZoneId = tonumber(prevZoneId) or 0
        if oldZoneId == 0 and type(prevZone) == "string" and prevZone ~= ""
            and prevZone ~= "?" then
            oldZoneId = ZoneIdByName(prevZone) or 0
        end
        local changedZone
        if newZoneId > 0 and oldZoneId > 0 then
            changedZone = (newZoneId ~= oldZoneId)
        else
            changedZone = data.zone and data.zone ~= "" and data.zone ~= prevZone
        end
        if changedLevel or changedZone then
            local upd = {}
            for k, v in pairs(data) do upd[k] = v end
            upd.isUpdate = true
            upd.observedAt = nowT
            upd.level = data.level or prevLevel
            upd.zone = data.zone or prevZone
            upd.zoneId = data.zoneId or prevZoneId
            QueuePeerNew(db, upd)
        end
    end
    return false
end

-- Opt-in, realm-local peer exchange. Received records never re-enter the queue.
-- Канал обмена привязан к ФРАКЦИИ. Сервер не пускает персонажа одной фракции
-- в канал, созданный другой (проверено 10.11.2026: под Ордой вход в общий
-- "nearbyspydata", созданный Альянсом, отклонён сервером).
--
-- Суффикс приклеивается БЕЗ разделителя: подчёркивание в имени канала клиент
-- не принимает (проверено в игре 10.11.2026). Отсюда имена nearbyspya /
-- nearbyspyh, а не nearbyspy_a / nearbyspy_h.
--
-- Обмен между фракциями не теряется: он идёт через сайт, куда обе фракции
-- грузят свои SavedVariables. Канал — это только «здесь и сейчас».
local PEER_CHANNEL_BASE = "nearbyspy"

-- Имена, под которыми аддон сидел раньше. Персонаж мог остаться их членом с
-- прошлых сессий, а пока membership есть, сервер отвечает
-- NOT_ALLOWED_IN_CHANNEL и печатает это в чат. Поэтому: выходим из них при
-- входе, а их сообщения по-прежнему прячем из чата (это тот же протокол).
local PEER_CHANNEL_LEGACY = { "nearbyspydata", "nearbyspydata_a", "nearbyspydata_h" }

-- Имя канала для текущего персонажа. Global on purpose — главный чанк стоит у
-- потолка Lua 5.1 в 200 top-level locals.
function PeerChannelName()
    local ok, faction = pcall(UnitFactionGroup, "player")
    if not ok or type(faction) ~= "string" then return PEER_CHANNEL_BASE end
    if faction == "Alliance" then return PEER_CHANNEL_BASE .. "a" end
    if faction == "Horde" then return PEER_CHANNEL_BASE .. "h" end
    -- фракция неизвестна (ранний вызов, нестандартный сервер) — общий канал
    return PEER_CHANNEL_BASE
end
-- Протокол отправки — N7: компактные поля (20.11.2026).
-- N6 кодировал одним символом класс/расу/фракцию и игру; N7 делает то же с
-- миром (код вместо 22 байт имени в КАЖДОМ сообщении) и временем (base36
-- вместо 10 цифр unix-тайма), а имя зоны отправляет один раз на зону за сессию.
-- Замер по живому SV (34 581 peer-запись): сообщение с одной записью 90 → 45
-- байт, записей в 240-байтовое сообщение 2.7 → 5.3 при том же интервале.
-- N5 — переходный режим для старых клиентов: поля текстом, мир текстом.
-- ⚠️ Отправки в формате N6 больше НЕТ: раскладка записи у N6 и N7 одна, и
-- «N6 с новыми полями» старый клиент прочитал бы как мир "a" вместо имени —
-- то есть испортил бы данные, а не просто не понял их. Выбор для старых
-- клиентов — N7 (поймут те, кто обновился) или N5 (поймут все): /nspy peer proto.
-- Приём у нас держит ВСЁ от N2 до N7, поэтому чужие записи слышны в любой
-- раскладке, включая N6 от клиентов прошлой версии.
local PEER_PROTO = "N7"

-- PEER_TTL: сколько секунд запись ждёт своей отправки, прежде чем сгореть.
-- Было 120, и этого не хватало (живой SV 15.11.2026: пять записей «expired
-- before send» в одну секунду — они встали в очередь в 23:08, а отправиться
-- смогли только в 23:10, потому что два батча по три записи при интервале 7 с
-- физически не успевают за две минуты). 600 с покрывают всплеск после /who-скана
-- и остаются конечными: зависшая запись всё равно не копится в очереди вечно.
local PEER_QUEUE_MAX, PEER_TTL = 60, 600
-- Очередь снапшотов экипировки: короче, чем у встреч, потому что пакет весит
-- втрое больше (133 против 47 байт) и разгружается только в простое канала.
local PEER_GEAR_QUEUE_MAX = 24
-- Интервал между сообщениями. Обычно 10 сек (не спамим канал зря), но при
-- большой очереди — 4 сек: /who-скан выдаёт десятки записей залпом, а при
-- 10 сек уходит лишь 24/мин, и очередь переполнялась (живой лог 10.11.2026:
-- 43 записи, «queue full»). 15 сообщений в минуту для канала — не флуд.
local PEER_GAP, PEER_GAP_BUSY, PEER_BUSY_LEN = 10, 7, 20
-- Интервал после троттлинга и время, через которое он «протухает».
-- Сервер на этом канале держит примерно 10 сообщений в минуту (живые метки:
-- медиана между отправками 6 секунд, троттлинг на 5 из 18 отправок). Поэтому
-- обычный интервал 7 секунд, а после отказа — 15: лучше отправить пачку позже,
-- чем получить отказ и потерять записи (в живом прогоне ушло 39 dropped).
local PEER_GAP_THROTTLED = 15
local PEER_THROTTLE_TTL = 90
-- Интервал между сообщениями. Обычно 10 сек (не спамим канал зря), при большой
-- очереди — 7 сек: 60 записей/мин сервер не держит, он троттлит.
-- Допустимое расхождение часов у отправителя пакета N4. Больше — отказ:
-- «пакет из будущего» иначе навсегда перебивал бы все обновления.
local PEER_CLOCK_SKEW = 3600
-- Сколько записей максимум в одной пачке N5. Ограничение по БАЙТАМ считает
-- сборщик пачки (PEER_PAYLOAD_MAX), это — защита от абсурда на приёме.
local PEER_BATCH_MAX = 5
-- Разделитель записей в пачке. НЕ '|': сервер отклоняет сообщение с ним как
-- «Invalid escape code in chat message» (проверено в игре 10.11.2026 — пачка с
-- '|' не уходила вовсе: sent=0, queue росла). Запятая не escape-символ и не
-- встречается ни в одном имени/зоне живого файла (16 138 записей).
local PEER_BATCH_SEP = ","
-- Разделитель ПОЛЕЙ внутри хвоста записи. Обязан отличаться от
-- PEER_BATCH_SEP: иначе имя зоны в хвосте склеивается с разделителем записей —
-- живой прогон дал «…;1000;Степи,Кэрол;e;25…», где «Степи» читалась как
-- отдельная запись. '~' не встречается в данных (проверено) и не escape-символ.
local PEER_TAIL_SEP = "~"
local peerQueue, peerQueued, peerSent = {}, {}, {}

-- PeerItemLabel(it) — как называть элемент очереди в логе.
-- В очереди лежат ДВА разных вида: записи о встречах (`rec`, есть `name`) и
-- управляющие пакеты вроде запроса Q1 (`raw`, имя «?»). Пока имя было одно,
-- потеря запроса писалась как «Peer queue full: dropped ?» — по такой строке
-- нельзя отличить управляющий пакет от рядовой записи, и в отчёте 26.11.2026
-- это дало ложное «отказов ноль» при askSent=0 и askOut=2.
function PeerItemLabel(it)
    if type(it) ~= "table" then return "?" end
    if type(it.raw) == "string" then return it.label or ("request " .. it.raw) end
    return it.name or "?"
end

-- PeerEvictIndex() — индекс самой старой РЯДОВОЙ записи в очереди; 0 = таких нет.
-- Управляющие пакеты (Q1) вытеснению НЕ подлежат: запрос стоит несравнимо
-- дороже одной встречи — он приводит десятки записей от пира, а встреча одна.
-- Записи добавляются в хвост, поэтому первая найденная рядовая — самая старая.
function PeerEvictIndex()
    for i = 1, #peerQueue do
        if type(peerQueue[i].raw) ~= "string" then return i end
    end
    return 0
end

-- Per-session peer counters/state. Kept in ONE table on purpose: the main chunk
-- of this file sits at the Lua 5.1 ceiling of 200 locals, so every new
-- top-level local breaks the whole addon at compile time.
local peerStats = {sent = 0, received = 0, merged = 0, dropped = 0, seen = 0, valid = 0, rejected = 0,
    foreign = 0, selfEcho = 0, inStart = 0, inCount = 0, lastSend = 0, rejectLogged = {}, lastNoChannel = 0,
    leftStale = nil, zoneSent = {}, gearQueue = {}, gearSent = {}}

-- PeerThrottled — сервер отказал принимать сообщения так часто
-- ("THROTTLED" в CHANNEL_MSG_CHANNEL_NOTICE). Реагируем на СИГНАЛ сервера, а не
-- на свой расчёт лимита: на живых метках интервал 4-6 секунд давал троттлинг на
-- 5 из 18 отправок и 39 потерянных записей. Теперь после отказа ждём дольше, а
-- через PEER_THROTTLE_TTL возвращаемся к обычному интервалу — поток мог
-- утихнуть.
function PeerThrottled()
    peerStats.throttled = (peerStats.throttled or 0) + 1
    peerStats.throttleUntil = time() + PEER_THROTTLE_TTL
    D(("Peer throttled by server, backing off to %ds (total %d)"):format(
        PEER_GAP_THROTTLED, peerStats.throttled))
end

local peerChatVisible = false -- session-only diagnostic; never persist raw traffic

-- Snapshot of peer counters into SavedVariables.
-- peerStats lives in memory only, so a plain logout used to wipe every trace
-- of channel activity: the SV showed source="peer" only for players that were
-- genuinely new, and nothing at all when a peer record merely refreshed an
-- existing row. db.debug.peer keeps the counters (no raw traffic, no names
-- beyond lastSender) and is written together with the rest of the SV.
PeerSync = function()
    local ok, db = pcall(GetDB)
    if not ok or type(db) ~= "table" then return end
    if type(db.debug) ~= "table" then return end
    -- GetChannelName returns TWO values (id, display name). Inside tonumber()
    -- that second return lands in tonumber's BASE argument and raises
    -- "bad argument #2 to 'tonumber' (number expected, got string)" — the
    -- whole call then aborts inside somebody else's pcall. Assign to a local
    -- first: an assignment keeps only the first value.
    local channelId = GetChannelName(PeerChannelName())
    -- Orphan-буфер живёт в NSP_INSPECT (свой файл), а кладём его числа в
    -- db.debug.peer: там вся peer-диагностика, и по SV видно эффект правки без
    -- входа в игру.
    local orphanStats = nil
    if NSP_INSPECT and type(NSP_INSPECT.OrphanStats) == "function" then
        local okO, s = pcall(NSP_INSPECT.OrphanStats)
        if okO and type(s) == "table" then orphanStats = s end
    end
    db.debug.peer = {
        enabled = db.peerEnabled and true or false,
        channel = tonumber(channelId) or 0,
        -- Имя своего канала (фракционное, с 10.11.2026): по SV видно, в каком
        -- именно канале сидел персонаж, не заходя в игру.
        channelName = PeerChannelName(),
        queued = #peerQueue,
        sent = peerStats.sent, received = peerStats.received,
        merged = peerStats.merged, dropped = peerStats.dropped,
        seen = peerStats.seen, valid = peerStats.valid,
        rejected = peerStats.rejected, foreign = peerStats.foreign,
        selfEcho = peerStats.selfEcho,
        -- Отказы сервера на частоте («THROTTLED»). Без этого поля счётчик жил
        -- только в памяти, и обещанная по нему диагностика в SV не появлялась:
        -- отличить «сервер отказывал» от «нечего было отправлять» было нельзя.
        throttled = peerStats.throttled or 0,
        throttleUntil = peerStats.throttleUntil,
        lastSender = peerStats.lastSender,
        chat = peerChatVisible and true or false,
        -- Снапшоты экипировки/билда (20.11.2026). Без этих полей вся
        -- диагностика gear жила только в памяти: в SV не было видно ни
        -- отправленных, ни принятых, ни причин отказа — ровно та же ошибка,
        -- что была с throttled. Длину очереди берём из peerStats, а не из
        -- локального peerQueue: очередь gear лежит там же.
        gearQueued = (type(peerStats.gearQueue) == "table") and #peerStats.gearQueue or 0,
        gearSent = peerStats.gearSentCount or 0,
        gearIn = peerStats.gearIn or 0,
        gearOrphan = peerStats.gearOrphan or 0,
        gearStale = peerStats.gearStale or 0,
        gearBad = peerStats.gearBad or 0,
        gearEmpty = peerStats.gearEmpty or 0,
        gearExpired = peerStats.gearExpired or 0,
        gearDropped = peerStats.gearDropped or 0,
        gearOff = db.peerGearOff and true or false,
        -- Записи, приехавшие ВНУТРИ пачек. Без этого поля «seen» (сообщения)
        -- и «valid» (записи) расходились без объяснения, а счётчик жил только
        -- в памяти — тот же дефект, что был у gear-полей и throttled.
        batchIn = peerStats.batchIn or 0,
        -- Диагностика приёма снапшотов (22.11.2026): причины тихих отказов и
        -- состав канала по протоколам. Без них «gearIn=0» не отличить от
        -- «G7 не приходит» — а это разные диагнозы с разными действиями.
        gearDrop = peerStats.gearDrop,
        gearSample = db.debug.gearSample,
        kinds = peerStats.kinds,
        gearNoRealm = peerStats.gearNoRealm or 0,
        gearRealmGuessed = peerStats.gearRealmGuessed or 0,
        gearOrphanFixed = peerStats.gearOrphanFixed or 0,
        gearAmbiguous = peerStats.gearAmbiguous or 0,
        -- Orphan-буфер (25.11.2026): снапшот, пришедший раньше записи о встрече,
        -- больше не теряется. Видно три числа: сколько отложено (buffered),
        -- сколько усыновлено (adopted), сколько ждёт прямо сейчас (held) и
        -- сколько протухло, не дождавшись строки (expired). Без них «gearIn
        -- растёт» не отличить от «снапшоты лежат в буфере и протухают».
        gearBuffered = peerStats.gearBuffered or 0,
        gearAdopted = (orphanStats and orphanStats.adopted) or 0,
        gearOrphanHeld = (orphanStats and orphanStats.held) or 0,
        gearOrphanExpired = (orphanStats and orphanStats.expired) or 0,
        -- Запрос базы у пиров (Q1, 24.11.2026). Без этих полей вся диагностика
        -- запроса жила бы только в памяти до логаута — ровно та же ошибка, что
        -- была с throttled и gear-счётчиками: в кольце строка есть, в файле
        -- ничего.
        askSent = peerStats.askSent or 0,
        askReqIn = peerStats.askReqIn or 0,
        askIgnored = peerStats.askIgnored or 0,
        askQueued = peerStats.askQueued or 0,
        askGearQueued = peerStats.askGearQueued or 0,
        askSkipped = peerStats.askSkipped or 0,
        askEmpty = peerStats.askEmpty or 0,
        askIn = peerStats.askIn or 0,
        -- Ответы ЧУЖИМ nonce (и пакеты A1 без своего запроса). Отдельный
        -- счётчик, потому что это и есть работа нового тега: посторонний
        -- клиент такие пакеты выбрасывает, и в SV должно быть видно, что они
        -- приходили, а не «в канале тишина».
        askStray = peerStats.askStray or 0,
        -- Запрос, истёкший в очереди неотправленным (26.11.2026). Отдельно от
        -- dropped: потеря управляющего пакета лишает десятков записей, и её
        -- нельзя смешивать с потерей одной встречи.
        askExpired = peerStats.askExpired or 0,
        -- Транспорт (26.11.2026): сколько отправлено аддон-сообщением и сколько
        -- старым каналом, сколько принято по префиксу, сколько отправлено
        -- таймером. Без них «sent растёт» не отличает новый путь от старого, а
        -- «тишина в приёме» — «префикс не сработал» от «никто не слал».
        viaAddon = peerStats.viaAddon or 0,
        viaChannel = peerStats.viaChannel or 0,
        addonIn = peerStats.addonIn or 0,
        timerSent = peerStats.timerSent or 0,
        timerFail = peerStats.timerFail or 0,
        -- Работает ли таймер ВООБЩЕ (26.11.2026): в живом SV timerSent был 0 при
        -- живых отправках, и вопрос «таймер молчит или просто ничего не смог
        -- отправить» не имел ответа. timerTicks отвечает прямо: тики идут —
        -- таймер жив; тиков 0 — не запустился.
        timerTicks = peerStats.timerTicks or 0,
        timerOn = peerStats.timerOn and 1 or 0,
        -- Адресные запросы (24.11.2026): сколько запросов отправлено и сколько
        -- сейчас открыто. При обходе пиров по очереди это главные числа —
        -- по ним видно, чей ответ ещё не пришёл.
        askOut = peerStats.askOut or 0,
        askNotMe = peerStats.askNotMe or 0,
        askWrongSender = peerStats.askWrongSender or 0,
        askLastFrom = peerStats.askLastFrom,
        askPending = (type(peerStats.askPending) == "table") and true or false,
    }
end

-- NspCut — обрезать строку до n БАЙТ, не разрывая символ UTF-8.
--
-- `string.sub` считает БАЙТЫ, поэтому кириллица, CJK и умляуты режутся
-- пополам, и в SavedVariables остаётся байт-огрызок. Живой файл 25.11.2026
-- содержал 6 таких мест (кольцо печати, тултипы предметов) — файл перестаёт
-- быть валидным UTF-8: Python-парсер выгрузки читает errors="replace" и терпит,
-- а Go на сайте подставил бы U+FFFD, то есть испортил бы текст молча.
--
-- Идём от конца отрезанной части: на ASCII-байте граница целая; на
-- continuation-байте (0x80..0xBF) отступаем назад; на lead-байте (0xC0..0xF4)
-- последовательность началась и не закончилась — отбрасываем её целиком.
-- Глобальная функция: главный чанк на 197 локалах из 200 в Lua 5.1.
function NspCut(s, n)
    if type(s) ~= "string" or type(n) ~= "number" or n < 1 then return s end
    if #s <= n then return s end
    local cut = s:sub(1, n)
    local i = #cut
    -- Шаг назад по continuation-байтам: 0x80..0xBF продолжают символ, начатый
    -- левее. Останавливаемся на lead-байте (>= 0xC0) или на ASCII.
    local lead = i
    while lead > 0 and cut:byte(lead) >= 0x80 and cut:byte(lead) < 0xC0 do
        lead = lead - 1
    end
    if lead == 0 then return "" end                   -- в куске нет целого символа
    local b = cut:byte(lead)
    if b < 0x80 then return cut end                   -- граница пришлась на ASCII
    local need
    if b >= 0xF0 then need = 4
    elseif b >= 0xE0 then need = 3
    elseif b >= 0xC0 then need = 2
    else return cut:sub(1, lead - 1) end              -- 0x80..0xBF началом быть не может
    -- Символ целый только если от lead до конца куска ровно need байт.
    -- Иначе (обрезали на середине) — отбрасываем начатую последовательность.
    if i - lead + 1 == need then return cut end
    return cut:sub(1, lead - 1)
end

-- Untrusted chat text: strip control chars and pipe escapes before it reaches
-- chat or the SV ring (a peer name must not be able to inject markup).
-- Global on purpose — a local function would cost a slot in the main chunk.
function PeerEsc(s, maxLen)
    if type(s) ~= "string" then return tostring(s) end
    -- A secret string passes the type check but throws on the first string
    -- operation (gsub/#/sub), so the gate has to sit right here (16.11.2026).
    if canaccessvalue and not canaccessvalue(s) then return "[secret]" end
    s = s:gsub("[%c|]", "?")
    maxLen = maxLen or 60
    if #s > maxLen then s = NspCut(s, maxLen) .. "..." end
    return s
end
local function PeerField(s, maxLen)
    -- Запрещены оба разделителя: запятая разделяет ЗАПИСИ в пачке, тильда —
    -- ПОЛЯ внутри хвоста записи. Пропустив любой из них, получим неразбираемое
    -- сообщение. '|' запрещён по той же причине и вдобавок отклоняется сервером
    -- как escape-код («Invalid escape code in chat message»).
    return type(s) == "string" and #s > 0 and #s <= maxLen
        and not s:find("[%c|;,~]")
end

-- ── Коды для класса, расы и фракции (протокол N6) ──────────────────────────
-- Эти три поля — конечные множества, и в текстовом виде они самые дорогие после
-- имени: "PALADIN;Human;Alliance" = 23 байта, кодами — 5. Экономия 19 байт на
-- запись поднимает ёмкость сообщения с 2 записей до 3 при длинной зоне.
--
-- Код — ОДИН символ латиницы. 'z' = «значение не из таблицы»: тогда настоящее
-- значение едет текстом в дополнительном поле записи (см. N6). Это нужно,
-- потому что сервер кастомный: раса Skyborne уже есть (и встречается у ОБЕИХ
-- фракций — 1506 у Альянса, 26 у Орды, поэтому фракцию нельзя выводить из расы),
-- а следующая кастомная раса не должна потеряться.
--
-- Таблицы глобальные: главный чанк стоит у потолка Lua 5.1 в 200 локалах.
NSP_PEER_CODES = {
    class = {
        a = "WARRIOR", b = "PALADIN", c = "HUNTER", d = "ROGUE", e = "PRIEST",
        f = "SHAMAN", g = "MAGE", h = "WARLOCK", i = "DRUID",
    },
    race = {
        a = "Human", b = "Dwarf", c = "NightElf", d = "Gnome",
        e = "Orc", f = "Scourge", g = "Tauren", h = "Troll", i = "Skyborne",
    },
    faction = { a = "Alliance", h = "Horde" },
    -- Игра тоже конечное множество (сейчас три значения в коде: forever,
    -- retail, classic_era). В заголовке она стоит один раз на сообщение, но
    -- для одиночного пакета это 6 байт из ~89 — заметно.
    game = { f = "forever", r = "retail", c = "classic_era" },
}
local PEER_CODE_UNKNOWN = "z"
-- Отдельный код «значения нет» (15.11.2026). Раньше отсутствие значения кодировалось
-- тем же 'z', что и «значение есть, но не из таблицы, текст в хвосте» — и приёмник
-- для любого 'z' лез в хвост за текстом. Наш отправитель при расе "?" клал 'z' и
-- текст НЕ клал, поэтому слот расы съедал следующий текст хвоста (имя зоны), и в
-- базе оказалось 384 записи с зоной в поле расы ("Duskwood", "Wetlands", …).
-- 'q' свободен: коды рас — a..i, классы — a..i, фракции — a/h, игра — f/r/c.
-- Новый код безопасен и для старых приёмников: PeerDecode вернёт nil (неизвестный
-- код) → "?", а takeText для 'q' не сдвигает индекс (он сдвигается только для 'z').
local PEER_CODE_NONE = "q"

-- Обратные карты строятся один раз при загрузке.
-- Строятся ПО ТАБЛИЦЕ КОДОВ, а не перечислением: новая категория (как game)
-- иначе роняла бы загрузку аддона на индексации nil.
NSP_PEER_DECODE = {}
for kind in pairs(NSP_PEER_CODES) do
    NSP_PEER_DECODE[kind] = {}
end
for kind, map in pairs(NSP_PEER_CODES) do
    for code, name in pairs(map) do
        NSP_PEER_DECODE[kind][name] = code
    end
end

-- PeerEncode(kind, value) -> code, needsText
-- needsText=true означает: значение не в таблице, его надо отправить текстом.
-- Отсутствие значения — отдельный код 'q' БЕЗ текста: иначе приёмник сдвигает
-- разбор хвоста и забирает чужой текст (см. PEER_CODE_NONE).
function PeerEncode(kind, value)
    if type(value) ~= "string" or value == "" then return PEER_CODE_NONE, false end
    local code = NSP_PEER_DECODE[kind][value]
    if code then return code, false end
    return PEER_CODE_UNKNOWN, true
end

-- PeerDecode(kind, code, text) -> значение. text используется, когда код 'z'.
function PeerDecode(kind, code, text)
    if code == PEER_CODE_UNKNOWN then
        return (type(text) == "string" and text ~= "") and text or nil
    end
    return NSP_PEER_CODES[kind][code or ""]
end

-- ── Компактные поля N7: мир и время (20.11.2026) ───────────────────────────
-- Мир стоит 22 байта в КАЖДОМ сообщении ("CAMWOW EU4 Realm 6 PvP"), а миров в
-- кластере полтора десятка (живой SV 20.11.2026: 14 разных на 34 581 запись).
-- Код — base36-индекс в таблице: 1 байт вместо 22.
-- ⚠️ Таблица ТОЛЬКО ДОПОЛНЯЕТСЯ В КОНЕЦ: индекс уезжает по сети, и перестановка
-- строк переименовала бы мир у всех получателей. Новый мир = новая строка
-- последней; менять порядок = менять протокол.
-- Мир вне таблицы уходит ТЕКСТОМ — приём отличает код от имени по длине и
-- алфавиту (код: 1-2 символа из [0-9a-z]).
NSP_REALM_CODES = {
    "CAMWOW EU4 Realm 6 PvP", "CAMWOW EU5 Realm 2 PvP", "CAMWOW EU4 Realm 8 PvP",
    "CAMWOW EU5 Realm 6 PvP", "CAMWOW EU5 Realm 4 PvP", "CAMWOW EU5 Realm 8 PvP",
    "CAMWOW EU4 Realm 2 PvP", "CAMWOW EU4 Realm 4 PvP", "CAMWOW EU5 Realm 5 PvE",
    "CAMWOW EU5 Realm 7 PvE", "CAMWOW EU5 Realm 1 PvE", "CAMWOW EU4 Realm 5 PvE",
    "CAMWOW EU5 Realm 9 RP PvP", "CAMWOW EU4 Realm 9 RP PvP",
}

-- Base36. tonumber(s, 36) в Lua 5.1 есть, обратной функции нет.
function PeerB36(n)
    n = tonumber(n) or 0
    if n <= 0 then return "0" end
    local digits, s = "0123456789abcdefghijklmnopqrstuvwxyz", ""
    while n > 0 do
        local d = n % 36
        s = digits:sub(d + 1, d + 1) .. s
        n = math.floor(n / 36)
    end
    return s
end

-- PeerRealmCode(realm) -> код или nil, если мира нет в таблице.
function PeerRealmCode(realm)
    if type(realm) ~= "string" or realm == "" then return nil end
    for i = 1, #NSP_REALM_CODES do
        if NSP_REALM_CODES[i] == realm then return PeerB36(i - 1) end
    end
    return nil
end

-- PeerRealmName(token) -> имя мира. Код распознаётся по длине и алфавиту, всё
-- остальное возвращается как есть: так понимаются и старые отправители
-- (полное имя), и новые миры, которых нет в таблице.
function PeerRealmName(token)
    if type(token) ~= "string" or token == "" then return nil end
    if #token > 2 or not token:match("^[0-9a-z]+$") then return token end
    local idx = tonumber(token, 36)
    if not idx then return token end
    return NSP_REALM_CODES[idx + 1] or token
end

-- Время наблюдения: 10 байт unix-тайма — второе по стоимости поле записи.
-- В base36 это 6 байт (в 2085 году — 7, признак формата всё равно по длине).
-- Секунды СОХРАНЕНЫ намеренно: минутная точность склеила бы «наблюдение» и
-- «отправку» внутри одной минуты (запись ждёт в очереди до PEER_TTL = 600 с),
-- и смысл поля — когда игрока ВИДЕЛИ — пропал бы ради одного байта.
-- Приём различает форматы по длине: 8+ цифр = старый unix-тайм, иначе base36.
function PeerTimeCode(ts)
    local n = tonumber(ts)
    if not n or n <= 0 then return "0" end
    return PeerB36(math.floor(n))
end

function PeerTimeValue(s)
    if type(s) ~= "string" or s == "" then return nil end
    if #s >= 8 and s:match("^%d+$") then return tonumber(s) end
    return tonumber(s, 36)
end

-- ── Экипировка в пакете: base64 над битовым потоком (20.11.2026) ───────────
-- Здесь base64 наконец оправдан, и только здесь. Строка «1:20521,2:276740,…»
-- тратит байты на десятичные цифры и на НОМЕР СЛОТА у каждого предмета: замер
-- по 849 живым снапшотам — 115 символов в среднем. В битовом потоке слот не
-- нужен вовсе (его задаёт карта занятости), а номер предмета — 20 бит:
-- 19 бит карты слотов + 8 бит ilvl + 20 бит на предмет = 51 символ (×2.2).
--
-- Таланты, наоборот, перекодировать НЕЛЬЗЯ: import-строка уже собрана из
-- base64-алфавита (6 бит на символ), то есть плотнее её сделать нечем —
-- любая упаковка вернёт те же биты. Она едет текстом как есть.
--
-- Пределы (проверены на живых данных): слотов 1..19, itemID до 287073 (20 бит
-- покрывают 1 048 575 — запас на будущие предметы), ilvl до 60 (8 бит = 255).
local PEER_B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
NSP_B64_INDEX = {}
for i = 1, #PEER_B64 do NSP_B64_INDEX[PEER_B64:sub(i, i)] = i - 1 end

-- Битовый писатель. В Lua 5.1 нет побитовых операций, поэтому сдвиг — это
-- умножение и деление на степень двойки; double точен до 2^53, а аккумулятор
-- здесь не превышает 26 бит (6 + максимум 20).
function PeerBitsNew() return {acc = 0, n = 0, out = {}} end

function PeerBitsPut(w, v, width)
    w.acc = w.acc * (2 ^ width) + (tonumber(v) or 0)
    w.n = w.n + width
    while w.n >= 6 do
        w.n = w.n - 6
        local shift = 2 ^ w.n
        local d = math.floor(w.acc / shift)
        w.out[#w.out + 1] = PEER_B64:sub(d + 1, d + 1)
        w.acc = w.acc - d * shift
    end
end

function PeerBitsFlush(w)
    if w.n > 0 then PeerBitsPut(w, 0, 6 - w.n) end
    return table.concat(w.out)
end

function PeerBitsReader(s)
    return {s = s, pos = 0, acc = 0, n = 0}
end

function PeerBitsGet(r, width)
    while r.n < width do
        r.pos = r.pos + 1
        local ch = r.s:sub(r.pos, r.pos)
        local idx = NSP_B64_INDEX[ch]
        -- Символ вне алфавита = испорченный пакет: вернуть nil, а не мусор.
        -- У пакованного формата нет ресинхронизации по разделителю, поэтому
        -- единственная защита — отбросить запись целиком.
        if not idx then return nil end
        r.acc = r.acc * 64 + idx
        r.n = r.n + 6
    end
    local shift = 2 ^ (r.n - width)
    local v = math.floor(r.acc / shift)
    r.acc = r.acc - v * shift
    r.n = r.n - width
    return v
end

-- ── Упаковка экипировки ────────────────────────────────────────────────────
-- Вход — строка снапшота из NearbySpy_Inspect.lua: "slot:id,slot:id,…".
-- Слоты упорядочены по возрастанию, иначе карта занятости не совпадёт с
-- порядком id в потоке (получатель читает id именно в порядке слотов).
function PeerGearPack(ids, ilvl)
    if type(ids) ~= "string" or ids == "" then return nil end
    local slots = {}
    for part in (ids .. ","):gmatch("(.-),") do
        if part ~= "" then
            local s, id = part:match("^(%d+):(%d+)$")
            s, id = tonumber(s), tonumber(id)
            -- Мусор в снапшоте не должен ломать пакет: пропускаем элемент,
            -- а не отправляем битый поток (у него нет ресинхронизации).
            if s and id and s >= 1 and s <= 19 and id > 0 and id < 1048576 then
                slots[#slots + 1] = {s = s, id = id}
            end
        end
    end
    if #slots == 0 then return nil end
    table.sort(slots, function(a, b) return a.s < b.s end)
    local map = 0
    for _, p in ipairs(slots) do map = map + 2 ^ (p.s - 1) end
    local w = PeerBitsNew()
    PeerBitsPut(w, map, 19)
    local lvl = tonumber(ilvl) or 0
    if lvl < 0 then lvl = 0 end
    if lvl > 255 then lvl = 255 end
    PeerBitsPut(w, lvl, 8)
    for _, p in ipairs(slots) do PeerBitsPut(w, p.id, 20) end
    return PeerBitsFlush(w)
end

-- Обратное: строка "slot:id,…", ilvl, число слотов. nil при любом мусоре —
-- вызывающий обязан отбросить запись целиком, половинчатый разбор запрещён.
function PeerGearUnpack(b64)
    if type(b64) ~= "string" or b64 == "" or #b64 > 200 then return nil end
    local r = PeerBitsReader(b64)
    local map = PeerBitsGet(r, 19)
    local ilvl = PeerBitsGet(r, 8)
    if not map or not ilvl or map == 0 then return nil end
    local parts = {}
    for slot = 1, 19 do
        if math.floor(map / 2 ^ (slot - 1)) % 2 == 1 then
            local id = PeerBitsGet(r, 20)
            if not id or id <= 0 then return nil end
            parts[#parts + 1] = slot .. ":" .. id
        end
    end
    if #parts == 0 then return nil end
    return table.concat(parts, ","), ilvl, #parts
end




-- Peers now carry the place as well (protocol N3, fields 9-12). A chat message
-- is capped by the client at 255 bytes, so the payload is built with a budget and
-- loses its optional parts in a fixed order instead of being dropped whole:
-- zone name first (zoneId and coordinates survive), then the coordinates.
-- #s in Lua counts BYTES, which is exactly what the client limit measures —
-- a Cyrillic zone name costs two bytes per character.
local PEER_PAYLOAD_MAX = 240
function PeerCoord(v)
    local n = v and tonumber(v)
    if not n then return "-" end
    return ("%.4f"):format(n)
end

QueuePeerNew = function(db, data)
    if not db.peerEnabled or not PeerField(data.name, 60)
        or not PeerField(data.realm, 100) or not PeerField(db.game, 16)
        or not PeerField(data.class, 32) then return end
    local level = tonumber(data.level)
    if not level or level < 1 or level > 80 or level % 1 ~= 0 then return end
    if not data.class:match("^[A-Z]+$") then return end
    -- Раса: ASCII-гейта больше нет (15.11.2026). Он отбрасывал не только мусор,
    -- но и настоящие значения — локализованное «Night Elf» (пробел) и кастомные
    -- расы кириллицей, а такие записи в канал просто не уходили. Достаточно
    -- PeerField (длина и отсутствие разделителей): не из таблицы — уйдёт текстом
    -- в хвосте, приём нормализует известные значения обратно в файл-ключ.
    local race = PeerField(data.race, 32) and data.race or "?"
    local faction = (data.faction == "Alliance" or data.faction == "Horde") and data.faction or "?"
    local base = db.game .. "|" .. data.key
    local zoneName = PeerField(data.zone, 60) and data.zone or "?"
    local zoneId = (data.zoneId and tonumber(data.zoneId)) or 0
    if zoneId < 0 or zoneId % 1 ~= 0 then zoneId = 0 end

    -- Ключ дедупа. Для НОВОЙ записи — один на игрока за сессию: повторные
    -- встречи того же человека в канал не идут.
    --
    -- Для ОБНОВЛЕНИЯ (isUpdate: /who увидел знакомого с другим уровнем или в
    -- другой зоне) ключ включает сами значения: без этого запись блокировалась
    -- бы первой же отправкой создания и новые уровни не уходили никогда.
    -- Одинаковое обновление дважды не уйдёт, а следующее изменение — уйдёт.
    local key = base
    if data.isUpdate then
        -- Обновления — низкий приоритет: если очередь уже наполовину полна,
        -- создание новых записей важнее. Иначе /who-скан на 50 человек вытеснит
        -- из очереди всё остальное (PEER_QUEUE_MAX = 60).
        if #peerQueue >= PEER_QUEUE_MAX / 2 then
            peerStats.updateSkipped = (peerStats.updateSkipped or 0) + 1
            return
        end
        key = base .. "|u" .. tostring(level) .. "|" .. tostring(zoneId)
    end
    -- Ответ на запрос пира (Q1, 24.11.2026). Ключ дедупа привязан к nonce
    -- запроса: без этого правило «одна запись на игрока за сессию» не выпустило
    -- бы запись, которую у нас как раз и просили, и повторный запрос не получил
    -- бы ничего. Одинаковый nonce дважды не уйдёт (это тот же ключ).
    if data.answerNonce then
        key = base .. "|a" .. tostring(data.answerNonce)
    end
    if peerSent[key] or peerQueued[key] then return end
    -- Coordinates are shared ONLY when they belong to the reported player.
    -- A /who entry knows the player's ZONE but has no position, so its x/y is
    -- where WE stood — sending that put a stranger on our own map spot (10 428
    -- such rows in the live database, the vast majority of it). Same for any
    -- record whose position fell back to the observer.
    local px, py = "-", "-"
    if data.coordsFromUnit then
        px, py = PeerCoord(data.x), PeerCoord(data.y)
    end

    -- Запись N6: имя;класс;уровень;раса;фракция;зонаId;x;y;время[;текст]
    -- Класс/раса/фракция — ОДИН символ. Текста зоны НЕТ: в N6 обратная
    -- совместимость не нужна, а id (4 байта) против имени (~26 байт) плюс
    -- резолв на языке получателя — это и экономия, и корректная локализация.
    -- Если id неизвестен, шлём 0 и имя в хвостовом поле «z»-механизма: терять
    -- зону молча нельзя.
    local clsCode, clsText = PeerEncode("class", data.class)
    local raceCode, raceText = PeerEncode("race", race ~= "?" and race or nil)
    local facCode, facText = PeerEncode("faction", faction ~= "?" and faction or nil)
    -- Коды отправляются через один символ, значения в тексте (когда 'z') — через
    -- запятую: именно сюда попадают кастомные значения, и запятая в них была бы
    -- неотличима от разделителя. Поэтому такие значения отправляются по одному:
    -- если в тексте есть запятая, вместо неё ставится '?', а в debug пишется
    -- след — молча потерять кастомную расу хуже, чем испортить один символ.
    local function cleanText(v)
        local s = tostring(v or "")
        if s:find(PEER_TAIL_SEP, 1, true) or s:find(PEER_BATCH_SEP, 1, true) then
            local dbg = (type(GetDB()) == "table") and GetDB() or nil
            if dbg then
                dbg.debug = dbg.debug or {}
                dbg.debug.peerCommaStripped = (dbg.debug.peerCommaStripped or 0) + 1
            end
            s = s:gsub(PEER_TAIL_SEP, "?"):gsub(PEER_BATCH_SEP, "?")
        end
        return s
    end
    local extra = {}
    if clsText then extra[#extra + 1] = cleanText(data.class) end
    if raceText then extra[#extra + 1] = cleanText(race ~= "?" and race or "") end
    if facText then extra[#extra + 1] = cleanText(faction ~= "?" and faction or "") end
    -- ── Имя зоны: РАСШИРЕНИЕ в хвосте, не поле записи ─────────────────────
    -- Основной ключ зоны — zoneId. Имя едет ДОПОЛНИТЕЛЬНО, последним в хвосте,
    -- и только если оно известно. Причины:
    --  1) нумерация uiMapID в клиенте Forever не совпадает с внешними дампами
    --     (проверено 10.11.2026: клиентский 1420 = Тирисфаль, в wago он
    --     18/997/1247/2070, сдвиг плавает 1369..1405) — id может не
    --     резолвиться у получателя;
    --  2) поэтому имя — запасной вариант, а не второй равноправный ключ.
    -- Приём отличает зону от 'z'-значений по количеству: он знает, сколько
    -- слотов помечено 'z', всё сверх этого — имя зоны.
    -- Имя зоны — один раз на зону за сессию, а не в каждой записи (20.11.2026).
    -- Кириллическая зона — 19.5 байта в UTF-8 (замер по 34 581 живой записи):
    -- четверть сообщения, при том что zoneId уже едет и резолвится у получателя
    -- ЕГО клиентом. Имя остаётся страховкой для тех, чей клиент id не знает:
    -- объявляем его первой записью зоны в сессии, и всегда — когда id нет вовсе.
    -- Счётчик живёт в peerStats, а не отдельным local: главный чанк стоит у
    -- потолка Lua 5.1 в 200 локалов. Инициализация ленивая: peerStats — общая
    -- сессионная таблица, её может пересоздать любой сброс состояния.
    local zoneSent = peerStats.zoneSent
    if type(zoneSent) ~= "table" then zoneSent = {}; peerStats.zoneSent = zoneSent end
    local zoneInTail = (zoneName ~= "" and zoneName ~= "?" and PeerField(zoneName, 60))
        and (zoneId == 0 or not zoneSent[zoneId])
    if zoneInTail then
        extra[#extra + 1] = cleanText(zoneName)
        if zoneId > 0 then zoneSent[zoneId] = true end
    end

    -- Запись N6: имя;класс;уровень;раса;фракция;zoneId;x;y;время[;хвост]
    -- Хвост = текстовые значения для 'z'-слотов + имя зоны последним.
    local function BuildRec(cx, cy, withZone)
        local rec = table.concat({data.name,
            clsCode, tostring(level), raceCode, facCode,
            tostring(zoneId), cx, cy, PeerTimeCode(data.observedAt or time())}, ";")
        local tail = extra
        if not withZone and zoneInTail and #extra > 0 then
            -- отбрасываем именно зону (последний элемент), прочие 'z' остаются
            tail = {}
            for i = 1, #extra - 1 do tail[i] = extra[i] end
        end
        if #tail > 0 then rec = rec .. ";" .. table.concat(tail, PEER_TAIL_SEP) end
        return rec
    end
    -- Размер проверяется по ОДИНОЧНОМУ пакету: запись, которая не влезает одна,
    -- не влезет и в пачке. Деградация в фиксированном порядке: сначала зона из
    -- хвоста (это расширение), затем координаты.
    local function PayloadOf(r)
        return table.concat({"N6", db.game, data.realm, r}, ";")
    end
    local rec = BuildRec(px, py, true)
    if #PayloadOf(rec) > PEER_PAYLOAD_MAX then rec = BuildRec(px, py, false) end
    if #PayloadOf(rec) > PEER_PAYLOAD_MAX then rec = BuildRec("-", "-", false) end
    if #PayloadOf(rec) > PEER_PAYLOAD_MAX then return end
    if #peerQueue >= PEER_QUEUE_MAX then
        -- Снимаем САМУЮ СТАРУЮ ЗАПИСЬ, а не голову очереди: в голове стоит
        -- управляющий пакет Q1 (у него есть raw), и прежнее «удалить первый»
        -- убивало запрос. Живой случай 26.11.2026: два запроса из двух
        -- выброшены так — за 3 минуты и за 1 секунду, askSent=0 при askOut=2.
        local victim = PeerEvictIndex()
        if victim == 0 then
            -- Вся очередь из управляющих пакетов: место новому не даём, но и
            -- запрос не трогаем — он приводит десятки записей, а эта одна.
            peerStats.dropped = peerStats.dropped + 1
            D(("Peer record not queued: the queue holds only requests, q=%d")
                :format(#peerQueue))
            return
        end
        local old = table.remove(peerQueue, victim)
        peerQueued[old.key] = nil
        peerStats.dropped = peerStats.dropped + 1
        D(("Peer queue full: dropped %s"):format(PeerEsc(PeerItemLabel(old), 40)))
    end
    peerQueue[#peerQueue + 1] = {
        key = key, rec = rec, name = data.name, at = time(),
        game = db.game, realm = data.realm,
        -- Ответ на запрос (Q1) уходит под своим тегом A1: «nonce» здесь —
        -- единственное, что отличает адресный ответ от обычного вещания.
        ans = data.answerNonce,
        -- Текстовая запись N4 для переходного режима PEER_PROTO == "N5":
        -- собирается здесь, а не при отправке, чтобы не тащить в очередь
        -- исходные поля ради редкого случая.
        legacyRec = table.concat({data.name, data.class, tostring(level), race, faction,
            tostring(zoneId), zoneName, px, py,
            tostring(tonumber(data.observedAt) or time())}, ";"),
    }
    peerQueued[key] = true
    -- Only the first detailed encounter is queued: this line is the proof that
    -- the record passed every gate and is waiting for a mouse click to go out.
    D(("Peer queued: %s (%s %d, %s) q=%d"):format(
        PeerEsc(data.name), PeerEsc(data.class, 20), level,
        PeerEsc(db.game, 16), #peerQueue))
    PeerSync()
end

-- ── Экипировка и билд в канал (20.11.2026) ─────────────────────────────────
-- Отдельная очередь и отдельный тип пакета G7: у записи о встрече и у снапшота
-- разная цена (133 байта против 47) и разная частота, поэтому общая очередь
-- означала бы либо голод встреч, либо переполнение канала вещами.
--
-- Что НЕ отправляется никогда:
--   • чужой снапшот, полученный по каналу (иначе релей, как и у встреч);
--   • снапшот, который мы уже отправили в этой сессии (дедуп по ключу + at).
function PeerQueueGear(key, snapshot, opts)
    local db = GetDB()
    if not db.peerEnabled or db.peerGearOff then return end
    if type(key) ~= "string" or key == "" or type(snapshot) ~= "table" then return end
    if type(snapshot.ids) ~= "string" or snapshot.ids == "" then return end
    local entry = db.players and db.players[key]
    if type(entry) ~= "table" then return end
    -- Снапшот, полученный от пира, помечен gearFrom и обратно не уходит.
    if snapshot.from then return end
    local at = tonumber(snapshot.at) or 0
    local q = peerStats.gearQueue
    if type(q) ~= "table" then q = {}; peerStats.gearQueue = q end
    local sent = peerStats.gearSent
    if type(sent) ~= "table" then sent = {}; peerStats.gearSent = sent end
    -- Ответ на запрос пира (Q1) переотправляет снапшот, который в этой сессии
    -- уже уходил пассивно: для него флаг «уже отправлено» не действует, иначе
    -- на запрос пришли бы встречи без вещей. Дедуп В ОЧЕРЕДИ остаётся — два
    -- одинаковых снапшота одновременно не стоят.
    local force = (type(opts) == "table" and opts.force) or nil
    if not force and sent[key] == at then return end
    for i = 1, #q do
        if q[i].key == key and q[i].snapAt == at then return end
    end
    -- Очередь вещей короткая: она разгружается медленнее встреч, и копить
    -- сотни снапшотов бессмысленно — они устареют раньше, чем дойдут.
    while #q >= PEER_GEAR_QUEUE_MAX do
        local old = table.remove(q, 1)
        peerStats.gearDropped = (peerStats.gearDropped or 0) + 1
        if old then D(("Peer gear queue full: dropped %s"):format(PeerEsc(old.name or "?", 40))) end
    end
    q[#q + 1] = {
        key = key, name = entry.name or "?",
        -- ⚠️ Пустая строка в Lua ИСТИННА, поэтому `entry.realm or PlayerRealm()`
        -- оставлял пустой мир: пакет уходил как "G7;f;;Имя;…", и каждый
        -- получатель отбивал его на проверке имени/мира (живой SV 22.11.2026:
        -- gearDrop={"bad name/realm"=9} при kinds={"G7"=9} — все пакеты в
        -- канале битые, gearIn=0 у всех). Записи без мира существуют: unit-детект
        -- и часть chat-записей пишут realm="" (640 снапшотов в живом SV), и
        -- именно они порождали нечитаемые пакеты.
        realm = (type(entry.realm) == "string" and entry.realm ~= "") and entry.realm
            or PlayerRealm(),
        game = db.game, at = time(), snapAt = at,
        ids = snapshot.ids, ilvl = tonumber(snapshot.ilvl) or 0,
        imp = type(snapshot.imp) == "string" and snapshot.imp or nil,
        gearFromPeer = snapshot.from and true or nil,
        -- Снапшот-ответ не имеет права обогнать свою запись о встрече: у
        -- получателя без строки он уйдёт в orphan (живой SV 22.11.2026: 68
        -- пакетов, 68 orphan). Пока ключ встречи стоит в очереди, снапшот ждёт.
        afterKey = (type(opts) == "table" and opts.afterKey) or nil,
        -- Ответ на запрос: снапшот тоже уходит под A1, иначе его запишут все
        -- клиенты канала, а не только тот, кто просил.
        ans = (type(opts) == "table" and opts.answerNonce) or nil,
    }
    D(("Peer gear queued: %s (%s, %d slots) q=%d"):format(
        PeerEsc(entry.name, 40), PeerEsc(db.game, 12), (snapshot.slots or tonumber(
            (snapshot.ids:gsub("[^,]", "")):len()) or 0) + 1, #q))
    PeerSync()
end

function PeerGearPayload(db, it)
    local gearB64 = PeerGearPack(it.ids, it.ilvl)
    local imp = it.imp
    if type(imp) ~= "string" or imp == "" then imp = nil end
    -- Таланты: только символы алфавита import-строки. Чужой текст в этом поле
    -- не должен ни удлинять пакет, ни ломать разбор у получателя.
    if imp and not imp:match("^[%w+/]+$") then imp = nil end
    if imp and #imp > 64 then imp = nil end
    if not gearB64 and not imp then return nil end

    local game = PeerEncode("game", it.game)
    if game == PEER_CODE_UNKNOWN or game == PEER_CODE_NONE then game = it.game end
    local realm = PeerRealmCode(it.realm) or it.realm
    -- Страховка: пустой мир получатель отбивает (PeerField требует длины > 0),
    -- поэтому битый пакет не отправляем вовсе — иначе канал молча спамится
    -- нечитаемыми сообщениями, а отправитель видит «gearSent растёт».
    if type(realm) ~= "string" or realm == "" then realm = PlayerRealm() end
    if type(realm) ~= "string" or realm == "" then
        peerStats.gearNoRealm = (peerStats.gearNoRealm or 0) + 1
        D(("Peer gear skipped: no realm for %s"):format(PeerEsc(it.name or "?", 40)))
        PeerSync()
        return nil
    end
    local stamp = PeerTimeCode(it.snapAt > 0 and it.snapAt or it.at)

    local function Build(withGear, withTalents)
        local flags = (withGear and "g" or "") .. (withTalents and "t" or "")
        local parts = {"G7", game, realm, it.name, stamp, flags}
        if withGear then parts[#parts + 1] = gearB64 end
        if withTalents then parts[#parts + 1] = imp end
        return table.concat(parts, ";")
    end
    local payload = Build(gearB64 ~= nil, imp ~= nil)
    -- Деградация в фиксированном порядке: сначала таланты (их можно прислать
    -- отдельным пакетом позже), потом уже вся запись не годится.
    if #payload > PEER_PAYLOAD_MAX and imp then payload = Build(gearB64 ~= nil, false) end
    if #payload > PEER_PAYLOAD_MAX and gearB64 then payload = Build(false, imp ~= nil) end
    if #payload > PEER_PAYLOAD_MAX then return nil end
    return payload
end

function PeerDrainGear(db)
    local q = peerStats.gearQueue
    if type(q) ~= "table" or #q == 0 then return end
    local nowT = time()
    local gap = PEER_GAP
    if peerStats.throttleUntil and nowT < peerStats.throttleUntil then
        gap = PEER_GAP_THROTTLED
    end
    if nowT - peerStats.lastSend < gap then return end
    while #q > 0 and nowT - q[1].at > PEER_TTL do
        local old = table.remove(q, 1)
        peerStats.gearExpired = (peerStats.gearExpired or 0) + 1
        D(("Peer gear expired before send: %s"):format(PeerEsc(old and old.name or "?", 40)))
    end
    if #q == 0 then return end
    -- Снапшот-ответ (Q1) ждёт, пока его запись о встрече не уйдёт из очереди:
    -- получатель без строки отбрасывает снапшот в orphan. Ждём, но не
    -- застреваем: проходим очередь по кругу один раз, и если все ждут — отдаём
    -- слот встречам (return false), они и разблокируют ожидание.
    local probe = 0
    while #q > 0 and q[1].afterKey and peerQueued[q[1].afterKey] and probe < #q do
        q[#q + 1] = table.remove(q, 1)
        probe = probe + 1
    end
    if #q == 0 or (q[1].afterKey and peerQueued[q[1].afterKey]) then return false end
    local channel = GetChannelName(PeerChannelName())
    if not channel or channel == 0 then
        if nowT - peerStats.lastNoChannel >= 60 then
            peerStats.lastNoChannel = nowT
            D(("Peer gear send blocked: channel %s not joined, q=%d")
                :format(PeerChannelName(), #q))
            PeerSync()
        end
        return false
    end
    local payload = PeerGearPayload(db, q[1])
    if not payload then
        -- Нечего отправлять (мусор в снапшоте) — запись не должна стоять вечно.
        local bad = table.remove(q, 1)
        peerStats.gearEmpty = (peerStats.gearEmpty or 0) + 1
        D(("Peer gear skipped: %s (nothing to pack)"):format(PeerEsc(bad and bad.name or "?", 40)))
        return false
    end
    if payload:find("|", 1, true) then
        db.debug.peerSendError = "gear payload contains '|' (server rejects it)"
        table.remove(q, 1)
        peerStats.gearEmpty = (peerStats.gearEmpty or 0) + 1
        return false
    end
    -- Снапшот-ответ на запрос уходит под тегом A1: иначе его запишут ВСЕ
    -- клиенты канала, хотя он адресован одному. Внутри — обычный G7, поэтому
    -- приём переиспользует тот же разбор.
    if q[1].ans then
        payload = "A1;" .. tostring(q[1].ans) .. ";" .. payload
        if #payload > PEER_PAYLOAD_MAX then
            local big = table.remove(q, 1)
            peerStats.gearEmpty = (peerStats.gearEmpty or 0) + 1
            D(("Peer gear skipped: %s (answer wrapper over budget)")
                :format(PeerEsc(big and big.name or "?", 40)))
            return false
        end
    end
    -- Транспорт — тот же PeerWireSend, что и у встреч: снапшоты шли старым
    -- SendChatMessage и после перевода слива на таймер давали БЛОКИРОВКУ на
    -- каждом пакете (живой SV 26.11.2026: `BLOCKED ... UNKNOWN()` вплотную к
    -- каждой строке `Peer gear sent`, счётчик peerGate 172 → 257, игрок видел
    -- попапы). Забыть третье место отправки — типичная цена «одной точки»:
    -- она одна только тогда, когда через неё прошли ВСЕ вызовы.
    local ok, result, transport = PeerWireSend(db, payload, channel)
    if NspNoteSendRet(db, ok, result, nowT) then
        D(("Peer gate: a block fired with this gear send (total %d)")
            :format(db.debug.peerGate or 0))
    end
    if not ok or result == false then
        db.debug.peerSendError = tostring(result):sub(1, 150)
        D(("Peer gear send error (%s): %s"):format(tostring(transport), PeerEsc(db.debug.peerSendError, 120)))
        PeerSync()
        return false
    end
    local it = table.remove(q, 1)
    local sent = peerStats.gearSent
    if type(sent) ~= "table" then sent = {}; peerStats.gearSent = sent end
    sent[it.key] = it.snapAt
    peerStats.lastSend = nowT
    peerStats.gearSentCount = (peerStats.gearSentCount or 0) + 1
    D(("Peer gear sent: %s (%d bytes) q=%d"):format(
        PeerEsc(it.name, 40), #payload, #q))
    PeerSync()
    return true
end

-- PeerWireSend(db, payload, channel) — ОДНА точка отправки пакета в канал.
-- С 26.11.2026 основной транспорт — аддон-сообщение по префиксу: замер зондом
-- NSGateProbe показал, что оно НЕ требует hardware-события (уходит из C_Timer),
-- в отличие от SendChatMessage, который клиент пускает только с клика по миру.
-- Отправка идёт в тот же канал (тип "CHANNEL" + номер), но отдельной полосой:
-- в чате её не видно, а слышат её только аддоны, зарегистрировавшие префикс.
-- Совместимость: старые клиенты префикс не регистрируют, поэтому НАШИ пакеты
-- они больше не слышат — принятое решение владельца (26.11.2026). Обратное
-- направление сохранено: приём идёт и с CHAT_MSG_CHANNEL, и с CHAT_MSG_ADDON,
-- поэтому старые клиенты продолжают кормить нас как раньше.
-- Возврат: ok, result, transport. global — в главном чанке 197 локалов из 200.
function PeerWireSend(db, payload, channel)
    local api = C_ChatInfo
    local addon = api and api.SendAddonMessage
    local useAddon = type(addon) == "function" and not (type(db) == "table" and db.peerViaAddon == false)
    if useAddon then
        local ok, r1 = pcall(addon, NSP_CONST.PEER_PREFIX, payload, "CHANNEL", channel)
        if ok then
            if type(db) == "table" and type(db.debug) == "table" then
                db.debug.peerTransport = "addon"
                peerStats.viaAddon = (peerStats.viaAddon or 0) + 1
            end
            return true, r1, "addon"
        end
        -- Исключение внутри API — падать в канал не надо, это тот же гейт:
        -- сообщаем наверх как ошибку транспорта.
        return false, tostring(r1), "addon"
    end
    local send = (api and api.SendChatMessage) or SendChatMessage
    if type(send) ~= "function" then return false, "no send api", "none" end
    local ok, r = pcall(send, payload, "CHANNEL", nil, channel)
    if type(db) == "table" and type(db.debug) == "table" then
        db.debug.peerTransport = "channel"
        peerStats.viaChannel = (peerStats.viaChannel or 0) + 1
    end
    return ok, r, "channel"
end

-- PeerRegisterPrefix() — объявить префикс клиенту. Без регистрации приёмник
-- НЕ получает CHAT_MSG_ADDON по этому префиксу вовсе, поэтому вызывается на
-- каждом входе и результат пишется в SV (иначе «тишина в канале» не отличить
-- от «префикс не зарегистрировался»).
function PeerRegisterPrefix(db)
    local api = C_ChatInfo
    if not api or type(api.RegisterAddonMessagePrefix) ~= "function" then
        if type(db) == "table" and type(db.debug) == "table" then
            db.debug.prefix = "api missing"
        end
        return false
    end
    local ok, r = pcall(api.RegisterAddonMessagePrefix, NSP_CONST.PEER_PREFIX)
    local registered
    if api.IsAddonMessagePrefixRegistered then
        local ok2, r2 = pcall(api.IsAddonMessagePrefixRegistered, NSP_CONST.PEER_PREFIX)
        registered = ok2 and tostring(r2) or ("error:" .. tostring(r2))
    end
    if type(db) == "table" and type(db.debug) == "table" then
        db.debug.prefix = ("%s/%s reg=%s"):format(
            NSP_CONST.PEER_PREFIX, tostring(type(ok) == "boolean" and r or ok), tostring(registered))
    end
    return ok == true or registered == "true"
end

-- PeerStartTimer() — слив очереди по таймеру (26.11.2026).
--
-- До этой правки очередь уходила ТОЛЬКО с клика по 3D-миру: клиент пускал
-- SendChatMessage в канал лишь из hardware-события (замер: 66 893 клика = все
-- отправки, а движение/каст/цель/ролл = 7 000+ попыток и НОЛЬ отправок плюс
-- попапы ADDON_ACTION_BLOCKED). Живой SV показывал queued=60 при sent=0.
-- Аддон-сообщение такого гейта не имеет (проверено зондом NSGateProbe), поэтому
-- слив переносится на таймер.
--
-- Шаг NSP_CONST.PEER_TIMER_STEP (1.2 с): замер показал пачку ~10 и устойчивые
-- ~1 сообщение в секунду; всё сверх одного в секунду сервер выбрасывает МОЛЧА
-- (526 из 600 при 10/с). 1.2 с = 50 сообщений в минуту при потолке ~65.
--
-- Своя проверка интервала НЕ дублирует DrainPeerQueue: там PEER_GAP считается
-- для старого транспорта, а здесь свой шаг. Поэтому PEER_GAP при работе таймера
-- не мешает: таймер вызывает слив, когда сам решит.
function PeerStartTimer()
    if type(C_Timer) ~= "table" or type(C_Timer.After) ~= "function" then return false end
    if peerStats.timerOn then return true end
    peerStats.timerOn = true
    local function Step()
        peerStats.timerTicks = (peerStats.timerTicks or 0) + 1
        local okDb, db = pcall(GetDB)
        if okDb and type(db) == "table" and db.peerEnabled then
            -- Только когда есть что отправлять: пустой тик не тратит канал.
            local gearQ = peerStats.gearQueue
            local hasGear = type(gearQ) == "table" and #gearQ > 0
            if #peerQueue > 0 or hasGear then
                local ok, err = pcall(DrainPeerTimer)
                if not ok then DbgErr("peerTimerDrain", err) end
            end
        end
        C_Timer.After(NSP_CONST.PEER_TIMER_STEP, Step)
    end
    C_Timer.After(NSP_CONST.PEER_TIMER_STEP, Step)
    return true
end

-- PeerWireTimerSend(db, payload, channel) — отправка из таймера.
-- Отдельная от PeerWireSend только затем, чтобы считать счётчик timerSent и
-- чтобы ошибка таймера не смешивалась с ошибкой отправки по клику.
function PeerWireTimerSend(db, payload, channel)
    local ok, result, transport = PeerWireSend(db, payload, channel)
    if ok and result ~= false then
        peerStats.timerSent = (peerStats.timerSent or 0) + 1
    else
        peerStats.timerFail = (peerStats.timerFail or 0) + 1
        if type(db) == "table" and type(db.debug) == "table" then
            db.debug.peerSendError = tostring(result):sub(1, 150)
        end
    end
    return ok, result, transport
end

-- Замер возврата канала (15.11.2026). Гейт клиента сообщает о себе СОБЫТИЕМ
-- ADDON_ACTION_BLOCKED, а не результатом вызова, поэтому заблокированная
-- отправка выглядела ровно как успешная: в живом SV три строки BLOCKED стояли
-- вплотную к строкам «Peer sent», и понять, ушёл пакет или нет, было нельзя.
-- Пишем, что вызов реально вернул (с типом: часть клиентов на успехе не
-- возвращает ничего), и поднимаем счётчик, если отказ гейта случился в ту же
-- секунду. global, не local: в главном чанке 193 локала из 200.
function NspNoteSendRet(db, okSent, result, nowT)
    if type(db) ~= "table" or type(db.debug) ~= "table" then return false end
    db.debug.sendRet = ("ok=%s ret=%s:%s"):format(tostring(okSent), type(result),
        PeerEsc(tostring(result), 30))
    db.debug.sendRetAt = nowT
    local at = type(db.debug.blockedAt) == "table" and db.debug.blockedAt["UNKNOWN()"]
    if okSent and result == nil and at and (nowT - at) <= 1 then
        db.debug.peerGate = (db.debug.peerGate or 0) + 1
        -- Счётчик ЗА СЕССИЮ (26.11.2026). `peerGate` накопительный и в SavedVariables
        -- не сбрасывается, поэтому по нему нельзя ответить «проблема сейчас или
        -- это остаток прошлых сессий». Живой случай: в файле стояло 694, из них
        -- 437 приросли на старом коде, а сессия после починки дала РОВНО 0 — но
        -- по одному числу это было не видно.
        db.debug.gateSession = (db.debug.gateSession or 0) + 1
        -- В КАКОМ контексте нас заблокировали: движение/каст/цель — это НЕ
        -- hardware-события, а клик по миру — да. Без этого нельзя решить, какие
        -- триггеры отправки стоит убрать (16.11.2026).
        db.debug.gateWhy = db.debug.gateWhy or {}
        local why = tostring(db.debug.lastDrainWhy or "?")
        db.debug.gateWhy[why] = (db.debug.gateWhy[why] or 0) + 1
        return true
    end
    return false
end

-- Чья блокировка (15.11.2026). Счётчик рос на блокировке ЛЮБОГО аддона, поэтому
-- «UNKNOWN() = 147» не отвечал на вопрос «сколько раз блокировали нас» и не имел
-- метки времени — цифра неизвестно чья и неизвестно за какой период. Свои
-- вызовы идут в blocked (+ blockedAt со временем), чужие — в blockedOther с
-- именем аддона, чтобы их не путали с нашими. global: в чанке 193 локала из 200.
function NspNoteBlock(db, addon, func, nowT, event)
    if type(db) ~= "table" or type(db.debug) ~= "table" then return false end
    local ours = type(addon) == "string" and addon:find("NearbySpy", 1, true) ~= nil
    if ours then
        db.debug.blocked = db.debug.blocked or {}
        db.debug.blocked[func] = (db.debug.blocked[func] or 0) + 1
        -- За сессию, рядом с накопительным: см. комментарий в NspNoteSendRet.
        db.debug.blockedSession = (db.debug.blockedSession or 0) + 1
        db.debug.blockedAt = db.debug.blockedAt or {}
        db.debug.blockedAt[func] = nowT
        db.debug.blockedEvent = db.debug.blockedEvent or {}
        db.debug.blockedEvent[func] = event
        return true
    end
    db.debug.blockedOther = db.debug.blockedOther or {}
    local key = tostring(addon) .. " -> " .. tostring(func)
    key = key:sub(1, 90)
    db.debug.blockedOther[key] = (db.debug.blockedOther[key] or 0) + 1
    return false
end

local function DrainPeerQueue()
    local db = GetDB()
    if not db.peerEnabled then return end
    -- Ответ на запрос пира (Q1, 24.11.2026): если запрос пришёл и его задержка
    -- истекла, записи встают в очередь ЗДЕСЬ — до выбора слота — чтобы уйти
    -- тем же кликом, который иначе ушёл бы на чужую пачку.
    if PeerAnswerDue then pcall(PeerAnswerDue, db) end
    -- ── Очерёдность «встречи или экипировка» (20.11.2026, второй заход) ────
    -- Сначала gear отправлялся ТОЛЬКО при пустой очереди встреч. На живом
    -- прогоне это оказалось голоданием: очередь встреч стояла на 55 из 60 и не
    -- пустела, поэтому gear не уходил НИКОГДА (gearSent=0, gearQueued=24/24,
    -- gearDropped=48 — вытеснено из переполненной очереди).
    --
    -- Причина не в канале: отправок было 1.6/мин при серверном лимите ~10/мин.
    -- Узкое место — hardware-гейт: отправка идёт только на клик по миру, и
    -- пока кликов мало, очередь встреч не разгружается до нуля.
    --
    -- Правило теперь: gear получает КАЖДЫЙ ТРЕТИЙ слот (при переполнении своей
    -- очереди — каждый второй), а при пустой очереди встреч — сразу. Вытеснение
    -- из полной очереди gear означает гарантированную потерю, тогда как встреча
    -- ещё подождёт в очереди (PEER_TTL = 600 с). Один слот, отданный gear,
    -- встречи не убивает — они разгружаются на следующем клике.
    peerStats.sendTurns = (peerStats.sendTurns or 0) + 1
    local gearQ = peerStats.gearQueue
    local gearLen = (type(gearQ) == "table") and #gearQ or 0
    if gearLen > 0 then
        local full = gearLen >= PEER_GEAR_QUEUE_MAX
        local every = full and 2 or 3
        if #peerQueue == 0 or full or (peerStats.sendTurns % every == 0) then
            -- PeerDrainGear возвращает true, только если реально отправил
            -- (например, gap ещё не прошёл) — иначе слот не тратим и отдаём
            -- его встречам.
            if PeerDrainGear(db) then return end
        end
    end
    if #peerQueue == 0 then return end
    local nowT = time()
    -- Адаптивный интервал: при большой очереди отправляем чаще, иначе канал
    -- захлёбывается после /who-скана. Но если сервер только что отказал
    -- (THROTTLED) — наоборот, ждём дольше.
    local gap = (#peerQueue >= PEER_BUSY_LEN) and PEER_GAP_BUSY or PEER_GAP
    if peerStats.throttleUntil and nowT < peerStats.throttleUntil then
        gap = PEER_GAP_THROTTLED
    end
    if nowT - peerStats.lastSend < gap then return end
    -- Подрезка смотрит ВСЮ очередь, а не только голову: раньше `while` крутился
    -- на head, и голова-запрос (свежая) не давала истечь записям за собой —
    -- они стояли, пока не вытеснялись переполнением. Запрос при истечении
    -- называется своим именем и считается отдельно: «Peer ask expired» —
    -- это потеря управляющего пакета, а не рядовой встречи.
    do
        local i = 1
        while i <= #peerQueue do
            local it = peerQueue[i]
            if nowT - (tonumber(it.at) or nowT) > PEER_TTL then
                table.remove(peerQueue, i)
                peerQueued[it.key] = nil
                peerStats.dropped = peerStats.dropped + 1
                if type(it.raw) == "string" then
                    peerStats.askExpired = (peerStats.askExpired or 0) + 1
                    D(("Peer ask expired before send: %s")
                        :format(PeerEsc(PeerItemLabel(it), 40)))
                else
                    D(("Peer expired before send: %s")
                        :format(PeerEsc(PeerItemLabel(it), 40)))
                end
            else
                i = i + 1
            end
        end
    end
    if #peerQueue == 0 then return end
    local channel = GetChannelName(PeerChannelName())
    if not channel or channel == 0 then
        -- The usual reason for a silent outbound queue: we never joined the
        -- channel (or the client dropped it on a zone change). One line a
        -- minute, otherwise every mouse click would repeat it.
        if nowT - peerStats.lastNoChannel >= 60 then
            peerStats.lastNoChannel = nowT
            D(("Peer send blocked: channel %s not joined (%s), q=%d")
                :format(PeerChannelName(), tostring(channel), #peerQueue))
            PeerSync()
        end
        return
    end
    -- Транспорт выбирает PeerWireSend: аддон-сообщение (основной) с фолбэком на
    -- SendChatMessage. Здесь достаточно убедиться, что есть ХОТЯ БЫ один —
    -- раньше проверялся только канальный, и клиент без него не отправил бы
    -- ничего, даже если аддон-сообщения работают.
    local hasAddon = C_ChatInfo and type(C_ChatInfo.SendAddonMessage) == "function"
    local send = C_ChatInfo and C_ChatInfo.SendChatMessage or SendChatMessage
    if not hasAddon and type(send) ~= "function" then return end

    -- ── Управляющий пакет (запрос Q1, 24.11.2026) ───────────────────────────
    -- Он уже собран целиком и в пачку не пакуется: это одно короткое
    -- сообщение, а не запись о встрече. Стоит в голове очереди, поэтому уходит
    -- первым же свободным слотом.
    local ctl = peerQueue[1]
    if ctl and type(ctl.raw) == "string" then
        if ctl.raw:find("|", 1, true) then
            db.debug.peerSendError = "ask payload contains '|' (server rejects it)"
            table.remove(peerQueue, 1)
            peerQueued[ctl.key] = nil
            PeerSync()
            return
        end
        local okC, resultC, trC = PeerWireSend(db, ctl.raw, channel)
        if NspNoteSendRet(db, okC, resultC, nowT) then
            D(("Peer gate: a block fired with this ask send (total %d)")
                :format(db.debug.peerGate or 0))
        end
        if not okC or resultC == false then
            db.debug.peerSendError = tostring(resultC):sub(1, 150)
            D(("Peer ask send error (%s): %s"):format(tostring(trC), PeerEsc(db.debug.peerSendError, 120)))
            PeerSync()
            return
        end
        table.remove(peerQueue, 1)
        peerQueued[ctl.key] = nil
        peerStats.lastSend = nowT
        peerStats.askSent = (peerStats.askSent or 0) + 1
        db.debug.peerSendError = nil
        D(("Peer ask sent: %s (%d bytes) q=%d"):format(
            PeerEsc(ctl.label or "?", 30), #ctl.raw, #peerQueue))
        PeerSync()
        return
    end

    -- ── Сборка пачки ────────────────────────────────────────────────────────
    -- Одна отправка = одно сообщение канала, а PEER_GAP даёт лишь 6 отправок в
    -- минуту. /who-скан на 20 человек при этом не успевал разгрузиться: очередь
    -- переполнялась, и через PEER_TTL записи сгорали неотправленными (живой лог
    -- 10.11.2026: пять строк "expired before send" подряд).
    --
    -- В одно сообщение влезает 3 записи (проверено по байтам: заголовок общий,
    -- записи через "|", разделитель безопасен — PeerField не пропускает "|" в
    -- имени/зоне). Пачка собирается только из записей ОДНОГО game+realm:
    -- мир — часть заголовка, иначе его пришлось бы повторять в каждой записи,
    -- съев весь выигрыш.
    local head = peerQueue[1]
    -- Игра в заголовке — один символ: "forever" (7 байт) -> "f". Если
    -- значение не в таблице (новая игра), уходит как есть, чтобы не потерять
    -- запись; приём понимает оба вида.
    local headGame = PeerEncode("game", head.game)
    -- 'q' (нет значения) и 'z' (неизвестное значение) здесь одинаково означают
    -- «кодом игру не передать»: тогда уходит имя игры как есть, приём понимает
    -- значение длиной больше одного символа.
    if headGame == PEER_CODE_UNKNOWN or headGame == PEER_CODE_NONE then headGame = head.game end
    -- Заголовок "N6;game;realm;" входит в лимит сообщения, поэтому считается
    -- сразу: без него пачка вылезала за PEER_PAYLOAD_MAX (живой прогон теста:
    -- 252 байта при лимите 240).
    -- Мир в заголовке — КОДОМ (20.11.2026): 1 байт вместо 22 у "CAMWOW EU4
    -- Realm 6 PvP". В режиме N5 мир уходит ТЕКСТОМ: старый клиент код не
    -- поймёт, а он для этого режима и нужен. Мир вне таблицы уходит текстом в
    -- любом режиме — приём различает код и имя по длине.
    local headRealm = head.realm
    if PEER_PROTO ~= "N5" then headRealm = PeerRealmCode(head.realm) or head.realm end
    -- ── Ответ на запрос — своим тегом A1 (24.11.2026) ───────────────────────
    -- Владелец потребовал отдельный код протокола для ответов, и это
    -- правильнее «рядового трафика»: ответ адресован ОДНОМУ запросившему, а
    -- если он уходит как N7, его записывают ВСЕ клиенты канала — чужие базы
    -- наполняются данными, которых никто не просил.
    --   A1;nonce;<внутренний пакет, как есть>   →  A1;nonce;N7;f;realm;rec1,rec2
    -- Клиент без поддержки A1 отбивает пакет на незнакомом протоколе; клиент с
    -- поддержкой применяет его только при совпадении nonce со СВОИМ запросом.
    -- Обёртка стоит ~10 байт, поэтому бюджет внутреннего пакета уменьшается —
    -- иначе пачка вылезла бы за предел сообщения.
    local headAns = head.ans
    local wrapper = headAns and ("A1;" .. tostring(headAns) .. ";") or ""
    local payloadMax = PEER_PAYLOAD_MAX - #wrapper
    -- Заголовок "N6;game;realm;" входит в лимит сообщения, поэтому считается
    -- сразу: без него пачка вылезала за PEER_PAYLOAD_MAX (живой прогон теста:
    -- 252 байта при лимите 240).
    -- Мир в заголовке — КОДОМ (20.11.2026): 1 байт вместо 22 у "CAMWOW EU4
    -- Realm 6 PvP". В режиме N5 мир уходит ТЕКСТОМ: старый клиент код не
    -- поймёт, а он для этого режима и нужен. Мир вне таблицы уходит текстом в
    -- любом режиме — приём различает код и имя по длине.
    local headerLen = #PEER_PROTO + 1 + #headGame + 1 + #headRealm + 1
    local batch, batchLen = { head }, headerLen + #head.rec
    local i = 2
    while i <= #peerQueue and #batch < PEER_BATCH_MAX do
        local it = peerQueue[i]
        if it.game ~= head.game or it.realm ~= head.realm then break end
        -- Ответы разных запросов в одну пачку не склеиваются: nonce — часть
        -- обёртки, и второй nonce сделал бы пакет нечитаемым для получателя.
        if it.ans ~= headAns then break end
        local add = 1 + #it.rec           -- разделитель + сама запись
        if batchLen + add > payloadMax then break end
        batch[#batch + 1] = it
        batchLen = batchLen + add
        i = i + 1
    end

    local payload
    -- Запись под текущий протокол: в режиме N5 (переходный) поля идут текстом.
    local function recFor(it)
        return (PEER_PROTO == "N5") and (it.legacyRec or it.rec) or it.rec
    end
    -- В переходном режиме N5 игра тоже текстом: старый клиент кода не поймёт.
    local gameForWire = (PEER_PROTO == "N5") and head.game or headGame
    if #batch == 1 then
        payload = PEER_PROTO .. ";" .. gameForWire .. ";" .. headRealm .. ";" .. recFor(head)
    else
        local parts = {}
        for k = 1, #batch do parts[k] = recFor(batch[k]) end
        payload = PEER_PROTO .. ";" .. gameForWire .. ";" .. headRealm .. ";" .. table.concat(parts, PEER_BATCH_SEP)
    end
    -- Обёртка ответа (A1): снаружи чужой nonce, внутри — готовый обычный пакет.
    if headAns then payload = wrapper .. payload end

    -- Последняя защита перед отправкой: сервер отклоняет сообщение с '|' как
    -- «Invalid escape code», и пакет с ним не уходит НИКОГДА (проверено в игре
    -- 10.11.2026). Лучше не отправить и сказать об этом, чем молча копить
    -- очередь: ошибка видна в db.debug.peerSendError.
    if payload:find("|", 1, true) then
        db.debug.peerSendError = "payload contains '|' (server rejects it)"
        D(("Peer send blocked: '|' in payload (%s)"):format(PeerEsc(payload, 60)))
        PeerSync()
        return
    end

    local ok, result, transport = PeerWireSend(db, payload, channel)
    if NspNoteSendRet(db, ok, result, nowT) then
        D(("Peer gate: a block fired with this send, packet may be lost (total %d)")
            :format(db.debug.peerGate or 0))
    end
    if not ok or result == false then
        db.debug.peerSendError = tostring(result):sub(1, 150)
        D(("Peer send error (%s): %s"):format(tostring(transport), PeerEsc(db.debug.peerSendError, 120)))
        PeerSync()
        return
    end
    local names = {}
    for k = 1, #batch do
        local it = batch[k]
        table.remove(peerQueue, 1)
        peerQueued[it.key] = nil
        peerSent[it.key] = true
        names[#names + 1] = PeerEsc(it.name or "?", 20)
    end
    peerStats.lastSend = nowT
    peerStats.sent = peerStats.sent + #batch
    peerStats.batched = (peerStats.batched or 0) + ((#batch > 1) and 1 or 0)
    db.debug.peerSendError = nil
    D(("Peer sent: %s%s q=%d sent=%d"):format(
        table.concat(names, ", "), (#batch > 1) and (" [batch " .. #batch .. "]") or "",
        #peerQueue, peerStats.sent))
    PeerSync()
end

-- DrainPeerTimer() — слив по таймеру (26.11.2026). Отдельная запись нужна
-- ровно затем, чтобы обойти СВОЙ интервал старого транспорта: внутри
-- DrainPeerQueue стоит `nowT - peerStats.lastSend < PEER_GAP → return`, и без
-- сброса таймер попадал бы под чужой шаг (10 с) вместо своего (1.2 с).
-- Сам шаг таймера уже проверен вызывающим, поэтому сбрасывать lastSend здесь
-- безопасно: две отправки в одну секунду всё равно не сложатся, таймер идёт
-- раз в PEER_TIMER_STEP.
function DrainPeerTimer()
    peerStats.lastSend = 0
    -- Счётчик timerSent раньше жил в PeerWireTimerSend, но слив идёт через
    -- DrainPeerQueue → PeerWireSend, то есть мимо этой обёртки: в живом SV
    -- 26.11.2026 таймер отработал десятки раз (queued=0), а timerSent остался 0.
    -- Считаем ДЕЛЬТУ отправленного вокруг вызова — так счётчик не зависит от
    -- того, через какую функцию прошла отправка.
    local before = peerStats.sent or 0
    local gearBefore = peerStats.gearSentCount or 0
    local ok, err = pcall(DrainPeerQueue)
    local added = ((peerStats.sent or 0) - before) + ((peerStats.gearSentCount or 0) - gearBefore)
    if added > 0 then
        peerStats.timerSent = (peerStats.timerSent or 0) + added
    elseif not ok then
        peerStats.timerFail = (peerStats.timerFail or 0) + 1
    end
    if not ok then error(err, 0) end
    return added > 0
end

-- ── Запрос базы у пиров: пакеты Q1 (запрос) и A1 (ответ) — 24.11.2026 ──────
-- Обмен был односторонним: N7 — встречи, G7 — экипировка и билд. Запроса
-- «пришли, что у тебя есть» в протоколе не было, поэтому добавлены ДВА тега:
--
--   запрос: Q1;game;realm;minutes;nonce          (~26 байт)
--   ответ:  A1;nonce;<обычный пакет>             → A1;k3f;N7;f;realm;rec1,rec2
--                                                 → A1;k3f;G7;f;realm;name;…
--
-- Почему у ответа СВОЙ тег (требование владельца 24.11.2026): ответ адресован
-- одному запросившему, а обычные N7/G7 записывают ВСЕ клиенты канала — чужие
-- базы наполнялись бы данными, которых никто не просил. С тегом A1 посторонний
-- клиент выбрасывает пакет (старый — на незнакомом протоколе, новый — на
-- несовпадении nonce), а наш разбор переиспользует обычный код внутри обёртки.
--
-- Ответ ограничен не размером базы, а каналом: ~10 сообщений в минуту, значит
-- верхушка по свежести (NSP_CONST.ASK_ROWS) плюс несколько снапшотов
-- (NSP_CONST.ASK_GEAR). «Выгрузить весь час» физически не влезает.

-- PeerNormName(s) — имя в сравнимом виде: без регистра, без лишних пробелов.
-- Замер по живому SV (240 отправителей в канале): двойные имена приходят ВСЕГДА
-- через ОДИН пробел («Youtchi Zerling», «Grishnákh Soulrend»), дефисов и цифр
-- в именах нет. Но ввод игрока бывает с лишним пробелом после копипаста, и
-- тогда точное сравнение молча не срабатывало бы.
function PeerNormName(s)
    if type(s) ~= "string" then return "" end
    s = s:lower():gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
    return s
end

-- PeerIsMe(name) — это имя нашего персонажа? Нужно адресному запросу (Q1 с
-- именем): отвечать должен ТОЛЬКО названный игрок, иначе «спросим по очереди»
-- снова превращается в залп от всех участников канала.
--
-- ⚠️ Двойные имена. UnitName отдаёт имя и фамилию ДВУМЯ значениями, а в канале
-- и в базе они склеены пробелом, поэтому сравнение идёт по склеенной форме.
-- Голое имя при наличии фамилии НЕ считается совпадением: иначе запрос «Wolff»
-- получил бы ответ и от «Wolff», и от «Wolff Magy» — то есть адресность теряла
-- бы смысл ровно там, ради чего делалась. Дефис приравнивается к пробелу:
-- внутри клиента двойное имя хранится через дефис, и игрок может набрать так.
function PeerIsMe(name)
    local want = PeerNormName(name)
    if want == "" then return false end
    local wantDash = (want:gsub("%-", " "))
    local me, surname = UnitName("player")
    if type(me) ~= "string" or me == "" then return false end
    local forms
    if type(surname) == "string" and surname ~= "" then
        forms = {me .. " " .. surname, me .. "-" .. surname}
    else
        forms = {me, me .. "-" .. PlayerRealm()}
    end
    for i = 1, #forms do
        local have = PeerNormName(forms[i])
        if have == want or (have:gsub("%-", " ")) == wantDash then return true end
    end
    return false
end

-- PeerAskSend(db, minutes, target) — поставить запрос в очередь канала.
-- target = nil → запрос всем (вещание); иначе спрашиваем ТОЛЬКО названного.
-- true + payload при успехе, false + причина при отказе.
function PeerAskSend(db, minutes, target)
    if type(db) ~= "table" then return false, "no database" end
    if not db.peerEnabled then return false, "sharing is off (/nspy peer on)" end
    minutes = math.floor(tonumber(minutes) or 60)
    if minutes < NSP_CONST.ASK_MIN then minutes = NSP_CONST.ASK_MIN end
    if minutes > NSP_CONST.ASK_MAX then minutes = NSP_CONST.ASK_MAX end
    -- GetChannelName возвращает ДВА значения (id, имя): в сравнении берём
    -- только первое, иначе во второй аргумент форматирования уехало бы имя.
    local chan = GetChannelName(PeerChannelName())
    if not chan or chan == 0 then
        return false, ("channel %s is not joined (/nspy peer on)"):format(PeerChannelName())
    end
    -- Мир для запроса не нужен: он не едет в пакете (требование владельца
    -- 24.11.2026), а ответ собирается по миру КАЖДОЙ записи. Раньше здесь стоял
    -- отказ «realm unknown» — он запрещал спросить в клиенте, который не отдал
    -- имя мира, хотя для запроса это уже не нужно.
    -- Локальная переменная остаётся только для метаданных элемента очереди
    -- (по ней видно, из какого мира запрос), поэтому пустое значение допустимо.
    local realm = PlayerRealm()
    if target then
        target = tostring(target)
        -- Имя едет ТЕКСТОМ (в отличие от прочих полей): оно не из конечного
        -- множества. PeerField запрещает разделители и управляющие символы —
        -- без него имя с ';' развалило бы пакет на лишние поля.
        if not PeerField(target, 60) then return false, "bad player name" end
        -- Просить у самого себя бессмысленно: ответ придёт от нас же и будет
        -- отброшен как собственное эхо.
        if PeerIsMe(target) then return false, "that is your own character" end
    end
    -- Пакет запроса — МИНИМАЛЬНЫЙ: `Q1;минуты;nonce[;имя]`. Игры и мира в нём
    -- НЕТ (замечание владельца 24.11.2026): канал уже определяет, кто слышит
    -- запрос, а мир каждой записи едет в самих N7-ответах — дублировать его в
    -- запросе значит тратить байты и заставлять приём сверять поле, которое
    -- ничего не решает.
    -- nonce уникален на КАЖДЫЙ запрос: по нему привязан и ключ дедупа ответа, и
    -- запись в таблице открытых запросов. Счётчик нужен потому, что при обходе
    -- пиров по очереди два запроса попадают в одну секунду — одного лишь
    -- time() не хватило бы, nonce совпал бы и второй ответ считался чужим.
    peerStats.askSeq = (peerStats.askSeq or 0) + 1
    local nonce = PeerB36(math.floor(time() % 1678591) + 1870) .. PeerB36(peerStats.askSeq)
    if #nonce > 8 then nonce = nonce:sub(-8) end
    local parts = {"Q1", PeerB36(minutes), nonce}
    if target then parts[#parts + 1] = target end
    local payload = table.concat(parts, ";")
    if #payload > PEER_PAYLOAD_MAX then return false, "request too long" end
    if payload:find("|", 1, true) then return false, "request contains '|'" end
    local key = "ask|" .. nonce
    for i = 1, #peerQueue do
        if peerQueue[i].key == key then return false, "the same request is already queued" end
    end
    local nowT = time()
    peerStats.askTargetAt = peerStats.askTargetAt or {}
    -- Один и тот же адресат не чаще ASK_TARGET_GAP: при обходе легко дважды
    -- кликнуть по тому же имени, а канал этого не любит. Для запроса «всем»
    -- ключ — "all": он стоит дороже всех (отвечают сразу все), поэтому
    -- ограничен тем же интервалом.
    local gateKey = target or "all"
    local prev = tonumber(peerStats.askTargetAt[gateKey]) or 0
    if prev > 0 and nowT - prev < NSP_CONST.ASK_TARGET_GAP then
        return false, ("already asked %s %ds ago")
            :format(target or "everyone", nowT - prev)
    end
    peerStats.askTargetAt[gateKey] = nowT
    -- Место под запрос освобождаем САМИ и только за счёт рядовой записи:
    -- без этой проверки вставка давала 61 элемент при лимите 60 (живой SV
    -- 26.11.2026), а очередь за потолком потом считалась «полной» вечно.
    if #peerQueue >= PEER_QUEUE_MAX then
        local victim = PeerEvictIndex()
        if victim > 0 then
            local gone = table.remove(peerQueue, victim)
            peerQueued[gone.key] = nil
            peerStats.dropped = peerStats.dropped + 1
            D(("Peer queue full: dropped %s (making room for a request)")
                :format(PeerEsc(PeerItemLabel(gone), 40)))
        end
    end
    -- В голову очереди: запрос — это одна короткая строка, и ждать за пачкой
    -- встреч ему незачем.
    table.insert(peerQueue, 1, {
        key = key, raw = payload, name = "?", at = nowT,
        game = db.game, realm = realm,
        label = target and ("Q1 %dm -> %s"):format(minutes, target) or ("Q1 %dm"):format(minutes),
    })
    peerQueued[key] = true
    -- Открытые запросы: их МОЖЕТ быть несколько одновременно, иначе обход по
    -- очереди ломался бы — второй запрос закрывал окно первого, и его ответ
    -- отбрасывался как «чужой». Храним по nonce, самый старый вытесняется.
    local open = peerStats.askOpen
    if type(open) ~= "table" then open = {}; peerStats.askOpen = open end
    local live, oldest, oldestAt = 0, nil, nil
    for n, req in pairs(open) do
        if nowT > (tonumber(req.expires) or 0) then
            open[n] = nil
        else
            live = live + 1
            local at = tonumber(req.at) or 0
            if not oldestAt or at < oldestAt then oldest, oldestAt = n, at end
        end
    end
    if live >= NSP_CONST.ASK_OPEN_MAX and oldest then open[oldest] = nil end
    open[nonce] = {target = target, minutes = minutes, at = nowT,
        -- Поле НЕ называем until: это зарезервированное слово Lua, и
        -- `req.until` не компилируется вовсе (ловится первым же прогоном).
        expires = nowT + NSP_CONST.ASK_OPEN_TTL}
    peerStats.askOut = (peerStats.askOut or 0) + 1
    D(("Peer ask queued: %s"):format(payload))
    PeerSync()
    return true, payload
end

-- PeerAskKnownPeers() — кто вообще подавал голос в канале. Нужен для обхода по
-- очереди: имена берём из tally отправителей, которая пишется в SavedVariables
-- (peerStats живёт только в памяти и на логауте обнуляется).
-- Возвращает массив {name=..., count=...}, отсортированный по числу пакетов.
function PeerAskKnownPeers(db)
    local out = {}
    if type(db) ~= "table" or type(db.debug) ~= "table" then return out end
    local senders = db.debug.peerSenders
    if type(senders) ~= "table" then return out end
    for name, count in pairs(senders) do
        if type(name) == "string" and name ~= "" then
            out[#out + 1] = {name = name, count = tonumber(count) or 0}
        end
    end
    table.sort(out, function(a, b)
        if a.count == b.count then return a.name < b.name end
        return a.count > b.count
    end)
    return out
end

-- PeerAnswerDue(db) — собрать ответ на пришедший Q1, когда прошла случайная
-- задержка. Вызывается из разгрузки очереди, поэтому ответ уходит тем же
-- кликом по миру, что и обычные пакеты.
function PeerAnswerDue(db)
    local req = peerStats.askPending
    if type(req) ~= "table" then return false end
    local nowT = time()
    if nowT < (tonumber(req.due) or 0) then return false end
    peerStats.askPending = nil
    if type(db) ~= "table" or not db.peerEnabled then return false end
    -- Канал отвечает не чаще NSP_CONST.ASK_GAP: два запроса подряд не должны
    -- давать два ответа, иначе один игрок займёт канал чужими записями.
    if peerStats.askLastAnswer
        and nowT - peerStats.askLastAnswer < NSP_CONST.ASK_GAP then
        peerStats.askSkipped = (peerStats.askSkipped or 0) + 1
        D("Peer ask answer skipped: channel answered recently")
        PeerSync()
        return false
    end
    local cutoff = nowT - (tonumber(req.minutes) or 60) * 60
    local rows = {}
    for key, p in pairs(db.players or {}) do
        local ls = tonumber(p.lastSeen) or 0
        -- Только СВОИ встречи: чужое (source == "peer") не пересылаем — иначе
        -- канал становится релеем, а получатель принимает это за наблюдение.
        if ls > 0 and ls >= cutoff and (p.source or "") ~= "peer"
            and p.class and p.level and p.name then
            rows[#rows + 1] = {key = key, p = p, ls = ls}
        end
    end
    if #rows == 0 then
        peerStats.askEmpty = (peerStats.askEmpty or 0) + 1
        D("Peer ask answer: nothing in the window")
        PeerSync()
        return false
    end
    table.sort(rows, function(a, b) return a.ls > b.ls end)
    local want = #rows
    if want > NSP_CONST.ASK_ROWS then want = NSP_CONST.ASK_ROWS end
    local queued, gearN, gearQ = 0, 0, 0
    for i = 1, want do
        local row = rows[i]
        local p = row.p
        local before = #peerQueue
        QueuePeerNew(db, {
            key = row.key, name = p.name, realm = p.realm,
            class = p.class, level = p.level, race = p.race, faction = p.faction,
            zone = p.zone, zoneId = p.zoneId,
            -- Координаты НЕ отправляем: в базе у /who-строк это точка
            -- НАБЛЮДАТЕЛЯ (провенанс точки в SV не сохраняется), а выдать её за
            -- позицию игрока — значит поставить чужого человека на свою точку.
            observedAt = row.ls,
            answerNonce = req.nonce,
        })
        if #peerQueue > before then
            queued = queued + 1
            local snap = p.gear
            if gearN < NSP_CONST.ASK_GEAR and type(snap) == "table"
                and type(snap.ids) == "string" and snap.ids ~= "" and not snap.from
                and not db.peerGearOff then
                local gBefore = type(peerStats.gearQueue) == "table"
                    and #peerStats.gearQueue or 0
                -- Ключ дедупа записи о встрече считаем так же, как QueuePeerNew:
                -- снапшот ждёт его отправки, иначе у получателя нет строки и
                -- снапшот уйдёт в orphan.
                PeerQueueGear(row.key, snap, {
                    force = true,
                    afterKey = db.game .. "|" .. row.key .. "|a" .. tostring(req.nonce),
                    answerNonce = req.nonce,
                })
                local gAfter = type(peerStats.gearQueue) == "table"
                    and #peerStats.gearQueue or 0
                if gAfter > gBefore then
                    gearN = gearN + 1
                    gearQ = gearQ + (gAfter - gBefore)
                end
            end
        end
    end
    local skipped = want - queued
    peerStats.askQueued = (peerStats.askQueued or 0) + queued
    peerStats.askGearQueued = (peerStats.askGearQueued or 0) + gearN
    peerStats.askSkipped = (peerStats.askSkipped or 0) + skipped
    if queued > 0 then peerStats.askLastAnswer = nowT end
    D(("Peer ask answer: %d of %d rows queued (%d left out of the window), gear %d/%d, from %s")
        :format(queued, want, #rows - want, gearN, gearQ, PeerEsc(req.from or "?", 30)))
    PeerSync()
    return queued > 0
end

-- ReceivePeerAsk(fields, sender) — пришёл запрос Q1. Отвечаем НЕ сразу:
-- случайная задержка разносит ответы нескольких пиров по времени, иначе все
-- ответят одним залпом в канал с лимитом ~10 сообщений в минуту.
function ReceivePeerAsk(fields, sender)
    local db = GetDB()
    local function Ignore(reason)
        peerStats.askIgnored = (peerStats.askIgnored or 0) + 1
        local tag = "ask:" .. reason
        if peerStats.rejectLogged and not peerStats.rejectLogged[tag] then
            peerStats.rejectLogged[tag] = true
            D(("Peer ask ignored: %s (from %s)"):format(reason, PeerEsc(sender or "?", 40)))
        end
        PeerSync()
    end
    peerStats.askReqIn = (peerStats.askReqIn or 0) + 1
    if not db.peerEnabled then return Ignore("sharing disabled") end
    -- Раскладка: Q1;минуты;nonce[;имя]. Ни игры, ни мира здесь нет — канал сам
    -- определяет слышимость, а мир едет в записях ответа. Поле адресата
    -- необязательное: 3 поля = запрос всем, 4 = адресный «ответь мне».
    if #fields ~= 3 and #fields ~= 4 then return Ignore("field count") end
    local minutes = tonumber(tostring(fields[2] or ""), 36)
    if not minutes or minutes <= 0 then return Ignore("bad window") end
    if minutes < NSP_CONST.ASK_MIN then minutes = NSP_CONST.ASK_MIN end
    if minutes > NSP_CONST.ASK_MAX then minutes = NSP_CONST.ASK_MAX end
    if type(fields[3]) ~= "string" or fields[3] == "" or not PeerField(fields[3], 8) then
        return Ignore("bad nonce")
    end
    -- Адресат: если запрос назвал конкретного игрока, отвечает ТОЛЬКО он.
    -- Это и есть смысл имени в команде — обходить пиров по одному, не устраивая
    -- залп из всех клиентов канала в минуту, которая держит ~10 сообщений.
    local target = fields[4]
    if target == "" or target == "-" then target = nil end
    if target then
        if not PeerField(target, 60) then return Ignore("bad target") end
        if not PeerIsMe(target) then
            peerStats.askNotMe = (peerStats.askNotMe or 0) + 1
            return
        end
    end
    local nowT = time()
    -- Один ответ на отправителя за NSP_CONST.ASK_SENDER_GAP: иначе один игрок
    -- может запрашивать базу в цикле, и канал будет занят только им.
    peerStats.askFrom = peerStats.askFrom or {}
    local last = tonumber(peerStats.askFrom[sender]) or 0
    if last > 0 and nowT - last < NSP_CONST.ASK_SENDER_GAP then
        return Ignore("request from this sender too soon")
    end
    if type(peerStats.askPending) == "table" then
        -- Отвечаем только на последний запрос: два ответа подряд канал всё
        -- равно не примет, а склеить их — значит нарушить nonce.
        peerStats.askSkipped = (peerStats.askSkipped or 0) + 1
        return
    end
    peerStats.askFrom[sender] = nowT
    local jitter = 0
    if NSP_CONST.ASK_JITTER > 0 then jitter = math.random(0, NSP_CONST.ASK_JITTER) end
    peerStats.askPending = {nonce = fields[3], minutes = minutes, due = nowT + jitter,
        sender = sender, from = PeerEsc(sender or "?", 40), target = target}
    D(("Peer ask received: %dm%s, answering in %ds (from %s)")
        :format(minutes, target and (" for " .. PeerEsc(target, 30)) or "", jitter,
            PeerEsc(sender or "?", 40)))
    PeerSync()
end

local function ReceivePeerMessage(message, sender, fromBatch)
    -- fromBatch: строку вызвал разбор пачки N5. Счётчики сообщений и лимит
    -- частоты считаются ОДИН раз на сообщение, а не на каждую запись внутри
    -- него — иначе пачка из 5 человек съедала бы 5/120 минутного лимита.
    if not fromBatch then
        peerStats.seen = peerStats.seen + 1
    end
    -- Reject(reason) — the reason is logged once per session (first occurrence)
    -- so a misconfigured realm or a foreign client version is visible in chat
    -- instead of the traffic silently vanishing.
    local function Reject(reason)
        peerStats.rejected = peerStats.rejected + 1
        if not peerStats.rejectLogged[reason] then
            peerStats.rejectLogged[reason] = true
            D(("Peer rejected: %s (from %s)"):format(reason, PeerEsc(sender or "?", 40)))
        end
        PeerSync()
    end
    local db = GetDB()
    if not db.peerEnabled then return Reject("sharing disabled") end
    if type(message) ~= "string" or (canaccessvalue and not canaccessvalue(message)) then
        return Reject("unreadable message")
    end
    if #message > 255 or type(sender) ~= "string"
        or (canaccessvalue and not canaccessvalue(sender))
        or not PeerField(sender, 120) then return Reject("bad sender/length") end
    -- Our OWN packet comes back through the channel as a normal chat message, and
    -- counting it as a received record made `received`/`merged` lie: the live save
    -- showed merged=1 right after our first send, with the "peer" being the player
    -- we had just reported ourselves. Self-echoes are recognised by the speaker's
    -- name (that is us) and never touch the stats or the database.
    do
        local me, surname = UnitName("player")
        if me and me ~= "" and (sender == me
            or (surname and surname ~= "" and sender == me .. " " .. surname)
            or sender == me .. "-" .. PlayerRealm()) then
            peerStats.selfEcho = peerStats.selfEcho + 1
            if not peerStats.rejectLogged.selfEcho then
                peerStats.rejectLogged.selfEcho = true
                D(("Peer: own packet echoed back, ignored (sender=%s)"):format(PeerEsc(sender, 40)))
            end
            return
        end
    end
    peerStats.lastSender = sender
    -- Per-sender tally: tells the owner which addon users actually feed the
    -- channel, and is the first thing to look at when a bad batch arrives.
    do
        local okDb, db = pcall(GetDB)
        if okDb and type(db) == "table" and type(db.debug) == "table" then
            db.debug.peerSenders = db.debug.peerSenders or {}
            local key = PeerEsc(sender, 40)
            db.debug.peerSenders[key] = (db.debug.peerSenders[key] or 0) + 1
        end
    end
    if peerChatVisible and DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
        -- The beta has no ChatFrame_AddChannel: mirror only received peer events.
        -- Escape pipes so untrusted chat text cannot inject texture/link markup.
        pcall(DEFAULT_CHAT_FRAME.AddMessage, DEFAULT_CHAT_FRAME,
            "[" .. PeerChannelName() .. "] " .. sender:gsub("|", "?") .. ": " .. message:gsub("|", "?"))
    end
    local nowT = time()
    if nowT - peerStats.inStart >= 60 then
        peerStats.inStart, peerStats.inCount = nowT, 0
    end
    peerStats.inCount = peerStats.inCount + 1
    if peerStats.inCount > 120 then return Reject("rate limit") end
    local fields = {}
    for part in (message .. ";"):gmatch("(.-);") do fields[#fields + 1] = part end
    -- Состав канала по протоколам (22.11.2026). Без него не видно, шлют ли пиры
    -- G7 вообще: seen считает все сообщения подряд, а «пришло 69, из них G7 ноль»
    -- и «пришло 69, все G7 и все отбиты» требуют разных действий.
    do
        local kind = tostring(fields[1] or "?"):sub(1, 6)
        local kinds = peerStats.kinds
        if type(kinds) ~= "table" then kinds = {}; peerStats.kinds = kinds end
        kinds[kind] = (kinds[kind] or 0) + 1
    end

    -- Снапшот экипировки/билда — отдельный тип пакета G7 (20.11.2026). Разбор
    -- вынесен в свою функцию, но живёт в этом же чанке, поэтому видит все
    -- локальные константы. Проверяется ДО валидации протокола: у G7 не 13
    -- полей, и старый чек «field count» отверг бы его как мусор.
    if fields[1] == "G7" then
        return ReceivePeerGear(fields, sender)
    end

    -- Запрос базы (Q1, 24.11.2026): управляющий пакет со своим форматом
    -- (5 полей), поэтому проверяется ДО валидации числа полей у встреч.
    if fields[1] == "Q1" then
        return ReceivePeerAsk(fields, sender)
    end

    -- Ответ на запрос (A1, 24.11.2026) — тоже до проверки числа полей: снаружи
    -- у него 3 поля, а записи внутри. Чужой ответ отбрасывается по nonce.
    if fields[1] == "A1" then
        return ReceivePeerAnswer(message, sender)
    end

    -- Признак пачки — разделитель PEER_BATCH_SEP (запятая). Он ЗАПРЕЩЁН в
    -- имени, зоне, мире и хвостовом тексте (PeerField), поэтому в одиночном
    -- пакете его быть не может. Без этой проверки одиночный N5 неотличим от
    -- пачки (у обоих 13 полей), и строка уходила в batch-ветку заново —
    -- рекурсия до лимита частоты.
    --
    -- Раньше признаком был '|', но с ним сервер отклонял сообщение целиком
    -- («Invalid escape code in chat message»), поэтому разделитель заменён.
    if (fields[1] == "N7" or fields[1] == "N6" or fields[1] == "N5")
        and type(message) == "string" and message:find(PEER_BATCH_SEP, 1, true) then
        local proto = fields[1]
        if not fields[2] or not fields[3] then return Reject("batch header") end
        local prefix = proto .. ";" .. fields[2] .. ";" .. fields[3] .. ";"
        if message:sub(1, #prefix) ~= prefix then return Reject("batch header") end
        local rest = message:sub(#prefix + 1)
        local n = 0
        for part in (rest .. PEER_BATCH_SEP):gmatch("(.-)" .. PEER_BATCH_SEP) do
            if part ~= "" then
                n = n + 1
                if n > PEER_BATCH_MAX then break end
                -- Запись внутри пачки НЕ содержит протокола и мира: они в
                -- заголовке. Всегда собираем полный пакет заново.
                ReceivePeerMessage(
                    proto .. ";" .. fields[2] .. ";" .. fields[3] .. ";" .. part, sender, true)
            end
        end
        if n == 0 then return Reject("empty batch") end
        peerStats.batchIn = (peerStats.batchIn or 0) + n
        if PeerSync then PeerSync() end
        return
    end

    -- N2 = 8 fields (no place), N3 = 12 (zone id, zone name, x, y),
    -- N4 = 13 (N3 + unix observation time),
    -- N5 = 13 (N4 с текстовыми классом/расой/фракцией),
    -- N6 = 13 или 14 (класс/раса/фракция и игра — кодами; имя зоны рядом с id;
    --      14-е поле — хвост с текстовыми значениями для слотов 'z').
    -- N7 = 13 или 14 — как N6, но мир кодом, время base36-минутами и имя зоны
    --      только при неизвестном zoneId (20.11.2026).
    -- Приём держит ВСЕ версии: старый клиент в канале не должен замолчать.
    if #fields ~= 8 and #fields ~= 12 and #fields ~= 13 and #fields ~= 14 then
        return Reject("field count")
    end
    local proto = fields[1]
    if proto ~= "N2" and proto ~= "N3" and proto ~= "N4"
        and proto ~= "N5" and proto ~= "N6" and proto ~= "N7" then
        return Reject("unknown protocol " .. PeerEsc(proto, 8))
    end
    -- «Компактная» раскладка: код класса/расы/фракции и хвост 'z'-значений.
    -- Одна переменная вместо сверки с каждой версией в трёх местах ниже — N7
    -- отличается от N6 только содержимым полей, а не структурой.
    local compact = (proto == "N6" or proto == "N7")
    -- Игру принимаем В ОБОИХ видах: кодом (N6) и именем (N2…N5). Признак кода —
    -- длина 1. Если такой код неизвестен, значение остаётся как есть, чтобы
    -- новая игра не потерялась до добавления в таблицу.
    local wireGame = fields[2]
    if #tostring(wireGame) == 1 then
        wireGame = PeerDecode("game", wireGame) or wireGame
    end
    if wireGame ~= db.game then
        return Reject(("game mismatch got=%s want=%s")
            :format(PeerEsc(tostring(wireGame), 12), PeerEsc(db.game, 12)))
    end
    -- Мир тоже может прийти кодом (N7): 1 байт вместо 22. PeerRealmName
    -- распознаёт код по длине и алфавиту и возвращает имя как есть, если это не
    -- код, — поэтому старый отправитель с полным именем понимается тем же
    -- вызовом. Сравнение с PlayerRealm() идёт уже по имени, иначе свой же
    -- пакет выглядел бы «чужим миром».
    local wireRealm = PeerRealmName(fields[3]) or fields[3]
    if wireRealm ~= PlayerRealm() then
        -- The channel is shared across the whole cluster (observed
        -- 09.11.2026: our CAMWOW EU5 Realm 1 PvE next to CAMWOW EU4 Realm 6
        -- PvP), so a foreign realm is expected data, not noise. It is accepted
        -- only while db.peerAllRealms is on (settings). The key already carries
        -- the realm, so two realms never overwrite each other; peerForeign lets
        -- the export separate "our realm via peer" from "another realm via peer".
        -- Only an explicit false disables it: a SavedVariables file from an
        -- older build has no key at all, and that must mean "on" (default).
        if db.peerAllRealms == false then return Reject("foreign realm disabled") end
        peerStats.foreign = peerStats.foreign + 1
    end
    local realm, name, class = wireRealm, fields[4], fields[5]
    local race, faction
    local tail = {}          -- хвост записи N6: 'z'-значения + имя зоны последним
    local tailZone           -- имя зоны из хвоста (расширение к zoneId)
    if compact then
        -- класс/раса/фракция — односимвольные коды; 'z' означает «не из
        -- таблицы», тогда значения идут текстом в хвосте (13-е поле).
        if not PeerField(name, 60) or not PeerField(realm, 100)
            or type(class) ~= "string" or #class ~= 1 then return Reject("bad name/class") end
        -- Хвост: zoneId;x;y;time;хвост — 13-е поле.
        if fields[13] and fields[13] ~= "" then
            for part in (fields[13] .. PEER_TAIL_SEP):gmatch("(.-)" .. PEER_TAIL_SEP) do
                tail[#tail + 1] = part
            end
        end
        local idx = 0
        local function takeText(code)
            if code ~= PEER_CODE_UNKNOWN then return nil end
            idx = idx + 1
            return tail[idx]
        end
        local clsText = takeText(class)
        local raceCode, facCode = fields[7], fields[8]
        if type(raceCode) ~= "string" or #raceCode ~= 1
            or type(facCode) ~= "string" or #facCode ~= 1 then return Reject("bad race/faction code") end
        local raceText = takeText(raceCode)
        local facText = takeText(facCode)
        class = PeerDecode("class", class, clsText) or ""
        race = PeerDecode("race", raceCode, raceText) or "?"
        faction = PeerDecode("faction", facCode, facText) or "?"
        if class == "" then return Reject("unknown class code") end
        -- Имя зоны — РАСШИРЕНИЕ: лежит последним в хвосте, ПОСЛЕ всех
        -- 'z'-значений. Сколько их — знаем по кодам, остальное зона.
        if #tail > idx then
            local z = tail[idx + 1]
            if z ~= "" and PeerField(z, 60) then tailZone = z end
        end
    end
    if not compact then
        if not PeerField(name, 60) or not PeerField(realm, 100)
            or not class:match("^[A-Z]+$") or #class > 32 then return Reject("bad name/class") end
        race = fields[7]
        faction = fields[8]
    end
    local level = tonumber(fields[6])
    if not level or level < 1 or level > 80 or level % 1 ~= 0 then return Reject("bad level") end
    -- Раса и фракция БОЛЬШЕ НЕ РОНЯЮТ ПАКЕТ (15.11.2026). Раньше строка
    -- "bad race" отбрасывала всю встречу целиком: живой лог терял игроков из-за
    -- одного второстепенного поля, причём под отказ попадали НАСТОЯЩИЕ значения
    -- (локализованное «Night Elf» не проходит ASCII-гейт из-за пробела, кастомные
    -- расы кириллицей — тоже). Имя, реалм, класс и уровень остаются критичными,
    -- раса с фракцией — украшение: ставим "?" и принимаем запись.
    if type(race) ~= "string" then race = "?" end
    local raceIsZone
    do
        local rawRace = race
        race, raceIsZone = NspNormalizeRace(db, race)
        if race == "?" and rawRace ~= "?" then
            peerStats.raceFixed = (peerStats.raceFixed or 0) + 1
            if not peerStats.rejectLogged.raceFixed then
                peerStats.rejectLogged.raceFixed = true
                D(("Peer race not recognised, kept as unknown: %s (from %s)")
                    :format(PeerEsc(rawRace, 30), PeerEsc(sender or "?", 40)))
            end
        end
        -- Текст, оказавшийся именем зоны, — это сдвиг разбора у старого
        -- отправителя. Не теряем его: если другого источника зоны нет, он и есть
        -- зона (так 384 записи в живом SV получили зону в поле расы).
        if raceIsZone and (not zoneName) and (not zoneId or zoneId == 0) then
            zoneName = rawRace
        end
    end
    if faction ~= "?" and faction ~= "Alliance" and faction ~= "Horde" then
        peerStats.factionFixed = (peerStats.factionFixed or 0) + 1
        faction = "?"
    end

    -- Place. zoneId — ОСНОВНОЙ ключ зоны во всех версиях, имя — расширение.
    --   N2: нет места вообще
    --   N3/N4/N5: zoneId;зона;x;y[;время] — имя полем
    --   N6:       zoneId;x;y;время[;хвост] — имя только в хвосте (расширение)
    --   N7:       как N6, но время — base36-минуты (PeerTimeValue понимает и
    --             старый unix-тайм, поэтому строка одна на оба протокола)
    local zoneId, zoneName, px, py, observedAt
    if compact then
        zoneId = tonumber(fields[9])
        if not zoneId or zoneId < 0 or zoneId % 1 ~= 0 or zoneId > 100000 then
            return Reject("bad zone id")
        end
        if fields[10] ~= "-" and fields[11] ~= "-" then
            px, py = tonumber(fields[10]), tonumber(fields[11])
            if not px or not py or px < 0 or px > 1 or py < 0 or py > 1 then
                return Reject("bad coords")
            end
        else
            px, py = nil, nil
        end
        observedAt = PeerTimeValue(fields[12])
        if not observedAt or observedAt <= 0 then return Reject("bad time") end
        if observedAt > time() + PEER_CLOCK_SKEW then return Reject("time in future") end
        -- Имя: сначала свой клиент по id (тогда оно на языке получателя), и
        -- только если id не резолвится — присланное расширение.
        zoneName = (zoneId > 0) and ZoneNameById(zoneId) or nil
        if not zoneName then zoneName = tailZone end
        if zoneName and not PeerField(zoneName, 60) then zoneName = nil end
    elseif proto ~= "N2" then
        zoneId = tonumber(fields[9])
        if not zoneId or zoneId < 0 or zoneId % 1 ~= 0 or zoneId > 100000 then
            return Reject("bad zone id")
        end
        zoneName = fields[10]
        if zoneName ~= "?" and not PeerField(zoneName, 60) then return Reject("bad zone") end
        if fields[11] ~= "-" and fields[12] ~= "-" then
            px, py = tonumber(fields[11]), tonumber(fields[12])
            if not px or not py or px < 0 or px > 1 or py < 0 or py > 1 then
                return Reject("bad coords")
            end
        else
            px, py = nil, nil
        end
        if proto == "N4" then
            observedAt = PeerTimeValue(fields[13])
            -- Время наблюдения: отрицательное или абсурдно далёкое будущее —
            -- отказ. Часы у отправителя могут врать, но не на годы; иначе
            -- один пакет «из 2030 года» навсегда перебивал бы все обновления.
            if not observedAt or observedAt <= 0 then return Reject("bad time") end
            if observedAt > time() + PEER_CLOCK_SKEW then return Reject("time in future") end
        end
        -- Локализация: если id известен получателю, его имя главнее текста.
        if zoneId > 0 then
            local localName = ZoneNameById(zoneId)
            if localName then zoneName = localName end
        end
    end
    peerStats.valid = peerStats.valid + 1
    local foreign = realm ~= PlayerRealm()
    -- observe = false: a packet is somebody else's report, not our own meeting.
    -- Without it the row claimed "seen right now" (lastSeen = receive time,
    -- count +1) and the site received a sighting we never had — the row is
    -- honest only as a peer observation, and peerAt below is what carries its
    -- time. A NEW row therefore keeps lastSeen = 0 / count = 0 (the site accepts
    -- such rows by peerAt, never as a local sighting), and a known row keeps its
    -- own lastSeen/count untouched; the place/profile gaps are still filled by
    -- the source == "peer" branch of UpsertPlayer.
    local isNew = UpsertPlayer(db, {key = name .. "-" .. realm, name = name, realm = realm,
        class = class, level = level, race = race ~= "?" and race or nil,
        observe = false,
        -- Время наблюдения из пакета N4: без него нельзя решить, обновлять ли
        -- уже известные поля. У N2/N3 времени нет — тогда nil и работает
        -- старое правило «peer только заполняет пустое».
        peerObservedAt = observedAt,
        -- the packet has only the file key; translate it once at intake so the
        -- stored record matches what a local observation would have written
        classLoc = ClassLocFromFile(class),
        faction = faction ~= "?" and faction or nil, source = "peer", silent = true,
        peerRealm = realm, peerForeign = foreign,
        -- provenance: the character whose addon sent the packet
        peerFrom = sender,
        zone = (zoneName and zoneName ~= "?") and zoneName or nil,
        zoneId = (zoneId and zoneId > 0) and zoneId or nil,
        x = px, y = py})
    if isNew then
        peerStats.received = peerStats.received + 1
    else
        -- A valid record that only refreshed a known player is the real proof
        -- the channel is alive: source="peer" never appears for those rows.
        peerStats.merged = peerStats.merged + 1
    end
    -- Ответ на НАШ запрос приходит под тегом A1 и обрабатывается в
    -- ReceivePeerAnswer — здесь счётчика по времени больше нет: с обёрткой
    -- принадлежность ответа определяется точно, по nonce.
    D(("Peer in: %s %s %d (%s) %s%s"):format(
        PeerEsc(name), PeerEsc(class, 20), level, PeerEsc(faction, 10),
        isNew and "new" or "merged",
        foreign and (" [realm=" .. PeerEsc(realm, 40) .. "]") or ""))
    PeerSync()
end

-- ── Ответ на запрос: пакет A1 (24.11.2026) ─────────────────────────────────
--   A1;<nonce>;<внутренний пакет как есть>   →  A1;k3f;N7;f;realm;rec1,rec2
--
-- Зачем отдельный тег, а не обычный N7/G7 (требование владельца): ответ
-- адресован ОДНОМУ запросившему, а N7 записывают ВСЕ клиенты канала — чужие
-- базы наполнялись бы данными, которых никто не просил. С тегом A1:
--   • клиент без поддержки отвечает «unknown protocol A1» и выбрасывает пакет;
--   • клиент с поддержкой применяет его ТОЛЬКО при совпадении nonce со своим
--     открытым запросом, иначе считает в askStray и выбрасывает.
-- Внутри — готовый обычный пакет, поэтому разбор переиспользуется целиком:
-- валидация, нормализация расы, правила провенанса и orphan-логика G7 уже
-- написаны и не дублируются.
function ReceivePeerAnswer(message, sender)
    local db = GetDB()
    local function Ignore(reason)
        peerStats.askStray = (peerStats.askStray or 0) + 1
        local tag = "answer:" .. reason
        if peerStats.rejectLogged and not peerStats.rejectLogged[tag] then
            peerStats.rejectLogged[tag] = true
            D(("Peer answer ignored: %s (from %s)"):format(reason, PeerEsc(sender or "?", 40)))
        end
        PeerSync()
    end
    if type(db) ~= "table" or not db.peerEnabled then return Ignore("sharing disabled") end
    -- Обёртка разбирается до общей проверки полей: у A1 снаружи три поля.
    local nonce, inner = message:match("^A1;([^;]*);(.+)$")
    if not nonce or not inner then return Ignore("bad wrapper") end
    if not PeerField(nonce, 8) then return Ignore("bad nonce") end
    -- ЧУЖОЙ ответ (или ответ на давно закрытый запрос) — выбрасываем. Это и
    -- есть смысл отдельного тега: третий клиент канала не должен записывать
    -- адресный ответ в свою базу.
    -- Открытых запросов может быть несколько (обход пиров по очереди), поэтому
    -- ищем nonce в таблице, а не сверяем с единственным «текущим».
    local nowT = time()
    local open = peerStats.askOpen
    if type(open) ~= "table" then return Ignore("no open requests") end
    local req = open[nonce]
    if type(req) ~= "table" then return Ignore("answer for another request") end
    if nowT > (tonumber(req.expires) or 0) then
        open[nonce] = nil
        return Ignore("answer window closed")
    end
    -- Отвечал тот, кого просили? Для вещания адресата нет. Несовпадение НЕ
    -- повод выбросить данные (ответ всё равно адресован нам по nonce), но
    -- считается: по этому счётчику видно, что кто-то ответил на чужой запрос.
    if req.target and sender and sender:lower() ~= req.target:lower() then
        peerStats.askWrongSender = (peerStats.askWrongSender or 0) + 1
    end
    req.answered = nowT
    peerStats.askLastFrom = PeerEsc(sender or "?", 40)
    -- Вложенность запрещена: A1 внутри A1 — это либо порча, либо попытка
    -- обойти проверку nonce. Внутри допустимы только «обычные» пакеты.
    if inner:sub(1, 2) == "A1" then return Ignore("nested answer") end
    if not (inner:match("^N%d;") or inner:match("^G%d;")) then
        return Ignore("bad inner packet")
    end
    peerStats.askIn = (peerStats.askIn or 0) + 1
    PeerSync()
    -- fromBatch = true: сообщение уже посчитано снаружи, второй раз seen не
    -- увеличиваем (как и у записей внутри пачки).
    return ReceivePeerMessage(inner, sender, true)
end

-- ── Приём снапшота экипировки/билда (пакет G7, 20.11.2026) ─────────────────
-- Формат: G7;game;realm;name;time;flags;gear[;talents]
--   flags: 'g' — есть упакованный gear, 't' — есть import-строка талантов
--   gear  — base64 битового потока (см. PeerGearPack), таланты — текстом
--
-- Три правила, без которых этот приём портит данные:
--   1) СВЕЖЕСТЬ: пакет применяется только если он новее уже сохранённого
--      снапшота. Иначе чужой старый пакет затрёт наш собственный инспект,
--      сделанный минуту назад.
--   2) РЕЛЕЙ ЗАПРЕЩЁН: записанный снапшот помечается from = отправитель, и
--      PeerQueueGear такой снапшот обратно не отправляет.
--   3) ПОЛОВИНЧАТЫЙ РАЗБОР ЗАПРЕЩЁН: битый gear → отказ целиком. У пакованного
--      потока нет ресинхронизации, «сколько успели» — это мусор в базе.
function ReceivePeerGear(fields, sender)
    local db = GetDB()
    -- Диагностика ТИХИХ отказов (22.11.2026). Раньше каждое условие ниже просто
    -- возвращало управление, поэтому живой SV показывал seen=79 при gearIn=0:
    -- «канал мёртв» без единой причины, и по такому набору нельзя было отличить
    -- чужой формат от нашей ошибки. Теперь причина считается, а первые три
    -- пакета кладутся в семпл — из него видно, ЧТО именно присылают пиры.
    local function Drop(reason)
        local gd = peerStats.gearDrop
        if type(gd) ~= "table" then gd = {}; peerStats.gearDrop = gd end
        gd[reason] = (gd[reason] or 0) + 1
        PeerSync()
    end
    do
        local smp = db.debug.gearSample
        if type(smp) ~= "table" then smp = {}; db.debug.gearSample = smp end
        if #smp < 3 then
            smp[#smp + 1] = ("fields=%d [1]=%s [2]=%s [3]=%s [4]=%s [5]=%s [6]=%s len7=%d len8=%d")
                :format(#fields, PeerEsc(fields[1], 6), PeerEsc(fields[2], 14),
                    PeerEsc(fields[3], 24), PeerEsc(fields[4], 40), PeerEsc(fields[5], 12),
                    PeerEsc(fields[6], 4),
                    fields[7] and #tostring(fields[7]) or -1,
                    fields[8] and #tostring(fields[8]) or -1)
        end
    end
    if not db.peerEnabled or db.peerGearOff then return end
    local game = fields[2]
    if type(game) ~= "string" or game == "" then return Drop("bad game field") end
    if #game == 1 then game = PeerDecode("game", game) or game end
    if game ~= db.game then return Drop("game " .. PeerEsc(tostring(game), 14)) end
    local realm = PeerRealmName(fields[3]) or fields[3]
    local name = fields[4]
    -- ПУСТОЙ МИР — известный баг опубликованной 1.6.0 (22.11.2026): у всех, кто на
    -- ней, GetRealmName() иногда возвращает "", и пакет уходит как "G7;f;;Имя;…".
    -- Отбивать такой пакет целиком значит терять ВСЕ снапшоты от старых клиентов:
    -- живой SV показывал kinds={G7=28} при gearDrop={"bad name/realm"=28} и
    -- gearIn=0. Принимаем, подставляя СВОЙ мир и помечая запись
    -- (peerRealmGuessed), чтобы подстановку было видно: канал общий на кластер,
    -- и чужой мир так определить нельзя — но потерять данные хуже, чем
    -- приписать запись нашему миру с явной пометкой.
    local guessedRealm = false
    if type(realm) ~= "string" or realm == "" then
        realm = PlayerRealm()
        guessedRealm = true
        peerStats.gearRealmGuessed = (peerStats.gearRealmGuessed or 0) + 1
    end
    if not PeerField(name, 60) or not PeerField(realm, 100) then return Drop("bad name/realm") end
    local ts = PeerTimeValue(fields[5])
    if not ts or ts <= 0 then return Drop("bad time") end
    if ts > time() + PEER_CLOCK_SKEW then return Drop("time future") end
    local flags = fields[6] or ""
    local wantGear = flags:find("g", 1, true) ~= nil
    local wantTalents = flags:find("t", 1, true) ~= nil
    if not wantGear and not wantTalents then return Drop("no flags") end
    local idx = 7
    local ids, ilvl, slots
    if wantGear then
        local packed = fields[idx]
        idx = idx + 1
        ids, ilvl, slots = PeerGearUnpack(packed)
        if not ids then
            peerStats.gearBad = (peerStats.gearBad or 0) + 1
            D(("Peer gear rejected: corrupted payload from %s"):format(PeerEsc(sender or "?", 40)))
            PeerSync()
            return
        end
    end
    local imp
    if wantTalents then
        local t = fields[idx]
        -- Только алфавит import-строки и разумная длина: чужой текст в этом
        -- поле не должен ни попасть в SV, ни сломать сайт.
        if type(t) == "string" and #t > 0 and #t <= 64 and t:match("^[%w+/]+$") then imp = t end
    end
    if not ids and not imp then return end
    local key = name .. "-" .. realm
    local entry = db.players and db.players[key]
    if type(entry) ~= "table" and guessedRealm then
        -- Мир подставлен нами, поэтому ключ мог не сойтись: игрок известен под
        -- ДРУГИМ миром кластера. Ищем по имени — ровно одна запись значит тот
        -- же игрок (имена в базе практически уникальны: неоднозначных 2.1%).
        -- Живой SV 22.11.2026: 68 из 68 пакетов уходили в orphan именно так.
        local found, cnt = nil, 0
        for k, p in pairs(db.players or {}) do
            if type(p) == "table" and p.name == name then
                cnt = cnt + 1
                found = k
                if cnt > 1 then break end
            end
        end
        if cnt == 1 then
            key, entry = found, db.players[found]
            peerStats.gearOrphanFixed = (peerStats.gearOrphanFixed or 0) + 1
        elseif cnt > 1 then
            -- Одно имя на нескольких мирах: приписать наугад нельзя.
            peerStats.gearAmbiguous = (peerStats.gearAmbiguous or 0) + 1
        end
    end
    -- Снапшот собирается ДО проверки строки: с 25.11.2026 он не выбрасывается,
    -- если игрока ещё нет в базе, а ждёт в orphan-буфере (см. ниже и
    -- NSP_INSPECT.BufferPeerGear). Поля «из уже известного» берутся из строки,
    -- только если она есть.
    local have = (type(entry) == "table" and type(entry.gear) == "table") and entry.gear or nil
    local haveAt = have and tonumber(have.at) or 0
    local snap = {
        at = ts,
        from = sender,                  -- релей-защита: такой снапшот не уходит
        ids = ids or (have and have.ids) or nil,
        slots = slots or (have and have.slots) or nil,
        ilvl = ilvl or (have and have.ilvl) or nil,
        imp = imp or (have and have.imp) or nil,
        -- Мир в пакете был пуст (баг 1.6.0) и подставлен наш: пометка остаётся в
        -- записи, чтобы на сайте и в разборе было видно, что мир не из пакета.
        realmGuessed = guessedRealm or nil,
    }
    if type(snap.ids) ~= "string" and type(snap.imp) ~= "string" then return end
    if type(entry) ~= "table" then
        -- Игрока ещё нет в базе. Создавать строку из одного снапшота НЕЛЬЗЯ: она
        -- придёт на сайт без класса и уровня. Но и терять снапшот незачем —
        -- G7 и запись о встрече N7 идут по каналу независимо, и снапшот часто
        -- приходит первым. Держим его 15 минут в orphan-буфере и прикрепляем,
        -- когда строка появится (замер 25.11.2026: 19 из 44 G7 уходили в orphan,
        -- — то есть 43% принятых снапшотов терялись именно так).
        peerStats.gearOrphan = (peerStats.gearOrphan or 0) + 1
        if NSP_INSPECT and type(NSP_INSPECT.BufferPeerGear) == "function" then
            local okB, buffered = pcall(NSP_INSPECT.BufferPeerGear, name, snap, realm)
            if okB and buffered then
                peerStats.gearBuffered = (peerStats.gearBuffered or 0) + 1
            end
        end
        return
    end
    if haveAt >= ts then
        peerStats.gearStale = (peerStats.gearStale or 0) + 1
        return
    end
    -- Пишем ТЕМ ЖЕ путём, что и собственный инспект: он ведёт кольцо вытеснения
    -- (db.gearRing). Обойти его — значит растить файл без границы.
    local okStore = false
    if NSP_INSPECT and type(NSP_INSPECT.Store) == "function" then
        local okc, res = pcall(NSP_INSPECT.Store, key, snap)
        okStore = okc and res and true or false
    end
    if not okStore then entry.gear = snap end
    peerStats.gearIn = (peerStats.gearIn or 0) + 1
    D(("Peer gear in: %s %s %s from %s"):format(
        PeerEsc(name, 40), PeerEsc(game, 12),
        (snap.ids and ((snap.slots or "?") .. " slots") or "talents only"),
        PeerEsc(sender or "?", 40)))
    PeerSync()
end

local function JoinPeerChannel()
    local db = GetDB()
    if not db.peerEnabled then return end
    local own = PeerChannelName()
    -- nil = channels not ready yet (early after login), 0 = not joined
    local channel = GetChannelName(own)
    if not channel or channel == 0 then
        -- Результат входа ПРОВЕРЯЕТСЯ: раньше возврат JoinChannelByName молча
        -- игнорировался, и серверный отказ («not allowed to join channel»)
        -- оставлял аддон без канала и без единой записи о причине. Теперь
        -- отказ виден в db.debug.peer.join (по нему и нашли фракционную
        -- блокировку 10.11.2026).
        local okJoin, joined = pcall(JoinChannelByName, own, nil, nil, false)
        db.debug = db.debug or {}
        db.debug.peerJoin = {
            channel = own,
            ok = okJoin and joined and true or false,
            result = okJoin and tostring(joined) or tostring(joined),
            at = time(),
        }
    end
    -- Выходим из устаревших каналов, если персонаж остался в них с прошлых
    -- сессий (общий "nearbyspydata" и его фракционные варианты с подчёркиванием
    -- — клиент такое имя не принимает). Пока membership есть, сервер отвечает
    -- NOT_ALLOWED_IN_CHANNEL и печатает это игроку в чат. Один раз за сессию.
    if not peerStats.leftStale then
        peerStats.leftStale = {}
        for _, legacy in ipairs(PEER_CHANNEL_LEGACY) do
            local stale = GetChannelName(legacy)
            if stale and stale ~= 0 and LeaveChannelByName then
                peerStats.leftStale[#peerStats.leftStale + 1] = legacy
                pcall(LeaveChannelByName, legacy)
            end
        end
    end
    if not peerChatVisible and ChatFrame_RemoveChannel then
        for i = 1, 10 do
            local chat = _G["ChatFrame" .. i]
            if chat then ChatFrame_RemoveChannel(chat, own) end
        end
    end
end

-- Channel state as the client sees it: id, joined or not, and the display
-- name ("N. nearbyspydata"). Logged after every join attempt — a nil/0 here
-- is the first thing to check when inbound traffic looks absent.
-- Global on purpose — a local function would cost a slot in the main chunk.
function PeerLogChannel(what)
    local ch = GetChannelName(PeerChannelName())
    D(("Peer %s: channel=%s"):format(what, tostring(ch)))
    PeerSync()
end

local function SetPeerChatVisible(visible)
    if visible and (not DEFAULT_CHAT_FRAME or not DEFAULT_CHAT_FRAME.AddMessage) then return false end
    peerChatVisible = visible
    return true
end

-- Race -> faction (file keys from UnitRace: Human, Orc, ...)
local RACE_FACTION = {
    Human = "Alliance", Dwarf = "Alliance", NightElf = "Alliance", Gnome = "Alliance",
    Orc = "Horde", Scourge = "Horde", Tauren = "Horde", Troll = "Horde",
}

-- localized race name (from /who) -> file key: ruRU + enUS
local RACE_LOCALE = {
    ["Человек"] = "Human", ["Human"] = "Human",
    ["Дворф"] = "Dwarf", ["Dwarf"] = "Dwarf",
    ["Ночной эльф"] = "NightElf", ["Night Elf"] = "NightElf",
    ["Гном"] = "Gnome", ["Gnome"] = "Gnome",
    ["Орк"] = "Orc", ["Orc"] = "Orc",
    ["Нежить"] = "Scourge", ["Undead"] = "Scourge", ["Forsaken"] = "Scourge",
    ["Таурен"] = "Tauren", ["Tauren"] = "Tauren",
    ["Тролль"] = "Troll", ["Troll"] = "Troll",
    -- German and French clients (24.11.2026). Strings come from DB2 ChrRaces,
    -- field Name_lang (wago.tools export) — the very strings the client shows
    -- in the /who race column and the server expects in the filter. Source
    -- check: the Russian values of the same export match the table above
    -- character for character.
    -- Female forms (Zwergin, Nachtelfe, Untote; Humaine, Naine, Orque,
    -- Morte-vivante, Taurène, Trollesse) are listed HERE FOR NORMALISATION
    -- ONLY: UnitRace returns the race name with the unit's gender, so without
    -- them those records would be stored as raw text instead of a file key.
    -- They never go into a race query — that uses the canon from
    -- RACE_BY_LOCALE, exactly like the Russian «Орчиха»/«Гномка».
    ["Mensch"] = "Human", ["Zwerg"] = "Dwarf", ["Zwergin"] = "Dwarf",
    ["Nachtelf"] = "NightElf", ["Nachtelfe"] = "NightElf", ["Gnom"] = "Gnome",
    ["Untoter"] = "Scourge", ["Untote"] = "Scourge",
    ["Humain"] = "Human", ["Humaine"] = "Human",
    ["Nain"] = "Dwarf", ["Naine"] = "Dwarf",
    ["Elfe de la nuit"] = "NightElf",
    ["Mort-vivant"] = "Scourge", ["Morte-vivante"] = "Scourge",
    ["Taurène"] = "Tauren", ["Trollesse"] = "Troll",
    -- Кастомная раса сервера (Skyborne) на немецком клиенте. Написание взято
    -- из живого SavedVariables 24.11.2026 (debug.whoSampleNoRace:
    -- "raceStr=Himmelsgeborener des Hohen Ordens; ... classStr=Druide;
    -- area=Der Friedhof \"Stille Gärten\"") — сервер прислал его сам, это не
    -- перевод. Без этой строки такие записи теряли расу (debug.raceUnresolved).
    ["Himmelsgeborener des Hohen Ordens"] = "Skyborne",
}

-- LearnedFactions — НАБОР фракций, в которых наблюдалась раса.

-- ── Раса: нормализация и защита от сдвига разбора (15.11.2026) ─────────────
-- Симптом: 384 записи в живом SV с именем зоны в поле расы ("Duskwood",
-- "Wetlands", "Ironforge", …). Корень — кодирование: отсутствие значения шло
-- кодом 'z' (тем же, что «значение текстом в хвосте») без самого текста, и
-- приёмник забирал следующим текстом хвоста имя зоны. Подробно — PEER_CODE_NONE.
--
-- Правила нормализации:
--  1) известное значение приводим к ФАЙЛ-КЛЮЧУ («Night Elf» / «Ночной эльф» ->
--     NightElf): база и выгрузка на сайт ждут файл-ключи, иначе одна раса
--     распадается на несколько строк статистики;
--  2) нераспознанный текст, совпавший с известным именем ЗОНЫ, — не раса (это
--     и есть сдвиг от старого отправителя): ставим «?»;
--  3) прочий текст принимаем как есть: кастомная раса, которой ещё нет в
--     таблицах, не должна теряться.
-- strict=true (только для записей из канала при миграции): любой нераспознанный
-- текст считается мусором — у локальных источников раса всегда файл-ключ от
-- UnitRace, поэтому текст вне таблиц приходит только сдвигом разбора.
-- Глобальные функции: главный чанк стоит на 193-м из 200 локалов.
function NspZoneNameSet(db)
    if type(db) ~= "table" then return {} end
    db.learn = db.learn or {}
    local set = db.learn.zoneNames
    if type(set) ~= "table" then set = {}; db.learn.zoneNames = set end
    return set
end

function NspNormalizeRace(db, race, strict)
    if type(race) ~= "string" or race == "" or race == "?" then return "?" end
    if NSP_PEER_DECODE.race[race] then return race end   -- уже файл-ключ
    local canon = RACE_LOCALE[race]
    if canon then return canon end
    local learn = type(db) == "table" and db.learn or nil
    local byLoc = learn and learn.raceLoc2File
    if type(byLoc) == "table" and byLoc[race] then return byLoc[race] end
    if NspZoneNameSet(db)[race] then return "?", true end  -- имя зоны, а не раса
    if strict then return "?" end
    if PeerField(race, 32) then return race end            -- новая кастомная раса
    return "?"
end

-- Одноразовая чистка базы от мусора в поле расы. Идёт вместе с миграцией имён
-- (GetDB), считает результат в db.debug, чтобы это было видно, а не «само
-- прошло». Словарь зон собирается из самой базы: имена зон, которые уже есть
-- в записях, — единственный локальный справочник, доступный без /who.
function NspMigrateRaces(db)
    if type(db) ~= "table" or db.migRaces == 2 then return end
    local zones = NspZoneNameSet(db)
    for _, p in pairs(db.players) do
        if type(p) == "table" and type(p.zone) == "string"
            and p.zone ~= "" and p.zone ~= "?" then
            zones[p.zone] = true
        end
    end
    local junk, canonical = 0, 0
    for _, p in pairs(db.players) do
        if type(p) == "table" and p.race ~= nil then
            local fixed = NspNormalizeRace(db, p.race, p.source == "peer")
            if fixed ~= p.race then
                if fixed == "?" then junk = junk + 1 else canonical = canonical + 1 end
                p.race = (fixed ~= "?") and fixed or nil
            end
        end
    end
    db.migRaces = 2
    if junk > 0 or canonical > 0 then
        db.debug.raceJunkCleared = junk
        db.debug.raceCanonicalised = canonical
        R(("race migration: %d junk cleared, %d canonicalised"):format(junk, canonical))
    end
end

-- ── Миграция записей без мира (22.11.2026) ─────────────────────────────────
-- GetRealmName() в клиенте Forever иногда возвращает "" — и `x or fallback`,
-- потому что пустая строка в Lua истинна, оставлял realm="". Такие записи
-- получили ключ "Имя-" (живой SV: 729 штук, у 54 имён был дубль с настоящим
-- миром) и, что хуже, снапшоты экипировки уходили в канал пакетами
-- "G7;f;;Имя;…", которые отбивал каждый получатель.
--
-- Миграция одноразовая (флаг db.realmFixed) и НЕ выдумывает мир: если клиент и
-- SavedVariables не дают непустого имени мира, записи остаются как есть.
-- Глобальная функция, а не local: главный чанк стоит у потолка Lua 5.1 в 200
-- локалах (замер: 195).
function NspMigrateRealms(db)
    if type(db) ~= "table" or db.realmFixed then return end
    local r = GetRealmName and GetRealmName() or nil
    if type(r) ~= "string" or r == "" then r = db.realm end
    if type(r) ~= "string" or r == "" or r == "?" then return end
    if type(db.players) ~= "table" then return end
    db.realmFixed = true

    local out, fixed, merged = {}, 0, 0
    for k, p in pairs(db.players) do
        if type(p) == "table" and type(p.name) == "string" and p.name ~= "" then
            local pr = p.realm
            if type(pr) ~= "string" or pr == "" or pr == "?" then
                p.realm = r
                fixed = fixed + 1
            end
            local nk = p.name .. "-" .. p.realm
            local ex = out[nk]
            if ex then
                -- Тот же игрок уже есть под правильным ключом: сливаем, не теряя
                -- ни встреч, ни снимков. Счётчик встреч складываем, границы
                -- времени берём крайние, пустые поля заполняем.
                ex.count = (ex.count or 0) + (p.count or 0)
                local f1, f2 = tonumber(ex.firstSeen), tonumber(p.firstSeen)
                if f2 and f2 > 0 and (not f1 or f1 <= 0 or f2 < f1) then ex.firstSeen = f2 end
                local l1, l2 = tonumber(ex.lastSeen), tonumber(p.lastSeen)
                if l2 and l2 > 0 and (not l1 or l2 > l1) then ex.lastSeen = l2 end
                for _, f in ipairs({"class", "race", "faction", "zone",
                        "zoneId", "guid", "x", "y", "peerAt", "peerFrom", "peerRealm"}) do
                    if (ex[f] == nil or ex[f] == "") and p[f] ~= nil and p[f] ~= "" then
                        ex[f] = p[f]
                    end
                end
                -- Снимок экипировки: берём более свежий из двух.
                local g1, g2 = ex.gear, p.gear
                if type(g2) == "table" and (type(g1) ~= "table"
                    or (tonumber(g2.at) or 0) > (tonumber(g1.at) or 0)) then
                    ex.gear = g2
                end
                merged = merged + 1
            else
                out[nk] = p
            end
        elseif type(p) == "table" then
            db.debug.realmMigDropped = (db.debug.realmMigDropped or 0) + 1
        end
    end
    db.players = out
    if fixed > 0 or merged > 0 then
        db.debug.realmMigFixed = fixed
        db.debug.realmMigMerged = merged
        R(("realm migration: %d records got %s, %d merged"):format(fixed, r, merged))
    end
end

-- ── Чистка db.debug от ключей, которых код больше не пишет (23.11.2026) ─────
-- SavedVariables МЕРЖАТСЯ: ключ, записанный прошлой версией аддона, остаётся в
-- файле навсегда — удаление кода его не убирает. Живой SV держал 98 КБ debug,
-- из которых ~70 КБ — дампы снятой пробы (/nspy talex, /nspy inspecttest:
-- talentTrees, talentTruth, talentSolve, inspect, players, playerOrder), плюс
-- мусор от давно снятых фич (cv_nameplateShow*).
--
-- Миграция одноразовая по номеру версии списка (db.debugPruned): список живых
-- счётчиков со временем меняется, и поднять номер дешевле, чем заводить новую
-- функцию. Удаляется только то, что код текущей версии не пишет: любой ключ
-- вне белого списка. db.debug не содержит ничего, кроме диагностики — рабочие
-- данные (players, world, itemNames, learn) лежат в корне db и не трогаются.
--
-- Список обязан совпадать с тем, что код реально пишет: за этим следит
-- tests/test_debug_prune.py (грепает все *.lua и падает при расхождении в обе
-- стороны — новый счётчик без записи в списке и мёртвый ключ в списке).
-- Глобальная функция, а не local: главный чанк стоит у потолка Lua 5.1 в 200
-- локалах.
NSP_DEBUG_PRUNE_VERSION = 2
function NspPruneDebug(db)
    if type(db) ~= "table" then return end
    if db.debugPruned == NSP_DEBUG_PRUNE_VERSION then return end
    if type(db.debug) ~= "table" then
        db.debug = {}
        db.debugPruned = NSP_DEBUG_PRUNE_VERSION
        return
    end
    local keep = {
        -- transport: peer channel + chat send
        peer = true, peerJoin = true, peerDrain = true, peerGate = true,
        -- транспорт обмена (26.11.2026): каким путём ушёл пакет и
        -- зарегистрировался ли префикс аддон-сообщений. Без них «отправок нет»
        -- не отличить от «префикс не встал».
        peerTransport = true, prefix = true,
        -- блокировки за СЕССИЮ (26.11.2026), рядом с накопительными peerGate и
        -- blocked: без них вопрос «проблема сейчас или остаток прошлых сессий»
        -- не имеет ответа
        gateSession = true, blockedSession = true,
        peerSenders = true, peerSendError = true, peerCommaStripped = true,
        lastDrainWhy = true, sendRet = true, sendRetAt = true,
        -- client gate (ADDON_ACTION_BLOCKED) and throttling
        blocked = true, blockedOther = true, blockedAt = true, blockedEvent = true,
        gateWhy = true, kbLockdown = true, kbLockdownLogged = true,
        -- errors: the support entry point
        err = true, errAt = true, errCount = true, errLast = true,
        lastErrorMsg = true, printRing = true, msgLog = true,
        -- /who: scan, throttle, gate probe
        whoResults = true, whoAdded = true, whoSoft = true, whoSample = true,
        whoSampleNoRace = true, whoThrottled = true, whoTest = true,
        -- passive inspects and gear snapshots
        inspectQueue = true, inspectTotal = true, gearSample = true,
        -- обратная миграция кольца вытеснения (25.11.2026): сколько снимков
        -- было ВНЕ gearRing и потому не вытеснялось никогда
        ringBackfilled = true,
        -- session/digest counters
        ticks = true, lastTickAt = true, lastPlayers = true, lastPlates = true,
        addedEvents = true, src = true,
        -- world data (vendors, fish, guild roster) and zone dictionary
        vendorsDropped = true, fishDropped = true, guildAdded = true,
        guildOnline = true, guildSeen = true, zoneMap = true,
        itemNamesRun = true, itemStatsKeys = true, scanErr = true,
        -- one-time migrations and their counters
        migrationDropped = true, realmMigFixed = true, realmMigMerged = true,
        realmMigDropped = true, raceCanonicalised = true, raceJunkCleared = true,
        raceSamples = true, raceEmpty = true, raceUnresolved = true,
        -- переходный механизм досстановления zoneId по имени зоны (24.11.2026):
        -- счётчик показывает, что механизм ещё нужен; когда рост прекратится —
        -- его пора убирать (см. NspResolveZoneId)
        zoneResolved = true,
        -- разовый проход «zoneId по тексту зоны» и след снятой API-пробы
        -- (25.11.2026): счётчики исправленных/досстановленных id, отметка о
        -- вычистке probe
        zoneIdFixed = true, zoneIdAdded = true, probePruned = true,
        cvarErr = true, hardcoreDeathCount = true, hardcoreDeathSamples = true,
        pruned = true, prunedAt = true,
        -- this migration's own bookkeeping
        debugPrunedCount = true, debugPrunedAt = true,
        -- позиционная схема записей: сколько перенесено и была ли ошибка
        recMigrated = true, recMigrateErr = true,
    }
    local dropped, names = 0, {}
    for k in pairs(db.debug) do
        if not keep[k] then
            db.debug[k] = nil
            dropped = dropped + 1
            if #names < 12 then names[#names + 1] = tostring(k) end
        end
    end
    db.debugPruned = NSP_DEBUG_PRUNE_VERSION
    if dropped > 0 then
        db.debug.debugPrunedCount = (db.debug.debugPrunedCount or 0) + dropped
        db.debug.debugPrunedAt = time()
        R(("debug prune v%d: %d key(s) removed [%s]")
            :format(NSP_DEBUG_PRUNE_VERSION, dropped, table.concat(names, ", ")))
    end
end

-- Раньше хранилась ОДНА фракция на расу (db.learn.raceFaction), и это ломало
-- кастомные расы: Skyborne есть и у Альянса, и у Орды (в базе сайта
-- Skyborne/Alliance 698 + Skyborne/Horde 1, то есть раса не одноместная).
-- Одна фракция в мапе означала, что фильтр выкидывает половину запросов:
-- скан Орды вообще не спрашивал р-"Небеснорожденный", потому что последним
-- наблюдением там оказался Альянс. Хуже: в ответе /who фракция ВЫВОДИЛАСЬ из
-- расы, поэтому ордынский Skyborne записывался как альянсовый — данные на
-- сайте тоже кривились.
--
-- Возвращает set {Alliance=true, Horde=true} или nil (раса не наблюдалась).
-- Старую мапу raceFaction читаем как набор из одного элемента — миграция без
-- правки SavedVariables.
local function LearnedFactions(db, raceFile)
    if not raceFile or raceFile == "" then return nil end
    local learn = db and db.learn
    if not learn then return nil end
    local set = learn.raceFactions and learn.raceFactions[raceFile]
    if set then return set end
    local one = learn.raceFaction and learn.raceFaction[raceFile]
    if one and one ~= "" and one ~= "Unknown" then return { [one] = true } end
    return nil
end

-- CountSet — сколько элементов в set-таблице.
local function CountSet(set)
    local n = 0
    for _ in pairs(set) do n = n + 1 end
    return n
end

-- Self-learning of races/factions (server custom races):
-- from unit detections we learn "localized race → file key" and the SET of
-- factions the race was seen in, then apply them to /who entries.
-- Stored in SavedVariables (db.learn).
local function LearnRace(db, raceLoc, raceFile, faction)
    db.learn = db.learn or {}
    if raceLoc and raceLoc ~= "" and raceFile and raceFile ~= "" then
        db.learn.raceLoc2File = db.learn.raceLoc2File or {}
        db.learn.raceLoc2File[raceLoc] = raceFile
    end
    if raceFile and raceFile ~= "" and faction and faction ~= "Unknown" and faction ~= "" then
        db.learn.raceFactions = db.learn.raceFactions or {}
        local set = db.learn.raceFactions[raceFile]
        if not set then set = {} db.learn.raceFactions[raceFile] = set end
        set[faction] = true
        -- старую мапу держим согласованной: другие места и прошлые SV её читают
        db.learn.raceFaction = db.learn.raceFaction or {}
        if CountSet(set) == 1 then
            db.learn.raceFaction[raceFile] = faction
        else
            db.learn.raceFaction[raceFile] = nil  -- кросс-фракционная: одной фракции нет
        end
    end
end

-- Faction: for enemy players UnitFactionGroup may be empty,
-- then infer "opposite of ours" via UnitCanAttack.
local function GetFaction(unit)
    local ok, fg = pcall(UnitFactionGroup, unit)
    if ok and fg and fg ~= "Neutral" then
        return fg
    end
    local okA, canAttack = pcall(UnitCanAttack, "player", unit)
    if okA and canAttack then
        local own = UnitFactionGroup("player")
        if own == "Alliance" then return "Horde" end
        if own == "Horde" then return "Alliance" end
    end
    return "Unknown"
end

local function Record(unit)
    if not unit or not UnitExists(unit) or not UnitIsPlayer(unit) then return end
    if UnitIsUnit(unit, "player") then return end

    local name, surname = UnitName(unit)
    if not name or name == "" then return end
    -- Клиент отдаёт ЛОКАЛИЗОВАННУЮ заглушку («Неизвестно» / «Unknown») для
    -- юнита, чьё имя недоступно. Такая запись — мусор: на сайте появлялся
    -- «игрок» по имени Неизвестно (нашёлся в БД 09.11.2026 как Skyborne/Horde,
    -- и именно из-за него казалось, что Skyborne есть у Орды). UNKNOWNOBJECT —
    -- стандартный глобал клиента, поэтому проверка работает на любом языке.
    local unknown = _G.UNKNOWNOBJECT
    if unknown and name == unknown then return end
    -- Camelot: the "realm" from UnitName is the surname of a two-word name — join them
    if surname and surname ~= "" then
        name = name .. " " .. surname
    end
    local realm = PlayerRealm()

    local db = GetDB()
    local okC, classLoc, classFile = pcall(UnitClass, unit)
    if not okC then classLoc, classFile = nil, nil end
    local okL, level = pcall(UnitLevel, unit)
    if okL and level and level < 0 then level = nil elseif not okL then level = nil end
    -- race: UnitRace returns (localized name, file key)
    local raceFile = nil
    local okR, raceLoc, raceFileRet = pcall(UnitRace, unit)
    if okR then raceFile = raceFileRet end
    local faction = GetFaction(unit)
    if (not faction or faction == "Unknown") and raceFile then
        local set = LearnedFactions(db, raceFile)
        local learned = (set and CountSet(set) == 1) and next(set) or nil
        faction = learned or RACE_FACTION[raceFile] or faction
    end
    LearnRace(db, raceLoc, raceFile, faction)

    -- coordinates: the unit's real ones first, else the player approximation.
    -- Remember WHICH of the two it was: only the unit's own point may be shared
    -- with peers. The fallback is where WE stand, and passing it off as the
    -- player's position put strangers on our own map spot.
    local okP, x, y = pcall(UnitPosition, unit)
    local coordsFromUnit = okP and x ~= nil and y ~= nil
    if not coordsFromUnit then
        x, y = PlayerXY()
    end

    UpsertPlayer(db, {
        key = name .. "-" .. realm,
        name = name,
        realm = realm,
        class = classFile,
        classLoc = classLoc,
        level = level,
        faction = faction,
        race = raceFile,
        guid = UnitGUID(unit),
        zone = PlayerZone(),
        zoneId = PlayerZoneId(),
        coordsFromUnit = coordsFromUnit and true or nil,
        x = x,
        y = y,
        source = "unit",
    })

    -- Passive inspection (1.6.0): ask for this player's gear and talent build
    -- in the background. Request() is cheap and idempotent — the real
    -- NotifyInspect is queued and paced by NSP_INSPECT, because the server
    -- drops inspect data when requests are flooded.
    if NSP_INSPECT and type(NSP_INSPECT.Request) == "function" then
        local okI, errI = pcall(NSP_INSPECT.Request, unit, name .. "-" .. realm)
        if not okI then DbgErr("inspectRequest", errI) end
    end
end

-- ============ passive world collection (1.5.0 — main mode) ============
-- Programmatic /who is dead since build 70291 (hardware gate in C++, whoprime 0/17) —
-- the world feeds the database: mouseover, party, guild, chat. All with no
-- user action. /who remains as the assisted manual mode (/nspy suggest).

-- party/raid: GROUP_ROSTER_UPDATE is spammy while a raid forms — throttle the pass
local lastGroupScan = 0
local function RecordGroup()
    local nowT = time()
    if nowT - lastGroupScan < NSP_CONST.GROUP_TROTTLE then return end
    lastGroupScan = nowT
    for i = 1, 4 do pcall(Record, "party" .. i) end
    for i = 1, 40 do pcall(Record, "raid" .. i) end
end

-- guild: the roster gives level/class/zone of all guildmates — a rich slice
local function RecordGuild()
    if not IsInGuild or not IsInGuild() then return end
    if not GetNumGuildMembers or not GetGuildRosterInfo then return end
    local n = GetNumGuildMembers() or 0
    if n <= 0 then return end
    local db = GetDB()
    local realm = PlayerRealm()
    local faction = GetFaction("player")  -- own guild = own faction
    local added, onlineN = 0, 0
    for i = 1, n do
        -- signature: name, rank, rankIdx, level, classLoc, zone, note, onote,
        -- online, status, classFile, achPts, achRank, mobile, soR, rep, guid
        local ok, name, _, _, level, classLoc, zone, _, _, online, _, classFile, _, _, _, _, _, guid =
            pcall(GetGuildRosterInfo, i)
        if ok and name and name ~= "" then
            name = name:match("^([^%-]+)%-") or name  -- strip "Name-Realm"
            -- online (9th return) separates a real sighting from a roster row:
            -- offline guildmates must not refresh lastSeen/count. A client that
            -- doesn't return the flag (nil) keeps the old behaviour.
            local present = online ~= false
            if present then onlineN = onlineN + 1 end
            if UpsertPlayer(db, {
                key = name .. "-" .. realm,
                name = name,
                realm = realm,
                class = classFile or ClassFileFromLocalized(classLoc),
                classLoc = classLoc,
                level = level,
                faction = faction,
                guid = guid,
                -- roster zone is the player's current zone only while online
                zone = (present and zone ~= "") and zone or nil,
                source = "guild",
                silent = true,  -- the roster comes in hundreds — don't spam chat
                observe = present,  -- offline: enrich the profile, don't claim a meeting
            }) then added = added + 1 end
        end
    end
    db.debug.guildSeen = n
    db.debug.guildOnline = onlineN
    db.debug.guildAdded = (db.debug.guildAdded or 0) + added
end

local function RequestGuildRoster()
    pcall(function()
        if C_GuildInfo and C_GuildInfo.GuildRoster then
            C_GuildInfo.GuildRoster()
        elseif GuildRoster then
            GuildRoster()
        end
    end)
end

-- ============ /who zone scan ============
-- The server returns at most 50 rows per query, so a wide reply must be split.
-- Two tiers: (1) by CLASS — the filter that works on every client;
-- (2) by LEVEL RANGE — a class slice that still overflows is halved
-- recursively until each part fits under the cap (down to a single level).
-- Levels do filter (measured: at most 41 players per class per level, so
-- level+class always fits), but the guard below keeps the scan honest if a
-- future build stops honouring ranges.

-- Level ceiling for /who scans, per game.
-- Do NOT derive this from the database: a ceiling computed as "max level seen,
-- rounded up to 10" can never grow past what the scan itself collected — to
-- find the first level-31 player you must already scan to 31. That deadlock is
-- exactly why the ceiling sat at 30 (05.11.2026). It is also why
-- GetMaxPlayerLevel is not the source of truth: on the Forever client it
-- reports the engine ceiling, which does not track the realm cap.
-- Fixed cap per game instead (user decision 05.11.2026: "no restriction now,
-- the ceiling is level 60").
local LEVEL_CAP = { forever = 60, classic_era = 60, retail = 80 }

local function MaxLevel()
    local game = "forever"
    local okDb, d = pcall(GetDB)
    if okDb and type(d) == "table" and type(d.game) == "string" and d.game ~= "" then
        game = d.game
    end
    return LEVEL_CAP[game] or 60
end

local whoShownByMe = {}    -- frames we showed to send /who
local whoHiddenPanels = {} -- foreign LFG panels hidden by us (HideWhoFrame will restore them)

local function EnsureWhoVisible()
    -- whoever is open — remember; HideWhoFrame removes only what we showed.
    -- WhoFrame does not exist in this client (08.10 test: empty tree) —
    -- take the real parent of the WhoFrameEditBox input
    pcall(function()
        local f = WhoFrame or (WhoFrameEditBox and WhoFrameEditBox:GetParent())
        while f and f.Show do
            if not f:IsShown() then
                f:Show()
                whoShownByMe[f] = true
            end
            f = f:GetParent()
        end
    end)
    -- 08.10: user complaint — opening shows the "dungeon finder" tab instead of
    -- players. Switch the tab: click LFGParentFrame tabs until the named foreign
    -- panels (Listing/Browse) go dark — that's the who tab; then mute leftovers
    -- and bring the who panel back if the tab removed it.
    pcall(function()
        -- Switching to the who tab via the client's GLOBAL function (08.10, exact
        -- build 1.60.1.70205 analyzed from sources):
        --   tabs: 1=Listing, 2=Browse, 3=Who;
        --   window OnShow itself restores the previous/first tab (hence "first of three");
        --   clicking the tabs themselves fails — the Templates.lua mixin calls local
        --   LFGParentFrame_SetActiveTab, unreachable from another file → nil;
        --   LFGParentFrameTab3_OnClick() — the official path: SetTab(3) + show
        --   LFGWhoListFrame + hide Listing/Browse + tab highlight.
        if type(LFGParentFrameTab3_OnClick) == "function" then
            LFGParentFrameTab3_OnClick()
        end
    end)
    pcall(function()
        -- fallback in case the global function is missing: mute foreign panels
        -- and guarantee the who panel is shown
        for _, pn in ipairs({ "LFGListingFrame", "LFGBrowseFrame" }) do
            local p = _G[pn]
            if p and p.Hide and p:IsShown() then
                p:Hide()
                whoHiddenPanels[p] = true
            end
        end
        local who = LFGWhoListFrame or (WhoFrameEditBox and WhoFrameEditBox:GetParent())
        if who and who.Show and not who:IsShown() then
            who:Show()
            whoShownByMe[who] = true
        end
    end)
end

local function HideWhoFrame()
    D("who window: HideWhoFrame called")
    pcall(function()
        for f in pairs(whoShownByMe) do
            if f.Hide then f:Hide() end
        end
    end)
    whoShownByMe = {}
    pcall(function()
        for f in pairs(whoHiddenPanels) do
            if f.Show then f:Show() end
        end
    end)
    whoHiddenPanels = {}
    if WhoFrame and WhoFrame:IsShown() then WhoFrame:Hide() end
end

-- ============ /nspy whotest — is programmatic /who still possible? ============
-- The client blocks programmatic who since build 70291: SendWho is gated to a
-- hardware click, and the click path stopped producing replies. Builds change,
-- so this probe measures the CURRENT build instead of trusting the note. It is
-- diagnostic only and never runs on its own.
--
-- Three paths, deliberately without SetFocus: focusing an EditBox
-- programmatically has crashed this client (CSimpleEditBox code=11).
-- The query is configurable: /nspy whotest 10-15, /nspy whotest gap 120 5 10-15
-- three paths; with a range given all three use it, so the paths are compared
-- on the same query
local WHO_TEST_DEFAULT_RANGES = { "1-10", "11-20", "21-30" }
local function WhoTestStepsFor(range, reopen)
    if range then
        return {
            { key = "button",  query = range, reopen = reopen },
            { key = "handler", query = range },
            { key = "api",     query = range },
        }
    end
    return {
        { key = "button",  query = WHO_TEST_DEFAULT_RANGES[1], reopen = reopen },  -- Click("LeftButton") on the magnifier
        { key = "handler", query = WHO_TEST_DEFAULT_RANGES[2] },  -- the button's own OnClick script
        { key = "api",     query = WHO_TEST_DEFAULT_RANGES[3] },  -- C_FriendList.SendWho
    }
end
local WHO_TEST_WAIT = 15   -- seconds to wait for a reply before the next step

local function WhoTestSay(line)
    P("whotest: " .. line)
    R("whotest: " .. line)   -- also into the SV ring: readable after logout
end

local WhoTestFinish, FinishWhoTestCleanup   -- forward: used before their definitions

-- Force the who window through a real Hide→Show cycle and report what moved.
-- Needed because the client only accepts a programmatic search right after the
-- window has actually been shown: measured 06.11.2026, the first click after a
-- show goes through and every next one is refused, while the box still takes
-- the text (so it looks like "typed but the search never ran").
local function WhoTestForceReopen()
    local hid, shown, chainLen = 0, 0, 0
    pcall(function()
        local f = WhoFrame or (WhoFrameEditBox and WhoFrameEditBox:GetParent())
        local chain = {}
        while f and f.Hide do
            chain[#chain + 1] = f
            f = f:GetParent()
        end
        chainLen = #chain
        for i = 1, #chain do
            if chain[i]:IsShown() then
                chain[i]:Hide()
                hid = hid + 1
            end
        end
        for i = #chain, 1, -1 do
            local fr = chain[i]
            if fr.Show and not fr:IsShown() then
                fr:Show()
                shown = shown + 1
            end
        end
    end)
    return hid, shown, chainLen
end

local function WhoTestSend(step)
    local q = step.query
    if step.key == "button" then
        local btn = LFGWhoListFrame and LFGWhoListFrame.WhoSearch
        if not (btn and btn.Click) then return false, "WhoSearch button not found" end
        pcall(function()
            if C_FriendList and C_FriendList.SetWhoToUi then C_FriendList.SetWhoToUi(true) end
        end)
        WHO_TEST_BOX_TEXT = nil
        WHO_TEST_REOPEN_LOG = nil
        if step.reopen then
            local hid, shown, chain = WhoTestForceReopen()
            WHO_TEST_REOPEN_LOG = ("reopen: %d frame(s) in chain, hid %d, showed %d")
                :format(chain or 0, hid or 0, shown or 0)
        end
        pcall(function() if WhoFrameEditBox then WhoFrameEditBox:SetText(q) end end)
        -- read the box back: if SetText silently fails, the click searches the
        -- PREVIOUS text and every "reply" is the old result shown again
        pcall(function()
            if WhoFrameEditBox and WhoFrameEditBox.GetText then
                WHO_TEST_BOX_TEXT = WhoFrameEditBox:GetText()
            end
        end)
        local ok, err = pcall(btn.Click, btn, "LeftButton")
        if not ok then return false, "Click raised: " .. tostring(err) end
        return true
    elseif step.key == "handler" then
        local btn = LFGWhoListFrame and LFGWhoListFrame.WhoSearch
        local h = btn and btn.GetScript and btn:GetScript("OnClick")
        if type(h) ~= "function" then return false, "the button has no OnClick script" end
        pcall(function() if WhoFrameEditBox then WhoFrameEditBox:SetText(q) end end)
        local ok, err = pcall(h, btn, "LeftButton")
        if not ok then return false, "OnClick raised: " .. tostring(err) end
        return true
    elseif step.key == "api" then
        if not (C_FriendList and C_FriendList.SendWho) then return false, "C_FriendList.SendWho is absent" end
        local ok, err = pcall(C_FriendList.SendWho, q)
        if not ok then return false, "SendWho raised: " .. tostring(err) end
        return true
    end
    return false, "unknown path"
end

function WhoTestFinish()
    local t = whoTest
    whoTest = nil
    if not t then return end
    local hits = 0
    for _, r in ipairs(t.log or {}) do
        if r.reply then hits = hits + 1 end
    end
    WhoTestSay(("done — %d of %d path(s) got a reply"):format(hits, #(t.log or {})))
    if hits == 0 then
        WhoTestSay("verdict: programmatic who is dead on this build; keep the assisted mode")
    else
        WhoTestSay("verdict: programmatic who WORKS on this build — an automatic scan is possible again")
    end
    local db = GetDB()
    db.debug.whoTest = t.log
    FinishWhoTestCleanup()
end

-- separate so the cleanup is visible and cannot be skipped by an early return
function FinishWhoTestCleanup()
    pcall(function()
        if WhoFrameEditBox then WhoFrameEditBox:SetText("") end
    end)
    pcall(HideWhoFrame)
end

local function WhoTestNext()
    local t = whoTest
    if not t then return end
    -- close out the step we were waiting on
    local prev = t.log[#t.log]
    if prev and prev.reply == nil then
        prev.reply = (t.replies > t.repliesBefore)
        prev.num = t.lastNum
        prev.sig = t.lastSig
        prev.box = prev.box or t.boxAtSend
        if prev.reply then
            -- identical player sets for two different queries = the client
            -- redrew a cached list; such a "reply" proves nothing
            local cached = false
            if prev.sig and prev.sig ~= "" then
                for i = #t.log - 1, 1, -1 do
                    local earlier = t.log[i]
                    if earlier.sig == prev.sig then cached = true break end
                end
            end
            prev.cached = cached
            WhoTestSay(("[%s] %s → REPLY %d rows%s"):format(
                prev.key, prev.query, prev.num or 0,
                cached and " (SAME players as an earlier step — cached redraw, not a real reply)" or ""))
        else
            WhoTestSay(("[%s] %s → no reply"):format(prev.key, prev.query))
        end
        -- the read-back only exists on the button path (that is where SetText
        -- matters): an empty or different box means the click searched old text
        if prev.key == "button" and tostring(prev.box or "") ~= prev.query then
            local shown = tostring(prev.box or "")
            if shown == "" then shown = "<empty>" end
            WhoTestSay(("[%s] WARNING: box contained \"%s\" but the query was \"%s\" — SetText did not land")
                :format(prev.key, shown, prev.query))
        end
        t.lastSig = nil
    end
    t.step = t.step + 1
    local step = t.steps[t.step]
    if not step then WhoTestFinish() return end
    t.repliesBefore = t.replies
    local entry = { key = step.key, query = step.query, reply = nil }
    t.log[#t.log + 1] = entry
    WHO_TEST_BOX_TEXT = nil
    EnsureWhoVisible()
    local ok, why = WhoTestSend(step)
    local wait = t.wait or WHO_TEST_WAIT
    if not ok then
        entry.reply = false
        WhoTestSay(("[%s] %s → send failed: %s"):format(step.key, step.query, tostring(why)))
        -- keep going: a missing path says nothing about the others
        t.boxAtSend = WHO_TEST_BOX_TEXT
        t.log[#t.log].box = WHO_TEST_BOX_TEXT
    else
        t.boxAtSend = WHO_TEST_BOX_TEXT
        t.log[#t.log].box = WHO_TEST_BOX_TEXT
        WhoTestSay(("sent [%s] \"%s\" (box: \"%s\"%s), waiting %ds")
            :format(step.key, step.query, tostring(WHO_TEST_BOX_TEXT or "?"),
                WHO_TEST_REOPEN_LOG and ("; " .. WHO_TEST_REOPEN_LOG) or "", wait))
    end
    C_Timer.After(wait, function() WhoTestNext() end)
end

local WHO_TEST_GAP_QUERIES = { "1-10", "11-20", "21-30", "31-40", "41-50", "51-60" }

-- Distinct queries for a cooldown run. Repeating one query is useless here:
-- an unchanged search box may just redraw the cached list, and then a "reply"
-- proves nothing about the gate. With a range given, split it into different
-- sub-windows; without one, cycle the six decades.
local function WhoTestDistinctQueries(range, count)
    local out = {}
    local lo, hi = (range or ""):match("^(%d+)%-(%d+)$")
    lo, hi = tonumber(lo), tonumber(hi)
    if lo and hi and hi > lo then
        local span = hi - lo + 1
        if count >= span then
            -- more steps than levels: fall back to a single level each, then
            -- wrap around with a shifted window so no two are identical
            for i = 1, count do
                local lvl = lo + ((i - 1) % span)
                out[i] = ("%d-%d"):format(lvl, math.min(lvl + 1, hi))
            end
        else
            -- even slices of the window, each non-empty and distinct
            local size = math.max(1, math.floor(span / count))
            for i = 1, count do
                local a = lo + (i - 1) * size
                local b = (i == count) and hi or math.min(a + size - 1, hi)
                out[i] = ("%d-%d"):format(a, b)
            end
        end
    else
        for i = 1, count do
            out[i] = WHO_TEST_GAP_QUERIES[(i - 1) % #WHO_TEST_GAP_QUERIES + 1]
        end
    end
    -- guard: if the slicing produced repeats, shift the tail (cannot happen
    -- with the math above, but a silent duplicate would poison the measurement)
    for i = 2, #out do
        if out[i] == out[i - 1] then
            local lvl = lo and (lo + ((i - 1) % math.max(1, (hi or lo) - lo + 1))) or nil
            if lvl then out[i] = ("%d-%d"):format(lvl, math.min(lvl + 1, hi)) end
        end
    end
    return out
end
local WHO_TEST_GAP_MAX = 6        -- queries in a cooldown run
local WHO_TEST_GAP_MAXWAIT = 600  -- s: cap on the gap, so the probe cannot hang
local WHO_TEST_GAP_DEFAULT = 120  -- s: gap when only a range/count is given

-- arg grammar (all parts optional):
--   [gap] [<seconds>] [<count>] [<lo>-<hi>]
--   ""                 → three paths, default ranges
--   "10-15"            → three paths, each with 10-15
--   "gap 120 5 10-15"  → five button clicks, 120 s apart, all 10-15
local function ParseWhoTestArg(arg)
    local res, gapMode = {}, false
    local words = {}
    for w in tostring(arg or ""):gmatch("%S+") do words[#words + 1] = w end
    local i = 1
    while i <= #words do
        local w = words[i]
        local lo, hi = w:match("^(%d+)%-(%d+)$")
        if w == "reopen" then
            res.reopen = true
        elseif w == "gap" then
            gapMode = true
            local n = tonumber(words[i + 1])
            if n then res.gap = n i = i + 1 end
        elseif lo then
            lo, hi = tonumber(lo), tonumber(hi)
            if lo and hi and lo >= 1 and hi <= 80 and hi > lo then
                res.range = ("%d-%d"):format(lo, hi)
            end
        else
            local n = tonumber(w)
            if n then
                if res.gap then res.count = n else res.gap = n end
            end
        end
        i = i + 1
    end
    res.gapMode = gapMode
    return res
end

local function StartWhoTest(arg)
    if whoTest then
        whoTest = nil
        FinishWhoTestCleanup()
        P("whotest: cancelled")
        return
    end
    if whoScan then
        P("whotest: stop the running scan first (/nspy who)")
        return
    end
    local btn = LFGWhoListFrame and LFGWhoListFrame.WhoSearch
    P(("whotest: build check — button=%s, OnClick=%s, SendWho=%s")
        :format(tostring(btn ~= nil and btn.Click ~= nil),
            tostring(btn ~= nil and btn.GetScript ~= nil and type(btn:GetScript("OnClick")) == "function"),
            tostring(C_FriendList ~= nil and C_FriendList.SendWho ~= nil)))

    -- "gap <seconds> [count] [range]": repeated BUTTON clicks with a fixed
    -- pause, to find out whether the block is a cooldown that expires
    -- (measured 06.11.2026: a click worked again 141 s after a blocked one).
    local a = ParseWhoTestArg(arg)
    if a.gapMode then
        local gap = math.min(math.max(a.gap or WHO_TEST_GAP_DEFAULT, 10), WHO_TEST_GAP_MAXWAIT)
        local count = math.min(math.max(a.count or 5, 2), WHO_TEST_GAP_MAX)
        local queries = WhoTestDistinctQueries(a.range, count)
        local steps = {}
        for i = 1, count do
            steps[i] = { key = "button", query = queries[i], reopen = a.reopen }
        end
        P(("whotest: cooldown run — %d button clicks, %ds apart, reopen=%s (total ~%d min)")
            :format(count, gap, tostring(a.reopen and true or false), math.floor(count * gap / 60 + 0.5)))
        P(("whotest: distinct queries — %s"):format(table.concat(queries, ", ")))
        whoTest = { step = 0, replies = 0, repliesBefore = 0, lastNum = nil, log = {},
                    steps = steps, wait = gap }
    else
        local steps = WhoTestStepsFor(a.range, a.reopen)
        if a.range then
            P(("whotest: three paths on the same query \"%s\""):format(a.range))
        end
        whoTest = { step = 0, replies = 0, repliesBefore = 0, lastNum = nil, log = {},
                    steps = steps }
    end
    WhoTestNext()
end

-- The /who zone filter token depends on the client locale:
-- enUS — z-"Zone", ruRU — з-"Зона" (Cyrillic!). With a Latin z on an RU client
-- the server silently drops the query — that's exactly why zone scans failed.
-- /who filter tokens are LOCALIZED in every locale: RU — з-/к-/р-,
-- EN — z-/c-/r-, zhCN — its own characters. The client keeps them in the
-- WHO_TAG_ZONE / WHO_TAG_CLASS / WHO_TAG_RACE globals (GlobalStrings) — read
-- from there, covers any language. Fallback — per-locale table.
local WHO_TOKEN_FALLBACK = {
    ruRU = { zone = "з-", class = "к-", race = "р-" },
    enUS = { zone = "z-", class = "c-", race = "r-" },
    enGB = { zone = "z-", class = "c-", race = "r-" },
}
local function WhoToken(globalName, key)
    local v = _G[globalName]
    if type(v) == "string" and v ~= "" then
        return v, "client"
    end
    local fb = (WHO_TOKEN_FALLBACK[GetLocale()] or {})[key]
        or ({ zone = "z-", class = "c-", race = "r-" })[key]
    return fb, "fallback"
end
local WHO_TOKEN_ZONE, WHO_TOKEN_SRC = WhoToken("WHO_TAG_ZONE", "zone")
local WHO_TOKEN_CLASS = WhoToken("WHO_TAG_CLASS", "class")
local WHO_TOKEN_RACE = WhoToken("WHO_TAG_RACE", "race")

-- localized race names for the r-"race" filter (in the client language)
local RACE_BY_LOCALE = {
    ruRU = {
        Human = "Человек", Dwarf = "Дворф", NightElf = "Ночной эльф",
        Gnome = "Гном",
        Orc = "Орк", Scourge = "Нежить", Tauren = "Таурен",
        Troll = "Тролль",
    },
    enUS = {
        Human = "Human", Dwarf = "Dwarf", NightElf = "Night Elf",
        Gnome = "Gnome",
        Orc = "Orc", Scourge = "Undead", Tauren = "Tauren",
        Troll = "Troll",
    },
    -- German and French clients (24.11.2026). Source: DB2 ChrRaces, field
    -- Name_lang (wago.tools export) — exactly the strings the client shows in
    -- the "Volk"/"race" column of the /who window and the ones the server
    -- expects in the filter. Source check: the Russian values of the same
    -- export matched the table above character for character.
    -- NOTE: German Orc is spelled «Orc», not «Ork» — that is the client string,
    -- not a typo. Female forms (Zwergin/Nachtelfe/Untote, Naine/Morte-vivante/
    -- Taurène/Trollesse) do NOT belong here: the server understands the canon,
    -- same as with the Russian «Орчиха»/«Гномка» (see RaceFilterNames).
    deDE = {
        Human = "Mensch", Dwarf = "Zwerg", NightElf = "Nachtelf",
        Gnome = "Gnom",
        Orc = "Orc", Scourge = "Untoter", Tauren = "Tauren",
        Troll = "Troll",
    },
    frFR = {
        Human = "Humain", Dwarf = "Nain", NightElf = "Elfe de la nuit",
        Gnome = "Gnome",
        Orc = "Orc", Scourge = "Mort-vivant", Tauren = "Tauren",
        Troll = "Troll",
    },
}

local function PlayerFaction()
    local ok, f = pcall(UnitFactionGroup, "player")
    if ok and (f == "Alliance" or f == "Horde") then return f end
    return nil
end

-- NameFitsLocale — написано ли имя в алфавите текущего клиента.
--
-- Зачем: db.learn.raceLoc2File — НАКОПИТЕЛЬНАЯ таблица, она собиралась и
-- русским, и английским клиентом, поэтому рядом с «Таурен» лежит «Tauren».
-- Запрос /who на русском клиенте принимает только локализованное имя, на
-- английское сервер отвечает пустым списком. Без фильтра половина расовых
-- запросов (а в плотных срезах — весь tier) уходила впустую и жгла троттлинг.
--
-- Проверка по ведущим байтам UTF-8, а не по списку слов: локализованных
-- названий рас десятки, и захардкоженный список сломался бы на первой
-- кастомной расе сервера.
-- IsFeminine — женская форма названия расы («Орчиха», «Гномка», «Ночная
-- эльфийка», «Небеснорожденная»). Нужна только как подсказка при выборе одной
-- формы кастомной расы из db.learn: канон сервера — мужская форма, как у
-- стандартных рас (raceStr=Human в ответе /who). Ошибиться здесь безопасно:
-- худший случай — одна лишняя попытка запроса, а не потеря данных.
local function IsFeminine(name)
    if type(name) ~= "string" then return false end
    local low = name:lower()
    -- окончание может быть не в конце строки: «НебеснорожденнАЯ из Высшего
    -- ордена» — прилагательное стоит первым словом. Поэтому проверяем и
    -- конец слова (перед пробелом), а не только конец строки.
    local function ends(tail)
        return low:match(tail .. "$") ~= nil or low:match(tail .. "%s") ~= nil
    end
    return ends("ая") or ends("яя") or ends("иха") or ends("ка")
        or ends("ица") or ends("ница")
end

local function NameFitsLocale(name, loc)
    if type(name) ~= "string" or name == "" then return false end
    loc = loc or (GetLocale and GetLocale()) or ""
    if loc == "enUS" or loc == "enGB" or loc == "enTW" then
        return name:find("[\128-\255]") == nil  -- только ASCII
    elseif loc == "deDE" or loc == "frFR" then
        -- Latin locales: umlauts and accents (ä ö ü ß é è) belong here, while
        -- Cyrillic (leading bytes D0/D1) and CJK (E3..ED) arrive only from a
        -- db.learn table accumulated in someone else's locale. The gate is
        -- needed exactly here: without it the German client queued
        -- р-"Таурен"/р-"Нежить" left over from the Russian session, the server
        -- answered with an empty list and the magnifier clicks were wasted.
        return name:find("[\208\209]") == nil and name:find("[\227-\237]") == nil
    elseif loc == "ruRU" then
        return name:find("[\208\209]") ~= nil   -- кириллица: D0/D1 + 80..BF
    elseif loc == "zhCN" or loc == "zhTW" or loc == "koKR" then
        return name:find("[\227-\237]") ~= nil  -- CJK/хангыль: 3-байтные E3..ED
    end
    return true  -- неизвестная локаль: не судим, лучше лишний запрос чем пропуск
end

-- Localized race names for the r-"race" filter.
--
-- Два источника, и они НЕ равноправны:
--   1) RACE_BY_LOCALE[локаль] — каноническое (мужское) название расы. Именно
--      его сервер понимает в /who, и именно в этой форме приходит raceStr в
--      ответе (проверено по SV: raceStr=Human для любой записи).
--   2) db.learn.raceLoc2File — самообучение из UnitRace. Ценно ТОЛЬКО для
--      рас, которых нет в эталонной таблице (кастомные, напр. Skyborne).
--
-- Ловушка, стоившая половины расовых запросов: UnitRace отдаёт название расы
-- С УЧЁТОМ ПОЛА юнита, поэтому в learn рядом с «Орк» лежат «Орчиха», «Гномка»,
-- «Дворфийка», «Ночная эльфийка». Это не отдельные расы: /who на них отвечает
-- пустым списком, а каждый такой запрос жжёт троттлинг /who (в SV видны
-- сообщения «Для повторного использования команды /кто необходимо немного
-- подождать»). Поэтому для известных рас берём ТОЛЬКО канон, а из learn — не
-- больше одной формы на расу.
--
-- faction ~= nil → cut races of the other faction: /who on Camelot returns
-- only the querying character's faction, queries for enemy races are always empty
local function RaceFilterNames(db, faction)
    local names = {}
    local loc = (GetLocale and GetLocale()) or ""
    local function want(raceFile)
        if not faction then return true end
        -- стандартные расы: фракция детерминирована, справочник не устаревает
        local known = RACE_FACTION[raceFile]
        if known then return known == faction end
        -- кастомные: смотрим НАБОР наблюдённых фракций
        local set = LearnedFactions(db, raceFile)
        if not set then return true end       -- не знаем — не судим, лучше лишний запрос
        if CountSet(set) > 1 then return true end  -- кросс-фракционная раса: нужна обеим сторонам
        return set[faction] == true
    end

    -- 1) канон: сначала написание, которое сервер сам вернул в ответе /who
    --    (learn.whoName), затем эталонная таблица локали. Для известных рас
    --    learn.raceLoc2File не нужен вовсе — там лежат ещё и женские формы.
    local canonical = {}
    local whoName = (db and db.learn and db.learn.whoName) or nil
    -- В какой локали выучено написание. whoName копится годами и хранит имена
    -- ВСЕХ клиентов, а латинские локали (en/de/fr) по алфавиту неразличимы:
    -- без метки английский клиент брал немецкое «Mensch» (ASCII проходит
    -- алфавитный гейт), а немецкий — русское «Нежить». Метка ставится при
    -- записи (см. HandleWhoList); у старых записей её нет, и для рас с
    -- известным каноном это значит «доверять таблице, а не whoName».
    local whoLoc = (db and db.learn and db.learn.whoNameLoc) or nil
    local locTable = RACE_BY_LOCALE[loc]
    if locTable then
        for raceFile, locName in pairs(locTable) do
            if want(raceFile) then
                local canon = whoName and whoName[raceFile]
                if canon and (not whoLoc or whoLoc[raceFile] ~= loc) then canon = nil end
                names[canon or locName] = true
                canonical[raceFile] = true
            end
        end
    end
    -- расы вне эталона (кастомные), для которых сервер уже вернул написание
    if whoName then
        for raceFile, locName in pairs(whoName) do
            if not canonical[raceFile] and want(raceFile) then
                -- та же метка локали: написание годится, если выучено на этом
                -- клиенте, либо (у старых записей без метки) если алфавит свой
                local tag = whoLoc and whoLoc[raceFile]
                local okLoc = (tag ~= nil and tag == loc)
                    or (tag == nil and NameFitsLocale(locName, loc))
                if okLoc then
                    names[locName] = true
                    canonical[raceFile] = true
                end
            end
        end
    end

    -- 2) learn: только расы вне эталона. Женские формы («Орчиха») и чужая
    -- локаль отсекаются, на одну расу — одна форма, иначе запросы дублируются.
    if db and db.learn and db.learn.raceLoc2File then
        local chosen = {}
        for locName, raceFile in pairs(db.learn.raceLoc2File) do
            if not canonical[raceFile] and want(raceFile) and NameFitsLocale(locName, loc) then
                local cur = chosen[raceFile]
                if not cur then
                    chosen[raceFile] = locName
                else
                    -- несколько написаний одной кастомной расы: берём ту, что
                    -- больше похожа на канон — без женского окончания
                    if IsFeminine(locName) and not IsFeminine(cur) then
                        -- оставляем cur
                    elseif IsFeminine(cur) and not IsFeminine(locName) then
                        chosen[raceFile] = locName
                    elseif locName < cur then
                        chosen[raceFile] = locName
                    end
                end
            end
        end
        for _, locName in pairs(chosen) do names[locName] = true end
    end
    return names
end

-- Full layered zone scan: a queue of level ranges advanced by the user's clicks.
local whoPumpScheduled = false

local function FinishZoneScan(reason)
    if not whoScan then return end
    local s = whoScan
    whoScan = nil
    whoQueue = {}
    GetDB().scan = nil   -- finished: nothing left to resume
    -- clean up after ourselves: the Who window remembers the last query in the
    -- input box — clear it so the user doesn't see the scan's "alien" values
    pcall(function()
        if WhoFrameEditBox then WhoFrameEditBox:SetText("") end
    end)
    HideWhoFrame()
    D(("/who %s: scan done%s — queries %d, found %d, new %d, splits %d, race splits %d%s"):format(
        s.zone, reason and (" (" .. reason .. ")") or "", s.sent, s.results, s.added,
        s.splits or 0, s.raceSplits or 0,
        (s.deadFilter and s.deadFilter > 0)
            and ("; level filter ignored on " .. s.deadFilter .. " slice(s)") or ""))
end

-- catch the server's anti-bot message ("Интересная операция, связанная с модификацией"):
-- the delivery channel is unpredictable — UI_ERROR_MESSAGE or system chat.
-- The pause is stored in db (survives /reload).
local function CheckWhoThrottle(msg)
    if type(msg) ~= "string" then return false end
    -- the client may deliver the message as a secret string — bail out before
    -- any string operation (same gate as the chat path)
    if canaccessvalue and not canaccessvalue(msg) then return false end
    local db = GetDB()
    if msg:find("[Пп]ерац") or msg:find("[Мм]одификац") then
        -- hard anti-bot ("Интересная операция…"): 5-minute pause, stop the scan
        db.debug.whoThrottled = (db.debug.whoThrottled or 0) + 1
        db.debug.lastErrorMsg = NspCut(msg, 120)
        db.whoPauseUntil = time() + 300
        if whoScan then FinishZoneScan("stopped: server throttles /who") end
        P(L("WHO_THROTTLED"))
        return true
    end
    if msg:find("[Пп]одожд")
        -- German cooldown text, captured live on a deDE client (24.11.2026,
        -- db.debug.msgLog): "Wartet noch einen Moment, bis Ihr /wer erneut
        -- verwenden könnt." Two of those arrived and whoSoft did NOT move —
        -- the gate only knew the Russian wording, so the pause was never
        -- noted. Stable part is "noch einen Moment"; the command name
        -- ("/wer" = /who on deDE) may differ in other builds.
        -- ⚠️ Never invent another locale's text: add it only when it actually
        -- shows up in db.debug.msgLog, otherwise the gate looks fine and
        -- silently does nothing.
        or msg:find("noch einen Moment") then
        -- soft command cooldown (a couple of seconds) — note it, don't stop the scan
        db.debug.whoSoft = (db.debug.whoSoft or 0) + 1
        db.debug.lastErrorMsg = NspCut(msg, 120)
        return true
    end
    return false
end

local function WhoPauseLeft()
    local left = (GetDB().whoPauseUntil or 0) - time()
    return left > 0 and left or 0
end

-- diagnostics: log recent system messages/errors into debug
-- to catch the exact text and channel of the server anti-bot message
local function LogSysMsg(chan, msg)
    if type(msg) ~= "string" then return end
    -- The client may deliver the message as a secret string: `msg == ""` is
    -- already a string operation and throws on it, so the gate goes BEFORE the
    -- emptiness check (the order CheckWhoThrottle already uses).
    if canaccessvalue and not canaccessvalue(msg) then return end
    if msg == "" then return end
    local db = GetDB()
    db.debug.msgLog = db.debug.msgLog or {}
    local log = db.debug.msgLog
    log[#log + 1] = chan .. "|" .. NspCut(msg, 220)
    if #log > 10 then table.remove(log, 1) end
end

local function PumpWhoQueue()
    if whoPumpScheduled then return end
    whoPumpScheduled = true
    -- next query right after the user's click (1.5s)
    local delay = 1.5
    C_Timer.After(delay, function()
        whoPumpScheduled = false
        if not whoScan then return end
        local q = table.remove(whoQueue, 1)
        if not q then
            FinishZoneScan()
            return
        end
        whoScan.current = q
        whoScan.sent = (whoScan.sent or 0) + 1
        -- mirror the remaining queue into SV right away: a /reload or relog
        -- writes SavedVariables at that moment, which is exactly the resume point
        if SaveScanState then SaveScanState() end
        -- query WITHOUT the zone filter (the server drops z-…), but with an
        -- optional slice filter (class/race token, localized) + level range
        -- filters: class slice and/or race slice, then the level range. Both
        -- tokens are localized (к-/р- on RU, c-/r- on EN).
        local filter = ""
        if q.base then filter = q.base end
        if q.race then
            filter = (filter ~= "" and (filter .. " ") or "")
                .. WHO_TOKEN_RACE .. '"' .. q.race .. '"'
        end
        if filter ~= "" then filter = filter .. " " end
        local query = filter .. ("%d-%d"):format(q.lo, q.hi)
        if whoScan.suggest then
            -- assisted mode (70291: programmatic who is dead): the addon types
            -- the query into the box, the user clicks the magnifier — a hardware
            -- click is the only thing the server answers. Retries are pointless:
            -- the reply comes from the click.
            EnsureWhoVisible()
            pcall(function()
                if C_FriendList and C_FriendList.SetWhoToUi then C_FriendList.SetWhoToUi(true) end
            end)
            pcall(function()
                if WhoFrameEditBox then WhoFrameEditBox:SetText(query) end
            end)
            pcall(function() PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON) end)
            P(L("SUGGEST_INSCRIBED"):format(query, #whoQueue))
            C_Timer.After(45, function()
                if whoScan and whoScan.suggest and whoScan.current == q and not q.answered then
                    P(L("SUGGEST_WAITING"):format(query))
                end
            end)
            return
        end
    end)
end

-- Level-first scan plan: the OUTER loop is the level, classes are the inner
-- one. Counts come from our own database, so the plan is an estimate — a reply
-- that comes back full is split further at reply time (classes, then races).
--
-- Packing rules (measured against the server population, 06.11.2026):
--   * the walk is TOP-DOWN (level 60 first): if the run is interrupted, the
--     endgame part is already covered;
--   * a whole level is queried WITHOUT a class filter when it fits the 50 cap,
--     and consecutive such levels are merged into one range;
--   * an overfull level is queried class by class, and each class keeps its
--     range open while the running total stays under the cap — this is what
--     turns 204 single-level queries into ~93 for the same coverage;
--   * a class+level pair that alone overflows is left as is: it gets split by
--     race when the reply comes back full.
-- SCAN — построители плана скана. Таблица, а не отдельные local function:
-- в Lua 5.1 на главный чанк приходится не больше 200 локалов, и каждый
-- отдельный построитель съедает слот (ловили дважды).
local SCAN = {}

function SCAN.Level(db, ml)
    local counts, loc = {}, {}
    for _, pl in pairs((db and db.players) or {}) do
        local cls, lvl = pl.class, pl.level
        if cls and lvl and lvl >= 1 and lvl <= ml then
            local byLevel = counts[cls]
            if not byLevel then byLevel = {} counts[cls] = byLevel end
            byLevel[lvl] = (byLevel[lvl] or 0) + 1
            if not loc[cls] then loc[cls] = (LOCALIZED_CLASS_NAMES_MALE or {})[cls] end
        end
    end

    local classes = {}
    for cls in pairs(counts) do classes[#classes + 1] = cls end
    table.sort(classes)   -- stable plan between runs

    local queue, openRange, wholeIdx = {}, {}, nil
    local function levelTotal(lvl)
        local t = 0
        for _, cls in ipairs(classes) do t = t + (counts[cls][lvl] or 0) end
        return t
    end

    -- top-down: the highest levels are scanned first, so an interrupted run
    -- still covers the endgame part of the server (that is where the players
    -- people actually look for are). Ranges therefore grow DOWNWARD: a level
    -- joins the open range when it sits directly below its current bottom.
    for lvl = ml, 1, -1 do
        local total = levelTotal(lvl)
        if total <= NSP_CONST.WHO_CAP then
            local idx = wholeIdx
            if idx and queue[idx].lo == lvl + 1 and ((queue[idx].n or 0) + total) <= NSP_CONST.WHO_CAP then
                queue[idx].lo = lvl
                queue[idx].n = (queue[idx].n or 0) + total
            else
                queue[#queue + 1] = { lo = lvl, hi = lvl, n = total }
                wholeIdx = #queue
            end
        else
            wholeIdx = nil
            for _, cls in ipairs(classes) do
                local n = counts[cls][lvl] or 0
                if n > 0 then
                    local idx = openRange[cls]
                    if idx and queue[idx].lo == lvl + 1 and ((queue[idx].n or 0) + n) <= NSP_CONST.WHO_CAP then
                        queue[idx].lo = lvl
                        queue[idx].n = (queue[idx].n or 0) + n
                    else
                        queue[#queue + 1] = {
                            base = WHO_TOKEN_CLASS .. '"' .. (loc[cls] or cls) .. '"',
                            lo = lvl, hi = lvl, n = n, cls = cls,
                        }
                        openRange[cls] = #queue
                    end
                else
                    local idx = openRange[cls]
                    if idx and queue[idx].lo > lvl + 1 then openRange[cls] = nil end
                end
            end
        end
    end
    return queue
end

-- SCAN.Speed — поверхностный слой трёхступенчатой воронкой сверху вниз.
--
-- Ступени (решение пользователя 09.11.2026):
--   tier 1 — полоса уровней шириной 10, от капа вниз: 51-60, 41-50, 31-40 …
--   tier 2 — если полоса упёрлась в лимит 50 строк, она раскрывается ПО КЛАССАМ,
--            и снова полосами по 10 от верха (к-"Воин" 51-60, 41-50 …)
--   tier 3 — если и срез класса упёрся в лимит, к нему добавляется РАСА,
--            тоже полосой по 10 от верха
--
-- Раскрытие адаптивное: в разреженной полосе оно не происходит вовсе, поэтому
-- на живом сервере это десятки запросов, а не сотни. Сверху вниз — потому что
-- интерес к эндгейму выше, и прерванный прогон всё равно покрывает верх.
--
-- SCAN.SPEED_MAX — жёсткий потолок раскрытия. Без него «поверхностный
-- слой» на плотном сервере мог бы развернуться в большее число запросов, чем
-- полная перепись (~110). Потолок считается по числу ДОБАВЛЕННЫХ срезов, а не
-- по позиции в очереди: после /reload счётчик восстанавливается из SV.
SCAN.SPEED_BAND = 10    -- ширина полосы уровней на каждой ступени
SCAN.RACE_MIN_OBS = 30  -- минимум наблюдений расы, чтобы судить о её классах
SCAN.SPEED_MAX = 60     -- потолок раскрытия: surface layer не должен стать переписью

function SCAN.Speed(db, ml, band)
    band = band or SCAN.SPEED_BAND
    local queue = {}
    -- от капа вниз: hi = ml, ml-band, …; lo не меньше 1
    for hi = ml, 1, -band do
        local lo = math.max(1, hi - band + 1)
        queue[#queue + 1] = { lo = lo, hi = hi, tier = 1, kind = "level" }
    end
    return queue
end

-- SCAN.SpeedClasses — ступень 2: классы для одной полосы уровней.
-- Порядок фиксирован сортировкой: сохранённая очередь после /reload должна
-- совпадать с исходной, иначе прогон каждый раз идёт по-новому.
function SCAN.SpeedClasses(q)
    local names = {}
    -- cls (файловый ключ, напр. DRUID) нужен ступени 3: расы фильтруются по
    -- реально наблюдаемым комбинациям «класс × раса»
    for cls, locName in pairs(LOCALIZED_CLASS_NAMES_MALE or {}) do
        names[#names + 1] = { loc = locName, cls = cls }
    end
    table.sort(names, function(a, b) return a.loc < b.loc end)
    local out = {}
    for _, e in ipairs(names) do
        out[#out + 1] = { base = WHO_TOKEN_CLASS .. '"' .. e.loc .. '"',
            cls = e.cls,
            lo = q.lo, hi = q.hi, tier = 2, kind = "class", parentSet = q.parentSet }
    end
    return out
end

-- SCAN.RaceName — локализованное имя расы по файловому ключу.
-- Приоритет: написание, которое вернул сам сервер (learn.whoName), затем
-- эталонная таблица локали, затем выученные написания (только те, что в
-- алфавите клиента).
function SCAN.RaceName(db, raceFile)
    if not raceFile or raceFile == "" then return nil end
    local loc = (GetLocale and GetLocale()) or ""
    local learn = db and db.learn
    -- whoName накопительный, поэтому написание берётся только если оно
    -- выучено на ЭТОМ клиенте (whoNameLoc); у старых записей без метки —
    -- если алфавит совпадает с локалью. Иначе падаем на канон таблицы.
    if learn and learn.whoName and learn.whoName[raceFile] then
        local tag = learn.whoNameLoc and learn.whoNameLoc[raceFile]
        local okLoc = (tag ~= nil and tag == loc)
            or (tag == nil and NameFitsLocale(learn.whoName[raceFile], loc))
        if okLoc then return learn.whoName[raceFile] end
    end
    local locTable = RACE_BY_LOCALE[loc]
    if locTable then
        local name = locTable[raceFile]
        if name then return name end
    end
    if learn and learn.raceLoc2File then
        -- несколько написаний одной расы: предпочитаем НЕ женскую форму
        -- («Небеснорожденный», а не «Небеснорожденная»), затем — по алфавиту.
        -- Иначе выбор зависел бы от случайного порядка и не совпадал с тем
        -- именем, которое RaceFilterNames кладёт в очередь запросов.
        local best, bestFem
        for locName, rf in pairs(learn.raceLoc2File) do
            if rf == raceFile and NameFitsLocale(locName, loc) then
                local fem = IsFeminine(locName)
                if not best then
                    best, bestFem = locName, fem
                elseif bestFem and not fem then
                    best, bestFem = locName, fem
                elseif bestFem == fem and locName < best then
                    best = locName
                end
            end
        end
        return best
    end
    return nil
end

-- SCAN.ClassRaces — какие расы реально бывают у класса, по данным игроков.
-- Возвращает set локализованных имён. Пустой set = комбинации ещё не
-- наблюдались (тогда вызывающий берёт все расы фракции).
--
-- Зачем: на этом сервере комбинации НЕ классические (у Дворфа шаман и паладин,
-- у Нежити паладин, у Skyborne друид), поэтому статическая таблица «класс ×
-- раса» была бы неверной в обе стороны — и теряла бы существующие пары, и
-- генерировала заведомо пустые запросы.
function SCAN.ClassRaces(db, cls)
    local out = {}
    if not cls then return out end
    for _, pl in pairs((db and db.players) or {}) do
        if pl.class == cls and pl.race and pl.race ~= "" then
            local locName = SCAN.RaceName(db, pl.race)
            if locName then out[locName] = true end
        end
    end
    return out
end

-- SCAN.RaceObs — сколько раз раса вообще наблюдалась (любым классом).
-- Нужно, чтобы сужать список рас только по ДОСТАТОЧНОЙ выборке: иначе
-- получается замкнутый круг — пару не спросили, потому что не видели, а не
-- увидели, потому что не спросили. Для редкой/новой расы фильтр не применяем.
function SCAN.RaceObs(db)
    local out = {}
    for _, pl in pairs((db and db.players) or {}) do
        if pl.race and pl.race ~= "" then
            local locName = SCAN.RaceName(db, pl.race)
            if locName then out[locName] = (out[locName] or 0) + 1 end
        end
    end
    return out
end

-- SCAN.RaceNames — локализованные имена рас для расового среза КЛАССА.
--
-- Общий список для ОБЕИХ воронок: speed-ступень 3 (SCAN.SpeedRaces) и расовое
-- дробление переполненного среза в level-first плане (режим /nspy who).
-- Держать их на одном источнике обязательно: level-first раньше брал ВСЕ расы
-- фракции, и в очередь попадали пары вида «Друид × Орк», которых на сервере
-- нет (замечание пользователя 20.11.2026).
--
--   cls ~= nil → только расы, реально наблюдавшиеся ИМЕННО с этим классом,
--                плюс вылет для редких рас (см. SCAN.RACE_MIN_OBS);
--   cls == nil → все расы фракции (план из старого SV, класс не сохранён).
function SCAN.RaceNames(db, cls)
    local allowed = RaceFilterNames(db, PlayerFaction())
    local observed = cls and SCAN.ClassRaces(db, cls) or nil
    local hasObs = observed ~= nil and next(observed) ~= nil
    local obsCount = hasObs and SCAN.RaceObs(db) or nil
    local names = {}
    for locName in pairs(allowed) do
        -- Раса попадает в срез, если пара «класс × раса» уже наблюдалась ИЛИ
        -- выборка по расе слишком мала, чтобы судить (тогда лишний запрос
        -- дешевле пропущенной расы).
        if not hasObs or observed[locName]
            or (obsCount[locName] or 0) < SCAN.RACE_MIN_OBS then
            names[#names + 1] = locName
        end
    end
    table.sort(names)
    return names
end

-- SCAN.SpeedRaces — ступень 3: расы для одного среза класса и полосы уровней.
function SCAN.SpeedRaces(db, q)
    local names = SCAN.RaceNames(db, q.cls)
    local out = {}
    for _, locName in ipairs(names) do
        out[#out + 1] = { base = q.base, race = locName,
            lo = q.lo, hi = q.hi, tier = 3, kind = "race", parentSet = q.parentSet }
    end
    return out
end

-- SCAN.SpeedExpand — какие срезы добавить, когда срез упёрся в лимит.
-- Возвращает массив (возможно урезанный по бюджету) или nil, если раскрывать
-- нечего. Вынесено из обработчика ответа: воронку надо проверять тестом, а не
-- глазами по логу в игре.
function SCAN.SpeedExpand(db, q, left)
    if not q or not q.tier then return nil end
    if q.tier == 1 then return SCAN.SpeedClasses(q) end
    if q.tier == 2 then return SCAN.SpeedRaces(db, q) end
    return nil  -- tier 3 — предел детализации
end

-- SCAN.SpeedTrim — урезать список срезов по остатку бюджета (left).
-- nil, если бюджета нет вовсе.
function SCAN.SpeedTrim(slices, left)
    if not slices or #slices == 0 or not left or left <= 0 then return nil end
    if #slices <= left then return slices end
    for i = #slices, left + 1, -1 do table.remove(slices, i) end
    return slices
end

-- ============ scan persistence ============
-- A full level-first plan is ~110 queries, so one scan inevitably spans a
-- /reload or a relog. The queue therefore lives in SavedVariables: the next
-- /nspy who continues where the previous one stopped instead of starting from
-- the top level again. Only the remaining queue is stored; parentSet (the
-- name list used by the dead-filter guard) is dropped — it is per-branch
-- bookkeeping, up to 50 names per entry, and would bloat the SV file.
local SCAN_RESUME_MAX_AGE = 12 * 3600   -- s: older plans are stale, start fresh

local function CompactQueue(queue)
    local out = {}
    for i = 1, #queue do
        local q = queue[i]
        out[i] = { lo = q.lo, hi = q.hi, base = q.base, race = q.race,
            noSplit = q.noSplit, tier = q.tier, kind = q.kind, cls = q.cls }
    end
    return out
end

-- called on every queue change: SavedVariables are written on /reload and
-- logout, so whatever is here at that moment is what the next session resumes
function SaveScanState()
    local db = GetDB()
    if not whoScan then
        db.scan = nil
        return
    end
    db.scan = {
        zone = whoScan.zone,
        mode = whoScan.mode,
        suggest = whoScan.suggest or nil,
        sent = whoScan.sent or 0,
        results = whoScan.results or 0,
        added = whoScan.added or 0,
        splits = whoScan.splits or 0,
        raceSplits = whoScan.raceSplits or 0,
        speedSlices = whoScan.speedSlices or 0,
        started = whoScan.started,
        total = whoScan.total or #whoQueue,
        queue = CompactQueue(whoQueue),
        updated = time(),
    }
end

-- returns the stored plan if it is still worth resuming
local function LoadScanState()
    local db = GetDB()
    local s = db.scan
    if type(s) ~= "table" or type(s.queue) ~= "table" or #s.queue == 0 then
        return nil
    end
    local age = time() - (tonumber(s.updated) or 0)
    if age > SCAN_RESUME_MAX_AGE or age < 0 then
        db.scan = nil
        return nil
    end
    return s
end

local function StartZoneScan(zone, manual, mode, suggest, forceNew)
    local db = GetDB()
    mode = mode or "level"
    if whoScan then
        return false, L("ERR_SCAN_RUNNING"):format(whoScan.zone)
    end
    if WhoPauseLeft() > 0 then
        return false, L("ERR_THROTTLE_PAUSE"):format(WhoPauseLeft())
    end

    -- resume the unfinished plan before building a new one: a full level-first
    -- scan is ~110 queries, so it almost never fits into one game session
    if not forceNew then
        local saved = LoadScanState()
        -- only resume a plan of the SAME kind: a saved "who" plan must not
        -- hijack "/nspy whoclass" (different mode, different slices)
        if saved and (saved.mode or "level") ~= (mode or "level") then
            saved = nil
        end
        if saved then
            whoQueue = saved.queue
            whoScan = {
                zone = saved.zone or zone,
                mode = saved.mode or mode,
                sent = saved.sent or 0,
                results = saved.results or 0,
                added = saved.added or 0,
                splits = saved.splits or 0,
                raceSplits = saved.raceSplits or 0,
                speedSlices = saved.speedSlices or 0,
                started = saved.started,
                total = saved.total or #whoQueue,
                suggest = saved.suggest or suggest or nil,
                resumed = true,
            }
            P(L("SCAN_RESUMED"):format(#whoQueue, whoScan.total))
            PumpWhoQueue()
            return true, L("QUERIES_FMT"):format(#whoQueue)
        end
    end

    whoQueue = {}
    local ml = MaxLevel()
    if mode == "class" then
        -- class slice: c-"mage" 1-80 (at the 50 cap — take as is)
        for _, locName in pairs(LOCALIZED_CLASS_NAMES_MALE or {}) do
            table.insert(whoQueue, { base = WHO_TOKEN_CLASS .. "\"" .. locName .. "\"", lo = 1, hi = ml })
        end
    elseif mode == "race" then
        -- race slice: r-"orc" 1-80; custom races — from the learned table
        local races = {}
        for locName in pairs(RaceFilterNames(db, PlayerFaction())) do races[#races + 1] = locName end
        table.sort(races)  -- стабильный план: очередь переживает /reload
        for _, locName in ipairs(races) do
            table.insert(whoQueue, { base = WHO_TOKEN_RACE .. "\"" .. locName .. "\"", lo = 1, hi = ml })
        end
    elseif mode == "speed" then
        whoQueue = SCAN.Speed(db, ml)
    else
        -- level-first plan (see SCAN.Level): levels from 1 up, classes
        -- inside each overfull level, races inside an overfull class+level
        whoQueue = SCAN.Level(db, ml)
        if #whoQueue == 0 then
            whoQueue = { { lo = 1, hi = ml } }
        end
    end
    if #whoQueue == 0 then
        return false, L("ERR_QUEUE_EMPTY")
    end
    whoScan = { zone = zone, mode = mode, sent = 0, results = 0, added = 0, started = time(),
        suggest = suggest or nil, total = #whoQueue }
    SaveScanState()
    local fac = PlayerFaction()
    if fac then
        P(L("WHO_FACTION_COVER"):format(fac == "Alliance" and L("ALLIANCE") or L("HORDE")))
    end
    PumpWhoQueue()
    return true, L("QUERIES_FMT"):format(#whoQueue)
end

-- sameNameSet: do two replies contain exactly the same players?
-- Used to detect a server that ignores level ranges: a narrower query that
-- returns the parent's players verbatim proves the filter was not applied.
local function sameNameSet(a, b)
    if type(a) ~= "table" or type(b) ~= "table" or #a ~= #b or #a == 0 then return false end
    local left = {}
    for i = 1, #a do left[a[i]] = (left[a[i]] or 0) + 1 end
    for i = 1, #b do
        local n = left[b[i]]
        if not n or n < 1 then return false end
        left[b[i]] = n - 1
    end
    return true
end

local function HandleWhoList()
    local db = GetDB()
    if not C_FriendList or not C_FriendList.GetNumWhoResults then return end
    local okN, num = pcall(C_FriendList.GetNumWhoResults)
    if not okN or not num then return end
    db.debug.whoResults = num
    if whoTest then
        -- a reply arrived while the probe waits — this is what the probe measures
        whoTest.replies = whoTest.replies + 1
        whoTest.lastNum = num
    end
    local added = 0
    local names = {}   -- reply contents, for the dead-level-filter guard
    local x, y = PlayerXY()
    local ownZone = PlayerZone()
    local ownZoneId = PlayerZoneId()
    for i = 1, num do
        local okRow, errRow = pcall(function()
        local okI, info = pcall(C_FriendList.GetWhoInfo, i)
        if okI and info and info.fullName then
            -- one-time dump of raw /who entry fields into debug (beta field diagnostics)
            if not db.debug.whoSample then
                local parts = {}
                for k, v in pairs(info) do parts[#parts + 1] = tostring(k) .. "=" .. tostring(v) end
                db.debug.whoSample = table.concat(parts, "; ")
            end
            local name = info.fullName:match("^([^%-]+)%-") or info.fullName
            names[#names + 1] = name
            local realm = PlayerRealm()  -- the suffix after the dash is unreliable; realm = current
            -- class: the beta has a ready filename field (MAGE); fallback — locale mapping
            local classFile = info.filename or ClassFileFromLocalized(info.classStr)
            -- race: from the learned table, then the classic mapping
            local raceLoc = info.raceStr
            local raceFile = (db.learn and db.learn.raceLoc2File and db.learn.raceLoc2File[raceLoc or ""])
                or RACE_LOCALE[raceLoc or ""]
            -- каноническое написание расы: сервер только что вернул его сам в
            -- ответе на /who, значит именно эту форму он понимает в фильтре
            -- р-"…". Для стандартных рас это мужская форма (Human), для
            -- кастомных — единственный способ узнать канон, не угадывая между
            -- «Небеснорожденный» и «Небеснорожденная». Используется в
            -- RaceFilterNames с высшим приоритетом.
            if raceFile and raceLoc and raceLoc ~= "" then
                db.learn = db.learn or {}
                db.learn.whoName = db.learn.whoName or {}
                db.learn.whoName[raceFile] = raceLoc
                -- в какой локали выучено (24.11.2026): whoName накопительный,
                -- а латинские локали по алфавиту неразличимы — без метки
                -- английский клиент брал немецкое «Mensch» из общего SV
                db.learn.whoNameLoc = db.learn.whoNameLoc or {}
                db.learn.whoNameLoc[raceFile] = (GetLocale and GetLocale()) or ""
            elseif raceLoc and raceLoc ~= "" then
                -- Раса пришла, но в наших таблицах её нет: без диагностики такие
                -- записи молча теряют расу И фракцию (/who отдаёт до 10% таких),
                -- а вместе с ними теряются комбинации «класс × раса» для
                -- фильтра /nspy who speed. Складываем написания в debug.
                db.debug.raceUnresolved = (db.debug.raceUnresolved or 0) + 1
                db.debug.raceSamples = db.debug.raceSamples or {}
                local samples = db.debug.raceSamples
                if not samples[raceLoc] then samples[raceLoc] = true end
            else
                -- сервер не прислал расу вовсе (raceStr пуст) — это другое:
                -- имя не выучить, пока клиент его не отдаст
                db.debug.raceEmpty = (db.debug.raceEmpty or 0) + 1
            end
            -- Один раз снимаем ВСЕ поля такой записи: нужно понять, приходит ли
            -- раса под другим ключом, чем raceStr, или её правда нет.
            if not raceFile and not db.debug.whoSampleNoRace then
                local parts = {}
                for k, v in pairs(info) do parts[#parts + 1] = tostring(k) .. "=" .. tostring(v) end
                db.debug.whoSampleNoRace = table.concat(parts, "; ")
            end
            -- фракция: у стандартных рас она детерминирована справочником, у
            -- кастомных — только если раса наблюдалась ровно в одной фракции.
            -- Кросс-фракционной расе (Skyborne: есть и у Альянса, и у Орды)
            -- фракцию НЕ приписываем: раньше здесь выводилось «что запомнили
            -- последним», и ордынский Skyborne уезжал в базу как альянсовый.
            local faction = RACE_FACTION[raceFile or ""]
            if raceFile and not faction then
                local set = LearnedFactions(db, raceFile)
                if set and CountSet(set) == 1 then
                    faction = next(set)
                end
            end
            -- /who ВСЕГДА отдаёт только свою фракцию (проверено по данным: все
            -- who-записи однозначны по фракции). Если раса не распозналась,
            -- фракция всё равно известна — иначе игрок уезжает в базу без неё.
            faction = faction or PlayerFaction()
            -- player zone — from the /who reply (info.area), not our current one!
            -- zoneId из словаря клиента: /who отдаёт зону текстом и id не даёт.
            -- Раньше id ставился только когда зона совпадала с нашей (23.5%
            -- записей); словарь поднимает это почти до полного покрытия и
            -- позволяет отправлять в канал число вместо текста.
            local zone = info.area or ownZone
            local zoneId = (zone == ownZone) and ownZoneId or ZoneIdByName(zone)
            if UpsertPlayer(db, {
                key = name .. "-" .. realm,
                name = name,
                realm = realm,
                class = classFile,
                classLoc = info.classStr,
                level = info.level,
                faction = faction,
                race = raceFile,
                zone = zone,
                zoneId = zoneId,
                x = x,
                y = y,
                source = "who",
                silent = true,   -- a /who zone can yield dozens of players — don't spam chat
            }) then
                added = added + 1
            end
        end
        end)
        if not okRow then DbgErr("whoRow", errRow) end
    end
    db.debug.whoAdded = (db.debug.whoAdded or 0) + added
    if whoTest then
        -- signature of THIS reply's player set: two different queries must
        -- never return the same players, so an identical signature means the
        -- client redrew a cached list instead of sending a new request
        local copy = {}
        for i = 1, #names do copy[i] = names[i] end
        table.sort(copy)
        whoTest.lastSig = (#copy > 0) and table.concat(copy, ",") or ""
        whoTest.lastCount = num
    end
    -- hide the Who window only after our own scan, with a human-like delay
    -- (instant hiding after every reply is a bot pattern for the anti-cheat);
    -- in suggest mode we don't touch the window — the user clicks the magnifier on it
    if whoScan and whoScan.suggest then
        -- keep the window open
    elseif whoScan then
        C_Timer.After(1.5 + math.random() * 3, HideWhoFrame)
    end

    if whoScan then
        -- reply to the layered scan query
        local q = whoScan.current
        if q then q.answered = true end
        whoScan.results = whoScan.results + num
        whoScan.added = whoScan.added + added
        if num >= NSP_CONST.WHO_CAP and q then
            if q.tier then
                -- трехступенчатая воронка speed: полоса уровней → классы →
                -- расы. Раскрывается ТОЛЬКО переполненный срез и только пока
                -- не выбран потолок SCAN.SPEED_MAX.
                local left = SCAN.SPEED_MAX - (whoScan.speedSlices or 0)
                local slices = SCAN.SpeedTrim(SCAN.SpeedExpand(db, q, left), left)
                if slices then
                    for i = #slices, 1, -1 do table.insert(whoQueue, 1, slices[i]) end
                    whoScan.speedSlices = (whoScan.speedSlices or 0) + #slices
                    D(("/who: %d (cap) — speed tier %d → %d slices (%s %d-%d)"):format(
                        num, q.tier, #slices, q.kind or "?", q.lo, q.hi))
                elseif q.tier == 3 then
                    D(("/who: %d (cap) — speed race slice %s %d-%d taken as is"):format(
                        num, q.race or "?", q.lo, q.hi))
                else
                    D(("/who: %d (cap) — speed budget spent, %s %d-%d taken as is"):format(
                        num, q.base or "level", q.lo, q.hi))
                end
            elseif q.noSplit then
                -- старый план из прошлого SV: обрезанный срез не дробим
                D(("/who: %d (cap) — surface slice %s %d-%d taken as is"):format(
                    num, q.base or "level", q.lo, q.hi))
            elseif not (q.base and q.base:find(WHO_TOKEN_CLASS, 1, true)) then
                -- wide reply: split by CLASS first (a class is the smallest
                -- filter that is known to work everywhere). The file key rides
                -- along: a class slice that later overflows a single level is
                -- split by race, and that split filters races by this key.
                local sub = 0
                for cls, locName in pairs(LOCALIZED_CLASS_NAMES_MALE or {}) do
                    table.insert(whoQueue, 1, { base = WHO_TOKEN_CLASS .. '"' .. locName .. '"',
                        cls = cls, lo = q.lo, hi = q.hi, parentSet = names })
                    sub = sub + 1
                end
                D(("/who: %d (cap) — splitting %d-%d into %d class slices"):format(num, q.lo, q.hi, sub))
            elseif q.lo < q.hi then
                -- class slice overflowed: split its level range in half. The
                -- split is recursive, so a dense class narrows down to single
                -- levels (level+class always fits the 50 cap: measured max is
                -- 41 players per class per level) while a sparse one stays wide
                -- and costs no extra clicks.
                --
                -- Guard: a child that returns the very same players as its
                -- parent means the server did not apply the range at all
                -- (10.10.2026 a beta build behaved like that). Then there is
                -- nothing to narrow — stop the branch instead of burning
                -- clicks on identical replies.
                if q.parentSet and sameNameSet(names, q.parentSet) then
                    whoScan.deadFilter = (whoScan.deadFilter or 0) + 1
                    D(("/who: %d (cap) — %s %d-%d returned the parent's players; level filter is not applied, branch stopped")
                        :format(num, q.base or "?", q.lo, q.hi))
                else
                    local mid = math.floor((q.lo + q.hi) / 2)
                    -- depth-first: the lower half goes first, so a partial run
                    -- still covers the levels most players actually occupy.
                    -- cls MUST travel with the halves: the race split below
                    -- filters races by the class, and without it the branch
                    -- degrades to "every race of the faction" — pairs such as
                    -- Друид × Орк that the server does not have.
                    table.insert(whoQueue, 1, { base = q.base, cls = q.cls, lo = mid + 1, hi = q.hi, parentSet = names })
                    table.insert(whoQueue, 1, { base = q.base, cls = q.cls, lo = q.lo, hi = mid, parentSet = names })
                    whoScan.splits = (whoScan.splits or 0) + 1
                    D(("/who: %d (cap) — %s %d-%d → %d-%d + %d-%d")
                        :format(num, q.base or "?", q.lo, q.hi, q.lo, mid, mid + 1, q.hi))
                end
            elseif not q.race and q.base then
                -- class + single level still overflows: split by RACE. Only a
                -- handful of pairs are that dense (measured max 78 players for
                -- one class on one level), so this tier costs ~10 extra queries
                -- and closes the last gap in coverage.
                --
                -- Races come from SCAN.RaceNames(db, q.cls): only the ones that
                -- actually occur with THIS class. Taking every faction race here
                -- produced queries for pairs the server does not have (Друид ×
                -- Орк) — each of them burns a click and a throttling slot.
                local races = SCAN.RaceNames(db, q.cls)
                local sub = 0
                for _, locName in ipairs(races) do
                    table.insert(whoQueue, 1, { base = q.base, cls = q.cls, race = locName,
                        lo = q.lo, hi = q.hi, parentSet = names })
                    sub = sub + 1
                end
                whoScan.raceSplits = (whoScan.raceSplits or 0) + 1
                D(("/who: %d (cap) — %s level %d → %d race slices (%s)")
                    :format(num, q.base, q.lo, sub, table.concat(races, ", ")))
            else
                -- race slice overflowed too: nothing narrower exists
                D(("/who: %d (cap) — %s level %d alone is overfull, taking what we get")
                    :format(num, q.race or q.base or "?", q.lo))
            end
        end
        PumpWhoQueue()
    else
        -- reply to a standalone general query
        if added > 0 then
            D(("/who %s: list %d, new %d"):format(
                (whoScan and whoScan.zone) or "?", num, added))
        end
        -- auto-start of the programmatic scan was REMOVED (1.5.0): since build
        -- 70291 programmatic /who is dead (hardware gate) — offer the assisted
        -- mode instead
        if num >= NSP_CONST.WHO_CAP then
            D(("/who: full reply (%d) — more data exists. /nspy suggest types queries, you click search"):format(num))
        end
    end
end

-- Observe nameplate CVars for diagnostics; never change a player's settings.
local NAMEPLATE_CVARS = { "nameplateShowFriends", "nameplateShowEnemies", "nameplateShowAll" }

local function EnsureNameplates(db)
    for _, cvar in ipairs(NAMEPLATE_CVARS) do
        local ok, value = pcall(GetCVar, cvar)
        if not ok then
            db.debug.cvarErr = (db.debug.cvarErr or 0) + 1
        else
            db.debug["cv_" .. cvar] = tostring(value)
        end
    end
end

local function ScanNameplates()
    local plates, players = 0, 0
    for i = 1, 40 do
        local unit = "nameplate" .. i
        if UnitExists(unit) then
            plates = plates + 1
            if UnitIsPlayer(unit) then
                players = players + 1
                Record(unit)
            end
        end
    end
    return plates, players
end

local function ScheduleTick()
    C_Timer.After(NSP_CONST.TICK_SECONDS, function()
        local db = GetDB()
        db.debug.ticks = (db.debug.ticks or 0) + 1
        db.debug.lastTickAt = time()
        local ok, plates, players = pcall(ScanNameplates)
        if ok then
            db.debug.lastPlates = plates
            db.debug.lastPlayers = players
        else
            db.debug.scanErr = (db.debug.scanErr or 0) + 1
        end
        if (db.debug.ticks % 15) == 0 then
            EnsureNameplates(db)
        end
        if (db.debug.ticks % (NSP_CONST.GUILD_REFRESH / NSP_CONST.TICK_SECONDS)) == 0 then
            RequestGuildRoster()
        end
        -- digest into the ring every 5 min (1.5.1): SV shows who feeds the database
        if (db.debug.ticks % 150) == 0 then
            local n, parts = 0, {}
            for _ in pairs(db.players) do n = n + 1 end
            for k, v in pairs(db.debug.src or {}) do parts[#parts + 1] = k .. "=" .. v end
            table.sort(parts)
            D(("digest: db %d, session +%d, src[%s]"):format(
                n, newThisSession,
                #parts > 0 and table.concat(parts, ",") or "-"))
        end
        -- Journal heartbeat, once a minute: playtime and zone time are
        -- accumulated live so a killed client does not lose the session
        -- (the next login closes it at the last beat).
        if (db.debug.ticks % 30) == 0 and NSP_JOURNAL then
            local okJ, errJ = pcall(NSP_JOURNAL.Beat, db, PlayerZone(), PlayerZoneId())
            if not okJ then DbgErr("journalBeat", errJ) end
        end
        ScheduleTick()
    end)
end

local function CountPlayers()
    local n = 0
    for _ in pairs(GetDB().players) do
        n = n + 1
    end
    return n
end

-- Сколько РАЗНЫХ ключей в таблице счётчиков. Префикс Nsp: глобалы общие для всех
-- аддонов, и голое CountKeys рано или поздно столкнётся с чужим.
function NspCountKeys(t)
    if type(t) ~= "table" then return 0 end
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local function DebugSummary(db)
    local d = db.debug or {}
    local age = d.lastTickAt and (time() - d.lastTickAt) or -1
    return ("ticks: %d (last %ds ago), plates/players in tick: %s/%s, " ..
           "PLATE_ADDED events: %d, CVar: friends=%s enemies=%s all=%s, " ..
           "/who: last list %d, new %d, scan/CVar errors %d/%d, " ..
           "tokens: %s%s%s (%s, locale %s)"):format(
        d.ticks or 0, age < 0 and 9999 or age,
        tostring(d.lastPlates or "?"), tostring(d.lastPlayers or "?"),
        d.addedEvents or 0,
        tostring(d.cv_nameplateShowFriends or "?"),
        tostring(d.cv_nameplateShowEnemies or "?"),
        tostring(d.cv_nameplateShowAll or "?"),
        d.whoResults or 0, d.whoAdded or 0,
        d.scanErr or 0, d.cvarErr or 0,
        WHO_TOKEN_ZONE, WHO_TOKEN_CLASS, WHO_TOKEN_RACE, WHO_TOKEN_SRC, GetLocale())
end

-- NSP_RECENT — список ПОСЛЕДНИХ записей для окна статистики (26.11.2026).
--
-- Решение владельца: держать не всю базу, а список последних N (500 — ровно
-- столько, сколько показывается); новая запись встаёт на своё место по
-- времени, хвост вытесняется. Сортировки в окне нет вообще.
--
-- Замер на живом SV (61 435 записей): пересборка полного порядка 70 мс, и это
-- платилось на каждое открытие/смену фильтра. Вставка в буфер из 500 — единицы
-- микросекунд, потому что сдвиг делает table.insert в C.
--
-- Что это меняет для пользователя (согласовано): фильтр по классу/реалму ищет
-- ВНУТРИ последних 500, поэтому при редком фильтре строк меньше, чем могло бы
-- быть по всей базе. Обычный список (без фильтра) полон — 500 из 500.
--
-- База игроков при этом НЕ уменьшается: выгрузка на сайт, парсеры и статистика
-- работают по db.players как раньше. Буфер — только для показа.
-- global: в главном чанке 197 локалов из 200.
NSP_RECENT = { list = {}, max = 500, dirty = true }

-- NspRecentBuild() — построить буфер из базы (первый показ, загрузка SV,
-- массовые изменения). Единственное место, где происходит сортировка.
function NspRecentBuild(db)
    local st = NSP_RECENT
    st.max = NSP_CONST.MAX_ROWS
    local players = (db or GetDB()).players or {}
    local all, n = {}, 0
    for key, p in pairs(players) do
        local v = NspEffectiveTime(p)
        if v > 0 then
            n = n + 1
            all[n] = { v = v, p = p, key = key }
        end
    end
    table.sort(all, function(a, b)
        if a.v == b.v then return (a.p.name or "") < (b.p.name or "") end
        return a.v > b.v
    end)
    local list = {}
    for i = 1, math.min(n, st.max) do list[i] = all[i] end
    st.list = list
    st.dirty = false
    return list
end

-- NspEffectiveTime(p) — по какому времени запись стоит в списке.
--
-- Своя встреча даёт lastSeen; у записи, которую мы никогда не видели сами
-- (пришла по каналу обмена), lastSeen = 0, и её единственное время — peerAt.
-- Раньше буфер брал ТОЛЬКО lastSeen, поэтому peer-записи в него не попадали
-- вовсе: вкладка «Обмен новые» была пустой, а в «Свежих» их не было никогда
-- (возраст считался от нуля). global: в главном чанке 195 локалов из 200.
function NspEffectiveTime(p)
    if type(p) ~= "table" then return 0 end
    local ls = tonumber(p.lastSeen) or 0
    if ls > 0 then return ls end
    return tonumber(p.peerAt) or 0
end

-- NspRecentTouch(key, entry) — запись обновилась: вставить/переставить её.
-- Вызывается из UpsertPlayer при СОЗДАНИИ записи, при обновлении встречи и при
-- обновлении peerAt, поэтому буфер всегда актуален без пересортировки.
function NspRecentTouch(key, entry)
    local st = NSP_RECENT
    if st.dirty or not key or type(entry) ~= "table" then return end
    local v = NspEffectiveTime(entry)
    if v <= 0 then return end
    local list = st.list
    -- Уже в буфере? Тогда сначала убрать со старого места (обновилось время).
    local at = nil
    for i = 1, #list do
        if list[i].key == key then at = i break end
    end
    if at and at == 1 and (tonumber(list[1].v) or 0) >= v then return end
    if at then table.remove(list, at) end
    -- Позиция вставки: бинарный поиск по убыванию времени.
    local lo, hi = 1, #list + 1
    while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        if (tonumber(list[mid].v) or 0) >= v then lo = mid + 1 else hi = mid end
    end
    -- Хвост вытесняется: в списке не больше st.max записей.
    if lo > st.max then return end
    table.insert(list, lo, { v = v, p = entry, key = key })
    if #list > st.max then table.remove(list, #list) end
end

-- NspRecentInvalidate() — после массовых изменений (prune, миграции) буфер
-- мог разойтись с базой; проще перестроить на следующем показе, чем ловить
-- расхождение в пяти местах.
function NspRecentInvalidate()
    NSP_RECENT.dirty = true
end

-- NspBaseList(db, key) — порядок для окна.
--
-- lastSeen: готовый буфер, без сортировки.
-- peerAt: вкладка «Обмен новые» сортирует ТОЛЬКО буфер (500 элементов) — на
-- всей базе это было бы 70 мс, здесь доли миллисекунды.
function NspBaseList(db, key)
    key = key or "lastSeen"
    local st = NSP_RECENT
    if st.dirty or #st.list == 0 then NspRecentBuild(db) end
    if key == "lastSeen" then
        local out = {}
        for i = 1, #st.list do out[i] = st.list[i].p end
        return out
    end
    -- Другой ключ (peerAt): пересортировать копию буфера. Он маленький.
    local tmp = {}
    for i = 1, #st.list do
        local p = st.list[i].p
        tmp[i] = { v = tonumber(p[key]) or 0, p = p, nm = p.name }
    end
    table.sort(tmp, function(a, b)
        if a.v == b.v then return (a.nm or "") < (b.nm or "") end
        return a.v > b.v
    end)
    local out = {}
    for i = 1, #tmp do out[i] = tmp[i].p end
    return out
end

-- NspTopPlayers(db, key, limit, accept) — верхние `limit` из готового порядка.
--
-- accept (фильтр видимости) применяется ПРОХОДОМ по уже отсортированному
-- списку: никакой повторной сортировки. Это даёт «N самых свежих ИЗ
-- ПОДХОДЯЩИХ» за один линейный проход.
--
-- Записи без встречи (ключ = 0) в базовый список не входят: их 41 550 из
-- 61 435, до топа они не достают. Но если подходящих меньше `limit` (свежая
-- установка, редкий фильтр), добираем их вторым проходом — иначе на маленькой
-- базе исчезли бы все peer-записи, у которых нет нашей встречи.
function NspTopPlayers(db, key, limit, accept)
    key = key or "lastSeen"
    limit = tonumber(limit) or NSP_CONST.MAX_ROWS
    local base = NspBaseList(db, key)
    local out, m, seen = {}, 0, {}
    for i = 1, #base do
        local p = base[i]
        if not accept or accept(p) then
            m = m + 1
            out[m] = p
            seen[p] = true
            if m >= limit then return out, m end
        end
    end
    if m < limit then
        -- Добор записей БЕЗ времени (эффективное = 0). Проверка `seen`
        -- обязательна: peer-запись попадает в базовый список по времени пакета,
        -- а по ключу lastSeen её «нет» — без отметки она добавилась бы вторым
        -- экземпляром (поймано тестом: 5 строк вместо 3).
        local players = (db and db.players) or {}
        for _, p in pairs(players) do
            if not seen[p] and NspEffectiveTime(p) <= 0 and (not accept or accept(p)) then
                m = m + 1
                out[m] = p
                seen[p] = true
                if m >= limit then break end
            end
        end
    end
    return out, m
end

-- ============ UI ============
-- Fonts (16.10.2026): use the client's own font object, period. Measured on
-- the ruRU beta: explicit SetFont() on ANY file path renders nothing during
-- the first ~10-20s after a cold login (and FRIZQT__.TTF never renders at
-- all), while GameFontNormal renders Cyrillic from second zero. No bundled
-- TTF, no polling, no repaint hacks. GameFontNormal also matches the client's
-- locale (native CJK/Korean fonts on zhCN/koKR clients).
-- ApplyFont honours the requested size — through Blizzard FONT OBJECTS, never
-- through SetFont(path, size): an explicit file path renders nothing for the
-- first 10-20s after a cold login on this client (FRIZQT__.TTF never renders at
-- all), while a font object renders Cyrillic from second zero.
--
-- Until 09.11.2026 the size argument was ignored outright: every label rendered at
-- GameFontNormal, so "the realm tag is 8pt against a 12pt name" was a fiction and
-- no text in the window could be made smaller. Sizes <= 9 now map to the client's
-- own small font object, >= 14 to the large one, with a fallback to normal.
-- Global on purpose: the main chunk is at the Lua 5.1 ceiling of 200 locals.
function FontObjectFor(size)
    local n = tonumber(size) or 12
    -- Threshold 7, not 9: sizes 8 and 9 are used by the column headers, metric
    -- cards, class bars and counters, and mapping them to the small object shrank
    -- the whole window. Only genuinely secondary text (7) is small.
    if n <= 7 then
        return _G.GameFontNormalSmall or _G.GameFontHighlightSmall or GameFontNormal
    elseif n >= 14 then
        return _G.GameFontNormalLarge or _G.GameFontHighlightLarge or GameFontNormal
    end
    return GameFontNormal
end

local function ApplyFont(fs, size, flags)
    local obj = FontObjectFor(size)
    if obj and fs.SetFontObject then
        pcall(fs.SetFontObject, fs, obj)
    end
end

local function NewText(parent, size, r, g, b)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    ApplyFont(fs, size)
    fs:SetTextColor(r or 1, g or 1, b or 1, 1)
    return fs
end

local function ClassColorRGB(classFile)
    if classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile] then
        local c = RAID_CLASS_COLORS[classFile]
        return c.r or 1, c.g or 1, c.b or 1
    end
    return 1, 1, 1
end

-- Клавиатурный захват в бою (15.11.2026). Во время combat lockdown клиент
-- запрещает SetPropagateKeyboardInput и отвечает ADDON_ACTION_BLOCKED — в живом
-- SV такая блокировка уже была (NearbySpyHubWindow). Вызов всё равно ничего не
-- делал, но поднимал ложную тревогу в диагностике и разносил taint, поэтому в
-- бою его пропускаем и считаем в db.debug.kbLockdown. global: чанк у предела
-- в 200 локалов.
function NspKeyboardPropagate(frame, value)
    if type(frame) ~= "table" or not frame.SetPropagateKeyboardInput then return end
    if InCombatLockdown and InCombatLockdown() then
        local ok, db = pcall(GetDB)
        if ok and type(db) == "table" and type(db.debug) == "table" then
            db.debug.kbLockdown = (db.debug.kbLockdown or 0) + 1
            if not db.debug.kbLockdownLogged then
                db.debug.kbLockdownLogged = true
                D("keyboard capture skipped: combat lockdown (client blocks it anyway)")
            end
        end
        return
    end
    pcall(frame.SetPropagateKeyboardInput, frame, value)
end

-- Opaque underlay for every addon window (18.10.2026): on the beta the
-- template's Bg can render transparent, so an overlapping window shows
-- whatever window is behind it ("окна смешиваются"). Sublayer -7 keeps the
-- template's own bg (where it renders) on top; where it doesn't, this solid
-- color shows instead. pcall: cosmetic only, must never abort a window build.
local function SolidUnderlay(frame)
    local ok = pcall(function()
        local t = frame:CreateTexture(nil, "BACKGROUND", -7)
        t:SetAllPoints()
        t:SetColorTexture(0.03, 0.025, 0.02, 1)
    end)
    if not ok then
        pcall(function()
            local t = frame:CreateTexture(nil, "BACKGROUND")
            t:SetAllPoints()
            t:SetColorTexture(0.03, 0.025, 0.02, 1)
        end)
    end
end

-- Stacking helpers, method-existence guarded: this client cuts APIs before
-- (debug lib, combat log), and a cosmetic call aborting BuildWindow leaves a
-- window with chrome but no content.
local function StackWindow(frame, level)
    if frame.SetToplevel then
        local ok, err = pcall(frame.SetToplevel, frame, true)
        if not ok then DbgErr("toplevel", err) end
    end
    if frame.SetFrameLevel then
        local ok, err = pcall(frame.SetFrameLevel, frame, level)
        if not ok then DbgErr("framelevel", err) end
    end
end

-- Command help is a separate, read-only window; never put help into an EditBox.
local HELP_COMMANDS = {
    "/nspy [show]", "/nspy help", "/nspy suggest",
    "/nspy who", "/nspy whostop", "/nspy announce",
    "/nspy peer on", "/nspy peer off", "/nspy peer new",
    -- ask добавлен 26.11.2026: команда существовала, но в справке её не было —
    -- узнать о ней можно было только из чужого сообщения.
    "/nspy ask", "/nspy ask status",
    "/nspy reset", "/nspy server", "/nspy menu",
    "/nspy minimap", "/nspy settings", "/nspy me",
}

local HELP_TEXT = {
    enUS = { "Player window", "This command list", "Assisted /who: you click search; repeat to stop", "Assisted wide /who: you click search", "Stop a /who scan", "Toggle new-encounter chat messages", "Join the optional player-sharing channel", "Leave the channel and clear pending sends", "What the channel delivered - new to us only", "Ask peers for their newest records over the channel", "Ask: counters and open requests, nothing sent", "Clear the player database", "Server census window (needs NearbySpy_Data)", "Menu window (hub)", "Show/hide the minimap button", "Settings window (peer sharing)", "This character's journal: playtime, zones, encounters, level"},
    zhCN = { "玩家窗口", "命令列表", "辅助 /who：点击搜索；再次输入可停止", "辅助广域 /who：点击搜索", "停止 /who 扫描", "切换新遇见玩家的聊天提示", "加入可选的玩家共享频道", "退出频道并清空待发队列", "频道带来的新记录（仅新增）", "通过频道向其他玩家请求他们的最新记录", "请求：计数器和待答请求（不发送）", "清空玩家数据库", "服务器普查窗口(需要 NearbySpy_Data)", "菜单窗口 (hub)", "显示/隐藏小地图按钮", "设置窗口 (共享开关)", "本角色的日志：游戏时长、区域、遇见、等级"},
    ruRU = { "Окно игроков", "Список команд", "Помощник /who: нажимай лупу; повтор — стоп", "Широкий /who: жми лупу", "Остановить скан /who", "Вкл/выкл сообщения о новых встречах", "Вступить в канал обмена игроками", "Покинуть канал и очистить очередь", "Что пришло из канала — только новые для нас", "Спросить у пиров их свежие записи через канал", "Запрос: счётчики и открытые запросы, без отправки", "Очистить базу игроков", "Окно ценза сервера (нужен NearbySpy_Data)", "Окно меню (hub)", "Показать/скрыть кнопку миникарты", "Окно настроек (обмен)", "Журнал персонажа: время в игре, зоны, встречи, уровень"},
    deDE = { "Spielerfenster", "Befehlsübersicht", "Assistiertes /who: Suche anklicken; erneut = Stopp", "Breites /who: Suche anklicken", "/who-Scan stoppen", "Meldungen über neue Begegnungen umschalten", "Optionalem Austauschkanal beitreten", "Kanal verlassen und Warteschlange leeren", "Was der Kanal geliefert hat - nur neue für uns", "Andere Spieler über den Kanal nach ihren neuesten Einträgen fragen", "Abfrage: Zähler und offene Anfragen, ohne Senden", "Spielerdatenbank leeren", "Server-Zensusfenster (benötigt NearbySpy_Data)", "Menüfenster (Hub)", "Minimap-Button ein-/ausblenden", "Einstellungsfenster (Peer-Austausch)", "Journal dieses Charakters: Spielzeit, Zonen, Begegnungen, Stufe"},
    frFR = { "Fenêtre des joueurs", "Liste des commandes", "/who assisté : cliquer sur recherche ; répéter pour arrêter", "/who large assisté : cliquer recherche", "Arrêter le scan /who", "Activer/désactiver les annonces de rencontres", "Rejoindre le canal de partage facultatif", "Quitter le canal et vider la file", "Ce que le canal a livré - nouveaux uniquement", "Demander aux autres joueurs leurs entrées les plus récentes via le canal", "Requête : compteurs et demandes en attente, sans envoi", "Effacer la base des joueurs", "Fenêtre de recensement (nécessite NearbySpy_Data)", "Fenêtre de menu (hub)", "Afficher/masquer le bouton de la minicarte", "Fenêtre des réglages (partage peer)", "Journal du personnage : temps de jeu, zones, rencontres, niveau"},
    koKR = { "플레이어 창", "명령어 목록", "보조 /who: 검색 클릭, 다시 입력하면 중지", "보조 전체 /who: 검색 클릭", "/who 스캔 중지", "새 만남 채팅 알림 전환", "선택적 플레이어 공유 채널 참가", "채널 나가기 및 전송 대기열 비우기", "채널에서 받은 신규 기록만", "채널로 다른 플레이어에게 최신 기록을 요청합니다", "요청: 카운터와 대기 중인 요청 (전송 없음)", "플레이어 데이터베이스 삭제", "서버 센서스 창 (NearbySpy_Data 필요)", "메뉴 창 (허브)", "미니맵 버튼 표시/숨기기", "설정 창 (피어 공유)", "이 캐릭터의 일지: 플레이 시간, 지역, 만남, 레벨"},
}
local EffectiveLocale -- forward: defined with the settings selectors below
local helpWin
-- Скролл, холст, подписи команд и ширины колонок — ОДНОЙ глобальной таблицей.
-- Не локалами: главный чанк уже стоит на потолке Lua 5.1 в 200 локалов, и пять
-- «удобных» локалов не дают файлу скомпилироваться вовсе («main function has
-- more than 200 local variables»).
NspHelp = {CMD_W = 155, DESC_W = 440}

-- Раскладка пересчитывается на КАЖДОМ показе, а не строится один раз.
-- Причины, обе — воспроизведённые дефекты:
--   • описания берутся из таблицы локали, поэтому их ВЫСОТА зависит от языка:
--     русская и немецкая строка переносится на две строки там, где английская
--     помещается в одну. Шаг 25 px при этом накладывал строки друг на друга;
--   • 22 команды при том же шаге давали последнюю строку на y = -574 при окне
--     высотой 480 — пять нижних строк рисовались ВНЕ рамки.
-- Теперь шаг = высота самой высокой части строки + отступ, высота холста = сумма
-- строк, а окно растёт под содержимое и упирается в потолок экрана; всё, что не
-- влезло, доступно скроллом.
function HelpLayout()
    local H = NspHelp
    if not helpWin or not H.content then return end
    local descriptions = HELP_TEXT[EffectiveLocale()] or HELP_TEXT.enUS
    local y = 0
    for i = 1, #HELP_COMMANDS do
        local cmd, desc = H.cmd[i], helpWin.__descRows[i]
        desc:SetText(descriptions[i] or "")
        local descH = OptTextHeight(desc, 26)
        local labH = OptTextHeight(cmd, 14)
        local rowH = (descH > labH) and descH or labH
        if cmd.ClearAllPoints then cmd:ClearAllPoints() end
        cmd:SetPoint("TOPLEFT", H.content, "TOPLEFT", 0, y)
        if desc.ClearAllPoints then desc:ClearAllPoints() end
        desc:SetPoint("TOPLEFT", H.content, "TOPLEFT", H.CMD_W + 7, y)
        y = y - rowH - 7
    end
    H.content:SetSize(H.CMD_W + H.DESC_W + 7, -y + 2)
    -- Открываем всегда с первой строки: иначе после листания окно
    -- открывается «в середине», и первая же команда выглядит пропавшей.
    if H.scroll then pcall(function() H.scroll:SetVerticalScroll(0) end) end
    -- Потолок высоты — экран, а не константа: на 1366x768 окно в 600 px уже
    -- перекрывает пол-экрана, и кнопка закрытия уезжает под курсор.
    local cap = 600
    local okH, screenH = pcall(function() return UIParent:GetHeight() end)
    if okH and type(screenH) == "number" and screenH > 0 then
        local s = math.floor(screenH * 0.8)
        if s < cap then cap = s end
    end
    local needH = -y + 44 + 20
    local h = (needH < cap) and needH or cap
    if h < 240 then h = 240 end
    helpWin:SetSize(670, h)
end

-- Прокрутка колесом. Шаблон UIPanelScrollFrameTemplate в этом клиенте НЕ вешает
-- обработчик колеса: в аддоне не было ни одного OnMouseWheel, и окно справки
-- крутиться не хотело (в Mastercraft рядом то же делают вручную, через
-- GetVerticalScrollRange). Поэтому обработчик ставим сами и на сам ScrollFrame,
-- и на холст: иначе колесо работает только когда курсор попал в узкую полосу,
-- не занятую текстом.
-- Все вызовы под pcall: в другой сборке API может не быть, а падение здесь
-- означало бы нерабочее окно целиком.
function NspHelpScrollBy(delta)
    local sf = NspHelp.scroll
    if not sf then return end
    local ok, cur = pcall(function() return sf:GetVerticalScroll() end)
    if not ok or type(cur) ~= "number" then cur = 0 end
    local range = 0
    local okR, r = pcall(function() return sf:GetVerticalScrollRange() end)
    if okR and type(r) == "number" then range = r end
    -- delta > 0 — колесо от себя: содержимое едет ВВЕРХ, то есть значение
    -- вертикальной прокрутки РАСТЁТ. Знак был перепутан, и колесо упиралось в
    -- ноль на первом же щелчке (тест это и поймал).
    local step = 32 * (delta or 0)
    local next_ = cur + step
    if next_ < 0 then next_ = 0 end
    if next_ > range then next_ = range end
    pcall(function() sf:SetVerticalScroll(next_) end)
end

function NspHelpHookWheel(frame)
    if not frame then return end
    if frame.EnableMouseWheel then pcall(frame.EnableMouseWheel, frame, true) end
    if frame.SetScript then
        pcall(frame.SetScript, frame, "OnMouseWheel", function(_, delta)
            NspHelpScrollBy(delta)
        end)
    end
end

local function ShowHelpWindow()
    if not helpWin then
        helpWin = CreateFrame("Frame", "NearbySpyHelpWindow", UIParent)
        helpWin:SetSize(670, 480)
        helpWin:SetPoint("CENTER")
        helpWin:SetFrameStrata("DIALOG")
        -- window stacking (18.10.2026): guarded — cosmetic, must not abort build
        StackWindow(helpWin, 200)
        helpWin:SetMovable(true)
        helpWin:EnableMouse(true)
        helpWin:RegisterForDrag("LeftButton")
        helpWin:SetScript("OnDragStart", helpWin.StartMoving)
        helpWin:SetScript("OnDragStop", helpWin.StopMovingOrSizing)
        helpWin:EnableKeyboard(true)
        helpWin:SetScript("OnKeyDown", function(_, key)
            if key == "ESCAPE" then
                NspKeyboardPropagate(helpWin, false)
                helpWin:Hide()
            else
                NspKeyboardPropagate(helpWin, true)
            end
        end)
        local bg = helpWin:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.05, 0.05, 0.08, 0.96)
        SolidUnderlay(helpWin)
        local title = NewText(helpWin, 16, 0.4, 1, 0.6)
        title:SetPoint("TOPLEFT", 16, -14)
        title:SetText("NearbySpy — /nspy help  (/nearbyspy)")
        local okClose, close = pcall(CreateFrame, "Button", nil, helpWin, "UIPanelCloseButton")
        if okClose and close then
            close:SetPoint("TOPRIGHT", -6, -6)
            close:SetScript("OnClick", function() helpWin:Hide() end)
        else
            local btn = CreateFrame("Button", nil, helpWin)
            btn:SetSize(26, 26)
            btn:SetPoint("TOPRIGHT", -8, -8)
            local label = NewText(btn, 16, 1, 0.4, 0.4)
            label:SetPoint("CENTER")
            label:SetText("X")
            btn:SetScript("OnClick", function() helpWin:Hide() end)
        end
        -- Скролл, как в окне игроков: тот же шаблон, та же защита pcall (в этом
        -- клиенте шаблон может быть вырезан — тогда обычный ScrollFrame).
        local okSf, sf = pcall(CreateFrame, "ScrollFrame", nil, helpWin, "UIPanelScrollFrameTemplate")
        if not okSf or not sf then sf = CreateFrame("ScrollFrame", nil, helpWin) end
        sf:SetPoint("TOPLEFT", 16, -44)
        sf:SetPoint("BOTTOMRIGHT", -34, 16)
        NspHelp.scroll = sf
        local content = CreateFrame("Frame", nil, sf)
        content:SetSize(NspHelp.CMD_W + NspHelp.DESC_W + 7, 1)
        sf:SetScrollChild(content)
        -- Колесо вешаем на ОБА фрейма: на сам ScrollFrame (курсор между
        -- колонками и у края) и на холст (курсор на тексте). Шаблон в этом
        -- клиенте этого не делает — иначе окно не крутится вовсе.
        NspHelpHookWheel(sf)
        NspHelpHookWheel(content)
        -- Холст не должен перекрывать полосу прокрутки шаблона: справа 18 px
        -- уходят под неё, иначе за неё не взяться мышью.
        if sf.SetScrollChild and content.SetWidth then
            pcall(function() content:SetWidth(NspHelp.CMD_W + NspHelp.DESC_W + 7) end)
        end
        NspHelp.content = content
        local descRows, cmds = {}, {}
        helpWin.__descRows = descRows
        NspHelp.cmd = cmds
        for i, command in ipairs(HELP_COMMANDS) do
            local cmd = NewText(content, 12, 0.5, 1, 0.6)
            cmd:SetWidth(NspHelp.CMD_W)
            cmd:SetJustifyH("LEFT")
            cmd:SetText(command)
            cmds[i] = cmd
            local desc = NewText(content, 12, 0.9, 0.9, 0.9)
            desc:SetWidth(NspHelp.DESC_W)
            desc:SetJustifyH("LEFT")
            descRows[i] = desc
        end
    end
    -- Тексты и раскладка — на каждый показ: язык мог смениться в настройках.
    HelpLayout()
    helpWin:Show()
end

-- Main window state.
local win, winList

local function HideWindow()
    if win then win:Hide() end
end

-- Scout / Tactical window. It intentionally uses only basic textures and
-- frames: this keeps the UI compatible with the custom Forever client while
-- still looking distinct from the old flat list.
local tactical = {rows = {}, bars = {}, classes = {}, filters = {}, filter = "all", started = time()}
local TACTICAL_ROW_H = 30
local TACTICAL_FRESH = 300
local TacticalUpdate

local function TacticalPanel(parent)
    local panel = CreateFrame("Frame", nil, parent)
    local bg = panel:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.075, 0.06, 0.04, 0.97)
    local accent = panel:CreateTexture(nil, "BORDER")
    accent:SetPoint("TOPLEFT")
    accent:SetPoint("BOTTOMLEFT")
    accent:SetWidth(2)
    accent:SetColorTexture(0.55, 0.42, 0.18, 0.95)
    return panel
end

local function TacticalClassIcon(texture, classFile)
    local key = classFile and string.upper(classFile) or nil
    local coords = key and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[key]
    if coords then
        texture:SetTexture("Interface\\TargetingFrame\\UI-Classes-Circles")
        texture:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
        texture:SetVertexColor(1, 1, 1, 1)
    else
        texture:SetTexture(nil)
        texture:SetColorTexture(0.2, 0.16, 0.1, 1)
        texture:SetTexCoord(0, 1, 0, 1)
    end
end

-- Compact realm tag for the list: the channel is cluster-wide, so a row can come
-- from another realm. Its full name ("CAMWOW EU4 Realm 6 PvP") does not fit into
-- a 142px name column, so the part shared with OUR realm is dropped and the rest
-- is shown ("EU4 Realm 6 PvP"). Derived from the two names — nothing invented.
-- Global on purpose: the main chunk is at the Lua 5.1 ceiling of 200 locals.
function PeerRealmTag(realm, mine)
    if type(realm) ~= "string" or realm == "" then return nil end
    mine = mine or PlayerRealm()
    if realm == mine then return nil end
    local function Tokens(s)
        local t = {}
        for w in tostring(s):gmatch("%S+") do t[#t + 1] = w end
        return t
    end
    local mineT, theirs = Tokens(mine), Tokens(realm)
    -- Drop only the CLUSTER prefix ("CAMWOW"), i.e. shared tokens that carry no
    -- digits: a shared "Realm" or "EU5" is exactly what tells the realms apart
    -- ("CAMWOW EU5 Realm 2 PvE" must shrink to "EU5 Realm 2 PvE", not to
    -- "2 PvE").
    local i = 1
    while mineT[i] and theirs[i] and mineT[i] == theirs[i] and i < #theirs
        and not theirs[i]:find("%d") do
        i = i + 1
    end
    local tag = table.concat(theirs, " ", i)
    if tag == "" then tag = realm end
    -- 24 chars + ellipsis: past that it collides with the profile column
    if #tag > 24 then tag = NspCut(tag, 24) .. "..." end
    return tag
end

-- Badge under the player name for EVERY row, not only for foreign ones. Since
-- 15.11.2026 every realm shrinks to its bucket, ours included: "EU PvE" / "EU PvP".
-- Before, our own realm showed only the ruleset ("PvE") while a foreign one kept
-- shard and number ("EU4 Realm 6 PvP") — the same distinction displayed in two
-- different shapes, and a dozen near-identical labels in the selector.
-- Global: the main chunk is at the 200-local ceiling.
function RealmBadge(realm)
    if type(realm) ~= "string" or realm == "" then return nil end
    return RealmBucket(realm) or PeerRealmTag(realm) or realm
end

local function TacticalVisible(p, now, filt)
    -- filt — режим списка. Необязателен: обычные вызовы берут текущий режим,
    -- а счётчики табов передают его явно, чтобы посчитать все четыре режима за
    -- один проход, не дёргая глобальное состояние окна.
    filt = filt or tactical.filter
    -- Foreign peer rows are hidden as soon as the "all realms" flag is off:
    -- they were accepted while it was on, and a list that keeps showing them
    -- would contradict the setting the user just changed. Nothing is deleted —
    -- turning the flag back on brings them back.
    if p.peerForeign and GetDB().peerAllRealms == false then return false end
    -- ⚠️ Фильтров по миру, классу и уровню здесь БОЛЬШЕ НЕТ (26.11.2026,
    -- решение владельца): «фильтр убираем полностью, будет такое только на
    -- сайте». Окно показывает список последних встреч, а разрезы по мирам,
    -- классам и уровням делает сайт, где для этого есть вся база.
    -- Остались только режимы списка (все / свежие / новые / из канала) — это не
    -- фильтры, а разные выборки одного и того же порядка.
    if filt == "fresh" then
        -- Возраст — по ЭФФЕКТИВНОМУ времени (своя встреча ИЛИ время пакета):
        -- у записи канала lastSeen = 0, и `now - 0` делало её «старой на 56 лет»,
        -- поэтому в «Свежих» peer-записей не было никогда (замечание владельца
        -- 26.11.2026: «эти новые по обмену надо показывать в списке свежие»).
        local t = NspEffectiveTime(p)
        return t > 0 and (now - t) <= TACTICAL_FRESH
    elseif filt == "new" then
        -- Only OUR OWN finds. A peer record gets firstSeen at the moment the
        -- packet arrives, so it satisfied the time check and filled "New" with
        -- players somebody else met (215 of them in the live save). "New" answers
        -- "whom did I discover this session", so peer rows are excluded; they have
        -- their own filter.
        return (p.firstSeen or 0) >= tactical.started and p.source ~= "peer"
    elseif filt == "peern" then
        -- Только то, чему канал научил ЗА ЭТУ СЕССИЮ. peerNew/peerAt лежат в
        -- SavedVariables и живут после релога, поэтому без проверки на
        -- tactical.started вкладка показывала все записи канала за всё время
        -- (на живом файле — 1451 строка за 19 часов). Это ровно та же ошибка,
        -- что была у фильтра "new", и лечится так же.
        return (p.peerAt or 0) >= tactical.started and p.peerNew == true
    end
    return true
end

-- NspShortNum(v) — компактная запись больших счётчиков: 20257 → «20.3k».
--
-- В окне числа бывают шестизначными (всего в базе 63 401, «новых» за сессию
-- 20 257), и они распирали табы и карточки. До тысячи печатаем как есть —
-- точность там ещё что-то значит; дальше k/M с одним знаком после точки,
-- хвостовой «.0» убираем (1000 → «1k», 12400 → «12.4k»).
-- Точка, а не запятая: так в примере владельца (26.11.2026: «20.2k»).
-- global: в главном чанке 195 локалов из 200, новые сущности — только глобалы.
function NspShortNum(v)
    v = tonumber(v) or 0
    if v < 1000 then return tostring(math.floor(v + 0.5)) end
    local div, unit = 1000, "k"
    -- 999 500 при округлении превращается в «1000k»; это уже мега, поэтому
    -- перескакиваем единицу заранее (проверено на границах 999499/999500).
    if v >= 999500 then div, unit = 1000000, "M" end
    if v >= 999500000 then div, unit = 1000000000, "B" end
    local x = v / div
    -- три знака перед точкой уже не сокращаются, дробь только мешает
    local s = (x >= 100) and string.format("%.0f", x) or string.format("%.1f", x)
    s = string.gsub(s, "%.0$", "")
    return s .. unit
end

-- NspTabCounts(now) — числа на табах.
--
-- Два разных смысла, так решил владелец 26.11.2026:
--   • «Свежие» и «Обмен новые» — сколько строк ОТКРОЕТСЯ по клику. Раньше здесь
--     считалась вся база (63 391 запись), а список берётся из буфера последних
--     500 — на вкладке «Обмен новые» стояло 953 при 462 строках (жалоба:
--     «в табе число отличается от списка в обмене»). Поэтому считается ровно тем
--     же NspTopPlayers с тем же фильтром и пределом, что и список.
--   • «Новые» — сколько новых ВСЕГО за сессию, даже если в списке помещается
--     только MAX_ROWS (просьба: «для новых надо показывать счётчик больше 500,
--     показывать всего сколько новых, но отображаем только 500»).
--   • «Все» — числа нет вовсе: это размер базы, а не список.
--
-- out.newAll — общее число новых, out[filt] — длина списка режима.
-- Кэш на 3 с, как у списка и агрегатов: полный проход по базе стоит десятки мс.
-- global: новых локалов в главном чанке нет (195 из 200).
function NspTabCounts(now)
    local db = GetDB()
    -- Новые зависят ещё и от начала сессии, а не только от данных и флага.
    local key = table.concat({
        tostring(db.peerAllRealms), tostring(tactical.started),
        tostring(math.floor(now / 3)),
    }, "|")
    local cached = tactical.tabCache
    if cached and cached.key == key then return cached.n end
    local out = {}
    local modes = { "all", "fresh", "new", "peern" }
    for i = 1, #modes do
        local filt = modes[i]
        -- Порядок вкладки peer — по времени пакета, остальных — по нашей встрече.
        local sortKey = (filt == "peern") and "peerAt" or "lastSeen"
        local _, shown = NspTopPlayers(db, sortKey, NSP_CONST.MAX_ROWS, function(p)
            return TacticalVisible(p, now, filt)
        end)
        out[filt] = shown or 0
    end
    local newAll = 0
    for _, p in pairs(db.players or {}) do
        if TacticalVisible(p, now, "new") then newAll = newAll + 1 end
    end
    out.newAll = newAll
    tactical.tabCache = { key = key, n = out }
    return out
end

-- Relative time for the contact column: freshness reads at a glance
-- ("3 min ago"), old entries get a short date. Lua 5.1: math.floor only.
local function TimeAgo(ts)
    if not ts or ts == 0 then return "?" end
    local d = time() - ts
    if d < 60 then return L("TIME_NOW") end
    if d < 3600 then return L("TIME_MIN"):format(math.floor(d / 60)) end
    if d < 86400 then return L("TIME_HOUR"):format(math.floor(d / 3600)) end
    return date("%d.%m", ts)
end

local function TacticalRow(parent, index)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(NSP_CONST.LIST_W, TACTICAL_ROW_H)
    -- Позиция задаётся ЗДЕСЬ и только здесь: индекс строки неизменен, поэтому
    -- ставить точку при каждой перерисовке (было ClearAllPoints + SetPoint на
    -- 500 строк = 1000 вызовов клиента впустую) незачем.
    row:SetPoint("TOPLEFT", 0, -(index - 1) * TACTICAL_ROW_H)
    row._nspShown = false
    row:EnableMouse(true)
    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    row.bg:SetColorTexture(index % 2 == 0 and 0.09 or 0.06, index % 2 == 0 and 0.075 or 0.05, index % 2 == 0 and 0.05 or 0.035, 0.9)
    row.hover = row:CreateTexture(nil, "ARTWORK")
    row.hover:SetAllPoints()
    row.hover:SetColorTexture(0.24, 0.17, 0.06, 0.75)
    row.hover:Hide()
    row.icon = row:CreateTexture(nil, "OVERLAY")
    row.icon:SetSize(20, 20)
    row.icon:SetPoint("LEFT", 6, 0)
    -- The name sits a bit higher than the row centre so the realm tag fits
    -- underneath it: 12pt + 8pt + gap is ~26px in a 30px row. The tag is a
    -- SEPARATE FontString, not a colour code appended to the name — one string
    -- cannot carry two sizes, and appending it to the name pushed the name
    -- itself off its column.
    -- Column offsets come from NSP_CONST: the table header reads the SAME
    -- numbers, so a width change can never leave the headings misaligned.
    row.name = NewText(row, 12)
    row.name:SetPoint("LEFT", NSP_CONST.COL_NAME_X, 5)
    row.name:SetWidth(NSP_CONST.COL_NAME_W)
    row.name:SetJustifyH("LEFT")
    -- 7pt: the realm is a dim annotation, not data the eye should land on first.
    -- 12pt name + 7pt tag + gap is ~24px in a 30px row, so nothing clips; the
    -- name moved 5px up (was 4) to keep the pair centred.
    row.realm = NewText(row, 7, 0.55, 0.5, 0.4)
    row.realm:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, 0)
    row.realm:SetWidth(NSP_CONST.COL_NAME_W)
    row.realm:SetJustifyH("LEFT")
    row.realm:Hide()
    row.profile = NewText(row, 11, 0.82, 0.79, 0.72)
    row.profile:SetPoint("LEFT", NSP_CONST.COL_PROF_X, 0)
    row.profile:SetWidth(NSP_CONST.COL_PROF_W)
    row.profile:SetJustifyH("LEFT")
    row.zone = NewText(row, 11, 0.6, 0.55, 0.45)
    row.zone:SetPoint("LEFT", NSP_CONST.COL_ZONE_X, 0)
    row.zone:SetWidth(NSP_CONST.COL_ZONE_W)
    row.zone:SetJustifyH("LEFT")
    row.seen = NewText(row, 10, 0.45, 0.5, 0.5)
    row.seen:SetPoint("LEFT", NSP_CONST.COL_SEEN_X, 0)
    row.seen:SetWidth(NSP_CONST.COL_SEEN_W)
    row.seen:SetJustifyH("LEFT")
    row:SetScript("OnEnter", function(self)
        self.hover:Show()
        local p = self.player
        if not p or not GameTooltip then return end
        local r, g, b = ClassColorRGB(p.class)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(p.name or "?", r, g, b)
        GameTooltip:AddLine(ClassDisplayName(p.class, p.classLoc)
            .. "; " .. L("LVL_PREFIX") .. tostring(p.level or "?"), 0.82, 0.88, 0.88)
        GameTooltip:AddLine(L("UI_ZONE") .. ": " .. ZoneDisplay(p.zoneId, p.zone), 0.65, 0.72, 0.72)
        if p.peerForeign and p.realm and p.realm ~= "" then
            -- A peer record from another realm: someone else in the channel met
            -- this player, we did not. The full realm has no room in the list,
            -- so the row carries a short tag next to the name and the truth is
            -- here.
            GameTooltip:AddLine(L("UI_REALM") .. ": " .. tostring(p.realm), 0.7, 0.62, 0.45)
        end
        -- firstSeen/lastSeen = 0 means "never observed by us" (a peer row): date(0)
        -- would print 01.01.1970, so the absence is printed as "?" and the peer
        -- packet time takes the contact line instead.
        local fs, ls = p.firstSeen or 0, p.lastSeen or 0
        local contact = (ls > 0 and date("%d.%m.%Y %H:%M", ls)) or
            ((p.peerAt or 0) > 0 and (date("%d.%m.%Y %H:%M", p.peerAt) .. " (" .. L("UI_PEER") .. ")") or "?")
        GameTooltip:AddLine(L("UI_FIRST") .. ": " .. ((fs > 0 and date("%d.%m.%Y %H:%M", fs)) or "?"), 0.58, 0.65, 0.65)
        GameTooltip:AddLine(L("UI_CONTACT") .. ": " .. contact, 0.58, 0.65, 0.65)
        GameTooltip:AddLine(L("UI_SOURCE") .. ": " .. tostring(p.source or "?"), 0.45, 0.72, 0.62)
        GameTooltip:AddLine(L("UI_ENCOUNTERS") .. ": " .. tostring(p.count or 1), 0.45, 0.72, 0.62)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function(self)
        self.hover:Hide()
        if GameTooltip then GameTooltip:Hide() end
    end)
    tactical.rows[index] = row
    return row
end

-- NspSetText(row, field, fs, text) — SetText только при изменении.
--
-- Замер перерисовки списка на живом SV: 500 строк = 8001 вызов клиентского API
-- (16 на строку), то есть 40–160 мс в клиенте НА КАЖДУЮ отрисовку. Больше
-- половины этих вызовов — SetText/SetTextColor одними и теми же значениями:
-- список перерисовывается при OnShow, при повторном клике по тому же фильтру,
-- при смене реалма (содержимое строк при этом не меняется).
-- Сравнение строк в Lua бесплатно против C-вызова в клиент.
-- global: в главном чанке 197 локалов из 200.
function NspSetText(row, field, fs, text)
    local cache = row._nspText
    if not cache then cache = {}; row._nspText = cache end
    if cache[field] == text then return end
    cache[field] = text
    fs:SetText(text)
end

-- NspSetColor(row, field, fs, r, g, b) — SetTextColor только при изменении.
function NspSetColor(row, field, fs, r, g, b)
    local cache = row._nspColor
    if not cache then cache = {}; row._nspColor = cache end
    local key = r .. "," .. g .. "," .. b
    if cache[field] == key then return end
    cache[field] = key
    fs:SetTextColor(r, g, b)
end

local function TacticalRows()
    local now, shown = time(), 0
    -- Свежесть — по времени пакета для вкладки «Обмен новые», иначе по нашей
    -- встрече. Фильтр (TacticalVisible) применяется ВНУТРИ отбора: так список
    -- остаётся «N самых свежих ИЗ ПОДХОДЯЩИХ», а не «N самых свежих, из которых
    -- подходящих может не оказаться».
    local key = (tactical.filter == "peern") and "peerAt" or "lastSeen"
    -- ── Кэш списка (26.11.2026) ─────────────────────────────────────────────
    -- ⚠️ Ключ НЕ содержит версию данных. Первая версия кэша была привязана к
    -- счётчику записей, а он растёт на КАЖДУЮ запись игрока (UpsertPlayer) — в городе
    -- записи идут непрерывно, поэтому кэш промахивался ВСЕГДА и фризы остались
    -- (живая жалоба владельца: «чувствуется фризы на секунду при фильтрах»).
    -- Окну статистики точность до последней записи не нужна: TTL в 3 с даёт
    -- ответ «свежий на глаз» и делает повторные клики бесплатными.
    local bucket = math.floor(now / 3)
    local cacheKey = table.concat({
        tostring(tactical.filter), tostring(GetDB().peerAllRealms), tostring(bucket),
    }, "|")
    local cache = tactical.listCache
    local list
    if cache and cache.key == cacheKey then
        list = cache.list
        tactical.cacheHits = (tactical.cacheHits or 0) + 1
    else
        list = NspTopPlayers(GetDB(), key, NSP_CONST.MAX_ROWS, function(p)
            return TacticalVisible(p, now)
        end)
        tactical.listCache = { key = cacheKey, list = list }
        tactical.cacheMiss = (tactical.cacheMiss or 0) + 1
    end
    for i = 1, #list do
        local p = list[i]
        shown = i
        local row = tactical.rows[shown] or TacticalRow(winList, shown)
        -- Позиция зависит ТОЛЬКО от индекса строки, а строка переиспользуется
        -- на том же индексе — значит ClearAllPoints/SetPoint достаточно сделать
        -- один раз, при создании (их делает TacticalRow). Раньше на каждой
        -- отрисовке уходило 1000 вызовов клиента впустую.
        row.player = p
        if row._nspClass ~= p.class then
            row._nspClass = p.class
            TacticalClassIcon(row.icon, p.class)
        end
        -- The realm goes UNDER the name in a smaller font — for our own
        -- records too, so one list never mixes labelled and unlabelled rows.
        -- Never into the ZONE column: that column is for locations.
        local realmTag = RealmBadge(p.realm)
        NspSetText(row, "name", row.name, p.name or "?")
        local cr, cg, cb = ClassColorRGB(p.class)
        NspSetColor(row, "name", row.name, cr, cg, cb)
        if realmTag then
            NspSetText(row, "realm", row.realm, realmTag)
            if not row._nspRealmShown then
                row._nspRealmShown = true
                row.realm:Show()
            end
        else
            NspSetText(row, "realm", row.realm, "")
            if row._nspRealmShown ~= false then
                row._nspRealmShown = false
                row.realm:Hide()
            end
        end
        NspSetText(row, "profile", row.profile, ("%s; %s%s"):format(
            ClassDisplayName(p.class, p.classLoc),
            L("LVL_PREFIX"), tostring(p.level or "?")))
        -- Peer records carry no position or zone at all (the packet has
        -- neither), so a peer row honestly has no zone.
        NspSetText(row, "zone", row.zone, ZoneDisplay(p.zoneId, p.zone))
        -- In the peer list the CONTACT column answers "when did this arrive
        -- over the channel", which is the only timestamp a peer row has.
        -- Everywhere else our own sighting wins; a peer row has none
        -- (lastSeen = 0 since 1.5.3), so it falls back to the packet time
        -- instead of showing "?" for a contact we do know.
        local stamp = (p.lastSeen or 0) > 0 and p.lastSeen or p.peerAt
        if tactical.filter == "peern" and (p.peerAt or 0) > 0 then stamp = p.peerAt end
        local age = now - (stamp or 0)
        NspSetText(row, "seen", row.seen, TimeAgo(stamp))
        if age <= 300 then NspSetColor(row, "seen", row.seen, 0.3, 0.9, 0.62)
        elseif age <= 3600 then NspSetColor(row, "seen", row.seen, 0.88, 0.72, 0.32)
        else NspSetColor(row, "seen", row.seen, 0.45, 0.5, 0.5) end
        if not row._nspShown then
            row._nspShown = true
            row:Show()
        end
    end
    -- Скрываем только ХВОСТ прошлого показа, а не все строки в начале: при
    -- 500 строках «скрыть всё, потом показать всё» — это 1000 лишних вызовов
    -- клиента на каждую отрисовку.
    local prev = tactical.shownCount or 0
    if prev > shown then
        for i = shown + 1, prev do
            local row = tactical.rows[i]
            if row and row._nspShown then
                row._nspShown = false
                row:Hide()
            end
        end
    end
    tactical.shownCount = shown
    winList:SetHeight(math.max(1, shown * TACTICAL_ROW_H))
    return shown
end

local function TacticalStats()
    -- Кэш агрегатов (26.11.2026). Проход по 61 435 записям стоит ~21 мс в lupa
    -- (~50–100 мс в клиенте) и повторяется на каждую отрисовку, хотя зависит
    -- только от данных, выбранного реалма и текущего времени (счётчики «5 мин /
    -- 15 мин / 1 час»). Ключ: реалм + окно 3 с.
    local now = time()
    -- Ключ кэша: только настройка «все миры канала» и окно времени. Фильтров
    -- мира/класса/уровня больше нет (26.11.2026), поэтому и в ключе их нет.
    local statsBucket = math.floor(now / 3)
    local cacheKey = table.concat({
        tostring(GetDB().peerAllRealms), tostring(statsBucket),
    }, "|")
    local cached = tactical.statsCache
    if cached and cached.key == cacheKey then
        tactical.statsHits = (tactical.statsHits or 0) + 1
        return cached.st
    end
    -- f5/newN/peerNewN убраны 26.11.2026: числа на табах и их карточках
    -- считает NspTabCounts тем же отбором, что строит список.
    local st = {total = 0, f15 = 0, f60 = 0, alliance = 0, horde = 0, unknown = 0, levelN = 0, levelSum = 0, level = {}, classes = {}}
    for _, p in pairs(GetDB().players) do
        st.total = st.total + 1
        -- Возраст — по эффективному времени (своя встреча ИЛИ время пакета),
        -- иначе «15m/1h» не считали бы записи канала, хотя «Свежие» их показывают.
        local age = now - NspEffectiveTime(p)
        if age <= 900 then st.f15 = st.f15 + 1 end
        if age <= 3600 then st.f60 = st.f60 + 1 end
        if p.faction == "Alliance" then st.alliance = st.alliance + 1
        elseif p.faction == "Horde" then st.horde = st.horde + 1
        else st.unknown = st.unknown + 1 end
        local level = tonumber(p.level)
        if level and level >= 1 and level <= 60 then
            st.levelN = st.levelN + 1
            st.levelSum = st.levelSum + level
            st.level[level] = (st.level[level] or 0) + 1
        end
        local file = p.class or "UNKNOWN"
        if not st.classes[file] then
            st.classes[file] = {file = file,
                label = ClassDisplayName(p.class, p.classLoc), count = 0}
        end
        st.classes[file].count = st.classes[file].count + 1
    end
    st.top = {}
    for _, item in pairs(st.classes) do st.top[#st.top + 1] = item end
    table.sort(st.top, function(a, b) return a.count > b.count end)
    tactical.statsCache = { key = cacheKey, st = st }
    tactical.statsMiss = (tactical.statsMiss or 0) + 1
    return st
end

local function TacticalSources()
    local s = (GetDB().debug and GetDB().debug.src) or {}
    local parts, shown = {}, {}
    -- Название источника берём из локалей: ключи в SV остаются техническими
    -- (unit/who/chat/guild/peer), но игроку в статус-строке нужен человеческий
    -- текст. Незнакомый источник печатается сырым ключом — он не должен
    -- молча исчезать из строки статуса.
    local function label(key)
        local k = "SRC_" .. string.upper(key)
        local t = L(k)
        return (t ~= k) and t or key
    end
    for _, key in ipairs({ "unit", "guild", "chat", "who" }) do
        local n = tonumber(s[key]) or 0
        -- Нулевой источник в строку не пишем: она отвечает на вопрос «что
        -- реально кормит базу сейчас», а "гильдия 0; чат 0" — шум. Новые
        -- источники ниже выводятся только при > 0 по той же причине.
        if n > 0 then parts[#parts + 1] = label(key) .. " " .. n end
        shown[key] = true
    end
    for key, value in pairs(s) do
        if not shown[key] and type(value) == "number" and value > 0 then
            parts[#parts + 1] = label(tostring(key)) .. " " .. value
        end
    end
    if #parts == 0 then return L("SRC_LINE") .. L("SRC_EMPTY") end
    return L("SRC_LINE") .. table.concat(parts, "; ")
end

local function TacticalFilterState(button, active)
    button.bg:SetColorTexture(active and 0.3 or 0.1, active and 0.22 or 0.08, active and 0.08 or 0.05, 1)
    if active then button.label:SetTextColor(1, 0.85, 0.45)
    else button.label:SetTextColor(0.62, 0.55, 0.42) end
end

-- Bucket of a realm: region + ruleset ("EU PvP", "EU PvE", "EU RP PvP").
-- The cluster's realms are "CAMWOW EU4 Realm 6 PvP" / "CAMWOW EU5 Realm 1 PvE";
-- showing the shard and the realm number multiplied the same distinction across a
-- dozen near-identical labels (user decision 15.11.2026: no multiplying layers).
-- What actually matters when picking someone out of the list is the region and
-- the ruleset, so both the badge and the selector use this. Stored data is NOT
-- touched: p.realm keeps the full name for the site export and dedup keys.
-- Global: the main chunk is at the 193rd of its 200 locals.
-- Кэш «имя реалма → bucket» (26.11.2026).
--
-- RealmBucket парсит строку: gmatch в таблицу, поиск токена Realm, два gsub,
-- concat. Замер на живом SV (61 435 записей): один проход по базе с вызовом
-- RealmBucket на КАЖДОЙ записи — 136 мс из 248, то есть больше половины
-- стоимости перерисовки списка И агрегатов. При этом уникальных имён реалмов
-- в базе ПЯТНАДЦАТЬ: парсить одну и ту же строку 61 тысячу раз незачем.
-- Ключ — сама строка (в Lua 5.1 строки интернируются, lookup дешёвый).
-- global: в главном чанке 197 локалов из 200.
-- ⚠️ Кэш инициализируется здесь, но RealmBucket к нему ТЕРПИМ: харнессы
-- вырезают функцию без этого файла, и жёсткая зависимость роняла бы девять
-- чужих тестов «attempt to index global 'NSP_BUCKET_CACHE'».
NSP_BUCKET_CACHE = NSP_BUCKET_CACHE or {}

function RealmBucket(realm)
    if type(realm) ~= "string" or realm == "" then return nil end
    local cache = NSP_BUCKET_CACHE
    if type(cache) ~= "table" then return RealmBucketCompute(realm) end
    local hit = cache[realm]
    if hit ~= nil then
        -- false = «уже считали, bucket пустой» (отличимо от «не считали»)
        if hit == false then return nil end
        return hit
    end
    local result = RealmBucketCompute(realm)
    cache[realm] = result or false
    return result
end

-- RealmBucketCompute(realm) — сам разбор, без кэша. Отдельной функцией, чтобы
-- кэш не смешивался с логикой и её можно было проверить тестом напрямую.
function RealmBucketCompute(realm)
    if type(realm) ~= "string" or realm == "" then return nil end
    local t = {}
    for w in realm:gmatch("%S+") do t[#t + 1] = w end
    -- Find "Realm" and the number after it: everything past the number is the
    -- ruleset ("PvE", "PvP", "RP PvP"), the token before "Realm" is the region.
    local at
    for i = 2, #t do
        if t[i] == "Realm" and tonumber(t[i + 1] or "") then at = i break end
    end
    if not at then
        -- Unknown layout (another cluster, a renamed realm): keep it readable and
        -- drop only the project prefix, as the badge always did.
        local from = (#t >= 3) and 2 or 1
        return table.concat(t, " ", from)
    end
    -- gsub returns (string, count): the parentheses keep the count from leaking
    -- into a caller like ("%s"):format(RealmBucket(x)).
    local region = ((t[at - 1] or ""):gsub("%d+$", ""))
    local rules = table.concat(t, " ", at + 2)
    if region == "" then region = t[1] or "" end
    if rules == "" then return region end
    return ((region .. " " .. rules):gsub("^%s+", ""))
end

-- Compact realm name for the cycler button when the bucket cannot be derived:
-- "CAMWOW EU4 Realm 6 PvP" -> "EU4 Realm 6 PvP". Only the leading cluster prefix
-- is dropped — the rest is what tells the realms apart, so nothing is invented.
-- Global on purpose: the main chunk is at the Lua 5.1 ceiling of 200 locals.
function RealmShortName(realm)
    if type(realm) ~= "string" or realm == "" then return "?" end
    local t = {}
    for w in realm:gmatch("%S+") do t[#t + 1] = w end
    -- the first token is the project prefix when there are at least three
    local from = (#t >= 3) and 2 or 1
    return table.concat(t, " ", from)
end

local function TacticalFilter(parent, key, x)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(NSP_CONST.FILTER_W, 25)
    button:SetPoint("LEFT", x, 0)
    button.bg = button:CreateTexture(nil, "BACKGROUND")
    button.bg:SetAllPoints()
    button.label = NewText(button, 10)
    button.label:SetPoint("CENTER")
    -- Ширина подписи = ширина кнопки минус поля. Подпись рисуется
    -- GameFontNormal (12pt): в 106px "Partage nouveaux 1451" переносилась на
    -- вторую строку и вылезала за кнопку высотой 25px.
    button.label:SetWidth(NSP_CONST.FILTER_W - 6)
    button.key = key
    button:SetScript("OnClick", function(self) tactical.filter = self.key; TacticalUpdate() end)
    button:SetScript("OnEnter", function(self) if tactical.filter ~= self.key then self.bg:SetColorTexture(0.18, 0.13, 0.06, 1) end end)
    button:SetScript("OnLeave", function(self) TacticalFilterState(self, tactical.filter == self.key) end)
    tactical.filters[key] = button
end

-- ⚠️ Фильтры мира, класса и уровня УДАЛЕНЫ 26.11.2026 по решению владельца:
-- «фильтр убираем полностью, будет такое только на сайте». Вместе с ними ушли
-- селекторы (TacticalRealmCycler/TacticalClassCycler/TacticalLevelCycler и их
-- State-функции), списки значений для них и клик-фильтр по столбцу гистограммы.
-- Разрезы по мирам, классам и уровням делает сайт, где есть вся база; окно
-- показывает только список последних встреч.

local function TacticalMetric(parent, x, width, label)
    local card = TacticalPanel(parent)
    card:SetPoint("TOPLEFT", x, -52)
    card:SetSize(width, 55)
    card.label = NewText(card, 9, 0.62, 0.55, 0.4)
    card.label:SetPoint("TOPLEFT", 10, -7)
    card.label:SetText(label)
    card.value = NewText(card, 17, 0.95, 0.92, 0.85)
    card.value:SetPoint("BOTTOMLEFT", 10, 8)
    card.detail = NewText(card, 9, 0.75, 0.6, 0.3)
    card.detail:SetPoint("BOTTOMRIGHT", -9, 9)
    return card
end

TacticalUpdate = function()
    -- The widgets are built lazily by BuildWindow(): a caller that runs before
    -- the player window was ever opened has nothing to update. Without this the
    -- update died on `tactical.total.value` (nil) — seen in game 09.11.2026 when
    -- the realm checkbox repainted the list from the settings window.
    if not tactical.total then return end
    local ok, err = pcall(function()
        local st = TacticalStats()
        -- Числа, у которых есть одноимённый таб, берём из отбора списка
        -- (NspTabCounts), иначе «на табе 462» спорит с «в списке 462».
        -- Карточки-статистики (всего в базе, фракции, уровни, классы, 15m/1h)
        -- остаются по всей базе: они про базу, а не про список.
        local tabN = NspTabCounts(time())
        tactical.total.value:SetText(NspShortNum(st.total))
        tactical.total.detail:SetText("+" .. NspShortNum(tabN.newAll) .. " " .. L("UI_NEW_SHORT"))
        tactical.fresh.value:SetText(NspShortNum(tabN.fresh))
        tactical.fresh.detail:SetText(("15m %s; 1h %s"):format(NspShortNum(st.f15), NspShortNum(st.f60)))
        tactical.factions.value:SetText(("|cffff6666%s %s|r ; |cff6699ff%s %s|r"):format(L("HORDE"), NspShortNum(st.horde), L("ALLIANCE"), NspShortNum(st.alliance)))
        tactical.factions.detail:SetText(st.unknown > 0 and ("? " .. NspShortNum(st.unknown)) or "")

        local maxCount, peakLevel = 0, 0
        for level = 1, 60 do
            local count = st.level[level] or 0
            if count > maxCount then maxCount, peakLevel = count, level end
        end
        for level = 1, 60 do
            local bar, count = tactical.bars[level], st.level[level] or 0
            bar:SetHeight(maxCount > 0 and math.max(1, math.floor(NSP_CONST.LEVEL_CHART_H * count / maxCount + 0.5)) or 1)
            if level == peakLevel then bar:SetColorTexture(0.98, 0.8, 0.35, 1)
            else bar:SetColorTexture(0.12, 0.55 + level / 400, 0.42 + level / 500, 0.92) end
        end
        if maxCount > 0 then
            tactical.chartLabel:SetText(L("CHART_LABEL"):format(
                NspShortNum(st.levelN), NspShortNum(maxCount),
                peakLevel, st.levelSum / st.levelN))
        else tactical.chartLabel:SetText(L("CHART_EMPTY")) end

        for i = 1, NSP_CONST.CLASS_BARS do
            local row, item = tactical.classes[i], st.top[i]
            if item and st.top[1].count > 0 then
                row:Show()
                TacticalClassIcon(row.icon, item.file)
                row.label:SetText(item.label)
                row.label:SetTextColor(0.85, 0.82, 0.75)
                -- count + share of all players: the top classes are nearly
                -- equal (3026/2992/2894), a pure max-relative bar looks flat
                row.value:SetText(("%s (%.0f%%)"):format(NspShortNum(item.count), 100 * item.count / math.max(1, st.total)))
                local r, g, b = ClassColorRGB(item.file)
                if row.bar then
                    row.bar:SetMinMaxValues(0, st.top[1].count)
                    row.bar:SetValue(item.count)
                    row.bar:SetStatusBarColor(r, g, b, 0.9)
                else
                    row.fill:SetWidth(math.max(1, math.floor(100 * item.count / st.top[1].count + 0.5)))
                    row.fill:SetColorTexture(r, g, b, 0.9)
                end
            else row:Hide() end
        end

        -- Числа на табах — из NspTabCounts: у «Свежих» и «Обмена» это длина
        -- списка (не спорят с ним), у «Новых» — сколько новых ВСЕГО за сессию,
        -- даже если в список помещается только 500. У «Все» числа нет: это
        -- размер базы, а не список (решение владельца 26.11.2026).
        tactical.filters.all.label:SetText(L("UI_ALL"))
        tactical.filters.fresh.label:SetText(L("UI_FRESH") .. " " .. NspShortNum(tabN.fresh))
        tactical.filters.new.label:SetText(L("UI_NEW") .. " " .. NspShortNum(tabN.newAll))
        tactical.filters.peern.label:SetText(L("UI_PEER_NEW") .. " " .. NspShortNum(tabN.peern))
        for key, button in pairs(tactical.filters) do TacticalFilterState(button, key == tactical.filter) end
        tactical.count:SetText(NspShortNum(TacticalRows()) .. " / " .. NspShortNum(st.total))
        tactical.status:SetText("|cff45dc9b+|r " .. L("UI_LIVE") .. " ; " .. TacticalSources())
    end)
    if not ok then P(L("ERR_LIST") .. tostring(err)) end
end

local function BuildWindow()
    -- Blizzard-native chrome first: the Forever build ships the modern panel
    -- template (Blizzard_UIPanelTemplates/Mainline/UIPanelTemplates.xml).
    -- Template text uses GameFont objects, which are empty in this client, so
    -- the bundled font is applied onto TitleText explicitly. If the template
    -- is missing, fall back to hand-drawn gold chrome in the same palette.
    local okTpl, tplWin = pcall(CreateFrame, "Frame", "NearbySpyWindow", UIParent, "BasicFrameTemplateWithInset")
    if okTpl and tplWin and tplWin.TitleText and tplWin.Bg and tplWin.CloseButton then
        win = tplWin
    else
        if tplWin and tplWin.Hide then tplWin:Hide() end
        win = CreateFrame("Frame", "NearbySpyWindow", UIParent)
        local bg = win:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(); bg:SetColorTexture(0.03, 0.025, 0.02, 0.97)
        local header = win:CreateTexture(nil, "BORDER")
        header:SetPoint("TOPLEFT", 1, -1); header:SetPoint("TOPRIGHT", -1, -1); header:SetHeight(42)
        header:SetColorTexture(0.18, 0.13, 0.06, 1)
        for _, edge in ipairs({
            {"TOPLEFT", "TOPRIGHT", true}, {"BOTTOMLEFT", "BOTTOMRIGHT", true},
            {"TOPLEFT", "BOTTOMLEFT", false}, {"TOPRIGHT", "BOTTOMRIGHT", false},
        }) do
            local texture = win:CreateTexture(nil, "OVERLAY")
            texture:SetPoint(edge[1]); texture:SetPoint(edge[2])
            if edge[3] then texture:SetHeight(1) else texture:SetWidth(1) end
            texture:SetColorTexture(0.55, 0.42, 0.18, 1)
        end
        win.TitleText = NewText(win, 14, 1, 0.82, 0)
        ApplyFont(win.TitleText, 14, "OUTLINE")
        win.TitleText:SetPoint("TOPLEFT", 15, -14)
        win.CloseButton = CreateFrame("Button", nil, win)
        win.CloseButton:SetSize(26, 26); win.CloseButton:SetPoint("TOPRIGHT", -8, -8)
        local text = NewText(win.CloseButton, 15, 0.85, 0.65, 0.25); text:SetPoint("CENTER"); text:SetText("x")
    end
    win:SetSize(NSP_CONST.WIN_W, NSP_CONST.WIN_H)
    win:SetPoint("CENTER")
    SolidUnderlay(win)
    win:SetFrameStrata("DIALOG")
    StackWindow(win, 100)
    win:SetMovable(true)
    win:EnableMouse(true)
    win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", win.StartMoving)
    win:SetScript("OnDragStop", win.StopMovingOrSizing)
    win:EnableKeyboard(true)
    win:SetScript("OnKeyDown", function(_, key)
        if key == "ESCAPE" then NspKeyboardPropagate(win, false); HideWindow()
        else NspKeyboardPropagate(win, true) end
    end)

    -- Blizzard panel title: NORMAL_FONT gold
    ApplyFont(win.TitleText, 14, "OUTLINE")
    win.TitleText:SetText("NearbySpy")
    win.TitleText:SetTextColor(1, 0.82, 0, 1)
    local subtitle = NewText(win, 8, 0.55, 0.47, 0.32)
    subtitle:SetPoint("LEFT", win.TitleText, "RIGHT", 10, -2)
    subtitle:SetWidth(400)
    subtitle:SetText(L("UI_SUBTITLE"))
    win.CloseButton:SetScript("OnClick", HideWindow)

    tactical.total = TacticalMetric(win, 16, 208, L("UI_DETECTED"))
    tactical.fresh = TacticalMetric(win, 232, 208, L("UI_ACTIVE5"))
    tactical.factions = TacticalMetric(win, 448, 236, L("UI_FACTIONS"))
    ApplyFont(tactical.factions.value, 11)

    local chart = TacticalPanel(win)
    chart:SetPoint("TOPLEFT", 16, -116); chart:SetSize(NSP_CONST.CHART_W, 100)
    tactical.chartLabel = NewText(chart, 9, 0.62, 0.55, 0.42)
    tactical.chartLabel:SetPoint("TOPLEFT", 9, -7)
    for level = 1, 60 do
        local bar = chart:CreateTexture(nil, "ARTWORK")
        bar:SetPoint("BOTTOMLEFT", 9 + (level - 1) * NSP_CONST.CHART_STEP, 10)
        bar:SetWidth(NSP_CONST.CHART_STEP - 2.5); bar:SetHeight(1)
        tactical.bars[level] = bar
        -- ⚠️ Прозрачная кнопка-цель поверх столбца УБРАНА 26.11.2026: клик по
        -- уровню больше не фильтрует (фильтры только на сайте), а кнопка без
        -- обработчика — это 60 лишних фреймов и ложное «сюда можно нажать».
    end
    local axis = chart:CreateTexture(nil, "ARTWORK")
    axis:SetPoint("BOTTOMLEFT", 8, 9)
    axis:SetSize(NSP_CONST.CHART_W - 21, 1); axis:SetColorTexture(0.3, 0.24, 0.12, 1)

    local classes = TacticalPanel(win)
    classes:SetPoint("TOPLEFT", NSP_CONST.CLASSES_X, -116)
    classes:SetSize(NSP_CONST.CLASSES_W, 100)
    local classTitle = NewText(classes, 9, 0.62, 0.55, 0.42)
    classTitle:SetPoint("TOPLEFT", 9, -7); classTitle:SetText(L("UI_CLASSES"))
    for i = 1, NSP_CONST.CLASS_BARS do
        local row = CreateFrame("Button", nil, classes)
        row:SetSize(NSP_CONST.ROW_COL_W, 20); row:SetPoint("TOPLEFT", 9, -23 - (i - 1) * 23)
        row.icon = row:CreateTexture(nil, "ARTWORK"); row.icon:SetSize(18, 18); row.icon:SetPoint("LEFT")
        row.label = NewText(row, 9, 0.85, 0.82, 0.75); row.label:SetPoint("LEFT", 23, 0); row.label:SetWidth(68); row.label:SetJustifyH("LEFT")
        -- StatusBar is the native bar widget (min/max/value, it fills itself);
        -- texture fallback if the custom beta lacks the widget
        local okBar, bar = pcall(CreateFrame, "StatusBar", nil, row)
        if okBar and bar and bar.SetMinMaxValues then
            bar:SetPoint("LEFT", 92, 0); bar:SetSize(NSP_CONST.ROW_COL_W - 150, 13)
            bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
            bar:SetMinMaxValues(0, 1); bar:SetValue(0)
            local bg = bar:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints(); bg:SetColorTexture(0.1, 0.08, 0.05, 1)
            row.bar = bar
            -- value rides INSIDE the bar (XP-bar style): with the client's
            -- default font a separate right-side label overlapped the fill;
            -- light text + dark shadow stays readable on both the fill and
            -- the dark track
            row.value = NewText(bar, 9, 0.95, 0.93, 0.88)
            row.value:SetPoint("RIGHT", -4, 0)
            row.value:SetShadowOffset(1, -1)
            row.value:SetShadowColor(0, 0, 0, 0.9)
        else
            if bar and bar.Hide then bar:Hide() end
            local track = row:CreateTexture(nil, "BACKGROUND"); track:SetPoint("LEFT", 92, 0); track:SetSize(NSP_CONST.ROW_COL_W - 150, 8); track:SetColorTexture(0.1, 0.08, 0.05, 1)
            row.fill = row:CreateTexture(nil, "ARTWORK"); row.fill:SetPoint("LEFT", 92, 0); row.fill:SetHeight(8); row.fill:SetWidth(1)
            row.value = NewText(row, 9); row.value:SetPoint("RIGHT", -1, 0)
        end
        tactical.classes[i] = row
        -- ⚠️ Клик и подсветка «выбранного класса» УБРАНЫ 26.11.2026: панель
        -- классов стала чисто информационной (фильтры переехали на сайт).
        -- OnEnter/OnLeave оставлены только как подсветка наведения.
        row:SetScript("OnEnter", function(self)
            self.label:SetTextColor(1, 0.9, 0.6)
        end)
        row:SetScript("OnLeave", function(self)
            self.label:SetTextColor(0.85, 0.82, 0.75)
        end)
    end

    local toolbar = TacticalPanel(win)
    toolbar:SetPoint("TOPLEFT", 16, -224); toolbar:SetSize(NSP_CONST.TOOLBAR_W, 31)
    -- Четыре таба одной строкой. Позиции считаются из констант, а не вписаны
    -- числами: при смене ширины окна или подписи достаточно поправить
    -- FILTER_X0 / FILTER_W / FILTER_STEP, и ряд остаётся ровным.
    -- tile 1..3: все / свежие / новые
    TacticalFilter(toolbar, "all", NSP_CONST.FILTER_X0)
    TacticalFilter(toolbar, "fresh", NSP_CONST.FILTER_X0 + NSP_CONST.FILTER_STEP)
    TacticalFilter(toolbar, "new", NSP_CONST.FILTER_X0 + 2 * NSP_CONST.FILTER_STEP)
    -- tile 4: what the exchange channel taught us THIS SESSION (peerNew).
    -- The "everything the channel ever delivered" tab was dropped: it mixed
    -- records of unknown age with fresh ones and answered no question the
    -- session view does not answer.
    TacticalFilter(toolbar, "peern", NSP_CONST.FILTER_X0 + 3 * NSP_CONST.FILTER_STEP)
    -- Счётчик "показано / всего" — 7pt (small): подпись табов идёт 12pt, и
    -- счётчик того же размера отъедал место у последнего таба.
    tactical.count = NewText(toolbar, 7, 0.6, 0.53, 0.4)
    tactical.count:SetPoint("RIGHT", -NSP_CONST.COUNT_X, 0)

    -- ⚠️ Ряд селекторов (мир / класс / уровень) УДАЛЁН 26.11.2026 по решению
    -- владельца: фильтры живут только на сайте. Вместе с ним освободилось 32 px
    -- по вертикали — таблица, заголовок и скролл подняты на столько же, иначе
    -- осталась бы пустая полоса.
    local tableHeader = CreateFrame("Frame", nil, win)
    tableHeader:SetPoint("TOPLEFT", 16, -256); tableHeader:SetSize(NSP_CONST.TOOLBAR_W, 24)
    local thBg = tableHeader:CreateTexture(nil, "BACKGROUND"); thBg:SetAllPoints(); thBg:SetColorTexture(0.07, 0.055, 0.035, 1)
    -- Заголовки берут X из тех же констант, что и строки: при смене ширины
    -- окна они не могут разъехаться с данными.
    local h1 = NewText(tableHeader, 9, 0.62, 0.55, 0.4); h1:SetPoint("LEFT", NSP_CONST.COL_NAME_X, 0); h1:SetText(L("UI_PLAYER"))
    local h2 = NewText(tableHeader, 9, 0.62, 0.55, 0.4); h2:SetPoint("LEFT", NSP_CONST.COL_PROF_X, 0); h2:SetText(L("UI_PROFILE"))
    local h3 = NewText(tableHeader, 9, 0.62, 0.55, 0.4); h3:SetPoint("LEFT", NSP_CONST.COL_ZONE_X, 0); h3:SetText(L("UI_ZONE"))
    local h4 = NewText(tableHeader, 9, 0.62, 0.55, 0.4); h4:SetPoint("LEFT", NSP_CONST.COL_SEEN_X, 0); h4:SetText(L("UI_CONTACT"))

    local okSf, sf = pcall(CreateFrame, "ScrollFrame", nil, win, "UIPanelScrollFrameTemplate")
    if not okSf or not sf then sf = CreateFrame("ScrollFrame", nil, win) end
    sf:SetPoint("TOPLEFT", 16, -280); sf:SetPoint("BOTTOMRIGHT", -32, 43)
    local content = CreateFrame("Frame", nil, sf); content:SetSize(NSP_CONST.LIST_W, 1); sf:SetScrollChild(content); winList = content

    tactical.status = NewText(win, 9, 0.55, 0.5, 0.4); tactical.status:SetPoint("BOTTOMLEFT", 17, 20)
    local hint = NewText(win, 9, 0.4, 0.36, 0.28)
    hint:SetPoint("BOTTOMLEFT", 17, 7)
    hint:SetText(L("WIN_HINT"))
    win:SetScript("OnShow", TacticalUpdate)
end

local function ShowWindow()
    local ok, err = pcall(function()
        if not win then
            BuildWindow()
        end
        win:Show()
        TacticalUpdate()  -- the custom beta may skip OnShow on programmatic Show()
    end)
    if not ok then
        P(L("ERR_WINDOW") .. tostring(err))
    end
end

-- ============ server census window (NearbySpy_Data companion) ============
-- The data module ships a weekly aggregated snapshot as the global
-- NearbySpyData (rendered by the site /api/datapack.lua — the addon itself
-- has no HTTP). Separate window by design (Spy Classic convention: the
-- tactical window stays lean, statistics get their own). Widgets are built
-- once; every Show re-reads the global, so a data-module update between
-- sessions is picked up without a rebuild.
local serverWin
local svr = {}

-- Display offset for the UTC heatmap, in hours: explicit user choice
-- (settings, db.tzOffset) beats the system clock; falls back to UTC if the
-- client lacks the os table functions.
local function HeatOffsetHours()
    local okDb, db = pcall(GetDB)
    if okDb and type(db) == "table"
        and type(db.tzOffset) == "number" and db.tzOffset >= -12 and db.tzOffset <= 14 then
        return db.tzOffset
    end
    local okOff, off = pcall(function()
        local diff = os.difftime and os.difftime(os.time(os.date("*t")), os.time(os.date("!*t")))
            or (os.time(os.date("*t")) - os.time(os.date("!*t")))
        return math.floor(diff / 3600 + 0.5)
    end)
    if okOff and type(off) == "number" and math.abs(off) <= 14 then return off end
    return 0
end

local function BuildServerWindow()
    local okTpl, tplWin = pcall(CreateFrame, "Frame", "NearbySpyServerWindow", UIParent, "BasicFrameTemplateWithInset")
    if okTpl and tplWin and tplWin.TitleText and tplWin.Bg and tplWin.CloseButton then
        serverWin = tplWin
    else
        if tplWin and tplWin.Hide then tplWin:Hide() end
        serverWin = CreateFrame("Frame", "NearbySpyServerWindow", UIParent)
        local bg = serverWin:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(); bg:SetColorTexture(0.03, 0.025, 0.02, 0.97)
        serverWin.TitleText = NewText(serverWin, 14, 1, 0.82, 0)
        serverWin.TitleText:SetPoint("TOPLEFT", 15, -14)
        local btn = CreateFrame("Button", nil, serverWin)
        btn:SetSize(26, 26); btn:SetPoint("TOPRIGHT", -8, -8)
        local label = NewText(btn, 15, 0.85, 0.65, 0.25); label:SetPoint("CENTER"); label:SetText("x")
        serverWin.CloseButton = btn
    end
    serverWin:SetSize(460, 620)
    serverWin:SetPoint("CENTER")
    SolidUnderlay(serverWin)
    serverWin:SetFrameStrata("DIALOG")
    StackWindow(serverWin, 300)
    serverWin:SetMovable(true)
    serverWin:EnableMouse(true)
    serverWin:RegisterForDrag("LeftButton")
    serverWin:SetScript("OnDragStart", serverWin.StartMoving)
    serverWin:SetScript("OnDragStop", serverWin.StopMovingOrSizing)
    serverWin:EnableKeyboard(true)
    serverWin:SetScript("OnKeyDown", function(_, key)
        if key == "ESCAPE" then NspKeyboardPropagate(serverWin, false); serverWin:Hide()
        else NspKeyboardPropagate(serverWin, true) end
    end)
    ApplyFont(serverWin.TitleText, 14, "OUTLINE")
    serverWin.TitleText:SetText(L("SVR_TITLE"))
    serverWin.TitleText:SetTextColor(1, 0.82, 0, 1)
    serverWin.CloseButton:SetScript("OnClick", function() serverWin:Hide() end)

    svr.date = NewText(serverWin, 9, 0.62, 0.55, 0.42); svr.date:SetPoint("TOPLEFT", 16, -44)
    svr.stale = NewText(serverWin, 9, 0.9, 0.6, 0.2); svr.stale:SetPoint("TOPRIGHT", -16, -44); svr.stale:SetJustifyH("RIGHT")
    svr.total = NewText(serverWin, 16, 0.93, 0.91, 0.87); svr.total:SetPoint("TOPLEFT", 16, -62)
    svr.totalLbl = NewText(serverWin, 9, 0.62, 0.55, 0.42)
    svr.totalLbl:SetPoint("LEFT", svr.total, "RIGHT", 6, -3); svr.totalLbl:SetText(L("SVR_TOTAL"))
    svr.factions = NewText(serverWin, 10, 0.8, 0.78, 0.7); svr.factions:SetPoint("TOPLEFT", 16, -86)

    local function Panel(y, h)
        local panel = CreateFrame("Frame", nil, serverWin)
        panel:SetPoint("TOPLEFT", 16, y); panel:SetSize(428, h)
        local bg = panel:CreateTexture(nil, "BACKGROUND"); bg:SetAllPoints(); bg:SetColorTexture(0.07, 0.055, 0.035, 1)
        return panel
    end

    -- heat grid: 7 days x 24 hours, amber on a log scale (same curve as the site)
    local heatPanel = Panel(-108, 170)
    local ht = NewText(heatPanel, 9, 0.62, 0.55, 0.42); ht:SetPoint("TOPLEFT", 8, -7); ht:SetText(L("SVR_PRIME"))
    -- the heat title carries its scope: prime time is a per-realm number, and a
    -- title that says "PRIME TIME" over an all-realms aggregate reads as if it
    -- described this realm
    svr.heatTitle = ht
    svr.heatCells = {}
    for d = 1, 7 do
        local dl = NewText(heatPanel, 8, 0.55, 0.47, 0.32)
        dl:SetPoint("TOPLEFT", 8, -27 - (d - 1) * 15); dl:SetWidth(20)
        dl:SetText(L("SVR_D" .. d))
        svr.heatCells[d] = {}
        for h = 0, 23 do
            local cell = heatPanel:CreateTexture(nil, "ARTWORK")
            cell:SetPoint("TOPLEFT", 32 + h * 15, -24 - (d - 1) * 15)
            cell:SetSize(13, 13)
            cell:SetColorTexture(0.94, 0.73, 0.04, 0.04)
            svr.heatCells[d][h] = cell
        end
    end
    for h = 0, 23 do
        local hl = NewText(heatPanel, 7, 0.4, 0.36, 0.26)
        hl:SetPoint("TOPLEFT", 32 + h * 15 - 2, -133); hl:SetWidth(17); hl:SetJustifyH("CENTER")
        hl:SetText(tostring(h))
    end
    svr.peak = NewText(heatPanel, 8, 0.55, 0.47, 0.32); svr.peak:SetPoint("BOTTOMLEFT", 8, 6)

    -- class bars: StatusBar with texture fallback (same pattern as the tactical window)
    local classPanel = Panel(-286, 207)
    local ct = NewText(classPanel, 9, 0.62, 0.55, 0.42); ct:SetPoint("TOPLEFT", 8, -7); ct:SetText(L("SVR_CLASSES"))
    svr.classRows = {}
    for i = 1, 9 do
        local row = CreateFrame("Frame", nil, classPanel)
        row:SetSize(412, 19); row:SetPoint("TOPLEFT", 8, -22 - (i - 1) * 20)
        row.label = NewText(row, 10, 0.9, 0.88, 0.8); row.label:SetPoint("LEFT"); row.label:SetWidth(90); row.label:SetJustifyH("LEFT")
        local okBar, bar = pcall(CreateFrame, "StatusBar", nil, row)
        if okBar and bar and bar.SetMinMaxValues then
            bar:SetPoint("LEFT", 96, 0); bar:SetSize(240, 13)
            bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
            bar:SetMinMaxValues(0, 1); bar:SetValue(0)
            local barBg = bar:CreateTexture(nil, "BACKGROUND"); barBg:SetAllPoints(); barBg:SetColorTexture(0.1, 0.08, 0.05, 1)
            row.bar = bar
            row.value = NewText(bar, 9, 0.95, 0.93, 0.88); row.value:SetPoint("RIGHT", -4, 0)
            row.value:SetShadowOffset(1, -1); row.value:SetShadowColor(0, 0, 0, 0.9)
        else
            if bar and bar.Hide then bar:Hide() end
            local track = row:CreateTexture(nil, "BACKGROUND"); track:SetPoint("LEFT", 96, 0); track:SetSize(240, 8); track:SetColorTexture(0.1, 0.08, 0.05, 1)
            row.fill = row:CreateTexture(nil, "ARTWORK"); row.fill:SetPoint("LEFT", 96, 0); row.fill:SetHeight(8); row.fill:SetWidth(1)
            row.value = NewText(row, 9); row.value:SetPoint("LEFT", 340, 0)
        end
        svr.classRows[i] = row
    end

    local zonePanel = Panel(-501, 48)
    local zt = NewText(zonePanel, 9, 0.62, 0.55, 0.42); zt:SetPoint("TOPLEFT", 8, -7); zt:SetText(L("SVR_ZONES"))
    svr.zones = NewText(zonePanel, 9, 0.85, 0.82, 0.75); svr.zones:SetPoint("TOPLEFT", 8, -21); svr.zones:SetWidth(412); svr.zones:SetJustifyH("LEFT")

    svr.nodata = NewText(serverWin, 11, 0.9, 0.85, 0.7)
    svr.nodata:SetPoint("CENTER"); svr.nodata:SetWidth(400); svr.nodata:SetJustifyH("CENTER")
end

local function FillServerWindow()
    local fmt = BreakUpLargeNumbers or tostring
    local data = NearbySpyData
    local db = GetDB()
    local g = nil
    if type(data) == "table" and type(data.games) == "table" then
        g = data.games[db.game] or data.games.forever
    end
    -- datapack format 2: предпочитаем срез текущего мира (мегасерверы
    -- Forever разделены по realm), иначе — общий агрегат игры.
    -- Prime time is a per-realm number: two realms of one cluster peak at
    -- different hours, so an aggregate heat map is a different statistic, not a
    -- coarser one. It is still shown as a fallback, but always labelled with its
    -- scope and, when the datapack has per-realm slices but not ours, said out
    -- loud instead of quietly mixing realms.
    local scope, realmNote = nil, nil
    local realm = PlayerRealm()
    if g and type(g.realms) == "table" and realm and realm ~= "?" and type(g.realms[realm]) == "table" then
        g = g.realms[realm]
        scope = realm
    elseif g and type(g.realms) == "table" and realm and realm ~= "?" then
        realmNote = L("SVR_NO_REALM"):format(realm)
    elseif g and realm and realm ~= "?" then
        -- format 1 snapshot: it has no realms at all, so this is a stale data
        -- module rather than a missing realm
        realmNote = L("SVR_NO_REALM"):format(realm)
    end
    if serverWin and serverWin.TitleText then
        serverWin.TitleText:SetText(L("SVR_TITLE") .. " — " .. (scope or L("SVR_SCOPE_ALL")))
    end
    if svr.heatTitle then
        svr.heatTitle:SetText(L("SVR_PRIME") .. " — " .. (scope or L("SVR_SCOPE_ALL")))
    end
    if not g then
        svr.nodata:SetText(L("SVR_NODATA")); svr.nodata:Show()
        -- drop the previous scope too: a stale "— <realm>" over an empty grid
        -- would claim data the module does not have
        if svr.heatTitle then svr.heatTitle:SetText(L("SVR_PRIME")) end
        svr.date:SetText(""); svr.stale:SetText(""); svr.total:SetText(""); svr.factions:SetText("")
        svr.peak:SetText(""); svr.zones:SetText("")
        for d = 1, 7 do for h = 0, 23 do svr.heatCells[d][h]:SetColorTexture(0.94, 0.73, 0.04, 0.04) end end
        for i = 1, 9 do
            local row = svr.classRows[i]
            row.label:SetText(""); row.value:SetText("")
            if row.bar then row.bar:SetValue(0) elseif row.fill then row.fill:SetWidth(1) end
        end
        return
    end
    svr.nodata:Hide()

    local gen = tonumber(data.generated) or 0
    svr.date:SetText(L("SVR_SNAPSHOT"):format(gen > 0 and date("%d.%m.%Y", gen) or "?"))
    local ageDays = gen > 0 and math.floor((time() - gen) / 86400) or 0
    local staleText = ageDays > 10 and L("SVR_STALE"):format(ageDays) or ""
    if realmNote then
        staleText = staleText ~= "" and (staleText .. " ; " .. realmNote) or realmNote
    end
    svr.stale:SetText(staleText)

    svr.total:SetText(fmt(tonumber(g.total) or 0))
    local f = g.factions or {}
    local fparts = {}
    if tonumber(f.Alliance) then fparts[#fparts + 1] = "|cff6699ff" .. L("ALLIANCE") .. " " .. fmt(tonumber(f.Alliance)) .. "|r" end
    if tonumber(f.Horde) then fparts[#fparts + 1] = "|cffff6666" .. L("HORDE") .. " " .. fmt(tonumber(f.Horde)) .. "|r" end
    svr.factions:SetText(table.concat(fparts, " ; "))

    -- datapack heat is UTC; rotate into the display timezone (settings
    -- override, else system clock) so the map matches the site
    local offset = HeatOffsetHours()
    local heat = g.heat
    local flat = nil
    if type(heat) == "table" then
        flat = {}
        for d = 1, 7 do
            local row = heat[d]
            for h = 0, 23 do
                flat[(d - 1) * 24 + h] = (type(row) == "table" and tonumber(row[h + 1])) or 0
            end
        end
    end
    local max, peakD, peakH = 0, nil, nil
    if flat then
        for i = 0, 167 do
            if (flat[i] or 0) > max then max = flat[i] end
        end
    end
    for d = 1, 7 do
        for h = 0, 23 do
            local v = 0
            if flat then
                v = flat[((d - 1) * 24 + h - offset) % 168] or 0
            end
            -- visibility floor: the snapshot is sparse and the log scale against
            -- the upload-hour spike made ordinary cells nearly invisible at 13px
            local a = 0.04
            if max > 0 and v > 0 then
                a = 0.2 + (math.log(1 + 9 * v / max) / math.log(10)) * 0.75
                if v == max then peakD, peakH = d, h end
            end
            svr.heatCells[d][h]:SetColorTexture(0.94, 0.73, 0.04, math.min(a, 1))
        end
    end
    if peakD then
        svr.peak:SetText(L("SVR_PEAK"):format(L("SVR_D" .. peakD), peakH, max))
    else
        svr.peak:SetText("")
    end

    local cls = {}
    for file, n in pairs(g.classes or {}) do
        cls[#cls + 1] = { file = file, n = tonumber(n) or 0 }
    end
    table.sort(cls, function(a, b) return a.n > b.n end)
    local top = cls[1] and cls[1].n or 0
    local totalN = tonumber(g.total) or 0
    for i = 1, 9 do
        local row = svr.classRows[i]
        local c = cls[i]
        if c and top > 0 then
            local r, cg, b = ClassColorRGB(c.file)
            local name = LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[c.file] or c.file
            row.label:SetText(name); row.label:SetTextColor(r, cg, b)
            row.value:SetText(("%s (%d%%)"):format(fmt(c.n), totalN > 0 and math.floor(c.n / totalN * 100 + 0.5) or 0))
            if row.bar then
                row.bar:SetMinMaxValues(0, top); row.bar:SetValue(c.n); row.bar:SetStatusBarColor(r, cg, b)
            else
                row.fill:SetWidth(math.max(1, 240 * c.n / top)); row.fill:SetColorTexture(r, cg, b, 1)
            end
            row:Show()
        else
            row:Hide()
        end
    end

    local zp = {}
    for i, z in ipairs(g.zones or {}) do
        if i > 5 then break end
        if type(z) == "table" then
            zp[#zp + 1] = tostring(z[1]) .. " " .. fmt(tonumber(z[2]) or 0)
        end
    end
    svr.zones:SetText(table.concat(zp, " ; "))
end

local function ShowServerWindow()
    local ok, err = pcall(function()
        if not serverWin then
            BuildServerWindow()
        end
        FillServerWindow()
        serverWin:Show()
    end)
    if not ok then
        P(L("ERR_WINDOW") .. tostring(err))
    end
end

-- ============ hub window + minimap button (18.10.2026) ============
-- One menu window (grid of sections) opened from the minimap button or
-- /nspy menu. The minimap button is a standalone frame (no LibDBIcon
-- dependency): drag along the minimap ring, angle persisted in SV;
-- /nspy minimap hides it. Cell "icons" are letter tiles (first character of
-- the localized label): the client font has no emoji, and guessing Blizzard
-- icon paths on a custom client is fragile.
local hubWin
local hub = {}
local miniBtn
local ShowSettingsWindow -- forward: hub tile 4 opens the settings window (defined below)
local MinimapButton_Update   -- forward: the settings checkbox toggles the icon (defined below)
local BuildMinimapButton     -- forward: showing the icon builds it if it never existed
local Atan2 = math.atan2 or function(y, x) return math.atan(y, x) end

local function Utf8First(s)
    return (type(s) == "string" and s:match("^.[\128-\191]*")) or "?"
end

local function AddonVersion()
    local v
    if GetAddOnMetadata then
        local ok, r = pcall(GetAddOnMetadata, "NearbySpy", "Version")
        if ok then v = r end
    end
    if not v and C_AddOns and C_AddOns.GetAddOnMetadata then
        local ok, r = pcall(C_AddOns.GetAddOnMetadata, "NearbySpy", "Version")
        if ok then v = r end
    end
    return v or "?"
end

function hub.Refresh()
    if not hubWin then return end
    local db = GetDB()
    hub.status:SetText(L("HUB_STATUS"):format(CountPlayers(),
        db.peerEnabled and L("ON") or L("OFF"), AddonVersion()))
end

-- Размеры сетки хаба: подписи на кириллице шире латиницы, и в прежних
-- 96x78 они не влезали — текст вылезал за ячейку и наезжал на соседнюю.
-- Размеры сетки хаба одной таблицей: в Lua 5.1 на главный чанк приходится
-- не больше 200 локалов, а четыре отдельные константы съедают четыре слота.
-- Высота с запасом на худший случай: при переносе и подписи, и описания на две
-- строки содержимое занимает ~94px (плитка 32 + 2×13 + 2×11 + отступы).
local HUBG = { w = 110, h = 96, col = 122, row = 104 }

local function HubCell(parent, col, row, labelKey, descKey, lr, lg, lb, onClick)
    local cell = CreateFrame("Button", nil, parent)
    cell:SetSize(HUBG.w, HUBG.h)
    cell:SetPoint("TOPLEFT", 14 + col * HUBG.col, -58 - row * HUBG.row)
    local bg = cell:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.11, 0.085, 0.045, 1)
    cell:SetHighlightTexture("Interface\\Buttons\\WHITE8x8", "ADD")
    local hl = cell.GetHighlightTexture and cell:GetHighlightTexture() or nil
    if hl and hl.SetVertexColor then hl:SetVertexColor(0.94, 0.73, 0.04, 0.35) end
    local tile = cell:CreateTexture(nil, "ARTWORK")
    tile:SetSize(32, 32)
    tile:SetPoint("TOP", 0, -10)
    tile:SetColorTexture(0.18, 0.14, 0.07, 1)
    local letter = NewText(cell, 15, lr, lg, lb)
    letter:SetPoint("CENTER", tile, "CENTER")
    letter:SetText(Utf8First(L(labelKey)))
    local label = NewText(cell, 10, 0.9, 0.88, 0.8)
    label:SetPoint("TOP", tile, "BOTTOM", 0, -3)
    -- SetWidth включает перенос: без него длинная подпись просто вылезает
    -- за границы ячейки (клиппинга у FontString нет)
    label:SetWidth(HUBG.w - 10)
    label:SetText(L(labelKey))
    local desc = NewText(cell, 8, 0.55, 0.47, 0.32)
    desc:SetPoint("TOP", label, "BOTTOM", 0, -1)
    desc:SetWidth(HUBG.w - 10)
    desc:SetText(L(descKey))
    -- Окно из главного меню ЗАМЕНЯЕТ меню: раньше hub оставался висеть под
    -- открытым окном, и его приходилось закрывать отдельным кликом (просьба
    -- пользователя 15.11.2026). Прячем после вызова, а не вместо него, и в
    -- pcall: падение обработчика не должно оставить меню на экране.
    -- hubWin — forward-объявление выше по файлу, поэтому виден здесь как upvalue.
    cell:SetScript("OnClick", function()
        local okClick, errClick = pcall(onClick)
        if hubWin then hubWin:Hide() end
        if not okClick then P(tostring(errClick)) end
    end)
    return cell, desc
end

local function BuildHubWindow()
    local okTpl, tplWin = pcall(CreateFrame, "Frame", "NearbySpyHubWindow", UIParent, "BasicFrameTemplateWithInset")
    if okTpl and tplWin and tplWin.TitleText and tplWin.Bg and tplWin.CloseButton then
        hubWin = tplWin
    else
        if tplWin and tplWin.Hide then tplWin:Hide() end
        hubWin = CreateFrame("Frame", "NearbySpyHubWindow", UIParent)
        local bg = hubWin:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.03, 0.025, 0.02, 0.97)
        hubWin.TitleText = NewText(hubWin, 14, 1, 0.82, 0)
        hubWin.TitleText:SetPoint("TOPLEFT", 15, -14)
        local btn = CreateFrame("Button", nil, hubWin)
        btn:SetSize(26, 26)
        btn:SetPoint("TOPRIGHT", -8, -8)
        local x = NewText(btn, 15, 0.85, 0.65, 0.25)
        x:SetPoint("CENTER")
        x:SetText("x")
        hubWin.CloseButton = btn
    end
    hubWin:SetSize(260, 274)
    hubWin:SetPoint("CENTER")
    SolidUnderlay(hubWin)
    hubWin:SetFrameStrata("DIALOG")
    StackWindow(hubWin, 400)
    hubWin:SetMovable(true)
    hubWin:EnableMouse(true)
    hubWin:RegisterForDrag("LeftButton")
    hubWin:SetScript("OnDragStart", hubWin.StartMoving)
    hubWin:SetScript("OnDragStop", hubWin.StopMovingOrSizing)
    hubWin:EnableKeyboard(true)
    hubWin:SetScript("OnKeyDown", function(_, key)
        if key == "ESCAPE" then
            NspKeyboardPropagate(hubWin, false)
            hubWin:Hide()
        else
            NspKeyboardPropagate(hubWin, true)
        end
    end)
    ApplyFont(hubWin.TitleText, 14, "OUTLINE")
    hubWin.TitleText:SetText("NEARBYSPY")
    hubWin.TitleText:SetTextColor(1, 0.82, 0, 1)
    hubWin.CloseButton:SetScript("OnClick", function() hubWin:Hide() end)

    hub.status = NewText(hubWin, 8, 0.62, 0.55, 0.42)
    hub.status:SetPoint("TOPLEFT", 15, -36)
    -- ширина с переносом: русский статус («42 записей — обмен вкл — v1.3.0»)
    -- длиннее английского и вылезал за окно
    hub.status:SetWidth(230)

    HubCell(hubWin, 0, 0, "HUB_PLAYERS", "HUB_PLAYERS_D", 0.55, 0.75, 1.0,
        function() ShowWindow() end)
    HubCell(hubWin, 1, 0, "HUB_SERVER", "HUB_SERVER_D", 1.0, 0.82, 0.0,
        function() ShowServerWindow() end)
    HubCell(hubWin, 0, 1, "HUB_HELP", "HUB_HELP_D", 1.0, 0.5, 0.5,
        function()
            local ok, err = pcall(ShowHelpWindow)
            if not ok then P(L("ERR_WINDOW") .. tostring(err)) end
        end)
    HubCell(hubWin, 1, 1, "HUB_SETTINGS", "HUB_SETTINGS_D", 0.75, 0.75, 0.78,
        function()
            -- вкладка в меню модификаций клиента, а если её нет — окно аддона
            local ok, err = pcall(NspOpenOptions)
            if not ok then P(L("ERR_WINDOW") .. tostring(err)) end
        end)
    hub.Refresh()
end

local function ShowHubWindow()
    local ok, err = pcall(function()
        if not hubWin then BuildHubWindow() end
        hub.Refresh()
        hubWin:Show()
    end)
    if not ok then P(L("ERR_WINDOW") .. tostring(err)) end
end

local function ToggleHubWindow()
    if hubWin and hubWin.IsShown and hubWin:IsShown() then
        hubWin:Hide()
    else
        ShowHubWindow()
    end
end

-- ============ settings window ============
-- Opened from hub tile 4 (and /nspy settings). Checkboxes write straight to
-- SV fields; future options land here. Blizzard checkbutton template with a
-- manual ASCII fallback for clients where the template is gutted.
local optWin
local opt = {}
-- Виджеты второго хозяина — вкладки в меню модификаций. Отдельная таблица, иначе
-- оба места писали бы в одну и перезатирали друг друга: после этого перестают
-- обновляться либо галочки окна, либо панели.
local optRows = {}

local function OptCheck(parent, x, y, labelKey, descKey, getter, setter)
    local okTpl, cb = pcall(CreateFrame, "CheckButton", nil, parent, "InterfaceOptionsCheckButtonTemplate")
    if not (okTpl and cb and cb.SetChecked and cb.GetChecked) then
        if cb and cb.Hide then cb:Hide() end
        cb = CreateFrame("Button", nil, parent)
        cb:SetSize(24, 24)
        local box = cb:CreateTexture(nil, "ARTWORK")
        box:SetAllPoints()
        box:SetColorTexture(0.16, 0.13, 0.07, 1)
        local mark = NewText(cb, 14, 1, 0.82, 0)
        mark:SetPoint("CENTER")
        cb.__mark = mark
        cb.__manual = true
        cb.SetChecked = function(self, v)
            self.__checked = v and true or false
            self.__mark:SetText(self.__checked and "x" or "")
        end
        cb.GetChecked = function(self) return self.__checked end
    end
    -- layout like Blizzard options panels: label on the left, the checkbox
    -- docked to the right edge of the row
    cb:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -16, y)
    cb:SetChecked(getter())
    cb:SetScript("OnClick", function(self)
        -- template CheckButtons auto-toggle before OnClick; manual one doesn't.
        -- == true, not truthy: mock/stub tables can answer a table for any key.
        if self.__manual == true then self:SetChecked(not self:GetChecked()) end
        setter(self:GetChecked() and true or false)
    end)
    local label = NewText(parent, 11, 0.93, 0.91, 0.87)
    label:SetPoint("TOPLEFT", x, y - 4)
    label:SetText(L(labelKey))
    local desc = NewText(parent, 8, 0.55, 0.47, 0.32)
    desc:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -3)
    desc:SetWidth(290)
    desc:SetJustifyH("LEFT")
    desc:SetText(L(descKey))
    return cb, label, desc
end

-- Height of a laid-out FontString, or a conservative fallback when the widget
-- cannot measure itself (the height depends on the CLIENT FONT and on the
-- language — a German or Russian description wraps to more lines than English,
-- which is exactly how the settings rows ended up overlapping each other).
-- Global on purpose: the main chunk is at the Lua 5.1 ceiling of 200 locals.
function OptTextHeight(fs, fallback)
    if fs and fs.GetStringHeight then
        local ok, h = pcall(fs.GetStringHeight, fs)
        if ok and type(h) == "number" and h > 0 then return h end
    end
    return fallback
end

-- Language selector data: Auto (client) first in the UI, then the fixed
-- public order en -> zh -> ru -> de -> fr -> ko.
local SET_LANG_ORDER = { "enUS", "zhCN", "ruRU", "deDE", "frFR", "koKR" }
local SET_LANG_NAME = {
    enUS = "English", zhCN = "中文", ruRU = "Русский",
    deDE = "Deutsch", frFR = "Français", koKR = "한국어",
}
-- forward-declared before the help window: assignment, not `local function`
EffectiveLocale = function()
    local db = GetDB()
    local ov = db and db.locale
    if ov then
        for i = 1, #SET_LANG_ORDER do
            if SET_LANG_ORDER[i] == ov then return ov end
        end
    end
    local cl = GetLocale and GetLocale() or "enUS"
    for i = 1, #SET_LANG_ORDER do
        if SET_LANG_ORDER[i] == cl then return cl end
    end
    return "enUS"
end

local RefreshSettingsText -- forward: the language selector relabels the window live

-- value selector, three tiers:
--   1) modern WowStyle2 DropdownButton + Steppers arrow buttons (the default
--      Settings look: dropdown in the middle, < > arrows cycling the options)
--   2) classic UIDropDownMenu template
--   3) ASCII "< value >" stepper built from raw widgets
-- Each tier pcall-falls through to the next when a template/mixin is gutted.
-- entriesFn() returns { { value=..., text=... }, ... } fresh each call
-- (the Auto row carries the current locale/system values in its text).
local function OptSelect(parent, y, ddName, labelKey, descKey, width, entriesFn, getCurrent, onPick)
    local label = NewText(parent, 11, 0.93, 0.91, 0.87)
    label:SetPoint("TOPLEFT", 16, y)
    label:SetText(L(labelKey))
    local desc = NewText(parent, 8, 0.55, 0.47, 0.32)
    desc:SetPoint("TOPLEFT", 16, y - 46)
    desc:SetWidth(330)
    desc:SetJustifyH("LEFT")
    desc:SetText(L(descKey))
    local function currentText()
        local cur = getCurrent()
        local entries = entriesFn()
        for i = 1, #entries do
            if entries[i].value == cur then return entries[i].text end
        end
        return ""
    end

    local function menuGen(dropdown, rootDescription)
        local entries = entriesFn()
        for i = 1, #entries do
            local e = entries[i]
            rootDescription:CreateRadio(e.text,
                function() return getCurrent() == e.value end,
                function() onPick(e.value) end,
                e.value)
        end
    end

    -- tier 1: modern dropdown + arrow steppers
    local mdd, mdec, minc
    local okModern = pcall(function()
        mdd = CreateFrame("DropdownButton", ddName, parent, "WowStyle2DropdownTemplate")
        if not (mdd.SetupMenu and mdd.CollectSelectionData and mdd.Increment and mdd.Decrement) then
            error("WowStyle2 dropdown mixin missing")
        end
        if mdd.SetWidth then pcall(mdd.SetWidth, mdd, width) end
        mdd:SetPoint("TOPLEFT", 56, y - 14)
        mdec = CreateFrame("Button", nil, parent, "SteppersDecrementButtonTemplate")
        minc = CreateFrame("Button", nil, parent, "SteppersIncrementButtonTemplate")
        if not (mdec and minc) then error("stepper button templates missing") end
        mdec:SetPoint("TOPLEFT", 16, y - 16)
        minc:SetPoint("LEFT", mdd, "RIGHT", 4, 0)
        mdd:SetupMenu(menuGen)
        local function UpdateSteppers()
            local ok, prev, nxt = pcall(function() return mdd:CollectSelectionData() end)
            if ok then
                mdec:SetEnabled(prev ~= nil)
                minc:SetEnabled(nxt ~= nil)
            end
        end
        mdec:SetScript("OnClick", function() mdd:Decrement() end)
        minc:SetScript("OnClick", function() mdd:Increment() end)
        if DropdownButtonMixin and DropdownButtonMixin.Event and mdd.RegisterCallback then
            pcall(function()
                mdd:RegisterCallback(DropdownButtonMixin.Event.OnUpdate, UpdateSteppers)
            end)
        end
        UpdateSteppers()
    end)
    if okModern and mdd then
        return {
            Refresh = function() pcall(mdd.SetupMenu, mdd, menuGen) end,
            label = label, desc = desc, dd = mdd,
        }
    end
    if mdd and mdd.Hide then mdd:Hide() end
    if mdec and mdec.Hide then mdec:Hide() end
    if minc and minc.Hide then minc:Hide() end

    -- tier 2: classic UIDropDownMenu
    local dd
    local okDD = pcall(function()
        dd = CreateFrame("Frame", ddName, parent, "UIDropDownMenuTemplate")
        dd:SetPoint("TOPLEFT", -12, y - 14)
        UIDropDownMenu_SetWidth(dd, width)
        UIDropDownMenu_Initialize(dd, function()
            local entries = entriesFn()
            local cur = getCurrent()
            for i = 1, #entries do
                local info = UIDropDownMenu_CreateInfo()
                info.text = entries[i].text
                info.value = entries[i].value
                info.checked = (entries[i].value == cur)
                info.func = function(btn)
                    onPick(btn.value)
                    UIDropDownMenu_SetText(dd, currentText())
                end
                UIDropDownMenu_AddButton(info)
            end
        end)
        UIDropDownMenu_SetText(dd, currentText())
    end)
    if okDD and dd then
        return {
            Refresh = function() UIDropDownMenu_SetText(dd, currentText()) end,
            label = label, desc = desc, dd = dd,
        }
    end
    if dd and dd.Hide then dd:Hide() end

    -- tier 3: "< value >" stepper (all templates gutted)
    local function mkBtn(txt, xOff)
        local b = CreateFrame("Button", nil, parent)
        b:SetSize(22, 18)
        b:SetPoint("TOPLEFT", xOff, y - 16)
        local bg = b:CreateTexture(nil, "ARTWORK")
        bg:SetAllPoints()
        bg:SetColorTexture(0.16, 0.13, 0.07, 1)
        local t = NewText(b, 11, 1, 0.82, 0)
        t:SetPoint("CENTER")
        t:SetText(txt)
        local hl = b:GetHighlightTexture()
        if hl and hl.SetColorTexture then hl:SetColorTexture(1, 0.82, 0, 0.15) end
        return b
    end
    local prev = mkBtn("<", 16)
    local nxt = mkBtn(">", 246)
    local val = NewText(parent, 10, 1, 0.82, 0)
    val:SetPoint("TOPLEFT", 44, y - 20)
    val:SetWidth(196)
    val:SetJustifyH("CENTER")
    local function Refresh() val:SetText(currentText()) end
    local function step(dir)
        local entries = entriesFn()
        local cur = getCurrent()
        local idx = 1
        for i = 1, #entries do
            if entries[i].value == cur then idx = i end
        end
        idx = idx + dir
        if idx > #entries then idx = 1 elseif idx < 1 then idx = #entries end
        onPick(entries[idx].value)
        Refresh()
    end
    prev:SetScript("OnClick", function() step(-1) end)
    nxt:SetScript("OnClick", function() step(1) end)
    Refresh()
    return { Refresh = Refresh, label = label, desc = desc, prev = prev, nxt = nxt }
end

-- Auto (client) first, then the fixed public order en -> zh -> ru -> de -> fr -> ko.
local function LangEntries()
    local t = { { value = "AUTO", text = L("SET_AUTO"):format(SET_LANG_NAME[EffectiveLocale()]) } }
    for i = 1, #SET_LANG_ORDER do
        local code = SET_LANG_ORDER[i]
        t[#t + 1] = { value = code, text = SET_LANG_NAME[code] }
    end
    return t
end
local function TzEntries()
    local t = { { value = "AUTO", text = L("SET_AUTO"):format(("UTC%+d"):format(HeatOffsetHours())) } }
    for h = -12, 14 do
        t[#t + 1] = { value = h, text = ("UTC%+d"):format(h) }
    end
    return t
end

-- ── Строки настроек: ОДНА таблица, ДВА места показа ─────────────────────────
-- Опции показываются в собственном окне аддона (/nspy settings, плитка hub) и
-- во вкладке меню модификаций клиента. Список живёт в ОДНОЙ функции, иначе
-- «добавил галочку в окно, забыл в панель» расходится молча: в меню клиента
-- не хватает настройки, которую видно в окне аддона.
--
-- Global, не local: главный чанк стоит на 195 из 200 локалов Lua 5.1.
--   kind = "check"  → OptCheck(parent, x, y, label, desc, getter, setter)
--   kind = "select" → OptSelect с entries (функция списка) и width
function NspSetRows()
    return {
        { kind = "check", key = "peer", label = "SET_PEER", desc = "SET_PEER_D",
          getter = function() return GetDB().peerEnabled and true or false end,
          setter = function(v)
              local db = GetDB()
              db.peerEnabled = v
              if v then
                  local ok, err = pcall(JoinPeerChannel)
                  if not ok then DbgErr("peerJoin", err) end
              else
                  peerQueue, peerQueued = {}, {}
                  if LeaveChannelByName then pcall(LeaveChannelByName, PeerChannelName()) end
              end
              hub.Refresh()
          end },

        { kind = "check", key = "allRealms", label = "SET_PEER_ALL", desc = "SET_PEER_ALL_D",
          getter = function() return GetDB().peerAllRealms and true or false end,
          setter = function(v)
              local db = GetDB()
              db.peerAllRealms = v
              -- Both directions change what the list shows, so repaint it right
              -- away: with the flag off stored foreign rows disappear, with it on
              -- they come back (nothing is deleted either way).
              -- `parent` here is whichever window hosts the row, so it tells us
              -- nothing about the PLAYER window — ask that window directly.
              local mainWin = _G and _G.NearbySpyWindow
              if mainWin and mainWin.IsShown and mainWin:IsShown() then pcall(TacticalUpdate) end
              if hub and hub.Refresh then pcall(hub.Refresh) end
          end },

        { kind = "check", key = "minimap", label = "SET_MINIMAP", desc = "SET_MINIMAP_D",
          getter = function() return not GetDB().minimapHide end,
          setter = function(v)
              local db = GetDB()
              -- stored inverted: minimapHide keeps old saved variables working
              db.minimapHide = not v
              -- the icon is created lazily; if the user shows it before it was
              -- ever built, build it first — then the update places it (hiding
              -- then showing must leave a button on screen, not nothing)
              if v and not miniBtn and BuildMinimapButton then pcall(BuildMinimapButton) end
              if MinimapButton_Update then MinimapButton_Update() end
          end },

        { kind = "select", key = "lang", ddName = "NearbySpyLangDD", width = 190,
          label = "SET_LANG", desc = "SET_LANG_D", entries = LangEntries,
          getter = function() return GetDB().locale or "AUTO" end,
          setter = function(v)
              local db = GetDB()
              db.locale = (v ~= "AUTO") and v or nil
              RefreshSettingsText()
              P(L("SET_RELOAD"))
          end },

        { kind = "select", key = "tz", ddName = "NearbySpyTzDD", width = 190,
          label = "SET_TZ", desc = "SET_TZ_D", entries = TzEntries,
          getter = function()
              local off = GetDB().tzOffset
              return (type(off) == "number") and off or "AUTO"
          end,
          setter = function(v)
              GetDB().tzOffset = (v ~= "AUTO") and v or nil
          end },
    }
end

-- Раскладка строк в любом родителе. Возвращает Y, на котором кончилось
-- содержимое (по нему хозяин считает высоту). Шаг считается по ИЗМЕРЕННОЙ высоте
-- текста: описание переносится на две-четыре строки в зависимости от шрифта
-- клиента и языка, и жёсткие 52 px накладывали длинные строки друг на друга.
-- nameSuffix нужен потому, что у дропдаунов есть ИМЕНА: два фрейма с одним
-- именем в WoW — ошибка «duplicate name», поэтому панель клиента получает свои.
function NspLayRows(parent, startY, store, nameSuffix)
    local rows = NspSetRows()
    local y = startY or -16
    local suffix = nameSuffix or ""
    for i = 1, #rows do
        local row = rows[i]
        if row.kind == "select" then
            local sel = OptSelect(parent, y, row.ddName .. suffix, row.label, row.desc,
                row.width, row.entries, row.getter, row.setter)
            store[row.key] = sel
            y = y - (46 + OptTextHeight(sel and sel.desc, 22)) - 18
        else
            local cb, label, desc = OptCheck(parent, 16, y, row.label, row.desc,
                row.getter, row.setter)
            store[row.key] = cb
            store[row.key .. "Label"] = label
            store[row.key .. "Desc"] = desc
            y = y - (4 + OptTextHeight(label, 14) + 3 + OptTextHeight(desc, 22)) - 16
        end
    end
    return y
end

local function BuildSettingsWindow()
    local okTpl, tplWin = pcall(CreateFrame, "Frame", "NearbySpySettings", UIParent,
        "BasicFrameTemplateWithInset")
    local win
    if okTpl and tplWin and tplWin.TitleText and tplWin.Bg and tplWin.CloseButton then
        win = tplWin
        win.TitleText:SetText(L("HUB_SETTINGS"))
    else
        if tplWin and tplWin.Hide then tplWin:Hide() end
        win = CreateFrame("Frame", "NearbySpySettings", UIParent)
        win:SetFrameStrata("DIALOG")
        local bg = win:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.05, 0.05, 0.08, 0.97)
        local title = NewText(win, 13, 1, 0.82, 0)
        title:SetPoint("TOP", 0, -12)
        title:SetText(L("HUB_SETTINGS"))
        opt.title = title
        -- the only template call without a guard: fall back to a manual X
        local okClose, closeBtn = pcall(CreateFrame, "Button", nil, win, "UIPanelCloseButton")
        if okClose and closeBtn then
            closeBtn:SetPoint("TOPRIGHT", -4, -4)
        else
            closeBtn = CreateFrame("Button", nil, win)
            closeBtn:SetSize(26, 26)
            closeBtn:SetPoint("TOPRIGHT", -6, -6)
            local x = NewText(closeBtn, 16, 1, 0.4, 0.4)
            x:SetPoint("CENTER")
            x:SetText("X")
            closeBtn:SetScript("OnClick", function() win:Hide() end)
        end
    end
    win:SetSize(380, 412)
    win:SetPoint("CENTER")
    SolidUnderlay(win)
    win:SetFrameStrata("DIALOG")
    StackWindow(win, 500)
    win:SetMovable(true)
    win:EnableMouse(true)
    win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", win.StartMoving)
    win:SetScript("OnDragStop", win.StopMovingOrSizing)
    win:EnableKeyboard(true)
    NspKeyboardPropagate(win, true)
    win:SetScript("OnKeyDown", function(_, key)
        if key == "ESCAPE" then
            NspKeyboardPropagate(win, false)
            win:Hide()
        else
            NspKeyboardPropagate(win, true)
        end
    end)
    optWin = win

    -- Rows are stacked by their MEASURED height, not by fixed offsets: a
    -- description wraps to two, three or four lines depending on the client
    -- font and the language, so hard-coded step of 52px made the longer rows
    -- overlap the next one (seen with the new "Accept other realms" checkbox).
    -- Сами строки берутся из общего списка NspSetRows — того же, из которого
    -- строится вкладка в меню модификаций.
    local rowY = NspLayRows(win, -52, opt)

    -- The window grows with its content: a fixed height clipped the last
    -- selector once a longer description was added.
    local needH = -rowY + 18
    if needH < 360 then needH = 360 end
    if win.SetHeight then win:SetHeight(needH) elseif win.SetSize then win:SetSize(380, needH) end

    win:Hide()
end

-- Live relabel after a language switch: only the settings surfaces rebuild their
-- text; windows built earlier keep their labels until /reload (hint is shown).
-- Text is relabelled in BOTH hosts — the custom window and the client's AddOns
-- panel — from the same row list, so a new row cannot be relabelled in one
-- place and forgotten in the other.
function NspRelabelRows(store)
    if type(store) ~= "table" then return end
    local rows = NspSetRows()
    for i = 1, #rows do
        local row = rows[i]
        if row.kind == "select" then
            local sel = store[row.key]
            if sel then
                if sel.label then sel.label:SetText(L(row.label)) end
                if sel.desc then sel.desc:SetText(L(row.desc)) end
                if sel.Refresh then sel.Refresh() end
            end
        else
            local lab, desc = store[row.key .. "Label"], store[row.key .. "Desc"]
            if lab then lab:SetText(L(row.label)) end
            if desc then desc:SetText(L(row.desc)) end
        end
    end
end

RefreshSettingsText = function()
    if optWin then
        local tt = optWin.TitleText or opt.title
        if tt and tt.SetText then tt:SetText(L("HUB_SETTINGS")) end
    end
    NspRelabelRows(opt)
    NspRelabelRows(optRows)
end

-- Проставить виджетам сохранённые значения. Нужно ОБОИМ хозяевам: настройку
-- можно поменять мимо панели (`/nspy peer off` в чате), и тогда галочка в меню
-- модификаций показывала бы неправду до /reload.
function NspSyncRowValues(store)
    if type(store) ~= "table" then return end
    local rows = NspSetRows()
    for i = 1, #rows do
        local row = rows[i]
        local w = store[row.key]
        if row.kind == "select" then
            if w and w.Refresh then w:Refresh() end
        elseif w and w.SetChecked then
            w:SetChecked(row.getter() and true or false)
        end
    end
end

ShowSettingsWindow = function()
    local ok, err = pcall(function()
        if not optWin then BuildSettingsWindow() end
        NspSyncRowValues(opt)
        optWin:Show()
    end)
    if not ok then P(L("ERR_WINDOW") .. tostring(err)) end
end

-- ── Вкладка в меню модификаций клиента (Settings → AddOns → NearbySpy) ─────
-- Как у остальных аддонов. Порядок ветвей взят из ЖИВОГО клиента (исходник
-- ForeverDungeonJournal/Systems/OptionsPanel.lua): сначала современная
-- Settings-API, при её отсутствии — старая InterfaceOptions. Оба API в этом
-- клиенте есть (замер по Interface/AddOns: Settings.Register* используют
-- Auctionator, Mastercraft, TalkingHeadRu, CatQuest; InterfaceOptions_AddCategory
-- — ForeverDungeonJournal, Details, BetterBlizzFrames).
-- Отдельный фрейм, а не переиспользование окна: у окна свой заголовок, рамка и
-- перетаскивание, а панель клиента сама рисует холст и скролл.
-- Глобалы (NspOptPanel/NspOptCategory), а не локалы: главный чанк стоит на 199
-- из 200 локалов Lua 5.1, и два «удобных» локала стоят дороже, чем одна буква
-- в имени.
local function BuildOptionsPanel()
    if NspOptPanel then return NspOptPanel end
    local p = CreateFrame("Frame", "NearbySpyOptionsPanel")
    -- Панель создаётся СКРЫТОЙ. Так делают оба аддона-образца этого клиента
    -- (Mastercraft: p:Hide(); TalkingHeadRu: panel:Hide()) — холст настроек
    -- показывает сама система при открытии вкладки. Без этого фрейм висит
    -- поверх игры сразу после входа.
    if p.Hide then p:Hide() end
    -- Старая API берёт заголовок вкладки из panel.name (у нового API он в
    -- аргументе), поэтому имя задаётся всегда.
    p.name = "NearbySpy"
    local lastY = NspLayRows(p, -16, optRows, "Opt")
    local h = -lastY + 16
    if h < 120 then h = 120 end
    if p.SetSize then p:SetSize(560, h) end
    p:SetScript("OnShow", function() pcall(NspSyncRowValues, optRows) end)
    NspOptPanel = p
    return p
end

-- true, если вкладка зарегистрирована (или уже была). false — регистрация не
-- удалась, и тогда команда открывает собственное окно аддона: молча ничего не
-- делать нельзя, иначе «настройки не открываются» без причины.
function NspRegisterOptions()
    if NspOptCategory then return true end
    local okBuild, p = pcall(BuildOptionsPanel)
    if not okBuild or not p then return false end
    if type(Settings) == "table" and Settings.RegisterCanvasLayoutCategory
        and Settings.RegisterAddOnCategory then
        local okReg, cat = pcall(function()
            local c = Settings.RegisterCanvasLayoutCategory(p, "NearbySpy")
            -- ID нужен Settings.OpenToCategory: по нему открывается вкладка
            if type(c) == "table" then c.ID = "NearbySpy" end
            Settings.RegisterAddOnCategory(c)
            return c
        end)
        if okReg and cat then
            NspOptCategory = cat
            return true
        end
    end
    if InterfaceOptions_AddCategory then
        local okReg = pcall(InterfaceOptions_AddCategory, p)
        if okReg then
            NspOptCategory = p
            return true
        end
    end
    return false
end

-- NspOpenOptions() — одна точка входа для `/nspy settings` и плитки в hub:
-- сначала вкладка клиента, иначе собственное окно.
function NspOpenOptions()
    if not NspOptCategory then pcall(NspRegisterOptions) end
    if NspOptCategory then
        if type(Settings) == "table" and Settings.OpenToCategory then
            -- Открывать надо по ИДЕНТИФИКАТОРУ категории, который отдаёт
            -- category:GetID() (так делает TalkingHeadRu в этом клиенте).
            -- Строковое имя система молча не находит: pcall не падает, окно не
            -- открывается — и команда «сработала», ничего не показав.
            local id
            if type(NspOptCategory.GetID) == "function" then
                local okId, v = pcall(NspOptCategory.GetID, NspOptCategory)
                if okId then id = v end
            end
            if id == nil then id = NspOptCategory.ID end
            if id ~= nil then
                local okOpen = pcall(Settings.OpenToCategory, id)
                if okOpen then return true end
            end
        end
        if InterfaceOptionsFrame_OpenToCategory then
            -- старый API: первый вызов открывает окно, второй выбирает вкладку —
            -- с одним вызовом игрок попадает на список категорий
            pcall(InterfaceOptionsFrame_OpenToCategory, NspOptCategory)
            pcall(InterfaceOptionsFrame_OpenToCategory, NspOptCategory)
            return true
        end
    end
    ShowSettingsWindow()
    return false
end

function MinimapButton_Update()
    if not miniBtn or not Minimap then return end
    local db = GetDB()
    if db.minimapHide then
        miniBtn:Hide()
        return
    end
    local okW, w = pcall(function() return Minimap:GetWidth() end)
    local r = ((okW and tonumber(w)) or 140) / 2 + 6
    local angle = math.rad(db.minimapAngle or -30)
    miniBtn:ClearAllPoints()
    miniBtn:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * r, math.sin(angle) * r)
    miniBtn:Show()
end

function BuildMinimapButton()
    if miniBtn or not Minimap then return end
    -- 31x31 как в Mastercraft/LibDBIcon: при этом размере центр кнопки
    -- (15.5) точно совпадает с центром нарисованного кольца (15.5)
    local BTN_SIZE = 31
    -- Иконка крупная и КРУГЛАЯ: исходник — непрозрачный квадрат 64x64, поэтому
    -- при увеличении его углы вылезали бы за обод, а собственные светлые края
    -- картинки читались как «рамка по бокам». Круглая маска
    -- TempPortraitAlphaMask (подтверждена в исходниках билда: её используют ~80
    -- мест FrameXML, есть и Texture:SetMask, и MaskTexture) срезает углы, а
    -- края картинки уходят под золотой обод.
    local ICON_SIZE = 27      -- с маской: чуть отступает от обода кольца
    local ICON_SIZE_SAFE = 24 -- без маски: крупный квадрат вылез бы из кольца
    miniBtn = CreateFrame("Button", "NearbySpyMinimapButton", Minimap)
    miniBtn:SetSize(BTN_SIZE, BTN_SIZE)
    miniBtn:SetFrameStrata("MEDIUM")
    -- уровень как у Mastercraft: иначе кнопка прячется под соседними элементами
    -- миникарты (лупа, календарь рисуются выше)
    miniBtn:SetFrameLevel(8)
    miniBtn:SetMovable(true)
    miniBtn:RegisterForDrag("LeftButton")
    miniBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    -- штатная подсветка кнопок миникарты (как в Mastercraft): WHITE8x8 с
    -- вершинным цветом выглядела как прямоугольная заливка
    pcall(function()
        miniBtn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    end)

    -- Схема кнопки взята из Mastercraft (Interface/AddOns/Mastercraft/Core.lua)
    -- — эта кнопка у пользователя выглядит правильно, и она же повторяет
    -- LibDBIcon, на котором висят кнопки тысяч аддонов:
    --     кнопка 31x31, frameLevel 8
    --     подложка 24x24 по CENTER  (UI-Minimap-Background)
    --     иконка   18x18 по CENTER
    --     кольцо   50-53 по TOPLEFT БЕЗ офсета (MiniMap-TrackingBorder)
    --
    -- Почему это работает, хотя кольцо прижато к углу: видимое кольцо в
    -- текстуре НЕ центрировано. Blizzard сама ставит эту текстуру с офсетом
    -- CENTER (11,-12), то есть у текстуры 53x53 центр нарисованного кольца
    -- лежит в (53/2-11, 53/2-12) = (15.5, 14.5) от угла. У кнопки 31x31 центр
    -- как раз (15.5, 15.5) — совпадает. Мой прежний расчёт принимал офсет за
    -- 10px, из-за чего кольцо уезжало на 6px: это и было «смещена от иконки».
    -- Иконка строится ПЕРВОЙ: её итоговый размер зависит от того, есть ли в
    -- клиенте круглая маска, и подложка должна получить размер уже после этого
    -- (иначе фон торчит из-под маленькой иконки). Порядок создания не влияет на
    -- порядок отрисовки — он задаётся слоями BACKGROUND/ARTWORK/OVERLAY.
    local icon = miniBtn:CreateTexture(nil, "ARTWORK")
    -- Маска ставится ДО текстуры: в клиенте отмечено, что маска перезаписывает
    -- tex coords, поэтому порядок «маска → текстура», как в самом Blizzard.
    local masked = pcall(function()
        icon:SetMask("Interface\\CharacterFrame\\TempPortraitAlphaMask")
    end)
    local iconSize = ICON_SIZE
    if not masked then
        -- маски нет (чужой клиент): крупный квадрат вылез бы за обод, поэтому
        -- возвращаемся к размеру, который целиком помещается в отверстие
        iconSize = ICON_SIZE_SAFE
    end
    icon:SetSize(iconSize, iconSize)
    -- 1px вправо: обод нарисован неравномерно по толщине, и математический
    -- центр читается как «иконка чуть левее». Подложка остаётся по центру.
    icon:SetPoint("CENTER", 1, 0)
    icon:SetTexture("Interface\\AddOns\\NearbySpy\\NearbySpyIcon")
    -- Подложка — тоже КРУГ и того же размера, что иконка. Квадратную подложку
    -- оставлять нельзя: её углы торчали бы из-под круглой иконки тёмными
    -- клиньями за ободом (ровно тот «квадрат», с которого всё началось).
    -- Без маски в клиенте подложку делаем на 1px меньше — тогда она целиком
    -- прячется за квадратной же иконкой.
    local disc = miniBtn:CreateTexture(nil, "BACKGROUND")
    local bgSize = masked and iconSize or (iconSize - 1)
    disc:SetSize(bgSize, bgSize)
    disc:SetPoint("CENTER")
    if masked then
        pcall(function()
            disc:SetMask("Interface\\CharacterFrame\\TempPortraitAlphaMask")
        end)
    end
    -- именно == false: часть версий API возвращает nil при успехе, и проверка
    -- на ложность вернула бы квадрат поверх круга
    if disc:SetTexture("Interface\\Minimap\\UI-Minimap-Background") == false then
        -- текстуры нет (чужой клиент/пережатые ресурсы) — остаётся плоский фон:
        -- кнопка некрасивая, зато видимая и кликабельная
        disc:SetColorTexture(0.06, 0.05, 0.03, 0.9)
    end

    -- Полупрозрачность: иконка читается как «под стеклом» кольца, и её
    -- квадратные углы меньше спорят с круглой формой кнопки.
    icon:SetAlpha(0.85)

    -- Кольцо по TOPLEFT без офсета — так же, как в Mastercraft и LibDBIcon.
    -- Кладём в OVERLAY, чтобы перекрывало края иконки.
    local ring = miniBtn:CreateTexture(nil, "OVERLAY")
    ring:SetSize(53, 53)
    ring:SetPoint("TOPLEFT")
    ring:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    local function onDragUpdate()
        local okC, mx, my = pcall(Minimap.GetCenter, Minimap)
        if not okC or not mx then return end
        local px, py = GetCursorPosition()
        local okS, scale = pcall(Minimap.GetEffectiveScale, Minimap)
        scale = (okS and tonumber(scale)) or 1
        px, py = px / scale, py / scale
        GetDB().minimapAngle = math.deg(Atan2(py - my, px - mx))
        MinimapButton_Update()
    end
    miniBtn:SetScript("OnDragStart", function(self) self:SetScript("OnUpdate", onDragUpdate) end)
    miniBtn:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
        self.dragged = true
    end)
    miniBtn:SetScript("OnClick", function(self, button)
        if self.dragged then
            self.dragged = false
            return
        end
        if button == "RightButton" then
            if win and win.IsShown and win:IsShown() then win:Hide() else ShowWindow() end
        else
            ToggleHubWindow()
        end
    end)
    miniBtn:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("NearbySpy", 1, 0.82, 0)
        GameTooltip:AddLine(L("MINIMAP_TIP_L"), 0.8, 0.78, 0.7)
        GameTooltip:AddLine(L("MINIMAP_TIP_R"), 0.8, 0.78, 0.7)
        GameTooltip:Show()
    end)
    miniBtn:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    MinimapButton_Update()
end

SLASH_NEARBYSPY1 = "/nearbyspy"
SLASH_NEARBYSPY2 = "/nspy"
-- NspParseAsk(rest) — разбор аргументов запроса базы у пиров (26.11.2026).
--
-- rest — хвост после слова ask: для `/nspy ask 60` это «60».
-- Возвращает target (кому), window (минуты), mode ("status" / "list" / nil).
--
-- Вынесено из диспетчера, потому что разбор нужно ПРОВЕРЯТЬ ТЕСТОМ, а не
-- глазами по сорока строкам ветки: команда `/nspy ask ...` долго не
-- существовала вовсе (живой случай 26.11.2026: «/nspy ask 60 не работает»,
-- ввод уходил в else и открывал окно помощи), и заметить это можно было
-- только запуском.
-- global: в главном чанке 195 локалов из 200.
function NspParseAsk(rest)
    if type(rest) ~= "string" then return nil, nil, nil end
    rest = rest:gsub("^%s+", ""):gsub("%s+$", "")
    if rest == "" then return nil, nil, nil end
    if rest == "status" or rest == "list" then return nil, nil, rest end
    -- «имя [минуты]»: имя двусловное у всех (замер по живому SV: 240
    -- отправителей, ни одного однословного), поэтому последний токен считаем
    -- минутами ТОЛЬКО если это чистое число.
    local name, num = rest:match("^(.-)%s+(%d+)$")
    if name and name ~= "" then
        -- Копипаст из чата/`list` тащит лишние пробелы: «Wolff  Magy» после
        -- схлопывания совпадёт с именем персонажа.
        return (name:gsub("%s+", " ")), num, nil
    end
    if rest:match("^%d+$") then return nil, rest, nil end
    return (rest:gsub("%s+", " ")), nil, nil
end

SlashCmdList["NEARBYSPY"] = function(msg)
    msg = string.lower((msg or ""):gsub("^%s+", ""):gsub("%s+$", ""))
    local db = GetDB()
    if msg == "" or msg == "show" then
        ShowWindow()
    elseif msg == "help" then
        local ok, err = pcall(ShowHelpWindow)
        if not ok then P(L("ERR_WINDOW") .. tostring(err)) end
    elseif msg == "server" then
        ShowServerWindow()
    elseif msg == "menu" or msg == "hub" then
        ToggleHubWindow()
    elseif msg == "minimap" then
        db.minimapHide = not db.minimapHide
        MinimapButton_Update()
        P(db.minimapHide and L("MM_OFF") or L("MM_ON"))
    elseif msg == "settings" or msg == "options" then
        -- Как у всех аддонов: вкладка в меню модификаций, иначе окно аддона.
        local okS, opened = pcall(NspOpenOptions)
        if not okS then P(L("ERR_WINDOW") .. tostring(opened)) end
    elseif msg == "whotest" or msg:match("^whotest%s") then
        -- diagnostic: probe the programmatic /who gate on this build
        --   /nspy whotest              three send paths, 15 s each
        --   /nspy whotest gap 150 4    four button clicks, 150 s apart
        StartWhoTest(msg:match("^whotest%s+(.*)$"))
    elseif msg == "gear" or msg:match("^gear%s") then
        -- passive gear/talent snapshots taken on encounters (no window opened)
        --   /nspy gear           status + counters
        --   /nspy gear on|off    toggle collection
        if type(NSP_INSPECT) ~= "table" then
            P("gear: module is missing (NearbySpy_Inspect.lua not loaded)")
        else
            NSP_INSPECT.P, NSP_INSPECT.GetDB, NSP_INSPECT.DbgErr = P, GetDB, DbgErr
            local mode = msg:match("^gear%s+(%a+)$")
            if mode == "on" then
                local okG, errG = pcall(NSP_INSPECT.Toggle, true)
                if not okG then P("gear: " .. tostring(errG)) end
            elseif mode == "off" then
                local okG, errG = pcall(NSP_INSPECT.Toggle, false)
                if not okG then P("gear: " .. tostring(errG)) end
            else
                local okG, errG = pcall(NSP_INSPECT.Report)
                if not okG then P("gear: " .. tostring(errG)) end
            end
        end
    elseif msg == "whostop" then
        if whoScan then
            FinishZoneScan("stopped manually")
        else
            P(L("SCAN_NOT_RUNNING"))
        end
    elseif msg == "suggest" or msg == "who" or msg == "whoclass" or msg == "whorace"
        or msg == "who new" or msg == "whospeed" or msg == "who speed"
        or msg == "who speed new" then
        -- assisted /who (70291): programmatic sends are hardware-gated by the
        -- server — only the user's click on the magnifier gets a reply. All
        -- scan commands are assisted; repeating a command stops the scan.
        local forceNew = (msg == "who new" or msg == "who speed new")
        if msg == "who new" then msg = "who" end
        if msg == "who speed new" then msg = "who speed" end
        if whoScan then
            FinishZoneScan("stopped manually")
            if forceNew then
                -- "who new" doubles as "stop and forget", so the next run is fresh
                GetDB().scan = nil
                P(L("SCAN_FORGOTTEN"))
            end
        else
            -- suggest/whoclass go straight to class slices: a wide 1-60 is
            -- pointless — on this server even 1-1 is overfull, the first click
            -- always hits the 50 cap
            local mode = ({ suggest = "class", who = "level", whoclass = "class",
                whorace = "race", whospeed = "speed", ["who speed"] = "speed" })[msg]
            local ok, info = StartZoneScan(PlayerZone() or "?", true, mode, true, forceNew)
            if ok then
                P(L("SUGGEST_STARTED"))
                if mode == "speed" then P(L("WHO_SPEED_ON")) end
            else
                P(L("SUGGEST_FAILED") .. tostring(info))
            end
        end
    elseif msg == "itemnames" or msg:match("^itemnames%s") then
        -- Имена предметов по ID: спрашиваются у клиента ПО ЗАПРОСУ, потому что
        -- в SavedVariables экипировка лежит числами, а имя есть только в игре.
        --   /nspy itemnames         спросить неизвестные ID (до 2000)
        --   /nspy itemnames 200     ограничить прогон
        --   /nspy itemnames all     весь справочник, без потолка
        --   /nspy itemnames retry   переспросить тех, кто не отдал тултип
        --   /nspy itemnames refresh переспросить ВСЁ (после смены формата записи)
        --   /nspy itemnames show    показать, что уже собрано
        if type(NSP_ITEMS) ~= "table" then
            P("itemnames: модуль не загружен (NearbySpy_Items.lua)")
        else
            NSP_ITEMS.P, NSP_ITEMS.GetDB = P, GetDB
            local arg = msg:match("^itemnames%s+(%S+)$")
            local okI, errI
            if arg == "show" or arg == "list" then
                okI, errI = pcall(NSP_ITEMS.Report)
            elseif arg == "stats" then
                -- разбор ключей статов: какие enum-ключи реально приходят
                okI, errI = pcall(NSP_ITEMS.ReportStats)
            elseif arg == "probe" then
                -- что ФАКТИЧЕСКИ возвращает GetItemStats (форма и типы ключей)
                okI, errI = pcall(NSP_ITEMS.ProbeStats)
            else
                okI, errI = pcall(NSP_ITEMS.Run, arg)
            end
            if not okI then P("itemnames: " .. tostring(errI)) end
        end
    elseif msg == "mem" then
        -- Память базы: сколько занимает Lua и из чего состоит база. Цифра
        -- «записей» — главная: она и определяет вес (поля почти не влияют).
        local kb = 0
        if type(collectgarbage) == "function" then
            local okC, v = pcall(collectgarbage, "count")
            if okC and type(v) == "number" then kb = v end
        end
        local total, own, foreign = 0, 0, 0
        local myRealm = (GetRealmName and GetRealmName()) or ""
        for _, p in pairs(db.players) do
            if type(p) == "table" then
                total = total + 1
                if (p.realm or "") == myRealm then own = own + 1 else foreign = foreign + 1 end
            end
        end
        P(("mem: Lua %.1f МБ (%d КБ); записей %d (свой реалм %d, чужие %d); retain %d дн.")
            :format(kb / 1024, math.floor(kb), total, own, foreign, tonumber(db.retainDays) or 0))
    elseif msg == "retain" or msg:match("^retain%s") then
        -- Срок хранения записей в SavedVariables. Умолчание — 7 дней
        -- (NSP_CONST.RETAIN_DAYS): база растёт от числа встреч, и без срока она
        -- упирается в память клиента. Удаление необратимо, поэтому полный снимок
        -- надо сохранить в файл ДО чистки (games/wow/scripts/archive_nspy.py).
        --   /nspy retain           — показать настройку и что будет удалено
        --   /nspy retain 14        — хранить 14 дней
        --   /nspy retain off       — не чистить вовсе (пишется 0, не nil:
        --                            nil вернул бы умолчание при следующем входе)
        local arg = msg:match("^retain%s+(%S+)$")
        if arg == "off" or arg == "0" then
            db.retainDays = 0
            P("retain: чистка выключена, записи не удаляются")
        elseif arg and tonumber(arg) then
            local days = math.floor(tonumber(arg))
            if days < 1 then days = 1 end
            db.retainDays = days
            P(("retain: хранить %d дн.; чистка выполняется при выходе из игры"):format(days))
        else
            local days = tonumber(db.retainDays) or 0
            if days > 0 then
                P(("retain: %d дн. (чистка при выходе включена)"):format(days))
            else
                P("retain: чистка выключена — записи не удаляются")
            end
        end
        -- сухой прогон: считаем, что удалилось бы, НЕ удаляя
        do
            local total = CountPlayers()
            local days = tonumber(db.retainDays)
            if days and days > 0 then
                local now = time()
                local cutoff = now - days * 86400
                local dead = 0
                for _, p in pairs(db.players) do
                    if type(p) == "table" then
                        local seen = tonumber(p.lastSeen) or 0
                        local peer = tonumber(p.peerAt) or 0
                        if peer > seen then seen = peer end
                        if seen <= 0 then seen = tonumber(p.firstSeen) or 0 end
                        if seen > 0 and seen < cutoff then dead = dead + 1 end
                    else
                        dead = dead + 1
                    end
                end
                P(("retain: удалилось бы %d из %d записей (~%.0f КБ)"):format(
                    dead, total, dead * 300 / 1024))
            end
        end
    elseif msg == "count" then
        P(L("COUNT"):format(
            CountPlayers(), newThisSession, db.announce and L("ON") or L("OFF")))
        -- Размер базы в SavedVariables. Нужен, чтобы игрок видел реальную
        -- картину, а не узнавал о ней отказом загрузки на сайте: файл растёт
        -- с числом встреченных игроков, и умолчание об этом — плохой способ
        -- сообщить о пределе.
        do
            local n = CountPlayers()
            -- ~378 байт на запись с экипировкой; оценка нужна без обхода
            -- всех ключей и сериализации, поэтому берём по числу записей
            local est = math.floor(n * 380 / 1024)
            local kb, mb = est, est / 1024
            local sizeTxt
            if mb >= 1 then
                sizeTxt = ("%.1f MB"):format(mb)
            else
                sizeTxt = ("%d KB"):format(kb)
            end
            P(("db size: ~%s (%d records)"):format(sizeTxt, n))
        end
        P(DebugSummary(db))
        -- Блокировки гейта: свои отдельно от чужих, плюс клавиатура в бою и
        -- отправки, совпавшие с отказом (15.11.2026).
        P(("debug: our gate blocks=%s, other addons=%s, keyboard skipped in combat=%d, gate-coincident sends=%d")
            :format(type(db.debug) == "table" and NspCountKeys(db.debug.blocked) or 0,
                type(db.debug) == "table" and NspCountKeys(db.debug.blockedOther) or 0,
                tonumber(db.debug.kbLockdown) or 0,
                tonumber(db.debug.peerGate) or 0))
        -- Ошибки по источникам: видно в чате, без чтения SV. Показываем последнюю
        -- и счётчик — «в логе была ошибка» должно быть проверяемо командой.
        local errKeys = {}
        for src in pairs(type(db.debug.errCount) == "table" and db.debug.errCount or {}) do
            errKeys[#errKeys + 1] = src
        end
        table.sort(errKeys)
        if #errKeys == 0 then
            P("errors: none recorded")
        else
            for _, src in ipairs(errKeys) do
                -- Возраст обязателен: errLast переживает логаут и остаётся в SV
                -- навсегда, поэтому починенная два дня назад ошибка читалась
                -- как «живая» (живой случай 20.11.2026: обе строки errLast были
                -- от 16 и 19 ноября, то есть до сегодняшнего прогона). Без метки
                -- времени команда отвечает не на тот вопрос, который задают.
                local at = type(db.debug.errAt) == "table" and db.debug.errAt[src]
                P(("error[%s] x%d (%s): %s"):format(src, tonumber(db.debug.errCount[src]) or 0,
                    TimeAgo(tonumber(at)),
                    PeerEsc(tostring((db.debug.errLast or {})[src] or "?"), 110)))
            end
        end
    elseif msg == "me" or msg == "journal" then
        -- Per-character journal (1.5.7): playtime, zones, encounters, progress.
        if NSP_JOURNAL then
            NSP_JOURNAL.P, NSP_JOURNAL.L = P, L
            local okJ, errJ = pcall(NSP_JOURNAL.Report, db)
            if not okJ then DbgErr("journalReport", errJ) end
        else
            P("journal module is missing")
        end
    elseif msg == "announce" then
        db.announce = not db.announce
        P(L("ANNOUNCE_TOGGLE") .. (db.announce and L("ON") or L("OFF")))
    elseif msg == "debug" then
        -- debug mode: on → logs (digests, scan progress, gate blocks) print to
        -- chat; off → stealth mode, chat shows only command replies,
        -- announcements and errors. Everything goes to the SV ring in both modes.
        db.debugMode = not db.debugMode
        P(db.debugMode and L("DEBUG_ON") or L("DEBUG_OFF"))
    elseif msg == "peer on" then
        db.peerEnabled = true
        local ok, err = pcall(JoinPeerChannel)
        if not ok then DbgErr("peerJoin", err) end
        P(L("PEER_ON"):format(PeerChannelName()))
        D(("Peer join attempt: channel=%s"):format(tostring(GetChannelName(PeerChannelName()))))
        if PeerSync then pcall(PeerSync) end
    elseif msg == "peer off" then
        db.peerEnabled = false
        peerQueue, peerQueued = {}, {}
        if peerChatVisible then pcall(SetPeerChatVisible, false) end
        if LeaveChannelByName then pcall(LeaveChannelByName, PeerChannelName()) end
        P(L("PEER_OFF"))
        if PeerSync then pcall(PeerSync) end
    elseif msg == "peer chat on" or msg == "peer chat off" then
        local visible = msg == "peer chat on"
        local ok, result = pcall(SetPeerChatVisible, visible)
        if ok and result then
            P("Peer channel visibility: " .. (visible and "ON" or "OFF") .. " (session only)")
        else
            P("Peer channel visibility unavailable: " .. tostring(result))
        end
    elseif msg == "zones" then
        -- Диагностика словаря зон БЕЗ /who: словарь строится лениво именно при
        -- /who, поэтому проверить его после правки иначе нечем — а сам /who
        -- тратит серверный троттлинг. Команда принудительно пересобирает
        -- словарь и печатает всё, что нужно для решения: сколько нашлось,
        -- сколько корней, какие типы карт запрашивались и есть ли API.
        NSP_ZONE_BY_NAME, NSP_ZONE_NAME_BY_ID = nil, nil
        zoneMapLastScan = 0
        local t0 = time()
        local byName, byId = ZoneMapInit()
        local ms = math.floor((time() - t0) * 1000)
        local n = 0
        for _ in pairs(byId) do n = n + 1 end
        local dbg = (db.debug and db.debug.zoneMap) or {}
        P(("zones: found=%d, roots=%s, %dms, preload=%s enum=%s")
            :format(n, tostring(dbg.roots), ms,
                tostring(dbg.hasPreload), tostring(dbg.hasEnum)))
        if type(dbg.types) == "table" then
            P("zones: map types requested = " .. table.concat(dbg.types, ","))
        end
        -- Примеры: по одному имени на каждые 200 записей — видно, что реально
        -- попало в словарь (и на каком языке), без вываливания всего в чат.
        local shown, list = 0, {}
        for id, name in pairs(byId) do
            shown = shown + 1
            if shown % 200 == 0 then list[#list + 1] = name .. "=" .. tostring(id) end
        end
        table.sort(list)
        if #list > 0 then P("zones: " .. table.concat(list, "; ")) end
        P(("zones: name lookup '%s' -> %s"):format(
            PlayerZone() or "?", tostring(byName[PlayerZone() or ""] or "нет")))
    elseif msg == "peer proto" then
        -- Переходный режим для старых клиентов в канале: без переустановки
        -- аддона. Цикл N7 ↔ N5. N7 — плотный формат; N5 — поля текстом, его
        -- понимает ЛЮБОЙ клиент, включая версии до N6. Отправки N6 нет
        -- намеренно: запись у N6 и N7 одной раскладки, и старый клиент принял
        -- бы код мира за имя (то есть испортил бы запись, а не пропустил её).
        PEER_PROTO = (PEER_PROTO == "N7") and "N5" or "N7"
        db.peerProto = PEER_PROTO
        P(("Peer protocol: %s (приём N2-N7 работает всегда)"):format(PEER_PROTO))
        if PeerSync then pcall(PeerSync) end
    elseif msg == "peer gear" or msg:match("^peer gear%s") or msg:match("^peer seed%s") then
        -- Экипировка и билды в канале (20.11.2026).
        --   /nspy peer gear            статус + счётчики
        --   /nspy peer gear on|off     включить/выключить отправку
        --   /nspy peer seed N          догрузить N уже собранных снапшотов
        -- Флаг ХРАНИТСЯ ИНВЕРТИРОВАННО (peerGearOff): старая SV без ключа
        -- означает «включено», а прямая запись нового поля сбросила бы настройку
        -- у всех, у кого файл уже есть.
        local db = GetDB()
        local q = peerStats.gearQueue
        local qn = (type(q) == "table") and #q or 0
        local mode = msg:match("^peer gear%s+(%a+)$") or msg:match("^peer seed%s+(%d+)$")
        if msg:match("^peer seed%s+(%d+)$") then
            local want = math.floor(tonumber(msg:match("^peer seed%s+(%d+)$")) or 0)
            if want < 1 then want = 1 end
            if want > 200 then want = 200 end
            local n, total = 0, 0
            if type(db.gearRing) == "table" then
                total = #db.gearRing
                for _, key in ipairs(db.gearRing) do
                    if n >= want then break end
                    local entry = db.players and db.players[key]
                    local snap = entry and entry.gear
                    if type(snap) == "table" and not snap.from then
                        local before = #peerStats.gearQueue
                        PeerQueueGear(key, snap)
                        if #peerStats.gearQueue > before then n = n + 1 end
                    end
                end
            end
            P(("peer: %d of %d stored snapshots queued (ring has %d)")
                :format(n, want, total))
        elseif mode == "on" then
            db.peerGearOff = nil
            P("peer gear: on (gear and builds are shared)")
        elseif mode == "off" then
            db.peerGearOff = true
            peerStats.gearQueue = {}
            P("peer gear: off (nothing more is sent or accepted)")
        else
            P(("peer gear: %s, queued=%d, sent=%d, in=%d, orphan=%d, stale=%d, bad=%d")
                :format(db.peerGearOff and "off" or "on", qn,
                        peerStats.gearSentCount or 0, peerStats.gearIn or 0,
                        peerStats.gearOrphan or 0, peerStats.gearStale or 0,
                        peerStats.gearBad or 0))
            -- Orphan-буфер (25.11.2026): отложенные снапшоты, которые ждут
            -- появления строки игрока. Если adopted не растёт, а held упирается
            -- в 200 — записи о встречах до нас не доходят, и буфер не при чём.
            if NSP_INSPECT and type(NSP_INSPECT.OrphanStats) == "function" then
                local okO, s = pcall(NSP_INSPECT.OrphanStats)
                if okO and type(s) == "table" then
                    P(("peer gear orphan buffer: held=%d buffered=%d adopted=%d expired=%d evicted=%d stale=%d")
                        :format(s.held or 0, s.buffered or 0, s.adopted or 0,
                                s.expired or 0, s.evicted or 0, s.stale or 0))
                end
            end
        end
        if PeerSync then pcall(PeerSync) end
    elseif msg == "peer ask" or msg == "ask"
        or msg:match("^peer ask%s") or msg:match("^ask%s") then
        -- Запрос базы у пиров (Q1/A1, 24.11.2026):
        --   /nspy ask                     запрос всем, за последний час
        --   /nspy ask 180                 запрос всем, за 3 часа (кламп 5…1440)
        --   /nspy ask Wolff               только этому игроку, окно по умолчанию
        --   /nspy ask Wolff 180           только ему, за 3 часа
        --   /nspy ask list                кто вообще говорил в канале (для обхода)
        --   /nspy ask status              состояние и счётчики, без отправки
        -- Приставка "peer" необязательна: игрок ищет команду по смыслу («спросить
        -- у пиров»), а не по внутреннему имени узла. Живой случай 26.11.2026:
        -- `/nspy ask 60` молча открывал окно помощи, потому что ветки для "ask"
        -- не было ни одной.
        -- Имя нужно, чтобы спрашивать по очереди: иначе на каждый запрос
        -- отвечают ВСЕ участники, а канал держит ~10 сообщений в минуту.
        -- Ник приводится к нижнему регистру диспетчером команд — сравнение на
        -- приёме тоже регистронезависимое, поэтому это не мешает.
        local rest = msg:match("^peer ask%s+(.+)$") or msg:match("^ask%s+(.+)$")
        local target, window, askMode = NspParseAsk(rest)
        if askMode == "status" then
            P(("peer ask: sent=%d, outgoing=%d, requests_in=%d, answer_rows=%d, answer_gear=%d, skipped=%d, empty=%d, in=%d, stray=%d")
                :format(peerStats.askSent or 0, peerStats.askOut or 0,
                        peerStats.askReqIn or 0, peerStats.askQueued or 0,
                        peerStats.askGearQueued or 0, peerStats.askSkipped or 0,
                        peerStats.askEmpty or 0, peerStats.askIn or 0,
                        peerStats.askStray or 0))
            -- Открытые запросы: при обходе их несколько, и надо видеть, чей ответ
            -- ещё не пришёл, а чей закрылся по времени.
            local openN, waiting = 0, {}
            if type(peerStats.askOpen) == "table" then
                for n, req in pairs(peerStats.askOpen) do
                    if time() <= (tonumber(req.expires) or 0) then
                        openN = openN + 1
                        if not req.answered then
                            waiting[#waiting + 1] = tostring(req.target or "all")
                        end
                    end
                end
            end
            P(("peer ask: open=%d, waiting for: %s")
                :format(openN, #waiting > 0 and table.concat(waiting, ", ") or "nobody"))
            P(("peer ask: pending answer=%s, ignored(not me)=%d, wrong sender=%d, last answer from=%s")
                :format(tostring(type(peerStats.askPending) == "table"),
                        peerStats.askNotMe or 0, peerStats.askWrongSender or 0,
                        tostring(peerStats.askLastFrom or "nobody")))
            P("peer ask: an answer is the newest rows the peer saw in the window - the channel carries ~10 messages a minute, not a whole dump")
        elseif askMode == "list" then
            local peers = PeerAskKnownPeers(db)
            if #peers == 0 then
                P("peer ask list: nobody has spoken in this channel yet - turn sharing on (/nspy peer on) and wait for other players")
            else
                P(("peer ask list: %d known peers (ask them one by one: /nspy peer ask <name>)"):format(#peers))
                local shown = #peers > 15 and 15 or #peers
                for i = 1, shown do
                    P(("  %d. %s (%d packets)"):format(i, peers[i].name, peers[i].count))
                end
                if #peers > shown then
                    P(("  ... and %d more"):format(#peers - shown))
                end
            end
        else
            local okA, done, payload = pcall(PeerAskSend, db, window, target)
            if not okA then
                P("peer ask error: " .. tostring(done))
            elseif not done then
                P("peer ask not sent: " .. tostring(payload))
            else
                P(("peer ask queued: %s"):format(tostring(payload)))
                if target then
                    P(("  only %s will answer, so you can go through peers one by one"):format(target))
                else
                    P("  everybody who has this version will answer - add a name to ask one peer only")
                end
                P("  it leaves on the next click in the world (hardware gate); /nspy peer send forces it")
            end
            if PeerSync then pcall(PeerSync) end
        end
    elseif msg == "peer send" then
        -- Ручная разгрузка очереди. Очередь штатно уходит только по клику в
        -- 3D-мир (hardware gate беты: WorldFrame OnMouseDown). Если этот гейт
        -- не срабатывает (кастомный клиент, окно поверх мира), пакеты стоят
        -- вечно — что и наблюдалось 10.11.2026: queued=4, sent=0. Команда
        -- пробует отправку тем же путём, но по явному требованию игрока.
        local before = peerStats.sent
        local okSend, errSend = pcall(DrainPeerQueue)
        if not okSend then
            P("Peer send error: " .. tostring(errSend))
        else
            local sent = peerStats.sent - before
            local ch = GetChannelName(PeerChannelName())
            P(("Peer send: %d sent, %d queued, channel=%s (%s)")
                :format(sent, #peerQueue, tostring(ch), PeerChannelName()))
            if sent == 0 and #peerQueue > 0 then
                -- причины по порядку: канал не присоединён, гейт PEER_GAP,
                -- ошибка SendChatMessage в db.debug.peerSendError
                P("  not sent: channel " .. tostring(ch)
                    .. (db.debug.peerSendError and (", error: " .. tostring(db.debug.peerSendError)) or ""))
            end
        end
        if PeerSync then pcall(PeerSync) end
    elseif msg == "peer new" or msg == "peer list" then
        -- "peer new" = то, чему канал научил ЗА ЭТУ СЕССИЮ (тот же набор, что
        -- вкладка "Peer new"); "peer list" = всё, что канал принёс когда-либо,
        -- включая обновления. peerAt/peerNew лежат в SavedVariables, поэтому
        -- без отсечки по tactical.started "peer new" показывал записи за всё
        -- время — на живом файле это 1451 строка за 19 часов.
        local onlyNew = (msg == "peer new")
        local list, fresh, foreign = {}, 0, 0
        for _, p in pairs(db.players) do
            if (p.peerAt or 0) > 0 then
                local thisSession = (p.peerAt or 0) >= tactical.started
                if p.peerNew and thisSession then fresh = fresh + 1 end
                if p.peerForeign then foreign = foreign + 1 end
                if not onlyNew or (p.peerNew and thisSession) then list[#list + 1] = p end
            end
        end
        if #list == 0 then
            P(L("PEER_LIST_EMPTY"):format(PeerChannelName()))
        else
            table.sort(list, function(a, b) return (a.peerAt or 0) > (b.peerAt or 0) end)
            local shown = #list > 20 and 20 or #list
            P(L("PEER_LIST_HEAD"):format(#list, fresh, shown))
            if foreign > 0 then P(L("PEER_LIST_FOREIGN"):format(foreign)) end
            for i = 1, shown do
                local p = list[i]
                P(("%d. %s (%s %s, %s) - %s, %s%s"):format(i, p.name or "?",
                    p.class or "?", tostring(p.level or "?"), p.faction or "?",
                    p.peerNew and L("PEER_TAG_NEW") or L("PEER_TAG_UPD"),
                    TimeAgo(p.peerAt),
                    p.peerForeign and (" [" .. PeerEsc(p.realm or "?", 40) .. "]") or ""))
            end
        end
    elseif msg == "peer" then
        P(L("PEER_STATUS"):format(
            db.peerEnabled and L("ON") or L("OFF"), tostring(GetChannelName(PeerChannelName())),
            #peerQueue, peerStats.sent, peerStats.received, peerStats.dropped,
            db.debug.peerSendError and (", error=" .. db.debug.peerSendError) or ""))
        -- Показываем ТОЛЬКО свой фракционный канал: базовое имя в выводе путало
        -- (казалось, что аддон всё ещё сидит в общем канале). Номер 0 = вход не
        -- состоялся, это единственное, что здесь важно.
        local joinInfo = type(db.debug) == "table" and db.debug.peerJoin or nil
        local ownName = PeerChannelName()
        local ownId = GetChannelName(ownName)
        P(("Peer channel: %s (id=%s)%s")
            :format(ownName, tostring(ownId),
                joinInfo and (("; last join: %s") :format(
                    joinInfo.ok and "ok" or ("FAILED " .. tostring(joinInfo.result)))) or ""))
        P(("Peer transport: seen=%d, valid=%d, rejected=%d, duplicates=%d, merged=%d, foreign=%d, selfEcho=%d, throttled=%d, chat=%s, lastSender=%s")
            :format(peerStats.seen, peerStats.valid, peerStats.rejected,
                peerStats.valid - peerStats.received - peerStats.merged, peerStats.merged,
                peerStats.foreign, peerStats.selfEcho, peerStats.throttled or 0,
                peerChatVisible and "ON" or "OFF",
                peerStats.lastSender or "-"))
        -- Приборы отправки: что вернул вызов канала и сколько отправок совпало с
        -- отказом гейта. Без этого «ушёл пакет или нет» было не проверить.
        P(("Peer send probe: last return %s; gate-coincident sends=%d")
            :format(tostring(db.debug.sendRet or "none"),
                tonumber(db.debug.peerGate) or 0))
        -- counters of the LAST logged session: the only cross-session proof that
        -- the channel carries anything at all (memory-only stats die on logout)
        local last = type(db.debug) == "table" and db.debug.peer or nil
        if type(last) == "table" then
            P(("Peer last session: sent=%d received=%d merged=%d foreign=%d selfEcho=%d seen=%d valid=%d rejected=%d throttled=%d channel=%s lastSender=%s")
                :format(last.sent or 0, last.received or 0, last.merged or 0, last.foreign or 0,
                    last.selfEcho or 0, last.seen or 0, last.valid or 0, last.rejected or 0,
                    last.throttled or 0, tostring(last.channel), PeerEsc(last.lastSender or "-", 40)))
        else
            P("Peer last session: no saved counters yet (written on logout)")
        end
    elseif msg == "world" then
        local vendors, items, fish, mcNew = WR.Counts()
        P(L("WORLD_STATUS"):format(vendors, items, fish))
        -- Сверка с базой MasterCraft: счётчик находок и версия снимка. Версия
        -- важна — по ней видно, насколько сравнение свежее (старый снимок даёт
        -- ложные «новые», если MasterCraft успел обновиться).
        local mcVer = (type(NSP_MC) == "table" and NSP_MC.version) or "?"
        P(L("MC_STATUS"):format(mcNew, mcVer))
    elseif msg == "reset" then
        db.players = {}
        newThisSession = 0
        P(L("DB_CLEARED"))
    else
        local ok, err = pcall(ShowHelpWindow)
        if not ok then P(L("ERR_WINDOW") .. tostring(err)) end
    end
end

-- ============ chat as a name source ============
-- SAY/YELL/CHANNEL give the speaker's name without class/level/zone — a passive
-- backfill for the database: city channels (trade, local) show players that
-- nameplate scans and rosters never reach. Class/level/zone fields are NOT
-- passed (nil, not ""): UpsertPlayer overwrites only present keys, so known
-- players' data is not zeroed; new chat entries' empty fields are filtered
-- downstream anyway (parser -> "", site: class<>'' and level>0).
-- Signature (wowpedia + warcraft.wiki, retail and the classic relaunch match):
--   text, playerName, languageName, channelName, playerName2, specialFlags, ...
-- i.e. the speaker is the event's 2nd argument (after the event name) —
-- confirmed on the live beta via SV dumps (11.10.2026).
local chatFrame = CreateFrame("Frame")
local function IsPeerChannel(channelName)
    if type(channelName) ~= "string" or (canaccessvalue and not canaccessvalue(channelName)) then return false end
    channelName = channelName:lower()
    -- Снимаем клиентский префикс "1. ": имя канала приходит и с ним, и без.
    local base = channelName:match("^%d+%. (.+)$") or channelName
    if base == PEER_CHANNEL_BASE then return true end
    -- Фракционный вариант: базовое имя плюс РОВНО один буквенно-цифровой
    -- символ (nearbyspya / nearbyspyh и любые будущие). Больше одного быть не
    -- может: подчёркивание в имени канала клиент не принимает, а сравнение по
    -- префиксу без этой границы съело бы чужой канал.
    if base:match("^" .. PEER_CHANNEL_BASE .. "[%w]$") then return true end
    -- Старые имена канала: сообщения того же протокола, их тоже прячем из чата,
    -- чтобы после переименования старые строки не сыпались игроку.
    for _, legacy in ipairs(PEER_CHANNEL_LEGACY) do
        if base == legacy then return true end
    end
    return false
end
-- Hide only our data messages, never suppress channel notices or other channels.
local addMessageFilter = ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter or ChatFrame_AddMessageEventFilter
if addMessageFilter then
    addMessageFilter("CHAT_MSG_CHANNEL", function(_, _, _, _, _, channelName, _, _, _, _, rawChannel)
        return IsPeerChannel(rawChannel) or IsPeerChannel(channelName)
    end)
end
-- Разгрузка очереди обмена. Сервер требует РЕАЛЬНОГО ввода для отправки в
-- канал (hardware gate беты) — программный SendChatMessage в тишине не
-- проходит. Обойти это нельзя, но можно ловить БОЛЬШЕ реальных вводов:
-- раньше триггер был один (клик по 3D-миру), и очередь стояла вечно, пока
-- игрок специально не кликнет по земле (наблюдалось 10.11.2026: queued=9,
-- sent=0). Теперь разгрузка пробуется на любом действии, которое физически
-- делает игрок: движение, каст, смена цели, клик по миру.
--
-- DrainPeerQueue сам решает, можно ли отправлять (PEER_GAP, наличие канала,
-- пустая очередь), поэтому лишние вызовы ничего не стоят.
-- Диагностика: сколько раз каждый триггер реально пытался отправить. По SV
-- видно, работают ли hardware-ворота в этом клиенте и какие вводы до них
-- доходят (peerSendError покажет отказ сервера).
function PeerDrainStat(why)
    local okDb, db = pcall(GetDB)
    if not okDb or type(db) ~= "table" then return end
    db.debug = db.debug or {}
    db.debug.peerDrain = db.debug.peerDrain or {}
    db.debug.peerDrain[why] = (db.debug.peerDrain[why] or 0) + 1
    -- Последний контекст вызова: по нему NspNoteSendRet атрибутирует блокировку
    -- гейта (см. db.debug.gateWhy). Глобал-поле, а не local — чанк у потолка.
    db.debug.lastDrainWhy = tostring(why)
end

local function PeerTryDrain(why)
    PeerDrainStat(why)
    local ok, err = pcall(DrainPeerQueue)
    if not ok then DbgErr("peerSend:" .. tostring(why), err) end
end

if WorldFrame and WorldFrame.HookScript then
    WorldFrame:HookScript("OnMouseDown", function() PeerTryDrain("world") end)
end

-- Разгрузка очереди по игровым событиям — СНЯТА (20.11.2026).
--
-- История: 16.11.2026 отсюда убрали движение (PLAYER_STARTED_MOVING /
-- STOPPED_MOVING): клиент пускает SendChatMessage в канал только из
-- hardware-события, а движение таковым не является — на нём гейт отвечал
-- ADDON_ACTION_BLOCKED, и игрок видел попап «Интерфейсная операция недоступна
-- из-за модификации». Три оставшихся события (UNIT_SPELLCAST_START,
-- PLAYER_TARGET_CHANGED, START_LOOT_ROLL) держались «под замер».
--
-- Замер закончен, живые счётчики одного прогона:
--
--   триггер                  попыток   отказов гейта
--   world (клик по миру)      34 598        0        ← единственный рабочий
--   PLAYER_TARGET_CHANGED      8 822      106
--   UNIT_SPELLCAST_START       1 498       27
--   START_LOOT_ROLL              102        1
--
-- 134 отказа = 134 попапа об ошибке интерфейса при НУЛЕВОМ вкладе в отправку:
-- за тот же прогон отправлено 16 сообщений, и все — по клику по миру.
-- Поэтому события сняты целиком, а не приглушены: отказ приходит на сам вызов,
-- и «пробовать реже» не уменьшило бы показ попапа, только его частоту.
--
-- Если понадобится вернуть источник отправок — возвращать НЕ эти события, а
-- искать другой настоящий hardware-ввод (варианты под замер: нажатие клавиши
-- через модификатор, клик по юнитфрейму). Проверять данными: db.debug.peerDrain
-- против db.debug.gateWhy, а не по названию события.

chatFrame:RegisterEvent("CHAT_MSG_SAY")
chatFrame:RegisterEvent("CHAT_MSG_YELL")
chatFrame:RegisterEvent("CHAT_MSG_CHANNEL")
chatFrame:RegisterEvent("CHAT_MSG_CHANNEL_NOTICE")
-- Приём по префиксу аддона (26.11.2026). Наш основной транспорт — аддон-сообщение
-- (см. PeerWireSend), но СТАРЫЙ путь в канал остаётся зарегистрированным: клиенты
-- до этой правки префикс не знают и продолжают слать обычным сообщением, и мы
-- обязаны их слышать. Обратное — не так: они нас больше не слышат, это решение
-- владельца.
if C_ChatInfo and type(C_ChatInfo.RegisterAddonMessagePrefix) == "function" then
    chatFrame:RegisterEvent("CHAT_MSG_ADDON")
end
chatFrame:SetScript("OnEvent", function(self, event, ...)
    -- all parsing under pcall: if the beta returns the name as a secret string
    -- (such were caught in combat via canaccessvalue), string operations would
    -- crash the whole chat handler — protect name collection, failures visible
    -- via DbgErr.
    -- pass varargs into the pcall lambda EXPLICITLY (ev, ...): a nested non-vararg
    -- function can't see the outer `...` — Lua 5.1 (client) raises the compile
    -- error "cannot use '...' outside a vararg function", luaparser missed that.
    local okP, errP = pcall(function(ev, ...)
        if ev == "CHAT_MSG_CHANNEL_NOTICE" then
            -- Ground truth about the channel population: JOIN/LEAVE notices name
            -- the addon users actually sitting in nearbyspydata. The event fires
            -- for EVERY channel we are in (Trade/General flood it), so only
            -- notices that mention our channel are kept. Raw arg dump is
            -- debug-mode only (stealth mode keeps the chat clean); the SV ring
            -- gets it in both modes through D().
            local okN, errN = pcall(function(...)
                local parts = {}
                for i = 1, 9 do parts[i] = PeerEsc(select(i, ...), 40) end
                local line = table.concat(parts, " | ")
                if line:lower():find(PEER_CHANNEL_BASE, 1, true) then
                    D("Channel notice: " .. line)
                    -- Сервер САМ сообщает, что канал не принимает сообщения
                    -- так часто ("THROTTLED"). Это точнее любого расчёта: на
                    -- живых метках интервал между отправками был 4-6 секунд, а
                    -- троттлинг приходил на 5 из 18 отправок. Реагируем на
                    -- сигнал, а не гадаем лимит.
                    if line:find("THROTTLED", 1, true) then
                        PeerThrottled()
                    end
                end
            end, ...)
            if not okN then DbgErr("channelNotice", errN) end
            return
        end
        -- ── Приём по префиксу аддона (26.11.2026) ────────────────────────────
        -- Раскладка события: prefix, text, chatType, sender, ...
        -- Фильтр ТОЛЬКО по префиксу: имя канала в событии не приходит (там тип
        -- рассылки — "CHANNEL"), поэтому IsPeerChannel применить нечем. Что
        -- пакет наш, решает содержимое: ReceivePeerMessage проверяет протокол,
        -- игру и мир, а на чужой префикс мы вообще не подписаны.
        if ev == "CHAT_MSG_ADDON" then
            local okA, errA = pcall(function(...)
                local prefix, text, chatType, sender = ...
                if type(prefix) ~= "string" or prefix:lower() ~= NSP_CONST.PEER_PREFIX:lower() then
                    return
                end
                if canaccessvalue and not canaccessvalue(text) then return end
                if type(text) ~= "string" or text == "" then return end
                if type(sender) ~= "string" or sender == "" then return end
                -- Только канальная рассылка: PARTY/GUILD/WHISPER тем же префиксом
                -- могут нести записи, снятые в другом месте, и принимать их за
                -- канал — значит мешать провенанс.
                if type(chatType) == "string" and chatType ~= "CHANNEL" then return end
                peerStats.addonIn = (peerStats.addonIn or 0) + 1
                ReceivePeerMessage(text, sender)
            end, ...)
            if not okA then DbgErr("peerAddon", errA) end
            return
        end
        if ev == "CHAT_MSG_CHANNEL" and
            (IsPeerChannel(select(9, ...)) or IsPeerChannel(select(4, ...))) then
            -- ⚠️ Скобки обязательны. `select(1, ...)` в СПИСКЕ АРГУМЕНТОВ
            -- разворачивается во ВСЕ значения от первого, поэтому вызов получал
            -- не два аргумента, а пять, и третий параметр (fromBatch) получал
            -- имя языка — всегда truthy. Следствие в живом SV 20.11.2026:
            -- seen=0 при valid=161, то есть счётчик «сколько сообщений
            -- получено» врал на ноль и живой канал читался как мёртвый.
            -- Скобки вокруг select берут РОВНО одно значение.
            ReceivePeerMessage((select(1, ...)), (select(2, ...)))
            return -- peer speaker is not a new encounter; no rebroadcast
        end
        local speaker = select(2, ...)
        -- ⚠️ Порядок проверок здесь не косметика: клиент может прислать
        -- говорящего СЕКРЕТНОЙ строкой (Midnight-стиль), а `speaker == ""` —
        -- это уже строковая операция, которая на такой строке бросает
        -- «attempt to compare local 'speaker' (a secret string value)».
        -- Гейт обязан стоять ПЕРВЫМ, до любого сравнения и до type() —
        -- type() секретную строку пропускает, поэтому его одного мало.
        if canaccessvalue and type(speaker) == "string" and not canaccessvalue(speaker) then return end
        if type(speaker) ~= "string" or speaker == "" then return end
        local me, surname = UnitName("player")
        if me and (speaker == me or (surname and surname ~= "" and speaker == me .. " " .. surname)
            or speaker == me .. "-" .. PlayerRealm()) then return end
        local db = GetDB()
        -- speaker: "Name" (own realm) or "Name-Realm" (cross). In vanilla a player
        -- name contains no dashes — the first "-" is always the realm separator
        local name, realm = speaker, nil
        local dash = speaker:find("-", 1, true)
        if dash then
            name = speaker:sub(1, dash - 1)
            realm = speaker:sub(dash + 1)
        end
        if name == "" then return end
        -- Пустая строка после дефиса ("Name-") не должна становиться миром:
        -- `realm or PlayerRealm()` её пропускал ("" истинна в Lua).
        if type(realm) ~= "string" or realm == "" then realm = PlayerRealm() end
        UpsertPlayer(db, {
            key = name .. "-" .. realm, -- same key format as in Record()
            name = name,
            realm = realm,
            source = "chat",
            silent = true, -- don't announce chat names in chat even with db.announce
        })
    end, event, ...)  -- varargs outward: the lambda is vararg (see comment above)
    if not okP then DbgErr("chat", errP) end
end)

-- ── Чистка старых записей (по желанию владельца) ───────────────────────────
-- ПО УМОЛЧАНИЮ ВЫКЛЮЧЕНА и ничего не удаляет, пока не включена командой.
--
-- Зачем нужна: файл растёт с каждой встречей. Замер 19.11.2026 на живом файле
-- (57 284 записи, 18.4 МБ в players): приток 1659 своих + 3271 peer в день,
-- то есть ~1.6 МБ/день. Без чистки 48-мегабайтный лимит сайта упирается
-- примерно за 19 дней.
--
-- Что здесь НЕ удаляется ни при каких настройках:
--   * мир (world: торговцы, уловы) и learn — справочники, они малы и
--     накапливаются по смыслу;
--   * журнал персонажа (journal) — своя история игры;
--   * debug — диагностика, её чистят отдельно и вручную.
--
-- Правило простое и по времени наблюдения: запись удаляется, только если её
-- последнее наблюдение старше N дней. Крон на хосте выгружает файл каждые
-- 30 минут, поэтому «старше N дней» при N >= 3 гарантированно означает
-- «давно уехало на сайт» — локальная копия там уже не единственная.
--
-- ⚠️ Обратная сторона, которую надо знать: peer-записи НЕ пересылаются
-- повторно. Если сайт потеряет данные, восстановить их из старого файла
-- нельзя — только собрать заново игрой.
function NspPrune(db, retainDays, now)
    if not db or type(db.players) ~= "table" then return 0, 0 end
    if type(retainDays) ~= "number" or retainDays <= 0 then return 0, 0 end
    now = now or time()
    local cutoff = now - retainDays * 86400
    local removed, kept = 0, 0
    local dead = {}
    for key, p in pairs(db.players) do
        if type(p) ~= "table" then
            dead[#dead + 1] = key
            removed = removed + 1
        else
            -- время последнего наблюдения: своя встреча или пакет канала
            local seen = tonumber(p.lastSeen) or 0
            local peer = tonumber(p.peerAt) or 0
            if peer > seen then seen = peer end
            local first = tonumber(p.firstSeen) or 0
            if seen <= 0 then seen = first end
            if seen > 0 and seen < cutoff then
                dead[#dead + 1] = key
                removed = removed + 1
            else
                kept = kept + 1
            end
        end
    end
    for _, key in ipairs(dead) do db.players[key] = nil end
    -- Буфер окна держит ссылки на записи: после массового удаления его надо
    -- перестроить, иначе окно показывало бы удалённых (26.11.2026).
    if removed > 0 and NspRecentInvalidate then NspRecentInvalidate() end
    -- кольцо экипировки ссылается на ключи игроков: подчищаем висячие ссылки,
    -- иначе gearRing копит ключи удалённых записей
    if type(db.gearRing) == "table" then
        local alive = {}
        for _, key in ipairs(db.gearRing) do
            if db.players[key] then alive[#alive + 1] = key end
        end
        db.gearRing = alive
    end
    db.debug = db.debug or {}
    db.debug.pruned = (db.debug.pruned or 0) + removed
    db.debug.prunedAt = now
    return removed, kept
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("NAME_PLATE_UNIT_ADDED")
frame:RegisterEvent("PLAYER_TARGET_CHANGED")
frame:RegisterEvent("PLAYER_FOCUS_CHANGED")
frame:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
frame:RegisterEvent("GROUP_ROSTER_UPDATE")
frame:RegisterEvent("GUILD_ROSTER_UPDATE")
frame:RegisterEvent("WHO_LIST_UPDATE")
frame:RegisterEvent("UI_ERROR_MESSAGE")
frame:RegisterEvent("UI_INFO_MESSAGE")
frame:RegisterEvent("CHAT_MSG_SYSTEM")
frame:RegisterEvent("HARDCORE_DEATHS")
frame:RegisterEvent("ADDON_ACTION_BLOCKED")
frame:RegisterEvent("ADDON_ACTION_FORBIDDEN")
frame:RegisterEvent("MACRO_ACTION_BLOCKED")
frame:RegisterEvent("MACRO_ACTION_FORBIDDEN")
frame:RegisterEvent("LUA_WARNING")
-- этап 0 сбора данных мира: окна торговца и улова (обработчики выходят сразу,
-- если проба не включена — регистрация ничего не стоит)
frame:RegisterEvent("MERCHANT_SHOW")
frame:RegisterEvent("LOOT_OPENED")
-- Journal (1.5.7): session boundaries, zones, level-ups, deaths
frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
frame:RegisterEvent("PLAYER_LOGOUT")
frame:RegisterEvent("PLAYER_LEVEL_UP")
frame:RegisterEvent("PLAYER_DEAD")

frame:SetScript("OnEvent", function(self, event, arg1, arg2, arg3)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then
            -- GetDB сам приводит записи к позиционной схеме (до миграции имён)
            local db = GetDB()
            -- Retention on load. Чистим сразу после загрузки базы: тогда в
            -- SavedVariables при выходе не уедет старый хвост, и следующая
            -- сессия стартует с меньшей базой. Память ТЕКУЩЕЙ сессии это почти
            -- не уменьшает (Lua не возвращает hash-часть таблицы при удалении
            -- ключей) — размер ограничивается для последующих загрузок.
            do
                local days = tonumber(db.retainDays) or 0
                if days > 0 then
                    local okP, removed = pcall(NspPrune, db, days)
                    if okP and removed and removed > 0 then
                        D(("prune: удалено старых записей при входе: %d (старше %d дн.)"):format(removed, days))
                    end
                end
            end
        end
    elseif event == "PLAYER_LOGIN" then
        local db = GetDB()
        -- Счётчики блокировок ЗА СЕССИЮ (26.11.2026). Накопительные (peerGate,
        -- blocked) живут в SavedVariables годами и на вопрос «проблема сейчас
        -- или это остаток» не отвечают: в живом файле стояло peerGate=694, из
        -- них 437 приросли на старом коде, а сессия после починки дала ровно 0 —
        -- по одному числу это было не видно. Обнуляем ровно на входе; /reload
        -- тоже пересоздаёт сессию, поэтому цифра всегда «с этого входа».
        db.debug = db.debug or {}
        db.debug.gateSession = 0
        db.debug.blockedSession = 0
        EnsureNameplates(db)
        ScheduleTick()
        -- Вкладка в меню модификаций (Settings → AddOns → NearbySpy). Регистрация
        -- здесь, а не в ADDON_LOADED: панель клиента к этому моменту уже создана,
        -- а рамки настроек ещё не нужны. Неудача не должна ломать вход — команда
        -- /nspy settings в этом случае откроет собственное окно аддона.
        local okOpt, registered = pcall(NspRegisterOptions)
        if not okOpt then DbgErr("optionsRegister", registered) end
        -- Passive inspector: same injection pattern (no UI, runs on encounters)
        if type(NSP_INSPECT) == "table" then
            NSP_INSPECT.P, NSP_INSPECT.GetDB, NSP_INSPECT.DbgErr = P, GetDB, DbgErr
            -- Хук наружу: инспект отдаёт снапшот в peer-канал (экипировка +
            -- билд), сам он про протокол и очереди ничего не знает.
            NSP_INSPECT.QueuePeerGear = PeerQueueGear
            -- counters are per session (see J.Start): /nspy gear then answers
            -- "how did it go today", not "since installation"
            local okS, errS = pcall(NSP_INSPECT.Start)
            if not okS then DbgErr("inspectStart", errS) end
        end
        -- Item name collector: separate chunk behind NSP_ITEMS (same reason as
        -- the others — the main chunk is at the Lua 5.1 locals ceiling)
        if type(NSP_ITEMS) == "table" then
            NSP_ITEMS.P, NSP_ITEMS.GetDB = P, GetDB
        end
        -- Journal (1.5.7): open (or recover) this character's session. P and L
        -- are injected because the journal chunk cannot see this file's locals.
        if NSP_JOURNAL then
            NSP_JOURNAL.P, NSP_JOURNAL.L = P, L
            local okJ, errJ = pcall(NSP_JOURNAL.Login, db, PlayerZone(), PlayerZoneId())
            if not okJ then DbgErr("journalLogin", errJ) end
        end
        if db.peerEnabled then
            local ok, err = pcall(JoinPeerChannel)
            if not ok then DbgErr("peerJoin", err) end
            -- Префикс аддон-сообщений: без регистрации приём CHAT_MSG_ADDON по
            -- нему не придёт ВООБЩЕ. Результат в SV (db.debug.prefix), иначе
            -- «тишина» не отличить от «префикс не зарегистрировался».
            local okP, errP = pcall(PeerRegisterPrefix, db)
            if not okP then DbgErr("peerPrefix", errP) end
            -- Слив очереди по таймеру (26.11.2026): аддон-сообщение не требует
            -- hardware-события, поэтому очередь больше не ждёт клика по миру.
            local okT, errT = pcall(PeerStartTimer)
            if not okT then DbgErr("peerTimer", errT) end
            pcall(PeerLogChannel, "join")
            -- channels may not be ready at PLAYER_LOGIN (GetChannelName = nil):
            -- one retry after 30s if the channel is still not up
            if C_Timer and C_Timer.After then
                C_Timer.After(30, function()
                    if not GetDB().peerEnabled then return end
                    local ch = GetChannelName(PeerChannelName())
                    if not ch or ch == 0 then
                        local okR, errR = pcall(JoinPeerChannel)
                        if not okR then DbgErr("peerJoinRetry", errR) end
                    end
                    pcall(PeerLogChannel, "join retry")
                end)
            end
        end
        do
            local ok, err = pcall(BuildMinimapButton)
            if not ok then DbgErr("minimap", err) end
        end
        D(L("STARTUP"):format(CountPlayers()))
        RequestGuildRoster()
    elseif event == "NAME_PLATE_UNIT_ADDED" then
        local db = GetDB()
        db.debug.addedEvents = (db.debug.addedEvents or 0) + 1
        local okE, errE = pcall(Record, arg1)
        if not okE then DbgErr("nameplate", errE) end
    elseif event == "PLAYER_TARGET_CHANGED" then
        local okE, errE = pcall(Record, "target")
        if not okE then DbgErr("target", errE) end
    elseif event == "PLAYER_FOCUS_CHANGED" then
        local okE, errE = pcall(Record, "focus")
        if not okE then DbgErr("focus", errE) end
    elseif event == "UPDATE_MOUSEOVER_UNIT" then
        local okE, errE = pcall(Record, "mouseover")
        if not okE then DbgErr("mouseover", errE) end
    elseif event == "GROUP_ROSTER_UPDATE" then
        local okE, errE = pcall(RecordGroup)
        if not okE then DbgErr("group", errE) end
    elseif event == "GUILD_ROSTER_UPDATE" then
        local okE, errE = pcall(RecordGuild)
        if not okE then DbgErr("guild", errE) end
    elseif event == "WHO_LIST_UPDATE" then
        local okE, errE = pcall(HandleWhoList)
        if not okE then DbgErr("who", errE) end
    elseif event == "ZONE_CHANGED_NEW_AREA" then
        if NSP_JOURNAL then
            local okJ, errJ = pcall(NSP_JOURNAL.Zone, GetDB(), PlayerZone(), PlayerZoneId())
            if not okJ then DbgErr("journalZone", errJ) end
        end
    elseif event == "PLAYER_LEVEL_UP" then
        if NSP_JOURNAL then
            local okJ, errJ = pcall(NSP_JOURNAL.LevelUp, GetDB(), arg1)
            if not okJ then DbgErr("journalLevel", errJ) end
        end
    elseif event == "PLAYER_DEAD" then
        if NSP_JOURNAL then
            local okJ, errJ = pcall(NSP_JOURNAL.Died, GetDB())
            if not okJ then DbgErr("journalDeath", errJ) end
        end
    elseif event == "PLAYER_LOGOUT" then
        -- Чистка старых записей: срок берётся из SavedVariables (умолчание —
        -- NSP_CONST.RETAIN_DAYS), 0 = чистка выключена командой /nspy retain off.
        do
            local dbL = GetDB()
            local days = tonumber(dbL.retainDays)
            if days and days > 0 then
                local okP, removed = pcall(NspPrune, dbL, days)
                if okP and removed and removed > 0 then
                    D(("prune: удалено старых записей: %d (старше %d дн.)"):format(removed, days))
                end
            end
        end
        -- SavedVariables are written right after this event, so the session is
        -- finalised here (/reload fires it too).
        if NSP_JOURNAL then
            local okJ, errJ = pcall(NSP_JOURNAL.Logout, GetDB())
            if not okJ then DbgErr("journalLogout", errJ) end
        end
    elseif event == "UI_ERROR_MESSAGE" then
        -- server throttles /who — the event signature varies: (msg) or (errorType, msg)
        local okE, errE = pcall(function()
            local sm = type(arg2) == "string" and arg2 or arg1
            LogSysMsg("err", sm)
            if not CheckWhoThrottle(arg2) then CheckWhoThrottle(arg1) end
        end)
        if not okE then DbgErr("sysmsg", errE) end
    elseif event == "UI_INFO_MESSAGE" then
        local okE, errE = pcall(function()
            local sm = type(arg2) == "string" and arg2 or arg1
            LogSysMsg("info", sm)
            if not CheckWhoThrottle(arg2) then CheckWhoThrottle(arg1) end
        end)
        if not okE then DbgErr("sysmsg", errE) end
    elseif event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN"
        or event == "MACRO_ACTION_BLOCKED" or event == "MACRO_ACTION_FORBIDDEN" then
        -- client guard gate (70291+): arg1 = addon, arg2 = function
        local addon, func = tostring(arg1), tostring(arg2)
        D(("BLOCKED[%s]: %s → %s"):format(event, addon, func))
        -- Только свои блокировки идут в blocked/blockedAt: общий счётчик смешивал
        -- нас с чужими аддонами и не отвечал ни на один вопрос (см. NspNoteBlock).
        local dbB = GetDB()
        if NspNoteBlock(dbB, addon, func, time(), event) then
            D(("client blocked our call: %s (%s)"):format(func, event))
            -- Интерфейсная ошибка «Interface action failed because of an AddOn»
            -- — это и есть попап ADDON_ACTION_BLOCKED/FORBIDDEN. Он всплывает на
            -- отправке в канал (гейт требует hardware-событие), а мы этот вызов
            -- пробуем сами и отказ уже учли в db.debug.blocked/peerGate —
            -- беспокоить игрока нечем. Гасим попап и НЕ трогаем чужие: если
            -- заблокировали другой аддон, его диалог не наше дело.
            -- pcall: в кастомном клиенте попапа может не быть вовсе.
            if StaticPopup_Hide then
                pcall(StaticPopup_Hide, "ADDON_ACTION_BLOCKED")
                pcall(StaticPopup_Hide, "ADDON_ACTION_FORBIDDEN")
                -- Близзард показывает попап по тому же событию и может сделать это
                -- ПОСЛЕ нас: повторяем хайд на следующем кадре, иначе диалог
                -- остаётся на экране и жалоба возвращается.
                if C_Timer and C_Timer.After then
                    C_Timer.After(0, function()
                        pcall(StaticPopup_Hide, "ADDON_ACTION_BLOCKED")
                        pcall(StaticPopup_Hide, "ADDON_ACTION_FORBIDDEN")
                    end)
                end
            end
        elseif addon == "UNKNOWN()" or addon == "" or addon == "nil" then
            -- ⚠️ Клиент НЕ ВСЕГДА называет виновника: в живом SV 315 блокировок
            -- пришли как `blocked["UNKNOWN()"]`, то есть arg1 = "UNKNOWN()".
            -- Такая запись не содержит имени аддона, NspNoteBlock относит её к
            -- чужим, и попап НЕ гасится — игрок видит «ошибку интерфейса»,
            -- которую мы же и вызвали. Атрибуция по времени: если наш вызов
            -- отправки был в пределах секунды, это почти наверняка мы (так же
            -- рассуждает NspNoteSendRet). Чужие блокировки без имени не трогаем,
            -- только когда рядом нет нашей отправки.
            local at = type(dbB.debug) == "table" and tonumber(dbB.debug.sendRetAt)
            if at and (time() - at) <= 1 and StaticPopup_Hide then
                D("client blocked an unnamed call right after our send — popup suppressed")
                pcall(StaticPopup_Hide, "ADDON_ACTION_BLOCKED")
                pcall(StaticPopup_Hide, "ADDON_ACTION_FORBIDDEN")
                if C_Timer and C_Timer.After then
                    C_Timer.After(0, function()
                        pcall(StaticPopup_Hide, "ADDON_ACTION_BLOCKED")
                        pcall(StaticPopup_Hide, "ADDON_ACTION_FORBIDDEN")
                    end)
                end
            end
        end
    elseif event == "LUA_WARNING" then
        D(("LUA_WARNING: %s | %s"):format(tostring(arg1), tostring(arg2)))
    elseif event == "HARDCORE_DEATHS" then
        local okE, errE = pcall(RecordHardcoreDeath, arg1)
        if not okE then DbgErr("hardcoreDeaths", errE) end
    elseif event == "MERCHANT_SHOW" then
        local okC, errC = pcall(WR.CollectVendor)
        if not okC then DbgErr("vendor", errC) end
    elseif event == "LOOT_OPENED" then
        local okC, errC = pcall(WR.CollectFishing)
        if not okC then DbgErr("fishing", errC) end
    elseif event == "CHAT_MSG_SYSTEM" then
        -- custom server messages ("Интересная операция…") arrive via system chat
        local okE, errE = pcall(function()
            LogSysMsg("sys", arg1)
            CheckWhoThrottle(arg1)
        end)
        if not okE then DbgErr("sysmsg", errE) end
    end
end)
