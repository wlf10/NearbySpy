"""Геометрия окна игроков: шапка таблицы и строки живут по одним числам.

Ширина окна — одна из вещей, которую правят чаще всего, и у неё есть тихая
поломка: заголовки колонок стоят отдельными числами, строки — своими. Сдвинул
окно и забыл один offset — заголовок "ЗОНА" оказывается над колонкой профиля,
а на глаз это читается как "данные поехали".

Что держит файл:
  - заголовки и ячейки строк берут X из ОДНИХ констант NSP_CONST;
  - колонки не налезают друг на друга и влезают в строку;
  - окно не шире типичного экрана.
"""

from pathlib import Path
import re
import unittest


SOURCE = Path(__file__).resolve().parents[1] / "NearbySpy.lua"
LOCALE = Path(__file__).resolve().parents[1] / "NearbySpy_Locale.lua"


def const(name):
    """Значение NSP_CONST.<name> из файла локалей."""
    src = LOCALE.read_text(encoding="utf-8")
    m = re.search(r"\b%s\s*=\s*(-?\d+)\s*," % name, src)
    if not m:
        raise AssertionError("NSP_CONST.%s не найдена" % name)
    return int(m.group(1))


class ColumnGeometryTests(unittest.TestCase):
    def test_columns_do_not_overlap_and_fit_the_row(self):
        cols = [
            ("name", const("COL_NAME_X"), const("COL_NAME_W")),
            ("profile", const("COL_PROF_X"), const("COL_PROF_W")),
            ("zone", const("COL_ZONE_X"), const("COL_ZONE_W")),
            ("seen", const("COL_SEEN_X"), const("COL_SEEN_W")),
        ]
        for (n1, x1, w1), (n2, x2, _) in zip(cols, cols[1:]):
            self.assertLessEqual(x1 + w1, x2,
                                 "колонка %s (до %d) налезает на %s (с %d)" % (n1, x1 + w1, n2, x2))
        last_x, last_w = cols[-1][1], cols[-1][2]
        self.assertLessEqual(last_x + last_w, const("LIST_W"),
                             "последняя колонка выходит за строку")

    def test_row_and_window_widths_are_consistent(self):
        # строка = окно минус внутренние поля; шапка таблицы = окно минус 32
        self.assertEqual(const("WIN_W") - 68, const("LIST_W"))
        self.assertEqual(const("WIN_W") - 32, const("TOOLBAR_W"))

    def test_chart_bars_fit_the_chart(self):
        # 60 столбцов по шагу, начиная с отступа 9, плюс ширина столбца
        last_right = 9 + 59 * const("CHART_STEP") + (const("CHART_STEP") - 2.5)
        self.assertLessEqual(last_right, const("CHART_W"),
                             "гистограмма вылезает за панель")

    def test_classes_panel_stays_inside_the_window(self):
        right = const("CLASSES_X") + const("CLASSES_W")
        self.assertLessEqual(right, const("WIN_W") - 16,
                             "панель классов выходит за правое поле окна")
        # панель не должна наезжать на гистограмму (она левее)
        self.assertGreaterEqual(const("CLASSES_X"), 16 + const("CHART_W"),
                                "панель классов налезает на гистограмму")

    def test_window_fits_a_common_screen(self):
        # окно центрируется: 880x800 влезает в 1920x1080 и в 1440x900
        self.assertLessEqual(const("WIN_W"), 1440)
        self.assertLessEqual(const("WIN_H"), 900)


class ToolbarFilterTests(unittest.TestCase):
    """Пять табов фильтров обязаны идти ОДНОЙ строкой и не лезть на счётчик."""

    def test_five_tiles_fit_before_the_counter(self):
        x0 = const("FILTER_X0")
        w = const("FILTER_W")
        step = const("FILTER_STEP")
        last_right = x0 + 4 * step + w
        # счётчик прижат к правому краю тулбара: "500 / 14868" при 7pt ~ 55px
        counter_left = const("TOOLBAR_W") - const("COUNT_X") - 60
        self.assertLessEqual(last_right, counter_left,
                             "последний таб (до %d) налезает на счётчик (с %d)"
                             % (last_right, counter_left))

    def test_tiles_do_not_overlap(self):
        w = const("FILTER_W")
        step = const("FILTER_STEP")
        self.assertGreaterEqual(step, w, "шаг меньше ширины: табы перекрываются")

    def test_longest_localized_label_fits_one_line(self):
        # Подписи рисуются GameFontNormal (~12pt). Оценка ширины: 7px на символ
        # для латиницы/кириллицы. Берём САМУЮ ДЛИННУЮ метку из всех локалей
        # вместе с максимальным числом счётчика (5 знаков).
        longest = self.longest_label() + " 99999"
        need = len(longest) * 7
        available = const("FILTER_W") - 6
        self.assertLessEqual(need, available,
                             "«%s» (~%dpx) не влезает в %dpx — перенесётся на вторую строку"
                             % (longest, need, available))

    def longest_label(self):
        """Самая длинная метка таба по всем шести локалям."""
        src = LOCALE.read_text(encoding="utf-8")
        best = ""
        for key in ("UI_ALL", "UI_FRESH", "UI_NEW", "UI_PEER", "UI_PEER_NEW"):
            for m in re.finditer(r'\b%s\s*=\s*"([^"]*)"' % key, src):
                if len(m.group(1)) > len(best):
                    best = m.group(1)
        self.assertTrue(best, "метки табов не найдены в локалях")
        return best


class NoHardcodedLayoutTests(unittest.TestCase):
    """Числа колонок не должны встречаться в коде окна напрямую."""

    def test_header_and_rows_read_the_same_constants(self):
        src = SOURCE.read_text(encoding="utf-8")
        # заголовки
        for key in ("COL_NAME_X", "COL_PROF_X", "COL_ZONE_X", "COL_SEEN_X"):
            self.assertIn("NSP_CONST.%s" % key, src, "%s не используется" % key)
        # строки берут ширины из тех же констант
        for key in ("COL_NAME_W", "COL_PROF_W", "COL_ZONE_W", "COL_SEEN_W"):
            self.assertIn("NSP_CONST.%s" % key, src, "%s не используется" % key)

    def test_row_width_uses_the_constant(self):
        src = SOURCE.read_text(encoding="utf-8")
        self.assertIn("row:SetSize(NSP_CONST.LIST_W", src,
                      "ширина строки задана числом, а не константой")
        self.assertIn("content:SetSize(NSP_CONST.LIST_W", src,
                      "ширина контента задана числом, а не константой")


if __name__ == "__main__":
    unittest.main()
