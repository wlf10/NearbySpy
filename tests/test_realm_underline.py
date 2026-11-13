"""Realm under the player name, in a smaller font (Lua 5.1 harness).

The channel is cluster-wide, so a row can come from another realm. The realm is
shown on its OWN line under the name and in a smaller font:

  - one FontString cannot carry two font sizes, so an appended colour code was
    the wrong tool: the tag took width from the 142px name column and pushed the
    name itself out;
  - the tag must be hidden for rows from our own realm, otherwise a stale tag
    from a recycled row would stay on screen.

Run: lupavenv/bin/python3 tests/test_realm_underline.py
"""

from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

from nsp_helpers import CONST_PRELUDE

SOURCE = Path(__file__).resolve().parents[1] / "NearbySpy.lua"

PRELUDE = r"""
tactical = {rows = {}, bars = {}, classes = {}, filters = {}, filter = "all", started = 1000}
TACTICAL_ROW_H = 30
MAX_ROWS = 500
LEVEL_CHART_H = 80
CLASS_BARS = 9
winList = { SetHeight = function() end }
MY_REALM = "CAMWOW EU5 Realm 1 PvE"
function PlayerRealm() return MY_REALM end
function L(k) return k end
function time() return 1000 end
function date() return "01.01" end
function ClassColorRGB() return 1, 1, 1 end
function TacticalClassIcon() end
function TacticalVisible() return true end
function TacticalStats() return {} end
function SortedPlayers() return {} end
function GetDB() return { players = {}, debug = {} } end

TEXTURES = {}
local function Widget()
    local w = { __size = {}, __shown = false }
    w.SetSize = function(self, a, b) self.__size.w, self.__size.h = a, b end
    w.SetPoint = function(self, ...) self.__point = { ... } end
    w.SetWidth = function(self, x) self.__size.w = x end
    w.SetText = function(self, t) self.__text = t end
    w.GetText = function(self) return self.__text end
    w.SetTextColor = function(self, r, g, b) self.__color = { r, g, b } end
    w.SetShadowOffset = function() end
    w.SetShadowColor = function() end
    w.SetJustifyH = function() end
    w.Show = function(self) self.__shown = true end
    w.Hide = function(self) self.__shown = false end
    w.IsShown = function(self) return self.__shown end
    w.SetScript = function(self, ev, fn) self.__scripts = self.__scripts or {}; self.__scripts[ev] = fn end
    w.EnableMouse = function() end
    w.SetAllPoints = function() end
    w.SetColorTexture = function() end
    w.SetAlpha = function() end
    w.CreateTexture = function() return Widget() end
    return w
end
function CreateFrame() return Widget() end
FONT_SIZES = {}
function NewText(parent, size, r, g, b)
    local w = Widget()
    w.__sizePt = size
    FONT_SIZES[#FONT_SIZES + 1] = size
    return w
end
"""


def block() -> str:
    src = SOURCE.read_text(encoding="utf-8")
    start = src.index("local function TacticalRow(parent, index)")
    end = src.index("local function TacticalRows()", start)
    return src[start:end]


class RealmUnderlineTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(CONST_PRELUDE + "\n" + PRELUDE + "\n" + block() + "\n"
                         "TestRow = TacticalRow\n")

    def row(self):
        return self.lua.globals()["TestRow"](self.lua.globals()["winList"], 1)

    def test_realm_has_its_own_fontstring_smaller_than_the_name(self):
        row = self.row()
        self.assertTrue(row["realm"] is not None, "row.realm must exist")
        self.assertLess(row["realm"]["__sizePt"], row["name"]["__sizePt"],
                        "the realm must be rendered smaller than the player name")

    def test_realm_is_anchored_under_the_name(self):
        row = self.row()
        point = row["realm"]["__point"]
        # SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, 1)
        self.assertEqual("TOPLEFT", point[1])
        self.assertEqual("BOTTOMLEFT", point[3], "the realm hangs below the name")

    def test_realm_fits_the_name_column(self):
        row = self.row()
        realm_w = row["realm"]["__size"]["w"]
        name_w = row["name"]["__size"]["w"]
        self.assertIsNotNone(realm_w, "the realm column must have a width")
        self.assertLessEqual(realm_w, name_w,
                             "the realm column must not be wider than the name column")

    def test_realm_starts_hidden(self):
        row = self.row()
        self.assertFalse(row["realm"]["__shown"],
                         "a fresh row must not show a realm until it has one")


if __name__ == "__main__":
    unittest.main()
