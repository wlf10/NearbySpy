#!/usr/bin/env python3
"""Gate diagnostics: block attribution, send-return probe, combat keyboard guard.

Three defects found in the live save on 15.11.2026:

1. `db.debug.blocked[func]` grew on a block of ANY addon, not only ours, and had
   no timestamp — "UNKNOWN() = 147" answered neither "how often were WE blocked"
   nor "when". Own calls now go to blocked/blockedAt/blockedEvent, foreign ones
   to blockedOther with the addon name.

2. A blocked send looked exactly like a successful one: the client gate reports
   itself by EVENT, not by return value, so three ADDON_ACTION_BLOCKED lines sat
   glued to "Peer sent" lines and there was no way to tell whether the packet
   left. The return value (with its type) is recorded and sends coinciding with
   a block are counted.

3. `SetPropagateKeyboardInput` is refused during combat lockdown (one blocked
   NearbySpyHubWindow call in the live save). Calling it anyway raised a false
   alarm in the diagnostics, so it is skipped in combat and counted.

Run: python tests/test_gate_diagnostics.py
"""
from pathlib import Path
import sys
import unittest

from lupa.lua51 import LuaRuntime

SOURCE = Path(__file__).resolve().parents[1] / "NearbySpy.lua"


def function_body(src: str, name: str) -> str:
    """The global function `name` with its trailing `end`, as source text."""
    start = src.index(f"function {name}(")
    end = src.index("\nend\n", start) + len("\nend\n")
    return src[start:end]


PRELUDE = """
-- stubs for the surrounding addon code
local DB = { debug = {} }
function GetDB() return DB end
function PeerEsc(s, maxLen)
    if type(s) ~= "string" then return tostring(s) end
    if maxLen and #s > maxLen then return s:sub(1, maxLen) .. "..." end
    return s
end
local DLOG = {}
local function D(msg) DLOG[#DLOG + 1] = tostring(msg) end
COMBAT = false
function InCombatLockdown() return COMBAT end
"""

EXPORTS = """
_G.T = { db = DB, log = DLOG,
    setCombat = function(v) COMBAT = v end }
"""


