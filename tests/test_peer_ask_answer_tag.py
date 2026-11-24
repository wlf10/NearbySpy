"""Ответ на запрос — отдельный тег A1, посторонние клиенты его выбрасывают.

Требование владельца (24.11.2026): «через запрос нужен отдельный код протокола,
чтобы другие отбрасывали эти пакеты». Причина: ответ адресован ОДНОМУ
запросившему, а обычные N7/G7 записывают ВСЕ клиенты канала — чужие базы
наполнялись бы данными, которых никто не просил.

Формат: `A1;nonce;<внутренний обычный пакет>` →
`A1;k3f;N7;f;realm;rec1,rec2` или `A1;k3f;G7;f;realm;name;time;flags;gear`.

Что проверяется — ТРИ разных получателя:
  1. обновлённый клиент, который сам просил (nonce совпал) — применяет;
  2. обновлённый клиент, который не просил (чужой/закрытый nonce) — выбрасывает
     и считает `askStray`, БД не трогает;
  3. старый клиент, у которого ветки A1 НЕТ вовсе — выбрасывает пакет по
     проверке числа полей. Это проверяется буквально: из того же среза кода
     удалена ветка A1, и пакет всё равно не доходит до данных.
"""

from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

from nsp_helpers import CONST_PRELUDE, RACE_PRELUDE

ADDON = Path(__file__).resolve().parents[1]
SOURCE = ADDON / "NearbySpy.lua"
REALM = "CAMWOW EU5 Realm 1 PvE"


def codec_block() -> str:
    src = SOURCE.read_text(encoding="utf-8")
    return src[src.index("NSP_PEER_CODES = {"):src.index("-- Peers now carry the place as well")]


def receive_block(drop_answer_branch: bool = False) -> str:
    """Приёмник целиком (включая ветки Q1/A1) или КАК У ПРОШЛОГО БИЛДА.

    drop_answer_branch=True буквально удаляет то, чего в прошлом билде не было:
    разбор Q1, разбор A1 и саму функцию ответа. Это и есть «другой клиент,
    который про A1 не знает» — у него этих строк в файле просто нет.
    Проверять отбрасывание на живой ветке бессмысленно: она пакет как раз
    принимает.
    """
    src = SOURCE.read_text(encoding="utf-8")
    start = src.index("local function ReceivePeerMessage(")
    end = src.index("local function JoinPeerChannel()")
    block = src[start:end]
    block += "\n" + src[src.index("function ReceivePeerGear(fields, sender)"):end]
    if drop_answer_branch:
        # разбор управляющих пакетов Q1 и A1 в диспетчере
        cut_from = block.index("    -- Запрос базы (Q1, 24.11.2026)")
        cut_to = block.index("    -- Признак пачки")
        block = block[:cut_from] + block[cut_to:]
        # сама функция ответа — от своего заголовка до приёма снапшотов
        fn_from = block.index("-- ── Ответ на запрос: пакет A1 (24.11.2026)")
        fn_to = block.index("-- ── Приём снапшота экипировки/билда")
        block = block[:fn_from] + block[fn_to:]
        assert 'fields[1] == "A1"' not in block, "ветка A1 осталась в срезе"
        assert "function ReceivePeerAnswer" not in block, "функция ответа осталась"
        assert 'fields[1] == "Q1"' not in block, "ветка Q1 осталась в срезе"
    return block


HARNESS = """
time = function() return 1794300000 end
UnitName = function() return 'Me', nil end
function PlayerRealm() return 'CAMWOW EU5 Realm 1 PvE' end
function PeerChannelName() return 'nearbyspyh' end
PEER_BATCH_SEP = ','
PEER_TAIL_SEP = '~'
function ZoneNameById(id) return nil end
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
-- Перехват главного следствия приёма: что именно попало бы в базу.
APPLIED = {}
function UpsertPlayer(db, data)
    APPLIED[#APPLIED + 1] = tostring(data.name)
    return true
end
NSP_INSPECT = nil
"""


