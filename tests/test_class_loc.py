"""Localized class name for rows that arrived over the peer channel (Lua 5.1).

A peer packet carries only the class FILE KEY ("DRUID"); a locally observed row
carries the localized name the client returned ("Друид"). The window printed
`classLoc or class`, so a channel row showed "DRUID" next to our own "Друид" in
the same list — the same field, two spellings.

The translation happens at DISPLAY time, so records already stored in
SavedVariables are fixed too, and at intake so new records carry classLoc.
"""

from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

SOURCE = Path(__file__).resolve().parents[1] / "NearbySpy.lua"


def helper() -> str:
    src = SOURCE.read_text(encoding="utf-8")
    start = src.index("function ClassLocFromFile(file)")
    end = src.index("-- localized class name -> file key", start)
    return src[start:end]


class ClassLocTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(
            'LOCALIZED_CLASS_NAMES_MALE = {DRUID="Друид", MAGE="Маг", WARRIOR="Воин"}\n'
            'LOCALIZED_CLASS_NAMES_FEMALE = {DRUID="Друидка"}\n'
            + helper() + "\nTestLoc = ClassLocFromFile\n")

    def loc(self, f):
        return self.lua.globals()["TestLoc"](f)

    def test_file_key_becomes_the_localized_name(self):
        self.assertEqual("Друид", self.loc("DRUID"))

    def test_male_form_is_preferred_over_female(self):
        # the client has both; a list of players must not alternate genders
        self.assertEqual("Друид", self.loc("DRUID"))

    def test_unknown_class_stays_untouched(self):
        # a custom server class has no entry: showing the raw key is honest,
        # inventing a translation is not
        self.assertIsNone(self.loc("SKYBORNE"))

    def test_empty_and_nil_are_tolerated(self):
        self.assertIsNone(self.loc(None))
        self.assertIsNone(self.loc(""))

    def test_falls_back_to_the_female_table(self):
        self.lua.execute('LOCALIZED_CLASS_NAMES_MALE = {}\n'
                         'LOCALIZED_CLASS_NAMES_FEMALE = {DRUID="Друидка"}')
        self.assertEqual("Друидка", self.loc("DRUID"))

    def test_survives_a_client_without_the_male_table(self):
        self.lua.execute("LOCALIZED_CLASS_NAMES_MALE = nil")
        self.assertEqual("Друидка", self.loc("DRUID"))


if __name__ == "__main__":
    unittest.main()
