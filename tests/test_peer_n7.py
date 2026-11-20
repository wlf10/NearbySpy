"""Протокол N7: компактные мир/время/зона (20.11.2026).

Зачем: сообщение peer-канала капнуто 240 байтами, а отправка — интервалом в
7-10 с, то есть пропускная способность канала считается не байтами, а числом
ЗАПИСЕЙ в сообщении. Замер по живому SavedVariables (34 581 peer-запись):

    поле                    байт    чем заменено в N7
    мир текстом             22.4    base36-код таблицы NSP_REALM_CODES -> 1
    имя зоны (кириллица)    19.5    только первая запись зоны за сессию
    время (unix epoch)      10.0    base36 секунд -> 6

Итог: сообщение с одной записью 90 -> 45 байт, записей в сообщении 2.7 -> 5.3.

Что держит файл:
  - код мира обратим для каждого значения таблицы, чужой мир уходит текстом;
  - приём различает код и имя по длине, поэтому старый отправитель с полным
    именем мира и base36-время понимаются ОДНИМ кодом приёма;
  - имя зоны объявляется один раз на зону за сессию и всегда — без zoneId;
  - N7-пачка разворачивается в те же записи, что и одиночный пакет;
  - старый N6 с 10-значным временем продолжает приниматься (совместимость);
  - пять длинных записей влезают в ОДНО сообщение там, где N6 их не уносил.
"""

from pathlib import Path
import re
import unittest

from lupa.lua51 import LuaRuntime

from nsp_helpers import CONST_PRELUDE, RACE_PRELUDE

ADDON = Path(__file__).resolve().parents[1]
SOURCE = ADDON / "NearbySpy.lua"
REALM = "CAMWOW EU5 Realm 1 PvE"     # 11-я строка NSP_REALM_CODES, base36(10) = "a"


def codes_block() -> str:
    """Коды класса/расы/фракции + кодеки N7 (мир, base36, время)."""
    src = SOURCE.read_text(encoding="utf-8")
    start = src.index("NSP_PEER_CODES = {")
    end = src.index("-- Peers now carry the place as well")
    return src[start:end]


def queue_part() -> str:
    src = SOURCE.read_text(encoding="utf-8")
    start = src.index("QueuePeerNew = function(db, data)")
    end = src.index("local function ReceivePeerMessage(")
    return src[start:end]


def receive_part() -> str:
    src = SOURCE.read_text(encoding="utf-8")
    start = src.index("local function ReceivePeerMessage(")
    end = src.index("local function JoinPeerChannel()")
    return src[start:end]


SEND_HARNESS = """
time = function() return 1000 end
PEER_CHANNEL_BASE = 'nearbyspy'
PEER_PROTO = "N7"
PEER_BATCH_SEP = ","
PEER_TAIL_SEP = "~"
PEER_QUEUE_MAX, PEER_TTL = 60, 600
PEER_GAP, PEER_GAP_BUSY, PEER_BUSY_LEN = 0, 0, 999
PEER_PAYLOAD_MAX = 240
PEER_BATCH_MAX = 5
peerQueue, peerQueued, peerSent = {}, {}, {}
peerStats = {sent = 0, received = 0, merged = 0, dropped = 0, seen = 0, valid = 0,
             rejected = 0, foreign = 0, selfEcho = 0, inStart = 0, inCount = 0,
             lastSend = 0, rejectLogged = {}, lastNoChannel = 0}
DB = {peerEnabled = true, debug = {}, game = 'forever'}
function GetDB() return DB end
function PeerChannelName() return 'nearbyspyh' end
GetChannelName = function() return 5 end
function PeerSync() end
local function D() end
local function DbgErr() end
local function P() end
function PeerEsc(s, n) return tostring(s) end
function PeerField(s, n) return type(s) == 'string' and #s > 0 and #s <= n
    and not s:find('[%c|;,~]') end
function PeerCoord(v) return string.format('%.4f', v) end
function ClassLocFromFile() return nil end
function ZoneNameById(id) return ({ [12] = 'Elwynn' })[tonumber(id)] end
SENT = {}
function SendChatMessage(payload) SENT[#SENT + 1] = payload end
C_ChatInfo = nil
"""

