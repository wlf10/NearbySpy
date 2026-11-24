"""Очерёдность отправки: gear не должен голодать при непустой очереди встреч.

Живой дефект (SV 20.11.2026, 10 минут игры):

    queued      = 55 из 60     очередь встреч почти полна и не пустеет
    gearQueued  = 24 из 24     очередь снапшотов ПЕРЕПОЛНЕНА
    gearSent    = 0            ни одного снапшота не ушло
    gearDropped = 48           вытеснено из переполненной очереди

Причина: gear отправлялся ТОЛЬКО при пустой очереди встреч. Отправок было
1.6/мин при серверном лимите ~10/мин — то есть канал не был перегружен,
узким местом оказался hardware-гейт (отправка только на клик по миру).
Пока кликов мало, очередь встреч не доходит до нуля, и gear не уходит никогда,
а его собственная очередь в это время молча вытесняет снапшоты.

Правило после фикса: gear получает каждый третий слот (при переполнении своей
очереди — каждый второй), при пустой очереди встреч — сразу.

Что держит файл:
  - при пустой очереди встреч gear уходит немедленно;
  - при НЕПУСТОЙ очереди встреч gear всё равно получает слоты (чередование);
  - при переполненной очереди gear он получает слот чаще;
  - когда PeerDrainGear не смог отправить (gap), слот НЕ тратится зря —
    уходят встречи;
  - встречи при этом не голодают: они по-прежнему получают большинство слотов.
"""

from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

from nsp_helpers import CONST_PRELUDE, RACE_PRELUDE

ADDON = Path(__file__).resolve().parents[1]
SOURCE = ADDON / "NearbySpy.lua"
REALM = "CAMWOW EU5 Realm 1 PvE"


def send_block() -> str:
    """Кодеки + очередь встреч + очередь gear + DrainPeerQueue."""
    src = SOURCE.read_text(encoding="utf-8")
    codes = src[src.index("NSP_PEER_CODES = {"):src.index("-- Peers now carry the place as well")]
    # маркер без закрывающей скобки: подпись PeerQueueGear может получить
    # аргументы (с 1.6.3 — opts), и точное совпадение с «(key, snapshot)» ломает
    # вырезание, хотя код рабочий.
    gear = src[src.index("function PeerQueueGear(key, snapshot"):
               src.index("-- Замер возврата канала (15.11.2026)")]
    queue = src[src.index("QueuePeerNew = function(db, data)"):
               src.index("local function ReceivePeerMessage(")]
    return codes + "\n" + gear + "\n" + queue


HARNESS = """
time = function() return 1795167302 end
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
function PeerCoord(v) return string.format('%.4f', v) end
function ClassLocFromFile() return nil end
function NspNoteSendRet() return false end
function ZoneNameById(id) return ({ [1429] = 'Goldwyn' })[tonumber(id)] end
SENT = {}
function SendChatMessage(payload) SENT[#SENT + 1] = payload end
C_ChatInfo = nil
"""


class GearTurnTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(CONST_PRELUDE + "\n" + RACE_PRELUDE + "\n" + HARNESS + "\n"
                         + send_block() + "\n"
                         "TestDrain = DrainPeerQueue\n"
                         "TestDrainGear = PeerDrainGear\n"
                         "TestQueueGear = PeerQueueGear\n"
                         "TestQueuePeer = QueuePeerNew\n")
        self.g = self.lua.globals()

    # ── наполнение очередей ──────────────────────────────────────────────
    def fill_meetings(self, n):
        for i in range(n):
            name = "Meet%d" % i
            self.g["TestQueuePeer"](self.g["DB"], self.lua.table_from({
                "key": name + "-" + REALM, "name": name, "realm": REALM,
                "class": "MAGE", "level": 20 + i % 40, "race": "Human",
                "faction": "Alliance", "zone": "Goldwyn", "zoneId": 1429,
                "source": "who", "observedAt": 1795167000 + i,
            }))

    def fill_gear(self, n):
        for i in range(n):
            name = "Geared%d" % i
            key = name + "-" + REALM
            self.g["DB"]["players"][key] = self.lua.table_from(
                {"name": name, "realm": REALM})
            self.g["TestQueueGear"](key, self.lua.table_from({
                "at": 1795167000 + i, "ids": "1:279391,2:273457,3:3748",
                "ilvl": 22, "slots": 3,
                "imp": "C0cBZcHs6hiHBl7Csp3hvR+3R+AghPwMmBAAAAAA",
            }))

    def sent(self):
        s = self.g["SENT"]
        return [str(s[i]) for i in range(1, len(s) + 1)]

    def gear_len(self):
        return self.g["peerStats"]["gearQueue"] and len(self.g["peerStats"]["gearQueue"]) or 0

    def meeting_len(self):
        return len(self.g["peerQueue"])

    # ── поведение ────────────────────────────────────────────────────────
    def test_gear_goes_immediately_when_the_meeting_queue_is_empty(self):
        self.fill_gear(3)
        self.g["TestDrain"]()
        sent = self.sent()
        self.assertEqual(1, len(sent), "при пустой очереди встреч gear не ушёл")
        self.assertTrue(sent[0].startswith("G7;"), sent[0][:12])

    def test_gear_is_not_starved_by_a_full_meeting_queue(self):
        # Это и был живой дефект: 55 встреч в очереди -> gearSent=0 навсегда.
        self.fill_meetings(50)
        self.fill_gear(5)
        sent_gear = 0
        for _ in range(30):
            self.g["TestDrain"]()
        for payload in self.sent():
            if payload.startswith("G7;"):
                sent_gear += 1
        self.assertGreater(sent_gear, 0,
                           "gear не отправился ни разу при непустой очереди встреч")

    def test_meetings_still_get_most_of_the_turns(self):
        # Обратная сторона: gear не должен захватить канал целиком.
        self.fill_meetings(50)
        self.fill_gear(5)
        for _ in range(30):
            self.g["TestDrain"]()
        sent = self.sent()
        gear = sum(1 for p in sent if p.startswith("G7;"))
        meetings = len(sent) - gear
        self.assertGreater(meetings, gear,
                           "встречи (%d) не получают большинства слотов против gear (%d)"
                           % (meetings, gear))

    def test_full_gear_queue_gets_more_turns_than_a_short_one(self):
        # При переполненной очереди gear чередование чаще: иначе следующая
        # запись вытесняется, а это гарантированная потеря.
        self.fill_meetings(50)
        self.fill_gear(24)          # ровно PEER_GEAR_QUEUE_MAX
        for _ in range(20):
            self.g["TestDrain"]()
        full_gear_sends = sum(1 for p in self.sent() if p.startswith("G7;"))
        self.assertGreater(full_gear_sends, 0,
                           "переполненная очередь gear не получила слотов")

    def test_skipped_gear_turn_does_not_eat_the_meeting_slot(self):
        # PeerDrainGear может НЕ отправить: например, снапшот не собрался в
        # поток (все слоты вне диапазона). Тогда слот отправки не должен
        # пропадать — встречи обязаны уйти в этом же вызове, иначе один битый
        # снапшот блокировал бы канал.
        self.fill_meetings(10)
        key = "Broken-" + REALM
        self.g["DB"]["players"][key] = self.lua.table_from(
            {"name": "Broken", "realm": REALM})
        self.g["TestQueueGear"](key, self.lua.table_from({
            "at": 1795167000, "ids": "0:5,20:7",   # недопустимые слоты
            "ilvl": 10, "slots": 2,
        }))
        self.assertEqual(1, self.gear_len(), "сломанный снапшот не попал в очередь")
        # Слот gear достаётся не первому вызову, поэтому прокручиваем несколько:
        # важно, что встречи идут на КАЖДОМ вызове, а битая запись исчезает,
        # когда gear получает свой слот, — иначе она висела бы в очереди вечно.
        for _ in range(6):
            self.g["TestDrain"]()
        sent = self.sent()
        self.assertTrue(sent, "встречи не отправились")
        self.assertFalse(any(p.startswith("G7;") for p in sent),
                         "битый снапшот всё-таки ушёл в канал")
        self.assertEqual(0, self.gear_len(),
                         "битая запись осталась в очереди навсегда")

    def test_gear_dropped_counter_is_not_used_as_a_priority_signal(self):
        # gearDropped не должен сбрасываться в ноль самим чередованием —
        # это накопительный счётчик потерь.
        self.fill_meetings(5)
        self.fill_gear(2)
        self.lua.execute("peerStats.gearDropped = 7")
        self.g["TestDrain"]()
        self.assertEqual(7, self.g["peerStats"]["gearDropped"])


