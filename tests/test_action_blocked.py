#!/usr/bin/env python3
"""The interface error dialog must not appear for OUR own blocked call.

`ADDON_ACTION_BLOCKED` raises the Blizzard dialog "Interface action failed
because of an AddOn". Ours fires on the channel send, which the client gates
behind a hardware event; the addon tries that call itself, already records the
refusal, and has nothing to ask the player about. So the popup is hidden when the
block belongs to NearbySpy — and only then: another addon's dialog is not ours to
close.

This file also holds the attribution of a block to its trigger context
(db.debug.gateWhy), which is what tells us later whether movement/cast/target
(non-hardware events) are the ones being refused.

Run: python tests/test_action_blocked.py
"""
from pathlib import Path
import re
import unittest

from lupa.lua51 import LuaRuntime

SOURCE = Path(__file__).resolve().parents[1] / "NearbySpy.lua"
SRC = SOURCE.read_text(encoding="utf-8")


def body(name: str) -> str:
    start = SRC.index(f"function {name}(")
    end = SRC.index("\nend\n", start) + len("\nend\n")
    return SRC[start:end]


PRELUDE = """
NOW = 5000
time = function() return NOW end
DB = { debug = {} }
function GetDB() return DB end
HIDDEN = {}
StaticPopup_Hide = function(which) HIDDEN[#HIDDEN + 1] = tostring(which) end
DEFERRED = {}
C_Timer = { After = function(delay, fn) DEFERRED[#DEFERRED + 1] = fn end }
function ranDeferred()
    local n = #DEFERRED
    for _, fn in ipairs(DEFERRED) do fn() end
    for _ = 1, n do table.remove(DEFERRED) end
    return n
end
RING = {}
function PeerEsc(s, n)
    if type(s) ~= "string" then return tostring(s) end
    if n and #s > n then return s:sub(1, n) end
    return s
end
"""


class BlockedPopupTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(PRELUDE + body("NspNoteBlock") + body("NspNoteSendRet") + "\n" + """
-- the branch of the ADDON_ACTION_BLOCKED handler, as in production
function handleBlocked(addon, func, event)
    local ours = NspNoteBlock(GetDB(), addon, func, time(), event)
    if ours and StaticPopup_Hide then
        pcall(StaticPopup_Hide, "ADDON_ACTION_BLOCKED")
        pcall(StaticPopup_Hide, "ADDON_ACTION_FORBIDDEN")
        if C_Timer and C_Timer.After then
            C_Timer.After(0, function()
                pcall(StaticPopup_Hide, "ADDON_ACTION_BLOCKED")
                pcall(StaticPopup_Hide, "ADDON_ACTION_FORBIDDEN")
            end)
        end
    end
    return ours
end
""")
        self.g = self.lua.globals()

    def hidden(self):
        out = self.g["HIDDEN"]
        return [str(out[i]) for i in range(1, len(out) + 1)]

    # --- popup suppression -------------------------------------------------

    def test_our_block_hides_the_dialog(self):
        ours = self.g["handleBlocked"]("NearbySpy", "UNKNOWN()", "ADDON_ACTION_BLOCKED")
        self.assertTrue(ours)
        self.assertIn("ADDON_ACTION_BLOCKED", self.hidden())
        self.assertIn("ADDON_ACTION_FORBIDDEN", self.hidden())

    def test_hide_is_repeated_on_the_next_frame(self):
        # Blizzard may show the popup AFTER our handler, so one hide is not enough
        self.g["handleBlocked"]("NearbySpy", "UNKNOWN()", "ADDON_ACTION_BLOCKED")
        before = len(self.hidden())
        ran = self.g["ranDeferred"]()
        self.assertEqual(1, ran, "the deferred hide was not scheduled")
        self.assertGreater(len(self.hidden()), before, "the dialog would come back")

    def test_another_addons_block_is_left_alone(self):
        ours = self.g["handleBlocked"]("SomeOtherAddon", "Foo()", "ADDON_ACTION_BLOCKED")
        self.assertFalse(ours)
        self.assertEqual([], self.hidden(), "we closed a dialog that was not ours")
        self.assertEqual(0, self.g["ranDeferred"]())

    def test_foreign_block_is_still_counted_separately(self):
        self.g["handleBlocked"]("SomeOtherAddon", "Foo()", "ADDON_ACTION_BLOCKED")
        self.assertEqual(1, self.g["DB"]["debug"]["blockedOther"]["SomeOtherAddon -> Foo()"])
        self.assertIsNone(self.g["DB"]["debug"]["blocked"])

    # --- the drain triggers that only produced refusals -------------------

    def test_no_event_trigger_makes_a_send_attempt(self):
        # The client gates channel sends to REAL hardware events, and only the
        # world click qualifies. History in two steps:
        #   16.11.2026 — PLAYER_STARTED/STOPPED_MOVING removed: the user saw the
        #                "Interface action failed because of an AddOn" popup when
        #                he moved (2869+2869 attempts, 156 refusals, 0 sends).
        #   20.11.2026 — the three remaining events removed too. Live counters
        #                from one run: world 34 598 attempts / 0 refusals, while
        #                PLAYER_TARGET_CHANGED gave 8 822 / 106 refusals,
        #                UNIT_SPELLCAST_START 1 498 / 27 and START_LOOT_ROLL
        #                102 / 1. All 16 messages of that run went out on a world
        #                click, so those 134 refusals bought nothing but popups.
        # A test, not a comment, keeps them from creeping back.
        # Ищем только триггеры ОТПРАВКИ (peerInput). Главный фрейм тоже слушает
        # PLAYER_TARGET_CHANGED — но там это СБОР встречи (Record("target")), он
        # ничего не отправляет и обязан остаться.
        self.assertNotIn("peerInput", SRC,
                         "фрейм peerInput вернулся: его события давали только "
                         "отказы гейта и попап «ошибка интерфейса»")
        # а вот единственный рабочий триггер обязан остаться
        self.assertIn('HookScript("OnMouseDown"', SRC)
        # сбор данных по цели обязан остаться на главном фрейме
        self.assertIn('pcall(Record, "target")', SRC,
                      "сбор встречи по смене цели пропал вместе с триггерами отправки")

    def test_the_world_click_trigger_is_still_hooked(self):
        # this is the one real hardware event we have — losing it would stall the
        # queue for players who never click into the world
        self.assertIn('HookScript("OnMouseDown"', SRC)
        self.assertIn('PeerTryDrain("world")', SRC)

    # --- attribution of a block to its trigger -----------------------------

    def test_gate_block_records_the_trigger_that_caused_it(self):
        self.g["DB"]["debug"]["lastDrainWhy"] = "PLAYER_STARTED_MOVING"
        self.g["NspNoteBlock"](self.g["DB"], "NearbySpy", "UNKNOWN()", 5000, "ADDON_ACTION_BLOCKED")
        fired = self.g["NspNoteSendRet"](self.g["DB"], True, None, 5000)
        self.assertTrue(fired)
        self.assertEqual(1, self.g["DB"]["debug"]["gateWhy"]["PLAYER_STARTED_MOVING"])

    def test_triggers_are_counted_separately(self):
        dbg = self.g["DB"]["debug"]
        # a Python dict assigned into a Lua table is not a Lua table: build it in Lua
        self.lua.execute('DB.debug.blockedAt = { ["UNKNOWN()"] = 5000 }')
        for why in ("world", "world", "UNIT_SPELLCAST_START"):
            dbg["lastDrainWhy"] = why
            self.g["NspNoteSendRet"](self.g["DB"], True, None, 5000)
        self.assertEqual(2, dbg["gateWhy"]["world"])
        self.assertEqual(1, dbg["gateWhy"]["UNIT_SPELLCAST_START"])

    def test_real_success_does_not_count_a_gate_loss(self):
        self.g["DB"]["debug"]["lastDrainWhy"] = "world"
        self.lua.execute('DB.debug.blockedAt = { ["UNKNOWN()"] = 5000 }')
        # a send that actually returned a value cannot be a blocked one
        self.assertFalse(self.g["NspNoteSendRet"](self.g["DB"], True, True, 5000))
        self.assertIsNone(self.g["DB"]["debug"]["gateWhy"])


if __name__ == "__main__":
    unittest.main()
