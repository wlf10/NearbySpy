"""Миникарт-кнопка: круглая подложка и окантовка — Lua 5.1.

Жалоба пользователя 09.11.2026: «кнопка миникарты квадратная, хотя у других она
круглая и с окантовкой». Причина: подложка рисовалась `SetColorTexture` — это
плоский прямоугольник, а круглой её делает только текстура.

Как у стандартных кнопок аддонов (подтверждено поиском по исходникам клиента
билда 1.60.1, репо Bleakfiber/Blizzard-Interface-Assets):
  - фон:     Interface\\Minimap\\UI-Minimap-Background   (круглая заливка)
  - окантовка: Interface\\Minimap\\MiniMap-TrackingBorder (кольцо 54x54,
                ей пользуются 11 файлов FrameXML — от PTRFeedback до WorldMap)

Тест держит три вещи, которые легко сломать молча:
  - подложка НЕ рисуется цветом, когда текстура загрузилась (иначе снова квадрат);
  - кольцо больше иконки и лежит в OVERLAY (иначе не перекрывает её края);
  - при отсутствии текстуры остаётся видимый фолбэк (кнопка не пропадает).
"""

from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

SOURCE = Path(__file__).resolve().parents[1] / "NearbySpy.lua"

BTN_BG = "Interface\\Minimap\\UI-Minimap-Background"
BTN_RING = "Interface\\Minimap\\MiniMap-TrackingBorder"
# Центр нарисованного кольца внутри текстуры 53x53 (Blizzard сама ставит эту
# текстуру с офсетом CENTER 11,-12 → 53/2-11=15.5 и 53/2-12=14.5 от угла).
RING_CX, RING_CY = 15.5, 14.5
RING_SIZE = 53


def minimap_block() -> str:
    """Функции BuildMinimapButton + MinimapButton_Update (они рядом)."""
    src = SOURCE.read_text(encoding="utf-8")
    start = src.index("function MinimapButton_Update()")
    end = src.index("SLASH_NEARBYSPY1", start)
    return src[start:end]


# Мок-виджет: записывает всё, что на него вызвали.
STUBS = """
MINI_BTN = nil
TEXTURES = {}
CURRENT_TEXTURE = nil

local function NewTexture(owner, layer)
    local t = {
        __layer = layer,
        __size = {},
        __texture = nil,
        __color = nil,
        __points = {},
        SetSize = function(self, w, h) self.__size.w, self.__size.h = w, h end,
        SetPoint = function(self, p, rel, rp, x, y)
            self.__points[#self.__points + 1] = p
            -- WoW принимает сокращённую форму SetPoint("TOPLEFT", 7, -6):
            -- если второй аргумент число, это x, а третий — y (relativeTo нет)
            if type(rel) == "number" then
                x, y = rel, rp
            end
            self.__point = { p = p, x = x, y = y }
        end,
        SetTexture = function(self, path)
            self.__texture = path
            -- TEXTURES_MISSING эмулирует клиент без этой текстуры
            if TEXTURES_MISSING and TEXTURES_MISSING[path] then return false end
            return true
        end,
        SetColorTexture = function(self, r, g, b, a) self.__color = {r, g, b, a} end,
        SetAlpha = function(self, v) self.__alpha = v end,
        GetAlpha = function(self) return self.__alpha end,
        SetMask = function(self, path)
            -- NO_MASK эмулирует клиент без Texture:SetMask
            if NO_MASK then error("SetMask is not available") end
            self.__mask = path
        end,
        GetMask = function(self) return self.__mask end,
    }
    TEXTURES[#TEXTURES + 1] = t
    return t
end

CreateFrame = function(kind, name, parent)
    local f = {
        __kind = kind, __name = name, __parent = parent,
        __size = {}, __shown = nil,
        SetSize = function(self, w, h) self.__size.w, self.__size.h = w, h end,
        SetFrameStrata = function() end,
        SetFrameLevel = function(self, lvl) self.__level = lvl end,
        SetHighlightTexture = function(self, path) self.__highlight = path end,
        SetShown = function(self, v) self.__shown = v end,
        SetMovable = function() end,
        RegisterForDrag = function() end,
        RegisterForClicks = function() end,
        SetScript = function(self, ev, fn) self[ev] = fn end,
        ClearAllPoints = function() end,
        SetPoint = function(self, p, rel, rp, x, y)
            self.__point = {p, rel, rp, x, y}
        end,
        Show = function(self) self.__shown = true end,
        Hide = function(self) self.__shown = false end,
        CreateTexture = function(self, name, layer) return NewTexture(self, layer) end,
    }
    MINI_BTN = f
    return f
end

Minimap = {
    GetWidth = function() return 140 end,
    GetCenter = function() return 0, 0 end,
    GetEffectiveScale = function() return 1 end,
}
function GetCursorPosition() return 0, 0 end
function Atan2(y, x) return 0 end
function GetDB() return {} end
function L(k) return k end
function Strata() end
Frames = {}
"""


