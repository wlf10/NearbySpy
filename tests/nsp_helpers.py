"""Shared helpers for the Lua 5.1 tests.

Since 09.11.2026 the addon is two files: NearbySpy_Locale.lua (the UI strings
and the shared constants table NSP_CONST) and NearbySpy.lua (the logic). The
tests slice pieces OUT of NearbySpy.lua and run them in isolation, so the
sliced chunk no longer sees anything declared ABOVE (or BELOW) the slice.

Use CONST_PRELUDE in the Lua source you execute:

    self.lua.execute(CONST_PRELUDE + "\\n" + block + "\\nTestX = X\\n")

The prelude defines NSP_CONST only; it does not touch the client's globals.

RACE_PRELUDE does the same for the race helpers. `ReceivePeerMessage` calls
`NspNormalizeRace`, which lives further down the file (next to RACE_LOCALE), so
any harness that slices the receiver must load it too — otherwise the tests die
on "attempt to call global 'NspNormalizeRace' (a nil value)" and prove nothing.
"""

from pathlib import Path

ADDON_DIR = Path(__file__).resolve().parents[1]
LOCALE_FILE = ADDON_DIR / "NearbySpy_Locale.lua"
ADDON_FILE = ADDON_DIR / "NearbySpy.lua"


def const_prelude() -> str:
    """The NSP_CONST table as Lua source, ready to execute before a chunk."""
    src = LOCALE_FILE.read_text(encoding="utf-8")
    start = src.index("NSP_CONST = {")
    end = src.index("\n}", start) + 2
    return src[start:end]


def race_prelude() -> str:
    """RACE_LOCALE plus the race normaliser, as one Lua chunk.

    Both pieces are cut from the addon so the tests exercise the real tables and
    the real function, not a copy. Empty when the tree predates them (a harness
    must still load and then fail on its assertions, not on a missing marker).
    """
    src = ADDON_FILE.read_text(encoding="utf-8")
    parts = []
    # NspNormalizeRace reads the code tables and PeerField, both declared above the
    # slice in production — so they travel with it here.
    if "NSP_PEER_CODES = {" in src:
        parts.append(src[src.index("NSP_PEER_CODES = {"):src.index("-- Peers now carry the place as well")])
    if "local function PeerField(s, maxLen)" in src:
        parts.append(src[src.index("local function PeerField(s, maxLen)"):
                          src.index("-- ── Коды для класса, расы и фракции")])
    if "local RACE_LOCALE = {" in src:
        parts.append(src[src.index("local RACE_LOCALE = {"):src.index("-- LearnedFactions")])
    if "function NspZoneNameSet(db)" in src:
        parts.append(src[src.index("function NspZoneNameSet(db)"):
                          src.index("-- Раньше хранилась ОДНА фракция на расу")])
    return "\n".join(parts)


def rec_prelude() -> str:
    """Позиционная схема записи (NSP_REC) плюс её конструктор, одним куском.

    С 1.7.0 запись игрока — массив из 23 слотов, и `UpsertPlayer` создаёт её
    через `NspNewPlayerRec`. Любой харнес, который вырезает `UpsertPlayer`,
    обязан принести и то, и другое: иначе он падает на
    "attempt to call global 'NspNewPlayerRec' (a nil value)" и не проверяет
    ничего о самом апсерте.

    Слоты берутся из настоящего файла локалей (там же метатаблица), а
    конструктор — из настоящего `NearbySpy.lua`: переписанная копия схемы в
    тесте разошлась бы с продакшном на первой правке порядка слотов.
    """
    loc = LOCALE_FILE.read_text(encoding="utf-8")
    start = loc.index("NSP_REC = {")
    end = loc.index("NSP_LOCALE = {", start)
    rec_block = loc[start:end]

    src = ADDON_FILE.read_text(encoding="utf-8")
    parts = [rec_block]
    marker = "function NspNewPlayerRec(key, data, observed, nowT)"
    if marker in src:
        ctor_start = src.index(marker)
        ctor_end = src.index("-- Приведение базы к позиционной схеме", ctor_start)
        parts.append(src[ctor_start:ctor_end])
    # NspResolveZoneId вызывается из UpsertPlayer, а объявлена выше вырезаемого
    # слайса. Без неё любой харнес апсерта падает «attempt to call global» и не
    # проверяет ничего о самом апсерте. Настоящая проверка — в
    # tests/test_zone_resolve.py, здесь достаточно заглушки.
    parts.append("NspResolveZoneId = function() end")
    return "\n".join(parts)


CONST_PRELUDE = const_prelude()
RACE_PRELUDE = race_prelude()
REC_PRELUDE = rec_prelude()


