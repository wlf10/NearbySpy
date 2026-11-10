"""Пачка N5: несколько записей в одном сообщении канала (Lua 5.1, real код).

Зачем: одна отправка = одно сообщение, а PEER_GAP даёт 6 отправок в минуту.
/who-скан на 20 человек не успевал разгрузиться, очередь переполнялась, и через
2 минуты TTL записи сгорали неотправленными (живой лог 10.11.2026: пять строк
"expired before send" подряд). Пачка втрое поднимает пропускную способность
при том же интервале.

Формат: N5;game;realm;rec1|rec2|… где rec = имя;класс;уровень;раса;фракция;
зонаId;зона;x;y;время. Разделитель "|" безопасен: PeerField не пропускает его
в имени/зоне/мире.

Что держит файл:
  - несколько записей уходят ОДНИМ сообщением, одна — по-прежнему N4;
  - пачка не смешивает разные миры (мир — часть заголовка);
  - приём N5 разворачивает пачку в те же записи, что и одиночные N4, и не
    даёт пачке обойти валидацию (битая запись внутри не проходит);
  - счётчик seen считает СООБЩЕНИЯ, а не записи внутри пачки.
"""

from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

from nsp_helpers import CONST_PRELUDE

ADDON = Path(__file__).resolve().parents[1]
SOURCE = ADDON / "NearbySpy.lua"


def queue_part() -> str:
    """От QueuePeerNew до конца DrainPeerQueue."""
    src = SOURCE.read_text(encoding="utf-8")
    start = src.index("QueuePeerNew = function(db, data)")
    end = src.index("local function ReceivePeerMessage(")
    return src[start:end]


SEND_HARNESS = """
time = function() return 1000 end
PEER_CHANNEL_BASE = 'nearbyspy'
PEER_PROTO = "N6"
PEER_BATCH_SEP = ","
PEER_QUEUE_MAX, PEER_TTL, PEER_GAP = 60, 120, 0   -- GAP=0: шлём сразу
PEER_PAYLOAD_MAX = 240
PEER_BATCH_MAX = 5
peerQueue, peerQueued, peerSent = {}, {}, {}
peerStats = {sent = 0, received = 0, merged = 0, dropped = 0, seen = 0, valid = 0,
             rejected = 0, foreign = 0, selfEcho = 0, inStart = 0, inCount = 0,
             lastSend = 0, rejectLogged = {}, lastNoChannel = 0, sentNames = {}}
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
    and not s:find('[%c|;]') end
function PeerCoord(v) return string.format('%.4f', v) end
function ClassLocFromFile() return nil end
SENT = {}
function SendChatMessage(payload) SENT[#SENT + 1] = payload end
C_ChatInfo = nil
"""


def codes_block() -> str:
    """Таблицы кодов класса/расы/фракции и функции PeerEncode/PeerDecode."""
    src = SOURCE.read_text(encoding="utf-8")
    start = src.index("NSP_PEER_CODES = {")
    end = src.index("-- Peers now carry the place as well")
    return src[start:end]


class BatchSendTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(CONST_PRELUDE + "\n" + SEND_HARNESS + "\n" + codes_block() + "\n"
                         + queue_part() + "\n"
                         "TestQueue = QueuePeerNew\n"
                         "TestDrain = DrainPeerQueue\n")
        self.g = self.lua.globals()

    def push(self, name, level=10, zone="Elwynn", zoneId=12, realm="R", game="forever"):
        self.g["TestQueue"](self.g["DB"], self.lua.table_from({
            "key": name + "-" + realm, "name": name, "realm": realm,
            "class": "MAGE", "level": level, "race": "Human", "faction": "Alliance",
            "zone": zone, "zoneId": zoneId, "source": "who",
        }))
        self.g["DB"]["game"] = game

    def sent(self):
        s = self.g["SENT"]
        return [str(s[i]) for i in range(1, len(s) + 1)]

    # --- одиночная запись остаётся N4 --------------------------------------

    def test_single_record_is_sent_as_n6(self):
        self.push("Alice")
        self.g["TestDrain"]()
        sent = self.sent()
        self.assertEqual(1, len(sent))
        self.assertTrue(sent[0].startswith("N6;"), sent[0][:20])
        # класс/раса/фракция — односимвольные коды, не текст
        parts = sent[0].split(";")
        self.assertEqual(1, len(parts[4]), "класс не закодирован: %r" % parts[4])
        self.assertEqual(1, len(parts[6]), "раса не закодирована: %r" % parts[6])
        self.assertEqual(1, len(parts[7]), "фракция не закодирована: %r" % parts[7])

    def test_encoded_fields_are_shorter_than_text(self):
        # ради этого всё и делалось: текстовые PALADIN/Human/Alliance — 23 байта
        self.push("Alice")
        self.g["TestDrain"]()
        single = self.sent()[0]
        text_form = single.replace(";g;10;a;a;", ";MAGE;10;Human;Alliance;")
        self.assertLess(len(single.encode()), len(text_form.encode()))

    def test_game_is_encoded_in_the_header(self):
        # игра — конечное множество (forever/retail/classic_era), кодируется
        # одним символом: "forever" (7 байт) -> "f"
        self.push("Alice")
        self.g["TestDrain"]()
        parts = self.sent()[0].split(";")
        self.assertEqual(1, len(parts[1]), "игра не закодирована: %r" % parts[1])
        self.assertEqual("f", parts[1], "код forever должен быть 'f'")

    def test_legacy_mode_sends_game_as_text(self):
        # переходный N5: старый клиент кода не поймёт, игра едет текстом
        self.lua.execute("PEER_PROTO = 'N5'")
        self.push("Alice")
        self.g["TestDrain"]()
        parts = self.sent()[0].split(";")
        self.assertEqual("N5", parts[0])
        self.assertEqual("forever", parts[1])

    def test_game_is_encoded_in_batch_header_too(self):
        # Заголовок пачки — тот же, что у одиночного пакета. Этот тест появился
        # после реальной ошибки: код игры добавили только в одиночную ветку, и
        # пачка продолжала слать "forever" (7 байт вместо 1).
        self.push("Alice"); self.push("Bob")
        self.g["TestDrain"]()
        parts = self.sent()[0].split(";")
        self.assertEqual("f", parts[1], "игра в пачке не закодирована: %r" % parts[1])

    def test_payload_never_contains_a_pipe(self):
        # Сервер отклоняет сообщение с '|' как «Invalid escape code in chat
        # message» — пакет не уходит вообще (живой лог 10.11.2026: sent=0,
        # очередь росла). Мок SendChatMessage такое НЕ ловит, потому что
        # ограничение живёт на сервере, поэтому проверяем сам payload.
        self.push("Alice"); self.push("Bob")
        self.g["TestDrain"]()
        for msg in self.sent():
            self.assertNotIn("|", msg, "в отправке остался '|': сервер её отвергнет")

    def test_batch_separator_is_comma(self):
        self.push("Alice"); self.push("Bob")
        self.g["TestDrain"]()
        msg = self.sent()[0]
        body = msg.split(";", 3)[3]
        self.assertEqual(2, len(body.split(",")), "записи не разделены запятой")

    def test_send_is_blocked_explicitly_if_a_pipe_appears(self):
        # защита в самом DrainPeerQueue: если '|' somehow попал в запись,
        # отправка блокируется с видимой причиной, а не молча копит очередь
        self.push("Alice")
        q = self.g["peerQueue"]
        q[1]["rec"] = str(q[1]["rec"]) + "|bad"
        self.g["TestDrain"]()
        self.assertEqual([], self.sent(), "пакет с '|' всё-таки ушёл")
        self.assertIn("|", str(self.g["DB"]["debug"]["peerSendError"]))

    # --- пачка -------------------------------------------------------------

    def test_two_records_go_in_one_message(self):
        self.push("Alice"); self.push("Bob")
        self.g["TestDrain"]()
        sent = self.sent()
        self.assertEqual(1, len(sent), "две записи ушли двумя сообщениями")
        self.assertTrue(sent[0].startswith("N6;"))
        body = sent[0].split(";", 3)[3]
        self.assertEqual(2, len(body.split(",")), "записи не разделены запятой")

    def test_batch_is_capped_by_payload_size(self):
        # длинные имена: в 240 байт влезет меньше пяти записей
        for i in range(5):
            self.push("Оченьдлинноеимя" + str(i))
        self.g["TestDrain"]()
        sent = self.sent()
        self.assertEqual(1, len(sent))
        self.assertLessEqual(len(sent[0].encode("utf-8")), 240,
                             "сообщение превысило лимит канала")

    def test_batch_does_not_mix_realms(self):
        # Мир — часть заголовка пачки, поэтому записи разных миров в одну пачку
        # попасть не могут. Один вызов TestDrain отправляет ОДНО сообщение,
        # поэтому проверяем: ушёл только первый мир, второй остался в очереди.
        self.push("Alice", realm="R1")
        self.push("Bob", realm="R2")
        self.g["TestDrain"]()
        sent = self.sent()
        self.assertEqual(1, len(sent), "за один вызов ушло больше одного сообщения")
        # игра в заголовке — код: "forever" -> 'f'
        self.assertTrue(sent[0].startswith("N6;f;R1;"),
                        "в пачку попал не тот мир: %s" % sent[0][:30])
        self.assertNotIn("Bob", sent[0], "в чужой мир уехала запись другого мира")
        self.assertEqual(1, len(self.g["peerQueue"]), "второй мир должен ждать своей отправки")

    def test_all_batched_records_leave_the_queue(self):
        self.push("Alice"); self.push("Bob")
        self.g["TestDrain"]()
        self.assertEqual(0, len(self.g["peerQueue"]), "очередь не очистилась")
        self.assertEqual(2, int(self.g["peerStats"]["sent"]))

    def test_batch_counter_is_tracked(self):
        self.push("Alice"); self.push("Bob")
        self.g["TestDrain"]()
        self.assertEqual(1, int(self.g["peerStats"]["batched"]))


