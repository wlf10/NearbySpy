"""Кодирование класса/расы/фракции в один символ + обратная совместимость N6.

Зачем: эти три поля — конечные множества, а в тексте они самые дорогие после
имени. "PALADIN;Human;Alliance" = 23 байта, кодами — 5. На длинной кириллической
зоне запись падала с 87 до 68 байт, и в сообщение влезало 3 записи вместо 2.

⚠️ Фракцию НЕЛЬЗЯ выводить из расы: кастомная раса Skyborne встречается у ОБОИХ
фракций (1506 у Альянса, 26 у Орды в живом файле). Поэтому три поля кодируются
независимо.

⚠️ Следующая кастомная раса не должна потеряться: код 'z' означает «не из
таблицы», и настоящее значение едет текстом в дополнительном поле записи.

Что держит файл:
  - кодирование обратимо для всех известных значений;
  - неизвестное значение не теряется (уходит текстом), а не превращается в nil;
  - приём понимает ВСЕ версии N2…N6 — это и есть плавный переход;
  - пакет N6 с чужим кодом класса отвергается, а не создаёт игрока без класса.
"""

from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

from nsp_helpers import CONST_PRELUDE

ADDON = Path(__file__).resolve().parents[1]
SOURCE = ADDON / "NearbySpy.lua"


def codes_block() -> str:
    src = SOURCE.read_text(encoding="utf-8")
    start = src.index("NSP_PEER_CODES = {")
    end = src.index("-- Peers now carry the place as well")
    return src[start:end]


class CodecTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(codes_block())
        self.g = self.lua.globals()

    def enc(self, kind, value):
        r = self.g["PeerEncode"](kind, value)
        return str(r[0]), bool(r[1])

    def dec(self, kind, code, text=None):
        return self.g["PeerDecode"](kind, code, text)

    # --- кодирование -------------------------------------------------------

    def test_every_known_class_round_trips(self):
        classes = ["WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST",
                   "SHAMAN", "MAGE", "WARLOCK", "DRUID"]
        for name in classes:
            code, needs_text = self.enc("class", name)
            self.assertEqual(1, len(code), "код класса не однобуквенный: %r" % code)
            self.assertFalse(needs_text)
            self.assertEqual(name, self.dec("class", code),
                             "обратное декодирование сломалось для %s" % name)

    def test_every_known_race_round_trips_including_custom(self):
        # Skyborne — кастомная раса Forever: она ОБЯЗАНА иметь код, иначе каждая
        # запись с ней несла бы текст
        races = ["Human", "Dwarf", "NightElf", "Gnome",
                 "Orc", "Scourge", "Tauren", "Troll", "Skyborne"]
        for name in races:
            code, needs_text = self.enc("race", name)
            self.assertEqual(1, len(code))
            self.assertFalse(needs_text, "%s ушла текстом" % name)
            self.assertEqual(name, self.dec("race", code))

    def test_faction_round_trips(self):
        for name, expect in (("Alliance", "a"), ("Horde", "h")):
            code, needs_text = self.enc("faction", name)
            self.assertEqual(expect, code)
            self.assertFalse(needs_text)
            self.assertEqual(name, self.dec("faction", code))

    # --- расширяемость -----------------------------------------------------

    def test_unknown_value_is_flagged_for_text_not_lost(self):
        code, needs_text = self.enc("race", "Pandaren")
        self.assertEqual("z", code)
        self.assertTrue(needs_text, "неизвестное значение должно ехать текстом")
        # и декодируется обратно из текста
        self.assertEqual("Pandaren", self.dec("race", code, "Pandaren"))

    def test_empty_value_is_unknown_without_text(self):
        for value in (None, ""):
            code, needs_text = self.enc("race", value)
            self.assertEqual("z", code)
            self.assertFalse(needs_text, "пустое значение не требует текста")

    def test_codes_are_unique_within_a_kind(self):
        for kind in ("class", "race", "faction"):
            seen = {}
            for code, name in self.g["NSP_PEER_CODES"][kind].items():
                self.assertNotIn(name, seen, "дубль значения %s в %s" % (name, kind))
                seen[name] = code


