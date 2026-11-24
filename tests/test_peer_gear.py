"""Пакет G7: экипировка и билд по peer-каналу (20.11.2026).

Зачем: канал уже передаёт, КОГО встретили; этого мало — цель проекта знать, ЧТО
у игрока надето и как он вкачан. Снапшот уже собирается пассивным инспектом
(`db.players[key].gear = { at, ids, ilvl, slots, imp }`) и сайт его принимает
(`svEntryToGear` → `ingestGearSection` → `DecodeTalents`), поэтому работа
целиком в аддоне.

Почему отдельный тип пакета, а не поле записи: цена и частота разные. Запись о
встрече — 47 байт, снапшот — 133 байта; общая очередь означала бы либо голод
встреч, либо переполнение канала вещами (серверный лимит ~10 сообщений в минуту).

Почему gear пакуется в биты, а таланты — нет:
  • «1:20521,2:276740,…» тратит байты на десятичные цифры и на НОМЕР СЛОТА у
    каждого предмета: замер по 849 живым снапшотам — 115 символов в среднем.
    Битовый поток: 19 бит карты слотов + 8 бит ilvl + 20 бит на предмет = 51
    символ (×2.2);
  • import-строка талантов уже собрана из base64-алфавита (6 бит на символ) —
    перекодировать её нечем, любая упаковка вернёт те же биты.

Что держит файл:
  - упаковка/распаковка обратима на РЕАЛЬНЫХ данных (слоты 1..19, itemID до
    287073, ilvl до 60) и на крайних значениях;
  - мусор в упакованном потоке отвергается целиком (ресинхронизации нет);
  - пакет влезает в лимит клиента 240 байт на худшем живом снапшоте;
  - приём применяет пакет только если он СВЕЖЕЕ сохранённого снапшота;
  - полученный снапшот не уходит обратно (защита от релея);
  - приём не создаёт строку игрока из одного снапшота (orphan-счётчик);
  - отключение (`db.peerGearOff`) закрывает и отправку, и приём.
"""

from pathlib import Path
import re
import unittest

from lupa.lua51 import LuaRuntime

from nsp_helpers import CONST_PRELUDE, RACE_PRELUDE

ADDON = Path(__file__).resolve().parents[1]
SOURCE = ADDON / "NearbySpy.lua"
REALM = "CAMWOW EU5 Realm 1 PvE"

# Худший случай из живого SV (самый длинный снапшот) и типичный.
LONG_IDS = ("1:20521,2:276740,3:20517,4:221316,5:12422,6:12424,7:12429,8:12426,"
            "9:12425,10:250589,11:12548,12:11977,13:17774,14:20130,15:276737,"
            "16:13006,17:17705,18:274643,19:275042")
TYPICAL_IDS = "1:279391,3:276740,5:12422,7:12429,9:12425,11:12548,13:17774,15:276737"
IMPORT = "C0cBZcHs6hiHBl7Csp3hvR+3R+AghPwMmBAAAAAA"


def codec_block() -> str:
    """Кодеки N7 и упаковка gear — от таблицы кодов до конца PeerGearUnpack."""
    src = SOURCE.read_text(encoding="utf-8")
    start = src.index("NSP_PEER_CODES = {")
    end = src.index("-- Peers now carry the place as well")
    return src[start:end]


def gear_send_block() -> str:
    src = SOURCE.read_text(encoding="utf-8")
    start = src.index("function PeerQueueGear(key, snapshot")  # без закрывающей скобки: подпись может получить аргументы
    end = src.index("-- Замер возврата канала (15.11.2026)")
    return src[start:end]


def receive_block() -> str:
    src = SOURCE.read_text(encoding="utf-8")
    start = src.index("local function ReceivePeerMessage(")
    end = src.index("local function JoinPeerChannel()")
    return src[start:end] + "\n" + src[src.index("function ReceivePeerGear(fields, sender)"):
                                      src.index("local function JoinPeerChannel()")]