def build(missing=None, no_mask=False):
    """Собрать кнопку.

    missing — пути, которые «не загрузились»; no_mask — в клиенте нет
    Texture:SetMask (тогда иконка обязана остаться маленькой, иначе квадрат
    вылезет за обод).
    """
    lua = LuaRuntime(unpack_returned_tuples=True)
    missing_lua = "NO_MASK = %s\nTEXTURES_MISSING = {}" % ("true" if no_mask else "false")
    if missing:
        # бэкслеши путей удваиваем: в Lua-строке "\M" — неизвестная escape-
        # последовательность, и ключ молча перестаёт совпадать с путём
        esc = [m.replace("\\", "\\\\") for m in missing]
        missing_lua = "TEXTURES_MISSING = {" + ",".join(
            '["%s"]=true' % m for m in esc) + "}"
    chunk = (
        missing_lua + "\n" + STUBS + "\n"
        + minimap_block() + "\n"
        + "BuildMinimapButton()\n"
        + "local out = { n = #TEXTURES }\n"
        + "local btn = MINI_BTN\n"
        + "out.size = tostring(btn.__size.w) .. 'x' .. tostring(btn.__size.h)\n"
        + "for i = 1, #TEXTURES do\n"
        + "  local t = TEXTURES[i]\n"
        + "  local pt = t.__point or {}\n"
        + "  out[i] = string.format('%s|%s|%sx%s|%s|%s|%s|%s|%s',\n"
        + "    tostring(t.__layer), tostring(t.__texture),\n"
        + "    tostring(t.__size.w), tostring(t.__size.h),\n"
        + "    t.__color and ('color' .. tostring(t.__color[1])) or 'no-color',\n"
        + "    tostring(pt.p), tostring(pt.x), tostring(pt.y),\n"
        + "    t.__alpha and tostring(t.__alpha) or 'opaque')\n"
        + "  out[i] = out[i] .. '|' .. (rawget(t, '__mask') and tostring(t.__mask) or 'no-mask')\n"
        + "end\n"
        + "return out\n"
    )
    res = lua.execute(chunk)
    # n берём из Lua: len() на прокси-таблице врёт
    n = int(res["n"])
    rows = [str(res[i]) for i in range(1, n + 1)]
    return str(res["size"]), rows


def tex_row(rows, texture):
    for r in rows:
        if r.split("|")[1] == texture:
            return r.split("|")
    return None


def tex_row(rows, texture):
    for r in rows:
        parts = r.split("|")
        if parts[1] == texture:
            return parts
    return None


def anchor_of(row):
    """('TOPLEFT', x, y) из строки теста; числа None если не заданы."""
    def num(v):
        return None if v in ("nil", "None", "") else float(v)
    return row[4], num(row[5]), num(row[6])


