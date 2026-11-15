"""Realm filter: cycler button and list/stats scoping (Lua 5.1).

The database can hold players from several realms of the cluster (they arrive
over the peer channel), so the player list needs a realm selector. The toolbar is
full (four filters + counter), hence a second row with one cycling button:
all realms -> realm A -> realm B -> ... -> all again.

What this holds:
  - the list is built from the records and puts OUR realm first;
  - the list and the selection work in BUCKETS ("EU PvP" / "EU PvE"): the cluster
    has a dozen realms differing only by shard and number, and multiplying that
    difference was the old behaviour (user decision 15.11.2026);
  - the short label is the bucket; RealmShortName survives only as a fallback;
  - one click moves to the next realm and wraps back to "all";
  - the list AND the counters obey the selection (a "Peer 12" badge over a list
    of 3 rows would be a lie).
"""

from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

SOURCE = Path(__file__).resolve().parents[1] / "NearbySpy.lua"

MINE = "CAMWOW EU5 Realm 1 PvE"
P2 = "CAMWOW EU4 Realm 6 PvP"
P3 = "CAMWOW EU5 Realm 2 PvP"


def block() -> str:
    src = SOURCE.read_text(encoding="utf-8")
    # RealmBucket sits just above RealmShortName and is what the list and the
    # label now use, so the slice starts there.
    start = src.index("function RealmBucket(realm)")
    end = src.index("local function TacticalMetric(", start)
    return src[start:end]


PRELUDE = r"""
tactical = {filter = "all", started = 1000, realmFilter = nil}
TACTICAL_FRESH = 300
MY = "CAMWOW EU5 Realm 1 PvE"
function PlayerRealm() return MY end
function L(k) return k end
function time() return 1000 end

DB = {players = {}, debug = {}, peerAllRealms = true}
function GetDB() return DB end

UPDATES = 0
function TacticalUpdate() UPDATES = UPDATES + 1 end

function NewText() 
    local w = {}
    w.SetPoint = function() end
    w.SetWidth = function() end
    w.SetText = function(self, t) self.text = t end
    w.SetTextColor = function(self, r, g, b) self.color = {r, g, b} end
    return w
end
BUTTON = nil
function CreateFrame()
    local f = {}
    f.SetSize = function() end
    f.SetPoint = function(self, ...) self.__point = { ... } end
    f.CreateTexture = function() return { SetAllPoints = function() end, SetColorTexture = function() end } end
    f.SetScript = function(self, ev, fn) self.__scripts = self.__scripts or {}; self.__scripts[ev] = fn end
    BUTTON = f
    return f
end
"""


class RealmCyclerTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(PRELUDE + "\n" + block() + "\n"
                         "TestCycler = TacticalRealmCycler\n"
                         "TestState = TacticalRealmCyclerState\n"
                         "TestShort = RealmShortName\n"
                         "TestList = TacticalRealmList\n")
        # три записи из двух чужих миров и одного нашего
        self.lua.execute(
            'GetDB().players["A"] = {name="A", realm="' + P2 + '"} '
            'GetDB().players["B"] = {name="B", realm="' + P3 + '"} '
            'GetDB().players["C"] = {name="C", realm="' + MINE + '"}')

    def click(self):
        btn = self.lua.globals()["BUTTON"]
        btn["__scripts"]["OnClick"](btn)

    # --- list -----------------------------------------------------------
    def test_list_holds_buckets_with_our_own_first(self):
        lst = self.lua.globals()["TestList"]()
        got = [lst[i + 1] for i in range(len(list(lst)))]
        # A and B are different servers but the same bucket (EU PvP), C is our
        # own EU PvE: two entries, ours first.
        self.assertEqual(["EU PvE", "EU PvP"], got)

    def test_different_servers_do_not_multiply_labels(self):
        # the defect this change removes: two shards of the same ruleset used to
        # produce two near-identical entries
        self.lua.execute('GetDB().players["D"] = {name="D", realm="CAMWOW EU5 Realm 3 PvP"} '
                         'GetDB().players["E"] = {name="E", realm="CAMWOW EU5 Realm 7 PvE"}')
        lst = self.lua.globals()["TestList"]()
        got = [lst[i + 1] for i in range(len(list(lst)))]
        self.assertEqual(["EU PvE", "EU PvP"], got)

    def test_short_name_drops_only_the_cluster_prefix(self):
        short = self.lua.globals()["TestShort"]
        self.assertEqual("EU4 Realm 6 PvP", short(P2))
        self.assertEqual("EU5 Realm 1 PvE", short(MINE))

    # --- cycling --------------------------------------------------------
    def test_click_walks_realms_and_wraps_back(self):
        self.lua.globals()["TestCycler"](self.lua.globals(), 22, -256, 200)
        tac = self.lua.globals()["tactical"]
        self.assertIsNone(tac["realmFilter"], "starts at all realms")
        seen = []
        for _ in range(3):                      # 2 buckets + wrap
            self.click()
            seen.append(tac["realmFilter"])
        self.assertEqual(2, len(set(x for x in seen[:2])), "each bucket once")
        self.assertIsNone(seen[2], "the cycle wraps back to all realms")

    def test_selection_survives_a_rebuilt_list(self):
        self.lua.globals()["TestCycler"](self.lua.globals(), 22, -256, 200)
        self.click()
        first = self.lua.globals()["tactical"]["realmFilter"]
        # a new realm appears; the current selection must still step forward
        self.lua.execute('GetDB().players["D"] = {name="D", realm="CAMWOW EU9 Realm 1 PvP"}')
        self.click()
        second = self.lua.globals()["tactical"]["realmFilter"]
        self.assertNotEqual(first, second)

    # --- label ----------------------------------------------------------
    def test_button_is_anchored_by_top_left(self):
        # "LEFT" on the window means its vertical centre — the button would land
        # in the middle of the list instead of the row under the toolbar
        self.lua.globals()["TestCycler"](self.lua.globals(), 22, -256, 200)
        point = self.lua.globals()["BUTTON"]["__point"]
        self.assertEqual("TOPLEFT", point[1])
        self.assertEqual(22, point[2], "x offset")
        self.assertEqual(-256, point[3], "y offset: the row under the toolbar")

    def test_label_shows_all_realms_when_nothing_is_selected(self):
        self.lua.globals()["TestCycler"](self.lua.globals(), 22, -256, 200)
        self.assertEqual("UI_REALM: UI_ALL", self.lua.globals()["BUTTON"]["label"]["text"])

    def test_label_shows_the_selected_bucket(self):
        self.lua.globals()["TestCycler"](self.lua.globals(), 22, -256, 200)
        self.lua.globals()["tactical"]["realmFilter"] = "EU PvP"
        self.lua.globals()["TestState"]()
        self.assertEqual("UI_REALM: EU PvP",
                         self.lua.globals()["BUTTON"]["label"]["text"])

    def test_label_falls_back_to_the_short_name_for_an_odd_selection(self):
        # a selection carried over from an older build is a full realm name; the
        # label must still read sensibly instead of going blank
        self.lua.globals()["TestCycler"](self.lua.globals(), 22, -256, 200)
        self.lua.globals()["tactical"]["realmFilter"] = MINE
        self.lua.globals()["TestState"]()
        self.assertEqual("UI_REALM: EU PvE",
                         self.lua.globals()["BUTTON"]["label"]["text"])


if __name__ == "__main__":
    unittest.main()