class PeerAnswerTagTests(unittest.TestCase):
    def build(self, drop_answer_branch=False):
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute(CONST_PRELUDE + "\n" + RACE_PRELUDE + "\n" + codec_block() + "\n"
                    + HARNESS + "\n" + receive_block(drop_answer_branch) + "\n"
                    "TestReceive = ReceivePeerMessage\n"
                    "TestDB = DB\n"
                    "TestStats = peerStats\n")
        return lua, lua.globals()

    def setUp(self):
        self.lua, self.g = self.build()

    # --- helpers -------------------------------------------------------
    def record(self, name="Answered Hero"):
        # тело записи N7: имя;класс;уровень;раса;фракция;zoneId;x;y;время
        return ";".join([name, "a", "60", "a", "a", "12", "-", "-", "lfky"])

    def answer(self, nonce, inner=None):
        inner = inner or ("N7;f;" + REALM + ";" + self.record())
        return "A1;" + nonce + ";" + inner

    def recv(self, msg):
        self.g["TestReceive"](msg, "Answerer")

    def open_request(self, nonce="mine"):
        self.g["TestStats"]["askNonce"] = nonce
        self.g["TestStats"]["askWindowUntil"] = 1794300000 + 180

    def applied(self):
        return [str(self.g["APPLIED"][i]) for i in range(1, len(self.g["APPLIED"]) + 1)]

    @staticmethod
    def stat(table, key, default=0):
        """Поле счётчика, которого может ещё не быть: lupa отдаёт None.

        У lua-таблицы нет python-метода `.get`, поэтому отсутствие ключа надо
        проверять явно — иначе тест падает на TypeError вместо проверки.
        """
        value = table[key]
        return default if value is None else value

    # --- 1. свой ответ применяется -------------------------------------
    def test_own_answer_is_applied(self):
        self.open_request("mine")
        self.recv(self.answer("mine"))
        self.assertEqual(["Answered Hero"], self.applied())
        self.assertEqual(1, self.g["TestStats"]["askIn"])

    def test_answer_batch_of_records_is_applied_record_by_record(self):
        self.open_request("mine")
        inner = "N7;f;" + REALM + ";" + self.record("First") + "," + self.record("Second")
        self.recv(self.answer("mine", inner))
        self.assertEqual(["First", "Second"], self.applied())

    def test_gear_answer_inside_wrapper_is_accepted(self):
        self.open_request("mine")
        self.g["TestDB"]["players"]["Gear Hero-" + REALM] = self.lua.table_from(
            {"name": "Gear Hero", "realm": REALM})
        inner = "G7;f;" + REALM + ";Gear Hero;1794300000;g;AAHngADIABkAAlgAMg"
        self.recv(self.answer("mine", inner))
        # G7 не создаёт запись (orphan-логика), но пакет не отброшен как чужой
        self.assertEqual(1, self.g["TestStats"]["askIn"])
        self.assertEqual(0, self.stat(self.g["TestStats"], "askStray"))

    # --- 2. чужой ответ выбрасывается ----------------------------------
    def test_answer_for_another_request_is_discarded(self):
        self.open_request("mine")
        self.recv(self.answer("someoneelse"))
        self.assertEqual([], self.applied())
        self.assertEqual(1, self.g["TestStats"]["askStray"])
        self.assertEqual(0, self.stat(self.g["TestStats"], "askIn"))

    def test_answer_without_any_open_request_is_discarded(self):
        self.recv(self.answer("mine"))          # мы вообще ничего не спрашивали
        self.assertEqual([], self.applied())
        self.assertEqual(1, self.g["TestStats"]["askStray"])

    def test_answer_after_the_window_closed_is_discarded(self):
        self.open_request("mine")
        self.lua.execute("time = function() return 1794300000 + 181 end")
        self.recv(self.answer("mine"))
        self.assertEqual([], self.applied())
        self.assertEqual(1, self.g["TestStats"]["askStray"])

    def test_nested_answer_is_discarded(self):
        self.open_request("mine")
        self.recv("A1;mine;A1;mine;" + self.record())
        self.assertEqual([], self.applied())
        self.assertEqual(1, self.g["TestStats"]["askStray"])

    def test_inner_packet_of_unknown_type_is_discarded(self):
        self.open_request("mine")
        self.recv(self.answer("mine", "Z9;f;" + REALM + ";x"))
        self.assertEqual([], self.applied())
        self.assertEqual(1, self.g["TestStats"]["askStray"])

    def test_broken_wrapper_is_discarded(self):
        self.open_request("mine")
        self.recv("A1;mine")                    # нет внутреннего пакета
        self.assertEqual([], self.applied())
        self.assertEqual(1, self.g["TestStats"]["askStray"])

    # --- 3. СТАРЫЙ клиент (без ветки A1) --------------------------------
    def test_old_client_discards_the_answer_packet(self):
        _, g = self.build(drop_answer_branch=True)
        g["TestStats"]["askNonce"] = "mine"
        g["TestStats"]["askWindowUntil"] = 1794300000 + 180
        g["TestReceive"](self.answer("mine"), "Answerer")
        self.assertEqual([], [str(g["APPLIED"][i]) for i in range(1, len(g["APPLIED"]) + 1)])
        self.assertEqual(1, g["TestStats"]["rejected"])
        self.assertEqual(0, self.stat(g["TestStats"], "askIn"))

    def test_old_client_discards_the_request_packet_too(self):
        _, g = self.build(drop_answer_branch=True)
        g["TestReceive"]("Q1;f;" + REALM + ";1o;abc", "Requester")
        # у Q1 пять полей, у встреч 8/12/13/14 — старый приёмник отвергает
        self.assertEqual(1, g["TestStats"]["rejected"])
        self.assertIsNone(g["TestStats"]["askPending"])


if __name__ == "__main__":
    unittest.main()