RECEIVE_HARNESS = """
time = function() return 1794300000 end
UnitName = function() return 'Me', nil end
function PlayerRealm() return 'CAMWOW EU5 Realm 1 PvE' end
function PeerChannelName() return 'nearbyspyh' end
PEER_BATCH_SEP = ','
PEER_TAIL_SEP = '~'
ZONE_NAMES = { [12] = 'Elwynn', [1429] = 'Goldshire Inn' }
function ZoneNameById(id) return ZONE_NAMES[tonumber(id)] end
function PeerCoord(v) return string.format('%.4f', v) end
function ClassLocFromFile() return nil end
PEER_BATCH_MAX, PEER_CLOCK_SKEW = 5, 3600
peerStats = {seen = 0, valid = 0, received = 0, merged = 0, rejected = 0,
             foreign = 0, selfEcho = 0, inStart = 0, inCount = 0, rejectLogged = {}}
function PeerSync() end
local function D() end
function PeerEsc(s, n) return tostring(s) end
DB = {peerEnabled = true, peerAllRealms = true, game = 'forever', players = {}, debug = {}}
function GetDB() return DB end
QUEUE = {}
QueuePeerNew = function(db, data) QUEUE[#QUEUE + 1] = data end
function UpsertPlayer(db, data)
  local k = data.name .. '-' .. data.realm
  if db.players[k] then return false end
  db.players[k] = { name = data.name, level = data.level, class = data.class,
                    race = data.race, faction = data.faction, zone = data.zone,
                    zoneId = data.zoneId, peerObservedAt = data.peerObservedAt }
  return true
end
"""


class CodecTests(unittest.TestCase):
    """Код мира и base36 — чистые функции, без клиента."""

    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(codes_block())
        self.g = self.lua.globals()

    # --- мир ---------------------------------------------------------------

    def test_every_realm_in_the_table_round_trips(self):
        table = self.g["NSP_REALM_CODES"]
        self.assertGreater(len(table), 10, "таблица миров пуста или обрезана")
        for value in table.values():
            code = self.g["PeerRealmCode"](value)
            self.assertIsNotNone(code, "мир %r не кодируется" % value)
            self.assertLessEqual(len(code), 2, "код мира дороже 2 байт: %r" % code)
            self.assertEqual(value, self.g["PeerRealmName"](code),
                             "обратное декодирование мира сломалось: %r" % value)

    def test_codes_are_unique(self):
        seen = {}
        for value in self.g["NSP_REALM_CODES"].values():
            code = self.g["PeerRealmCode"](value)
            self.assertNotIn(code, seen, "дубль кода %r у %r и %r"
                             % (code, seen.get(code), value))
            seen[code] = value

    def test_unknown_realm_has_no_code_but_still_travels(self):
        # новый мир кластера не должен теряться: кода нет -> едет текстом
        self.assertIsNone(self.g["PeerRealmCode"]("CAMWOW EU6 Realm 1 PvE"))
        text = "CAMWOW EU6 Realm 1 PvE"
        self.assertEqual(text, self.g["PeerRealmName"](text))

    def test_full_name_from_an_old_sender_passes_through(self):
        # старый клиент шлёт полное имя — приём не должен принять его за код
        self.assertEqual(REALM, self.g["PeerRealmName"](REALM))
        self.assertEqual("R", self.g["PeerRealmName"]("R"), "чужой короткий мир")

    def test_code_beyond_the_table_is_treated_as_text(self):
        # индекс вне таблицы (у получателя старая версия) — не падаем и не
        # подменяем мир: значение остаётся как пришло, запись уйдёт как чужая
        self.assertEqual("zz", self.g["PeerRealmName"]("zz"))

    # --- base36 и время ---------------------------------------------------

    def test_base36_known_values(self):
        self.assertEqual("0", self.g["PeerB36"](0))
        self.assertEqual("10", self.g["PeerB36"](36))
        self.assertEqual("rs", self.g["PeerB36"](1000))
        self.assertEqual("toa2qo", self.g["PeerB36"](1794300000))

    def test_time_round_trips_to_the_second(self):
        for ts in (1000, 1794300000, 1794942454):
            code = self.g["PeerTimeCode"](ts)
            self.assertLess(len(code), 10, "время не ужалось: %r" % code)
            self.assertEqual(ts, self.g["PeerTimeValue"](code),
                             "секунда потерялась на %r" % ts)

    def test_old_epoch_time_is_still_read(self):
        # N6-отправитель: 10 цифр unix-тайма
        self.assertEqual(1794300000, self.g["PeerTimeValue"]("1794300000"))

    def test_garbage_time_is_rejected(self):
        # ВНИМАНИЕ: "zzzzzzzz" здесь НЕ мусор — это валидный base36 (огромное
        # число); такое значение ловит проверка «время из будущего» на приёме,
        # а не кодек. Здесь только то, что не разбирается вообще.
        for value in ("", "-", "abc def", "!!!"):
            self.assertIsNone(self.g["PeerTimeValue"](value),
                              "мусор принят за время: %r" % value)


class SendTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(CONST_PRELUDE + "\n" + RACE_PRELUDE + "\n"
                         + codes_block() + "\n" + SEND_HARNESS + "\n" + queue_part() + "\n"
                         "TestQueue = QueuePeerNew\n"
                         "TestDrain = DrainPeerQueue\n")
        self.g = self.lua.globals()

    def push(self, name, zone="Таверна \"Гордость льва\"", zoneId=1429, realm=REALM):
        self.g["TestQueue"](self.g["DB"], self.lua.table_from({
            "key": name + "-" + realm, "name": name, "realm": realm,
            "class": "MAGE", "level": 20, "race": "Human", "faction": "Alliance",
            "zone": zone, "zoneId": zoneId, "source": "who",
        }))
        self.g["DB"]["game"] = "forever"

    def sent(self):
        s = self.g["SENT"]
        return [str(s[i]) for i in range(1, len(s) + 1)]

    def test_single_record_is_n7_with_coded_realm(self):
        self.push("Wolfrider")
        self.g["TestDrain"]()
        payload = self.sent()[0]
        parts = payload.split(";")
        self.assertEqual("N7", parts[0])
        self.assertEqual("a", parts[2], "мир должен уйти кодом: %r" % payload[:40])
        self.assertTrue(payload.startswith("N7;f;a;"), payload[:40])

    def test_time_travels_as_base36(self):
        self.push("Wolfrider")
        self.g["TestDrain"]()
        parts = self.sent()[0].split(";")
        self.assertEqual(1000, self.g["PeerTimeValue"](parts[11]))
        self.assertLess(len(parts[11]), 10)

    def test_zone_name_is_announced_once_per_zone(self):
        # 19.5 байта кириллического имени в КАЖДОЙ записи — четверть сообщения.
        # Имя нужно как страховка для получателя, чей клиент не знает zoneId,
        # поэтому первая запись зоны его несёт, следующие — нет.
        self.push("First")
        self.push("Second")
        self.g["TestDrain"]()
        sent = self.sent()
        self.assertEqual(1, len(sent), "две записи одной зоны — одно сообщение")
        recs = sent[0].split(";", 3)[3].split(",")
        self.assertEqual(2, len(recs))
        self.assertIn("Таверна", recs[0], "первая запись зоны несёт имя зоны")
        self.assertNotIn("Таверна", recs[1], "вторая запись имя зоны не повторяет")

    def test_zone_name_still_sent_when_the_zone_id_is_unknown(self):
        # без zoneId имя — единственный ключ зоны, экономить тут нечего
        self.push("First", zone="Duskwood", zoneId=0)
        self.push("Second", zone="Duskwood", zoneId=0)
        self.g["TestDrain"]()
        recs = self.sent()[0].split(";", 3)[3].split(",")
        self.assertIn("Duskwood", recs[0])
        self.assertIn("Duskwood", recs[1])

    def test_unknown_realm_travels_as_text(self):
        self.push("Alice", realm="CAMWOW EU6 Realm 1 PvE")
        self.g["TestDrain"]()
        parts = self.sent()[0].split(";")
        self.assertEqual("CAMWOW EU6 Realm 1 PvE", parts[2])

    def test_five_long_records_fit_one_message(self):
        # Ради этого всё и делалось: канал отдаёт ~10 сообщений в минуту, значит
        # пропускная способность = записей в сообщении. Одинаковые записи гоняем
        # в N7 и в N6 и сравниваем РЕАЛЬНЫЕ payload'ы.
        names = ["Morvanna Dunkelfluch", "Robert Terwilliger", "Albino Pentti",
                 "Liz Grimm", "Randal Windlance"]
        for n in names:
            self.push(n)
        self.g["TestDrain"]()
        n7 = self.sent()
        self.assertEqual(1, len(n7), "пять записей не влезли в одно сообщение")
        self.assertLessEqual(len(n7[0].encode()), 240, "вылезли за лимит клиента")

        # Тот же набор в переходном режиме N5 (единственный фолбэк для старых
        # клиентов) — сравниваем РЕАЛЬНЫЕ payload'ы, а не ожидания.
        self.lua.execute("PEER_PROTO = 'N5'")
        self.lua.execute("SENT = {}")
        self.lua.execute("peerQueue, peerQueued, peerSent = {}, {}, {}")
        self.lua.execute("peerStats.zoneSent = {}")
        for n in names:
            self.push(n)
        self.g["TestDrain"]()
        old_msgs = self.sent()
        total_old = sum(len(p.encode()) for p in old_msgs)
        total7 = len(n7[0].encode())
        self.assertLess(total7, total_old,
                        "N7 (%d Б в 1 сообщении) не короче N5 (%d Б в %d сообщениях)"
                        % (total7, total_old, len(old_msgs)))

    def test_legacy_mode_still_sends_the_realm_as_text(self):
        # в N5 код мира сломал бы старого получателя: он бы прочитал "a" как имя
        self.lua.execute("PEER_PROTO = 'N5'")
        self.push("Alice")
        self.g["TestDrain"]()
        parts = self.sent()[0].split(";")
        self.assertEqual("N5", parts[0])
        self.assertEqual(REALM, parts[2], "в N5 мир обязан ехать текстом")


class ReceiveTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(CONST_PRELUDE + "\n" + RACE_PRELUDE + "\n"
                         + codes_block() + "\n" + RECEIVE_HARNESS + "\n"
                         + receive_part() + "\n"
                         "TestReceive = ReceivePeerMessage\n"
                         "TestDB = DB\n"
                         "TestStats = peerStats\n"
                         "function TestTime(ts) return PeerTimeCode(ts) end\n")
        self.g = self.lua.globals()

    def player(self, name):
        return self.g["TestDB"]["players"][name + "-" + REALM]

    def recv(self, msg):
        self.g["TestReceive"](msg, "Sender")

    def n7(self, name, level=20, extra="", zone_id=1429, ts=1794300000):
        code = self.g["TestTime"](ts)
        return ("N7;f;a;%s;g;%d;a;a;%d;-;-;%s%s"
                % (name, level, zone_id, code, extra))

    def test_n7_packet_is_accepted_with_coded_realm_and_base36_time(self):
        self.recv(self.n7("Alice"))
        p = self.player("Alice")
        self.assertIsNotNone(p, "пакет N7 не принят")
        self.assertEqual("MAGE", p["class"])       # g = MAGE
        self.assertEqual(20, p["level"])
        self.assertEqual(1794300000, p["peerObservedAt"],
                         "время из base36 не восстановилось")
        self.assertEqual("Goldshire Inn", p["zone"], "зона из zoneId не резолвится")

    def test_coded_realm_is_not_mistaken_for_a_foreign_realm(self):
        self.recv(self.n7("Bob"))
        self.assertEqual(0, self.g["TestStats"]["foreign"],
                         "свой мир принят за чужой: код не декодирован")

    def test_n7_batch_unfolds_into_records(self):
        payload = "N7;f;a;" + self.n7("Ann").split(";", 3)[3] + "," \
            + self.n7("Ben").split(";", 3)[3]
        self.recv(payload)
        self.assertIsNotNone(self.player("Ann"), "первая запись пачки потеряна")
        self.assertIsNotNone(self.player("Ben"), "вторая запись пачки потеряна")

    def test_old_n6_with_epoch_time_still_works(self):
        # клиент прошлой версии: полное имя мира и 10-значный тайм
        self.recv("N6;f;CAMWOW EU5 Realm 1 PvE;Old;g;20;a;a;1429;-;-;1794300000")
        p = self.player("Old")
        self.assertIsNotNone(p, "N6 перестал приниматься")
        self.assertEqual(1794300000, p["peerObservedAt"])

    def test_unknown_protocol_is_still_rejected(self):
        self.recv("N9;f;a;Ghost;g;20;a;a;1429;-;-;1794300000")
        self.assertIsNone(self.player("Ghost"))

    def test_garbage_time_in_n7_is_rejected(self):
        self.recv("N7;f;a;Bad;g;20;a;a;1429;-;-;zzzzzzzz")
        self.assertIsNone(self.player("Bad"), "мусорное время должно ронять пакет")


if __name__ == "__main__":
    unittest.main()
