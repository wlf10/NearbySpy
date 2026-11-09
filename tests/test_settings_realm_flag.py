"""Settings window: the "accept other realms" flag (Lua 5.1 harness).

The window is built from real source; only the widgets are stubbed. What the test
holds:
  - the checkbox exists, reads the saved value and writes it back;
  - turning the flag on/off repaints the player list and the hub status line;
  - switching the language relabels the new row too (a missing label renders as
    `nil` in one locale the user may never open).
"""

from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

SOURCE = Path(__file__).resolve().parents[1] / "NearbySpy.lua"

PRELUDE = r"""
opt, optWin = {}, nil
PEER_CHANNEL = "nearbyspydata"
REPAINTS = { tactical = 0, hub = 0 }
function TacticalUpdate() REPAINTS.tactical = REPAINTS.tactical + 1 end
hub = { Refresh = function() REPAINTS.hub = REPAINTS.hub + 1 end }
function RefreshSettingsText() end   -- replaced by the real one from the block
local function P() end
local function DbgErr() end
function JoinPeerChannel() end
function LeaveChannelByName() end
function SolidUnderlay() end
function StackWindow() end
function L(k) return k end

DB = { peerEnabled = true, peerAllRealms = true }
function GetDB() return DB end

local function Widget()
    local w = {}
    w.SetText = function(self, t) self.text = t end
    w.SetPoint = function() end
    w.SetSize = function() end
    w.SetWidth = function() end
    w.SetJustifyH = function() end
    w.SetScript = function(self, ev, fn) self._scripts = self._scripts or {}; self._scripts[ev] = fn end
    w.Show = function(self) self.shown = true end
    w.Hide = function(self) self.shown = false end
    w.IsShown = function(self) return self.shown == true end
    w.CreateTexture = function() return Widget() end
    return w
end

function CreateFrame()
    local w = Widget()
    w.TitleText, w.Bg, w.CloseButton = Widget(), Widget(), Widget()
    w.StartMoving, w.StopMovingOrSizing = function() end, function() end
    w.SetFrameStrata, w.SetMovable, w.EnableMouse = function() end, function() end, function() end
    w.RegisterForDrag, w.EnableKeyboard = function() end, function() end
    w.SetPropagateKeyboardInput = function() end
    return w
end
function NewText() return Widget() end

CHECKS = {}
function OptCheck(parent, x, y, labelKey, descKey, getter, setter)
    local cb, label, desc = Widget(), Widget(), Widget()
    cb.GetChecked = function(self) return self.checked end
    cb.SetChecked = function(self, v) self.checked = v and true or false end
    cb.__click = function() setter(not cb:GetChecked()) end
    CHECKS[labelKey] = cb
    label.text, desc.text = labelKey, descKey
    cb:SetChecked(getter())
    return cb, label, desc
end
function OptSelect(parent, y, name, labelKey, descKey, width, entriesFn, getCurrent, onPick)
    local label, desc = Widget(), Widget()
    label.text, desc.text = labelKey, descKey
    return { label = label, desc = desc, Refresh = function() end }
end
"""


class SettingsRealmFlagTests(unittest.TestCase):
    def setUp(self):
        source = SOURCE.read_text(encoding="utf-8")
        start = source.index("local function BuildSettingsWindow()")
        end = source.index("function MinimapButton_Update()", start)
        block = source[start:end]
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(PRELUDE + "\n" + block + "\nBuildSettingsWindow()\n")

    def test_checkbox_is_created_and_reflects_the_saved_value(self):
        checks = self.lua.globals()["CHECKS"]
        cb = checks["SET_PEER_ALL"]
        self.assertTrue(cb is not None, "the accept-other-realms checkbox must exist")
        self.assertEqual(True, cb["checked"])

    def click(self):
        # the settings window is hidden after build; a real click can only happen
        # on a visible window, so show it first
        g = self.lua.globals()
        g["ShowSettingsWindow"]()
        g["CHECKS"]["SET_PEER_ALL"]["__click"]()

    def test_unchecking_writes_false_and_repaints_the_list(self):
        self.click()
        db = self.lua.globals()["DB"]
        self.assertEqual(False, db["peerAllRealms"])
        repaints = self.lua.globals()["REPAINTS"]
        self.assertEqual(1, repaints["tactical"])
        self.assertEqual(1, repaints["hub"])

    def test_checking_again_restores_the_value(self):
        self.click()
        self.click()
        self.assertEqual(True, self.lua.globals()["DB"]["peerAllRealms"])

    def test_language_switch_relabels_the_new_row(self):
        lua = self.lua
        lua.globals()["L"] = lua.eval("function(k) return 'LOC:' .. k end")
        lua.globals()["RefreshSettingsText"]()
        checks = lua.globals()["CHECKS"]
        self.assertTrue(checks["SET_PEER_ALL"] is not None)
        # the label widget is relabelled through opt.allRealmsLabel
        opt = lua.globals()["opt"]
        self.assertEqual("LOC:SET_PEER_ALL", opt["allRealmsLabel"]["text"])
        self.assertEqual("LOC:SET_PEER_ALL_D", opt["allRealmsDesc"]["text"])


if __name__ == "__main__":
    unittest.main()
