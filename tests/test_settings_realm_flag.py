"""Settings window: the "accept other realms" flag and row layout (Lua 5.1).

The window is built from real source; only the widgets are stubbed. What the test
holds:
  - the checkbox exists, reads the saved value and writes it back;
  - turning the flag on/off repaints the player list and the hub status line;
  - switching the language relabels the new row too (a missing label renders as
    `nil` in one locale the user may never open);
  - rows are stacked by their MEASURED text height, so a long description (ru/de
    wrap to more lines than en) never overlaps the row below it.
"""

from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

SOURCE = Path(__file__).resolve().parents[1] / "NearbySpy.lua"

# Longest of the six locales per key, extracted from the addon's LOCALE table:
# the layout must hold for the widest string the window can render.
DESC_TEXT_JSON = """{
    ["SET_PEER"] = "Обмен данными (peer)",
    ["SET_PEER_D"] = "Envoyer les nouvelles rencontres au canal nearbyspydata et recevoir celles des autres",
    ["SET_PEER_ALL"] = "Accepter d'autres royaumes",
    ["SET_PEER_ALL_D"] = "Canal commun au cluster. Activé : les entrées d'autres royaumes sont acceptées et marquées. Désactivé : elles sont ignorées et masquées.",
    ["SET_MINIMAP"] = "Afficher le bouton de minicarte",
    ["SET_MINIMAP_D"] = "Das NearbySpy-Symbol auf der Minimap ein- oder ausblenden",
    ["SET_LANG"] = "Language",
    ["SET_LANG_D"] = "Langue de l'interface de l'addon. Les autres fenêtres se mettent à jour après /reload.",
    ["SET_TZ"] = "Часовой пояс теплокарты",
    ["SET_TZ_D"] = "La carte des heures de pointe (fenêtre serveur) s'affiche dans ce fuseau ; Auto = horloge système.",
    ["HUB_SETTINGS"] = "Einstellungen",
}"""

PRELUDE = r"""
opt, optWin = {}, nil
PEER_CHANNEL = "nearbyspydata"
REPAINTS = { tactical = 0, hub = 0 }
function TacticalUpdate() REPAINTS.tactical = REPAINTS.tactical + 1 end
hub = { Refresh = function() REPAINTS.hub = REPAINTS.hub + 1 end }
local function P() end
local function DbgErr() end
function JoinPeerChannel() end
function LeaveChannelByName() end
function SolidUnderlay() end
function StackWindow() end

-- L() answers with the REAL strings from the addon's locale tables (the longest
-- of the six languages per key), so the layout is measured against what the
-- window actually renders. A synthetic short string hides exactly the bug this
-- test exists for: "Accept other realms" is 200 chars in French.
DESC_TEXT = DESC_TEXT_JSON
function L(k) return DESC_TEXT[k] or k end

-- Height model of a laid-out row: description width 290px, 8pt font, about 45
-- characters per line (Cyrillic and French accents are wider than English),
-- 11px per line; label is one 11pt line.
function OptTextHeight(fs, fallback)
    local t = (fs and fs.text) or ""
    local perLine = (fallback == 14) and 200 or 45   -- labels wrap rarely
    local lines = math.max(1, math.ceil(#t / perLine))
    return lines * ((fallback == 14) and 14 or 11)
end

-- The player window is a separate frame, built lazily; the checkbox may only
-- repaint it when it is actually on screen.
NearbySpyWindow = { __shown = false }
function NearbySpyWindow:IsShown() return self.__shown end

DB = { peerEnabled = true, peerAllRealms = true }
function GetDB() return DB end

local function Widget()
    local w = {}
    w.SetText = function(self, t) self.text = t end
    w.SetPoint = function(self, ...)
        local a = { ... }
        self.__point = a
        self.__y = (type(a[2]) == "number") and a[2] or nil
    end
    w.SetSize = function(self) end
    w.SetWidth = function(self) end
    w.SetHeight = function(self, h) self.height = h end
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
SELECTS = {}
CHECK_ROWS = {}
function OptCheck(parent, x, y, labelKey, descKey, getter, setter)
    local cb, label, desc = Widget(), Widget(), Widget()
    cb.GetChecked = function(self) return self.checked end
    cb.SetChecked = function(self, v) self.checked = v and true or false end
    cb.__click = function() setter(not cb:GetChecked()) end
    CHECKS[labelKey] = cb
    label.text, desc.text = L(labelKey), L(descKey)
    CHECK_ROWS[#CHECK_ROWS + 1] = { key = labelKey, y = y, label = label, desc = desc }
    cb:SetChecked(getter())
    return cb, label, desc
end
function OptSelect(parent, y, name, labelKey, descKey, width, entriesFn, getCurrent, onPick)
    local label, desc = Widget(), Widget()
    label.text, desc.text = L(labelKey), L(descKey)
    SELECTS[labelKey] = { label = label, desc = desc, y = y }
    return { label = label, desc = desc, Refresh = function() end }
end
WIN = { height = nil }
"""


