--[[
    NearbySpy 1.5.4
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
        ring[#ring + 1] = stamped:sub(1, 500)
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
                        for _, f in ipairs({"class", "classLoc", "race", "faction", "zone", "zoneId"}) do
                            if (ex[f] == nil or ex[f] == "") and p[f] ~= nil and p[f] ~= "" then
                                ex[f] = p[f]
                            end
                        end
                    else
                        p.key = nk
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
    samples[#samples + 1] = { at = time(), realm = GetRealmName(), message = message:sub(1, 500) }
    if #samples > 200 then table.remove(samples, 1) end
end

-- ring without chat (digests every 5 min — don't spam the player)
local function R(msg)
    local ok, db2 = pcall(GetDB)
    if ok and type(db2) == "table" and type(db2.debug) == "table" then
        local ring = db2.debug.printRing
        if type(ring) ~= "table" then ring = {}; db2.debug.printRing = ring end
        ring[#ring + 1] = ("[%s] %s"):format(date("%H:%M:%S"), tostring(msg)):sub(1, 500)
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
local function DbgErr(src, err)
    local ok, db = pcall(GetDB)
    if not ok then return end
    db.debug.err = db.debug.err or {}
    if not db.debug.err[src] then
        db.debug.err[src] = tostring(err):sub(1, 200)
        -- err survives logout in SavedVariables, so without a stamp a month-old
        -- entry reads exactly like a fresh failure (cost me a hunt on 09.11.2026:
        -- the ring said line 1471 while the deployed code had no tonumber there).
        db.debug.errAt = db.debug.errAt or {}
        db.debug.errAt[src] = time()
        D(("DEBUG error [%s]: %s"):format(src, tostring(err):sub(1, 120)))
    end
end

local function PlayerRealm()
    -- Camelot: two-word names — UnitName returns the SURNAME as the
    -- "realm", so the real realm is taken only from GetRealmName().
    return GetRealmName() or "?"
end

-- zone by player name (another unit in the beta returns mapID=0, zone name unavailable)
local function PlayerZone()
    local zone = GetZoneText()
    if not zone or zone == "" then
        zone = GetRealZoneText()
    end
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

-- ZoneIdByName — id по тексту зоны из /who. nil, если зоны нет в словаре
-- (тогда вызывающий шлёт текст, как раньше, — молча терять зону нельзя).
function ZoneIdByName(name)
    if type(name) ~= "string" or name == "" then return nil end
    ZoneMapRefresh()          -- если прошлый обход собрал огрызок — попробуем ещё
    local byName = ZoneMapInit()
    return byName[name]
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
        if ok and type(info) == "table" and type(info.name) == "string"
            and info.name ~= "" then
            if not (canaccessvalue and not canaccessvalue(info.name)) then
                return info.name
            end
        end
    end
    local _, byId = ZoneMapInit()
    return byId[n]
end

local function Round4(v)
    if type(v) ~= "number" then return nil end
    return math.floor(v * 10000 + 0.5) / 10000
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
    return txt:sub(1, 120)
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

    db.debug = db.debug or {}
    db.debug.mcGap = db.debug.mcGap or {}
    db.debug.mcGap[#db.debug.mcGap + 1] = { id = npcID, name = name or "?", at = time() }
    if #db.debug.mcGap > 50 then table.remove(db.debug.mcGap, 1) end

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
        db.players[key] = {
            name = data.name,
            realm = data.realm,
            class = data.class,
            classLoc = data.classLoc,
            level = data.level,
            faction = data.faction,
            race = data.race,
            guid = data.guid,
            -- A peer packet carries the reporter's zone and position (protocol
            -- N3). For a row we have never seen ourselves this is the only place
            -- we have, so it is stored; see the update branch below for why it
            -- never overwrites our own sighting.
            zone = (observed or data.source == "peer") and data.zone or nil,
            zoneId = (observed or data.source == "peer") and data.zoneId or nil,
            x = (observed or data.source == "peer") and Round4(data.x) or nil,
            y = (observed or data.source == "peer") and Round4(data.y) or nil,
            firstSeen = observed and nowT or 0,
            lastSeen = observed and nowT or 0,
            count = observed and 1 or 0,
            source = data.source,
            -- peerAt/peerNew: the row came in over the nearbyspydata channel.
            -- Stored in SV so the Peer filter and /nspy peer new still answer
            -- after a relog (the in-memory counters do not survive logout).
            peerAt = data.source == "peer" and nowT or nil,
            peerNew = data.source == "peer" or nil,
            -- Which realm reported the record, and whether that realm is not
            -- ours: the channel turned out to be shared cluster-wide (09.11.2026,
            -- CAMWOW EU4/EU5), so the export must be able to tell our own
            -- sightings-by-peer from another realm's.
            peerRealm = data.peerRealm or nil,
            peerForeign = data.peerForeign or nil,
            -- Which character's addon told us about this player. Provenance is
            -- the only way to answer "whose data is this row" later: peer
            -- records are never re-sent, so the sender IS the discoverer.
            peerFrom = data.peerFrom or nil,
        }
        newThisSession = newThisSession + 1
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
        if data.zone and data.source ~= "peer" then entry.zone = data.zone end
        if data.zoneId and data.source ~= "peer" then entry.zoneId = data.zoneId end
        if data.x and data.source ~= "peer" then
            entry.x = Round4(data.x)
            entry.y = Round4(data.y)
        end
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
    if data.classLoc then entry.classLoc = data.classLoc end
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
        if not entry.x and data.x then
            entry.x = Round4(data.x)
            entry.y = Round4(data.y)
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
    if observed and data.source ~= "peer" and QueuePeerNew then
        local changedLevel = data.level and prevLevel and data.level ~= prevLevel
        local changedZone = data.zone and data.zone ~= "" and data.zone ~= prevZone
        -- зона сравнивается по id, когда он известен: имя локализовано, а id —
        -- один и тот же во всех клиентских языках
        if data.zoneId and data.zoneId > 0 and prevZoneId and data.zoneId ~= prevZoneId then
            changedZone = true
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
-- Протокол отправки — N6. Он кодирует ОДНИМ СИМВОЛОМ и класс/расу/фракцию
-- (в записи), и игру (в заголовке): обе — конечные множества.
-- N5 — переходный режим: пачки с текстовыми полями, включается настройкой,
-- если в канале остались клиенты, которые кодов не понимают.
-- Приём поддерживает ВСЁ от N2 до N6, поэтому старые клиенты продолжают
-- работать в обе стороны: мы их слышим, они нас — пока мы в режиме N5.
local PEER_PROTO = "N6"

local PEER_QUEUE_MAX, PEER_TTL = 60, 120
-- Интервал между сообщениями. Обычно 10 сек (не спамим канал зря), но при
-- большой очереди — 4 сек: /who-скан выдаёт десятки записей залпом, а при
-- 10 сек уходит лишь 24/мин, и очередь переполнялась (живой лог 10.11.2026:
-- 43 записи, «queue full»). 15 сообщений в минуту для канала — не флуд.
local PEER_GAP, PEER_GAP_BUSY, PEER_BUSY_LEN = 10, 4, 20
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
-- Per-session peer counters/state. Kept in ONE table on purpose: the main chunk
-- of this file sits at the Lua 5.1 ceiling of 200 locals, so every new
-- top-level local breaks the whole addon at compile time.
local peerStats = {sent = 0, received = 0, merged = 0, dropped = 0, seen = 0, valid = 0, rejected = 0,
    foreign = 0, selfEcho = 0, inStart = 0, inCount = 0, lastSend = 0, rejectLogged = {}, lastNoChannel = 0,
    leftStale = nil}
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
        lastSender = peerStats.lastSender,
        chat = peerChatVisible and true or false,
    }
end

-- Untrusted chat text: strip control chars and pipe escapes before it reaches
-- chat or the SV ring (a peer name must not be able to inject markup).
-- Global on purpose — a local function would cost a slot in the main chunk.
function PeerEsc(s, maxLen)
    if type(s) ~= "string" then return tostring(s) end
    s = s:gsub("[%c|]", "?")
    maxLen = maxLen or 60
    if #s > maxLen then s = s:sub(1, maxLen) .. "..." end
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
function PeerEncode(kind, value)
    if type(value) ~= "string" or value == "" then return PEER_CODE_UNKNOWN, false end
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
    local race = PeerField(data.race, 32) and data.race:match("^[A-Za-z]+$") and data.race or "?"
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
    local zoneInTail = (zoneName ~= "" and zoneName ~= "?" and PeerField(zoneName, 60))
    if zoneInTail then extra[#extra + 1] = cleanText(zoneName) end

    -- Запись N6: имя;класс;уровень;раса;фракция;zoneId;x;y;время[;хвост]
    -- Хвост = текстовые значения для 'z'-слотов + имя зоны последним.
    local function BuildRec(cx, cy, withZone)
        local rec = table.concat({data.name,
            clsCode, tostring(level), raceCode, facCode,
            tostring(zoneId), cx, cy, tostring(tonumber(data.observedAt) or time())}, ";")
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
        local old = table.remove(peerQueue, 1)
        peerQueued[old.key] = nil
        peerStats.dropped = peerStats.dropped + 1
        D(("Peer queue full: dropped %s"):format(PeerEsc(old.name or "?")))
    end
    peerQueue[#peerQueue + 1] = {
        key = key, rec = rec, name = data.name, at = time(),
        game = db.game, realm = data.realm,
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

local function DrainPeerQueue()
    local db = GetDB()
    if not db.peerEnabled or #peerQueue == 0 then return end
    local nowT = time()
    -- Адаптивный интервал: при большой очереди отправляем чаще, иначе канал
    -- захлёбывается после /who-скана.
    local gap = (#peerQueue >= PEER_BUSY_LEN) and PEER_GAP_BUSY or PEER_GAP
    if nowT - peerStats.lastSend < gap then return end
    while #peerQueue > 0 and nowT - peerQueue[1].at > PEER_TTL do
        local old = table.remove(peerQueue, 1)
        peerQueued[old.key] = nil
        peerStats.dropped = peerStats.dropped + 1
        D(("Peer expired before send: %s"):format(PeerEsc(old.name or "?")))
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
    -- The beta may require a hardware input event for sending channel chat.
    local send = C_ChatInfo and C_ChatInfo.SendChatMessage or SendChatMessage
    if not send then return end

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
    if headGame == PEER_CODE_UNKNOWN then headGame = head.game end
    -- Заголовок "N6;game;realm;" входит в лимит сообщения, поэтому считается
    -- сразу: без него пачка вылезала за PEER_PAYLOAD_MAX (живой прогон теста:
    -- 252 байта при лимите 240).
    local headerLen = #PEER_PROTO + 1 + #headGame + 1 + #head.realm + 1
    local batch, batchLen = { head }, headerLen + #head.rec
    local i = 2
    while i <= #peerQueue and #batch < PEER_BATCH_MAX do
        local it = peerQueue[i]
        if it.game ~= head.game or it.realm ~= head.realm then break end
        local add = 1 + #it.rec           -- разделитель + сама запись
        if batchLen + add > PEER_PAYLOAD_MAX then break end
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
        payload = PEER_PROTO .. ";" .. gameForWire .. ";" .. head.realm .. ";" .. recFor(head)
    else
        local parts = {}
        for k = 1, #batch do parts[k] = recFor(batch[k]) end
        payload = PEER_PROTO .. ";" .. gameForWire .. ";" .. head.realm .. ";" .. table.concat(parts, PEER_BATCH_SEP)
    end

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

    local ok, result = pcall(send, payload, "CHANNEL", nil, channel)
    if not ok or result == false then
        db.debug.peerSendError = tostring(result):sub(1, 150)
        D(("Peer send error: %s"):format(PeerEsc(db.debug.peerSendError, 120)))
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

    -- Признак пачки — разделитель PEER_BATCH_SEP (запятая). Он ЗАПРЕЩЁН в
    -- имени, зоне, мире и хвостовом тексте (PeerField), поэтому в одиночном
    -- пакете его быть не может. Без этой проверки одиночный N5 неотличим от
    -- пачки (у обоих 13 полей), и строка уходила в batch-ветку заново —
    -- рекурсия до лимита частоты.
    --
    -- Раньше признаком был '|', но с ним сервер отклонял сообщение целиком
    -- («Invalid escape code in chat message»), поэтому разделитель заменён.
    if (fields[1] == "N6" or fields[1] == "N5")
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
    -- Приём держит ВСЕ версии: старый клиент в канале не должен замолчать.
    if #fields ~= 8 and #fields ~= 12 and #fields ~= 13 and #fields ~= 14 then
        return Reject("field count")
    end
    local proto = fields[1]
    if proto ~= "N2" and proto ~= "N3" and proto ~= "N4"
        and proto ~= "N5" and proto ~= "N6" then
        return Reject("unknown protocol " .. PeerEsc(proto, 8))
    end
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
    if fields[3] ~= PlayerRealm() then
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
    local realm, name, class = fields[3], fields[4], fields[5]
    local race, faction
    local tail = {}          -- хвост записи N6: 'z'-значения + имя зоны последним
    local tailZone           -- имя зоны из хвоста (расширение к zoneId)
    if proto == "N6" then
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
    if proto ~= "N6" then
        if not PeerField(name, 60) or not PeerField(realm, 100)
            or not class:match("^[A-Z]+$") or #class > 32 then return Reject("bad name/class") end
        race = fields[7]
        faction = fields[8]
    end
    local level = tonumber(fields[6])
    if not level or level < 1 or level > 80 or level % 1 ~= 0 then return Reject("bad level") end
    if type(race) ~= "string" then race = "?" end
    if race ~= "?" and (not race:match("^[A-Za-z]+$") or #race > 32) then return Reject("bad race") end
    if faction ~= "?" and faction ~= "Alliance" and faction ~= "Horde" then return Reject("bad faction") end

    -- Place. zoneId — ОСНОВНОЙ ключ зоны во всех версиях, имя — расширение.
    --   N2: нет места вообще
    --   N3/N4/N5: zoneId;зона;x;y[;время] — имя полем
    --   N6:       zoneId;x;y;время[;хвост] — имя только в хвосте (расширение)
    local zoneId, zoneName, px, py, observedAt
    if proto == "N6" then
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
        observedAt = tonumber(fields[12])
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
            observedAt = tonumber(fields[13])
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
    D(("Peer in: %s %s %d (%s) %s%s"):format(
        PeerEsc(name), PeerEsc(class, 20), level, PeerEsc(faction, 10),
        isNew and "new" or "merged",
        foreign and (" [realm=" .. PeerEsc(realm, 40) .. "]") or ""))
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
}

-- LearnedFactions — НАБОР фракций, в которых наблюдалась раса.
--
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
    local locTable = RACE_BY_LOCALE[loc]
    if locTable then
        for raceFile, locName in pairs(locTable) do
            if want(raceFile) then
                local canon = (whoName and whoName[raceFile]) or locName
                names[canon] = true
                canonical[raceFile] = true
            end
        end
    end
    -- расы вне эталона (кастомные), для которых сервер уже вернул написание
    if whoName then
        for raceFile, locName in pairs(whoName) do
            if not canonical[raceFile] and want(raceFile) and NameFitsLocale(locName, loc) then
                names[locName] = true
                canonical[raceFile] = true
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
        db.debug.lastErrorMsg = msg:sub(1, 120)
        db.whoPauseUntil = time() + 300
        if whoScan then FinishZoneScan("stopped: server throttles /who") end
        P(L("WHO_THROTTLED"))
        return true
    end
    if msg:find("[Пп]одожд") then
        -- soft command cooldown (a couple of seconds) — note it, don't stop the scan
        db.debug.whoSoft = (db.debug.whoSoft or 0) + 1
        db.debug.lastErrorMsg = msg:sub(1, 120)
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
    if type(msg) ~= "string" or msg == "" then return end
    if canaccessvalue and not canaccessvalue(msg) then return end
    local db = GetDB()
    db.debug.msgLog = db.debug.msgLog or {}
    local log = db.debug.msgLog
    log[#log + 1] = chan .. "|" .. msg:sub(1, 220)
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
    if learn and learn.whoName and learn.whoName[raceFile] then
        return learn.whoName[raceFile]
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

-- SCAN.SpeedRaces — ступень 3: расы для одного среза класса и полосы уровней.
-- Раса-фильтр тот же, что у whorace: фракция + локаль клиента.
function SCAN.SpeedRaces(db, q)
    -- расы, разрешённые фракцией и локалью
    local allowed = RaceFilterNames(db, PlayerFaction())
    -- и только те, что реально встречались с ЭТИМ классом
    local observed = SCAN.ClassRaces(db, q.cls)
    local obsCount = SCAN.RaceObs(db)
    local names = {}
    for locName in pairs(allowed) do
        -- Раса попадает в срез, если пара «класс × раса» уже наблюдалась ИЛИ
        -- выборка по расе слишком мала, чтобы судить (тогда лишний запрос
        -- дешевле пропущенной расы).
        if next(observed) == nil or observed[locName]
            or (obsCount[locName] or 0) < SCAN.RACE_MIN_OBS then
            names[#names + 1] = locName
        end
    end
    table.sort(names)
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
                -- filter that is known to work everywhere)
                local sub = 0
                for _, locName in pairs(LOCALIZED_CLASS_NAMES_MALE or {}) do
                    table.insert(whoQueue, 1, { base = WHO_TOKEN_CLASS .. "\"" .. locName .. "\"",
                        lo = q.lo, hi = q.hi, parentSet = names })
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
                    -- still covers the levels most players actually occupy
                    table.insert(whoQueue, 1, { base = q.base, lo = mid + 1, hi = q.hi, parentSet = names })
                    table.insert(whoQueue, 1, { base = q.base, lo = q.lo, hi = mid, parentSet = names })
                    whoScan.splits = (whoScan.splits or 0) + 1
                    D(("/who: %d (cap) — %s %d-%d → %d-%d + %d-%d")
                        :format(num, q.base or "?", q.lo, q.hi, q.lo, mid, mid + 1, q.hi))
                end
            elseif not q.race and q.base then
                -- class + single level still overflows: split by RACE. Only a
                -- handful of pairs are that dense (measured max 78 players for
                -- one class on one level), so this tier costs ~10 extra queries
                -- and closes the last gap in coverage.
                local races = RaceFilterNames(db, PlayerFaction())
                local sub = 0
                for locName in pairs(races) do
                    table.insert(whoQueue, 1, { base = q.base, race = locName,
                        lo = q.lo, hi = q.hi, parentSet = names })
                    sub = sub + 1
                end
                whoScan.raceSplits = (whoScan.raceSplits or 0) + 1
                D(("/who: %d (cap) — %s level %d → %d race slices")
                    :format(num, q.base, q.lo, sub))
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

local function SortedPlayers(db)
    local list = {}
    for _, p in pairs(db.players) do
        list[#list + 1] = p
    end
    table.sort(list, function(a, b)
        return (a.lastSeen or 0) > (b.lastSeen or 0)
    end)
    return list
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
        -- Which object was actually used is invisible from outside, and the client
        -- is not guaranteed to ship every variant: record it once per size so the
        -- choice can be verified from SavedVariables instead of guessed.
        local okDb, db = pcall(GetDB)
        if okDb and type(db) == "table" then
            db.debug = db.debug or {}
            local fonts = db.debug.fonts
            if type(fonts) ~= "table" then fonts = {}; db.debug.fonts = fonts end
            local key = tostring(size)
            if fonts[key] == nil then
                fonts[key] = (obj == _G.GameFontNormalSmall and "small")
                    or (obj == _G.GameFontNormalLarge and "large") or "normal"
            end
        end
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
    "/nspy who", "/nspy whostop",
    "/nspy count", "/nspy announce", "/nspy debug",
    "/nspy peer on", "/nspy peer off", "/nspy peer", "/nspy peer new", "/nspy peer list",
    "/nspy peer send", "/nspy zones", "/nspy reset",
    "/nspy server", "/nspy menu", "/nspy minimap", "/nspy settings",
}

local HELP_TEXT = {
    enUS = {"Player window", "This command list", "Assisted /who: you click search; repeat to stop", "Assisted wide /who: you click search", "Stop a /who scan", "Counters and diagnostics", "Toggle new-encounter chat messages", "Toggle technical chat logs", "Join the optional player-sharing channel", "Leave the channel and clear pending sends", "Sharing status and counters", "What the channel delivered - new to us only", "Everything the channel delivered (updates included)", "Force-send the pending queue (no world click needed)", "Zone dictionary: rebuild and report (no /who needed)", "Clear the player database", "Server census window (needs NearbySpy_Data)", "Menu window (hub)", "Show/hide the minimap button", "Settings window (peer sharing)"},
    zhCN = {"玩家窗口", "命令列表", "辅助 /who：点击搜索；再次输入可停止", "辅助广域 /who：点击搜索", "停止 /who 扫描", "计数与诊断", "切换新遇见玩家的聊天提示", "切换技术日志", "加入可选的玩家共享频道", "退出频道并清空待发队列", "共享状态与计数", "频道带来的新记录（仅新增）", "频道收到的全部记录（含更新）", "强制发送待发队列（无需点击世界）", "区域字典：重建并报告（无需 /who）", "清空玩家数据库", "服务器普查窗口(需要 NearbySpy_Data)", "菜单窗口 (hub)", "显示/隐藏小地图按钮", "设置窗口 (共享开关)"},
    ruRU = {"Окно игроков", "Список команд", "Помощник /who: нажимай лупу; повтор — стоп", "Широкий /who: жми лупу", "Остановить скан /who", "Счётчики и диагностика", "Вкл/выкл сообщения о новых встречах", "Вкл/выкл технические логи в чате", "Вступить в канал обмена игроками", "Покинуть канал и очистить очередь", "Состояние и счётчики обмена", "Что пришло из канала — только новые для нас", "Всё, что пришло из канала (включая обновления)", "Отправить очередь принудительно (без клика по миру)", "Словарь зон: пересобрать и показать (без /who)", "Очистить базу игроков", "Окно ценза сервера (нужен NearbySpy_Data)", "Окно меню (hub)", "Показать/скрыть кнопку миникарты", "Окно настроек (обмен)"},
    deDE = {"Spielerfenster", "Befehlsübersicht", "Assistiertes /who: Suche anklicken; erneut = Stopp", "Breites /who: Suche anklicken", "/who-Scan stoppen", "Zähler und Diagnose", "Meldungen über neue Begegnungen umschalten", "Technische Chat-Logs umschalten", "Optionalem Austauschkanal beitreten", "Kanal verlassen und Warteschlange leeren", "Austauschstatus und Zähler", "Was der Kanal geliefert hat - nur neue für uns", "Alles vom Kanal (auch Aktualisierungen)", "Warteschlange sofort senden (ohne Klick in die Welt)", "Zonen-Wörterbuch: neu aufbauen und melden (ohne /who)", "Spielerdatenbank leeren", "Server-Zensusfenster (benötigt NearbySpy_Data)", "Menüfenster (Hub)", "Minimap-Button ein-/ausblenden", "Einstellungsfenster (Peer-Austausch)"},
    frFR = {"Fenêtre des joueurs", "Liste des commandes", "/who assisté : cliquer sur recherche ; répéter pour arrêter", "/who large assisté : cliquer recherche", "Arrêter le scan /who", "Compteurs et diagnostic", "Activer/désactiver les annonces de rencontres", "Activer/désactiver les journaux techniques", "Rejoindre le canal de partage facultatif", "Quitter le canal et vider la file", "État et compteurs du partage", "Ce que le canal a livré - nouveaux uniquement", "Tout ce que le canal a livré (mises à jour incluses)", "Forcer l'envoi de la file (sans clic dans le monde)", "Dictionnaire des zones : reconstruire et rapporter (sans /who)", "Effacer la base des joueurs", "Fenêtre de recensement (nécessite NearbySpy_Data)", "Fenêtre de menu (hub)", "Afficher/masquer le bouton de la minicarte", "Fenêtre des réglages (partage peer)"},
    koKR = {"플레이어 창", "명령어 목록", "보조 /who: 검색 클릭, 다시 입력하면 중지", "보조 전체 /who: 검색 클릭", "/who 스캔 중지", "통계 및 진단", "새 만남 채팅 알림 전환", "기술 로그 채팅 출력 전환", "선택적 플레이어 공유 채널 참가", "채널 나가기 및 전송 대기열 비우기", "공유 상태 및 통계", "채널에서 받은 신규 기록만", "채널에서 받은 전체 기록 (갱신 포함)", "대기열 강제 전송 (월드 클릭 없이)", "지역 사전: 재구성 및 보고 (/who 불필요)", "플레이어 데이터베이스 삭제", "서버 센서스 창 (NearbySpy_Data 필요)", "메뉴 창 (허브)", "미니맵 버튼 표시/숨기기", "설정 창 (피어 공유)"},
}
local helpWin
local EffectiveLocale -- forward: defined with the settings selectors below
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
                helpWin:SetPropagateKeyboardInput(false)
                helpWin:Hide()
            else
                helpWin:SetPropagateKeyboardInput(true)
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
        local descRows = {}
        helpWin.__descRows = descRows
        for i, command in ipairs(HELP_COMMANDS) do
            local y = -49 - (i - 1) * 25
            local cmd = NewText(helpWin, 12, 0.5, 1, 0.6)
            cmd:SetPoint("TOPLEFT", 16, y)
            cmd:SetWidth(155)
            cmd:SetJustifyH("LEFT")
            cmd:SetText(command)
            local desc = NewText(helpWin, 12, 0.9, 0.9, 0.9)
            desc:SetPoint("TOPLEFT", 178, y)
            desc:SetWidth(475)
            desc:SetJustifyH("LEFT")
            descRows[i] = desc
        end
    end
    -- the settings language override may have changed since the window was
    -- built — relabel on every show (EffectiveLocale: override > client > enUS)
    local descriptions = HELP_TEXT[EffectiveLocale()] or HELP_TEXT.enUS
    for i, desc in ipairs(helpWin.__descRows) do
        desc:SetText(descriptions[i])
    end
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
local tactical = {rows = {}, bars = {}, classes = {}, filters = {}, filter = "all", started = time(),
    realmFilter = nil}   -- nil = все миры; иначе точное имя реалма
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
    if #tag > 24 then tag = tag:sub(1, 24) .. "..." end
    return tag
end

-- Badge under the player name for EVERY row, not only for foreign ones. Our own
-- realm shrinks to its ruleset ("PvE" / "PvP"), because repeating a long realm
-- name under every line of a 12k-row list is noise; a foreign realm keeps the
-- part that identifies it. Global: the main chunk is at the 200-local ceiling.
function RealmBadge(realm)
    if type(realm) ~= "string" or realm == "" then return nil end
    if realm == PlayerRealm() then
        -- last token of "CAMWOW EU5 Realm 1 PvE" — the ruleset
        local rules = realm:match("(%S+)$")
        return rules or realm
    end
    return PeerRealmTag(realm)
end

local function TacticalVisible(p, now)
    -- Foreign peer rows are hidden as soon as the "all realms" flag is off:
    -- they were accepted while it was on, and a list that keeps showing them
    -- would contradict the setting the user just changed. Nothing is deleted —
    -- turning the flag back on brings them back.
    if p.peerForeign and GetDB().peerAllRealms == false then return false end
    -- Realm filter: the database now holds players from other realms of the
    -- cluster (they arrive over the peer channel), so "show me only EU4 Realm 6"
    -- has to be answerable. An empty selection means all realms.
    if tactical.realmFilter and (p.realm or "") ~= tactical.realmFilter then return false end
    -- Класс: nil = все. Псевдокласс "?" — записи без класса (их видно в
    -- панели «КЛАССЫ» как отдельная строка, молча прятать их нельзя).
    if tactical.classFilter then
        local file = p.class
        if type(file) == "string" and file ~= "" then file = string.upper(file) else file = "?" end
        if file ~= tactical.classFilter then return false end
    end
    -- Уровень: диапазон (levelFilter) и точное значение (levelExact) —
    -- взаимоисключающие, точный сбрасывает диапазон.
    if tactical.levelFilter then
        local lvl = tonumber(p.level)
        if not lvl or lvl < tactical.levelFilter[1] or lvl > tactical.levelFilter[2] then
            return false
        end
    elseif tactical.levelExact then
        local lvl = tonumber(p.level)
        if not lvl or lvl ~= tactical.levelExact then return false end
    end
    if tactical.filter == "fresh" then
        return now - (p.lastSeen or 0) <= TACTICAL_FRESH
    elseif tactical.filter == "new" then
        -- Only OUR OWN finds. A peer record gets firstSeen at the moment the
        -- packet arrives, so it satisfied the time check and filled "New" with
        -- players somebody else met (215 of them in the live save). "New" answers
        -- "whom did I discover this session", so peer rows are excluded; they have
        -- their own filter.
        return (p.firstSeen or 0) >= tactical.started and p.source ~= "peer"
    elseif tactical.filter == "peer" then
        -- Rows that arrived over the nearspydata channel. peerAt is written
        -- on receipt (new row) or on refresh of a known one, so this is the
        -- only list that shows what the channel actually delivered.
        return (p.peerAt or 0) > 0
    elseif tactical.filter == "peern" then
        -- Только то, чему канал научил ЗА ЭТУ СЕССИЮ. peerNew/peerAt лежат в
        -- SavedVariables и живут после релога, поэтому без проверки на
        -- tactical.started вкладка показывала все записи канала за всё время
        -- (на живом файле — 1451 строка за 19 часов). Это ровно та же ошибка,
        -- что была у фильтра "new", и лечится так же.
        return (p.peerAt or 0) >= tactical.started and p.peerNew == true
    end
    return true
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
        GameTooltip:AddLine(L("UI_ZONE") .. ": " .. tostring(p.zone or "?"), 0.65, 0.72, 0.72)
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

local function TacticalRows()
    for _, row in ipairs(tactical.rows) do row:Hide() end
    local now, shown = time(), 0
    local list = SortedPlayers(GetDB())
    if tactical.filter == "peer" then
        -- The peer list is ordered by arrival of the packet, not by our own
        -- sighting: for a player someone else met, lastSeen may be long stale.
        table.sort(list, function(a, b) return (a.peerAt or 0) > (b.peerAt or 0) end)
    end
    for _, p in ipairs(list) do
        if TacticalVisible(p, now) then
            -- check the limit BEFORE counting: incrementing first returned 501
            -- and sized the scroll list for 501 rows while only 500 were drawn
            if shown >= NSP_CONST.MAX_ROWS then break end
            shown = shown + 1
            local row = tactical.rows[shown] or TacticalRow(winList, shown)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 0, -(shown - 1) * TACTICAL_ROW_H)
            row.player = p
            TacticalClassIcon(row.icon, p.class)
            -- The realm goes UNDER the name in a smaller font — for our own
            -- records too, so one list never mixes labelled and unlabelled rows.
            -- Never into the ZONE column: that column is for locations.
            local realmTag = RealmBadge(p.realm)
            row.name:SetText(p.name or "?")
            row.name:SetTextColor(ClassColorRGB(p.class))
            if realmTag then
                row.realm:SetText(realmTag)
                row.realm:Show()
            else
                row.realm:SetText("")
                row.realm:Hide()
            end
            row.profile:SetText(("%s; %s%s"):format(
                ClassDisplayName(p.class, p.classLoc),
                L("LVL_PREFIX"), tostring(p.level or "?")))
            -- Peer records carry no position or zone at all (the packet has
            -- neither), so a peer row honestly has no zone.
            row.zone:SetText(p.zone or "?")
            -- In the peer list the CONTACT column answers "when did this arrive
            -- over the channel", which is the only timestamp a peer row has.
            -- Everywhere else our own sighting wins; a peer row has none
            -- (lastSeen = 0 since 1.5.3), so it falls back to the packet time
            -- instead of showing "?" for a contact we do know.
            local stamp = (p.lastSeen or 0) > 0 and p.lastSeen or p.peerAt
            if tactical.filter == "peer" and (p.peerAt or 0) > 0 then stamp = p.peerAt end
            local age = now - (stamp or 0)
            row.seen:SetText(TimeAgo(stamp))
            if age <= 300 then row.seen:SetTextColor(0.3, 0.9, 0.62)
            elseif age <= 3600 then row.seen:SetTextColor(0.88, 0.72, 0.32)
            else row.seen:SetTextColor(0.45, 0.5, 0.5) end
            row:Show()
        end
    end
    winList:SetHeight(math.max(1, shown * TACTICAL_ROW_H))
    return shown
end

local function TacticalStats()
    local st = {total = 0, f5 = 0, f15 = 0, f60 = 0, newN = 0, peerN = 0, peerNewN = 0, alliance = 0, horde = 0, unknown = 0, levelN = 0, levelSum = 0, level = {}, classes = {}}
    local now = time()
    local realmSel = tactical.realmFilter
    for _, p in pairs(GetDB().players) do
        -- counters follow the same realm selection as the list: a "Peer 12" badge
        -- over a list of 3 realm rows would be a lie
        if realmSel and (p.realm or "") ~= realmSel then
            -- skip: counted nowhere
        else
        st.total = st.total + 1
        local age = now - (p.lastSeen or 0)
        if age <= 300 then st.f5 = st.f5 + 1 end
        if age <= 900 then st.f15 = st.f15 + 1 end
        if age <= 3600 then st.f60 = st.f60 + 1 end
        if (p.firstSeen or 0) >= tactical.started and p.source ~= "peer" then
            st.newN = st.newN + 1
        end
        if (p.peerAt or 0) > 0 and not (p.peerForeign and GetDB().peerAllRealms == false) then
            st.peerN = st.peerN + 1
            -- Счётчик на вкладке "Peer new" — про текущую сессию, как и сам
            -- фильтр (см. TacticalVisible). Иначе бейдж показывал бы число
            -- записей за всё время, а список под ним — только сегодняшние.
            if p.peerNew and (p.peerAt or 0) >= tactical.started then
                st.peerNewN = st.peerNewN + 1
            end
        end
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
    end
    st.top = {}
    for _, item in pairs(st.classes) do st.top[#st.top + 1] = item end
    table.sort(st.top, function(a, b) return a.count > b.count end)
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

-- Compact realm name for the cycler button: "CAMWOW EU4 Realm 6 PvP" -> "EU4
-- Realm 6 PvP". Only the leading cluster prefix is dropped — the rest is what
-- tells the realms apart, so nothing is invented.
-- Global on purpose: the main chunk is at the Lua 5.1 ceiling of 200 locals.
function RealmShortName(realm)
    if type(realm) ~= "string" or realm == "" then return "?" end
    local t = {}
    for w in realm:gmatch("%S+") do t[#t + 1] = w end
    -- the first token is the project prefix when there are at least three
    local from = (#t >= 3) and 2 or 1
    return table.concat(t, " ", from)
end

-- Realms actually present in the database, our own first. The list is rebuilt on
-- every click so a newly arrived realm shows up without /reload.
function TacticalRealmList()
    local mine = PlayerRealm()
    local seen, list = {}, {}
    for _, p in pairs(GetDB().players) do
        local r = p.realm
        if type(r) == "string" and r ~= "" and not seen[r] then
            seen[r] = true
            list[#list + 1] = r
        end
    end
    table.sort(list, function(a, b)
        if a == mine then return true end
        if b == mine then return false end
        return a < b
    end)
    return list
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

-- Realm cycler: one button that walks "all realms -> realm A -> realm B -> ... ->
-- all". A dropdown would be the conventional control, but the list is 6 entries
-- and the toolbar has no room for one; cycling needs no menu code on a client
-- where dropdown templates are already cut down (see the settings selectors).
-- Global, not local: the main chunk is at the Lua 5.1 ceiling of 200 locals.
function TacticalRealmCycler(parent, x, y, width)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(width, 25)
    -- TOPLEFT with an explicit y: the toolbar positions itself with "LEFT" inside a
    -- 31px strip, but this button hangs off the window itself, where "LEFT" means
    -- the vertical centre of the whole (800px) window.
    button:SetPoint("TOPLEFT", x, y)
    button.bg = button:CreateTexture(nil, "BACKGROUND")
    button.bg:SetAllPoints()
    button.label = NewText(button, 10)
    button.label:SetPoint("CENTER")
    button.label:SetWidth(width - 8)
    button:SetScript("OnClick", function()
        local list = TacticalRealmList()
        if #list == 0 then
            tactical.realmFilter = nil
        else
            -- position of the current selection in the fresh list; 0 means "not
            -- found" (nothing selected = all realms), so the next step lands on
            -- the first realm. Starting at -1 made nxt = 0 and the click did
            -- nothing — caught by test_click_walks_realms_and_wraps_back.
            local cur = 0
            for i = 1, #list do
                if list[i] == tactical.realmFilter then cur = i break end
            end
            local nxt = cur + 1
            tactical.realmFilter = (nxt > #list) and nil or list[nxt]
        end
        TacticalUpdate()
    end)
    button:SetScript("OnEnter", function(self) self.bg:SetColorTexture(0.18, 0.13, 0.06, 1) end)
    button:SetScript("OnLeave", function(self) TacticalRealmCyclerState(self) end)
    tactical.realmButton = button
    TacticalRealmCyclerState(button)
    return button
end

function TacticalRealmCyclerState(button)
    button = button or tactical.realmButton
    if not button or not button.label then return end
    local active = tactical.realmFilter ~= nil
    button.bg:SetColorTexture(active and 0.3 or 0.1, active and 0.22 or 0.08, active and 0.08 or 0.05, 1)
    button.label:SetTextColor(active and 1 or 0.62, active and 0.85 or 0.55, active and 0.45 or 0.42)
    local name = active and RealmShortName(tactical.realmFilter) or L("UI_ALL")
    button.label:SetText(L("UI_REALM") .. ": " .. name)
end

--- ============ Выборка по классу и уровню ============
-- Три селектора в одну строку под тулбаром: мир (TacticalRealmCycler, выше),
-- класс и уровень. Все три — циклеры по списку: список короткий, а меню на
-- этом клиенте пришлось бы поднимать руками (см. комментарий к циклеру миров).
--
-- Состояние лежит в tactical (classFilter / levelFilter), а не в отдельных
-- local-переменных: главный чанк стоит у потолка Lua 5.1 в 200 top-level
-- locals, и каждый новый local — это шаг к «main function has more than 200
-- local variables».

-- Список классов, реально встречающихся в базе: строки файлов классов в
-- верхнем регистре плюс псевдокласс "?" для записей без класса (238 в живом
-- файле). Список строится из данных, а не зашит: класс, которого в базе ещё
-- не было, не должен занимать место в циклере.
function TacticalClassList()
    local seen, list = {}, {}
    for _, p in pairs(GetDB().players) do
        local file = p.class
        if type(file) == "string" and file ~= "" then
            file = string.upper(file)
            if not seen[file] then
                seen[file] = true
                list[#list + 1] = file
            end
        end
    end
    if not seen["?"] then
        -- записи без класса — честная отдельная группа, а не «невидимые»
        list[#list + 1] = "?"
    end
    -- Порядок: частые сверху (как в панели «КЛАССЫ»), редкие вниз.
    local counts = {}
    for _, p in pairs(GetDB().players) do
        local file = p.class
        if type(file) == "string" and file ~= "" then
            file = string.upper(file)
            counts[file] = (counts[file] or 0) + 1
        end
    end
    table.sort(list, function(a, b)
        local ca, cb = counts[a] or 0, counts[b] or 0
        if ca ~= cb then return ca > cb end
        return a < b
    end)
    return list
end

-- Диапазоны уровня: широкие шаги для быстрого ответа «кто на капе» плюс
-- «ровно N» для точного уровня (его ставит клик по столбцу гистограммы).
TacticalLevelRanges = {
    {1, 10}, {11, 20}, {21, 30}, {31, 40}, {41, 50}, {51, 60},
}

-- Подпись диапазона уровня: "1-10" или "56".
function TacticalLevelLabel(range)
    if type(range) == "number" then return tostring(range) end
    if range[1] == range[2] then return tostring(range[1]) end
    return tostring(range[1]) .. "-" .. tostring(range[2])
end

-- Циклер уровня: nil → 1-10 → 11-20 → ... → 51-60 → nil. Точное значение
-- («ровно N») в этот цикл не входит: его ставит клик по столбцу гистограммы
-- (TacticalLevelExact), который виден на глаз, а не выбирается из списка.
function TacticalLevelCycler(parent, x, y, width)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(width, 25)
    button:SetPoint("TOPLEFT", x, y)
    button.bg = button:CreateTexture(nil, "BACKGROUND")
    button.bg:SetAllPoints()
    button.label = NewText(button, 10)
    button.label:SetPoint("CENTER")
    button.label:SetWidth(width - 8)
    button:SetScript("OnClick", function()
        local ranges = TacticalLevelRanges
        local cur = 0
        for i = 1, #ranges do
            local r = ranges[i]
            if tactical.levelFilter and tactical.levelFilter[1] == r[1]
                and tactical.levelFilter[2] == r[2] then cur = i break end
        end
        local nxt = cur + 1
        if nxt > #ranges then
            tactical.levelFilter = nil
        else
            local r = ranges[nxt]
            tactical.levelFilter = { r[1], r[2] }
        end
        TacticalUpdate()
    end)
    button:SetScript("OnEnter", function(self) self.bg:SetColorTexture(0.18, 0.13, 0.06, 1) end)
    button:SetScript("OnLeave", function(self) TacticalLevelCyclerState(self) end)
    tactical.levelButton = button
    TacticalLevelCyclerState(button)
    return button
end

function TacticalLevelCyclerState(button)
    button = button or tactical.levelButton
    if not button or not button.label then return end
    local active = tactical.levelFilter ~= nil
    button.bg:SetColorTexture(active and 0.3 or 0.1, active and 0.22 or 0.08, active and 0.08 or 0.05, 1)
    button.label:SetTextColor(active and 1 or 0.62, active and 0.85 or 0.55, active and 0.45 or 0.42)
    local name = active and TacticalLevelLabel(tactical.levelFilter) or L("UI_ALL")
    button.label:SetText(L("UI_LEVEL") .. ": " .. name)
end

-- Циклер класса: nil → самый частый класс → ... → nil.
function TacticalClassCycler(parent, x, y, width)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(width, 25)
    button:SetPoint("TOPLEFT", x, y)
    button.bg = button:CreateTexture(nil, "BACKGROUND")
    button.bg:SetAllPoints()
    button.label = NewText(button, 10)
    button.label:SetPoint("CENTER")
    button.label:SetWidth(width - 8)
    button:SetScript("OnClick", function()
        local list = TacticalClassList()
        if #list == 0 then
            tactical.classFilter = nil
        else
            local cur = 0
            for i = 1, #list do
                if list[i] == tactical.classFilter then cur = i break end
            end
            local nxt = cur + 1
            tactical.classFilter = (nxt > #list) and nil or list[nxt]
        end
        TacticalUpdate()
    end)
    button:SetScript("OnEnter", function(self) self.bg:SetColorTexture(0.18, 0.13, 0.06, 1) end)
    button:SetScript("OnLeave", function(self) TacticalClassCyclerState(self) end)
    tactical.classButton = button
    TacticalClassCyclerState(button)
    return button
end

function TacticalClassCyclerState(button)
    button = button or tactical.classButton
    if not button or not button.label then return end
    local active = tactical.classFilter ~= nil
    button.bg:SetColorTexture(active and 0.3 or 0.1, active and 0.22 or 0.08, active and 0.08 or 0.05, 1)
    button.label:SetTextColor(active and 1 or 0.62, active and 0.85 or 0.55, active and 0.45 or 0.42)
    local name = L("UI_ALL")
    if active then
        if tactical.classFilter == "?" then
            name = L("UI_NO_CLASS")
        else
            name = ClassDisplayName(tactical.classFilter)
        end
    end
    button.label:SetText(L("UI_CLASS") .. ": " .. name)
end

-- Точный уровень: клик по столбцу гистограммы. Повторный клик по тому же
-- столбцу снимает фильтр («ровно N» → «все»).
function TacticalLevelExact(level)
    if tactical.levelExact == level then
        tactical.levelExact = nil
    else
        tactical.levelExact = level
    end
    -- точный уровень и диапазон взаимоисключающи: показан ровно один
    if tactical.levelExact then tactical.levelFilter = nil end
    TacticalUpdate()
end

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
        tactical.total.value:SetText(tostring(st.total))
        tactical.total.detail:SetText("+" .. tostring(st.newN) .. " " .. L("UI_NEW_SHORT"))
        tactical.fresh.value:SetText(tostring(st.f5))
        tactical.fresh.detail:SetText(("15m %d; 1h %d"):format(st.f15, st.f60))
        tactical.factions.value:SetText(("|cffff6666%s %d|r ; |cff6699ff%s %d|r"):format(L("HORDE"), st.horde, L("ALLIANCE"), st.alliance))
        tactical.factions.detail:SetText(st.unknown > 0 and ("? " .. st.unknown) or "")

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
            tactical.chartLabel:SetText(L("CHART_LABEL"):format(st.levelN, maxCount, peakLevel, st.levelSum / st.levelN))
        else tactical.chartLabel:SetText(L("CHART_EMPTY")) end

        for i = 1, NSP_CONST.CLASS_BARS do
            local row, item = tactical.classes[i], st.top[i]
            if item and st.top[1].count > 0 then
                row:Show()
                TacticalClassIcon(row.icon, item.file)
                row.label:SetText(item.label)
                -- файл класса для обработчика клика (он читает row.classFile)
                row.classFile = item.file
                -- выбранный класс подсвечен: иначе фильтр не виден — в списке
                -- просто меньше строк, а почему — непонятно
                local selected = tactical.classFilter == item.file
                if selected then
                    row.label:SetTextColor(1, 0.85, 0.45)
                else
                    row.label:SetTextColor(0.85, 0.82, 0.75)
                end
                -- count + share of all players: the top classes are nearly
                -- equal (3026/2992/2894), a pure max-relative bar looks flat
                row.value:SetText(("%d (%.0f%%)"):format(item.count, 100 * item.count / math.max(1, st.total)))
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

        tactical.filters.all.label:SetText(L("UI_ALL") .. " " .. st.total)
        tactical.filters.fresh.label:SetText(L("UI_FRESH") .. " " .. st.f5)
        tactical.filters.new.label:SetText(L("UI_NEW") .. " " .. st.newN)
        tactical.filters.peer.label:SetText(L("UI_PEER") .. " " .. st.peerN)
        tactical.filters.peern.label:SetText(L("UI_PEER_NEW") .. " " .. st.peerNewN)
        for key, button in pairs(tactical.filters) do TacticalFilterState(button, key == tactical.filter) end
        tactical.count:SetText(tostring(TacticalRows()) .. " / " .. tostring(st.total))
        TacticalRealmCyclerState()
        TacticalClassCyclerState()
        TacticalLevelCyclerState()
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
        if key == "ESCAPE" then win:SetPropagateKeyboardInput(false); HideWindow()
        else win:SetPropagateKeyboardInput(true) end
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
        -- Прозрачная кнопка поверх столбца: сам столбец узкий — мелкая цель
        -- для мыши, а зона клика по всей ширине шага ловит уровень надёжно.
        -- Высота — вся высота гистограммы: промахнуться по уровню невозможно.
        local hit = CreateFrame("Button", nil, chart)
        hit:SetPoint("BOTTOMLEFT", 9 + (level - 1) * NSP_CONST.CHART_STEP - 3, 8)
        hit:SetSize(NSP_CONST.CHART_STEP, NSP_CONST.LEVEL_CHART_H)
        hit.level = level
        hit:SetScript("OnClick", function(self) TacticalLevelExact(self.level) end)
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
        -- Клик по строке класса — выборка по нему. Файл класса известен после
        -- отрисовки (TacticalUpdate заполняет row.classFile), поэтому обработчик
        -- читает его оттуда, а не из замыкания по i.
        row:SetScript("OnClick", function(self)
            local file = self.classFile
            if not file then return end
            tactical.classFilter = (tactical.classFilter == file) and nil or file
            TacticalUpdate()
        end)
        row:SetScript("OnEnter", function(self)
            if self.classFile and tactical.classFilter ~= self.classFile then
                self.label:SetTextColor(1, 0.9, 0.6)
            end
        end)
        row:SetScript("OnLeave", function(self)
            if self.classFile and tactical.classFilter ~= self.classFile then
                self.label:SetTextColor(0.85, 0.82, 0.75)
            end
        end)
    end

    local toolbar = TacticalPanel(win)
    toolbar:SetPoint("TOPLEFT", 16, -224); toolbar:SetSize(NSP_CONST.TOOLBAR_W, 31)
    -- Пять табов одной строкой. Позиции считаются из констант, а не вписаны
    -- числами: при смене ширины окна или подписи достаточно поправить
    -- FILTER_X0 / FILTER_W / FILTER_STEP, и ряд остаётся ровным.
    -- tile 1..3: все / свежие / новые
    TacticalFilter(toolbar, "all", NSP_CONST.FILTER_X0)
    TacticalFilter(toolbar, "fresh", NSP_CONST.FILTER_X0 + NSP_CONST.FILTER_STEP)
    TacticalFilter(toolbar, "new", NSP_CONST.FILTER_X0 + 2 * NSP_CONST.FILTER_STEP)
    -- tile 4: rows that arrived over the exchange channel (peerAt)
    TacticalFilter(toolbar, "peer", NSP_CONST.FILTER_X0 + 3 * NSP_CONST.FILTER_STEP)
    -- tile 5: the subset of channel rows that were new to us (peerNew)
    TacticalFilter(toolbar, "peern", NSP_CONST.FILTER_X0 + 4 * NSP_CONST.FILTER_STEP)
    -- Счётчик "показано / всего" — 7pt (small): подпись табов идёт 12pt, и
    -- счётчик того же размера отъедал место у последнего таба.
    tactical.count = NewText(toolbar, 7, 0.6, 0.53, 0.4)
    tactical.count:SetPoint("RIGHT", -NSP_CONST.COUNT_X, 0)

    -- Selector row: the database can hold players from other realms of the
    -- cluster (peer channel), so the list needs a realm selector of its own.
    -- A second row rather than another toolbar tile: the five filters plus the
    -- counter already fill the strip. The class and level selectors live in the
    -- same row — three selectors, one strip, each 260px in an 880px window.
    TacticalRealmCycler(win, 22, -256, 260)
    TacticalClassCycler(win, 298, -256, 260)
    TacticalLevelCycler(win, 574, -256, 260)

    local tableHeader = CreateFrame("Frame", nil, win)
    tableHeader:SetPoint("TOPLEFT", 16, -288); tableHeader:SetSize(NSP_CONST.TOOLBAR_W, 24)
    local thBg = tableHeader:CreateTexture(nil, "BACKGROUND"); thBg:SetAllPoints(); thBg:SetColorTexture(0.07, 0.055, 0.035, 1)
    -- Заголовки берут X из тех же констант, что и строки: при смене ширины
    -- окна они не могут разъехаться с данными.
    local h1 = NewText(tableHeader, 9, 0.62, 0.55, 0.4); h1:SetPoint("LEFT", NSP_CONST.COL_NAME_X, 0); h1:SetText(L("UI_PLAYER"))
    local h2 = NewText(tableHeader, 9, 0.62, 0.55, 0.4); h2:SetPoint("LEFT", NSP_CONST.COL_PROF_X, 0); h2:SetText(L("UI_PROFILE"))
    local h3 = NewText(tableHeader, 9, 0.62, 0.55, 0.4); h3:SetPoint("LEFT", NSP_CONST.COL_ZONE_X, 0); h3:SetText(L("UI_ZONE"))
    local h4 = NewText(tableHeader, 9, 0.62, 0.55, 0.4); h4:SetPoint("LEFT", NSP_CONST.COL_SEEN_X, 0); h4:SetText(L("UI_CONTACT"))

    local okSf, sf = pcall(CreateFrame, "ScrollFrame", nil, win, "UIPanelScrollFrameTemplate")
    if not okSf or not sf then sf = CreateFrame("ScrollFrame", nil, win) end
    sf:SetPoint("TOPLEFT", 16, -312); sf:SetPoint("BOTTOMRIGHT", -32, 43)
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
        if key == "ESCAPE" then serverWin:SetPropagateKeyboardInput(false); serverWin:Hide()
        else serverWin:SetPropagateKeyboardInput(true) end
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
    cell:SetScript("OnClick", onClick)
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
            hubWin:SetPropagateKeyboardInput(false)
            hubWin:Hide()
        else
            hubWin:SetPropagateKeyboardInput(true)
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
        function() ShowSettingsWindow() end)
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
    if win.SetPropagateKeyboardInput then win:SetPropagateKeyboardInput(true) end
    win:SetScript("OnKeyDown", function(_, key)
        if key == "ESCAPE" then
            win:SetPropagateKeyboardInput(false)
            win:Hide()
        else
            win:SetPropagateKeyboardInput(true)
        end
    end)
    optWin = win

    -- Rows are stacked by their MEASURED height, not by fixed offsets: a
    -- description wraps to two, three or four lines depending on the client
    -- font and the language, so hard-coded step of 52px made the longer rows
    -- overlap the next one (seen with the new "Accept other realms" checkbox).
    local rowY = -52
    local function NextCheckY(label, desc)
        return rowY - (4 + OptTextHeight(label, 14) + 3 + OptTextHeight(desc, 22)) - 16
    end
    local function NextSelectY(sel)
        -- a selector draws its label at y, the dropdown at y-14 and the
        -- description at y-46, so its block never ends before 46 + desc height
        return rowY - (46 + OptTextHeight(sel and sel.desc, 22)) - 18
    end

    opt.peer, opt.peerLabel, opt.peerDesc = OptCheck(win, 16, rowY, "SET_PEER", "SET_PEER_D",
        function() return GetDB().peerEnabled and true or false end,
        function(v)
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
        end)
    rowY = NextCheckY(opt.peerLabel, opt.peerDesc)

    opt.allRealms, opt.allRealmsLabel, opt.allRealmsDesc = OptCheck(win, 16, rowY,
        "SET_PEER_ALL", "SET_PEER_ALL_D",
        function() return GetDB().peerAllRealms and true or false end,
        function(v)
            local db = GetDB()
            db.peerAllRealms = v
            -- Both directions change what the list shows, so repaint it right
            -- away: with the flag off stored foreign rows disappear, with it on
            -- they come back (nothing is deleted either way).
            -- `win` here is the SETTINGS window: checking it told us only that
            -- the checkbox was visible, and the repaint then ran against a player
            -- window that may never have been built. Ask the player window.
            local mainWin = _G and _G.NearbySpyWindow
            if mainWin and mainWin.IsShown and mainWin:IsShown() then pcall(TacticalUpdate) end
            if hub and hub.Refresh then pcall(hub.Refresh) end
        end)
    rowY = NextCheckY(opt.allRealmsLabel, opt.allRealmsDesc)

    opt.minimap, opt.minimapLabel, opt.minimapDesc = OptCheck(win, 16, rowY, "SET_MINIMAP", "SET_MINIMAP_D",
        function() return not GetDB().minimapHide end,
        function(v)
            local db = GetDB()
            -- stored inverted: minimapHide keeps old saved variables working
            db.minimapHide = not v
            -- the icon is created lazily; if the user shows it before it was
            -- ever built, build it first — then the update places it (hiding
            -- then showing must leave a button on screen, not nothing)
            if v and not miniBtn and BuildMinimapButton then pcall(BuildMinimapButton) end
            if MinimapButton_Update then MinimapButton_Update() end
        end)
    rowY = NextCheckY(opt.minimapLabel, opt.minimapDesc)

    opt.lang = OptSelect(win, rowY, "NearbySpyLangDD", "SET_LANG", "SET_LANG_D", 190,
        LangEntries,
        function() return GetDB().locale or "AUTO" end,
        function(v)
            local db = GetDB()
            db.locale = (v ~= "AUTO") and v or nil
            RefreshSettingsText()
            P(L("SET_RELOAD"))
        end)
    rowY = NextSelectY(opt.lang)

    opt.tz = OptSelect(win, rowY, "NearbySpyTzDD", "SET_TZ", "SET_TZ_D", 190,
        TzEntries,
        function()
            local off = GetDB().tzOffset
            return (type(off) == "number") and off or "AUTO"
        end,
        function(v)
            GetDB().tzOffset = (v ~= "AUTO") and v or nil
        end)
    rowY = NextSelectY(opt.tz)

    -- The window grows with its content: a fixed height clipped the last
    -- selector once a longer description was added.
    local needH = -rowY + 18
    if needH < 360 then needH = 360 end
    if win.SetHeight then win:SetHeight(needH) elseif win.SetSize then win:SetSize(380, needH) end

    win:Hide()
end

-- Live relabel after a language switch: only the settings window rebuilds its
-- text; windows built earlier keep their labels until /reload (hint is shown).
RefreshSettingsText = function()
    if not optWin then return end
    local tt = optWin.TitleText or opt.title
    if tt and tt.SetText then tt:SetText(L("HUB_SETTINGS")) end
    if opt.peerLabel then opt.peerLabel:SetText(L("SET_PEER")) end
    if opt.peerDesc then opt.peerDesc:SetText(L("SET_PEER_D")) end
    if opt.allRealmsLabel then opt.allRealmsLabel:SetText(L("SET_PEER_ALL")) end
    if opt.allRealmsDesc then opt.allRealmsDesc:SetText(L("SET_PEER_ALL_D")) end
    if opt.minimapLabel then opt.minimapLabel:SetText(L("SET_MINIMAP")) end
    if opt.minimapDesc then opt.minimapDesc:SetText(L("SET_MINIMAP_D")) end
    if opt.lang then
        opt.lang.label:SetText(L("SET_LANG"))
        opt.lang.desc:SetText(L("SET_LANG_D"))
        opt.lang.Refresh()
    end
    if opt.tz then
        opt.tz.label:SetText(L("SET_TZ"))
        opt.tz.desc:SetText(L("SET_TZ_D"))
        opt.tz.Refresh()
    end
end

ShowSettingsWindow = function()
    local ok, err = pcall(function()
        if not optWin then BuildSettingsWindow() end
        if opt.peer then opt.peer:SetChecked(GetDB().peerEnabled and true or false) end
        if opt.allRealms then opt.allRealms:SetChecked(GetDB().peerAllRealms and true or false) end
        if opt.lang then opt.lang.Refresh() end
        if opt.tz then opt.tz.Refresh() end
        optWin:Show()
    end)
    if not ok then P(L("ERR_WINDOW") .. tostring(err)) end
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
        ShowSettingsWindow()
    elseif msg == "whotest" or msg:match("^whotest%s") then
        -- diagnostic: probe the programmatic /who gate on this build
        --   /nspy whotest              three send paths, 15 s each
        --   /nspy whotest gap 150 4    four button clicks, 150 s apart
        StartWhoTest(msg:match("^whotest%s+(.*)$"))
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
    elseif msg == "count" then
        P(L("COUNT"):format(
            CountPlayers(), newThisSession, db.announce and L("ON") or L("OFF")))
        P(DebugSummary(db))
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
        -- Переходный режим: N6 экономит 19 байт на запись, но клиент старой
        -- версии его не поймёт. Команда позволяет вернуться на N5 (те же пачки,
        -- поля текстом) без переустановки аддона.
        PEER_PROTO = (PEER_PROTO == "N6") and "N5" or "N6"
        db.peerProto = PEER_PROTO
        P(("Peer protocol: %s (приём N2-N6 работает всегда)"):format(PEER_PROTO))
        if PeerSync then pcall(PeerSync) end
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
        P(("Peer transport: seen=%d, valid=%d, rejected=%d, duplicates=%d, merged=%d, foreign=%d, selfEcho=%d, chat=%s, lastSender=%s")
            :format(peerStats.seen, peerStats.valid, peerStats.rejected,
                peerStats.valid - peerStats.received - peerStats.merged, peerStats.merged,
                peerStats.foreign, peerStats.selfEcho, peerChatVisible and "ON" or "OFF",
                peerStats.lastSender or "-"))
        -- counters of the LAST logged session: the only cross-session proof that
        -- the channel carries anything at all (memory-only stats die on logout)
        local last = type(db.debug) == "table" and db.debug.peer or nil
        if type(last) == "table" then
            P(("Peer last session: sent=%d received=%d merged=%d foreign=%d selfEcho=%d seen=%d valid=%d rejected=%d channel=%s lastSender=%s")
                :format(last.sent or 0, last.received or 0, last.merged or 0, last.foreign or 0,
                    last.selfEcho or 0, last.seen or 0, last.valid or 0, last.rejected or 0,
                    tostring(last.channel), PeerEsc(last.lastSender or "-", 40)))
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
end

local function PeerTryDrain(why)
    PeerDrainStat(why)
    local ok, err = pcall(DrainPeerQueue)
    if not ok then DbgErr("peerSend:" .. tostring(why), err) end
end

if WorldFrame and WorldFrame.HookScript then
    WorldFrame:HookScript("OnMouseDown", function() PeerTryDrain("world") end)
end

-- События реального ввода: каждое означает, что игрок что-то нажал.
-- Регистрируются на отдельном фрейме, чтобы не трогать основной обработчик.
local peerInput = CreateFrame("Frame")
peerInput:RegisterEvent("PLAYER_STARTED_MOVING")
peerInput:RegisterEvent("PLAYER_STOPPED_MOVING")
peerInput:RegisterEvent("UNIT_SPELLCAST_START")
peerInput:RegisterEvent("PLAYER_TARGET_CHANGED")
peerInput:RegisterEvent("START_LOOT_ROLL")
peerInput:SetScript("OnEvent", function(_, event, arg1)
    -- UNIT_SPELLCAST_START приходит для любого юнита: нас интересует только
    -- действие самого игрока, иначе чужие касты в группе будут дёргать очередь.
    if event == "UNIT_SPELLCAST_START" and arg1 ~= "player" then return end
    PeerTryDrain(event)
end)
chatFrame:RegisterEvent("CHAT_MSG_SAY")
chatFrame:RegisterEvent("CHAT_MSG_YELL")
chatFrame:RegisterEvent("CHAT_MSG_CHANNEL")
chatFrame:RegisterEvent("CHAT_MSG_CHANNEL_NOTICE")
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
                end
            end, ...)
            if not okN then DbgErr("channelNotice", errN) end
            return
        end
        if ev == "CHAT_MSG_CHANNEL" and
            (IsPeerChannel(select(9, ...)) or IsPeerChannel(select(4, ...))) then
            ReceivePeerMessage(select(1, ...), select(2, ...))
            return -- peer speaker is not a new encounter; no rebroadcast
        end
        local speaker = select(2, ...)
        if type(speaker) ~= "string" or speaker == "" or
            (canaccessvalue and not canaccessvalue(speaker)) then return end
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
        realm = realm or PlayerRealm()
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

frame:SetScript("OnEvent", function(self, event, arg1, arg2, arg3)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then
            GetDB()
        end
    elseif event == "PLAYER_LOGIN" then
        local db = GetDB()
        EnsureNameplates(db)
        ScheduleTick()
        if db.peerEnabled then
            local ok, err = pcall(JoinPeerChannel)
            if not ok then DbgErr("peerJoin", err) end
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
        local db = GetDB()
        db.debug.blocked = db.debug.blocked or {}
        db.debug.blocked[func] = (db.debug.blocked[func] or 0) + 1
        if addon:find("NearbySpy", 1, true) then
            D(("client blocked our call: %s (%s)"):format(func, event))
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
