--[[
    NearbySpy 1.0.0
    Записывает игроков рядом с тобой в SavedVariables (NearbySpy.lua).

    Источники данных — пассивные, основной режим (пользователю ничего делать не надо):
      - таргет, фокус, наведение мыши (UPDATE_MOUSEOVER_UNIT);
      - nameplate1..nameplate40 (NAME_PLATE_UNIT_ADDED + тик раз в 2 сек) — в бете
        nameplate'ы молчат (lastPlates=0), оставлено на случай включения;
      - группа/рейд (GROUP_ROSTER_UPDATE);
      - ростер гильдии (GUILD_ROSTER_UPDATE) — уровень/класс/зона всех согильдийцев;
      - комбат-лог (COMBAT_LOG_EVENT_UNFILTERED) — имя+класс+раса по GUID, дедуп 2 мин;
      - чат (CHAT_MSG_SAY/YELL/CHANNEL) — только имя говорящего (класс/уровень
        неизвестны → пустые поля не передаются), source='chat': городские каналы
        показывают тех, до кого nameplate-скан и ростеры не доходят;
      - /who — РАСШИРЕННЫЙ ручной режим /nspy suggest: с билда 1.60.1.70291 сервер
        отвечает только на аппаратный клик (hardware-гейт в C++, программный who мёртв),
        поэтому аддон вписывает запрос в поле, а пользователь жмёт лупу.
    Команды: /nearbyspy (или /nspy) — окно со списком,
             /nspy suggest | count | who | announce | debug | reset

]]

local ADDON_NAME = ...

local PREFIX = "|cff33ff99NearbySpy|r: "
local REAP_SECONDS = 600      -- встреча после паузы дольше = новый "заход" в счётчик
local TICK_SECONDS = 2
local WHO_GAP = 45            -- базовая пауза между запросами скана, сек (+ случайные 0-30 — не метроном)
local WHO_CAP = 50            -- серверный лимит строк в ответе /who
local MAX_ROWS = 500          -- сколько строк рисуем в списке (защита от гигантских баз)
local GROUP_TROTTLE = 10      -- GROUP_ROSTER_UPDATE спамится — проход не чаще, сек
local GUILD_REFRESH = 600     -- дозапрос ростера гильдии раз в 10 мин
local LEVEL_CHART_H = 56      -- графики окна: высота столбика уровней, px
local CLASS_BARS = 3          -- сколько баров топ-классов рисуем

-- ============ локализация UI (enUS fallback, ruRU, zhCN) ============
-- Только пользовательские строки (P/окна). Отладочные D()-сообщения и
-- причины FinishZoneScan — технические, держим на английском вне таблицы.
local LOCALE = {
    enUS = {
        ON = "on", OFF = "off",
        LVL_PREFIX = "lvl ",
        ALLIANCE = "Alliance", HORDE = "Horde",
        FIRST_SEEN = "first seen nearby: %s (%s%s) - %s",
        WHO_THROTTLED = "server is throttling /who — pausing for 5 min",
        SUGGEST_INSCRIBED = "suggest: typed \"%s\" — CLICK the search button (%d more queued)",
        SUGGEST_WAITING = "suggest: still waiting for your search-button click (\"%s\")",
        ERR_SCAN_RUNNING = "scan already running (%s)",
        ERR_THROTTLE_PAUSE = "throttle pause: %ds — the server complained recently",
        ERR_QUEUE_EMPTY = "queue is empty (no names to filter)",
        WHO_FACTION_COVER = "/who sees only the %s faction — full coverage needs a scan on a character of each faction",
        CVAR_FIX = "enabled %s=1",
        EXPORT_TITLE = "NearbySpy - export (raw data)",
        EXPORT_HINT = "Click the text -> Ctrl+A, Ctrl+C; Esc or × to close",
        ERR_EXPORT = "export window ERROR: ",
        ERR_LIST = "list ERROR: ",
        ERR_WINDOW = "window ERROR: ",
        TIME_NOW = "just now", TIME_MIN = "%d min ago", TIME_HOUR = "%d h ago",
        SRC_LINE = "Sources: ",
        WIN_TOTAL = "Total: %d players · new this session: %d",
        WIN_FRESH = "Fresh: 5m=%d · 15m=%d · 1h=%d",
        WIN_DEMO = "Lvl %d–%d (avg %d)",
        CHART_LABEL = "Levels 1–60: %d with a level · peak %d players at lvl %d · avg %.1f",
        CHART_EMPTY = "Levels 1–60: no data",
        BTN_COPY = "Copy",
        WIN_HINT = "Esc - close · /nspy count - stats · /nspy who - zone scan",
        MODE_LEVEL = "wide + classes", MODE_CLASS = "by classes", MODE_RACE = "by races",
        SCAN_STARTED = "%s scan started (%s), 45-75 sec pause between queries",
        SCAN_FAILED = "scan did not start: ",
        SCAN_NOT_RUNNING = "no scan running",
        SUGGEST_PROG_BLOCK = "programmatic scan running — /nspy whostop first",
        SUGGEST_STARTED = "suggest: typing queries into the who box — you only click the search button. Stop: /nspy suggest",
        SUGGEST_FAILED = "suggest did not start: ",
        COUNT = "total players: %d, new this session: %d, announcements: %s",
        ANNOUNCE_TOGGLE = "new player announcements: ",
        DEBUG_ON = "debug mode: on — logs to chat (digests, scan, who, gate blocks)",
        DEBUG_OFF = "debug mode: off — stealth mode, logs go only to the SV ring",
        DB_CLEARED = "encounter database cleared",
        CMDS = "commands: /nspy [show|export|who|whoclass|whorace|whostop|suggest|count|announce|debug|reset]",
        QUERIES_FMT = "%d queries",
        STARTUP = "started, %d players in db. Commands: /nspy (suggest — assisted /who)",
    },
    ruRU = {
        ON = "вкл", OFF = "выкл",
        LVL_PREFIX = "ур. ",
        ALLIANCE = "Альянс", HORDE = "Орда",
        FIRST_SEEN = "впервые рядом: %s (%s%s) - %s",
        WHO_THROTTLED = "сервер троттлит /who — пауза 5 минут",
        SUGGEST_INSCRIBED = "suggest: вписал «%s» — ЖМИ ЛУПУ (в очереди ещё %d)",
        SUGGEST_WAITING = "suggest: всё ещё жду твой клик по лупе («%s»)",
        ERR_SCAN_RUNNING = "скан уже идёт (%s)",
        ERR_THROTTLE_PAUSE = "пауза троттла: %dс — сервер недавно ругался",
        ERR_QUEUE_EMPTY = "очередь пуста (нет имён для фильтра)",
        WHO_FACTION_COVER = "who видит только фракцию %s — полное покрытие: скан под персонажем каждой фракции",
        CVAR_FIX = "включил %s=1",
        EXPORT_TITLE = "NearbySpy - экспорт (сырые данные)",
        EXPORT_HINT = "Клик по тексту -> Ctrl+A, Ctrl+C; Esc или × - закрыть",
        ERR_EXPORT = "ОШИБКА окна экспорта: ",
        ERR_LIST = "ОШИБКА списка: ",
        ERR_WINDOW = "ОШИБКА окна: ",
        TIME_NOW = "только что", TIME_MIN = "%d мин назад", TIME_HOUR = "%d ч назад",
        SRC_LINE = "Кто кормит: ",
        WIN_TOTAL = "Всего: %d игроков · новых за сессию: %d",
        WIN_FRESH = "Свежие: 5м=%d · 15м=%d · 1ч=%d",
        WIN_DEMO = "Ур. %d–%d (ср. %d)",
        CHART_LABEL = "Уровни 1–60: всего с уровнем %d · макс %d игроков ур. %d · ср. %.1f",
        CHART_EMPTY = "Уровни 1–60: данных нет",
        BTN_COPY = "Копировать",
        WIN_HINT = "Esc - закрыть · /nspy count - статистика · /nspy who - скан зоны",
        MODE_LEVEL = "широкий + классы", MODE_CLASS = "по классам", MODE_RACE = "по расам",
        SCAN_STARTED = "скан %s запущен (%s), пауза 45-75 сек между запросами",
        SCAN_FAILED = "скан не ушёл: ",
        SCAN_NOT_RUNNING = "скан не идёт",
        SUGGEST_PROG_BLOCK = "идёт программный скан — сначала /nspy whostop",
        SUGGEST_STARTED = "suggest: вписываю запросы в поле who — твоё дело только жать лупу. Стоп: /nspy suggest",
        SUGGEST_FAILED = "suggest не стартовал: ",
        COUNT = "всего игроков: %d, новых за сессию: %d, анонсы: %s",
        ANNOUNCE_TOGGLE = "анонсы новых игроков: ",
        DEBUG_ON = "режим дебага: вкл — логи в чат (дайджесты, скан, who, блокировки гейта)",
        DEBUG_OFF = "режим дебага: выкл — скрытный, логи только в SV-кольцо",
        DB_CLEARED = "база встреч очищена",
        CMDS = "команды: /nspy [show|export|who|whoclass|whorace|whostop|suggest|count|announce|debug|reset]",
        QUERIES_FMT = "%d запросов",
        STARTUP = "запущен, в базе %d игроков. Команды: /nspy (suggest — расширенный /who)",
    },
    zhCN = {
        ON = "开启", OFF = "关闭",
        LVL_PREFIX = "等级 ",
        ALLIANCE = "联盟", HORDE = "部落",
        FIRST_SEEN = "首次发现附近玩家: %s (%s%s) - %s",
        WHO_THROTTLED = "服务器正在限制 /who —— 暂停5分钟",
        SUGGEST_INSCRIBED = "suggest: 已填入「%s」——请点击搜索按钮（队列还有%d个）",
        SUGGEST_WAITING = "suggest: 仍在等待你点击搜索按钮（「%s」）",
        ERR_SCAN_RUNNING = "扫描已在进行中（%s）",
        ERR_THROTTLE_PAUSE = "限流暂停: %d秒 —— 服务器最近发出过限制警告",
        ERR_QUEUE_EMPTY = "队列为空（没有可过滤的名字）",
        WHO_FACTION_COVER = "/who 只能看到%s阵营 —— 完整覆盖需要在每个阵营的角色上扫描",
        CVAR_FIX = "已启用 %s=1",
        EXPORT_TITLE = "NearbySpy - 导出（原始数据）",
        EXPORT_HINT = "点击文本 -> Ctrl+A, Ctrl+C；Esc 或 × 关闭",
        ERR_EXPORT = "导出窗口错误: ",
        ERR_LIST = "列表错误: ",
        ERR_WINDOW = "窗口错误: ",
        TIME_NOW = "刚刚", TIME_MIN = "%d分钟前", TIME_HOUR = "%d小时前",
        SRC_LINE = "数据来源: ",
        WIN_TOTAL = "总计: %d名玩家 · 本次会话新增: %d",
        WIN_FRESH = "最近活跃: 5分钟=%d · 15分钟=%d · 1小时=%d",
        WIN_DEMO = "等级 %d–%d（平均%d）",
        CHART_LABEL = "等级 1–60: 有等级的%d名 · %d级最多%d名玩家 · 平均%.1f",
        CHART_EMPTY = "等级 1–60: 暂无数据",
        BTN_COPY = "复制",
        WIN_HINT = "Esc - 关闭 · /nspy count - 统计 · /nspy who - 区域扫描",
        MODE_LEVEL = "广域+职业", MODE_CLASS = "按职业", MODE_RACE = "按种族",
        SCAN_STARTED = "%s扫描已启动（%s），查询间隔45-75秒",
        SCAN_FAILED = "扫描未能启动: ",
        SCAN_NOT_RUNNING = "没有进行中的扫描",
        SUGGEST_PROG_BLOCK = "程序扫描正在运行 —— 请先 /nspy whostop",
        SUGGEST_STARTED = "suggest: 正在将查询填入搜索框 —— 你只需点击搜索按钮。停止: /nspy suggest",
        SUGGEST_FAILED = "suggest 未能启动: ",
        COUNT = "玩家总数: %d，本次会话新增: %d，公告: %s",
        ANNOUNCE_TOGGLE = "新玩家公告: ",
        DEBUG_ON = "调试模式: 开启 —— 日志输出到聊天（摘要、扫描、who、门禁拦截）",
        DEBUG_OFF = "调试模式: 关闭 —— 静默模式，日志仅写入SV环形缓冲区",
        DB_CLEARED = "遭遇数据库已清空",
        CMDS = "命令: /nspy [show|export|who|whoclass|whorace|whostop|suggest|count|announce|debug|reset]",
        QUERIES_FMT = "%d 个查询",
        STARTUP = "已启动，数据库中有%d名玩家。命令: /nspy（suggest —— 辅助 /who）",
    },
}
local function L(key)
    local t = LOCALE[GetLocale()] or LOCALE.enUS
    return t[key] or LOCALE.enUS[key] or key
