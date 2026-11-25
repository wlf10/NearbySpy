#!/usr/bin/env python3
"""Orphan-буфер peer-снапшотов + потолок сессии инспекта (25.11.2026).

Две правки, обе про ДАННЫЕ, которые терялись молча:

  A. ПОТОЛОК СЕССИИ. `MAX_PER_SESSION` был 200 при шаге 0.9–1.8 с, то есть
     выбирался за ~5 минут игры; дальше новые встречи не инспектировались
     вовсе — и оба выхода по потолку были молчаливыми. Замер 24.11.2026:
     из 3 877 unit-встреч за сутки снимок получили 2 029 (52%). Теперь отказ
     считается (sessionFull / sessionDrain), а потолок выше.

  C. ORPHAN-БУФЕР. Пакеты G7 (снапшот) и N7 (встреча) идут по каналу
     независимо, и снапшот часто приходит первым. Приём выбрасывал его, если
     строки игрока ещё нет: «создавать запись из одного снапшота нельзя».
     Замер по живому SV: gearIn=25 против gearOrphan=19 — 43% принятых
     снапшотов терялись ровно так.

Правила, которые держит этот файл (и ни одно из них не проверяется фактом
«снапшот записался»):

  - потолок сессии ВИДЕН: отказ по нему считается, а не молчит;
  - потолок берётся ИЗ КОДА, а не дублирует число в тесте;
  - отложенный снапшот прикрепляется, когда строка игрока появляется;
  - отложенный снапшот НЕ создаёт строку сам (иначе на сайт уйдёт игрок без
    класса и уровня) и НЕ уходит обратно в канал (релей);
  - буфер ограничен по числу и по времени, протухшее считается;
  - прикреплённый через буфер снапшот попадает в кольцо вытеснения (gearRing),
    иначе файл растёт без границы;
  - более свежий снапшот не затирается отложенным старым.

Run: python tests/test_peer_gear_orphan.py
"""
from pathlib import Path
import re
import unittest

from lupa.lua51 import LuaRuntime

ADDON = Path(__file__).resolve().parents[1]
INSPECT_FILE = ADDON / "NearbySpy_Inspect.lua"
SOURCE = ADDON / "NearbySpy.lua"
REALM = "CAMWOW EU5 Realm 1 PvE"

PRELUDE = """
NOW = 1000000
time = function() return NOW end
math.random = function() return 0 end
TIMERS = {}
C_Timer = { After = function(sec, fn) TIMERS[#TIMERS + 1] = { sec = sec, fn = fn } end }
function FireTimers(limit)
    local n = 0
    while #TIMERS > 0 and n < (limit or 100) do
        local t = table.remove(TIMERS, 1)
        n = n + 1
        t.fn()
    end
    return n
end
CHAT = {}
function PStub(msg) CHAT[#CHAT + 1] = tostring(msg) end
DEFAULT_CHAT_FRAME = { AddMessage = function(_, msg) CHAT[#CHAT + 1] = tostring(msg) end }
CreateFrame = function() return { RegisterEvent = function() end, SetScript = function() end } end
UNITS = { target = { guid = 'Player-1-00000001' } }
UnitExists = function(u) return UNITS[u] ~= nil end
UnitGUID = function(u) local r = UNITS[u]; return r and r.guid or nil end
UnitIsUnit = function(a, b) return false end
UnitIsPlayer = function(u) return true end
CanInspect = function(u, strict) return UNITS[u] ~= nil end
NOTIFY = {}
NotifyInspect = function(u) NOTIFY[#NOTIFY + 1] = u end
ITEMS = { [5] = 3283, [7] = 5941 }
GetInventoryItemID = function(u, slot) return ITEMS[slot] end
C_PaperDollInfo = { GetInspectItemLevel = function(u) return 42 end }
C_Traits = { GenerateInspectImportString = function(u) return 'C0cBZcHs6hiHBl7Csp3hvR' end }
DB = { players = {}, debug = {} }
DB.players['Ann-Realm'] = { name = 'Ann', realm = 'Realm' }
"""