class SettingsRealmFlagTests(unittest.TestCase):
    def setUp(self):
        source = SOURCE.read_text(encoding="utf-8")
        start = source.index("local function BuildSettingsWindow()")
        end = source.index("function MinimapButton_Update()", start)
        block = source[start:end]
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        prelude = PRELUDE.replace("DESC_TEXT_JSON", DESC_TEXT_JSON)
        self.lua.execute(prelude + "\n" + block + "\nBuildSettingsWindow()\n"
                         "WIN = optWin\n"
                         "TestBuild = BuildSettingsWindow\n")

    def click(self):
        g = self.lua.globals()
        g["ShowSettingsWindow"]()
        g["CHECKS"]["SET_PEER_ALL"]["__click"]()

    def rows(self, table=None):
        t = table if table is not None else self.lua.globals()["CHECK_ROWS"]
        return [t[i] for i in range(1, len(list(t)) + 1)]

    # --- the flag itself ------------------------------------------------
    def test_checkbox_is_created_and_reflects_the_saved_value(self):
        cb = self.lua.globals()["CHECKS"]["SET_PEER_ALL"]
        self.assertTrue(cb is not None, "the accept-other-realms checkbox must exist")
        self.assertEqual(True, cb["checked"])

    def test_unchecking_writes_false_and_repaints_the_list(self):
        # the player window is open: its list must drop the foreign rows at once
        self.lua.globals()["NearbySpyWindow"]["__shown"] = True
        self.click()
        self.assertEqual(False, self.lua.globals()["DB"]["peerAllRealms"])
        repaints = self.lua.globals()["REPAINTS"]
        self.assertEqual(1, repaints["tactical"])
        self.assertEqual(1, repaints["hub"])

    def test_unchecking_with_a_closed_player_window_does_not_repaint(self):
        # a closed (or never built) player window has nothing to repaint; it
        # refreshes on its own OnShow. Repainting anyway crashed the list update.
        self.lua.globals()["NearbySpyWindow"]["__shown"] = False
        self.click()
        self.assertEqual(False, self.lua.globals()["DB"]["peerAllRealms"])
        self.assertEqual(0, self.lua.globals()["REPAINTS"]["tactical"])

    def test_checking_again_restores_the_value(self):
        self.click()
        self.click()
        self.assertEqual(True, self.lua.globals()["DB"]["peerAllRealms"])

    def test_language_switch_relabels_the_new_row(self):
        lua = self.lua
        lua.globals()["L"] = lua.eval("function(k) return 'LOC:' .. k end")
        lua.globals()["RefreshSettingsText"]()
        opt = lua.globals()["opt"]
        self.assertEqual("LOC:SET_PEER_ALL", opt["allRealmsLabel"]["text"])
        self.assertEqual("LOC:SET_PEER_ALL_D", opt["allRealmsDesc"]["text"])

    # --- layout ---------------------------------------------------------
    def test_rows_do_not_overlap_with_a_long_description(self):
        # 120 chars wrap to 3 lines at 55 chars per line — what the ru and de
        # strings do. The old fixed 52px step ignored the wrap and overlapped.
        rows = self.rows()
        self.assertGreaterEqual(len(rows), 3)
        measure = self.lua.globals()["OptTextHeight"]
        for prev, nxt in zip(rows, rows[1:]):
            label_h = measure(prev["label"], 14)
            desc_h = measure(prev["desc"], 22)
            needed = 4 + label_h + 3 + desc_h
            delta = prev["y"] - nxt["y"]
            self.assertGreaterEqual(
                delta, needed,
                f"row {nxt['key']} starts {delta}px below {prev['key']}, needs {needed}px")

    def test_spacing_follows_each_description_height(self):
        # every gap must equal what the row above needs — a constant step would
        # make some gaps too small (overlap) and others wastefully large
        measure = self.lua.globals()["OptTextHeight"]
        rows = self.rows()
        for prev, nxt in zip(rows, rows[1:]):
            needed = (4 + measure(prev["label"], 14) + 3
                      + measure(prev["desc"], 22))
            delta = prev["y"] - nxt["y"]
            self.assertLessEqual(
                delta, needed + 20,
                f"gap after {prev['key']} is {delta}px, row needs only {needed}px")

    def test_window_height_follows_content(self):
        win = self.lua.globals()["WIN"]
        self.assertIsNotNone(win["height"], "the window must size itself")
        last = self.rows()[-1]
        self.assertGreater(win["height"], -last["y"], "content is taller than the window")


if __name__ == "__main__":
    unittest.main()