end

local newThisSession = 0
local lastWhoSent = 0
local whoScan = nil           -- активный послойный скан {zone, sent, results, added, current, suggest}
local whoQueue = {}           -- очередь диапазонов {lo, hi}

local GetDB   -- forward: тело P пишет кольцо в db через эту ссылку

local function P(msg)
    -- таймстамп в каждую строку (08.10): без времени в кольце невозможно
    -- отличить мгновенный ответ от кулдауна сервера
    local stamped = ("[%s] %s"):format(date("%H:%M:%S"), tostring(msg))
    print(PREFIX .. stamped)
    -- дубль печати в SavedVariables-кольцо (последние 200 строк): чат-кэш
    -- пуст, вывод команд читается после логаута прямо из SV
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
        NearbySpy = { players = {}, announce = true, created = time() }
    end
    if type(NearbySpy.players) ~= "table" then
        NearbySpy.players = {}
    end
    if type(NearbySpy.debug) ~= "table" then
        NearbySpy.debug = {}
    end
    local db = NearbySpy
    -- метка игры для сайта (14.10.2026): retail / classic_era / forever.
    -- GetBuildInfo: 1.60.x — Forever-бета; прочий 1.x — classic-лайн;
    -- >=11 — retail. Пишется один раз; API нет → не пишем (сайт сам
    -- подставит дефолт forever).
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
    -- разовая миграция: склейка двусловных имён Camelot, разорванных старым
    -- парсингом (фамилия попадала в realm), + замена realm на настоящий
    if not db.migratedNames then
        local realRealm = GetRealmName()
        if realRealm and realRealm ~= "" then
            db.migratedNames = true
            local merged = {}
            for _, p in pairs(db.players) do
                if p.name and p.realm and p.realm ~= ""
                    and p.realm ~= realRealm and not p.name:find(" ") then
                    -- фамилия застряла в realm — возвращаем в имя
                    p.name = p.name .. " " .. p.realm
                end
                p.realm = realRealm
                local nk = p.name .. "-" .. realRealm
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
            end
            db.players = merged
        end
    end
    return db
end

-- кольцо без чата (дайджесты каждые 5 мин — не спамим игроку)
local function R(msg)
    local ok, db2 = pcall(GetDB)
    if ok and type(db2) == "table" and type(db2.debug) == "table" then
        local ring = db2.debug.printRing
        if type(ring) ~= "table" then ring = {}; db2.debug.printRing = ring end
        ring[#ring + 1] = ("[%s] %s"):format(date("%H:%M:%S"), tostring(msg)):sub(1, 500)
        if #ring > 200 then table.remove(ring, 1) end
    end
end

-- ЛОГ (режим дебага): всегда в SV-кольцо, а в чат — ТОЛЬКО при
-- db.debugMode (/nspy debug). С выключенным debug модуль «скрытный»: в чате
-- только ответы на команды, анонсы и ошибки; технические строки (прогресс
-- скана, дайджесты, блокировки гейта) читаются из кольца после логаута.
local function D(msg)
    local ok, db2 = pcall(GetDB)
    if ok and type(db2) == "table" and db2.debugMode then
        P(msg)   -- P печатает в чат и дублирует в кольцо
    else
        R(msg)   -- тихо: только кольцо
    end
end

-- первая ошибка по источнику — в debug (раньше pcall глотал молча, 1.5.1)
local function DbgErr(src, err)
    local ok, db = pcall(GetDB)
    if not ok then return end
    db.debug.err = db.debug.err or {}
    if not db.debug.err[src] then
        db.debug.err[src] = tostring(err):sub(1, 200)
        D(("DEBUG error [%s]: %s"):format(src, tostring(err):sub(1, 120)))
    end
end

local function PlayerRealm()
    -- Camelot: двусловные имена — UnitName отдаёт ФАМИЛИЮ как «realm»,
    -- поэтому настоящий реалм берём только из GetRealmName().
    return GetRealmName() or "?"
end

-- зона по имени игрока (чужой юнит в бете отдаёт mapID=0, имя зоны не вытащить)
local function PlayerZone()
    local zone = GetZoneText()
    if not zone or zone == "" then
        zone = GetRealZoneText()
    end
    return zone
end

-- приближённые координаты: позиция игрока (кто рядом — в той же зоне)
local function PlayerXY()
    local ok, mapID = pcall(C_Map.GetBestMapForUnit, "player")
    if not ok or not mapID then return nil, nil end
    local ok2, pos = pcall(C_Map.GetPlayerMapPosition, mapID, "player")
    if not ok2 or not pos then return nil, nil end
    local x, y = pos:GetXY()
    return x, y
end

-- uiMapID текущей зоны — число, одинаковое на любом языке клиента
local function PlayerZoneId()
    local ok, mapID = pcall(C_Map.GetBestMapForUnit, "player")
    if ok and mapID and mapID > 0 then return mapID end
    return nil
end

local function Round4(v)
    if type(v) ~= "number" then return nil end
    return math.floor(v * 10000 + 0.5) / 10000
end

-- локализованное имя класса -> файл-ключ (для цвета в UI)
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

-- общая запись/обновление
local function UpsertPlayer(db, data)
    local key = data.key
    if not key then return false end
    local nowT = time()
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
            zone = data.zone,
            zoneId = data.zoneId,
            x = Round4(data.x),
            y = Round4(data.y),
            firstSeen = nowT,
            lastSeen = nowT,
            count = 1,
            source = data.source,
        }
        newThisSession = newThisSession + 1
        -- счётчик по источникам (1.5.1, полный дебаг): кто реально кормит базу
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
        return true
    end
    if nowT - (entry.lastSeen or 0) > REAP_SECONDS then
        entry.count = (entry.count or 1) + 1
    end
    entry.lastSeen = nowT
    if data.level then entry.level = data.level end
    if data.class then entry.class = data.class end
    if data.classLoc then entry.classLoc = data.classLoc end
    if data.zone then entry.zone = data.zone end
    if data.zoneId then entry.zoneId = data.zoneId end
    if data.x then
        entry.x = Round4(data.x)
        entry.y = Round4(data.y)
    end
    if data.faction and (not entry.faction or entry.faction == "Unknown") then
        entry.faction = data.faction
    end
    if data.race and not entry.race then
        entry.race = data.race
    end
    entry.guid = entry.guid or data.guid
    return false
