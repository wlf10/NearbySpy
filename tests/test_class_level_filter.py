"""Выборка по классу и уровню в окне игроков (Lua 5.1, real TacticalVisible).

Три селектора стоят в одну строку под тулбаром: мир (был), класс, уровень.
Класс и уровень складываются (AND) — «паладины 40+» это один запрос.

Что держит файл:
  - фильтр по классу показывает только строки этого класса; записи без класса
    («?») доступны отдельным пунктом и не прячутся молча;
  - фильтр по диапазону уровня (1-10, 11-20, ...) и по точному уровню;
  - точный уровень и диапазон взаимоисключающи;
  - запись без уровня не попадает ни в один диапазон;
  - фильтры складываются с фильтром по миру.
"""

from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

from nsp_helpers import CONST_PRELUDE

SOURCE = Path(__file__).resolve().parents[1] / "NearbySpy.lua"


class FilterTests(unittest.TestCase):
    def setUp(self):
        source = SOURCE.read_text(encoding="utf-8")
        # Блок от tactical до конца селекторов: фильтры живут в TacticalVisible,
        # а список классов и подпись уровня — рядом с циклерами, ниже.
        # Граница с запасным вариантом: на коде БЕЗ селекторов (проверка
        # «тест красный на старом коде») маркера нет — режем по старой границе,
        # и тест падает на ассертах, а не на поиске строки.
        start = source.index("local tactical = {rows = {")
        end = source.index("-- Точный уровень: клик по столбцу гистограммы.") \
            if "-- Точный уровень: клик по столбцу гистограммы." in source \
            else source.index("-- Relative time for the contact column")
        if "-- Точный уровень: клик по столбцу гистограммы." in source:
            end = source.index("\nend\n", end) + len("\nend\n")
        block = source[start:end]
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(
            CONST_PRELUDE + "\n"
            "time = function() return 1000 end\n"
            "ALL_REALMS = true\n"
            "DB = {players = {}}\n"
            "function GetDB() return DB end\n"
            + block + "\n"
            "TestVisible = TacticalVisible\n"
            "TestStat = tactical\n"
            "TestLevelLabel = TacticalLevelLabel\n"
            "TestClassList = TacticalClassList\n"
        )

    def visible(self, player, **filters):
        stats = self.lua.globals()["TestStat"]
        for key in ("classFilter", "levelFilter", "levelExact", "realmFilter"):
            stats[key] = None
        for key, value in filters.items():
            stats[key] = value
        return self.lua.globals()["TestVisible"](self.lua.table_from(player), 1000)

    # --- класс -----------------------------------------------------------

    def test_class_filter_keeps_only_that_class(self):
        self.assertTrue(self.visible({"class": "PALADIN", "lastSeen": 999}, classFilter="PALADIN"))
        self.assertFalse(self.visible({"class": "MAGE", "lastSeen": 999}, classFilter="PALADIN"))

    def test_class_filter_is_case_insensitive(self):
        # the addon stores class file keys in upper case, but an old save may
        # hold "paladin" — the filter must not lose the row over the case
        self.assertTrue(self.visible({"class": "paladin", "lastSeen": 999}, classFilter="PALADIN"))

    def test_rows_without_a_class_are_reachable_as_the_pseudo_class(self):
        self.assertFalse(self.visible({"level": 30}, classFilter="PALADIN"))
        self.assertTrue(self.visible({"level": 30}, classFilter="?"))
        self.assertTrue(self.visible({"class": "", "level": 30}, classFilter="?"))

    def test_no_class_filter_shows_everything(self):
        self.assertTrue(self.visible({"class": "MAGE"}))
        self.assertTrue(self.visible({"class": ""}))

    # --- уровень ---------------------------------------------------------

    def test_level_range_filter(self):
        self.assertTrue(self.visible({"level": 5}, levelFilter=self.lua.table_from([1, 10])))
        self.assertTrue(self.visible({"level": 10}, levelFilter=self.lua.table_from([1, 10])))
        self.assertFalse(self.visible({"level": 11}, levelFilter=self.lua.table_from([1, 10])))

    def test_exact_level_filter(self):
        self.assertTrue(self.visible({"level": 56}, levelExact=56))
        self.assertFalse(self.visible({"level": 55}, levelExact=56))
        self.assertFalse(self.visible({"level": 57}, levelExact=56))

    def test_row_without_a_level_is_not_in_any_range(self):
        # a chat-channel row has no level; it must not sneak into "1-10"
        self.assertFalse(self.visible({"class": "MAGE"}, levelFilter=self.lua.table_from([1, 10])))
        self.assertFalse(self.visible({"class": "MAGE"}, levelExact=1))

    def test_class_and_level_filters_combine(self):
        both = dict(classFilter="PALADIN", levelFilter=self.lua.table_from([41, 50]))
        self.assertTrue(self.visible({"class": "PALADIN", "level": 45}, **both))
        self.assertFalse(self.visible({"class": "MAGE", "level": 45}, **both))
        self.assertFalse(self.visible({"class": "PALADIN", "level": 30}, **both))

    def test_class_and_level_combine_with_the_realm_filter(self):
        player = {"class": "PALADIN", "level": 45, "realm": "CAMWOW EU5 Realm 1 PvE"}
        self.assertTrue(self.visible(player, classFilter="PALADIN",
                                     realmFilter="CAMWOW EU5 Realm 1 PvE"))
        self.assertFalse(self.visible(player, classFilter="PALADIN",
                                      realmFilter="CAMWOW EU4 Realm 6 PvP"))

    # --- подписи ---------------------------------------------------------

    def test_level_label(self):
        self.assertEqual("1-10", str(self.lua.globals()["TestLevelLabel"](self.lua.table_from([1, 10]))))
        self.assertEqual("56", str(self.lua.globals()["TestLevelLabel"](56)))

    def test_class_list_is_built_from_the_data(self):
        # GetDB() в прелюдии отдаёт свою таблицу; подменяем её на базу с
        # игроками — список классов строится из данных, а не зашит.
        self.lua.execute(
            "DB = {players = {"
            "{name='A', class='PALADIN', realm='r'},"
            "{name='B', class='MAGE', realm='r'},"
            "{name='C', class='PALADIN', realm='r'},"
            "{name='D', class='', realm='r'}}}"
        )
        lst = [str(x) for x in self.lua.globals()["TestClassList"]().values()]
        self.assertIn("PALADIN", lst)
        self.assertIn("MAGE", lst)
        self.assertIn("?", lst)
        # the frequent class comes first — the cycler starts from the top
        self.assertEqual("PALADIN", lst[0])


if __name__ == "__main__":
    unittest.main()
