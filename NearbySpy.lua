--[[
    NearbySpy 1.3.1
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
              count | announce | debug | peer | reset

]]

local ADDON_NAME = ...

local PREFIX = "|cff33ff99NearbySpy|r: "
local REAP_SECONDS = 600      -- an encounter after a longer pause = a new "visit" in the counter
local TICK_SECONDS = 2
local WHO_CAP = 50            -- server limit of rows in a /who reply
local MAX_ROWS = 500          -- how many rows we draw in the list (guard against giant databases)
local GROUP_TROTTLE = 10      -- GROUP_ROSTER_UPDATE is spammy — pass no more often than this, sec
local GUILD_REFRESH = 600     -- re-request the guild roster every 10 min
local LEVEL_CHART_H = 56      -- window charts: level bar height, px
local CLASS_BARS = 3          -- how many top-class bars we draw

-- ============ UI localization (enUS fallback, ruRU, zhCN) ============
-- Only user-facing strings (P/windows). Debug D() messages and
-- FinishZoneScan reasons are technical — kept in English outside the table.
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
        ERR_LIST = "list ERROR: ",
        ERR_WINDOW = "window ERROR: ",
        TIME_NOW = "just now", TIME_MIN = "%d min ago", TIME_HOUR = "%d h ago",
        SRC_LINE = "Sources: ",
        CHART_LABEL = "Levels 1-60: %d with a level; peak %d players at lvl %d; avg %.1f",
        CHART_EMPTY = "Levels 1-60: no data",
        WIN_HINT = "Esc - close; /nspy count - stats; /nspy who - zone scan",
        UI_SUBTITLE = "LIVE SERVER INTELLIGENCE",
        UI_DETECTED = "DETECTED", UI_ACTIVE5 = "ACTIVE < 5 MIN", UI_FACTIONS = "FACTIONS",
        UI_CLASSES = "CLASSES", UI_ALL = "All", UI_FRESH = "Fresh", UI_NEW = "New", UI_NEW_SHORT = "new",
        UI_PLAYER = "PLAYER", UI_PROFILE = "PROFILE", UI_ZONE = "ZONE", UI_CONTACT = "CONTACT",
        UI_FIRST = "First seen", UI_SOURCE = "Source", UI_ENCOUNTERS = "Encounters", UI_LIVE = "COLLECTING",
        SCAN_NOT_RUNNING = "no scan running",
        SUGGEST_STARTED = "suggest: typing queries into the who box — you only click the search button. Stop: /nspy suggest",
        SUGGEST_FAILED = "suggest did not start: ",
        COUNT = "total players: %d, new this session: %d, announcements: %s",
        ANNOUNCE_TOGGLE = "new player announcements: ",
        DEBUG_ON = "debug mode: on — logs to chat (digests, scan, who, gate blocks)",
        DEBUG_OFF = "debug mode: off — stealth mode, logs go only to the SV ring",
        DB_CLEARED = "encounter database cleared",
        QUERIES_FMT = "%d queries",
        STARTUP = "started, %d players in db. Commands: /nspy (suggest — assisted /who)",
        SVR_TITLE = "Server census", SVR_SNAPSHOT = "RealmPulse snapshot: %s", SVR_TOTAL = "PLAYERS",
        SVR_PRIME = "PRIME TIME (28 DAYS)", SVR_CLASSES = "CLASSES", SVR_ZONES = "TOP ZONES",
        SVR_PEAK = "Peak: %s %02d:00 - %d players",
        SVR_NODATA = "No data module found. Install NearbySpy_Data (datapack-latest release) next to NearbySpy.",
        SVR_STALE = "snapshot %d days old - update NearbySpy_Data",
        SVR_D1 = "Mon", SVR_D2 = "Tue", SVR_D3 = "Wed", SVR_D4 = "Thu", SVR_D5 = "Fri", SVR_D6 = "Sat", SVR_D7 = "Sun",
        HUB_STATUS = "%d records - peer %s - v%s",
        HUB_PLAYERS = "Players", HUB_PLAYERS_D = "encounter list",
        HUB_SERVER = "Server", HUB_SERVER_D = "realm census",
        HUB_HELP = "Help", HUB_HELP_D = "all commands",
        HUB_SETTINGS = "Settings", HUB_SETTINGS_D = "options and sharing",
        SET_PEER = "Peer sharing", SET_PEER_D = "Send new encounters to the nearbyspydata channel and receive from others",
        SET_AUTO = "Auto (%s)",
        SET_LANG = "Language", SET_LANG_D = "Addon interface language. Other windows update after /reload.",
        SET_TZ = "Heatmap timezone", SET_TZ_D = "The prime-time map in the server window is shown in this timezone; Auto = system clock.",
        SET_RELOAD = "Language changed; type /reload to rebuild all windows.",
        MINIMAP_TIP_L = "Left-click: menu", MINIMAP_TIP_R = "Right-click: player list",
        MM_ON = "minimap button shown", MM_OFF = "minimap button hidden",
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
        ERR_LIST = "列表错误: ",
        ERR_WINDOW = "窗口错误: ",
        TIME_NOW = "刚刚", TIME_MIN = "%d分钟前", TIME_HOUR = "%d小时前",
        SRC_LINE = "数据来源: ",
        CHART_LABEL = "等级 1-60: 有等级的%d名; %d级最多%d名玩家; 平均%.1f",
        CHART_EMPTY = "等级 1-60: 暂无数据",
        WIN_HINT = "Esc - 关闭; /nspy count - 统计; /nspy who - 区域扫描",
        UI_SUBTITLE = "实时服务器情报",
        UI_DETECTED = "已发现", UI_ACTIVE5 = "5分钟内活跃", UI_FACTIONS = "阵营",
        UI_CLASSES = "职业", UI_ALL = "全部", UI_FRESH = "最近", UI_NEW = "新增", UI_NEW_SHORT = "新增",
        UI_PLAYER = "玩家", UI_PROFILE = "资料", UI_ZONE = "区域", UI_CONTACT = "最后发现",
        UI_FIRST = "首次发现", UI_SOURCE = "来源", UI_ENCOUNTERS = "相遇次数", UI_LIVE = "正在收集",
        SCAN_NOT_RUNNING = "没有进行中的扫描",
        SUGGEST_STARTED = "suggest: 正在将查询填入搜索框 —— 你只需点击搜索按钮。停止: /nspy suggest",
        SUGGEST_FAILED = "suggest 未能启动: ",
        COUNT = "玩家总数: %d，本次会话新增: %d，公告: %s",
        ANNOUNCE_TOGGLE = "新玩家公告: ",
        DEBUG_ON = "调试模式: 开启 —— 日志输出到聊天（摘要、扫描、who、门禁拦截）",
        DEBUG_OFF = "调试模式: 关闭 —— 静默模式，日志仅写入SV环形缓冲区",
        DB_CLEARED = "遭遇数据库已清空",
        QUERIES_FMT = "%d 个查询",
        STARTUP = "已启动，数据库中有%d名玩家。命令: /nspy（suggest —— 辅助 /who）",
        SVR_TITLE = "服务器普查", SVR_SNAPSHOT = "RealmPulse 快照: %s", SVR_TOTAL = "玩家总数",
        SVR_PRIME = "高峰时段 (28天)", SVR_CLASSES = "职业", SVR_ZONES = "热门区域",
        SVR_PEAK = "峰值: %s %02d:00 - %d 玩家",
        SVR_NODATA = "未找到数据模块。请在 NearbySpy 旁安装 NearbySpy_Data (datapack-latest)。",
        SVR_STALE = "快照已过期 %d 天 - 请更新 NearbySpy_Data",
        SVR_D1 = "一", SVR_D2 = "二", SVR_D3 = "三", SVR_D4 = "四", SVR_D5 = "五", SVR_D6 = "六", SVR_D7 = "日",
        HUB_STATUS = "%d 条记录 - 共享 %s - v%s",
        HUB_PLAYERS = "玩家", HUB_PLAYERS_D = "遇到的玩家列表",
        HUB_SERVER = "服务器", HUB_SERVER_D = "服务器普查",
        HUB_HELP = "帮助", HUB_HELP_D = "所有命令",
        HUB_SETTINGS = "设置", HUB_SETTINGS_D = "选项与共享",
        SET_PEER = "共享数据 (peer)", SET_PEER_D = "发送新遇到的玩家到 nearbyspydata 频道并接收他人的数据",
        SET_AUTO = "自动 (%s)",
        SET_LANG = "语言", SET_LANG_D = "插件界面语言。其他窗口将在 /reload 后更新。",
        SET_TZ = "热力图时区", SET_TZ_D = "服务器窗口的高峰时段图按此时区显示；自动 = 系统时钟。",
        SET_RELOAD = "语言已更改；输入 /reload 重建所有窗口。",
        MINIMAP_TIP_L = "左键: 菜单", MINIMAP_TIP_R = "右键: 玩家列表",
        MM_ON = "小地图按钮已显示", MM_OFF = "小地图按钮已隐藏",
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
        ERR_LIST = "ОШИБКА списка: ",
        ERR_WINDOW = "ОШИБКА окна: ",
        TIME_NOW = "только что", TIME_MIN = "%d мин назад", TIME_HOUR = "%d ч назад",
        SRC_LINE = "Кто кормит: ",
        CHART_LABEL = "Уровни 1-60: всего с уровнем %d; макс %d игроков ур. %d; ср. %.1f",
        CHART_EMPTY = "Уровни 1-60: данных нет",
        WIN_HINT = "Esc - закрыть; /nspy count - статистика; /nspy who - скан зоны",
        UI_SUBTITLE = "РАЗВЕДКА СЕРВЕРА В РЕАЛЬНОМ ВРЕМЕНИ",
        UI_DETECTED = "ОБНАРУЖЕНО", UI_ACTIVE5 = "АКТИВНЫ < 5 МИН", UI_FACTIONS = "ФРАКЦИИ",
        UI_CLASSES = "КЛАССЫ", UI_ALL = "Все", UI_FRESH = "Свежие", UI_NEW = "Новые", UI_NEW_SHORT = "новых",
        UI_PLAYER = "ИГРОК", UI_PROFILE = "ПРОФИЛЬ", UI_ZONE = "ЗОНА", UI_CONTACT = "КОНТАКТ",
        UI_FIRST = "Первая встреча", UI_SOURCE = "Источник", UI_ENCOUNTERS = "Встреч", UI_LIVE = "СБОР АКТИВЕН",
        SCAN_NOT_RUNNING = "скан не идёт",
        SUGGEST_STARTED = "suggest: вписываю запросы в поле who — твоё дело только жать лупу. Стоп: /nspy suggest",
        SUGGEST_FAILED = "suggest не стартовал: ",
        COUNT = "всего игроков: %d, новых за сессию: %d, анонсы: %s",
        ANNOUNCE_TOGGLE = "анонсы новых игроков: ",
        DEBUG_ON = "режим дебага: вкл — логи в чат (дайджесты, скан, who, блокировки гейта)",
        DEBUG_OFF = "режим дебага: выкл — скрытный, логи только в SV-кольцо",
        DB_CLEARED = "база встреч очищена",
        QUERIES_FMT = "%d запросов",
        STARTUP = "запущен, в базе %d игроков. Команды: /nspy (suggest — расширенный /who)",
        SVR_TITLE = "Ценз сервера", SVR_SNAPSHOT = "Снимок RealmPulse: %s", SVR_TOTAL = "ИГРОКОВ",
        SVR_PRIME = "ПРАЙМ-ТАЙМ (28 ДНЕЙ)", SVR_CLASSES = "КЛАССЫ", SVR_ZONES = "ТОП ЗОН",
        SVR_PEAK = "Пик: %s %02d:00 - %d игроков",
        SVR_NODATA = "Нет data-модуля. Поставь NearbySpy_Data (релиз datapack-latest) рядом с NearbySpy.",
        SVR_STALE = "снимку %d дн. - обнови NearbySpy_Data",
        SVR_D1 = "Пн", SVR_D2 = "Вт", SVR_D3 = "Ср", SVR_D4 = "Чт", SVR_D5 = "Пт", SVR_D6 = "Сб", SVR_D7 = "Вс",
        HUB_STATUS = "%d записей - обмен %s - v%s",
        HUB_PLAYERS = "Игроки", HUB_PLAYERS_D = "список встреченных",
        HUB_SERVER = "Сервер", HUB_SERVER_D = "ценз сервера",
        HUB_HELP = "Помощь", HUB_HELP_D = "все команды",
        HUB_SETTINGS = "Настройки", HUB_SETTINGS_D = "опции и обмен",
        SET_PEER = "Обмен данными (peer)", SET_PEER_D = "Отправлять новые встречи в канал nearbyspydata и принимать от других",
        SET_AUTO = "Авто (%s)",
        SET_LANG = "Язык", SET_LANG_D = "Язык интерфейса аддона. Остальные окна обновятся после /reload.",
        SET_TZ = "Часовой пояс теплокарты", SET_TZ_D = "Карта прайм-тайма в окне сервера показывается в этом поясе; Авто = системные часы.",
        SET_RELOAD = "Язык изменён; набери /reload, чтобы пересоздать все окна.",
        MINIMAP_TIP_L = "ЛКМ: меню", MINIMAP_TIP_R = "ПКМ: список игроков",
        MM_ON = "кнопка миникарты показана", MM_OFF = "кнопка миникарты скрыта",
    },
    deDE = {
        ON = "an", OFF = "aus",
        LVL_PREFIX = "Stufe ",
        ALLIANCE = "Allianz", HORDE = "Horde",
        FIRST_SEEN = "zum ersten Mal in der Nähe: %s (%s%s) - %s",
        WHO_THROTTLED = "Der Server drosselt /who — 5 Minuten Pause",
        SUGGEST_INSCRIBED = "suggest: \"%s\" eingetragen — KLICKE die Lupe (noch %d in der Warteschlange)",
        SUGGEST_WAITING = "suggest: warte weiter auf deinen Klick auf die Lupe (\"%s\")",
        ERR_SCAN_RUNNING = "Scan läuft bereits (%s)",
        ERR_THROTTLE_PAUSE = "Drossel-Pause: %ds — der Server hat sich kürzlich beschwert",
        ERR_QUEUE_EMPTY = "Warteschlange ist leer (keine Namen zum Filtern)",
        WHO_FACTION_COVER = "/who sieht nur die Fraktion %s — volle Abdeckung: Scan mit einem Charakter jeder Fraktion",
        ERR_LIST = "Listen-FEHLER: ",
        ERR_WINDOW = "Fenster-FEHLER: ",
        TIME_NOW = "gerade eben", TIME_MIN = "vor %d Min", TIME_HOUR = "vor %d Std",
        SRC_LINE = "Quellen: ",
        CHART_LABEL = "Stufen 1-60: %d mit Stufe; max %d Spieler auf Stufe %d; avg %.1f",
        CHART_EMPTY = "Stufen 1-60: keine Daten",
        WIN_HINT = "Esc - schließen; /nspy count - Statistik; /nspy who - Zonenscan",
        UI_SUBTITLE = "LIVE-SERVER-AUFKLÄRUNG",
        UI_DETECTED = "ENTDECKT", UI_ACTIVE5 = "AKTIV < 5 MIN", UI_FACTIONS = "FRAKTIONEN",
        UI_CLASSES = "KLASSEN", UI_ALL = "Alle", UI_FRESH = "Aktuell", UI_NEW = "Neu", UI_NEW_SHORT = "neu",
        UI_PLAYER = "SPIELER", UI_PROFILE = "PROFIL", UI_ZONE = "ZONE", UI_CONTACT = "KONTAKT",
        UI_FIRST = "Zuerst gesehen", UI_SOURCE = "Quelle", UI_ENCOUNTERS = "Begegnungen", UI_LIVE = "SAMMLUNG AKTIV",
        SCAN_NOT_RUNNING = "kein Scan aktiv",
        SUGGEST_STARTED = "suggest: trage Anfragen ins Who-Feld ein — du klickst nur die Lupe. Stopp: /nspy suggest",
        SUGGEST_FAILED = "suggest nicht gestartet: ",
        COUNT = "Spieler gesamt: %d, neu diese Sitzung: %d, Ansagen: %s",
        ANNOUNCE_TOGGLE = "Ansagen neuer Spieler: ",
        DEBUG_ON = "Debug-Modus: an — Logs im Chat (Digests, Scan, Who, Gate-Blockierungen)",
        DEBUG_OFF = "Debug-Modus: aus — versteckt, Logs nur im SV-Ring",
        DB_CLEARED = "Begegnungs-Datenbank geleert",
        QUERIES_FMT = "%d Anfragen",
        STARTUP = "gestartet, %d Spieler in der DB. Befehle: /nspy (suggest — assistiertes /who)",
        SVR_TITLE = "Server-Zensus", SVR_SNAPSHOT = "RealmPulse-Snapshot: %s", SVR_TOTAL = "SPIELER",
        SVR_PRIME = "PRIME TIME (28 TAGE)", SVR_CLASSES = "KLASSEN", SVR_ZONES = "TOP-ZONEN",
        SVR_PEAK = "Spitze: %s %02d:00 - %d Spieler",
        SVR_NODATA = "Kein Datenmodul gefunden. Installiere NearbySpy_Data (Release datapack-latest) neben NearbySpy.",
        SVR_STALE = "Snapshot ist %d Tage alt - NearbySpy_Data aktualisieren",
        SVR_D1 = "Mo", SVR_D2 = "Di", SVR_D3 = "Mi", SVR_D4 = "Do", SVR_D5 = "Fr", SVR_D6 = "Sa", SVR_D7 = "So",
        HUB_STATUS = "%d Einträge - Austausch %s - v%s",
        HUB_PLAYERS = "Spieler", HUB_PLAYERS_D = "Begegnungsliste",
        HUB_SERVER = "Server", HUB_SERVER_D = "Server-Zensus",
        HUB_HELP = "Hilfe", HUB_HELP_D = "alle Befehle",
        HUB_SETTINGS = "Einstellungen", HUB_SETTINGS_D = "Optionen und Austausch",
        SET_PEER = "Peer-Austausch", SET_PEER_D = "Neue Begegnungen an den Kanal nearbyspydata senden und von anderen empfangen",
        SET_AUTO = "Auto (%s)",
        SET_LANG = "Sprache", SET_LANG_D = "Sprache der Addon-Oberfläche. Andere Fenster aktualisieren sich nach /reload.",
        SET_TZ = "Heatmap-Zeitzone", SET_TZ_D = "Die Prime-Time-Karte im Serverfenster wird in dieser Zeitzone gezeigt; Auto = Systemuhr.",
        SET_RELOAD = "Sprache geändert; /reload baut alle Fenster neu.",
        MINIMAP_TIP_L = "Linksklick: Menü", MINIMAP_TIP_R = "Rechtsklick: Spielerliste",
        MM_ON = "Minimap-Button eingeblendet", MM_OFF = "Minimap-Button ausgeblendet",
    },
    frFR = {
        ON = "activé", OFF = "désactivé",
        LVL_PREFIX = "niv. ",
        ALLIANCE = "Alliance", HORDE = "Horde",
        FIRST_SEEN = "vu pour la première fois : %s (%s%s) - %s",
        WHO_THROTTLED = "le serveur limite /who — pause de 5 min",
        SUGGEST_INSCRIBED = "suggest : « %s » saisi — CLIQUE sur la loupe (encore %d en file)",
        SUGGEST_WAITING = "suggest : j'attends toujours ton clic sur la loupe (« %s »)",
        ERR_SCAN_RUNNING = "scan déjà en cours (%s)",
        ERR_THROTTLE_PAUSE = "pause de limitation : %ds — le serveur a râlé récemment",
        ERR_QUEUE_EMPTY = "file vide (aucun nom à filtrer)",
        WHO_FACTION_COVER = "/who ne voit que la faction %s — couverture complète : scan avec un personnage de chaque faction",
        ERR_LIST = "ERREUR liste : ",
        ERR_WINDOW = "ERREUR fenêtre : ",
        TIME_NOW = "à l'instant", TIME_MIN = "il y a %d min", TIME_HOUR = "il y a %d h",
        SRC_LINE = "Sources : ",
        CHART_LABEL = "Niveaux 1-60 : %d avec niveau; max %d joueurs niv. %d; moy. %.1f",
        CHART_EMPTY = "Niveaux 1-60 : aucune donnée",
        WIN_HINT = "Échap - fermer; /nspy count - stats; /nspy who - scan de zone",
        UI_SUBTITLE = "RENSEIGNEMENT SERVEUR EN DIRECT",
        UI_DETECTED = "DÉTECTÉS", UI_ACTIVE5 = "ACTIFS < 5 MIN", UI_FACTIONS = "FACTIONS",
        UI_CLASSES = "CLASSES", UI_ALL = "Tous", UI_FRESH = "Récents", UI_NEW = "Nouveaux", UI_NEW_SHORT = "nouveaux",
        UI_PLAYER = "JOUEUR", UI_PROFILE = "PROFIL", UI_ZONE = "ZONE", UI_CONTACT = "CONTACT",
        UI_FIRST = "Première vue", UI_SOURCE = "Source", UI_ENCOUNTERS = "Rencontres", UI_LIVE = "COLLECTE ACTIVE",
        SCAN_NOT_RUNNING = "aucun scan en cours",
        SUGGEST_STARTED = "suggest : je saisis les requêtes dans le champ who — tu n'as qu'à cliquer la loupe. Stop : /nspy suggest",
        SUGGEST_FAILED = "suggest non lancé : ",
        COUNT = "joueurs au total : %d, nouveaux cette session : %d, annonces : %s",
        ANNOUNCE_TOGGLE = "annonces des nouveaux joueurs : ",
        DEBUG_ON = "mode debug : activé — logs dans le chat (digests, scan, who, blocages du gate)",
        DEBUG_OFF = "mode debug : désactivé — furtif, logs uniquement dans le ring SV",
        DB_CLEARED = "base des rencontres vidée",
        QUERIES_FMT = "%d requêtes",
        STARTUP = "démarré, %d joueurs en base. Commandes : /nspy (suggest — /who assisté)",
        SVR_TITLE = "Recensement du royaume", SVR_SNAPSHOT = "Snapshot RealmPulse : %s", SVR_TOTAL = "JOUEURS",
        SVR_PRIME = "HEURES DE POINTE (28 JOURS)", SVR_CLASSES = "CLASSES", SVR_ZONES = "ZONES PRINCIPALES",
        SVR_PEAK = "Pic : %s %02d:00 - %d joueurs",
        SVR_NODATA = "Module de données absent. Installez NearbySpy_Data (release datapack-latest) à côté de NearbySpy.",
        SVR_STALE = "snapshot vieux de %d jours - mettez à jour NearbySpy_Data",
        SVR_D1 = "Lun", SVR_D2 = "Mar", SVR_D3 = "Mer", SVR_D4 = "Jeu", SVR_D5 = "Ven", SVR_D6 = "Sam", SVR_D7 = "Dim",
        HUB_STATUS = "%d entrées - partage %s - v%s",
        HUB_PLAYERS = "Joueurs", HUB_PLAYERS_D = "liste des rencontres",
        HUB_SERVER = "Serveur", HUB_SERVER_D = "recensement",
        HUB_HELP = "Aide", HUB_HELP_D = "toutes les commandes",
        HUB_SETTINGS = "Réglages", HUB_SETTINGS_D = "options et partage",
        SET_PEER = "Partage peer", SET_PEER_D = "Envoyer les nouvelles rencontres au canal nearbyspydata et recevoir celles des autres",
        SET_AUTO = "Auto (%s)",
        SET_LANG = "Langue", SET_LANG_D = "Langue de l'interface de l'addon. Les autres fenêtres se mettent à jour après /reload.",
        SET_TZ = "Fuseau de la carte", SET_TZ_D = "La carte des heures de pointe (fenêtre serveur) s'affiche dans ce fuseau ; Auto = horloge système.",
        SET_RELOAD = "Langue modifiée ; tapez /reload pour reconstruire toutes les fenêtres.",
        MINIMAP_TIP_L = "Clic gauche : menu", MINIMAP_TIP_R = "Clic droit : liste des joueurs",
        MM_ON = "bouton minicarte affiché", MM_OFF = "bouton minicarte masqué",
    },
    koKR = {
        ON = "켜짐", OFF = "꺼짐",
        LVL_PREFIX = "레벨 ",
        ALLIANCE = "얼라이언스", HORDE = "호드",
        FIRST_SEEN = "처음 근처에서 발견: %s (%s%s) - %s",
        WHO_THROTTLED = "서버가 /who 를 제한 중 — 5분 일시 중지",
        SUGGEST_INSCRIBED = "suggest: 「%s」 입력됨 — 돋보기 버튼을 클릭하세요 (대기열 %d개 남음)",
        SUGGEST_WAITING = "suggest: 돋보기 클릭을 기다리는 중 (「%s」)",
        ERR_SCAN_RUNNING = "스캔이 이미 진행 중 (%s)",
        ERR_THROTTLE_PAUSE = "제한 일시 중지: %d초 — 서버가 최근에 경고함",
        ERR_QUEUE_EMPTY = "대기열이 비어 있음 (필터링할 이름 없음)",
        WHO_FACTION_COVER = "/who 는 %s 진영만 볼 수 있음 — 전체 커버리지: 각 진영 캐릭터로 스캔",
        ERR_LIST = "목록 오류: ",
        ERR_WINDOW = "창 오류: ",
        TIME_NOW = "방금", TIME_MIN = "%d분 전", TIME_HOUR = "%d시간 전",
        SRC_LINE = "데이터 출처: ",
        CHART_LABEL = "레벨 1-60: 레벨 있는 %d명; 최다 %d명 %d레벨; 평균 %.1f",
        CHART_EMPTY = "레벨 1-60: 데이터 없음",
        WIN_HINT = "Esc - 닫기; /nspy count - 통계; /nspy who - 지역 스캔",
        UI_SUBTITLE = "실시간 서버 정보",
        UI_DETECTED = "발견", UI_ACTIVE5 = "5분 내 활동", UI_FACTIONS = "진영",
        UI_CLASSES = "직업", UI_ALL = "전체", UI_FRESH = "최근", UI_NEW = "신규", UI_NEW_SHORT = "신규",
        UI_PLAYER = "플레이어", UI_PROFILE = "프로필", UI_ZONE = "지역", UI_CONTACT = "마지막 접촉",
        UI_FIRST = "최초 발견", UI_SOURCE = "출처", UI_ENCOUNTERS = "조우", UI_LIVE = "수집 중",
        SCAN_NOT_RUNNING = "진행 중인 스캔 없음",
        SUGGEST_STARTED = "suggest: 검색창에 쿼리를 입력합니다 — 돋보기 버튼만 클릭하세요. 중지: /nspy suggest",
        SUGGEST_FAILED = "suggest 시작 실패: ",
        COUNT = "전체 플레이어: %d, 이번 세션 신규: %d, 알림: %s",
        ANNOUNCE_TOGGLE = "신규 플레이어 알림: ",
        DEBUG_ON = "디버그 모드: 켜짐 — 채팅에 로그 출력 (다이제스트, 스캔, who, 게이트 차단)",
        DEBUG_OFF = "디버그 모드: 꺼짐 — 스텔스 모드, 로그는 SV 링에만 기록",
        DB_CLEARED = "조우 데이터베이스 삭제됨",
        QUERIES_FMT = "%d개 쿼리",
        STARTUP = "시작됨, DB에 플레이어 %d명. 명령어: /nspy (suggest — 보조 /who)",
        SVR_TITLE = "서버 센서스", SVR_SNAPSHOT = "RealmPulse 스냅샷: %s", SVR_TOTAL = "플레이어",
        SVR_PRIME = "프라임 타임 (28일)", SVR_CLASSES = "직업", SVR_ZONES = "인기 지역",
        SVR_PEAK = "피크: %s %02d:00 - %d 플레이어",
        SVR_NODATA = "데이터 모듈이 없습니다. NearbySpy 옆에 NearbySpy_Data(datapack-latest)를 설치하세요.",
        SVR_STALE = "스냅샷이 %d일 지남 - NearbySpy_Data 업데이트",
        SVR_D1 = "월", SVR_D2 = "화", SVR_D3 = "수", SVR_D4 = "목", SVR_D5 = "금", SVR_D6 = "토", SVR_D7 = "일",
        HUB_STATUS = "%d개 기록 - 공유 %s - v%s",
        HUB_PLAYERS = "플레이어", HUB_PLAYERS_D = "만난 플레이어 목록",
        HUB_SERVER = "서버", HUB_SERVER_D = "서버 센서스",
        HUB_HELP = "도움말", HUB_HELP_D = "모든 명령어",
        HUB_SETTINGS = "설정", HUB_SETTINGS_D = "옵션 및 공유",
        SET_PEER = "피어 공유", SET_PEER_D = "새로 만난 플레이어를 nearbyspydata 채널로 보내고 다른 플레이어의 정보를 받기",
        SET_AUTO = "자동 (%s)",
        SET_LANG = "언어", SET_LANG_D = "애드온 인터페이스 언어. 다른 창은 /reload 후에 적용됩니다.",
        SET_TZ = "히트맵 시간대", SET_TZ_D = "서버 창의 프라임타임 지도가 이 시간대로 표시됩니다; 자동 = 시스템 시계.",
        SET_RELOAD = "언어가 변경되었습니다. /reload 로 모든 창을 다시 만드세요.",
        MINIMAP_TIP_L = "좌클릭: 메뉴", MINIMAP_TIP_R = "우클릭: 플레이어 목록",
        MM_ON = "미니맵 버튼 표시", MM_OFF = "미니맵 버튼 숨김",
    },
}
local function L(key)
    -- settings override (db.locale) beats the client locale; NearbySpy is the
    -- SV global, nil until ADDON_LOADED — early L() calls just use the client
    local ov = (type(NearbySpy) == "table") and NearbySpy.locale or nil
    local t = (ov and LOCALE[ov]) or LOCALE[GetLocale()] or LOCALE.enUS
    return t[key] or LOCALE.enUS[key] or key
