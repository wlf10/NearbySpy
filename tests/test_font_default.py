"""Exercise the production font assignment in Lua 5.1."""
from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

SOURCE = Path(__file__).resolve().parents[1] / "NearbySpy.lua"


class FontDefaultTests(unittest.TestCase):
    def make_lua(self, with_game_font=True, with_small=True):
        source = SOURCE.read_text()
        block = source[source.index("-- ============ UI ============") : source.index("local function ClassColorRGB(")]
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute("WITH_SMALL = %s" % ("true" if with_small else "false"))
        lua.execute("""
        GameFontNormal = {name = 'GameFontNormal'}
        GameFontNormalSmall = WITH_SMALL and {name = 'GameFontNormalSmall'} or nil
        GameFontNormalLarge = {name = 'GameFontNormalLarge'}
        FONT_DB = {debug = {}}
        function GetDB() return FONT_DB end
        function NewFontString()
            return {
                fontObject = nil,
                setFontCalls = 0,
                SetFont = function(self, path, size, flags)
                    self.setFontCalls = self.setFontCalls + 1
                    return true
                end,
                SetFontObject = function(self, obj) self.fontObject = obj end,
                SetTextColor = function() end,
            }
        end
        function NewParent()
            return {CreateFontString = function() return NewFontString() end}
        end
        """)
        if not with_game_font:
            lua.execute("GameFontNormal = nil")
        lua.execute(block + "\nNewTextX = NewText")
        return lua

    def test_uses_client_font_object_and_never_setfont(self):
        lua = self.make_lua()
        parent = lua.globals().NewParent()
        fs = lua.globals().NewTextX(parent, 12)
        self.assertEqual("GameFontNormal", fs.fontObject.name)
        self.assertEqual(0, fs.setFontCalls, "no explicit SetFont: it breaks cold-start rendering")

    def test_only_the_smallest_size_uses_the_small_font_object(self):
        # THE point: before 09.11.2026 the size was ignored and every label
        # rendered at GameFontNormal, so no text could be made smaller.
        # Threshold is 7 on purpose: sizes 8-9 are column headers, metric cards,
        # class bars and counters — mapping them to the small object shrank the
        # whole window (reported in game 09.11.2026).
        lua = self.make_lua()
        parent = lua.globals().NewParent()
        fs = lua.globals().NewTextX(parent, 7)
        self.assertEqual("GameFontNormalSmall", fs.fontObject.name)
        self.assertEqual(0, fs.setFontCalls, "still no explicit SetFont")
        for size in (8, 9):
            fs = lua.globals().NewTextX(parent, size)
            self.assertEqual("GameFontNormal", fs.fontObject.name,
                             f"size {size} must stay at the normal object")

    def test_normal_and_large_sizes_keep_their_objects(self):
        lua = self.make_lua()
        parent = lua.globals().NewParent()
        self.assertEqual("GameFontNormal", lua.globals().NewTextX(parent, 12).fontObject.name)
        self.assertEqual("GameFontNormalLarge", lua.globals().NewTextX(parent, 14).fontObject.name)

    def test_falls_back_to_normal_when_the_client_lacks_the_small_object(self):
        lua = self.make_lua(with_small=False)
        parent = lua.globals().NewParent()
        fs = lua.globals().NewTextX(parent, 8)
        self.assertEqual("GameFontNormal", fs.fontObject.name,
                         "a missing variant must degrade to normal, not to nothing")

    def test_survives_missing_gamefont(self):
        lua = self.make_lua(with_game_font=False)
        parent = lua.globals().NewParent()
        fs = lua.globals().NewTextX(parent, 12)
        self.assertIsNone(fs.fontObject)


if __name__ == "__main__":
    unittest.main()
