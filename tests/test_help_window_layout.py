"""Окно справки: строки обязаны помещаться и не наезжать друг на друга (Lua 5.1).

Два дефекта, которые были до правки (оба воспроизводимы арифметикой):
  - 22 команды при жёстком шаге 25 px от y = -49 давали последнюю строку на
    -574 при окне высотой 480: пять нижних строк рисовались ВНЕ рамки;
  - высота описания зависит от языка (русская и немецкая строка переносится на
    две строки там, где английская помещается в одну), а шаг был константным —
    строки накладывались друг на друга.

Что держит тест:
  - каждая строка попадает в холст скролла: низ последней строки не ниже границы
    содержимого;
  - соседние строки не пересекаются при САМЫХ ДЛИННЫХ описаниях (ru/de), и шаг
    равен измеренной высоте, а не константе;
  - холст — ребёнок скролла (иначе окно просто обрежет содержимое);
  - высота окна растёт под содержимое и упирается в потолок экрана; при
    маленьком экране остаётся скролл, а не обрезка;
  - смена языка пересобирает раскладку (тексты и высоты), а не только текст.
"""

from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

SOURCE = Path(__file__).resolve().parents[1] / "NearbySpy.lua"


# Заглушки клиента. Модель высоты текста повторяет поведение шрифта: описание
# шириной 440 px и 12 pt вмещает ~52 символа в строке (кириллица и немецкие
# слова шире), строка ~12 px; подпись команды — одна строка 14 px.
# Ровно эта модель и обнажала прежний шаг в 25 px.
PRELUDE = r"""
UIParent = { __h = 1080 }
function UIParent:GetHeight() return self.__h end
function UIParent:SetHeight(h) self.__h = h end
SCREEN_H = 1080
FRAMES = {}
function CreateFrame(kind, name, parent, template)
    local f = {
        __kind = kind, __name = name, __parent = parent, __template = template,
        __points = {}, __children = {}, __scripts = {},
    }
    f.SetSize = function(self, w, h) self.w, self.h = w, h end
    f.GetHeight = function(self) return self.h end
    f.GetWidth = function(self) return self.w end
    f.SetPoint = function(self, ...) self.__points[#self.__points + 1] = { ... } end
    f.ClearAllPoints = function(self) self.__points = {} end
    f.GetNumPoints = function(self) return #self.__points end
    f.SetScrollChild = function(self, child) self.__scrollChild = child end
    f.GetScrollChild = function(self) return self.__scrollChild end
    f.SetScript = function(self, ev, fn) self.__scripts[ev] = fn end
    f.Show = function(self) self.shown = true end
    f.Hide = function(self) self.shown = false end
    f.IsShown = function(self) return self.shown == true end
    f.SetMovable, f.EnableMouse, f.RegisterForDrag, f.EnableKeyboard =
        function() end, function() end, function() end, function() end
    f.StartMoving, f.StopMovingOrSizing = function() end, function() end
    f.SetFrameStrata = function() end
    f.CreateTexture = function() return { SetAllPoints = function() end,
        SetColorTexture = function() end } end
    FRAMES[#FRAMES + 1] = f
    return f
end
function NewText(parent, size, r, g, b)
    local fs = {
        __parent = parent, __size = size, __points = {}, __text = "",
    }
    fs.SetText = function(self, t) self.__text = t or "" end
    fs.GetText = function(self) return self.__text end
    fs.SetPoint = function(self, ...) self.__points[#self.__points + 1] = { ... } end
    fs.ClearAllPoints = function(self) self.__points = {} end
    fs.GetNumPoints = function(self) return #self.__points end
    fs.SetWidth = function(self, w) self.__w = w end
    fs.GetWidth = function(self) return self.__w end
    fs.SetJustifyH = function() end
    fs.SetTextColor = function() end
    fs.SetFontObject = function() end
    return fs
end
function ApplyFont() end
function SolidUnderlay() end
function StackWindow() end
function NspKeyboardPropagate() end
function P() end
LANG = "ruRU"
function EffectiveLocale() return LANG end
-- Реальная модель: описание 440 px при 12 pt — около 52 символов в строке.
function OptTextHeight(fs, fallback)
    local t = (fs and fs.__text) or ""
    if fallback == 14 then return 14 end       -- подпись команды — одна строка
    local perLine = 52
    local lines = math.max(1, math.ceil(#t / perLine))
    return lines * 12
end
"""