class GateDiagnosticsTests(unittest.TestCase):
    def setUp(self):
        src = SOURCE.read_text(encoding="utf-8")
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(
            PRELUDE
            + function_body(src, "NspNoteBlock")
            + function_body(src, "NspNoteSendRet")
            + function_body(src, "NspKeyboardPropagate")
            + EXPORTS
        )
        self.t = self.lua.globals()["T"]

    # --- 1. attribution -----------------------------------------------------

    def test_our_block_is_counted_with_a_timestamp(self):
        ours = self.lua.globals()["NspNoteBlock"]
        flagged = ours(self.t["db"], "NearbySpy", "SendWho()", 1000, "ADDON_ACTION_BLOCKED")
        self.assertTrue(flagged)
        debug = self.t["db"]["debug"]
        self.assertEqual(1, debug["blocked"]["SendWho()"])
        self.assertEqual(1000, debug["blockedAt"]["SendWho()"])
        self.assertEqual("ADDON_ACTION_BLOCKED", debug["blockedEvent"]["SendWho()"])

    def test_foreign_block_does_not_touch_our_counter(self):
        # this is the actual defect: 147 foreign blocks were attributed to us
        block = self.lua.globals()["NspNoteBlock"]
        flagged = block(self.t["db"], "SomeOtherAddon", "UNKNOWN()", 1000, "ADDON_ACTION_BLOCKED")
        self.assertFalse(flagged)
        debug = self.t["db"]["debug"]
        self.assertIsNone(debug["blocked"], "a foreign block must not create/raise our counter")
        self.assertEqual(1, debug["blockedOther"]["SomeOtherAddon -> UNKNOWN()"])

    def test_blocks_are_grouped_per_addon_and_function(self):
        block = self.lua.globals()["NspNoteBlock"]
        block(self.t["db"], "AddonA", "Foo()", 1, "E")
        block(self.t["db"], "AddonA", "Foo()", 2, "E")
        block(self.t["db"], "AddonB", "Foo()", 3, "E")
        other = self.t["db"]["debug"]["blockedOther"]
        self.assertEqual(2, other["AddonA -> Foo()"])
        self.assertEqual(1, other["AddonB -> Foo()"])

    def test_our_counter_accumulates_across_calls(self):
        block = self.lua.globals()["NspNoteBlock"]
        block(self.t["db"], "NearbySpy", "UNKNOWN()", 100, "E")
        block(self.t["db"], "NearbySpy", "UNKNOWN()", 200, "E")
        debug = self.t["db"]["debug"]
        self.assertEqual(2, debug["blocked"]["UNKNOWN()"])
        self.assertEqual(200, debug["blockedAt"]["UNKNOWN()"], "the stamp must be the latest block")

    # --- 2. send-return probe ----------------------------------------------

    def test_probe_records_what_the_call_returned(self):
        note = self.lua.globals()["NspNoteSendRet"]
        note(self.t["db"], True, None, 5000)
        # the type matters: some clients return nothing at all on success, and
        # without knowing that a nil return cannot be read as "blocked"
        self.assertEqual("ok=true ret=nil:nil", self.t["db"]["debug"]["sendRet"])
        self.assertEqual(5000, self.t["db"]["debug"]["sendRetAt"])

    def test_probe_records_a_false_return(self):
        note = self.lua.globals()["NspNoteSendRet"]
        note(self.t["db"], True, False, 5000)
        self.assertEqual("ok=true ret=boolean:false", self.t["db"]["debug"]["sendRet"])

    def test_send_coinciding_with_a_block_is_counted(self):
        block = self.lua.globals()["NspNoteBlock"]
        note = self.lua.globals()["NspNoteSendRet"]
        block(self.t["db"], "NearbySpy", "UNKNOWN()", 5000, "ADDON_ACTION_BLOCKED")
        self.assertTrue(note(self.t["db"], True, None, 5000))
        self.assertEqual(1, self.t["db"]["debug"]["peerGate"])

    def test_send_far_from_a_block_is_not_counted(self):
        block = self.lua.globals()["NspNoteBlock"]
        note = self.lua.globals()["NspNoteSendRet"]
        block(self.t["db"], "NearbySpy", "UNKNOWN()", 1000, "ADDON_ACTION_BLOCKED")
        self.assertFalse(note(self.t["db"], True, None, 1000 + 60),
                         "a block a minute ago says nothing about this send")
        self.assertIsNone(self.t["db"]["debug"]["peerGate"])

    def test_send_without_any_block_is_not_counted(self):
        note = self.lua.globals()["NspNoteSendRet"]
        self.assertFalse(note(self.t["db"], True, None, 5000))
        self.assertIsNone(self.t["db"]["debug"]["peerGate"])

    def test_raised_send_is_not_counted_as_a_gate_loss(self):
        # ok=false means the call itself threw — a different problem, reported
        # through peerSendError, not through the gate counter
        block = self.lua.globals()["NspNoteBlock"]
        note = self.lua.globals()["NspNoteSendRet"]
        block(self.t["db"], "NearbySpy", "UNKNOWN()", 5000, "ADDON_ACTION_BLOCKED")
        self.assertFalse(note(self.t["db"], False, "boom", 5000))

    # --- 3. combat keyboard guard ------------------------------------------

    def test_keyboard_capture_is_skipped_in_combat(self):
        self.lua.execute(
            "CALLS = {}\n"
            "local f = { SetPropagateKeyboardInput = function(self, v) CALLS[#CALLS+1] = tostring(v) end }\n"
            "FRAME = f\n"
        )
        self.t["setCombat"](True)
        self.lua.globals()["NspKeyboardPropagate"](self.lua.globals()["FRAME"], False)
        self.assertEqual(0, len(self.lua.globals()["CALLS"]), "the client refuses this call in combat")
        self.assertEqual(1, self.t["db"]["debug"]["kbLockdown"])

    def test_keyboard_capture_works_out_of_combat(self):
        self.lua.execute(
            "CALLS = {}\n"
            "local f = { SetPropagateKeyboardInput = function(self, v) CALLS[#CALLS+1] = tostring(v) end }\n"
            "FRAME = f\n"
        )
        self.t["setCombat"](False)
        self.lua.globals()["NspKeyboardPropagate"](self.lua.globals()["FRAME"], False)
        self.assertEqual("false", self.lua.globals()["CALLS"][1])
        self.assertIsNone(self.t["db"]["debug"]["kbLockdown"])

    def test_missing_method_is_not_an_error(self):
        self.t["setCombat"](False)
        self.lua.execute("BARE = {}")
        self.lua.globals()["NspKeyboardPropagate"](self.lua.globals()["BARE"], True)

    def test_lockdown_is_logged_once_not_every_keypress(self):
        self.lua.execute(
            "local f = { SetPropagateKeyboardInput = function() end }\n"
            "FRAME = f\n"
        )
        self.t["setCombat"](True)
        for _ in range(5):
            self.lua.globals()["NspKeyboardPropagate"](self.lua.globals()["FRAME"], True)
        self.assertEqual(5, self.t["db"]["debug"]["kbLockdown"])
        self.assertEqual(1, len(self.t["log"]), "the ring should get one line, not one per keypress")


if __name__ == "__main__":
    unittest.main()