def const(src: str, name: str) -> int:
    """Лимит берём из кода: он уже менялся, дублировать число в тесте нельзя."""
    m = re.search(r"^local %s = (\d+)" % re.escape(name), src, re.M)
    assert m, "константа %s не найдена в исходнике" % name
    return int(m.group(1))


class InspectLimitsTests(unittest.TestCase):
    """A: потолок сессии инспекта больше не молчит."""

    def setUp(self):
        self.src = INSPECT_FILE.read_text(encoding="utf-8")
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(PRELUDE)
        self.J = self.lua.execute(self.src)
        self.g = self.lua.globals()
        self.db = self.g["DB"]
        self.J["P"] = self.g["PStub"]
        self.J["GetDB"] = self.lua.eval("function() return DB end")
        self.cap = const(self.src, "MAX_PER_SESSION")
        self.queue_cap = const(self.src, "MAX_QUEUE")

    def counters(self):
        return self.db["debug"]["inspectQueue"]

    def drive_to(self, n):
        """Довести сессию до n отправленных запросов РЕАЛЬНЫМ прогоном.

        sentThisSession — локальная переменная чанка, снаружи её не выставить:
        подменять её глобалом значило бы проверять не тот код, что работает в
        клиенте. Поэтому гоняем настоящую пару «запрос → ответ → пауза».
        """
        sent = 0
        self.g["UNITS"] = self.lua.eval(
            '{ target = { guid = "Player-1-00000001" } }')
        for i in range(n):
            key = "P%d-Realm" % i
            self.db["players"][key] = self.lua.eval('{ name = "x", realm = "Realm" }')
            guid = "Player-1-%08d" % (i + 2)
            self.g["UNITS"]["target"]["guid"] = guid
            self.J["Request"]("target", key)
            self.J["OnInspectReady"](guid)
            self.g["FireTimers"](50)
            sent = int(self.counters()["sent"] or 0)
        return sent

    def test_session_cap_is_not_silent(self):
        # Заполняем сессию до потолка и просим инспект ещё раз: отказ обязан
        # быть посчитан. На старом коде счётчика не было вовсе, и «новые встречи
        # не инспектируются» нельзя было отличить от «инспект выключен».
        self.assertEqual(self.drive_to(self.cap), self.cap, "сессия не набрала потолок")
        notified = len(list(self.g["NOTIFY"].values()))

        key = "Bob-Realm"
        self.db["players"][key] = self.lua.eval('{ name = "Bob", realm = "Realm" }')
        self.g["UNITS"]["target"]["guid"] = "Player-9-00000009"
        self.J["Request"]("target", key)
        self.assertEqual(int(self.counters()["sessionFull"] or 0), 1,
                         "отказ по потолку сессии прошёл молча")
        self.assertEqual(len(list(self.g["NOTIFY"].values())), notified,
                         "запрос ушёл вопреки потолку")

    def test_drain_past_the_cap_is_counted_separately(self):
        # Запись уже стояла в очереди, когда лимит кончился: это другой случай,
        # и он тоже обязан быть виден.
        self.assertEqual(self.drive_to(self.cap - 2), self.cap - 2)
        self.g["UNITS"] = self.lua.eval(
            '{ target = { guid = "Player-1-00000001" },'
            '  mouseover = { guid = "Player-1-00000002" } }')
        for name, guid in (("Ann", "Player-1-00000001"), ("Bob", "Player-1-00000002")):
            self.db["players"][name + "-Realm"] = self.lua.eval(
                '{ name = "%s", realm = "Realm" }' % name)
        # Ann уходит в полёт (sent = cap-1), Bob и Carl копятся в очереди
        self.J["Request"]("target", "Ann-Realm")
        self.g["UNITS"]["target"]["guid"] = "Player-1-00000003"
        self.db["players"]["Carl-Realm"] = self.lua.eval('{ name = "Carl", realm = "Realm" }')
        self.J["Request"]("mouseover", "Bob-Realm")
        self.J["Request"]("target", "Carl-Realm")
        self.assertEqual(int(self.counters()["sent"] or 0), self.cap - 1)

        # первый ответ доводит сессию до потолка, второй выкидывает запись
        self.J["OnInspectReady"]("Player-1-00000001")
        self.g["FireTimers"](50)
        self.J["OnInspectReady"]("Player-1-00000003")
        self.g["FireTimers"](50)
        self.assertEqual(int(self.counters()["sessionDrain"] or 0), 1,
                         "запись, выброшенная из очереди по потолку, не посчитана")

    def test_caps_were_raised_for_the_measured_workload(self):
        # Потолок 200 выбирался за ~5 минут игры — это и было узкое место.
        self.assertGreaterEqual(self.cap, 600,
                                "потолок сессии ниже замера: 600 запросов = 9-18 минут игры")
        self.assertGreaterEqual(self.queue_cap, 160,
                                "очередь меньше двух шагов потолка: встречи будут отбрасываться")


