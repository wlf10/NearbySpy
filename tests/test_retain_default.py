#!/usr/bin/env python3
"""Срок хранения записей по умолчанию: умолчание применяется, явный 0 держится.

Контракт, который здесь проверяется (и который легко сломать незаметно):

  1. NSP_CONST.RETAIN_DAYS задаёт умолчание — сейчас 7 дней;
  2. db.retainDays == nil («не настраивали») → подставляется умолчание;
  3. db.retainDays == 0 («/nspy retain off») → остаётся 0, умолчание НЕ
     возвращается: иначе выключенная чистка включилась бы при следующем входе;
  4. явное число не перетирается.

Тест исполняет фрагмент GetDB из продакшна, а не его пересказ. Суть в том,
что настройка читается при КАЖДОЙ загрузке: клиент грузит SavedVariables
раньше аддона, и только GetDB решает, что делать с отсутствующим ключом.

Запуск: python tests/test_retain_default.py
"""
import unittest
from pathlib import Path

from lupa.lua51 import LuaRuntime

ADDON = Path(__file__).resolve().parents[1] / "NearbySpy.lua"
LOCALE = Path(__file__).resolve().parents[1] / "NearbySpy_Locale.lua"

PRELUDE = """
GetLocale = function() return "enUS" end
NSP_CONST = nil
"""


def default_snippet() -> str:
    """Вырезает из GetDB блок применения умолчания retention."""
    src = ADDON.read_text(encoding="utf-8")
    marker = "if NearbySpy.retainDays == nil then"
    start = src.index(marker)
    tail = src.index("\n    end\n", start) + len("\n    end\n")
    return src[start:tail]


class RetainDefaultTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(PRELUDE)
        # константы берём из настоящего файла локали, не из литерала в тесте
        self.lua.execute(LOCALE.read_text(encoding="utf-8"))
        # и код умолчания — из настоящего GetDB
        self.snippet = default_snippet()
        self.lua.globals()["SNIPPET"] = self.snippet

    def apply(self, retain):
        """Гоняет фрагмент над таблицей NearbySpy и возвращает итоговый срок."""
        self.lua.execute("NearbySpy = {}")
        if retain is not None:
            self.lua.execute(f"NearbySpy.retainDays = {retain}")
        self.lua.execute(self.snippet)
        return self.lua.eval("NearbySpy.retainDays")

    def test_default_constant_is_seven_days(self):
        days = self.lua.eval("NSP_CONST.RETAIN_DAYS")
        self.assertEqual(days, 7)

    def test_missing_setting_gets_default(self):
        self.assertEqual(self.apply(None), 7)

    def test_explicit_off_stays_off(self):
        # /nspy retain off пишет 0; умолчание не должно вернуться
        self.assertEqual(self.apply(0), 0)

    def test_explicit_number_is_kept(self):
        self.assertEqual(self.apply(14), 14)

    def test_snippet_is_the_real_one(self):
        # защита от «тест проверяет пустоту»: фрагмент обязан читать поле
        self.assertIn("NearbySpy.retainDays", self.snippet)
        self.assertIn("NSP_CONST", self.snippet)


if __name__ == "__main__":
    unittest.main(verbosity=2)