end

local newThisSession = 0
local lastWhoSent = 0
local whoScan = nil           -- active layered scan {zone, sent, results, added, current, suggest}
local whoQueue = {}           -- queue of ranges {lo, hi}

local GetDB   -- forward: P's body writes the ring into db through this reference

local function P(msg)
    -- timestamp on every line (08.10): without time in the ring you can't
    -- tell an instant reply from a server cooldown
    local stamped = ("[%s] %s"):format(date("%H:%M:%S"), tostring(msg))
    print(PREFIX .. stamped)
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
    local db = NearbySpy
    -- game tag for the site (14.10.2026): retail / classic_era / forever.
    -- GetBuildInfo: 1.60.x — Forever beta; other 1.x — classic live;
    -- >=11 — retail. Written once; no API → skip (the site fills in
    -- the default forever itself).
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
                if p.name and p.realm and p.realm ~= "" and p.realm ~= "?"
                    and p.realm ~= realRealm and not p.name:find(" ") then
                    -- surname got stuck in realm — move it back into the name
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

local function Round4(v)
    if type(v) ~= "number" then return nil end
    return math.floor(v * 10000 + 0.5) / 10000
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
local QueuePeerNew -- assigned below; only local discoveries may call it
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
        if data.source ~= "peer" and QueuePeerNew then QueuePeerNew(db, data) end
        return true
    end
    if nowT - (entry.lastSeen or 0) > REAP_SECONDS then
        entry.count = (entry.count or 1) + 1
    end
    entry.lastSeen = nowT
    -- Peer data can fill gaps, but cannot overwrite values already observed.
    if data.level and (data.source ~= "peer" or not entry.level) then entry.level = data.level end
    if data.class and (data.source ~= "peer" or not entry.class) then entry.class = data.class end
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