class BatchReceiveTests(unittest.TestCase):
    """Приём N5: пачка разворачивается в обычные записи и не обходит валидацию."""

    def setUp(self):
        src = SOURCE.read_text(encoding="utf-8")
        start = src.index("local function ReceivePeerMessage(")
        end = src.index("local function JoinPeerChannel()")
        block = src[start:end]
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(CONST_PRELUDE + "\n"
                         "time = function() return 1794300000 end\n"
                         "UnitName = function() return 'Me', nil end\n"
                         "function PlayerRealm() return 'R' end\n"
                         "function PeerChannelName() return 'nearbyspyh' end\n"
                         "function PeerField(s, n) return type(s) == 'string' and #s > 0 "
                         "and #s <= n and not s:find('[%c|;,]') end\n"
                         "PEER_BATCH_MAX, PEER_CLOCK_SKEW = 5, 3600\n"
                         "PEER_BATCH_SEP = ','\n"
                         "peerStats = {seen = 0, valid = 0, received = 0, merged = 0, "
                         "rejected = 0, foreign = 0, selfEcho = 0, inStart = 0, inCount = 0, "
                         "rejectLogged = {}}\n"
                         "function PeerSync() end\n"
                         "local function D() end\n"
                         "function PeerEsc(s, n) return tostring(s) end\n"
                         "function ClassLocFromFile() return nil end\n"
                         "PEER_CLOCK_SKEW = 3600\n"
                         "DB = {peerEnabled = true, peerAllRealms = true, game = 'forever', "
                         "players = {}, debug = {}}\n"
                         "function GetDB() return DB end\n"
                         "QUEUE = {}\n"
                         "QueuePeerNew = function(db, data) QUEUE[#QUEUE + 1] = data end\n"
                         "function UpsertPlayer(db, data)\n"
                         "  local k = data.name .. '-' .. data.realm\n"
                         "  local existed = db.players[k] ~= nil\n"
                         "  if not existed then\n"
                         "    db.players[k] = { name = data.name, level = data.level,\n"
                         "                      zone = data.zone, peerAt = nil }\n"
                         "    return true\n"
                         "  end\n"
                         "  return false\n"
                         "end\n"
                         + block + "\n"
                         "TestReceive = ReceivePeerMessage\n"
                         "TestDB = DB\n"
                         "TestStats = peerStats\n")

    def recv(self, msg, sender="Sender-R"):
        self.lua.globals()["TestReceive"](msg, sender)

    def player(self, name):
        return self.lua.globals()["TestDB"]["players"][name + "-R"]

    def test_batch_adds_every_record(self):
        msg = ("N5;forever;R;"
               "Alice;MAGE;10;Human;Alliance;12;Elwynn;-;-;1794300000,"
               "Bob;WARRIOR;20;Orc;Horde;14;Durotar;-;-;1794300000,"
               "Carol;PRIEST;30;Dwarf;Alliance;1;Ironforge;-;-;1794300000")
        self.recv(msg)
        for name in ("Alice", "Bob", "Carol"):
            self.assertIsNotNone(self.player(name), "%s не добавлен" % name)
        self.assertEqual(3, int(self.lua.globals()["TestStats"]["batchIn"]))

    def test_seen_counts_messages_not_records(self):
        msg = ("N5;forever;R;"
               "Alice;MAGE;10;Human;Alliance;12;Elwynn;-;-;1794300000,"
               "Bob;WARRIOR;20;Orc;Horde;14;Durotar;-;-;1794300000")
        self.recv(msg)
        self.assertEqual(1, int(self.lua.globals()["TestStats"]["seen"]),
                         "seen посчитал записи вместо сообщений")

    def test_bad_record_inside_batch_is_rejected_not_accepted(self):
        # уровень вне диапазона — эта запись отбрасывается, соседняя проходит
        msg = ("N5;forever;R;"
               "Good;MAGE;10;Human;Alliance;12;Elwynn;-;-;1794300000,"
               "Bad;WARRIOR;999;Orc;Horde;14;Durotar;-;-;1794300000")
        self.recv(msg)
        self.assertIsNotNone(self.player("Good"))
        self.assertIsNone(self.player("Bad"), "битая запись прошла валидацию")

    def test_batch_from_another_game_is_rejected(self):
        msg = "N5;retail;R;Alice;MAGE;10;Human;Alliance;12;Elwynn;-;-;1794300000"
        self.recv(msg)
        self.assertIsNone(self.player("Alice"))

    def test_empty_batch_is_rejected(self):
        self.recv("N5;forever;R;")
        self.assertGreater(int(self.lua.globals()["TestStats"]["rejected"]), 0)

    def test_batch_does_not_exceed_the_record_cap(self):
        recs = ["P%d;MAGE;10;Human;Alliance;12;Elwynn;-;-;1794300000" % i
                for i in range(10)]
        self.recv("N5;forever;R;" + ",".join(recs))
        added = sum(1 for i in range(10) if self.player("P%d" % i) is not None)
        self.assertLessEqual(added, 5, "пачка обошла лимит записей")


if __name__ == "__main__":
    unittest.main()