class N6ReceiveTests(unittest.TestCase):
    """Приём N6: коды декодируются, старые протоколы по-прежнему понимаются."""

    def setUp(self):
        src = SOURCE.read_text(encoding="utf-8")
        start = src.index("local function ReceivePeerMessage(")
        end = src.index("local function JoinPeerChannel()")
        block = src[start:end]
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(CONST_PRELUDE + "\n"
                         + codes_block() + "\n"
                         "time = function() return 1794300000 end\n"
                         "UnitName = function() return 'Me', nil end\n"
                         "function PlayerRealm() return 'R' end\n"
                         "function PeerChannelName() return 'nearbyspyh' end\n"
                         "function PeerField(s, n) return type(s) == 'string' and #s > 0 "
                         "and #s <= n and not s:find('[%c|;]') end\n"
                         "function PeerCoord(v) return string.format('%.4f', v) end\n"
                         "function ClassLocFromFile() return nil end\n"
                         "PEER_BATCH_MAX, PEER_CLOCK_SKEW = 5, 3600\n"
                         "peerStats = {seen = 0, valid = 0, received = 0, merged = 0, "
                         "rejected = 0, foreign = 0, selfEcho = 0, inStart = 0, inCount = 0, "
                         "rejectLogged = {}}\n"
                         "function PeerSync() end\n"
                         "local function D() end\n"
                         "function PeerEsc(s, n) return tostring(s) end\n"
                         "DB = {peerEnabled = true, peerAllRealms = true, game = 'forever', "
                         "players = {}, debug = {}}\n"
                         "function GetDB() return DB end\n"
                         "QUEUE = {}\n"
                         "QueuePeerNew = function(db, data) QUEUE[#QUEUE + 1] = data end\n"
                         "function UpsertPlayer(db, data)\n"
                         "  local k = data.name .. '-' .. data.realm\n"
                         "  if db.players[k] then return false end\n"
                         "  db.players[k] = { name = data.name, level = data.level,\n"
                         "                    class = data.class, race = data.race,\n"
                         "                    faction = data.faction }\n"
                         "  return true\n"
                         "end\n"
                         + block + "\n"
                         "TestReceive = ReceivePeerMessage\n"
                         "TestDB = DB\n"
                         "TestStats = peerStats\n")

    def player(self, name):
        return self.lua.globals()["TestDB"]["players"][name + "-R"]

    def recv(self, msg):
        self.lua.globals()["TestReceive"](msg, "Sender-R")

    def test_n6_decodes_all_three_codes(self):
        # b = PALADIN, a = Human, a = Alliance
        self.recv("N6;forever;R;Alice;b;20;a;a;12;Elwynn;-;-;1794300000")
        p = self.player("Alice")
        self.assertIsNotNone(p, "запись N6 не принята")
        self.assertEqual("PALADIN", p["class"])
        self.assertEqual("Human", p["race"])
        self.assertEqual("Alliance", p["faction"])

    def test_n6_custom_race_travels_as_text(self):
        # раса не из таблицы: код 'z' и текст в 14-м поле
        self.recv("N6;forever;R;Bob;g;30;z;a;12;Elwynn;-;-;1794300000;Pandaren")
        p = self.player("Bob")
        self.assertIsNotNone(p, "запись с кастомной расой потеряна")
        self.assertEqual("Pandaren", p["race"])
        self.assertEqual("MAGE", p["class"])

    def test_n6_unknown_class_code_is_rejected(self):
        # одиночная 'q' нет в таблице классов и не помечена как 'z' с текстом
        self.recv("N6;forever;R;Ghost;X;20;a;a;12;Elwynn;-;-;1794300000")
        self.assertIsNone(self.player("Ghost"))

    # --- обратная совместимость -------------------------------------------

    def test_old_protocols_still_work(self):
        # N4 (текстовые поля, без времени-кода) — старый клиент в канале
        self.recv("N4;forever;R;Old4;MAGE;20;Human;Alliance;12;Elwynn;-;-;1794300000")
        p = self.player("Old4")
        self.assertIsNotNone(p, "N4 перестал приниматься")
        self.assertEqual("MAGE", p["class"])
        self.assertEqual("Human", p["race"])

    def test_n3_without_time_still_works(self):
        self.recv("N3;forever;R;Old3;MAGE;20;Human;Alliance;12;Elwynn;-;-")
        self.assertIsNotNone(self.player("Old3"), "N3 перестал приниматься")

    def test_n2_minimal_still_works(self):
        self.recv("N2;forever;R;Old2;MAGE;20;Human;Alliance")
        self.assertIsNotNone(self.player("Old2"), "N2 перестал приниматься")


if __name__ == "__main__":
    unittest.main()