-- Opt-in, realm-local peer exchange. Received records never re-enter the queue.
local PEER_CHANNEL = "nearbyspydata"
local PEER_QUEUE_MAX, PEER_TTL, PEER_GAP = 60, 120, 10
local peerQueue, peerQueued, peerSent = {}, {}, {}
local peerIncoming = {start = 0, count = 0}
local lastPeerSend = 0
local peerStats = {sent = 0, received = 0, dropped = 0}
local function PeerField(s, maxLen)
    return type(s) == "string" and #s > 0 and #s <= maxLen
        and not s:find("[%c|;]")
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
    local key = db.game .. "|" .. data.key
    if peerSent[key] or peerQueued[key] then return end
    local payload = table.concat({"N2", db.game, data.realm, data.name,
        data.class, tostring(level), race, faction}, ";")
    if #payload > 220 then return end
    if #peerQueue >= PEER_QUEUE_MAX then
        local old = table.remove(peerQueue, 1)
        peerQueued[old.key] = nil
        peerStats.dropped = peerStats.dropped + 1
    end
    peerQueue[#peerQueue + 1] = {key = key, payload = payload, at = time()}
    peerQueued[key] = true
end

local function DrainPeerQueue()
    local db = GetDB()
    if not db.peerEnabled or #peerQueue == 0 then return end
    local nowT = time()
    if nowT - lastPeerSend < PEER_GAP then return end
    while #peerQueue > 0 and nowT - peerQueue[1].at > PEER_TTL do
        local old = table.remove(peerQueue, 1)
        peerQueued[old.key] = nil
        peerStats.dropped = peerStats.dropped + 1
    end
    if #peerQueue == 0 then return end
    local channel = GetChannelName(PEER_CHANNEL)
    if not channel or channel == 0 then return end
    -- The beta may require a hardware input event for sending channel chat.
    local send = C_ChatInfo and C_ChatInfo.SendChatMessage or SendChatMessage
    if not send then return end
    local item = peerQueue[1]
    local ok, result = pcall(send, item.payload, "CHANNEL", nil, channel)
    if not ok or result == false then
        db.debug.peerSendError = tostring(result):sub(1, 150)
        return
    end
    table.remove(peerQueue, 1)
    peerQueued[item.key] = nil
    peerSent[item.key] = true
    lastPeerSend = nowT
    peerStats.sent = peerStats.sent + 1
    db.debug.peerSendError = nil
end

local function ReceivePeerMessage(message, sender)
    local db = GetDB()
    if not db.peerEnabled or type(message) ~= "string" or #message > 220
        or (canaccessvalue and not canaccessvalue(message)) then return end
    if type(sender) ~= "string" or (canaccessvalue and not canaccessvalue(sender))
        or not PeerField(sender, 120) then return end
    local nowT = time()
    if nowT - peerIncoming.start >= 60 then
        peerIncoming.start, peerIncoming.count = nowT, 0
    end
    peerIncoming.count = peerIncoming.count + 1
    if peerIncoming.count > 120 then return end
    local fields = {}
    for part in (message .. ";"):gmatch("(.-);") do fields[#fields + 1] = part end
    if #fields ~= 8 or fields[1] ~= "N2" or fields[2] ~= db.game
        or fields[3] ~= PlayerRealm() then return end
    local realm, name, class = fields[3], fields[4], fields[5]
    if not PeerField(name, 60) or not PeerField(realm, 100)
        or not class:match("^[A-Z]+$") or #class > 32 then return end
    local level = tonumber(fields[6])
    if not level or level < 1 or level > 80 or level % 1 ~= 0 then return end
    local race = fields[7]
    if race ~= "?" and (not race:match("^[A-Za-z]+$") or #race > 32) then return end
    local faction = fields[8]
    if faction ~= "?" and faction ~= "Alliance" and faction ~= "Horde" then return end
    if UpsertPlayer(db, {key = name .. "-" .. realm, name = name, realm = realm,
        class = class, level = level, race = race ~= "?" and race or nil,
        faction = faction ~= "?" and faction or nil, source = "peer", silent = true}) then
        peerStats.received = peerStats.received + 1
    end
end

local function JoinPeerChannel()
    if not GetDB().peerEnabled then return end
    if GetChannelName(PEER_CHANNEL) == 0 then
        JoinChannelByName(PEER_CHANNEL, nil, nil, false)
    end
    if ChatFrame_RemoveChannel then
        for i = 1, 10 do
            local chat = _G["ChatFrame" .. i]
            if chat then ChatFrame_RemoveChannel(chat, PEER_CHANNEL) end
        end
    end
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

-- Self-learning of races/factions (server custom races):
-- from unit detections we learn "localized race → file key" and "race → faction",
-- then apply them to /who entries. Stored in SavedVariables (db.learn).
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
        local learned = db.learn and db.learn.raceFaction and db.learn.raceFaction[raceFile]
        faction = learned or RACE_FACTION[raceFile] or faction
    end
    LearnRace(db, raceLoc, raceFile, faction)

    -- coordinates: the unit's real ones first, else the player approximation
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

-- ============ passive world collection (1.5.0 — main mode) ============
-- Programmatic /who is dead since build 70291 (hardware gate in C++, whoprime 0/17) —
-- the world feeds the database: mouseover, party, guild, chat. All with no
-- user action. /who remains as the assisted manual mode (/nspy suggest).

-- party/raid: GROUP_ROSTER_UPDATE is spammy while a raid forms — throttle the pass
local lastGroupScan = 0
local function RecordGroup()
    local nowT = time()
    if nowT - lastGroupScan < GROUP_TROTTLE then return end
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
    local added = 0
    for i = 1, n do
        -- signature: name, rank, rankIdx, level, classLoc, zone, note, onote,
        -- online, status, classFile, achPts, achRank, mobile, soR, rep, guid
        local ok, name, _, _, level, classLoc, zone, _, _, _, _, classFile, _, _, _, _, _, guid =
            pcall(GetGuildRosterInfo, i)
        if ok and name and name ~= "" then
            name = name:match("^([^%-]+)%-") or name  -- strip "Name-Realm"
            if UpsertPlayer(db, {
                key = name .. "-" .. realm,
                name = name,
                realm = realm,
                class = classFile or ClassFileFromLocalized(classLoc),
                classLoc = classLoc,
                level = level,
                faction = faction,
                guid = guid,
                zone = zone,  -- roster zone — where the player is now (may be a different zone)
                source = "guild",
                silent = true,  -- the roster comes in hundreds — don't spam chat
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

-- ============ /who zone scan ============
-- The server returns at most 50 rows per query. Workaround (CensusPlus approach):
-- scan in level ranges (1-10, 11-20, ...), split any range with 50 results
-- in half down to a single level (1-1, 2-2, ...).

local function MaxLevel()
    -- The real ceiling = max level seen in the database, rounded up to a
    -- multiple of 10 (user decision 09.10.2026: "use the maximum level
    -- available, right now it's 30"). GetMaxPlayerLevel returns the engine's
    -- 60 and lies about the beta server cap (30), so we rely on actual data;
    -- as players level higher, the ceiling grows on its own, no code edits.
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

-- The /who zone filter token depends on the client locale:
-- enUS — z-"Zone", ruRU — з-"Зона" (Cyrillic!). With a Latin z on an RU client
-- the server silently drops the query — that's exactly why zone scans failed.
local IS_RU = (GetLocale() == "ruRU")
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

-- Localized race names for the r-"race" filter: standard + learned custom
-- ones (Skyborne etc.) from db.learn
-- faction ~= nil → cut races of the other faction: /who on Camelot returns
-- only the querying character's faction, queries for enemy races are always empty
local function RaceFilterNames(db, faction)
    local names = {}
    local function want(raceFile)
        if not faction then return true end
        local rf = (db and db.learn and db.learn.raceFaction and db.learn.raceFaction[raceFile])
            or RACE_FACTION[raceFile]
        return rf == nil or rf == faction
    end
    -- the table exists only for ru/en; on other locales (zhCN etc.)
    -- only learned races work (self-learning from targets)
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

-- Full layered zone scan: a queue of level ranges advanced by the user's clicks.
local whoPumpScheduled = false

local function FinishZoneScan(reason)
    if not whoScan then return end
    local s = whoScan
    whoScan = nil
    whoQueue = {}
    -- clean up after ourselves: the Who window remembers the last query in the
    -- input box — clear it so the user doesn't see the scan's "alien" values
    pcall(function()
        if WhoFrameEditBox then WhoFrameEditBox:SetText("") end
    end)
    HideWhoFrame()
    D(("/who %s: scan done%s — queries %d, found %d, new %d"):format(
        s.zone, reason and (" (" .. reason .. ")") or "", s.sent, s.results, s.added))
end

-- catch the server's anti-bot message ("Интересная операция, связанная с модификацией"):
-- the delivery channel is unpredictable — UI_ERROR_MESSAGE or system chat.
-- The pause is stored in db (survives /reload).
local function CheckWhoThrottle(msg)
    if type(msg) ~= "string" then return false end
    local db = GetDB()
    if msg:find("[Пп]ерац") or msg:find("[Мм]одификац") then
        -- hard anti-bot ("Интересная операция…"): 5-minute pause, stop the scan
        db.debug.whoThrottled = (db.debug.whoThrottled or 0) + 1
        db.debug.lastErrorMsg = msg:sub(1, 120)
        db.whoPauseUntil = time() + 300
        lastWhoSent = time()
        if whoScan then FinishZoneScan("stopped: server throttles /who") end
        P(L("WHO_THROTTLED"))
        return true
    end
    if msg:find("[Пп]одожд") then
        -- soft command cooldown (a couple of seconds) — note it, don't stop the scan
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

-- diagnostics: log recent system messages/errors into debug
-- to catch the exact text and channel of the server anti-bot message
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
        -- query WITHOUT the zone filter (the server drops z-…), but with an
        -- optional slice filter (class/race token, localized) + level range
        local query = q.base and ("%s %d-%d"):format(q.base, q.lo, q.hi)
            or ("%d-%d"):format(q.lo, q.hi)
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
        -- class slice: c-"mage" 1-80 (at the 50 cap — take as is)
        for _, locName in pairs(LOCALIZED_CLASS_NAMES_MALE or {}) do
            table.insert(whoQueue, { base = WHO_TOKEN_CLASS .. "\"" .. locName .. "\"", lo = 1, hi = ml })
        end
    elseif mode == "race" then
        -- race slice: r-"orc" 1-80; custom races — from the learned table
        for locName in pairs(RaceFilterNames(db, PlayerFaction())) do
            table.insert(whoQueue, { base = WHO_TOKEN_RACE .. "\"" .. locName .. "\"", lo = 1, hi = ml })
        end
    else
        -- initial wide query from level 1: on Camelot even 1-1 is overfull,
        -- narrow level grids don't save you from the 50 cap anyway
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
            local realm = PlayerRealm()  -- the suffix after the dash is unreliable; realm = current
            -- class: the beta has a ready filename field (MAGE); fallback — locale mapping
            local classFile = info.filename or ClassFileFromLocalized(info.classStr)
            -- race: from the learned table, then the classic mapping
            local raceLoc = info.raceStr
            local raceFile = (db.learn and db.learn.raceLoc2File and db.learn.raceLoc2File[raceLoc or ""])
                or RACE_LOCALE[raceLoc or ""]
            local faction = nil
            if raceFile then
                faction = (db.learn and db.learn.raceFaction and db.learn.raceFaction[raceFile])
                    or RACE_FACTION[raceFile]
            end
            -- player zone — from the /who reply (info.area), not our current one!
            -- zoneId is known only if the zone matches ours (the API gives no id for foreign zones)
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
                silent = true,   -- a /who zone can yield dozens of players — don't spam chat
            }) then
                added = added + 1
            end
        end
        end)
        if not okRow then DbgErr("whoRow", errRow) end
    end
    db.debug.whoAdded = (db.debug.whoAdded or 0) + added
    -- hide the Who window only after our own scan, with a human-like delay
    -- (instant hiding after every reply is a bot pattern for the anti-cheat);
    -- in suggest mode we don't touch the window — the user clicks the magnifier on it
    if whoScan and whoScan.suggest then
        -- keep the window open
    elseif whoScan or (time() - (lastWhoSent or 0) < 60) then
        C_Timer.After(1.5 + math.random() * 3, HideWhoFrame)
    end

    if whoScan then
        -- reply to the layered scan query
        local q = whoScan.current
        if q then q.answered = true end
        whoScan.results = whoScan.results + num
        whoScan.added = whoScan.added + added
        if num >= WHO_CAP and q then
            -- 50 cap: split a wide reply by CLASS (per the user's decision:
            -- level splitting is useless — even 1-1 is overfull); a class
            -- slice is taken as is, not split further
            if not (q.base and q.base:find(WHO_TOKEN_CLASS, 1, true)) then
                local sub = 0
                for _, locName in pairs(LOCALIZED_CLASS_NAMES_MALE or {}) do
                    table.insert(whoQueue, 1, { base = WHO_TOKEN_CLASS .. "\"" .. locName .. "\"", lo = q.lo, hi = q.hi })
                    sub = sub + 1
                end
                D(("/who: %d (cap) — splitting %d-%d into %d class slices"):format(num, q.lo, q.hi, sub))
            else
                -- 10.10.2026: the server IGNORES level ranges in /who
                -- (c-"Druid" 51-60 returned 50 with cap 30 and zero players >30
                -- in an 8800-strong database) — level splitting is pointless,
                -- class is the last working filter. Don't split further.
                D(("/who: %d (cap) — %s overflowed; server ignores level ranges, taking what we get"):format(num, q.base or "?"))
            end
        end
        PumpWhoQueue()
    else
        -- reply to a standalone general query
        if added > 0 then
            D(("/who %s: list %d, new %d"):format(db.debug.whoZone or "?", num, added))
        end
        -- auto-start of the programmatic scan was REMOVED (1.5.0): since build
        -- 70291 programmatic /who is dead (hardware gate) — offer the assisted
        -- mode instead
        if num >= WHO_CAP then
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
            EnsureNameplates(db)
        end
        if (db.debug.ticks % (GUILD_REFRESH / TICK_SECONDS)) == 0 then
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
           "/who: sent %d, last list %d, new %d, who errors %d, scan/CVar errors %d/%d, " ..
           "tokens: %s%s%s (%s, locale %s)"):format(
        d.ticks or 0, age < 0 and 9999 or age,
        tostring(d.lastPlates or "?"), tostring(d.lastPlayers or "?"),
        d.addedEvents or 0,
        tostring(d.cv_nameplateShowFriends or "?"),
        tostring(d.cv_nameplateShowEnemies or "?"),
        tostring(d.cv_nameplateShowAll or "?"),
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

-- ============ UI ============
-- Fonts (16.10.2026): use the client's own font object, period. Measured on
-- the ruRU beta: explicit SetFont() on ANY file path renders nothing during
-- the first ~10-20s after a cold login (and FRIZQT__.TTF never renders at
-- all), while GameFontNormal renders Cyrillic from second zero. No bundled
-- TTF, no polling, no repaint hacks. GameFontNormal also matches the client's
-- locale (native CJK/Korean fonts on zhCN/koKR clients).
local function ApplyFont(fs, size, flags)
    if GameFontNormal and fs.SetFontObject then
        pcall(fs.SetFontObject, fs, GameFontNormal)
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
    "/nspy peer on", "/nspy peer off", "/nspy peer", "/nspy reset",
    "/nspy server", "/nspy menu", "/nspy minimap", "/nspy settings",
}

local HELP_TEXT = {
    enUS = {"Player window", "This command list", "Assisted /who: you click search; repeat to stop", "Assisted wide /who: you click search", "Stop a /who scan", "Counters and diagnostics", "Toggle new-encounter chat messages", "Toggle technical chat logs", "Join the optional player-sharing channel", "Leave the channel and clear pending sends", "Sharing status and counters", "Clear the player database", "Server census window (needs NearbySpy_Data)", "Menu window (hub)", "Show/hide the minimap button", "Settings window (peer sharing)"},
    zhCN = {"玩家窗口", "命令列表", "辅助 /who：点击搜索；再次输入可停止", "辅助广域 /who：点击搜索", "停止 /who 扫描", "计数与诊断", "切换新遇见玩家的聊天提示", "切换技术日志", "加入可选的玩家共享频道", "退出频道并清空待发队列", "共享状态与计数", "清空玩家数据库", "服务器普查窗口(需要 NearbySpy_Data)", "菜单窗口 (hub)", "显示/隐藏小地图按钮", "设置窗口 (共享开关)"},
    ruRU = {"Окно игроков", "Список команд", "Помощник /who: нажимай лупу; повтор — стоп", "Широкий /who: жми лупу", "Остановить скан /who", "Счётчики и диагностика", "Вкл/выкл сообщения о новых встречах", "Вкл/выкл технические логи в чате", "Вступить в канал обмена игроками", "Покинуть канал и очистить очередь", "Состояние и счётчики обмена", "Очистить базу игроков", "Окно ценза сервера (нужен NearbySpy_Data)", "Окно меню (hub)", "Показать/скрыть кнопку миникарты", "Окно настроек (обмен)"},
    deDE = {"Spielerfenster", "Befehlsübersicht", "Assistiertes /who: Suche anklicken; erneut = Stopp", "Breites /who: Suche anklicken", "/who-Scan stoppen", "Zähler und Diagnose", "Meldungen über neue Begegnungen umschalten", "Technische Chat-Logs umschalten", "Optionalem Austauschkanal beitreten", "Kanal verlassen und Warteschlange leeren", "Austauschstatus und Zähler", "Spielerdatenbank leeren", "Server-Zensusfenster (benötigt NearbySpy_Data)", "Menüfenster (Hub)", "Minimap-Button ein-/ausblenden", "Einstellungsfenster (Peer-Austausch)"},
    frFR = {"Fenêtre des joueurs", "Liste des commandes", "/who assisté : cliquer sur recherche ; répéter pour arrêter", "/who large assisté : cliquer recherche", "Arrêter le scan /who", "Compteurs et diagnostic", "Activer/désactiver les annonces de rencontres", "Activer/désactiver les journaux techniques", "Rejoindre le canal de partage facultatif", "Quitter le canal et vider la file", "État et compteurs du partage", "Effacer la base des joueurs", "Fenêtre de recensement (nécessite NearbySpy_Data)", "Fenêtre de menu (hub)", "Afficher/masquer le bouton de la minicarte", "Fenêtre des réglages (partage peer)"},
    koKR = {"플레이어 창", "명령어 목록", "보조 /who: 검색 클릭, 다시 입력하면 중지", "보조 전체 /who: 검색 클릭", "/who 스캔 중지", "통계 및 진단", "새 만남 채팅 알림 전환", "기술 로그 채팅 출력 전환", "선택적 플레이어 공유 채널 참가", "채널 나가기 및 전송 대기열 비우기", "공유 상태 및 통계", "플레이어 데이터베이스 삭제", "서버 센서스 창 (NearbySpy_Data 필요)", "메뉴 창 (허브)", "미니맵 버튼 표시/숨기기", "설정 창 (피어 공유)"},
}
local helpWin
local function ShowHelpWindow()
    if not helpWin then
        helpWin = CreateFrame("Frame", "NearbySpyHelpWindow", UIParent)
        helpWin:SetSize(670, 445)
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
        local descriptions = HELP_TEXT[GetLocale()] or HELP_TEXT.enUS
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
            desc:SetText(descriptions[i])
        end
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

local function TacticalVisible(p, now)
    if tactical.filter == "fresh" then
        return now - (p.lastSeen or 0) <= TACTICAL_FRESH
    elseif tactical.filter == "new" then
        return (p.firstSeen or 0) >= tactical.started
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
    row:SetSize(632, TACTICAL_ROW_H)
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
    row.name = NewText(row, 12)
    row.name:SetPoint("LEFT", 34, 0)
    row.name:SetWidth(142)
    row.name:SetJustifyH("LEFT")
    row.profile = NewText(row, 11, 0.82, 0.79, 0.72)
    row.profile:SetPoint("LEFT", 180, 0)
    row.profile:SetWidth(150)
    row.profile:SetJustifyH("LEFT")
    row.zone = NewText(row, 11, 0.6, 0.55, 0.45)
    row.zone:SetPoint("LEFT", 334, 0)
    row.zone:SetWidth(195)
    row.zone:SetJustifyH("LEFT")
    row.seen = NewText(row, 10, 0.45, 0.5, 0.5)
    row.seen:SetPoint("LEFT", 533, 0)
    row.seen:SetWidth(94)
    row.seen:SetJustifyH("LEFT")
    row:SetScript("OnEnter", function(self)
        self.hover:Show()
        local p = self.player
        if not p or not GameTooltip then return end
        local r, g, b = ClassColorRGB(p.class)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(p.name or "?", r, g, b)
        GameTooltip:AddLine((p.classLoc or p.class or "?") .. "; " .. L("LVL_PREFIX") .. tostring(p.level or "?"), 0.82, 0.88, 0.88)
        GameTooltip:AddLine(L("UI_ZONE") .. ": " .. tostring(p.zone or "?"), 0.65, 0.72, 0.72)
        GameTooltip:AddLine(L("UI_FIRST") .. ": " .. (p.firstSeen and date("%d.%m.%Y %H:%M", p.firstSeen) or "?"), 0.58, 0.65, 0.65)
        GameTooltip:AddLine(L("UI_CONTACT") .. ": " .. (p.lastSeen and date("%d.%m.%Y %H:%M", p.lastSeen) or "?"), 0.58, 0.65, 0.65)
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
    for _, p in ipairs(SortedPlayers(GetDB())) do
        if TacticalVisible(p, now) then
            shown = shown + 1
            if shown > MAX_ROWS then break end
            local row = tactical.rows[shown] or TacticalRow(winList, shown)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 0, -(shown - 1) * TACTICAL_ROW_H)
            row.player = p
            TacticalClassIcon(row.icon, p.class)
            row.name:SetText(p.name or "?")
            row.name:SetTextColor(ClassColorRGB(p.class))
            row.profile:SetText(("%s; %s%s"):format(p.classLoc or p.class or "?", L("LVL_PREFIX"), tostring(p.level or "?")))
            row.zone:SetText(p.zone or "?")
            local age = now - (p.lastSeen or 0)
            row.seen:SetText(TimeAgo(p.lastSeen))
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
    local st = {total = 0, f5 = 0, f15 = 0, f60 = 0, newN = 0, alliance = 0, horde = 0, unknown = 0, levelN = 0, levelSum = 0, level = {}, classes = {}}
    local now = time()
    for _, p in pairs(GetDB().players) do
        st.total = st.total + 1
        local age = now - (p.lastSeen or 0)
        if age <= 300 then st.f5 = st.f5 + 1 end
        if age <= 900 then st.f15 = st.f15 + 1 end
        if age <= 3600 then st.f60 = st.f60 + 1 end
        if (p.firstSeen or 0) >= tactical.started then st.newN = st.newN + 1 end
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
            st.classes[file] = {file = file, label = p.classLoc or p.class or "?", count = 0}
        end
        st.classes[file].count = st.classes[file].count + 1
    end
    st.top = {}
    for _, item in pairs(st.classes) do st.top[#st.top + 1] = item end
    table.sort(st.top, function(a, b) return a.count > b.count end)
    return st
end

local function TacticalSources()
    local s = (GetDB().debug and GetDB().debug.src) or {}
    local parts, shown = {}, {}
    for _, key in ipairs({"unit", "guild", "chat", "who"}) do
        parts[#parts + 1] = key .. " " .. tostring(s[key] or 0)
        shown[key] = true
    end
    -- any new data source with a nonzero counter is appended — it must not
    -- silently vanish from the status bar
    for key, value in pairs(s) do
        if not shown[key] and type(value) == "number" and value > 0 then
            parts[#parts + 1] = tostring(key) .. " " .. value
        end
    end
    return L("SRC_LINE") .. table.concat(parts, "; ")
end

local function TacticalFilterState(button, active)
    button.bg:SetColorTexture(active and 0.3 or 0.1, active and 0.22 or 0.08, active and 0.08 or 0.05, 1)
    if active then button.label:SetTextColor(1, 0.85, 0.45)
    else button.label:SetTextColor(0.62, 0.55, 0.42) end
end

local function TacticalFilter(parent, key, x)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(112, 25)
    button:SetPoint("LEFT", x, 0)
    button.bg = button:CreateTexture(nil, "BACKGROUND")
    button.bg:SetAllPoints()
    button.label = NewText(button, 10)
    button.label:SetPoint("CENTER")
    button.label:SetWidth(106)
    button.key = key
    button:SetScript("OnClick", function(self) tactical.filter = self.key; TacticalUpdate() end)
    button:SetScript("OnEnter", function(self) if tactical.filter ~= self.key then self.bg:SetColorTexture(0.18, 0.13, 0.06, 1) end end)
    button:SetScript("OnLeave", function(self) TacticalFilterState(self, tactical.filter == self.key) end)
    tactical.filters[key] = button
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
            bar:SetHeight(maxCount > 0 and math.max(1, math.floor(LEVEL_CHART_H * count / maxCount + 0.5)) or 1)
            if level == peakLevel then bar:SetColorTexture(0.98, 0.8, 0.35, 1)
            else bar:SetColorTexture(0.12, 0.55 + level / 400, 0.42 + level / 500, 0.92) end
        end
        if maxCount > 0 then
            tactical.chartLabel:SetText(L("CHART_LABEL"):format(st.levelN, maxCount, peakLevel, st.levelSum / st.levelN))
        else tactical.chartLabel:SetText(L("CHART_EMPTY")) end

        for i = 1, CLASS_BARS do
            local row, item = tactical.classes[i], st.top[i]
            if item and st.top[1].count > 0 then
                row:Show()
                TacticalClassIcon(row.icon, item.file)
                row.label:SetText(item.label)
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
        for key, button in pairs(tactical.filters) do TacticalFilterState(button, key == tactical.filter) end
        tactical.count:SetText(tostring(TacticalRows()) .. " / " .. tostring(st.total))
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
    win:SetSize(700, 640)
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
    chart:SetPoint("TOPLEFT", 16, -116); chart:SetSize(412, 100)
    tactical.chartLabel = NewText(chart, 9, 0.62, 0.55, 0.42)
    tactical.chartLabel:SetPoint("TOPLEFT", 9, -7)
    for level = 1, 60 do
        local bar = chart:CreateTexture(nil, "ARTWORK")
        bar:SetPoint("BOTTOMLEFT", 9 + (level - 1) * 6.5, 10)
        bar:SetWidth(5.5); bar:SetHeight(1)
        tactical.bars[level] = bar
    end
    local axis = chart:CreateTexture(nil, "ARTWORK")
    axis:SetPoint("BOTTOMLEFT", 8, 9); axis:SetSize(391, 1); axis:SetColorTexture(0.3, 0.24, 0.12, 1)

    local classes = TacticalPanel(win)
    classes:SetPoint("TOPLEFT", 436, -116); classes:SetSize(248, 100)
    local classTitle = NewText(classes, 9, 0.62, 0.55, 0.42)
    classTitle:SetPoint("TOPLEFT", 9, -7); classTitle:SetText(L("UI_CLASSES"))
    for i = 1, CLASS_BARS do
        local row = CreateFrame("Frame", nil, classes)
        row:SetSize(230, 20); row:SetPoint("TOPLEFT", 9, -23 - (i - 1) * 23)
        row.icon = row:CreateTexture(nil, "ARTWORK"); row.icon:SetSize(18, 18); row.icon:SetPoint("LEFT")
        row.label = NewText(row, 9, 0.85, 0.82, 0.75); row.label:SetPoint("LEFT", 23, 0); row.label:SetWidth(68); row.label:SetJustifyH("LEFT")
        -- StatusBar is the native bar widget (min/max/value, it fills itself);
        -- texture fallback if the custom beta lacks the widget
        local okBar, bar = pcall(CreateFrame, "StatusBar", nil, row)
        if okBar and bar and bar.SetMinMaxValues then
            bar:SetPoint("LEFT", 92, 0); bar:SetSize(100, 13)
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
            local track = row:CreateTexture(nil, "BACKGROUND"); track:SetPoint("LEFT", 92, 0); track:SetSize(100, 8); track:SetColorTexture(0.1, 0.08, 0.05, 1)
            row.fill = row:CreateTexture(nil, "ARTWORK"); row.fill:SetPoint("LEFT", 92, 0); row.fill:SetHeight(8); row.fill:SetWidth(1)
            row.value = NewText(row, 9); row.value:SetPoint("RIGHT", -1, 0)
        end
        tactical.classes[i] = row
    end

    local toolbar = TacticalPanel(win)
    toolbar:SetPoint("TOPLEFT", 16, -224); toolbar:SetSize(668, 31)
    TacticalFilter(toolbar, "all", 6); TacticalFilter(toolbar, "fresh", 122); TacticalFilter(toolbar, "new", 238)
    tactical.count = NewText(toolbar, 9, 0.6, 0.53, 0.4); tactical.count:SetPoint("RIGHT", -9, 0)

    local tableHeader = CreateFrame("Frame", nil, win)
    tableHeader:SetPoint("TOPLEFT", 16, -260); tableHeader:SetSize(668, 24)
    local thBg = tableHeader:CreateTexture(nil, "BACKGROUND"); thBg:SetAllPoints(); thBg:SetColorTexture(0.07, 0.055, 0.035, 1)
    local h1 = NewText(tableHeader, 9, 0.62, 0.55, 0.4); h1:SetPoint("LEFT", 34, 0); h1:SetText(L("UI_PLAYER"))
    local h2 = NewText(tableHeader, 9, 0.62, 0.55, 0.4); h2:SetPoint("LEFT", 180, 0); h2:SetText(L("UI_PROFILE"))
    local h3 = NewText(tableHeader, 9, 0.62, 0.55, 0.4); h3:SetPoint("LEFT", 334, 0); h3:SetText(L("UI_ZONE"))
    local h4 = NewText(tableHeader, 9, 0.62, 0.55, 0.4); h4:SetPoint("LEFT", 533, 0); h4:SetText(L("UI_CONTACT"))

    local okSf, sf = pcall(CreateFrame, "ScrollFrame", nil, win, "UIPanelScrollFrameTemplate")
    if not okSf or not sf then sf = CreateFrame("ScrollFrame", nil, win) end
    sf:SetPoint("TOPLEFT", 16, -284); sf:SetPoint("BOTTOMRIGHT", -32, 43)
    local content = CreateFrame("Frame", nil, sf); content:SetSize(632, 1); sf:SetScrollChild(content); winList = content

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
    if not g then
        svr.nodata:SetText(L("SVR_NODATA")); svr.nodata:Show()
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
    if ageDays > 10 then svr.stale:SetText(L("SVR_STALE"):format(ageDays)) else svr.stale:SetText("") end

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

local function HubRefreshStatus()
    if not hubWin then return end
    local db = GetDB()
    hub.status:SetText(L("HUB_STATUS"):format(CountPlayers(),
        db.peerEnabled and L("ON") or L("OFF"), AddonVersion()))
end

local function HubCell(parent, col, row, labelKey, descKey, lr, lg, lb, onClick)
    local cell = CreateFrame("Button", nil, parent)
    cell:SetSize(96, 78)
    cell:SetPoint("TOPLEFT", 14 + col * 104, -56 - row * 86)
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
    label:SetText(L(labelKey))
    local desc = NewText(cell, 8, 0.55, 0.47, 0.32)
    desc:SetPoint("TOP", label, "BOTTOM", 0, -1)
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
    hubWin:SetSize(228, 252)
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
    HubRefreshStatus()
end

local function ShowHubWindow()
    local ok, err = pcall(function()
        if not hubWin then BuildHubWindow() end
        HubRefreshStatus()
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

-- Language selector data: Auto (client) first in the UI, then the fixed
-- public order en -> zh -> ru -> de -> fr -> ko.
local SET_LANG_ORDER = { "enUS", "zhCN", "ruRU", "deDE", "frFR", "koKR" }
local SET_LANG_NAME = {
    enUS = "English", zhCN = "中文", ruRU = "Русский",
    deDE = "Deutsch", frFR = "Français", koKR = "한국어",
}
local function EffectiveLocale()
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
        local closeBtn = CreateFrame("Button", nil, win, "UIPanelCloseButton")
        closeBtn:SetPoint("TOPRIGHT", -4, -4)
    end
    win:SetSize(380, 300)
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

    opt.peer, opt.peerLabel, opt.peerDesc = OptCheck(win, 16, -52, "SET_PEER", "SET_PEER_D",
        function() return GetDB().peerEnabled and true or false end,
        function(v)
            local db = GetDB()
            db.peerEnabled = v
            if v then
                local ok, err = pcall(JoinPeerChannel)
                if not ok then DbgErr("peerJoin", err) end
            else
                peerQueue, peerQueued = {}, {}
                if LeaveChannelByName then pcall(LeaveChannelByName, PEER_CHANNEL) end
            end
            HubRefreshStatus()
        end)

    opt.lang = OptSelect(win, -104, "NearbySpyLangDD", "SET_LANG", "SET_LANG_D", 190,
        LangEntries,
        function() return GetDB().locale or "AUTO" end,
        function(v)
            local db = GetDB()
            db.locale = (v ~= "AUTO") and v or nil
            RefreshSettingsText()
            P(L("SET_RELOAD"))
        end)

    opt.tz = OptSelect(win, -186, "NearbySpyTzDD", "SET_TZ", "SET_TZ_D", 190,
        TzEntries,
        function()
            local off = GetDB().tzOffset
            return (type(off) == "number") and off or "AUTO"
        end,
        function(v)
            GetDB().tzOffset = (v ~= "AUTO") and v or nil
        end)

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
        if opt.lang then opt.lang.Refresh() end
        if opt.tz then opt.tz.Refresh() end
        optWin:Show()
    end)
    if not ok then P(L("ERR_WINDOW") .. tostring(err)) end
end

local function MinimapButton_Update()
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

local function BuildMinimapButton()
    if miniBtn or not Minimap then return end
    miniBtn = CreateFrame("Button", "NearbySpyMinimapButton", Minimap)
    miniBtn:SetSize(28, 28)
    miniBtn:SetFrameStrata("MEDIUM")
    miniBtn:SetMovable(true)
    miniBtn:RegisterForDrag("LeftButton")
    miniBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    local disc = miniBtn:CreateTexture(nil, "BACKGROUND")
    disc:SetSize(26, 26)
    disc:SetPoint("CENTER")
    disc:SetColorTexture(0.06, 0.05, 0.03, 0.9)
    local icon = miniBtn:CreateTexture(nil, "ARTWORK")
    icon:SetSize(22, 22)
    icon:SetPoint("CENTER")
    icon:SetTexture("Interface\\AddOns\\NearbySpy\\NearbySpyIcon")
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
    elseif msg == "whostop" then
        if whoScan then
            FinishZoneScan("stopped manually")
        else
            P(L("SCAN_NOT_RUNNING"))
        end
    elseif msg == "suggest" or msg == "who" or msg == "whoclass" or msg == "whorace" then
        -- assisted /who (70291): programmatic sends are hardware-gated by the
        -- server — only the user's click on the magnifier gets a reply. All
        -- scan commands are assisted; repeating a command stops the scan.
        if whoScan then
            FinishZoneScan("stopped manually")
        else
            -- suggest/whoclass go straight to class slices: a wide 1-60 is
            -- pointless — on this server even 1-1 is overfull, the first click
            -- always hits the 50 cap
            local mode = ({ suggest = "class", who = "level", whoclass = "class", whorace = "race" })[msg]
            local ok, info = StartZoneScan(PlayerZone() or "?", true, mode, true)
            if ok then
                P(L("SUGGEST_STARTED"))
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
        P("Peer sharing enabled (channel: " .. PEER_CHANNEL .. "). Sends only new, detailed encounters.")
    elseif msg == "peer off" then
        db.peerEnabled = false
        peerQueue, peerQueued = {}, {}
        if LeaveChannelByName then pcall(LeaveChannelByName, PEER_CHANNEL) end
        P("Peer sharing disabled.")
    elseif msg == "peer" then
        P(("Peer %s: channel=%s, queued=%d, sent=%d, received=%d, dropped=%d%s"):format(
            db.peerEnabled and "on" or "off", tostring(GetChannelName(PEER_CHANNEL)),
            #peerQueue, peerStats.sent, peerStats.received, peerStats.dropped,
            db.debug.peerSendError and (", error=" .. db.debug.peerSendError) or ""))
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
-- i.e. the speaker is the event's 2nd argument (after the event name). The
-- order in the beta client is not guaranteed — write the first 15 events in
-- full to db.debug.chatSample, verify against the dump after the first session
-- and adjust select().
local chatFrame = CreateFrame("Frame")
local chatSampled = 0
local CHAT_SAMPLE_MAX = 15
local function IsPeerChannel(channelName)
    if type(channelName) ~= "string" or (canaccessvalue and not canaccessvalue(channelName)) then return false end
    channelName = channelName:lower()
    return channelName == PEER_CHANNEL or
        channelName:match("^%d+%. " .. PEER_CHANNEL .. "$") ~= nil
end
-- Hide only our data messages, never suppress channel notices or other channels.
local addMessageFilter = ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter or ChatFrame_AddMessageEventFilter
if addMessageFilter then
    addMessageFilter("CHAT_MSG_CHANNEL", function(_, _, _, _, _, channelName, _, _, _, _, rawChannel)
        return IsPeerChannel(rawChannel) or IsPeerChannel(channelName)
    end)
end
if WorldFrame and WorldFrame.HookScript then
    WorldFrame:HookScript("OnMouseDown", function()
        local ok, err = pcall(DrainPeerQueue)
        if not ok then DbgErr("peerSend", err) end
    end)
end
chatFrame:RegisterEvent("CHAT_MSG_SAY")
chatFrame:RegisterEvent("CHAT_MSG_YELL")
chatFrame:RegisterEvent("CHAT_MSG_CHANNEL")
chatFrame:SetScript("OnEvent", function(self, event, ...)
    -- all parsing under pcall: if the beta returns the name as a secret string
    -- (such were caught in combat via canaccessvalue), string operations would
    -- crash the whole chat handler — protect name collection, failures visible
    -- via DbgErr.
    -- pass varargs into the pcall lambda EXPLICITLY (ev, ...): a nested non-vararg
    -- function can't see the outer `...` — Lua 5.1 (client) raises the compile
    -- error "cannot use '...' outside a vararg function", luaparser missed that.
    local okP, errP = pcall(function(ev, ...)
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
        -- debug dump of the first events: speaker position verified on the live client
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
        local sm = type(arg2) == "string" and arg2 or arg1
        LogSysMsg("err", sm)
        if not CheckWhoThrottle(arg2) then CheckWhoThrottle(arg1) end
    elseif event == "UI_INFO_MESSAGE" then
        local sm = type(arg2) == "string" and arg2 or arg1
        LogSysMsg("info", sm)
        if not CheckWhoThrottle(arg2) then CheckWhoThrottle(arg1) end
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
    elseif event == "CHAT_MSG_SYSTEM" then
        -- custom server messages ("Интересная операция…") arrive via system chat
        LogSysMsg("sys", arg1)
        CheckWhoThrottle(arg1)
    end
end)