end

-- Расы -> фракция (файл-ключи из UnitRace: Human, Orc, ...)
local RACE_FACTION = {
    Human = "Alliance", Dwarf = "Alliance", NightElf = "Alliance", Gnome = "Alliance",
    Orc = "Horde", Scourge = "Horde", Tauren = "Horde", Troll = "Horde",
}

-- локализованное имя расы (из /who) -> файл-ключ: ruRU + enUS
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

-- Самообучение рас/фракций (кастомные расы сервера):
-- из юнит-детектов учим "локализованная раса → файл-ключ" и "раса → фракция",
-- затем применяем к /who-записям. Хранится в SavedVariables (db.learn).
local function LearnRace(db, raceLoc, raceFile, faction)
    db.learn = db.learn or {}
    if raceLoc and raceLoc ~= "" and raceFile and raceFile ~= "" then
        db.learn.raceLoc2File = db.learn.raceLoc2File or {}
        db.learn.raceLoc2File[raceLoc] = raceFile
    end
    if raceFile and raceFile ~= "" and faction and faction ~= "Unknown" and faction ~= "" then
        db.learn.raceFaction = db.learn.raceFaction or {}
        db.learn.raceFaction[raceFile] = faction
    end
end

-- Фракция: у вражеских игроков UnitFactionGroup может быть пустым,
-- тогда выводим "противоположную своему" через UnitCanAttack.
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
    -- Camelot: «realm» из UnitName — это фамилия двусловного имени, склеиваем
    if surname and surname ~= "" then
        name = name .. " " .. surname
    end
    local realm = PlayerRealm()

    local db = GetDB()
    local okC, classLoc, classFile = pcall(UnitClass, unit)
    if not okC then classLoc, classFile = nil, nil end
    local okL, level = pcall(UnitLevel, unit)
    if okL and level and level < 0 then level = nil elseif not okL then level = nil end
    -- раса: UnitRace возвращает (локализованное имя, файл-ключ)
    local raceFile = nil
    local okR, raceLoc, raceFileRet = pcall(UnitRace, unit)
    if okR then raceFile = raceFileRet end
    local faction = GetFaction(unit)
    if (not faction or faction == "Unknown") and raceFile then
        local learned = db.learn and db.learn.raceFaction and db.learn.raceFaction[raceFile]
        faction = learned or RACE_FACTION[raceFile] or faction
    end
    LearnRace(db, raceLoc, raceFile, faction)

    -- координаты: сначала реальные юнита, иначе приближение игрока
    local okP, x, y = pcall(UnitPosition, unit)
    if not okP or not x then
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
        x = x,
        y = y,
        source = "unit",
    })
end

-- ============ пассивный сбор мира (1.5.0 — основной режим) ============
-- Программный /who мёртв с билда 70291 (hardware-гейт в C++, whoprime 0/17) —
-- базу кормит мир: наведение, группа, гильдия, чат. Всё без действий
-- пользователя. /who остаётся расширенным ручным режимом (/nspy suggest).

-- группа/рейд: GROUP_ROSTER_UPDATE спамится при сборе рейда — троттл прохода
local lastGroupScan = 0
local function RecordGroup()
    local nowT = time()
    if nowT - lastGroupScan < GROUP_TROTTLE then return end
    lastGroupScan = nowT
    for i = 1, 4 do pcall(Record, "party" .. i) end
    for i = 1, 40 do pcall(Record, "raid" .. i) end
end

-- гильдия: ростер отдаёт уровень/класс/зону всех согильдийцев — богатый срез
local function RecordGuild()
    if not IsInGuild or not IsInGuild() then return end
    if not GetNumGuildMembers or not GetGuildRosterInfo then return end
    local n = GetNumGuildMembers() or 0
    if n <= 0 then return end
    local db = GetDB()
    local realm = PlayerRealm()
    local faction = GetFaction("player")  -- своя гильдия = своя фракция
    local added = 0
    for i = 1, n do
        -- сигнатура: name, rank, rankIdx, level, classLoc, zone, note, onote,
        -- online, status, classFile, achPts, achRank, mobile, soR, rep, guid
        local ok, name, _, _, level, classLoc, zone, _, _, _, _, classFile, _, _, _, _, _, guid =
            pcall(GetGuildRosterInfo, i)
        if ok and name and name ~= "" then
            name = name:match("^([^%-]+)%-") or name  -- стрип «Имя-Реалм»
            if UpsertPlayer(db, {
                key = name .. "-" .. realm,
                name = name,
                realm = realm,
                class = classFile or ClassFileFromLocalized(classLoc),
                classLoc = classLoc,
                level = level,
                faction = faction,
                guid = guid,
                zone = zone,  -- зона из ростера — где игрок сейчас (может быть чужая)
                source = "guild",
                silent = true,  -- ростер сотнями — не спамим чат
            }) then added = added + 1 end
        end
    end
    db.debug.guildSeen = n
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

-- ============ /who зоновый скан ============
-- Сервер отдаёт максимум 50 строк на один запрос. Обход (подход CensusPlus):
-- сканируем диапазонами уровней (1-10, 11-20, ...), диапазон с 50 результатами
-- дробим пополам вплоть до одного уровня (1-1, 2-2, ...).

local function MaxLevel()
    -- Реальный потолок = макс. уровень, виденный в базе, округлённый вверх до
    -- границы полосы 10 (решение пользователя 09.10.2026: «используй
    -- максимальный уровень доступный, сейчас это 30»). GetMaxPlayerLevel
    -- отдаёт движковый 60 и врёт про серверный кап беты (30), поэтому
    -- ориентируемся на фактические данные; когда игроки поднимутся выше,
    -- потолок вырастет сам без правок кода.
    local m = 0
    local d = GetDB()
    if d and d.players then
        for _, p in pairs(d.players) do
            local l = tonumber(p.level) or 0
            if l > m then m = l end
        end
    end
    if m > 0 then
        return math.ceil(m / 10) * 10
    end
    if GetMaxPlayerLevel then
        local ok, ml = pcall(GetMaxPlayerLevel)
        if ok and type(ml) == "number" and ml > 0 then return ml end
    end
    return 60
end

-- Отправка /who БЕЗ чата (решение пользователя 07.10.2026: «давай без чата»).
-- Наблюдение пользователя 07.10.2026: SetText подставляет текст в поле Who,
-- но поиск НЕ запускается — ручной эталон работает только с ОТКРЫТЫМ окном,
-- а аддон окно лишь прячет и кликает мёртвую кнопку. Поэтому:
--   * перед enter/button-путями показываем окно Who и его родителей;
--   * пути ротируются по числу попытки (PumpWhoQueue крутит q.retries):
--     1. OnEnterPressed поля (эквивалент «ввод + Enter»);
--     2. клик по кнопке (эквивалент ручного клика);
--     3. тихий C_FriendList.SendWho (API, без окна);
--   * если выбранный путь падает синхронно (нет обработчика/кнопки) —
--     в ТОЙ ЖЕ отправке пробуется следующий, скан не умирает;
--   * возврат: true, "<путь>" | false, "<детали провалов>".
local WHO_PATHS = { "button", "enter", "api" }
local whoShownByMe = {}    -- фреймы, показанные нами ради отправки /who
local whoHiddenPanels = {} -- чужие панели LFG, скрытые нами (вернёт HideWhoFrame)

local function EnsureWhoVisible()
    -- кто открыт — запоминаем, HideWhoFrame уберёт только показанное нами.
    -- WhoFrame в этом клиенте отсутствует (тест 08.10: дерево пустое) —
    -- берём реального родителя поля ввода WhoFrameEditBox
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
    -- 08.10: жалоба пользователя — при открытии видно «поиск подземелья», а не
    -- игроков. Переключаем вкладку: кликаем табы LFGParentFrame, пока именованные
    -- чужие панели (Listing/Browse) не погаснут — это и есть вкладка who; затем
    -- глушим остатки и возвращаем who-панель, если таб её убрал.
    pcall(function()
        -- Переключение на вкладку who — ГЛОБАЛЬНОЙ функцией клиента (08.10, точный
        -- билд 1.60.1.70205 разобран по исходникам):
        --   вкладки: 1=Listing, 2=Browse, 3=Who;
        --   OnShow окна сама ставит прежнюю/первую вкладку (потому и «первая из трёх»);
        --   клик самих табов падает — миксин Templates.lua зовёт local
        --   LFGParentFrame_SetActiveTab, недоступный из другого файла → nil;
        --   LFGParentFrameTab3_OnClick() — официальный путь: SetTab(3) + показ
        --   LFGWhoListFrame + скрытие Listing/Browse + подсветка вкладки.
        if type(LFGParentFrameTab3_OnClick) == "function" then
            LFGParentFrameTab3_OnClick()
        end
    end)
    pcall(function()
        -- подстраховка на случай, если глобальной функции нет: глушим чужие панели
        -- и гарантируем показ who-панели
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

local WhoSearchButton  -- определение ниже; local здесь,
    -- чтобы WhoSendRaw видел ту же переменную, а не nil-глобал

-- Жмём «лупу» как игрок (08.10): обработчик клиента (WhoSearchMixin:OnClick)
-- читает LFGWhoListFrame.EditBox и шлёт SendWho(text, Social, filters).
-- Берём виджеты НАПРЯМУЮ из parentKey-полей XML (WhoSearch/EditBox), дублируем
-- SetWhoToUi(true) (его ставит OnShow панели — после показа скрытого родителя
-- мог не отработать; если окно спрятут — OnHide вернёт false и ответ уйдёт
-- из UI, баг 06.10) и даём видимую отдачу: программный Click() не анимирует
-- текстуру кнопки — пользователь видит «не нажимается».
local function WhoPress(query)
    EnsureWhoVisible()
    pcall(function()
        if C_FriendList and C_FriendList.SetWhoToUi then
            C_FriendList.SetWhoToUi(true)
        end
    end)
    local box = (LFGWhoListFrame and LFGWhoListFrame.EditBox) or WhoFrameEditBox
    if not box then error("who edit box not found") end
    box:SetText(query)
    local txtAtClick = (box.GetText and box:GetText()) or "?"
    local btn = (LFGWhoListFrame and LFGWhoListFrame.WhoSearch) or WhoSearchButton()
    if not btn then error("who search button not found") end
    pcall(function() PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON) end)
    pcall(function() btn:LockHighlight() end)
    C_Timer.After(0.2, function() pcall(function() btn:UnlockHighlight() end) end)
    btn:Click("LeftButton")
    local txtAfter = (box.GetText and box:GetText()) or "?"
    return btn, box, txtAtClick, txtAfter