class MinimapButtonTest(unittest.TestCase):
    """Кнопка миникарты: круглая и окантовка ровно по иконке.

    Две жалобы пользователя подряд:
      1) «кнопка квадратная» — подложка рисовалась SetColorTexture;
      2) «окантовка смещена от иконки» — текстура MiniMap-TrackingBorder
         НЕ симметрична: видимое кольцо нарисовано со сдвигом к левому верхнему
         углу текстуры. Анкор CENTER ставит в центр кнопки центр ТЕКСТУРЫ, а не
         центр нарисованного кольца, поэтому кольцо уезжало вправо-вниз.
         Лечится каноном LibDBIcon: кольцо 53x53 по TOPLEFT + иконка 17x17
         со сдвигом (7,-6).
    """

    def test_background_is_texture_not_flat_color(self):
        """Круглой подложку делает текстура, SetColorTexture даёт квадрат."""
        size, rows = build()
        bg = tex_row(rows, BTN_BG)
        self.assertIsNotNone(bg, "нет подложки UI-Minimap-Background: %s" % rows)
        self.assertEqual(bg[0], "BACKGROUND", "подложка не в слое BACKGROUND")
        self.assertEqual(bg[3], "no-color",
                         "подложка нарисована цветом — это и есть квадрат: %s" % bg)

    def test_ring_anchored_top_left_not_center(self):
        """Главное: кольцо по TOPLEFT. CENTER и даёт смещение."""
        size, rows = build()
        ring = tex_row(rows, BTN_RING)
        self.assertIsNotNone(ring, "нет окантовки: %s" % rows)
        point, x, y = anchor_of(ring)
        self.assertEqual(point, "TOPLEFT",
                         "кольцо анкорено %r; при несимметричной текстуре нужно "
                         "TOPLEFT, иначе окантовка съезжает" % point)
        self.assertEqual(ring[0], "OVERLAY", "кольцо не перекрывает иконку")

    def test_icon_centers_inside_ring(self):
        """Центр иконки совпадает с центром НАРИСОВАННОГО кольца.

        Схема как в Mastercraft/LibDBIcon: иконка и подложка по CENTER кнопки,
        кольцо 53x53 по TOPLEFT БЕЗ офсета. Работает потому, что кольцо в
        текстуре не центрировано: его центр — в (15.5, 14.5) от угла текстуры,
        а центр кнопки 31x31 — (15.5, 15.5). Совпадение и есть правильная
        посадка; прежний расчёт «офсет 10px» давал сдвиг на 6px.
        """
        size, rows = build()
        ring = tex_row(rows, BTN_RING)
        icon = tex_row(rows, "Interface\\AddOns\\NearbySpy\\NearbySpyIcon")
        self.assertIsNotNone(icon, "нет иконки аддона")

        btn_w = float(size.split("x")[0])
        btn_cx, btn_cy = btn_w / 2, -btn_w / 2

        # иконка центрирована на кнопке
        point, _, _ = anchor_of(icon)
        self.assertEqual(point, "CENTER", "иконка не по CENTER: %s" % point)

        # кольцо по TOPLEFT без смещения
        rpoint, rx, ry = anchor_of(ring)
        self.assertEqual(rpoint, "TOPLEFT", "кольцо не по TOPLEFT: %s" % rpoint)
        rx = 0.0 if rx is None else rx
        ry = 0.0 if ry is None else ry
        ring_size = float(ring[2].split("x")[0])
        # центр нарисованного кольца в координатах кнопки
        ring_cx = rx + RING_CX * ring_size / RING_SIZE
        ring_cy = ry - RING_CY * ring_size / RING_SIZE

        self.assertAlmostEqual(
            btn_cx, ring_cx, delta=1.0,
            msg="центр кнопки/иконки и кольца не совпадают по X: %s vs %s" % (btn_cx, ring_cx))
        self.assertAlmostEqual(
            btn_cy, ring_cy, delta=1.0,
            msg="центр кнопки/иконки и кольца не совпадают по Y: %s vs %s" % (btn_cy, ring_cy))

    def test_icon_is_circular_masked_and_large(self):
        """Крупная иконка обязана быть круглой — иначе углы вылезут за обод.

        Исходник NearbySpyIcon.tga — непрозрачный квадрат 64x64 (проверено
        разбором файла: alpha=255 во всех пикселях, полей нет). При увеличении
        его собственные светлые края читались как «рамка по бокам», а углы
        выходили за золотое кольцо. Круглая маска TempPortraitAlphaMask
        (Texture:SetMask подтверждён в исходниках клиента) решает оба.
        """
        size, rows = build()
        icon = tex_row(rows, "Interface\\AddOns\\NearbySpy\\NearbySpyIcon")
        mask = icon[8] if len(icon) > 8 else "no-mask"
        self.assertEqual(mask, "Interface\\CharacterFrame\\TempPortraitAlphaMask",
                         "иконка без круглой маски: %s" % mask)
        icon_w = float(icon[2].split("x")[0])
        # 26 — нижняя граница: ниже снова начнут читаться края самой картинки.
        # 27 выбрано пользователем осознанно (30 заполняло отверстие вплотную).
        self.assertGreaterEqual(icon_w, 26,
                                "иконка слишком мелкая, будут видны края картинки: %s" % icon_w)
        self.assertLessEqual(icon_w, 29,
                             "иконка снова упирается в обод кольца: %s" % icon_w)

    def test_without_mask_icon_stays_small(self):
        """Нет Texture:SetMask → иконка остаётся маленькой (квадрат не вылезет)."""
        size, rows = build(no_mask=True)
        icon = tex_row(rows, "Interface\\AddOns\\NearbySpy\\NearbySpyIcon")
        icon_w = float(icon[2].split("x")[0])
        self.assertLessEqual(icon_w, 25,
                             "без маски крупный квадрат вылезет за обод: %s" % icon_w)

    def test_background_follows_final_icon_size(self):
        """Подложка считается от ИТОГОВОГО размера иконки, а не от заявленного.

        Регрессия: пока размер иконки разрешался ПОСЛЕ подложки, при отсутствии
        маски фон оставался 29px при иконке 24px и торчал на 5px вокруг.
        """
        for no_mask in (False, True):
            size, rows = build(no_mask=no_mask)
            icon = tex_row(rows, "Interface\\AddOns\\NearbySpy\\NearbySpyIcon")
            bg = tex_row(rows, BTN_BG)
            icon_w = float(icon[2].split("x")[0])
            bg_w = float(bg[2].split("x")[0])
            self.assertLessEqual(
                bg_w, icon_w,
                "подложка (%s) больше иконки (%s) при no_mask=%s — фон торчит"
                % (bg_w, icon_w, no_mask))

    def test_ring_bigger_than_icon(self):
        """Кольцо обязано быть больше иконки, иначе она торчит из него."""
        size, rows = build()
        ring_w = float(tex_row(rows, BTN_RING)[2].split("x")[0])
        icon_w = float(tex_row(rows, "Interface\\AddOns\\NearbySpy\\NearbySpyIcon")[2].split("x")[0])
        self.assertGreater(ring_w, icon_w, "иконка не меньше кольца")

    def test_icon_is_large_enough(self):
        """Иконка не должна снова стать мелкой.

        Пользователь просил увеличить иконку внутри кольца: 17x17 читалась как
        точка, 24 всё ещё оставляла видимые края картинки. Нижняя граница 26
        держит результат и не даёт рефакторингу молча вернуть прежний размер.
        """
        size, rows = build()
        icon = tex_row(rows, "Interface\\AddOns\\NearbySpy\\NearbySpyIcon")
        icon_w = float(icon[2].split("x")[0])
        self.assertGreaterEqual(icon_w, 26, "иконка снова мелкая: %s" % icon_w)
        self.assertLessEqual(icon_w, 29, "иконка снова упирается в обод: %s" % icon_w)

    def test_icon_is_semi_transparent(self):
        """Иконка полупрозрачная — читается как «под стеклом» кольца."""
        size, rows = build()
        icon = tex_row(rows, "Interface\\AddOns\\NearbySpy\\NearbySpyIcon")
        alpha = icon[7] if len(icon) > 7 else "opaque"
        self.assertNotEqual(alpha, "opaque", "иконка непрозрачная: SetAlpha не задан")
        val = float(alpha)
        self.assertGreater(val, 0.5, "иконка почти невидима: %s" % val)
        self.assertLess(val, 1.0, "иконка полностью непрозрачная: %s" % val)

    def test_button_bigger_than_icon(self):
        """Кнопка не меньше своей иконки, иначе клик мимо цели."""
        size, rows = build()
        bw = float(size.split("x")[0])
        icon_w = float(tex_row(rows, "Interface\\AddOns\\NearbySpy\\NearbySpyIcon")[2].split("x")[0])
        self.assertGreaterEqual(bw, icon_w, "кнопка меньше своей иконки")

    def test_border_and_icon_share_anchor_convention(self):
        """Подложка и иконка — по CENTER (как в Mastercraft), кольцо — TOPLEFT."""
        size, rows = build()
        bg = tex_row(rows, BTN_BG)
        icon = tex_row(rows, "Interface\\AddOns\\NearbySpy\\NearbySpyIcon")
        self.assertEqual(anchor_of(bg)[0], "CENTER", "подложка не по CENTER")
        self.assertEqual(anchor_of(icon)[0], "CENTER", "иконка не по CENTER")

    def test_background_not_larger_than_icon_and_masked(self):
        """Подложка не больше иконки и тоже круглая.

        Квадратная подложка крупнее иконки торчала бы из-под круглой иконки
        тёмными клиньями за ободом — тот же «квадрат», только снизу.
        """
        size, rows = build()
        bg = tex_row(rows, BTN_BG)
        icon = tex_row(rows, "Interface\\AddOns\\NearbySpy\\NearbySpyIcon")
        self.assertEqual(anchor_of(bg)[0], "CENTER")
        bg_w = float(bg[2].split("x")[0])
        icon_w = float(icon[2].split("x")[0])
        self.assertLessEqual(bg_w, icon_w,
                             "подложка больше иконки и торчит из-под неё: %s > %s"
                             % (bg_w, icon_w))
        mask = bg[8] if len(bg) > 8 else "no-mask"
        self.assertEqual(mask, "Interface\\CharacterFrame\\TempPortraitAlphaMask",
                         "подложка без круглой маски: %s" % mask)

    def test_icon_nudged_one_pixel_right(self):
        """Иконка сдвинута вправо ровно на 1px — так решил пользователь.

        Обод нарисован неравномерно по толщине, поэтому математический центр
        читается как «иконка чуть левее». 1px — минимальная поправка; больше
        не нужно, и отдельной настройки под это не заводим (лишняя сущность).
        Подложка при этом остаётся строго по центру.
        """
        size, rows = build()
        icon = tex_row(rows, "Interface\\AddOns\\NearbySpy\\NearbySpyIcon")
        bg = tex_row(rows, BTN_BG)
        point, x, y = anchor_of(icon)
        self.assertEqual(point, "CENTER", "иконка должна остаться по CENTER")
        self.assertEqual(x, 1.0, "сдвиг иконки: ожидался ровно 1px, получено %s" % x)
        self.assertEqual(y, 0.0, "по вертикали иконка должна стоять ровно: y=%s" % y)
        # подложка НЕ двигается — тёмный круг обязан остаться по центру
        self.assertEqual(anchor_of(bg)[0], "CENTER")
        self.assertIsNone(anchor_of(bg)[1], "подложка съехала вместе с иконкой")

    def test_fallback_when_texture_missing(self):
        """Нет текстуры → остаётся видимый фолбэк, кнопка не исчезает."""
        size, rows = build(missing=[BTN_BG])
        bg = tex_row(rows, BTN_BG)
        self.assertIsNotNone(bg)
        self.assertNotEqual(bg[3], "no-color",
                            "без текстуры подложка осталась невидимой: %s" % bg)

    def test_ring_absent_does_not_break_button(self):
        size, rows = build(missing=[BTN_RING])
        self.assertTrue(size, "кнопка не создана без кольца")
        self.assertIsNotNone(tex_row(rows, BTN_BG), "подложка пропала вместе с кольцом")


if __name__ == "__main__":
    unittest.main(verbosity=2)