class InspectOrphanBufferTests(unittest.TestCase):
    """C: отложенный снапшот доживает до появления строки игрока."""

    def setUp(self):
        self.src = INSPECT_FILE.read_text(encoding="utf-8")
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(PRELUDE)
        self.J = self.lua.execute(self.src)
        self.g = self.lua.globals()
        self.db = self.g["DB"]
        self.J["P"] = self.g["PStub"]
        self.J["GetDB"] = self.lua.eval("function() return DB end")
        self.max, self.ttl = (const(self.src, "ORPHAN_MAX"),
                              const(self.src, "ORPHAN_TTL"))

    def snap(self, at=1000000, ids="5:3283", imp=None):
        t = {"at": at, "from": "Sender", "ids": ids, "slots": 1, "ilvl": 42}
        if imp:
            t["imp"] = imp
        return self.lua.table_from(t)

    def stats(self):
        return self.J["OrphanStats"]()

    def test_buffered_snapshot_is_adopted_when_the_row_appears(self):
        self.assertTrue(self.J["BufferPeerGear"]("Stranger", self.snap(), REALM))
        self.assertEqual(int(self.stats()["held"]), 1)
        # строки ещё нет — усыновлять некуда
        self.assertFalse(self.J["AdoptPeerGear"]("Stranger-" + REALM, "Stranger"))
        self.assertIsNone(self.db["players"]["Stranger-" + REALM])

        # запись о встрече пришла (UpsertPlayer создаёт строку) → усыновление
        self.db["players"]["Stranger-" + REALM] = self.lua.eval(
            '{ name = "Stranger", realm = "%s", level = 40, class = "PRIEST" }' % REALM)
        self.assertTrue(self.J["AdoptPeerGear"]("Stranger-" + REALM, "Stranger"))
        gear = self.db["players"]["Stranger-" + REALM]["gear"]
        self.assertEqual(str(gear["ids"]), "5:3283")
        self.assertEqual(int(self.stats()["adopted"]), 1)
        self.assertEqual(int(self.stats()["held"]), 0, "усыновлённый снапшот остался в буфере")

    def test_adoption_name_match_ignores_case(self):
        # ник в пакете мог прийти из /who другого клиента в другом регистре
        self.J["BufferPeerGear"]("wolfrider", self.snap(), REALM)
        self.db["players"]["Wolfrider-" + REALM] = self.lua.eval(
            '{ name = "Wolfrider", realm = "%s" }' % REALM)
        self.assertTrue(self.J["AdoptPeerGear"]("Wolfrider-" + REALM, "Wolfrider"))

    def test_adopted_snapshot_enters_the_eviction_ring(self):
        # Без кольца усыновлённый снапшот не вытеснится никогда и файл растёт.
        self.J["BufferPeerGear"]("Stranger", self.snap(), REALM)
        key = "Stranger-" + REALM
        self.db["players"][key] = self.lua.eval('{ name = "Stranger", realm = "%s" }' % REALM)
        self.J["AdoptPeerGear"](key, "Stranger")
        ring = list(self.db["gearRing"].values())
        self.assertIn(key, ring, "усыновлённый снапшот не попал в gearRing")

    def test_newer_row_snapshot_is_not_overwritten_by_a_buffered_old_one(self):
        key = "Stranger-" + REALM
        self.db["players"][key] = self.lua.eval('{ name = "Stranger", realm = "%s" }' % REALM)
        self.db["players"][key]["gear"] = self.lua.eval('{ at = 1000500, ids = "7:5941" }')
        self.J["BufferPeerGear"]("Stranger", self.snap(at=1000000), REALM)
        self.assertFalse(self.J["AdoptPeerGear"](key, "Stranger"))
        self.assertEqual(str(self.db["players"][key]["gear"]["ids"]), "7:5941",
                         "старый буферный снапшот затёр свежий")
        self.assertEqual(int(self.stats()["stale"]), 1)

    def test_fresher_buffered_snapshot_replaces_the_held_one(self):
        self.J["BufferPeerGear"]("Stranger", self.snap(at=1000000), REALM)
        self.J["BufferPeerGear"]("Stranger", self.snap(at=1000200, ids="7:5941"), REALM)
        key = "Stranger-" + REALM
        self.db["players"][key] = self.lua.eval('{ name = "Stranger", realm = "%s" }' % REALM)
        self.J["AdoptPeerGear"](key, "Stranger")
        self.assertEqual(str(self.db["players"][key]["gear"]["ids"]), "7:5941")
        self.assertEqual(int(self.stats()["held"]), 0)

    def test_expired_entry_is_dropped_and_counted(self):
        self.J["BufferPeerGear"]("Stranger", self.snap(), REALM)
        self.g["NOW"] = 1000000 + self.ttl + 1
        # любая следующая запись запускает уборку
        self.J["BufferPeerGear"]("Other", self.snap(), REALM)
        self.assertEqual(int(self.stats()["expired"]), 1, "протухшая запись не посчитана")
        self.assertEqual(int(self.stats()["held"]), 1)
        self.assertFalse(self.J["AdoptPeerGear"]("Stranger-" + REALM, "Stranger"))

    def test_buffer_is_bounded(self):
        for i in range(self.max + 5):
            self.J["BufferPeerGear"]("P%d" % i, self.snap(at=1000000 + i), REALM)
        st = self.stats()
        self.assertLessEqual(int(st["held"]), self.max,
                             "буфер растёт без границы — это память клиента")
        self.assertGreater(int(st["evicted"]), 0, "вытеснение не посчитано")

    def test_buffer_never_creates_a_player_row(self):
        # снапшот сам по себе не доказывает встречу: строка без класса и уровня
        # на сайте бесполезна, а last_seen создал бы ложные sighting'и
        self.J["BufferPeerGear"]("Stranger", self.snap(), REALM)
        self.assertNotIn("Stranger-" + REALM, list(self.db["players"].keys()))

    def test_garbage_snapshot_is_not_buffered(self):
        self.assertFalse(self.J["BufferPeerGear"]("Stranger",
                                                  self.lua.eval('{ at = 1 }'), REALM))
        self.assertEqual(int(self.stats()["held"]), 0)


