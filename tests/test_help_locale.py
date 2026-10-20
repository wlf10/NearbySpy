"""Regression tests: help window must follow the language override (Lua 5.1).

The help window used HELP_TEXT[GetLocale()], ignoring the settings override
(db.locale), and never rebuilt descriptions after a language change. The
harness extracts BOTH the help-window block and the real EffectiveLocale
definition (which sits later in the file) to also catch Lua local-scoping
mistakes (a later `local function` is invisible to earlier code).
"""

from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime


SOURCE = Path(__file__).resolve().parents[1] / "NearbySpy.lua"

FRAME_MOCK = r"""
local function MockWidget()
    local w = { __scripts = {} }
    w.SetScript = function(self, k, fn) self.__scripts[k] = fn end
    w.SetText = function(self, t) self.__text = t end
    w.GetText = function(self) return self.__text end
    w.CreateTexture = function(self) return MockWidget() end
    return setmetatable(w, { __index = function(t, k)
        local f = function(...) return MockWidget() end
        rawset(t, k, f)
        return f
    end })
end
CreateFrame = function() return MockWidget() end
UIParent = {}
NewText = function() return MockWidget() end
StackWindow = function() end
SolidUnderlay = function() end
CLIENT_LOCALE = "ruRU"
GetLocale = function() return CLIENT_LOCALE end
LuaType = function(v) return type(v) end
DB = { locale = nil }
GetDB = function() return DB end
"""


class HelpLocaleTests(unittest.TestCase):
    def setUp(self):
        source = SOURCE.read_text(encoding="utf-8")
        help_block = source[
            source.index("local HELP_COMMANDS") : source.index("-- Main window state.")
        ]
        eff_block = source[
            source.index("local SET_LANG_ORDER") :
            source.index("local RefreshSettingsText")
        ]
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(
            FRAME_MOCK + help_block + "\n" + eff_block + "\n"
            "TestShowHelp = ShowHelpWindow\n"
            "TestHelpWin = function() return helpWin end\n"
        )
        self.g = self.lua.globals()

    def show_and_descriptions(self):
        self.g["TestShowHelp"]()
        win = self.g["TestHelpWin"]()
        rows = win["__descRows"]
        # lupa proxies are all callable() and lua_type() misdetects them here —
        # ask Lua itself; the mock's __index fallback answers with a function
        if self.g["LuaType"](rows) != "table":
            return None
        return [rows[i]["__text"] for i in range(1, len(rows) + 1)]

    def test_uses_settings_language_over_client_locale(self):
        self.g["DB"]["locale"] = "deDE"
        descs = self.show_and_descriptions()
        self.assertIsNotNone(descs, "help window must keep references to desc rows")
        self.assertEqual("Spielerfenster", descs[1 - 1])

    def test_uses_client_locale_when_no_override(self):
        self.g["DB"]["locale"] = None
        descs = self.show_and_descriptions()
        self.assertIsNotNone(descs)
        self.assertEqual("Окно игроков", descs[1 - 1])

    def test_relabels_on_reopen_after_language_change(self):
        self.g["DB"]["locale"] = None
        first = self.show_and_descriptions()
        self.assertIsNotNone(first)
        self.g["DB"]["locale"] = "deDE"
        second = self.show_and_descriptions()
        self.assertEqual("Spielerfenster", second[0])
        self.assertNotEqual(first[0], second[0])

    def test_unknown_override_falls_back_to_client_locale(self):
        self.g["DB"]["locale"] = "xxXX"
        descs = self.show_and_descriptions()
        self.assertIsNotNone(descs)
        self.assertEqual("Окно игроков", descs[0])


if __name__ == "__main__":
    unittest.main()