class HelpWindowLayoutTests(unittest.TestCase):
    lua = None

    def build(self, screen_h=1080, lang="ruRU"):
        lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua = lua
        g = lua.globals()
        src = SOURCE.read_text(encoding="utf-8")
        start = src.index("local HELP_COMMANDS = {")
        end = src.index("-- Main window state.")
        chunk = PRELUDE + "\n" + src[start:end] + "\n" + (
            "SCREEN_H = %d\n" % screen_h
            + "LANG = %r\n" % lang
            # EffectiveLocale — local-forward внутри среза: присваивать только в
            # том же чанке, иначе внутри функции он остаётся nil
            + "EffectiveLocale = function() return LANG end\n"
            + "TestShow = ShowHelpWindow\n"
            "TestLayout = HelpLayout\n"
            "TestWin = function() return helpWin end\n"
            "TestHelp = NspHelp\n"
            "TestCommands = HELP_COMMANDS\n"
            "TestHelpText = HELP_TEXT\n"
        )
        lua.execute(chunk)
        g["UIParent"]["__h"] = screen_h
        g["TestShow"]()
        return lua, g

    def rows(self, g):
        """Строки в порядке отрисовки: пары (подпись команды, описание)."""
        H = g["TestHelp"]
        n = len(g["TestCommands"])
        out = []
        for i in range(1, n + 1):
            out.append((H["cmd"][i], g["TestWin"]() and self.desc(g, i)))
        return out

    def desc(self, g, i):
        win = g["TestWin"]()
        return win["__descRows"][i]

    def top_y(self, fs):
        """Y верхней границы FontString из первого TOPLEFT-якоря.

        Якоря лежат в lua-таблице (индексы с 1), поэтому длину и элементы
        спрашиваем у Lua: итерация такой таблицы из Python отдаёт ключи.
        """
        n = self.lua.eval("function(t) return #t end")(fs["__points"])
        for i in range(1, n + 1):
            anchor = fs["__points"][i]
            if str(anchor[1]) != "TOPLEFT":
                continue
            y = anchor[5]
            if isinstance(y, (int, float)):
                return y
        return None

    def content_height(self, g):
        return g["TestHelp"]["content"]["h"]

    # --- главное: ничего не вылезает ------------------------------------
    def test_no_row_falls_outside_the_canvas(self):
        lua, g = self.build()
        self.lua = lua
        H = g["TestHelp"]
        content_h = self.content_height(g)
        last = self.desc(g, len(g["TestCommands"]))
        y = self.top_y(last)
        self.assertIsNotNone(y)
        # высота описания последней строки: низ не должен уйти ниже холста
        desc_h = lua.globals()["OptTextHeight"](last, 26)
        self.assertGreaterEqual(y + desc_h + content_h, 0,
                                f"низ последней строки ({y + desc_h}) выше границы холста ({-content_h})")

    def test_canvas_is_the_scroll_child(self):
        lua, g = self.build()
        H = g["TestHelp"]
        self.assertIsNotNone(H["scroll"], "должен быть ScrollFrame")
        same = lua.eval("function() return NspHelp.content == NspHelp.scroll.__scrollChild end")()
        self.assertTrue(same, "холст обязан быть ребёнком скролла, иначе окно просто обрежет строки")

    def test_rows_never_overlap_with_the_longest_descriptions(self):
        lua, g = self.build(lang="ruRU")
        n = len(g["TestCommands"])
        measure = lua.globals()["OptTextHeight"]
        prev_y, prev_h = None, None
        for i in range(1, n + 1):
            desc = self.desc(g, i)
            y = self.top_y(desc)
            h = measure(desc, 26)
            if prev_y is not None:
                gap = prev_y - y
                # зазор обязан покрывать высоту ПРЕДЫДУЩЕЙ строки: сравнение с
                # высотой текущей пропускало бы наложение
                self.assertGreaterEqual(
                    gap, prev_h,
                    f"строка {i} начинается через {gap}px после предыдущей, "
                    f"а описание предыдущей занимает {prev_h}px")
            prev_y, prev_h = y, h

    def test_row_step_follows_the_text_not_a_constant(self):
        # В старом коде шаг был ровно 25 px у всех строк. Теперь он обязан
        # отличаться там, где описание переносится на две строки.
        lua, g = self.build()
        n = len(g["TestCommands"])
        steps = []
        prev = None
        for i in range(1, n + 1):
            y = self.top_y(self.desc(g, i))
            if prev is not None:
                steps.append(prev - y)
            prev = y
        self.assertGreater(len(set(steps)), 1,
                           f"шаг одинаков у всех строк ({set(steps)}) — раскладка снова константная")

    # --- высота окна ----------------------------------------------------
    def test_window_grows_with_content(self):
        _, g = self.build(screen_h=1080)
        win = g["TestWin"]()
        content_h = self.content_height(g)
        # окно ниже содержимого — это нормально (скролл), но оно не должно быть
        # меньше 240 (нижняя граница) и не больше потолка 0.8 экрана
        self.assertGreaterEqual(win["h"], 240)
        self.assertLessEqual(win["h"], 864)
        self.assertGreater(win["h"] + 44, min(content_h, 700),
                           "высота окна не связана с содержимым")

    def test_small_screen_caps_the_window_instead_of_clipping(self):
        # На 1366x768 окно в 600 px перекрывало бы пол-экрана; потолок считается
        # от экрана, а остальное отдаётся скроллу.
        _, g = self.build(screen_h=768)
        win = g["TestWin"]()
        self.assertLessEqual(win["h"], int(768 * 0.8))
        self.assertGreater(self.content_height(g), win["h"] - 60,
                           "на маленьком экране содержимое должно прокручиваться, а не обрезаться молча")

    # --- язык -----------------------------------------------------------
    def test_language_switch_rebuilds_texts_and_layout(self):
        lua, g = self.build(lang="enUS")
        first = [str(self.desc(g, i)["__text"]) for i in range(1, len(g["TestCommands"]) + 1)]
        height_en = self.content_height(g)
        lua.globals()["LANG"] = "deDE"
        lua.globals()["TestShow"]()
        second = [str(self.desc(g, i)["__text"]) for i in range(1, len(g["TestCommands"]) + 1)]
        self.assertNotEqual(first, second, "смена языка не переписала описания")
        height_de = self.content_height(g)
        self.assertGreater(height_de, 0)
        # немецкие строки длиннее → холст не может стать меньше
        self.assertGreaterEqual(height_de, height_en)

    def test_every_command_has_a_description_in_every_locale(self):
        # Ключевая связка окна: HELP_TEXT позиционный, и пропуск строки в локали
        # сдвигает ВСЕ описания ниже — на глаз это выглядит как «описание не от
        # той команды». Паритет ключей такое не ловит: это разные массивы.
        lua, g = self.build()
        n = len(g["TestCommands"])
        texts = g["TestHelpText"]
        for loc in ("enUS", "zhCN", "ruRU", "deDE", "frFR", "koKR"):
            arr = texts[loc]
            self.assertEqual(n, lua.eval("function(t) return #t end")(arr),
                             f"в локали {loc} описаний не {n} — позиции разъедутся")


if __name__ == "__main__":
    unittest.main()