class WiringTests(unittest.TestCase):
    """Связка: NearbySpy.lua обязан звать буфер на orphan и усыновление на создание."""

    def test_receive_calls_the_buffer_instead_of_dropping(self):
        src = SOURCE.read_text(encoding="utf-8")
        block = src[src.index("function ReceivePeerGear(fields, sender)"):
                    src.index("local function JoinPeerChannel()")]
        self.assertIn("BufferPeerGear", block,
                      "приём не кладёт orphan-снапшот в буфер — правка не подключена")
        # и снапшот собирается ДО проверки строки, иначе буферу нечего взять
        self.assertLess(block.index("local snap = {"), block.index("if type(entry) ~= \"table\" then"),
                        "снапшот собирается после проверки строки — буфер получит пустое")

    def test_upsert_adopts_on_create(self):
        src = SOURCE.read_text(encoding="utf-8")
        start = src.index("local function UpsertPlayer(db, data)")
        end = src.index("local function ", start + 10)
        create_branch = src[start:end]
        self.assertIn("AdoptPeerGear", create_branch,
                      "создание строки не усыновляет отложенный снапшот")
        # внутри ветки создания: до неё идёт NspNewPlayerRec
        self.assertLess(create_branch.index("NspNewPlayerRec"),
                        create_branch.index("AdoptPeerGear"),
                        "усыновление стоит до создания строки — писать некуда")

    def test_counters_reach_the_saved_variables(self):
        src = SOURCE.read_text(encoding="utf-8")
        sync = src[src.index("PeerSync = function()"):src.index("-- Untrusted chat text")]
        for field in ("gearBuffered", "gearAdopted", "gearOrphanHeld", "gearOrphanExpired"):
            self.assertIn(field, sync, "счётчик %s не доезжает до SV" % field)