class GearStarvationScenarioTests(unittest.TestCase):
    """Сценарий живого дефекта целиком: постоянный приток встреч.

    В SV 20.11.2026 очередь встреч стояла на 55 из 60 и НЕ пустела, потому что
    новые встречи прибывают быстрее, чем hardware-гейт даёт слоты отправки.
    Gear ждал пустой очереди — и не уходил никогда.

    Здесь это воспроизведено по шагам: на каждом шаге добавляются встречи, раз в
    четыре шага — снапшот. Проверяется, что gear прогрессирует, а встречи
    по-прежнему получают большинство слотов.
    """

    HARNESS_GAP = HARNESS.replace(
        "PEER_GAP, PEER_GAP_BUSY, PEER_BUSY_LEN = 0, 0, 999",
        "PEER_GAP, PEER_GAP_BUSY, PEER_BUSY_LEN = 7, 4, 20").replace(
        "time = function() return 1795167302 end",
        "NOW = 1795167302\n"
        "time = function() return NOW end\n"
        "function Advance(n) NOW = NOW + n end")

    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(CONST_PRELUDE + "\n" + RACE_PRELUDE + "\n" + self.HARNESS_GAP
                         + "\n" + send_block() + "\n"
                         "TestDrain = DrainPeerQueue\n"
                         "TestQueueGear = PeerQueueGear\n"
                         "TestQueuePeer = QueuePeerNew\n")
        self.g = self.lua.globals()

    def run_scenario(self):
        g = self.g
        advance = g["Advance"]

        def meetings(k0, n):
            for i in range(k0, k0 + n):
                nm = "Meet%d" % i
                g["TestQueuePeer"](g["DB"], self.lua.table_from({
                    "key": nm + "-" + REALM, "name": nm, "realm": REALM,
                    "class": "MAGE", "level": 20 + i % 40, "race": "Human",
                    "faction": "Alliance", "zone": "Goldwyn", "zoneId": 1429,
                    "source": "who", "observedAt": 1795167000 + i}))

        def gear(k0, n):
            for i in range(k0, k0 + n):
                nm = "Geared%d" % i
                k = nm + "-" + REALM
                g["DB"]["players"][k] = self.lua.table_from({"name": nm, "realm": REALM})
                g["TestQueueGear"](k, self.lua.table_from({
                    "at": 1795167000 + i, "ids": "1:279391,2:273457", "ilvl": 22,
                    "slots": 2, "imp": "C0cBZcHs6hiHBl7Csp3hvR+3R+AghPwMmBAAAAAA"}))

        meetings(0, 30)
        gear(0, 6)
        m_i, g_i = 30, 6
        for step in range(40):
            meetings(m_i, 2)          # постоянный приток встреч
            m_i += 2
            if step % 4 == 0:
                gear(g_i, 1)
                g_i += 1
            advance(8)
            g["TestDrain"]()

        sent = [str(g["SENT"][i]) for i in range(1, len(g["SENT"]) + 1)]
        return sent

    def test_gear_progresses_under_constant_meeting_pressure(self):
        sent = self.run_scenario()
        gear_sent = sum(1 for p in sent if p.startswith("G7;"))
        self.assertGreater(gear_sent, 0,
                           "gear не отправился ни разу при постоянном притоке "
                           "встреч — это ровно живой дефект 20.11.2026")
        self.assertGreater(len(sent) - gear_sent, gear_sent,
                           "gear захватил больше половины канала — встречи голодают")
        # очередь снапшотов не должна остаться переполненной
        self.assertLess(len(self.g["peerStats"]["gearQueue"]), 24,
                        "очередь gear осталась переполненной после прогона")


if __name__ == "__main__":
    unittest.main()
