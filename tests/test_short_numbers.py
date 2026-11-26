"""Компактные числа в окне: 20257 → «20.3k» (Lua 5.1).

Владелец 26.11.2026: «большие числа как 20 257 надо сократить в табе например
20.2k». Числа в окне шестизначные (всего в базе 63 401, новых за сессию 20 257)
и распирали табы, карточки и подпись графика уровней.

Правила: до 1000 — как есть; дальше k/M/B с одним знаком после точки, хвостовой
«.0» срезается; точка, а не запятая (как в примере владельца).
"""

from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

ADDON = Path(__file__).resolve().parents[1]
SOURCE = ADDON / "NearbySpy.lua"
LOCALE = ADDON / "NearbySpy_Locale.lua"


def formatter_block() -> str:
    src = SOURCE.read_text(encoding="utf-8")
    start = src.index("function NspShortNum(v)")
    return src[start:src.index("\nend", start) + 4]


class ShortNumTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(formatter_block())
        self.f = self.lua.globals()["NspShortNum"]

    def test_small_numbers_stay_exact(self):
        for v in (0, 1, 47, 500, 999):
            with self.subTest(v=v):
                self.assertEqual(str(v), self.f(v))

    def test_thousands(self):
        cases = {1000: "1k", 1049: "1k", 1050: "1.1k", 1500: "1.5k",
                 12400: "12.4k", 20257: "20.3k", 63401: "63.4k"}
        for v, want in cases.items():
            with self.subTest(v=v):
                self.assertEqual(want, self.f(v))

    def test_three_digits_drop_the_fraction(self):
        self.assertEqual("100k", self.f(99999))
        self.assertEqual("123k", self.f(123456))
        self.assertEqual("999k", self.f(999499))

    def test_unit_promotes_instead_of_printing_1000k(self):
        """Округление до 1000 единиц младшего разряда — уже старший разряд."""
        self.assertEqual("1M", self.f(999500))
        self.assertEqual("1M", self.f(1000000))
        self.assertEqual("999M", self.f(999499999))
        self.assertEqual("1B", self.f(999500000))

    def test_millions(self):
        self.assertEqual("1.5M", self.f(1500000))
        self.assertEqual("20.3M", self.f(20257000))

    def test_junk_is_tolerated(self):
        """В окне встречаются nil и строки — форматтер не должен падать."""
        self.assertEqual("0", self.f(None))
        self.assertEqual("12.3k", self.f("12345"))
        self.assertEqual("2.5k", self.f(2549.6))

    def test_the_owner_example(self):
        """«большие числа как 20 257 ... например 20.2k» — формат совпадает."""
        out = self.f(20257)
        self.assertTrue(out.endswith("k"), out)
        self.assertIn(".", out, "нет десятичной точки: %s" % out)
        self.assertNotIn(",", out, "запятая вместо точки: %s" % out)


class RenderedNumbersTests(unittest.TestCase):
    """Ни одно число в окне не должно печататься сырым через %d."""

    def setUp(self):
        full = SOURCE.read_text(encoding="utf-8")
        # Только тело TacticalUpdate: в файле есть ещё отладочные строки чата
        # (D(...) с «%d»), они к числам окна отношения не имеют.
        start = full.index("TacticalUpdate = function()")
        self.src = full[start:full.index("local function BuildWindow()", start)]

    def test_no_raw_counters_in_the_window(self):
        offenders = []
        for line in self.src.splitlines():
            if "NspShortNum" in line or "SetValue" in line or "SetWidth" in line:
                continue   # внутренние значения, не текст
            # счётчики игроков печатались как %d / tostring(...)
            if "%d (" in line and "format" in line:
                offenders.append(line.strip())
            if "tostring(st.total)" in line or "tostring(tabN." in line:
                offenders.append(line.strip())
        self.assertEqual([], offenders,
                         "сырые числа в окне: %s" % offenders[:3])

    def test_chart_label_takes_shortened_counters(self):
        line = [l for l in self.src.splitlines() if "CHART_LABEL" in l]
        self.assertEqual(1, len(line))
        joined = "".join(self.src.splitlines()[self.src.splitlines().index(line[0]):][:3])
        self.assertIn("NspShortNum", joined,
                      "подпись графика печатает счётчики сырыми")

    def test_locales_match_the_placeholders(self):
        """Шесть локалей: два счётчика стали %s, остальные подстановки целы."""
        loc = LOCALE.read_text(encoding="utf-8")
        lines = [l for l in loc.splitlines() if "CHART_LABEL" in l]
        self.assertEqual(6, len(lines))
        for line in lines:
            with self.subTest(line=line.strip()[:40]):
                # уровень и среднее остаются числовыми, счётчики — строковые
                self.assertEqual(2, line.count("%s"), line.strip())
                self.assertEqual(1, line.count("%d"), line.strip())
                self.assertEqual(1, line.count("%.1f"), line.strip())


if __name__ == "__main__":
    unittest.main()