class ReceiveWithBufferTests(unittest.TestCase):
    """Сквозной путь: G7 без строки → буфер → N7 создаёт строку → снапшот на месте."""

    def setUp(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "tpgear", Path(__file__).parent / "test_peer_gear.py")
        self.tp = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.tp)

        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(self.tp.CONST_PRELUDE + "\n" + self.tp.RACE_PRELUDE + "\n"
                         + self.tp.codec_block() + "\n" + self.tp.RECEIVE_HARNESS + "\n"
                         + self.tp.receive_block() + "\n"
                         "TestReceive = ReceivePeerMessage\n"
                         "TestDB = DB\n"
                         "TestStats = peerStats\n"
                         "function TestPack(ids, ilvl) return PeerGearPack(ids, ilvl) end\n")
        self.g = self.lua.globals()

        # Реальный NSP_INSPECT загружаем поверх: буфер — его код, и проверяем мы
        # именно связку двух файлов, а не мок. PRELUDE переопределяет time(),
        # поэтому часы синхронизируем с RECEIVE_HARNESS (иначе пакет из 1794300000
        # выглядит «из будущего» и отбивается до буфера).
        self.lua.execute(PRELUDE)
        self.lua.execute("NOW = 1794300000")
        self.lua.execute('DB = TestDB\nDB.debug = DB.debug or {}\nDB.players = DB.players or {}')
        self.J = self.lua.execute(INSPECT_FILE.read_text(encoding="utf-8"))
        self.J["P"] = self.g["PStub"]
        self.J["GetDB"] = self.lua.eval("function() return TestDB end")
        self.lua.execute("NSP_INSPECT = nil")
        self.g["TestStats"]  # keep reference

    def packet(self, name="Stranger", ids="5:3283,7:5941", at=1794300000,
               ilvl=42, flags="g"):
        packed = str(self.g["TestPack"](ids, ilvl))
        return ";".join(["G7", "f", "a", name, str(at), flags, packed])

    def test_orphan_packet_is_buffered_then_adopted(self):
        self.g["NSP_INSPECT"] = self.J
        self.g["TestReceive"](self.packet(), "Sender")
        stats = self.J["OrphanStats"]()
        self.assertEqual(int(stats["buffered"]), 1, "G7 без строки не попал в буфер")
        self.assertEqual(int(self.g["TestStats"]["gearOrphan"] or 0), 1)

        key = "Stranger-" + REALM
        self.g["TestDB"]["players"][key] = self.lua.eval('{ name = "Stranger", realm = "%s" }' % REALM)
        self.assertTrue(self.J["AdoptPeerGear"](key, "Stranger"))
        gear = self.g["TestDB"]["players"][key]["gear"]
        self.assertEqual(str(gear["ids"]), "5:3283,7:5941",
                         "снапшот из канала не дожил до появления строки")


if __name__ == "__main__":
    unittest.main()