def peer_prelude() -> str:
    """Слайс peer-подсистемы целиком: константы, упаковка, очереди и запрос Q1.

    Зачем одним куском, а не функция за функцией: `PeerAnswerDue` зовёт
    настоящие `QueuePeerNew` и `PeerQueueGear`, а те живут внутри той же
    секции и держат состояние в ЕЁ локалах (`peerQueue`, `peerQueued`,
    `peerStats`). Вырезать их по отдельности можно, но тогда харнес начнёт
    подменять очередь своей копией — и проверять переписанный код, а не
    продакшн.

    Слайс идёт от начала peer-секции до `ReceivePeerMessage` (его не берём: он
    тянет за собой пол-файла). Область видимости чанка = один Lua-чанк, поэтому
    состояние видно вызываемому коду и остаётся недоступным снаружи — наружу
    отдаём ссылки `TestPeerQueue` / `TestPeerStats` / `TestPeerQueued`.

    Внешние имена (D, P, GetDB, time, GetChannelName, PlayerRealm, UnitName,
    UnitFactionGroup, PlayerZone, NspNoteSendRet, PeerCoord, ClassLocFromFile,
    ZoneNameById) в продакшне объявлены ВЫШЕ слайса, поэтому в харнессе это
    глобалы-заглушки, и тест обязан задать их ДО выполнения чанка.
    """
    src = ADDON_FILE.read_text(encoding="utf-8")
    start = src.index("-- Opt-in, realm-local peer exchange.")
    end = src.index("local function ReceivePeerMessage(message, sender, fromBatch)")
    return (src[start:end]
            + "\nTestPeerQueue, TestPeerStats, TestPeerQueued = peerQueue, peerStats, peerQueued\n"
            + """
-- Сброс сессионного состояния очередей: тесту нужно чистое «что ушло после
-- этой команды», а дедуп-карты живут в локалах чанка и снаружи не чистятся.
TestPeerReset = function()
    for i = #peerQueue, 1, -1 do peerQueue[i] = nil end
    for k in pairs(peerQueued) do peerQueued[k] = nil end
    for k in pairs(peerSent) do peerSent[k] = nil end
    peerStats.gearQueue = {}
    peerStats.gearSent = {}
end
-- Разгрузка очереди — настоящая, не копия: иначе тест «сколько сообщений
-- уходит в канал» проверял бы сборку пачки, переписанную в тесте.
TestDrain = DrainPeerQueue
""")


PEER_PRELUDE = peer_prelude()

# Заглушки клиента для peer-слайса. Каждое имя здесь в продакшне объявлено ВЫШЕ
# слайса, поэтому в чанке оно резолвится как глобал — и тест обязан задать их до
# выполнения чанка, иначе получит «attempt to call a nil value» вместо проверки.
PEER_STUBS = r"""
TestClock = 1000000
TestChannel = 7
TestDB = {game = "forever", peerEnabled = true, players = {}, debug = {}}
D = function() end
P = function() end
L = function(k) return k end
time = function() return TestClock end
GetDB = function() return TestDB end
PlayerRealm = function() return "TestRealm PvP" end
PlayerZone = function() return "TestZone" end
UnitName = function() return "Me", nil end
UnitFactionGroup = function() return "Alliance" end
GetChannelName = function() return TestChannel end
NspNoteSendRet = function() return false end
PeerCoord = function(v) return tostring(v) end
ClassLocFromFile = function(c) return c end
ZoneNameById = function() return nil end
-- NspResolveZoneId объявлена выше слайса (досстанавливает zoneId по имени
-- зоны, см. её определение в NearbySpy.lua). Настоящая проверка — в
-- tests/test_zone_resolve.py; здесь нужна заглушка, иначе вызов внутри
-- UpsertPlayer падает «attempt to call global».
NspResolveZoneId = function() end
-- jitter в ответах на запрос делаем детерминированным: иначе тест «ответ
-- уходит сразу» плавал бы на случайности.
math.random = function(a, b) return a or 0 end
"""


def peer_module(lua):
    """Загрузить peer-слайс в готовый LuaRuntime, вернуть таблицу TestDB.

    Состояние (очередь, счётчики) остаётся внутри чанка и доступно тесту через
    глобалы TestPeerQueue / TestPeerStats / TestPeerQueued.
    """
    lua.execute(CONST_PRELUDE + "\n" + PEER_STUBS + "\n" + PEER_PRELUDE)
    return lua.globals()["TestDB"]


def lua_fields(lua, payload: str):
    """Разложить пакет на поля ТЕМ ЖЕ разбором, что в приёмнике.

    Не `lua.table_from([...])`: он строит индексы с нуля, и `fields[2]` внутри
    аддона оказывается ЧУЖИМ полем (тест падал на «game mismatch» при
    правильном пакете). Разбор строки через gmatch — это буквально код
    `ReceivePeerMessage`, так что и раскладка совпадает по определению.
    """
    lua.globals()["TestPayload"] = payload
    lua.execute(
        "TestFields = {}\n"
        "for part in (TestPayload .. ';'):gmatch('(.-);') do TestFields[#TestFields + 1] = part end\n"
    )
    return lua.globals()["TestFields"]