end

local function WhoSendRaw(query, attempt)
    -- 08.10: кнопка с Click("LeftButton") — единственный подтверждённо живой не-чат
    -- путь (whotest clickL: 50, уровни 27-30). Ротацию по попыткам убрали: ретраи
    -- сторожа ВСЕГДА идут кнопкой, enter/api — только синхронный фолбэк, если окно
    -- или кнопка недоступны. attempt в сигнатуре оставлен (вызовы передают).
    local errs = {}
    for i = 1, #WHO_PATHS do
        local path = WHO_PATHS[i]
        local ok, err
        if path == "enter" then
            ok, err = pcall(function()
                EnsureWhoVisible()
                if not WhoFrameEditBox then error("WhoFrameEditBox=nil") end
                WhoFrameEditBox:SetText(query)
                local fn = WhoFrameEditBox.GetScript
                    and WhoFrameEditBox:GetScript("OnEnterPressed")
                if not fn then error("OnEnterPressed=nil") end
                fn(WhoFrameEditBox)
            end)
        elseif path == "button" then
            ok, err = pcall(function()
                WhoPress(query)
            end)
        else
            ok, err = pcall(function()
                if not (C_FriendList and C_FriendList.SendWho) then error("C_FriendList.SendWho=nil") end
                C_FriendList.SendWho(query)
            end)
        end
        if ok then
            lastWhoSent = time()
            return true, path
        end
        errs[#errs + 1] = path .. "(" .. tostring(err):sub(1, 50) .. ")"
    end
    return false, table.concat(errs, "; ")
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

-- Токен зонового фильтра /who зависит от локали клиента:
-- enUS — z-"Zone", ruRU — з-"Зона" (кириллица!). С латинским z на RU-клиенте
-- сервер молча дропает запрос — именно поэтому зоновые сканы не работали.
local IS_RU = (GetLocale() == "ruRU")
-- Токены фильтров /who ЛОКАЛИЗОВАНЫ В КАЖДОЙ локали: RU — з-/к-/р-,
-- EN — z-/c-/r-, zhCN — свои иероглифы. Клиент хранит их в глобалах
-- WHO_TAG_ZONE / WHO_TAG_CLASS / WHO_TAG_RACE (GlobalStrings) — читаем
-- оттуда, это покрывает любой язык. Фолбэк — таблица по локали.
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

-- локализованные имена рас для фильтра р-"раса" (в языке клиента)
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

-- Локализованные имена рас для фильтра р-"раса": стандартные + выученные
-- кастомные (Skyborne и пр.) из db.learn
-- faction ~= nil → отсекаем расы чужой фракции: /who на Camelot отдаёт
-- только фракцию запрашивающего персонажа, запросы чужих рас всегда пусты
local function RaceFilterNames(db, faction)
    local names = {}
    local function want(raceFile)
        if not faction then return true end
        local rf = (db and db.learn and db.learn.raceFaction and db.learn.raceFaction[raceFile])
            or RACE_FACTION[raceFile]
        return rf == nil or rf == faction
    end
    -- таблица есть только для ru/en; на других локалях (zhCN и пр.)
    -- работают только выученные расы (самообучение из таргетов)
    local locTable = RACE_BY_LOCALE[GetLocale()]
    if locTable then
        for raceFile, locName in pairs(locTable) do
            if want(raceFile) then names[locName] = true end
        end
    end
    if db and db.learn and db.learn.raceLoc2File then
        for locName, raceFile in pairs(db.learn.raceLoc2File) do
            if want(raceFile) then names[locName] = true end
        end
    end
    return names
end

-- Полный послойный скан зоны: очередь диапазонов уровней с паузой WHO_GAP.
local whoPumpScheduled = false

local function FinishZoneScan(reason)
    if not whoScan then return end
    local s = whoScan
    whoScan = nil
    whoQueue = {}
    -- прибираем за собой: окно Who запоминает последний запрос в поле ввода —
    -- очищаем, чтобы пользователь не видел «чужие» значения скана
    pcall(function()
        if WhoFrameEditBox then WhoFrameEditBox:SetText("") end
    end)
    HideWhoFrame()
    D(("/who %s: scan done%s — queries %d, found %d, new %d"):format(
        s.zone, reason and (" (" .. reason .. ")") or "", s.sent, s.results, s.added))
end

-- ловим анти-бот сообщение сервера («Интересная операция, связанная с модификацией»):
-- канал прихода непредсказуем — UI_ERROR_MESSAGE или системный чат.
-- Пауза хранится в db (переживает /reload).
local function CheckWhoThrottle(msg)
    if type(msg) ~= "string" then return false end
    local db = GetDB()
    if msg:find("[Пп]ерац") or msg:find("[Мм]одификац") then
        -- жёсткий антибот («Интересная операция…»): пауза 5 минут, стоп скана
        db.debug.whoThrottled = (db.debug.whoThrottled or 0) + 1
        db.debug.lastErrorMsg = msg:sub(1, 120)
        db.whoPauseUntil = time() + 300
        lastWhoSent = time()
        if whoScan then FinishZoneScan("stopped: server throttles /who") end
        P(L("WHO_THROTTLED"))
        return true
    end
    if msg:find("[Пп]одожд") then
        -- мягкий кулдаун команды (пара секунд) — отмечаем, скан не останавливаем
        db.debug.whoSoft = (db.debug.whoSoft or 0) + 1
        db.debug.lastErrorMsg = msg:sub(1, 120)
        lastWhoSent = time()
        return true
    end
    return false
end

local function WhoPauseLeft()
    local left = (GetDB().whoPauseUntil or 0) - time()
    return left > 0 and left or 0
end

-- диагностика: логируем последние системные сообщения/ошибки в debug,
-- чтобы поймать точный текст и канал серверного антибот-сообщения
local function LogSysMsg(chan, msg)
    if type(msg) ~= "string" or msg == "" then return end
    local db = GetDB()
    db.debug.msgLog = db.debug.msgLog or {}
    local log = db.debug.msgLog
    log[#log + 1] = chan .. "|" .. msg:sub(1, 220)
    if #log > 10 then table.remove(log, 1) end
end

local function PumpWhoQueue()
    if whoPumpScheduled then return end
    whoPumpScheduled = true
    -- suggest: следующий запрос сразу после клика пользователя (1.5с),
    -- программный скан — антитроттл-пауза 45-75с
    local delay = (whoScan and whoScan.suggest) and 1.5 or (WHO_GAP + math.random(0, 30))
    C_Timer.After(delay, function()
        whoPumpScheduled = false
        if not whoScan then return end
        local q = table.remove(whoQueue, 1)
        if not q then
            FinishZoneScan()
            return
        end
        whoScan.current = q
        -- запрос БЕЗ зонового фильтра (сервер дропает z-…), но с опциональным
        -- фильтром-срезом (к-"класс" / р-"раса") + диапазон уровней
        local query = q.base and ("%s %d-%d"):format(q.base, q.lo, q.hi)
            or ("%d-%d"):format(q.lo, q.hi)
        if whoScan.suggest then
            -- расширенный режим (70291: программный who мёртв): аддон вписывает
            -- запрос в поле, пользователь жмёт лупу — аппаратный клик единственное,
            -- на что отвечает сервер. Ретраи бессмысленны: ответ придёт от клика.
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
        -- попытка 1 = первый путь (enter); ретраи сторожа сдвигают ротацию
        local ok, err = WhoSendRaw(query, (q.retries or 0) + 1)
        if ok then
            whoScan.sent = whoScan.sent + 1
            GetDB().debug.whoSent = (GetDB().debug.whoSent or 0) + 1
            D(("/who %s → waiting for reply… (%s)"):format(query, tostring(err)))
            -- сторож: ответ не пришёл за 15 сек — сервер дропает часть запросов
            -- молча (пропускает ~1-2 в минуту). Диапазон не теряем: повтор до 3 раз.
            C_Timer.After(15, function()
                if whoScan and whoScan.current == q and not q.answered then
                    q.retries = (q.retries or 0) + 1
                    if q.retries <= 3 then
                        table.insert(whoQueue, q)
                        D(("/who %s: no reply, retrying later (%d/3)"):format(query, q.retries))
                    else
                        D(("/who %s: no reply after 3 attempts — skipping"):format(query))
                    end
                    PumpWhoQueue()
                end
            end)
        else
            GetDB().debug.whoErr = (GetDB().debug.whoErr or 0) + 1
            FinishZoneScan("error: " .. tostring(err))
        end
    end)
end

local function StartZoneScan(zone, manual, mode, suggest)
    local db = GetDB()
    mode = mode or "level"
    if whoScan then
        return false, L("ERR_SCAN_RUNNING"):format(whoScan.zone)
    end
    if WhoPauseLeft() > 0 then
        return false, L("ERR_THROTTLE_PAUSE"):format(WhoPauseLeft())
    end
    whoQueue = {}
    local ml = MaxLevel()
    if mode == "class" then
        -- срез по классам: к-"маг" 1-80 (при лимите 50 — берём как есть)
        for _, locName in pairs(LOCALIZED_CLASS_NAMES_MALE or {}) do
            table.insert(whoQueue, { base = WHO_TOKEN_CLASS .. "\"" .. locName .. "\"", lo = 1, hi = ml })
        end
    elseif mode == "race" then
        -- срез по расам: р-"орк" 1-80; кастомные расы — из обученной таблицы
        for locName in pairs(RaceFilterNames(db, PlayerFaction())) do
            table.insert(whoQueue, { base = WHO_TOKEN_RACE .. "\"" .. locName .. "\"", lo = 1, hi = ml })
        end
    else
        -- стартовый широкий запрос от 1 уровня: на Camelot переполнен даже
        -- 1-1, узкие уровневые сетки от лимита50 всё равно не спасают
        table.insert(whoQueue, { lo = 1, hi = ml })
    end
    if #whoQueue == 0 then
        return false, L("ERR_QUEUE_EMPTY")
    end
    whoScan = { zone = zone, mode = mode, sent = 0, results = 0, added = 0, started = time(),
        suggest = suggest or nil }
    local fac = PlayerFaction()
    if fac then
        P(L("WHO_FACTION_COVER"):format(fac == "Alliance" and L("ALLIANCE") or L("HORDE")))
    end
    PumpWhoQueue()
    return true, L("QUERIES_FMT"):format(#whoQueue)
end

local function HandleWhoList()
    local db = GetDB()
    if not C_FriendList or not C_FriendList.GetNumWhoResults then return end
    local okN, num = pcall(C_FriendList.GetNumWhoResults)
    if not okN or not num then return end
    db.debug.whoResults = num
    local added = 0
    local x, y = PlayerXY()
    local ownZone = PlayerZone()
    local ownZoneId = PlayerZoneId()
    for i = 1, num do
        local okI, info = pcall(C_FriendList.GetWhoInfo, i)
        if okI and info and info.fullName then
            -- разовый дамп сырых полей /who-записи в debug (диагностика полей беты)
            if not db.debug.whoSample then
                local parts = {}
                for k, v in pairs(info) do parts[#parts + 1] = tostring(k) .. "=" .. tostring(v) end
                db.debug.whoSample = table.concat(parts, "; ")
            end
            local name = info.fullName:match("^([^%-]+)%-") or info.fullName
            local realm = PlayerRealm()  -- суффикс после дефиса ненадёжен; реалм = текущий
            -- класс: в бете есть готовое поле filename (MAGE); fallback — маппинг локали
            local classFile = info.filename or ClassFileFromLocalized(info.classStr)
            -- раса: из обученной таблицы, затем классический маппинг
            local raceLoc = info.raceStr
            local raceFile = (db.learn and db.learn.raceLoc2File and db.learn.raceLoc2File[raceLoc or ""])
                or RACE_LOCALE[raceLoc or ""]
            local faction = nil
            if raceFile then
                faction = (db.learn and db.learn.raceFaction and db.learn.raceFaction[raceFile])
                    or RACE_FACTION[raceFile]
            end
            -- зона игрока — из ответа /who (info.area), не наша текущая!
            -- zoneId известен только если зона совпала с нашей (id у чужих зон API не даёт)
            local zone = info.area or ownZone
            local zoneId = (zone == ownZone) and ownZoneId or nil
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
                silent = true,   -- /who зона может дать десятки игроков — не спамим чат
            }) then
                added = added + 1
            end
        end
    end
    db.debug.whoAdded = (db.debug.whoAdded or 0) + added
    -- прячем окно Who только после своего скана, с человеческой задержкой
    -- (мгновенное скрытие после каждого ответа — паттерн бота для античита);
    -- в suggest-режиме окно не трогаем — пользователь кликает по нему лупу
    if whoScan and whoScan.suggest then
        -- окно оставляем открытым
    elseif whoScan or (time() - (lastWhoSent or 0) < 60) then
        C_Timer.After(1.5 + math.random() * 3, HideWhoFrame)
    end

    if whoScan then
        -- ответ на запрос послойного скана
        local q = whoScan.current
        if q then q.answered = true end
        whoScan.results = whoScan.results + num
        whoScan.added = whoScan.added + added
        if num >= WHO_CAP and q then
            -- лимит 50: широкий ответ режем по КЛАССАМ (по решению
            -- пользователя: уровневое дробление бесполезно — переполнен
            -- даже 1-1); классовый срез берём как есть, не дробим
            if not (q.base and q.base:find(WHO_TOKEN_CLASS, 1, true)) then
                local sub = 0
                for _, locName in pairs(LOCALIZED_CLASS_NAMES_MALE or {}) do
                    table.insert(whoQueue, 1, { base = WHO_TOKEN_CLASS .. "\"" .. locName .. "\"", lo = q.lo, hi = q.hi })
                    sub = sub + 1
                end
                D(("/who: %d (cap) — splitting %d-%d into %d class slices"):format(num, q.lo, q.hi, sub))
            else
                -- 10.10.2026: сервер ИГНОРИРУЕТ диапазон уровней в /who
                -- (к-"Друид" 51-60 отдал 50 при капе 30 и нуле игроков >30
                -- в базе из 8800) — резать по уровням бессмысленно,
                -- класс — последний рабочий фильтр. Дальше не дробим.
                D(("/who: %d (cap) — %s overflowed; server ignores level ranges, taking what we get"):format(num, q.base or "?"))
            end
        end
        PumpWhoQueue()
    else
        -- ответ на одиночный общий запрос
        if added > 0 then
            D(("/who %s: list %d, new %d"):format(db.debug.whoZone or "?", num, added))
        end
        -- автозапуск программного скана УБРАН (1.5.0): с билда 70291 программный
        -- /who мёртв (hardware-гейт) — вместо него предлагаем расширенный режим
        if num >= WHO_CAP then
            D(("/who: full reply (%d) — more data exists. /nspy suggest types queries, you click search"):format(num))
        end
    end
end

-- Плашки: nameplateShowEnemies/ShowAll есть в бете, nameplateShowFriends — нет
-- (GetCVar возвращает nil). Несуществующие CVar'ы не трогаем вообще.
local NAMEPLATE_CVARS = { "nameplateShowFriends", "nameplateShowEnemies", "nameplateShowAll" }

local function EnsureNameplates(db, announceFix)
    for _, cvar in ipairs(NAMEPLATE_CVARS) do
        local ok, value = pcall(GetCVar, cvar)
        if not ok then
            db.debug.cvarErr = (db.debug.cvarErr or 0) + 1
        else
            db.debug["cv_" .. cvar] = tostring(value)
            if value ~= nil and value ~= "1" then
                local okS = pcall(SetCVar, cvar, "1")
                if okS then
                    local okR, after = pcall(GetCVar, cvar)
                    if okR then db.debug["cv_" .. cvar .. "_after"] = tostring(after) end
                    db.debug.nsfFixed = (db.debug.nsfFixed or 0) + 1
                    if announceFix then
                        P(L("CVAR_FIX"):format(cvar))
                    end
                end
            end
        end
    end
    -- обратная совместимость с debug-полем 1.1/1.2
    db.debug.nsf = db.debug.cv_nameplateShowFriends
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
    C_Timer.After(TICK_SECONDS, function()
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
            EnsureNameplates(db, false)
        end
        if (db.debug.ticks % (GUILD_REFRESH / TICK_SECONDS)) == 0 then
            RequestGuildRoster()
        end
        -- дайджест в кольцо раз в 5 мин (1.5.1): видно в SV, кто кормит базу
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
           "PLATE_ADDED events: %d, CVar: friends=%s enemies=%s all=%s (fixes %d), " ..
           "/who: sent %d, last list %d, new %d, who errors %d, scan/CVar errors %d/%d, " ..
           "tokens: %s%s%s (%s, locale %s)"):format(
        d.ticks or 0, age < 0 and 9999 or age,
        tostring(d.lastPlates or "?"), tostring(d.lastPlayers or "?"),
        d.addedEvents or 0,
        tostring(d.cv_nameplateShowFriends or "?"),
        tostring(d.cv_nameplateShowEnemies or "?"),
        tostring(d.cv_nameplateShowAll or "?"),
        d.nsfFixed or 0,
        d.whoSent or 0, d.whoResults or 0, d.whoAdded or 0, d.whoErr or 0,
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

local function BuildExportText()
    local db = GetDB()
    local lines = {
        "#name-realm|class|level|faction|zone|count|firstSeen|lastSeen|x,y|source",
    }
    for _, p in ipairs(SortedPlayers(db)) do
        lines[#lines + 1] = string.format(
            "%s-%s|%s|%s|%s|%s|%d|%s|%s|%s|%s",
            p.name or "?",
            p.realm or "?",
            p.class or "?",
            tostring(p.level or "?"),
            p.faction or "?",
            p.zone or "?",
            p.count or 1,
            p.firstSeen and date("%Y-%m-%d %H:%M", p.firstSeen) or "?",
            p.lastSeen and date("%Y-%m-%d %H:%M", p.lastSeen) or "?",
            (p.x and p.y) and string.format("%.4f,%.4f", p.x, p.y) or "?",
            p.source or "unit"
        )
    end
    return table.concat(lines, "\n")
end

-- ============ UI ============
-- Без GameFont-объектов: в кастомной бете они могут отсутствовать/быть пустыми
-- (окно рендерится, текст — нет). Шрифт ставим явно по файлу с fallback'ами.

local FONT_FILES = {
    -- свой шрифт с полной кириллицей (11.10.2026): клиентские TTF в бете
    -- запакованы в .slug-ресурсы и кириллицы НЕ содержат (EN-шрифты
    -- Forever) — весь русский текст окна был «квадратиками». Путь — от папки
    -- Interface/ (стандарт аддоновых шрифтов). Liberation Sans (OFL).
    "Interface\\AddOns\\NearbySpy\\NearbySpySans.ttf",
    "Fonts\\FRIZQT__.TTF",
    "Fonts\\ARIALN.TTF",
    "Fonts\\MORPHEUS.TTF",
    "Fonts\\SKURRI.TTF",
}

-- zhCN: Liberation Sans без CJK-глифов — на китайском клиенте сначала
-- штатные CJK-шрифты клиента, иначе иероглифы будут «квадратиками».
if GetLocale() == "zhCN" then
    table.insert(FONT_FILES, 1, "Fonts\\ARHei.TTF")
    table.insert(FONT_FILES, 2, "Fonts\\ARKai_T.TTF")
end

local function ApplyFont(fs, size, flags)
    for _, path in ipairs(FONT_FILES) do
        local ok, res = pcall(fs.SetFont, fs, path, size, flags or "")
        if ok and res then
            return true
        end
    end
    return false
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

-- Окно копирования: отдельное, чтобы красивый список не путался с сырьём
local copyWin, copyEdit

local function HideCopyWindow()
    if copyWin then
        if copyEdit then copyEdit:ClearFocus() end
        copyWin:Hide()
    end
end

local function BuildCopyWindow()
    copyWin = CreateFrame("Frame", "NearbySpyCopyWindow", UIParent)
    copyWin:SetSize(700, 480)
    copyWin:SetPoint("CENTER")
    copyWin:SetFrameStrata("TOOLTIP")
    copyWin:SetMovable(true)
    copyWin:EnableMouse(true)
    copyWin:RegisterForDrag("LeftButton")
    copyWin:SetScript("OnDragStart", copyWin.StartMoving)
    copyWin:SetScript("OnDragStop", copyWin.StopMovingOrSizing)
    copyWin:EnableKeyboard(true)
    copyWin:SetScript("OnKeyDown", function(_, key)
        if key == "ESCAPE" then
            copyWin:SetPropagateKeyboardInput(false)
            HideCopyWindow()
        else
            copyWin:SetPropagateKeyboardInput(true)
        end
    end)

    local bg = copyWin:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.02, 0.02, 0.02, 0.95)

    local title = NewText(copyWin, 16)
    title:SetPoint("TOPLEFT", 14, -14)
    title:SetText(L("EXPORT_TITLE"))

    local okClose, close = pcall(CreateFrame, "Button", nil, copyWin, "UIPanelCloseButton")
    if okClose and close then
        close:SetPoint("TOPRIGHT", -6, -6)
        close:SetScript("OnClick", HideCopyWindow)
    end

    local hint = NewText(copyWin, 11, 0.7, 0.7, 0.7)
    hint:SetPoint("BOTTOMLEFT", 14, 10)
    hint:SetText(L("EXPORT_HINT"))

    local okSf, sf = pcall(CreateFrame, "ScrollFrame", nil, copyWin, "UIPanelScrollFrameTemplate")
    if not okSf or not sf then
        sf = CreateFrame("ScrollFrame", nil, copyWin)
    end
    sf:SetPoint("TOPLEFT", 12, -44)
    sf:SetPoint("BOTTOMRIGHT", -30, 28)

    -- Без SetFocus()/HighlightText(): автозахват фокуса на Show ронял
    -- клиент (assert CSimpleEditBox code 11). Фокус ставится только
    -- по клику пользователя внутри EditBox (EnableMouse=true).
    local eb = CreateFrame("EditBox", nil, sf)
    eb:SetMultiLine(true)
    ApplyFont(eb, 12)
    eb:SetTextColor(1, 1, 1, 1)
    eb:SetAutoFocus(false)
    eb:SetWidth(660)
    eb:EnableMouse(true)
    eb:SetScript("OnEscapePressed", HideCopyWindow)
    sf:SetScrollChild(eb)
    copyEdit = eb

    copyWin:SetScript("OnShow", function()
        copyEdit:SetText(BuildExportText())
    end)
end

local function ShowCopyWindow()
    local ok, err = pcall(function()
        if not copyWin then
            BuildCopyWindow()
        end
        copyEdit:SetText(BuildExportText())
        copyWin:Show()
    end)
    if not ok then
        P(L("ERR_EXPORT") .. tostring(err))
    end
end

-- Главное окно: красивый список
local win, winList, winSummary, winSummary2, winSummary3, winSummary4
local levelBars, classRows, chartLabel, chartFrame  -- графики окна
local rowPool = {}

local function HideWindow()
    if win then
        win:Hide()
    end
end

local function MakeRow(parent, index)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(600, 16)
    row.name = NewText(row, 12)
    row.name:SetPoint("LEFT", 4, 0)
    row.name:SetWidth(150)
    row.name:SetJustifyH("LEFT")
    row.mid = NewText(row, 12)
    row.mid:SetPoint("LEFT", row.name, "RIGHT", 8, 0)
    row.mid:SetWidth(180)
    row.mid:SetJustifyH("LEFT")
    row.right = NewText(row, 11, 0.65, 0.65, 0.65)
    row.right:SetPoint("LEFT", row.mid, "RIGHT", 8, 0)
    row.right:SetWidth(250)
    row.right:SetJustifyH("LEFT")
    rowPool[index] = row
    return row
end

-- Относительное время для правой колонки: свежесть читается с одного
-- взгляда («3 мин назад»), старое — короткой датой. Lua 5.1: только math.floor.
local function TimeAgo(ts)
    if not ts or ts == 0 then return "?" end
    local d = time() - ts
    if d < 60 then return L("TIME_NOW") end
    if d < 3600 then return L("TIME_MIN"):format(math.floor(d / 60)) end
    if d < 86400 then return L("TIME_HOUR"):format(math.floor(d / 3600)) end
    return date("%d.%m", ts)
end

local function RefreshRows()
    if not winList then return 0 end
    for _, row in ipairs(rowPool) do row:Hide() end

    local db = GetDB()
    local list = SortedPlayers(db)
    local n = math.min(#list, MAX_ROWS)
    local y = -6

    for i = 1, n do
        local p = list[i]
        local row = rowPool[i] or MakeRow(winList, i)
        row:SetPoint("TOPLEFT", 0, y)
        y = y - 18

        row.name:SetText(p.name or "?")
        row.name:SetTextColor(ClassColorRGB(p.class))

        local classStr = p.classLoc or p.class or "?"
        local lvl = p.level and (L("LVL_PREFIX") .. p.level) or "?"
        local fac = (p.faction == "Horde" and L("HORDE")) or (p.faction == "Alliance" and L("ALLIANCE")) or "?"
        row.mid:SetText(("%s, %s · %s"):format(classStr, lvl, fac))
        if p.faction == "Horde" then
            row.mid:SetTextColor(1, 0.3, 0.3)
        elseif p.faction == "Alliance" then
            row.mid:SetTextColor(0.35, 0.55, 1)
        else
            row.mid:SetTextColor(0.8, 0.8, 0.8)
        end

        local realm = p.realm and ("(" .. p.realm .. ") ") or ""
        local zone = p.zone or "?"
        local cnt = p.count or 1
        local when = TimeAgo(p.lastSeen)
        row.right:SetText(("%s%s · x%d · %s"):format(realm, zone, cnt, when))

        row:Show()
    end
    winList:SetHeight(math.max(1, n * 18 + 12))
    return n
end

-- Сводка окна: всё считается по db.players за один проход — свежесть
-- (аналог «рядом сейчас» у Spy), срез уровней и топ-классов (как счётчики
-- CensusPlus), источники из debug.src — сразу видно, кто реально кормит базу.
local function WinStats()
    local db = GetDB()
    local now = time()
    local f5, f15, f60 = 0, 0, 0
    local lmin, lmax, lsum, ln = nil, nil, 0, 0
    local cls = {}
    for _, p in pairs(db.players) do
        local age = now - (p.lastSeen or 0)
        if age <= 300 then f5 = f5 + 1 end
        if age <= 900 then f15 = f15 + 1 end
        if age <= 3600 then f60 = f60 + 1 end
        local lv = tonumber(p.level)
        if lv and lv > 0 and lv <= 60 then
            if not lmin or lv < lmin then lmin = lv end
            if not lmax or lv > lmax then lmax = lv end
            lsum = lsum + lv
            ln = ln + 1
        end
        local c = (p.classLoc and p.classLoc ~= "") and p.classLoc or p.class
        if c and c ~= "" then cls[c] = (cls[c] or 0) + 1 end
    end
    local top = {}
    for k, v in pairs(cls) do top[#top + 1] = { k = k, v = v } end
    table.sort(top, function(a, b) return a.v > b.v end)
    return { f5 = f5, f15 = f15, f60 = f60, lmin = lmin, lmax = lmax,
             lavg = (ln > 0) and math.floor(lsum / ln) or nil, top = top }
end

-- Строка «кто кормит»: фиксированный порядок важных источников (unit — мир и
-- группа через Record, guild, chat, who), всё прочее с ненулевым счётчиком
-- добавляется скопом — новые источники не потеряются.
local function SrcLine()
    local s = (GetDB().debug and GetDB().debug.src) or {}
    local parts, shown = {}, {}
    for _, k in ipairs({ "unit", "guild", "chat", "who" }) do
        parts[#parts + 1] = k .. " " .. (s[k] or 0)
        shown[k] = true
    end
    for k, v in pairs(s) do
        if not shown[k] and type(v) == "number" and v > 0 then
            parts[#parts + 1] = tostring(k) .. " " .. v
        end
    end
    return L("SRC_LINE") .. table.concat(parts, " · ")
end

-- Заполнение окна: вынесено из OnShow и вызывается ещё и из
-- ShowWindow. Пустое окно при видимом тайтле (только title рисуется) = OnShow
-- в этой кастомной бете1.60 не стреляет при win:Show() — двойной вызов лечит;
-- дубли безопасен (идемпотентный SetText).
local function UpdateWindowUI()
    local ok, err = pcall(function()
        winSummary:SetText(L("WIN_TOTAL"):format(
            CountPlayers(), newThisSession))
        local st = WinStats()
        winSummary2:SetText(L("WIN_FRESH"):format(
            st.f5, st.f15, st.f60))
        -- демо-строка без топа классов: топ теперь графиком-барами ниже
        local demo = ""
        if st.lmin then
            demo = L("WIN_DEMO"):format(st.lmin, st.lmax, st.lavg)
        end
        winSummary3:SetText(demo ~= "" and demo or "—")
        winSummary4:SetText(SrcLine())
        -- гистограмма уровней: столбики 1..60 из db.players. Клиентская
        -- бета без графического API (нет ни линий, ни шейдеров) — рисуем
        -- цветными текстурами, как CensusPlus. maxL — ярче остальных.
        local lvlCount, lvlN, lvlSum, maxC, maxL = {}, 0, 0, 0, 0
        for _, p in pairs(db.players) do
            local lv = tonumber(p.level)
            if lv and lv >= 1 and lv <= 60 then
                lvlN = lvlN + 1
                lvlSum = lvlSum + lv
                local c = (lvlCount[lv] or 0) + 1
                lvlCount[lv] = c
                if c > maxC then maxC, maxL = c, lv end
            end
        end
        for i = 1, 60 do
            local bar = levelBars[i]
            local c = lvlCount[i] or 0
            if maxC > 0 then
                bar:SetHeight(math.max(1, math.floor(LEVEL_CHART_H * c / maxC + 0.5)))
                if i == maxL then
                    bar:SetColorTexture(0.5, 1, 0.55, 1)
                else
                    bar:SetColorTexture(0.3, 0.62, 0.36, 0.9)
                end
            else
                bar:SetHeight(1)
            end
        end
        if maxC > 0 then
            chartLabel:SetText(L("CHART_LABEL"):format(
                lvlN, maxC, maxL, lvlSum / lvlN))
        else
            chartLabel:SetText(L("CHART_EMPTY"))
        end
        -- топ-3 класса горизонтальными барами (top уже посчитан WinStats)
        for i = 1, CLASS_BARS do
            local row = classRows[i]
            local t = st.top[i]
            if t and st.top[1] and st.top[1].v > 0 then
                row:Show()
                row.label:SetText(t.k)
                row.value:SetText(t.v)
                row.fill:SetWidth(math.max(1, math.floor(470 * t.v / st.top[1].v + 0.5)))
            else
                row:Hide()
            end
        end
        RefreshRows()
    end)
    if not ok then
        P(L("ERR_LIST") .. tostring(err))
    end
end

local function BuildWindow()
    win = CreateFrame("Frame", "NearbySpyWindow", UIParent)
    win:SetSize(680, 540)
    win:SetPoint("CENTER")
    win:SetFrameStrata("DIALOG")
    win:SetMovable(true)
    win:EnableMouse(true)
    win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", win.StartMoving)
    win:SetScript("OnDragStop", win.StopMovingOrSizing)
    win:EnableKeyboard(true)
    win:SetScript("OnKeyDown", function(_, key)
        if key == "ESCAPE" then
            win:SetPropagateKeyboardInput(false)
            HideWindow()
        else
            win:SetPropagateKeyboardInput(true)
        end
    end)

    -- ручная рамка: фон, верхний бордер (шаблонов в кастомной бете может не быть)
    local bg = win:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.05, 0.05, 0.08, 0.95)
    local edge = win:CreateTexture(nil, "OVERLAY")
    edge:SetPoint("TOPLEFT")
    edge:SetPoint("TOPRIGHT")
    edge:SetHeight(2)
    edge:SetColorTexture(0.4, 0.7, 0.4, 0.8)

    local title = NewText(win, 16, 0.4, 1, 0.6)
    title:SetPoint("TOPLEFT", 14, -14)
    title:SetText("NearbySpy")

    local okClose, close = pcall(CreateFrame, "Button", nil, win, "UIPanelCloseButton")
    if okClose and close then
        close:SetPoint("TOPRIGHT", -6, -6)
        close:SetScript("OnClick", HideWindow)
    else
        local xbtn = CreateFrame("Button", nil, win)
        xbtn:SetSize(24, 24)
        xbtn:SetPoint("TOPRIGHT", -8, -8)
        local xt = NewText(xbtn, 16, 1, 0.4, 0.4)
        xt:SetPoint("CENTER")
        xt:SetText("X")
        xbtn:SetScript("OnClick", HideWindow)
    end

    -- сводка: 4 строки (счётчики, свежесть, демо, источники)
    winSummary = NewText(win, 12, 0.9, 0.9, 0.9)
    winSummary:SetPoint("TOPLEFT", 20, -44)
    winSummary:SetJustifyH("LEFT")
    winSummary2 = NewText(win, 12, 0.65, 0.95, 0.65)  -- свежесть: живое — зеленоватое
    winSummary2:SetPoint("TOPLEFT", 20, -58)
    winSummary2:SetJustifyH("LEFT")
    winSummary3 = NewText(win, 12, 0.8, 0.8, 0.8)     -- демо-срез
    winSummary3:SetPoint("TOPLEFT", 20, -72)
    winSummary3:SetJustifyH("LEFT")
    winSummary4 = NewText(win, 12, 0.6, 0.6, 0.65)    -- источники
    winSummary4:SetPoint("TOPLEFT", 20, -86)
    winSummary4:SetJustifyH("LEFT")

    -- графики: пул создаётся один раз, в UpdateWindowUI пересчитываются
    -- только высоты/цвета/подписи. (1) гистограмма уровней 1–60 — столбики
    -- снизу вверх от оси; (2) топ-3 класса горизонтальными барами.
    chartLabel = NewText(win, 10, 0.55, 0.65, 0.55)
    chartLabel:SetPoint("TOPLEFT", 22, -100)
    chartFrame = CreateFrame("Frame", nil, win)
    chartFrame:SetPoint("TOPLEFT", 20, -110)
    chartFrame:SetSize(620, LEVEL_CHART_H + 2)
    levelBars = {}
    for i = 1, 60 do
        local bar = chartFrame:CreateTexture(nil, "ARTWORK")
        bar:SetColorTexture(0.3, 0.62, 0.36, 0.9)
        bar:SetPoint("BOTTOMLEFT", 2 + (i - 1) * 10, 1)
        bar:SetWidth(9)
        bar:SetHeight(1)
        levelBars[i] = bar
    end
    local axis = chartFrame:CreateTexture(nil, "ARTWORK")
    axis:SetColorTexture(0.4, 0.45, 0.4, 0.7)
    axis:SetPoint("BOTTOMLEFT", 0, 0)
    axis:SetSize(602, 1)
    classRows = {}
    for i = 1, CLASS_BARS do
        local row = CreateFrame("Frame", nil, win)
        row:SetSize(620, 11)
        row:SetPoint("TOPLEFT", 22, -176 - (i - 1) * 14)
        local fill = row:CreateTexture(nil, "ARTWORK")
        fill:SetColorTexture(0.35, 0.5, 0.95, 0.85)
        fill:SetPoint("LEFT", 112, 0)
        fill:SetHeight(10)
        fill:SetWidth(1)
        local lbl = NewText(row, 10, 0.85, 0.85, 0.9)
        lbl:SetPoint("LEFT", 2, 0)
        lbl:SetJustifyH("LEFT")
        local val = NewText(row, 10, 1, 1, 1)
        val:SetPoint("LEFT", 118, 0)
        row.fill = fill
        row.label = lbl
        row.value = val
        row:Hide()
        classRows[i] = row
    end

    -- кнопка копирования
    local okBtn, copyBtn = pcall(CreateFrame, "Button", nil, win, "UIPanelButtonTemplate")
    if okBtn and copyBtn then
        copyBtn:SetSize(120, 22)
        copyBtn:SetPoint("BOTTOMRIGHT", -14, 8)
        copyBtn:SetText(L("BTN_COPY"))
        copyBtn:SetScript("OnClick", ShowCopyWindow)
    else
        copyBtn = CreateFrame("Button", nil, win)
        copyBtn:SetSize(120, 22)
        copyBtn:SetPoint("BOTTOMRIGHT", -14, 8)
        local bt = NewText(copyBtn, 12, 0.4, 1, 0.6)
        bt:SetPoint("CENTER")
        bt:SetText(L("BTN_COPY"))
        copyBtn:SetScript("OnClick", ShowCopyWindow)
    end

    local hint = NewText(win, 10, 0.5, 0.5, 0.5)
    hint:SetPoint("BOTTOMLEFT", 14, 12)
    hint:SetText(L("WIN_HINT"))

    -- список
    local okSf, sf = pcall(CreateFrame, "ScrollFrame", nil, win, "UIPanelScrollFrameTemplate")
    if not okSf or not sf then
        sf = CreateFrame("ScrollFrame", nil, win)
    end
    sf:SetPoint("TOPLEFT", 20, -220)
    sf:SetPoint("BOTTOMRIGHT", -34, 36)
    local content = CreateFrame("Frame", nil, sf)
    content:SetSize(600, 1)
    sf:SetScrollChild(content)
    winList = content

    win:SetScript("OnShow", UpdateWindowUI)
end

local function ShowWindow()
    local ok, err = pcall(function()
        if not win then
            BuildWindow()
        end
        win:Show()
        UpdateWindowUI()  -- OnShow в этой бете не стреляет (см. выше) — дубль
    end)
    if not ok then
        P(L("ERR_WINDOW") .. tostring(err))
    end
end

-- Настоящая кнопка поиска в окне Who: из дерева 08.10 — анонимная (без имени)
-- прямая дочерняя кнопка LFGWhoListFrame с OnClick и пустым текстом, рядом с
-- полем WhoFrameEditBox (единственная такая; «Фильтр» отсекается по тексту,
-- крестик очистки — ребёнок поля, а не окна).
function WhoSearchButton()
    local f = LFGWhoListFrame
    if not f or not f.GetChildren then return nil end
    local hidden = nil
    for i = 1, select("#", f:GetChildren()) do
        local c = select(i, f:GetChildren())
        if c and c.IsObjectType and c:IsObjectType("Button") then
            local onc = c.GetScript and c:GetScript("OnClick") ~= nil
            local txt = (c.GetText and c:GetText()) or ""
            if onc and txt == "" then
                if c.IsShown and c:IsShown() then return c end
                hidden = hidden or c
            end
        end
    end
    return hidden
end

SLASH_NEARBYSPY1 = "/nearbyspy"
SLASH_NEARBYSPY2 = "/nspy"
SlashCmdList["NEARBYSPY"] = function(msg)
    msg = string.lower((msg or ""):gsub("^%s+", ""):gsub("%s+$", ""))
    local db = GetDB()
    if msg == "" or msg == "show" then
        ShowWindow()
    elseif msg == "export" then
        ShowCopyWindow()
    elseif msg == "who" or msg == "whoclass" or msg == "whorace" then
        local mode = ({ who = "level", whoclass = "class", whorace = "race" })[msg]
        local modeL = ({ level = L("MODE_LEVEL"), class = L("MODE_CLASS"), race = L("MODE_RACE") })[mode]
        local ok, info = StartZoneScan(PlayerZone() or "?", true, mode)
        if ok then
            P(L("SCAN_STARTED"):format(modeL, info))
        else
            P(L("SCAN_FAILED") .. info)
        end
    elseif msg == "whostop" then
        if whoScan then
            FinishZoneScan("stopped manually")
        else
            P(L("SCAN_NOT_RUNNING"))
        end
    elseif msg == "suggest" then
        -- расширенный режим (70291): очередь скана вписывается в поле who по
        -- одному запросу, пользователь жмёт лупу; ответ двигает очередь дальше
        if whoScan and whoScan.suggest then
            FinishZoneScan("suggest off")
        elseif whoScan then
            P(L("SUGGEST_PROG_BLOCK"))
        else
            -- сразу классовые срезы: широкий 1-60 бессмысленен — на этом сервере
            -- переполнен даже 1-1, первый клик всегда уходит в лимит 50
            local okS, infoS = StartZoneScan(PlayerZone() or "?", true, "class", true)
            if okS then
                P(L("SUGGEST_STARTED"))
            else
                P(L("SUGGEST_FAILED") .. tostring(infoS))
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
        -- режим дебага: вкл → логи (дайджесты, прогресс скана, блокировки
        -- гейта) печатаются в чат; выкл → скрытный режим, в чате только ответы
        -- на команды, анонсы и ошибки. Всё пишется в SV-кольцо в обоих режимах.
        db.debugMode = not db.debugMode
        P(db.debugMode and L("DEBUG_ON") or L("DEBUG_OFF"))
    elseif msg == "reset" then
        db.players = {}
        newThisSession = 0
        P(L("DB_CLEARED"))
    else
        P(L("CMDS"))
    end
end

-- ============ чат как источник имён ============
-- SAY/YELL/CHANNEL отдают имя говорящего без класса/уровня/зоны — пассивный
-- дозаполнитель базы: городские каналы (трейд, локальные) показывают тех, до
-- кого nameplate-скан и ростеры не доходят. Поля класса/уровня/зоны НЕ
-- передаём (nil, не ""): UpsertPlayer затирает только присутствующие ключи,
-- так что данные известных игроков не обнуляются; у новых чат-записей пустые
-- поля и так отфильтрованы на пути (парсер -> "", сайт: class<>'' и level>0).
-- Сигнатура (wowpedia + warcraft.wiki, retail и classic-перезапуск совпадают):
--   text, playerName, languageName, channelName, playerName2, specialFlags, ...
-- то есть спикер — 2-й аргумент события (после имени события). Порядок в
-- бета-клиенте не гарантирован — первые 15 событий пишем целиком в
-- db.debug.chatSample, после первой игры сверяем по dump и правим select().
local chatFrame = CreateFrame("Frame")
local chatSampled = 0
local CHAT_SAMPLE_MAX = 15
chatFrame:RegisterEvent("CHAT_MSG_SAY")
chatFrame:RegisterEvent("CHAT_MSG_YELL")
chatFrame:RegisterEvent("CHAT_MSG_CHANNEL")
chatFrame:SetScript("OnEvent", function(self, event, ...)
    -- весь разбор под pcall: если бета отдаёт имя как secret-строку (в комбате
    -- такие ловили через canaccessvalue), строковые операции уронили бы весь
    -- обработчик чата — сбор имён защищаем, падения видны через DbgErr.
    -- varargs передаём в pcall-лямбду ЯВНО (ev, ...): вложенная не-vararg
    -- функция не видит наружный `...` — Lua 5.1 (клиент) даёт ошибку компиляции
    -- «cannot use '...' outside a vararg function», luaparser это пропускал.
    local okP, errP = pcall(function(ev, ...)
        local speaker = select(2, ...)
        if type(speaker) ~= "string" or speaker == "" then return end
        local db = GetDB()
        -- debug-дамп первых событий: позиция спикера сверяется на живом клиенте
        if chatSampled < CHAT_SAMPLE_MAX then
            chatSampled = chatSampled + 1
            db.debug = db.debug or {}
            db.debug.chatSample = db.debug.chatSample or {}
            local parts = {}
            for i = 1, 8 do
                parts[i] = i .. "=" .. tostring(select(i, ...) or "-")
            end
            db.debug.chatSample[#db.debug.chatSample + 1] =
                ev .. " | " .. table.concat(parts, " | ")
        end
        -- спикер: "Name" (свой реалм) или "Name-Realm" (кросс). В ванили имя
        -- игрока дефисов не содержит — первый "-" всегда разделитель реалма
        local name, realm = speaker, nil
        local dash = speaker:find("-", 1, true)
        if dash then
            name = speaker:sub(1, dash - 1)
            realm = speaker:sub(dash + 1)
        end
        if name == "" then return end
        realm = realm or PlayerRealm()
        UpsertPlayer(db, {
            key = name .. "-" .. realm, -- тот же формат ключа, что в Record()
            name = name,
            realm = realm,
            source = "chat",
            silent = true, -- не анонсировать чат-имена в чат даже при db.announce
        })
    end, event, ...)  -- varargs наружу: лямбда vararg (см. комментарий выше)
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
frame:RegisterEvent("ADDON_ACTION_BLOCKED")
frame:RegisterEvent("ADDON_ACTION_FORBIDDEN")
frame:RegisterEvent("MACRO_ACTION_BLOCKED")
frame:RegisterEvent("MACRO_ACTION_FORBIDDEN")
frame:RegisterEvent("LUA_WARNING")

frame:SetScript("OnEvent", function(self, event, arg1, arg2, arg3)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then
            GetDB()
        end
    elseif event == "PLAYER_LOGIN" then
        local db = GetDB()
        EnsureNameplates(db, true)
        ScheduleTick()
        P(L("STARTUP"):format(CountPlayers()))
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
        -- сервер троттлит /who — сигнатура события различается: (msg) или (errorType, msg)
        local sm = type(arg2) == "string" and arg2 or arg1
        LogSysMsg("err", sm)
        if not CheckWhoThrottle(arg2) then CheckWhoThrottle(arg1) end
    elseif event == "UI_INFO_MESSAGE" then
        local sm = type(arg2) == "string" and arg2 or arg1
        LogSysMsg("info", sm)
        if not CheckWhoThrottle(arg2) then CheckWhoThrottle(arg1) end
    elseif event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN"
        or event == "MACRO_ACTION_BLOCKED" or event == "MACRO_ACTION_FORBIDDEN" then
        -- защитный гейт клиента (70291+): arg1 = модификация, arg2 = функция
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
    elseif event == "CHAT_MSG_SYSTEM" then
        -- кастомные серверные сообщения («Интересная операция…») приходят системным чатом
        LogSysMsg("sys", arg1)
        CheckWhoThrottle(arg1)
    end
end)