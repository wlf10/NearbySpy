"""TacticalUpdate must survive being called before the window is built (Lua 5.1).

The player window builds its widgets lazily in BuildWindow(). Anything that calls
TacticalUpdate earlier (a settings checkbox repainting the list, for instance)
used to die on `tactical.total.value:SetText` with
"attempt to index field 'total' (a nil value)" — seen in game 09.11.2026 when the
"Accept other realms" checkbox was unchecked.
"""

from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

SOURCE = Path(__file__).resolve().parents[1] / "NearbySpy.lua"


def block() -> str:
    src = SOURCE.read_text(encoding="utf-8")
    start = src.index("TacticalUpdate = function()")
    end = src.index("local function BuildWindow()", start)
    return src[start:end]


PRELUDE = r"""
tactical = {rows = {}, bars = {}, classes = {}, filters = {}, filter = "all", started = 1000}
TACTICAL_FRESH = 300
MAX_ROWS = 500
TACTICAL_ROW_H = 30
CHAT = {}
function P(msg) CHAT[#CHAT + 1] = tostring(msg) end
function L(k) return k end
function ClassColorRGB() return 1, 1, 1 end
function TimeAgo() return "now" end
function TacticalClassIcon() end
function TacticalSources() return "src" end
function TacticalFilterState() end
function TacticalRows() return 0 end
function TacticalStats()
    return { total = 0, f5 = 0, f15 = 0, f60 = 0, newN = 0, alliance = 0, horde = 0,
             unknown = 0, levelN = 0, levelSum = 0, level = {}, classes = {}, top = {} }
end
function GetDB() return { players = {}, debug = {} } end
function time() return 1000 end
LEVEL_CHART_H = 80
CLASS_BARS = 9
winList = {}
"""


class TacticalUpdateGuardTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(PRELUDE + "\n" + block() + "\nTestUpdate = TacticalUpdate\n")

    def test_update_before_the_window_exists_is_a_noop(self):
        # tactical.total is nil: nothing was built yet
        self.lua.globals()["TestUpdate"]()
        chat = self.lua.globals()["CHAT"]
        self.assertEqual(0, len(list(chat)),
                         f"update must stay silent, chat got: {[chat[i] for i in range(1, len(list(chat)) + 1)]}")

    def test_update_after_build_reports_its_own_errors(self):
        # with widgets in place but a broken stats call the error IS surfaced —
        # the guard must not swallow real failures
        self.lua.execute("tactical.total = {}")
        self.lua.execute("TacticalStats = function() error('boom') end")
        self.lua.globals()["TestUpdate"]()
        chat = [self.lua.globals()["CHAT"][i] for i in range(
            1, len(list(self.lua.globals()["CHAT"])) + 1)]
        self.assertTrue(any("boom" in str(c) for c in chat),
                        f"a real error must reach chat, got: {chat}")


if __name__ == "__main__":
    unittest.main()
