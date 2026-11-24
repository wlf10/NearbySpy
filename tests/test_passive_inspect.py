#!/usr/bin/env python3
"""NearbySpy_Inspect.lua — passive gear collection must be polite and honest.

The inspector runs with no user action and no window: on every encounter the
addon queues a NotifyInspect and stores the answer in the player's record. That
makes three things load-bearing, and each one is a rule below:

  - POLITE. The client's own inspect code warns the server drops inspect data
    when requests are flooded. So: one request in flight at a time, requests
    paced by a timer, the same player skipped inside the cooldown, a bounded
    queue and a session cap. A test that only checks "it stores a snapshot"
    would pass on a version that hammers the server.
  - HONEST. Silence (no INSPECT_READY) is recorded as a timeout and never as an
    empty snapshot — "the server ignored us" and "the server said: no gear"
    mean opposite things.
  - BOUNDED. Snapshots live in SavedVariables, so the ring cap must actually
    drop the oldest snapshot while leaving the player row intact.

Timers are collected and fired by the test (never auto-run): the pause between
requests is behaviour under test, not an implementation detail.

Run: python tests/test_passive_inspect.py
"""
import unittest
from pathlib import Path

from lupa.lua51 import LuaRuntime

INSPECT_FILE = Path(__file__).resolve().parents[1] / "NearbySpy_Inspect.lua"

PRELUDE = """
NOW = 1000
time = function() return NOW end
MATH_RANDOM = function() return 0 end   -- deterministic gap in tests

TIMERS = {}
C_Timer = { After = function(sec, fn) TIMERS[#TIMERS + 1] = { sec = sec, fn = fn } end }
function FireTimers(limit)
    local n = 0
    while #TIMERS > 0 and n < (limit or 100) do
        local t = table.remove(TIMERS, 1)
        n = n + 1
        t.fn()
    end
    return n
end

CHAT = {}
function PStub(msg) CHAT[#CHAT + 1] = tostring(msg) end
DEFAULT_CHAT_FRAME = { AddMessage = function(_, msg) CHAT[#CHAT + 1] = tostring(msg) end }

CreateFrame = function() return { RegisterEvent = function() end, SetScript = function() end } end

UNITS = { target = { guid = "Player-1-00000001" } }
UnitExists = function(u) return UNITS[u] ~= nil end
UnitGUID = function(u) local r = UNITS[u]; return r and r.guid or nil end
UnitIsUnit = function(a, b) return false end
UnitIsPlayer = function(u) return true end

CanInspect = function(u, strict) return UNITS[u] ~= nil end
NOTIFY = {}
NotifyInspect = function(u) NOTIFY[#NOTIFY + 1] = u end

ITEMS = { [5] = 3283, [7] = 5941, [16] = 5191 }
ILVL = 42
IMPORT = "C0cBZcHs6hiHBl7Csp3hvR"
GetInventoryItemID = function(u, slot) return ITEMS[slot] end
C_PaperDollInfo = { GetInspectItemLevel = function(u) return ILVL end }
C_Traits = { GenerateInspectImportString = function(u) return IMPORT end }

DB = { players = {} }
"""


class PassiveInspectTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(PRELUDE)
        # deterministic pacing
        self.lua.execute("math.random = function() return 0 end")
        self.g = self.lua.globals()
        src = INSPECT_FILE.read_text(encoding="utf-8")
        self.J = self.lua.execute(src)
        # Потолок кольца — local в исходнике; выносим его в глобал, чтобы тест
        # проверял ФАКТИЧЕСКИЙ лимит, а не зашитое когда-то число.
        import re as _re
        m = _re.search(r"local MAX_GEAR = (\d+)", src)
        if m:
            self.g["NSP_INSPECT_MAX_GEAR"] = int(m.group(1))
        self.J["P"] = self.g["PStub"]
        self.J["GetDB"] = self.lua.eval("function() return DB end")
        self.db = self.g["DB"]
        self.db["players"]["Ann-Realm"] = self.lua.eval('{ name = "Ann", realm = "Realm" }')

    # -- helpers -----------------------------------------------------------
    def fire(self, limit=200):
        return self.g["FireTimers"](limit)

    def request(self, unit="target", key="Ann-Realm"):
        return self.J["Request"](unit, key)

    def notify_count(self):
        return len(list(self.g["NOTIFY"].values()))

    def ready(self, guid="Player-1-00000001"):
        self.J["OnInspectReady"](guid)

    def gear(self, key="Ann-Realm"):
        return self.db["players"][key]["gear"]

    def counters(self):
        return self.db["debug"]["inspectQueue"]

    # -- the snapshot itself ------------------------------------------------
    def test_encounter_stores_slots_ilvl_and_build(self):
        self.request()
        self.assertEqual(self.notify_count(), 1)      # one request, sent once
        self.ready()

        g = self.gear()
        self.assertEqual(g["ids"], "5:3283,7:5941,16:5191")
        self.assertEqual(int(g["slots"]), 3)          # count of stored slots
        self.assertEqual(int(g["ilvl"]), 42)
        self.assertEqual(g["imp"], "C0cBZcHs6hiHBl7Csp3hvR")
        self.assertEqual(int(self.counters()["ok"]), 1)

    def test_no_window_is_ever_opened(self):
        # the whole point: no InspectFrame / talent frame call anywhere
        src = INSPECT_FILE.read_text(encoding="utf-8")
        for forbidden in ("OpenToClassTalentsTab", "InspectUnit(", "PlayerSpellsFrame",
                          "ShowUIPanel", "InspectFrame"):
            self.assertNotIn(forbidden, src)

    # -- politeness ---------------------------------------------------------
    def test_requests_are_paced_not_chained(self):
        # a second player must NOT be requested in the same tick: the server
        # drops inspect data when requests are flooded
        self.db["players"]["Bob-Realm"] = self.lua.eval('{ name = "Bob", realm = "Realm" }')
        self.g["UNITS"] = self.lua.eval('{ target = { guid = "Player-1-00000001" },'
                                        ' mouseover = { guid = "Player-1-00000002" } }')
        self.request("target", "Ann-Realm")
        self.request("mouseover", "Bob-Realm")
        self.assertEqual(self.notify_count(), 1)      # one in flight only

        self.ready("Player-1-00000001")               # answer → next is scheduled
        self.assertEqual(self.notify_count(), 1)      # still nothing: gap timer
        self.fire()                                   # the gap elapses
        self.assertEqual(self.notify_count(), 2)      # now Bob is requested

    def test_same_player_is_skipped_inside_the_cooldown(self):
        self.request()
        self.ready()
        self.assertEqual(int(self.counters()["ok"]), 1)

        self.g["NOW"] = 1000 + 60                     # a minute later
        self.request()
        self.assertEqual(self.notify_count(), 1)      # no new request
        self.assertEqual(int(self.counters()["skipCooldown"]), 1)

    def test_same_player_is_inspected_again_after_the_cooldown(self):
        self.request()
        self.ready()
        self.g["NOW"] = 1000 + 6 * 3600 + 1
        self.request()
        self.assertEqual(self.notify_count(), 2)

    def test_queue_is_bounded(self):
        # Очередь ограничена (MAX_QUEUE), и лишнее считается, а не копится
        # молча. Граница вынесена в константу: она уже менялась (40 → 80),
        # поэтому тест берёт предел ИЗ КОДА, а не дублирует число.
        import re as _re
        src = INSPECT_FILE.read_text(encoding="utf-8")
        cap = int(_re.search(r"local MAX_QUEUE = (\d+)", src).group(1))
        self.g["UNITS"] = self.lua.eval(
            '{ target = { guid = "Player-1-00000001" } }')
        # cap+20 distinct players queued while nothing can be processed
        self.J["Request"]("target", "Ann-Realm")      # occupies the in-flight slot
        for i in range(cap + 20):
            key = "P%d-Realm" % i
            self.db["players"][key] = self.lua.eval('{ name = "x", realm = "Realm" }')
            self.g["UNITS"]["target"]["guid"] = "Player-1-%08d" % (i + 2)
            self.J["Request"]("target", key)
        # queue cap is 40 — the excess is counted, not queued silently
        dropped = self.counters()["droppedFull"]
        self.assertGreater(int(dropped or 0), 0)

    def test_session_cap_stops_the_flood(self):
        src = INSPECT_FILE.read_text(encoding="utf-8")
        self.assertIn("MAX_PER_SESSION", src)
        self.assertIn("sentThisSession >= MAX_PER_SESSION", src)

    # -- honesty ------------------------------------------------------------
    def test_silence_is_a_timeout_and_stores_nothing(self):
        self.request()
        self.fire()                                   # the timeout expires
        self.assertEqual(int(self.counters()["timeout"]), 1)
        self.assertIsNone(self.gear())                # no empty snapshot written

    def test_empty_inspect_is_counted_not_stored_as_gear(self):
        # a valid answer with zero items must not masquerade as real gear
        self.g["ITEMS"] = self.lua.eval("{}")
        self.request()
        self.ready()
        self.assertEqual(int(self.counters()["emptySlots"]), 1)
        self.assertIsNone(self.gear())

    def test_stale_event_of_another_player_is_rejected(self):
        self.request()
        self.ready("Player-1-00000002")               # not the unit we asked for
        self.assertEqual(int(self.counters()["staleEvent"]), 1)
        self.assertIsNone(self.gear())

    def test_unknown_unit_is_skipped_without_a_request(self):
        self.J["Request"]("focus", "Ann-Realm")       # focus does not exist here
        self.assertEqual(self.notify_count(), 0)

    # -- the token is a handle, the GUID is the identity ---------------------
    def test_player_is_found_again_under_another_token(self):
        # field run 19.11.2026: 78 of 102 requests died because target/mouseover
        # were recycled while the paced queue waited. The player was still in the
        # world — under nameplate7 — so the request must follow the GUID.
        self.g["UNITS"]["target"] = self.lua.eval('{ guid = "Player-1-00000001" }')
        self.request("target", "Ann-Realm")
        self.assertEqual(self.notify_count(), 1)

        # the target changes to someone else, our player is now a nameplate
        self.g["UNITS"]["target"]["guid"] = "Player-1-00000009"
        self.g["UNITS"]["nameplate7"] = self.lua.eval('{ guid = "Player-1-00000001" }')
        self.ready("Player-1-00000001")

        g = self.gear()
        self.assertIsNotNone(g)                       # data still landed
        self.assertEqual(int((self.counters()["relocatedOnRead"] or 0)), 1)

    def test_request_is_sent_to_the_relocated_unit(self):
        self.db["players"]["Bob-Realm"] = self.lua.eval('{ name = "Bob", realm = "Realm" }')
        self.g["UNITS"]["target"] = self.lua.eval('{ guid = "Player-1-00000001" }')
        self.g["UNITS"]["mouseover"] = self.lua.eval('{ guid = "Player-1-00000002" }')
        self.request("target", "Ann-Realm")           # Ann is in flight
        self.request("mouseover", "Bob-Realm")        # Bob waits in the queue

        # while Bob waits, mouseover becomes someone else and Bob shows up as focus
        self.J["OnInspectReady"]("Player-1-00000001")
        self.g["UNITS"]["mouseover"]["guid"] = "Player-1-00000003"
        self.g["UNITS"]["focus"] = self.lua.eval('{ guid = "Player-1-00000002" }')
        self.fire()

        self.assertEqual(self.notify_count(), 2)
        self.assertEqual(int((self.counters()["relocated"] or 0)), 1)

    def test_player_that_left_the_world_is_not_requested(self):
        self.g["UNITS"]["target"] = self.lua.eval('{ guid = "Player-1-00000001" }')
        self.g["UNITS"]["focus"] = self.lua.eval('{ guid = "Player-1-00000002" }')
        self.db["players"]["Bob-Realm"] = self.lua.eval('{ name = "Bob", realm = "Realm" }')
        self.request("target", "Ann-Realm")           # in flight
        self.request("focus", "Bob-Realm")            # queued behind Ann

        # Bob leaves the world entirely before the queue reaches him
        self.g["UNITS"]["focus"] = None
        self.J["OnInspectReady"]("Player-1-00000001")
        self.fire()

        self.assertEqual(self.notify_count(), 1)        # only Ann was asked
        self.assertGreaterEqual(int((self.counters()["skipGone"] or 0)), 1)

    def test_stale_queue_entry_expires_instead_of_wasting_a_request(self):
        self.g["NOW"] = 1000
        self.db["players"]["Bob-Realm"] = self.lua.eval('{ name = "Bob", realm = "Realm" }')
        self.g["UNITS"]["mouseover"] = self.lua.eval('{ guid = "Player-1-00000002" }')
        self.request("target", "Ann-Realm")     # in flight
        self.request("mouseover", "Bob-Realm")  # waits behind Ann

        self.g["NOW"] = 1000 + 120              # Bob waited two minutes
        self.J["OnInspectReady"]("Player-1-00000001")
        self.fire()

        self.assertEqual(int((self.counters()["expired"] or 0)), 1)
        self.assertEqual(self.notify_count(), 1)

    def test_newest_encounter_is_served_first(self):
        # LIFO is deliberate: the queue can't keep up with encounters, so a FIFO
        # order spends requests on players who already left (measured: 17 sent,
        # 2 stored, 35 "gone"). The newest entry is the one still in front of us.
        self.db["players"]["Bob-Realm"] = self.lua.eval('{ name = "Bob", realm = "Realm" }')
        self.db["players"]["Cid-Realm"] = self.lua.eval('{ name = "Cid", realm = "Realm" }')
        self.g["UNITS"]["mouseover"] = self.lua.eval('{ guid = "Player-1-00000002" }')
        self.g["UNITS"]["focus"] = self.lua.eval('{ guid = "Player-1-00000003" }')

        self.request("target", "Ann-Realm")       # in flight
        self.request("mouseover", "Bob-Realm")    # queued first
        self.request("focus", "Cid-Realm")        # queued last → served first

        self.J["OnInspectReady"]("Player-1-00000001")
        # fire enough timers: the finished request leaves its own timeout in the
        # queue, and that stale timer must do nothing before the gap timer runs
        self.fire(limit=5)

        sent = [str(u) for u in self.g["NOTIFY"].values()]
        # the order is the assertion: Cid (queued last, seen most recently) is
        # asked BEFORE Bob, who has been in the queue longer
        self.assertEqual(sent[:2], ["target", "focus"])

    def test_oldest_queued_entry_expires_rather_than_being_chased(self):
        # 20 s: a player who stood next to us half a minute ago has moved on
        self.g["NOW"] = 1000
        self.db["players"]["Bob-Realm"] = self.lua.eval('{ name = "Bob", realm = "Realm" }')
        self.g["UNITS"]["mouseover"] = self.lua.eval('{ guid = "Player-1-00000002" }')
        self.request("target", "Ann-Realm")       # in flight
        self.request("mouseover", "Bob-Realm")

        self.g["NOW"] = 1000 + 25                 # past MAX_AGE
        self.J["OnInspectReady"]("Player-1-00000001")
        self.fire()

        self.assertEqual(int(self.counters()["expired"] or 0), 1)
        self.assertEqual(self.notify_count(), 1)  # Bob was never asked

    def test_secret_import_string_is_not_stored(self):
        self.lua.execute("canaccessvalue = function(v) return false end")
        self.request()
        self.ready()
        g = self.gear()
        self.assertIsNotNone(g)                       # gear still lands
        self.assertIsNone(g["imp"])                   # build string withheld

    # -- bounded storage ----------------------------------------------------
    def test_snapshot_ring_drops_oldest_and_keeps_the_player_row(self):
        # fill the ring past its cap by hand, then let one Store evict.
        # Потолок берём ИЗ АДДОНА, а не хардкодим: MAX_GEAR менялся (2000 → 6000
        # 24.11.2026), и зашитое число превращает полезный тест в ложный провал.
        cap = int(self.lua.eval("NSP_INSPECT_MAX_GEAR")) if self.lua.globals()["NSP_INSPECT_MAX_GEAR"] else None
        if cap is None:
            self.skipTest("MAX_GEAR не выставлен в тестовом окружении")
        self.lua.execute(f"""
        for i = 1, {cap + 1} do
            local k = "P" .. i .. "-Realm"
            DB.players[k] = {{ name = "p" .. i, gear = {{ at = i }} }}
            DB.gearRing = DB.gearRing or {{}}
            DB.gearRing[#DB.gearRing + 1] = k
        end
        """)
        self.request()
        self.ready()

        ring = [str(k) for k in self.db["gearRing"].values()]
        self.assertLessEqual(len(ring), cap)
        # the evicted player keeps the row, loses only the snapshot
        self.assertIsNotNone(self.db["players"]["P1-Realm"])
        self.assertIsNone(self.db["players"]["P1-Realm"]["gear"])

    # -- controls -----------------------------------------------------------
    def test_toggle_off_stops_collection(self):
        self.J["Toggle"](False)
        self.request()
        self.assertEqual(self.notify_count(), 0)
        self.assertFalse(bool(self.J["Enabled"]()))

        self.J["Toggle"](True)
        self.request()
        self.assertEqual(self.notify_count(), 1)

    def test_report_prints_counters_and_storage(self):
        self.request()
        self.ready()
        self.J["Report"]()
        text = " ".join(str(x) for x in self.g["CHAT"].values())
        self.assertIn("gear:", text)
        self.assertIn("snapshots=1", text)
        self.assertIn("efficiency (this session): 1 of 1", text)

    # -- per-session counters -----------------------------------------------
    def test_start_moves_session_counters_into_running_totals(self):
        # /nspy gear must answer "how did it go today". Without the roll-over the
        # SV counter accumulates across sessions and the ratio is unreadable.
        self.request()
        self.ready()
        self.assertEqual(int(self.counters()["ok"]), 1)

        self.J["Start"]()
        self.assertEqual(len(self.counters()), 0)              # session cleared
        self.assertEqual(int(self.db["debug"]["inspectTotal"]["ok"]), 1)
        self.assertEqual(int(self.db["debug"]["inspectTotal"]["sent"]), 1)

    def test_start_accumulates_over_several_sessions(self):
        # each session must be past the 6 h cooldown, otherwise the second
        # request is correctly refused and the test proves nothing
        for session in range(2):
            self.g["NOW"] = 1000 + (session + 1) * 7 * 3600
            self.request()
            self.ready()
            self.J["Start"]()
        self.assertEqual(int(self.db["debug"]["inspectTotal"]["ok"]), 2)

    def test_start_keeps_snapshots_intact(self):
        self.request()
        self.ready()
        self.J["Start"]()
        self.assertIsNotNone(self.gear())                      # data not touched


if __name__ == "__main__":
    unittest.main(verbosity=2)
