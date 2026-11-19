#!/usr/bin/env python3
"""NearbySpy_Probe.lua — the /nspy inspecttest probe must measure, not guess.

The probe answers two product questions on the live client: can the addon read
another player's GEAR (NotifyInspect → INSPECT_READY → GetInventoryItemLink) and
is there ANY working route to their TALENTS. Its value is that the three
outcomes stay apart, so the rules below are the contract:

  - "the function is absent" (recorded through the API snapshot), "the function
    throws" (recorded with its error text) and "the function answers" are
    three different results — a silent nil must never read as "no data";
  - silence is a finding: a unit whose INSPECT_READY never arrives is recorded
    as a TIMEOUT, never as "inspected with empty slots" (those mean opposite
    things: one says the server ignores us, the other that the server answered);
  - the SV snapshot is REPLACED on every run, so probing repeatedly cannot
    grow the SavedVariables file;
  - a secret string (the client marks such values) must not crash the read: the
    sample is recorded as <secret> and the rest of the inspect still lands.

Every case runs the real file in a real Lua 5.1 runtime with the client globals
stubbed; timers are collected and fired by the test, because the pacing between
inspect requests is part of the behaviour (the client's own code warns the
server drops inspect data on flood).

Run: python tests/test_inspect_probe.py
"""
import unittest
from pathlib import Path

from lupa.lua51 import LuaRuntime

PROBE_FILE = Path(__file__).resolve().parents[1] / "NearbySpy_Probe.lua"

PRELUDE = """
NOW = 1000
time = function() return NOW end

-- timers are collected, never auto-fired: the pause between NotifyInspect
-- calls is behaviour under test, not an implementation detail
TIMERS = {}
C_Timer = { After = function(sec, fn) TIMERS[#TIMERS + 1] = { sec = sec, fn = fn } end }
function FireTimers(limit)
    local n = 0
    while #TIMERS > 0 and n < (limit or 50) do
        local t = table.remove(TIMERS, 1)
        n = n + 1
        t.fn()
    end
    return n
end

CHAT = {}
DEFAULT_CHAT_FRAME = { AddMessage = function(_, msg) CHAT[#CHAT + 1] = tostring(msg) end }
function PStub(msg) CHAT[#CHAT + 1] = tostring(msg) end

CreateFrame = function() return { RegisterEvent = function() end, SetScript = function() end } end
GetBuildInfo = function() return "1.60.1", "70291", "Nov 17 2026", 16001 end

UNITS = { target = { exists = true, name = "Randaz Windlance", guid = "Player-1-00000001" } }
UnitExists = function(u) return UNITS[u] ~= nil and UNITS[u].exists == true end
UnitName = function(u) local r = UNITS[u]; return r and r.name or nil end
UnitGUID = function(u) local r = UNITS[u]; return r and r.guid or nil end
UnitClass = function(u) return "Mage", "MAGE" end
UnitLevel = function(u) return 60 end
UnitIsUnit = function(a, b) return false end

CAN_INSPECT = true
CanInspect = function(u, strict) return CAN_INSPECT end
NOTIFY = {}
NotifyInspect = function(u) NOTIFY[#NOTIFY + 1] = u end

ITEMS = {}
GetInventoryItemLink = function(u, slot) return ITEMS[slot] end
GetInventoryItemID = function(u, slot) return ITEMS[slot] and (1000 + slot) or nil end

SECRET = false
canaccessvalue = function(v) return not SECRET end

DB = {}
"""


class ProbeTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(PRELUDE)
        self.g = self.lua.globals()
        self.J = self.lua.execute(PROBE_FILE.read_text(encoding="utf-8"))
        self.J["P"] = self.g["PStub"]
        self.J["GetDB"] = self.lua.eval("function() return DB end")
        self.db = self.g["DB"]

    # -- helpers -----------------------------------------------------------
    def fire(self, limit=50):
        return self.g["FireTimers"](limit)

    def run_probe(self, arg=""):
        self.J["Run"](arg)

    def snapshot(self):
        return self.db["debug"]["inspect"]

    def chat(self):
        return [str(x) for x in self.g["CHAT"].values()]

    def give_gear(self):
        self.g["ITEMS"] = self.lua.eval(
            '{[1] = "|Hitem:1|h[Helm]|h", [5] = "|Hitem:5|h[Chest]|h", [16] = "|Hitem:16|h[Sword]|h"}'
        )

    def give_talents(self):
        self.lua.execute("""
        C_SpecializationInfo = {
            -- classic-era inspect signature; answers only with isInspect + unit
            -- the TABLE-argument API: positional calls throw in the client
            GetTalentInfo = function(query)
                if type(query) == "table" and query.isInspect and query.target == "target" then
                    return { name = "Improved Fireball", ranks = query.tier, maxRanks = 5 }
                end
            end,
            GetInspectSpecialization = function(unit) return 3 end,
        }
        """)

    # -- argument parsing (pure) -------------------------------------------
    def test_parse_args_defaults(self):
        a = self.J["ParseArgs"](None)
        self.assertEqual(a["mode"], "unit")
        self.assertEqual(int(a["gap"]), 2)
        self.assertEqual(int(a["timeout"]), 6)
        self.assertEqual(int(a["maxUnits"]), 4)

    def test_parse_args_modes(self):
        self.assertEqual(self.J["ParseArgs"]("all")["mode"], "all")
        self.assertEqual(self.J["ParseArgs"]("nm")["mode"], "nm")
        self.assertEqual(self.J["ParseArgs"]("nameplates")["mode"], "nm")
        self.assertEqual(self.J["ParseArgs"]("party")["mode"], "party")

    def test_parse_args_clamps_values_in_code_not_in_the_players_head(self):
        # a zero gap would flood the server (which then drops inspect data) and
        # a huge max would make a throwaway probe into a long unattended run
        self.assertEqual(int(self.J["ParseArgs"]("gap 0")["gap"]), 1)
        self.assertEqual(int(self.J["ParseArgs"]("gap 99")["gap"]), 15)
        self.assertEqual(int(self.J["ParseArgs"]("max 99")["maxUnits"]), 10)
        self.assertEqual(int(self.J["ParseArgs"]("timeout 1")["timeout"]), 2)
        self.assertEqual(int(self.J["ParseArgs"]("GAP 3 MAX 2")["gap"]), 3)
        self.assertEqual(int(self.J["ParseArgs"]("gap 3 max 2")["maxUnits"]), 2)

    # -- the three outcomes of a call --------------------------------------
    def test_try_keeps_absent_and_throwing_apart(self):
        absent = self.J["Try"]("x", None)
        self.assertIn("absent", absent["err"])
        self.assertIsNone(absent["v"])

        throwing = self.J["Try"]("y", self.lua.eval("function() error('boom') end"))
        self.assertIn("boom", throwing["err"])
        self.assertIsNone(throwing["v"])

        answering = self.J["Try"]("z", self.lua.eval("function() return 7, 8 end"))
        self.assertIsNone(answering["err"])
        self.assertEqual(int(answering["n"]), 2)
        # ⚠️ {pcall(f)} shifts returns by one: a naive reader would show 8, nil
        self.assertEqual(answering["v"], "7|8")

    # -- gear ---------------------------------------------------------------
    def test_gear_reads_slots_after_inspect_ready(self):
        self.give_gear()
        self.run_probe("")
        self.assertEqual(list(self.g["NOTIFY"].values()), ["target"])

        self.J["OnInspectReady"]("Player-1-00000001")
        self.fire()

        snap = self.snapshot()
        self.assertEqual(int(snap["answered"]), 1)
        rec = list(snap["lastRun"].values())[0]
        self.assertEqual(rec["event"], "INSPECT_READY")
        self.assertEqual(int(rec["items"]["links"]), 3)
        self.assertIn("1=|Hitem:1", rec["items"]["sampleText"])

    def test_silence_is_a_timeout_not_an_empty_inspect(self):
        # the server ignoring us and the server answering "no items" look the
        # same in the SV unless the probe writes the timeout explicitly
        self.run_probe("")
        self.fire()          # the timeout expires, the queue drains, report runs

        snap = self.snapshot()
        self.assertEqual(int(snap["answered"]), 0)
        rec = list(snap["lastRun"].values())[0]
        self.assertTrue(str(rec["event"]).startswith("timeout"), rec["event"])
        self.assertIsNone(rec["items"])

    def test_secret_link_does_not_crash_the_read(self):
        self.give_gear()
        self.g["SECRET"] = True
        self.run_probe("")
        self.J["OnInspectReady"]("Player-1-00000001")
        self.fire()

        rec = list(self.snapshot()["lastRun"].values())[0]
        self.assertIsNone(rec["readError"])
        self.assertEqual(int(rec["items"]["links"]), 3)
        self.assertIn("<secret>", rec["items"]["sampleText"])

    # -- talents ------------------------------------------------------------
    def test_every_talent_variant_is_recorded_with_its_own_outcome(self):
        self.give_talents()
        self.run_probe("")
        self.J["OnInspectReady"]("Player-1-00000001")
        self.fire()

        rec = list(self.snapshot()["lastRun"].values())[0]
        by_name = {t["f"]: t for t in rec["talents"].values()}
        # the route that answers is the finding
        hit = by_name["spec.GetTalentInfo{ml}"]
        self.assertIn("Improved Fireball", hit["v"])
        self.assertIn("ranks=1", hit["v"])
        self.assertEqual(int(by_name["spec.GetInspectSpecialization"]["v"]), 3)
        # a route with no implementation must say "absent", not "no data"
        self.assertIn("absent", by_name["traits.HasValidInspectData()"]["err"])
        self.assertTrue(any("talents=" in line for line in self.chat()))

    def test_api_snapshot_separates_present_from_missing(self):
        self.lua.execute("C_Traits = { CanEditConfig = function() end }")
        self.run_probe("")
        self.fire()          # the matrix lands in SV with the report
        snap = self.snapshot()
        self.assertEqual(snap["api"]["C_Traits.HasValidInspectData"], "nil")
        # a path the probe never asked about is MISSING FROM THE TABLE, which is
        # how "not asked" stays distinguishable from "asked and absent"
        self.assertIsNone(snap["api"]["C_Traits.CanEditConfig"])
        self.assertEqual(snap["api"]["C_Traits.GetConfigsByType"], "nil")
        self.assertEqual(snap["api"]["CanInspect"], "function")
        self.assertGreater(int(snap["apiPresent"]), 0)

    # -- run contract -------------------------------------------------------
    def test_snapshot_is_replaced_not_appended(self):
        self.give_gear()
        for _ in range(2):
            self.run_probe("")
            self.J["OnInspectReady"]("Player-1-00000001")
            self.fire()
        self.assertEqual(len(list(self.snapshot()["lastRun"].values())), 1)

    def test_no_unit_is_a_message_and_not_an_empty_run(self):
        self.g["UNITS"] = self.lua.eval("{}")
        self.run_probe("")
        self.assertIsNone(self.db["debug"]["inspect"] if "debug" in self.db else None)
        self.assertTrue(any("no unit to probe" in line for line in self.chat()))

    def test_second_command_cancels_the_running_probe(self):
        self.run_probe("")
        self.run_probe("")
        self.assertTrue(any("cancelled" in line for line in self.chat()))

    # -- talents: the table-argument API and the import string ---------------
    def test_talent_grid_reads_tiers_through_the_query_table(self):
        self.give_talents()
        self.run_probe("")
        self.J["OnInspectReady"]("Player-1-00000001")
        self.fire()

        rec = list(self.snapshot()["lastRun"].values())[0]
        # one row per tier/column/shape that answered — the grid is the readable
        # form of the build, so a zero here must mean "the API answered nothing"
        self.assertGreaterEqual(int(rec["grid"]["hits"]), 9)
        self.assertIn("Improved Fireball", rec["grid"]["sample"])

    def test_own_import_string_is_recorded_for_comparison(self):
        # the inspect string is only proof of the TARGET's build if it differs
        # from the player's own — so both are stored
        self.lua.execute("""
        C_Traits = {
            GenerateInspectImportString = function(unit) return "TARGETBUILD" end,
            GenerateImportString = function(configID) return "MYOWNBUILD" end,
        }
        C_ClassTalents = { GetActiveConfigID = function() return 7 end }
        """)
        self.run_probe("")
        self.J["OnInspectReady"]("Player-1-00000001")
        self.fire()

        rec = list(self.snapshot()["lastRun"].values())[0]
        self.assertEqual(rec["talents"][1]["v"], "TARGETBUILD")
        self.assertEqual(rec["ownString"], "MYOWNBUILD")
        self.assertNotEqual(rec["talents"][1]["v"], rec["ownString"])

    def test_has_valid_inspect_data_is_called_without_arguments(self):
        # documented as argument-less; passing a unit threw on the live client
        # and looked like "no trait data" in the matrix
        self.lua.execute("""
        C_Traits = { HasValidInspectData = function(...)
            if select("#", ...) > 0 then error("takes no arguments") end
            return true
        end }
        """)
        self.run_probe("")
        self.J["OnInspectReady"]("Player-1-00000001")
        self.fire()

        rec = list(self.snapshot()["lastRun"].values())[0]
        by_name = {t["f"]: t for t in rec["talents"].values()}
        self.assertEqual(by_name["traits.HasValidInspectData()"]["v"], "true")

    # -- native UI: the client can just open the target's talent window ------
    def test_ui_mode_calls_the_native_inspect_path(self):
        calls = self.lua.execute("""
        NATIVE = {}
        InspectUnit = function(unit) NATIVE[#NATIVE + 1] = "InspectUnit:" .. tostring(unit) end
        PlayerSpellsUtil = { OpenToClassTalentsTab = function(unit)
            NATIVE[#NATIVE + 1] = "TalentTab:" .. tostring(unit) end }
        return NATIVE
        """)
        self.run_probe("ui")
        self.J["OnInspectReady"]("Player-1-00000001")
        self.fire()

        rec = list(self.snapshot()["lastRun"].values())[0]
        self.assertIsNotNone(rec["native"])
        self.assertIsNone(rec["native"]["inspectUnit"]["err"])
        self.assertIsNone(rec["native"]["talentTab"]["err"])
        got = [str(x) for x in self.g["NATIVE"].values()]
        self.assertIn("InspectUnit:target", got)
        self.assertIn("TalentTab:target", got)

    def test_ui_mode_is_off_by_default(self):
        self.assertEqual(self.J["ParseArgs"]("")["openUi"], False)
        self.assertEqual(self.J["ParseArgs"]("ui")["openUi"], True)
        self.assertEqual(self.J["ParseArgs"]("ui")["mode"], "unit")

    # -- the ring of probed players -----------------------------------------
    def test_players_ring_is_bounded_and_keyed_by_guid(self):
        self.give_gear()
        for i in range(9):
            guid = "Player-1-%08d" % (i + 1)
            self.lua.execute('UNITS["target"]["guid"] = "%s"' % guid)
            self.run_probe("")
            self.J["OnInspectReady"](guid)
            self.fire()

        dbg = self.db["debug"]
        order = [str(g) for g in dbg["playerOrder"].values()]
        self.assertEqual(len(order), 8)                 # oldest evicted
        self.assertEqual(order[0], "Player-1-00000002")
        self.assertEqual(len(list(dbg["players"].values())), 8)
        self.assertNotIn("Player-1-00000001", dbg["players"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
