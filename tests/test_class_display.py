"""Class names come from the CLIENT, never from an addon translation table.

Decision (user, 09.11.2026): names taken from the game — class and zone — are shown
as the game shows them. Switching the addon interface language changes the addon's
own labels, not game data. So with a Russian client the class stays "Маг" even when
the interface is English.

The one translation that IS needed: a peer packet carries only the class file key
("DRUID"), so the key has to be turned into the CLIENT's localized string,
otherwise a channel row shows "DRUID" next to "Друид" for a local one.
"""

from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

SOURCE = Path(__file__).resolve().parents[1] / "NearbySpy.lua"


def blocks() -> str:
    src = SOURCE.read_text(encoding="utf-8")
    start = src.index("function ClassDisplayName(file, fallback)")
    end = src.index("function ClassLocFromFile(file)")
    loc = src[end:src.index("-- localized class name -> file key", end)]
    return src[start:end] + "\n" + loc


PRELUDE = r"""
LOCALE = {enUS = {}, ruRU = {}}
function GetLocale() return "ruRU" end
NearbySpy = {locale = "enUS"}
LOCALIZED_CLASS_NAMES_MALE = {DRUID = "Друид", MAGE = "Маг", WARRIOR = "Воин"}
LOCALIZED_CLASS_NAMES_FEMALE = {}
"""


class ClassDisplayTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(PRELUDE + "\n" + blocks() + "\nTestName = ClassDisplayName\n")

    def name(self, file, fallback=None):
        return self.lua.globals()["TestName"](file, fallback)

    def test_interface_language_does_not_translate_game_names(self):
        # English interface, Russian client: the class stays as the game shows it
        self.assertEqual("Маг", self.name("MAGE", "Маг"))

    def test_peer_row_gets_the_client_localized_name(self):
        # the packet has only the key; it must not be displayed raw
        self.assertEqual("Друид", self.name("DRUID", None))

    def test_stored_class_loc_wins_over_the_key(self):
        self.assertEqual("Чернокнижник", self.name("WARLOCK", "Чернокнижник"))

    def test_unknown_custom_class_falls_back_to_the_client_name(self):
        self.assertEqual("Небеснорожденный", self.name("SKYBORNE", "Небеснорожденный"))

    def test_nothing_known_still_yields_a_string(self):
        self.assertEqual("?", self.name(None, None))


if __name__ == "__main__":
    unittest.main()