SEND_HARNESS = """
time = function() return 1000 end
PEER_CHANNEL_BASE = 'nearbyspy'
PEER_PROTO = "N7"
PEER_BATCH_SEP = ","
PEER_TAIL_SEP = "~"
PEER_QUEUE_MAX, PEER_TTL = 60, 600
PEER_GEAR_QUEUE_MAX = 24
PEER_PAYLOAD_MAX = 240
PEER_BATCH_MAX = 5
PEER_GAP, PEER_GAP_BUSY, PEER_BUSY_LEN = 0, 0, 999
peerQueue, peerQueued, peerSent = {}, {}, {}
peerStats = {sent = 0, received = 0, merged = 0, dropped = 0, seen = 0, valid = 0,
             rejected = 0, foreign = 0, selfEcho = 0, inStart = 0, inCount = 0,
             lastSend = 0, rejectLogged = {}, lastNoChannel = 0,
             gearQueue = {}, gearSent = {}}
DB = {peerEnabled = true, debug = {}, game = 'forever', players = {}}
function GetDB() return DB end
function PlayerRealm() return "CAMWOW EU5 Realm 1 PvE" end
function PeerChannelName() return 'nearbyspyh' end
GetChannelName = function() return 5 end
function PeerSync() end
local function D() end
local function DbgErr() end
local function P() end
function PeerEsc(s, n) return tostring(s) end
function PeerField(s, n) return type(s) == 'string' and #s > 0 and #s <= n
    and not s:find('[%c|;,~]') end
function ClassLocFromFile() return nil end
function NspNoteSendRet() return false end
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
ZONE_NAMES = {}
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
QueuePeerNew = function() end
function UpsertPlayer(db, data) return false end
NSP_INSPECT = nil
"""


class GearCodecTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(codec_block())
        self.g = self.lua.globals()

    def pack(self, ids, ilvl=0):
        return self.g["PeerGearPack"](ids, ilvl)

    def unpack(self, b64):
        return self.g["PeerGearUnpack"](b64)

    # --- обратимость -------------------------------------------------------

    def test_round_trip_on_the_longest_live_snapshot(self):
        packed = self.pack(LONG_IDS, 60)
        self.assertIsNotNone(packed)
        ids, ilvl, slots = self.unpack(packed)
        self.assertEqual(LONG_IDS, str(ids), "порядок и значения слотов потерялись")
        self.assertEqual(60, ilvl)
        self.assertEqual(19, slots)

    def test_round_trip_on_a_sparse_snapshot(self):
        # дыры в слотах — норма (пустые слоты не передаются вовсе)
        packed = self.pack(TYPICAL_IDS, 22)
        ids, ilvl, slots = self.unpack(packed)
        self.assertEqual(TYPICAL_IDS, str(ids))
        self.assertEqual(22, ilvl)
        self.assertEqual(8, slots)

    def test_round_trip_on_every_slot_alone(self):
        for slot in range(1, 20):
            packed = self.pack("%d:1000" % slot, 5)
            ids, _, slots = self.unpack(packed)
            self.assertEqual("%d:1000" % slot, str(ids), "слот %d не пережил упаковку" % slot)
            self.assertEqual(1, slots)

    def test_extreme_ids_and_ilvl(self):
        # 2^20-1 — верхняя граница формата; ilvl 255 — верхняя граница байта
        packed = self.pack("1:1048575,19:1", 255)
        ids, ilvl, _ = self.unpack(packed)
        self.assertEqual("1:1048575,19:1", str(ids))
        self.assertEqual(255, ilvl)

    def test_ilvl_above_the_byte_is_clamped_not_wrapped(self):
        packed = self.pack("1:5", 300)
        _, ilvl, _ = self.unpack(packed)
        self.assertEqual(255, ilvl, "ilvl обязан упираться в предел, а не обнуляться")

    # --- плотность ---------------------------------------------------------

    def test_packed_is_much_shorter_than_the_text_form(self):
        packed = str(self.pack(LONG_IDS, 60))
        text = LONG_IDS
        self.assertLess(len(packed), len(text) / 2,
                        "упакованный gear %d симв. против %d текстом — экономии нет"
                        % (len(packed), len(text)))

    # --- мусор -------------------------------------------------------------

    def test_garbage_is_rejected_whole(self):
        # у пакованного потока нет ресинхронизации: либо всё, либо ничего
        for bad in ("", "-", "!!!", "AAAA", "AAAAAAAA"):
            self.assertIsNone(self.unpack(bad), "мусор принят за снапшот: %r" % bad)

    def test_out_of_range_item_ids_are_dropped_not_wrapped(self):
        # id за пределом 20 бит и слот 0/20 не должны попасть в поток
        packed = self.pack("0:5,20:7,1:1048576,3:42", 10)
        ids, _, slots = self.unpack(packed)
        self.assertEqual("3:42", str(ids), "в поток попали недопустимые слоты/предметы")
        self.assertEqual(1, slots)

    def test_all_invalid_ids_yield_no_payload(self):
        self.assertIsNone(self.pack("0:5,20:7", 1))


class GearSendTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(CONST_PRELUDE + "\n" + RACE_PRELUDE + "\n" + codec_block() + "\n"
                         + SEND_HARNESS + "\n" + gear_send_block() + "\n"
                         "TestQueueGear = PeerQueueGear\n"
                         "TestDrainGear = PeerDrainGear\n"
                         "TestPayload = PeerGearPayload\n")
        self.g = self.lua.globals()

    def add_player(self, name="Wolfrider Alpha", realm=REALM):
        key = name + "-" + realm
        self.g["DB"]["players"][key] = self.lua.table_from({"name": name, "realm": realm})
        return key

    def snapshot(self, ids=LONG_IDS, imp=IMPORT, at=1000, ilvl=60, slots=19):
        return self.lua.table_from({"at": at, "ids": ids, "imp": imp,
                                    "ilvl": ilvl, "slots": slots})

    def item(self, key):
        q = self.g["peerStats"]["gearQueue"]
        return q[1]

    # --- сборка пакета -----------------------------------------------------

    def test_payload_starts_with_the_gear_tag_and_codes(self):
        key = self.add_player()
        self.g["TestQueueGear"](key, self.snapshot())
        payload = str(self.g["TestPayload"](self.g["DB"], self.item(key)))
        parts = payload.split(";")
        self.assertEqual("G7", parts[0])
        self.assertEqual("f", parts[1], "игра должна ехать кодом")
        self.assertEqual("a", parts[2], "мир должен ехать кодом")
        self.assertEqual("Wolfrider Alpha", parts[3])
        self.assertEqual("gt", parts[5], "флаги: и вещи, и билд")

    def test_worst_live_snapshot_fits_one_message(self):
        # 240 — бюджет payload'а, лимит клиента 255. Худший живой снапшот
        # (19 слотов + билд) обязан влезать ОДНИМ сообщением, иначе половина
        # данных уезжает отдельным пакетом и теряется при троттлинге.
        key = self.add_player("Robert Terwilliger")
        self.g["TestQueueGear"](key, self.snapshot())
        payload = str(self.g["TestPayload"](self.g["DB"], self.item(key)))
        self.assertLessEqual(len(payload.encode()), 240,
                             "пакет %d байт не влезает в лимит" % len(payload.encode()))
        self.assertNotIn("|", payload, "сервер отклоняет '|' целиком")

    def test_talents_travel_only_from_the_import_alphabet(self):
        key = self.add_player()
        self.g["TestQueueGear"](key, self.snapshot(imp="DROP TABLE;--"))
        payload = str(self.g["TestPayload"](self.g["DB"], self.item(key)))
        self.assertEqual("g", payload.split(";")[5],
                         "чужая import-строка не должна уходить в канал")
        self.assertNotIn("DROP", payload)

    def test_gear_only_packet_when_there_are_no_talents(self):
        key = self.add_player()
        self.g["TestQueueGear"](key, self.snapshot(imp=None))
        payload = str(self.g["TestPayload"](self.g["DB"], self.item(key)))
        self.assertEqual("g", payload.split(";")[5])

    # --- политика отправки --------------------------------------------------

    def test_snapshot_received_from_a_peer_is_never_resent(self):
        # иначе канал превращается в релей: два клиента гоняют один снапшот вечно
        key = self.add_player()
        snap = self.snapshot()
        snap["from"] = "Someone Else"
        self.g["TestQueueGear"](key, snap)
        self.assertEqual(0, len(self.g["peerStats"]["gearQueue"]))

    def test_same_snapshot_is_queued_once(self):
        key = self.add_player()
        self.g["TestQueueGear"](key, self.snapshot())
        self.g["TestQueueGear"](key, self.snapshot())
        self.assertEqual(1, len(self.g["peerStats"]["gearQueue"]),
                         "один снапшот не должен вставать в очередь дважды")

    def test_newer_snapshot_goes_after_the_old_one_was_sent(self):
        key = self.add_player()
        self.g["TestQueueGear"](key, self.snapshot(at=1000))
        self.g["TestDrainGear"](self.g["DB"])
        self.g["TestQueueGear"](key, self.snapshot(at=2000))
        self.assertEqual(1, len(self.g["peerStats"]["gearQueue"]),
                         "новый снапшот не встал в очередь после отправки старого")

    def test_gear_off_blocks_queueing(self):
        key = self.add_player()
        self.g["DB"]["peerGearOff"] = True
        self.g["TestQueueGear"](key, self.snapshot())
        self.assertEqual(0, len(self.g["peerStats"]["gearQueue"]))

    def test_unknown_player_is_not_queued(self):
        self.g["TestQueueGear"]("Nobody-Realm", self.snapshot())
        self.assertEqual(0, len(self.g["peerStats"]["gearQueue"]))

    # --- отправка -----------------------------------------------------------

    def test_drain_sends_the_packet_and_marks_it_sent(self):
        key = self.add_player()
        self.g["TestQueueGear"](key, self.snapshot())
        self.g["TestDrainGear"](self.g["DB"])
        sent = self.g["SENT"]
        self.assertEqual(1, len(sent))
        self.assertTrue(str(sent[1]).startswith("G7;"), str(sent[1])[:20])
        self.assertEqual(0, len(self.g["peerStats"]["gearQueue"]))
        self.assertEqual(1000, self.g["peerStats"]["gearSent"][key])


class GearDiagnosticsTests(unittest.TestCase):
    """Счётчики gear обязаны доезжать до SavedVariables.

    Живой прогон 20.11.2026 поймал ровно этот дефект: gear отправлялся
    (`Peer gear sent: Mr Defense (100 bytes)` в кольце), а в SV не было ни
    одного gear-поля — PeerSync писал фиксированный набор ключей. Диагностика,
    которой нельзя воспользоваться после логаута, не диагностика: то же самое
    уже случалось с `throttled`.
    """

    def setUp(self):
        src = SOURCE.read_text(encoding="utf-8")
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        block = src[src.index("PeerSync = function()"):src.index("-- Untrusted chat text")]
        self.lua.execute(CONST_PRELUDE + "\n" + SEND_HARNESS + "\n"
                         + "peerChatVisible = false\n" + block + "\n"
                         "TestSync = PeerSync\n")

    def test_every_gear_counter_reaches_the_saved_variables(self):
        self.lua.execute("""
            peerStats.gearQueue = { {}, {} }
            peerStats.gearSentCount = 3
            peerStats.gearIn = 4
            peerStats.gearOrphan = 5
            peerStats.gearStale = 6
            peerStats.gearBad = 7
            peerStats.gearEmpty = 8
            peerStats.gearExpired = 9
            peerStats.gearDropped = 10
            DB.peerGearOff = false
            TestSync()
        """)
        peer = self.lua.globals()["DB"]["debug"]["peer"]
        expect = {"gearQueued": 2, "gearSent": 3, "gearIn": 4, "gearOrphan": 5,
                  "gearStale": 6, "gearBad": 7, "gearEmpty": 8, "gearExpired": 9,
                  "gearDropped": 10}
        for key, value in expect.items():
            self.assertIn(key, list(peer.keys()), "поля %s нет в SV-снимке" % key)
            self.assertEqual(value, peer[key], "поле %s не доехало до SV" % key)

    def test_gear_switch_is_visible_in_the_saved_variables(self):
        self.lua.execute("DB.peerGearOff = true; TestSync()")
        self.assertTrue(self.lua.globals()["DB"]["debug"]["peer"]["gearOff"])


class PeerCounterReachTests(unittest.TestCase):
    """seen и batchIn: «канал мёртв» не должно следовать из нулевого счётчика.

    Живой случай 20.11.2026: в SV лежало seen=0 при valid=161. Все записи
    приехали ПАЧКАМИ, а seen увеличивался только для одиночных пакетов, поэтому
    по файлу канал выглядел мёртвым. batchIn существовал в памяти, но в SV не
    писался вовсе.
    """

    def setUp(self):
        src = SOURCE.read_text(encoding="utf-8")
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        block = src[src.index("PeerSync = function()"):src.index("-- Untrusted chat text")]
        self.lua.execute(CONST_PRELUDE + "\n" + SEND_HARNESS + "\n"
                         + "peerChatVisible = false\n" + block + "\n"
                         "TestSync = PeerSync\n")

    def test_batch_counter_reaches_the_saved_variables(self):
        self.lua.execute("peerStats.batchIn = 42; TestSync()")
        peer = self.lua.globals()["DB"]["debug"]["peer"]
        self.assertEqual(42, peer["batchIn"], "batchIn не доехал до SV")


class GearReceiveTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(CONST_PRELUDE + "\n" + RACE_PRELUDE + "\n" + codec_block() + "\n"
                         + RECEIVE_HARNESS + "\n" + receive_block() + "\n"
                         "TestReceive = ReceivePeerMessage\n"
                         "TestDB = DB\n"
                         "TestStats = peerStats\n"
                         "function TestPack(ids, ilvl) return PeerGearPack(ids, ilvl) end\n")
        self.g = self.lua.globals()

    def add_player(self, name="Wolfrider Alpha", realm=REALM):
        key = name + "-" + realm
        self.g["TestDB"]["players"][key] = self.lua.table_from({"name": name, "realm": realm})
        return key

    def packet(self, name="Wolfrider Alpha", ids=LONG_IDS, imp=IMPORT, at=1794300000,
               ilvl=60, flags="gt"):
        packed = str(self.g["TestPack"](ids, ilvl)) if ids else None
        parts = ["G7", "f", "a", name, str(at), flags]
        if packed and "g" in flags:
            parts.append(packed)
        if imp and "t" in flags:
            parts.append(imp)
        return ";".join(parts)

    def recv(self, msg):
        self.g["TestReceive"](msg, "Sender")

    # --- happy path --------------------------------------------------------

    def test_snapshot_lands_on_the_players_row(self):
        key = self.add_player()
        self.recv(self.packet())
        gear = self.g["TestDB"]["players"][key]["gear"]
        self.assertIsNotNone(gear, "снапшот не записан")
        self.assertEqual(LONG_IDS, str(gear["ids"]))
        self.assertEqual(60, gear["ilvl"])
        self.assertEqual(IMPORT, str(gear["imp"]))
        self.assertEqual(1794300000, gear["at"])

    def test_received_snapshot_is_marked_with_its_sender(self):
        # метка нужна отправке: снапшот от пира не имеет права уйти обратно
        key = self.add_player()
        self.recv(self.packet())
        self.assertEqual("Sender", str(self.g["TestDB"]["players"][key]["gear"]["from"]))

    def test_gear_only_packet_keeps_the_known_build(self):
        key = self.add_player()
        self.recv(self.packet())
        self.recv(self.packet(ids=TYPICAL_IDS, imp=None, at=1794300100, flags="g"))
        gear = self.g["TestDB"]["players"][key]["gear"]
        self.assertEqual(TYPICAL_IDS, str(gear["ids"]))
        self.assertEqual(IMPORT, str(gear["imp"]),
                         "пакет без талантов не должен стирать известный билд")

    # --- свежесть ----------------------------------------------------------

    def test_stale_packet_does_not_overwrite_a_newer_snapshot(self):
        key = self.add_player()
        self.recv(self.packet(at=1794300100))
        self.recv(self.packet(ids=TYPICAL_IDS, at=1794300000))
        gear = self.g["TestDB"]["players"][key]["gear"]
        self.assertEqual(LONG_IDS, str(gear["ids"]),
                         "старый пакет затёр более свежий снапшот")
        self.assertEqual(1, self.g["TestStats"]["gearStale"])

    def test_packet_from_the_future_is_rejected(self):
        key = self.add_player()
        self.recv(self.packet(at=1794300000 + 7200))
        self.assertIsNone(self.g["TestDB"]["players"][key]["gear"])

    # --- отказы ------------------------------------------------------------

    def test_corrupted_gear_is_rejected_whole(self):
        key = self.add_player()
        self.recv("G7;f;a;Wolfrider Alpha;1794300000;gt;!!!;%s" % IMPORT)
        self.assertIsNone(self.g["TestDB"]["players"][key]["gear"])
        self.assertEqual(1, self.g["TestStats"]["gearBad"])

    def test_unknown_player_is_counted_as_orphan_and_not_created(self):
        self.recv(self.packet(name="Stranger"))
        self.assertNotIn("Stranger-" + REALM, list(self.g["TestDB"]["players"].keys()),
                         "снапшот не должен создавать строку без класса и уровня")
        self.assertEqual(1, self.g["TestStats"]["gearOrphan"])

    def test_gear_off_ignores_packets(self):
        key = self.add_player()
        self.g["TestDB"]["peerGearOff"] = True
        self.recv(self.packet())
        self.assertIsNone(self.g["TestDB"]["players"][key]["gear"])

    def test_foreign_game_is_ignored(self):
        key = self.add_player()
        self.recv("G7;r;a;Wolfrider Alpha;1794300000;gt;%s" % str(self.g["TestPack"](LONG_IDS, 1)))
        self.assertIsNone(self.g["TestDB"]["players"][key]["gear"])

    # --- соседство с записями о встречах -----------------------------------

    def test_identity_packet_still_works_after_gear_support(self):
        # приём gear не должен сломать обычный N7: оба типа идут одним каналом
        key = self.add_player()
        self.recv("N7;f;a;Wolfrider Alpha;g;20;a;a;1429;-;-;1794300000")
        self.assertEqual(0, self.g["TestStats"]["rejected"])
        self.assertIsNotNone(self.g["TestDB"]["players"][key])


if __name__ == "__main__":
    unittest.main()
