#!/usr/bin/env python3
"""Race over the peer channel: no more "bad race", no more zone-as-race.

Two defects found in the live save on 15.11.2026:

1. `Reject("bad race")` dropped a WHOLE encounter because of one secondary field.
   The ASCII gate behind it (`^[A-Za-z]+$`) also rejected genuine values: the
   localized "Night Elf" has a space, custom races come in Cyrillic. Sender side
   had the same gate, so such a record never left the client at all.

2. 384 records stored a ZONE NAME in the race field ("Duskwood", "Wetlands",
   "Ironforge", ...). Root cause: "no value" was encoded with the same code 'z'
   as "value is text in the tail", and the sender put 'z' WITHOUT the text. The
   receiver then consumed the next tail text — the zone name — as the race.

Fixes held by this file:
  - absence has its own code 'q' and never consumes a tail slot;
  - an unrecognised race no longer rejects the packet, it becomes "?";
  - known localized names normalise to the file key ("Night Elf" -> "NightElf");
  - a text that equals a known zone name is treated as a parse shift, not a race,
    and is handed back as the zone when nothing else provides one;
  - the one-off migration clears the junk already stored.

Run: python tests/test_peer_race.py
"""
from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

SOURCE = Path(__file__).resolve().parents[1] / "NearbySpy.lua"
SRC = SOURCE.read_text(encoding="utf-8")


def slice_between(start_marker: str, end_marker: str) -> str:
    """Slice, tolerating a tree that predates the marker.

    A missing marker must NOT abort the harness: then every case would "fail" on
    a string lookup and prove nothing. With an empty slice the cases go red on
    their assertions instead ('z' where 'q' is required, a nil normaliser), which
    is the behaviour under test.
    """
    if start_marker not in SRC:
        return ""
    start = SRC.index(start_marker)
    end = SRC.find(end_marker, start)
    return SRC[start:] if end < 0 else SRC[start:end]


def codec_block() -> str:
    return slice_between("NSP_PEER_CODES = {", "-- Peers now carry the place as well")


def race_block() -> str:
    return slice_between("function NspZoneNameSet(db)",
                         "-- Раньше хранилась ОДНА фракция на расу")


def race_locale_block() -> str:
    """The real RACE_LOCALE table: it sits ABOVE the sliced block in production."""
    return slice_between("local RACE_LOCALE = {", "-- LearnedFactions")


PRELUDE = """
time = function() return 1794000000 end
local function PeerEsc(s, n)
    if type(s) ~= "string" then return tostring(s) end
    if n and #s > n then return s:sub(1, n) end
    return s
end
function PeerField(s, maxLen)
    return type(s) == "string" and #s > 0 and #s <= maxLen and not s:find("[%c|;,~]")
end
local RING = {}
local function R(msg) RING[#RING + 1] = tostring(msg) end
local RACE_FACTION = { Human = "Alliance", NightElf = "Alliance", Skyborne = nil }
"""

EXPORTS = """
_G.T = {
    enc = PeerEncode, dec = PeerDecode, norm = NspNormalizeRace,
    migrate = NspMigrateRaces, zones = NspZoneNameSet,
    ring = RING, codeNone = PEER_CODE_NONE, codeUnknown = PEER_CODE_UNKNOWN,
}
"""


class RaceCodecTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(PRELUDE + codec_block() + "\n" + race_locale_block()
                         + "\n" + race_block() + "\n" + EXPORTS)
        self.t = self.lua.globals()["T"]
        # Build the db IN LUA: table_from() with nested {} leaves Python dicts
        # behind, and the production code checks type(x) == "table" everywhere.
        self.lua.execute("DB = { players = {}, debug = {}, learn = {} }")
        self.db = self.lua.globals()["DB"]

    def enc(self, kind, value):
        return self.t["enc"](kind, value)

    # --- 1. absence vs unknown value ---------------------------------------

    def test_absence_has_its_own_code(self):
        code, needs_text = self.enc("race", None)
        self.assertEqual("q", code, "absence must not reuse the 'z' text code")
        self.assertFalse(needs_text)

    def test_unknown_value_still_asks_for_its_text(self):
        code, needs_text = self.enc("race", "SomeNewRace")
        self.assertEqual("z", code)
        self.assertTrue(needs_text, "an unknown value must keep travelling as text")

    def test_known_value_is_a_code(self):
        self.assertEqual("a", self.enc("race", "Human")[0])

    def test_absence_decodes_to_nothing(self):
        self.assertIsNone(self.t["dec"]("race", "q"))
        self.assertEqual("NightElf", self.t["dec"]("race", "c", None))

    def test_absence_code_does_not_consume_tail_text(self):
        # this is the actual defect: with 'z' the next tail text (the zone) was
        # taken as the race; with 'q' the tail stays untouched
        out = self.lua.execute("""
            local NONE, UNKNOWN = ...
            local tail = { "Duskwood" }
            local idx = 0
            local function takeText(code)
                if code ~= UNKNOWN then return nil end
                idx = idx + 1
                return tail[idx]
            end
            local taken = takeText(NONE)
            return tostring(taken) .. "|" .. tostring(idx)
        """, self.t["codeNone"], self.t["codeUnknown"])
        self.assertEqual("nil|0", out)

    # --- 2. normalisation --------------------------------------------------

    def test_localized_name_becomes_the_file_key(self):
        self.assertEqual("NightElf", self.t["norm"](self.db, "Night Elf"))
        self.assertEqual("Human", self.t["norm"](self.db, "Человек"))

    def test_file_key_stays(self):
        self.assertEqual("Skyborne", self.t["norm"](self.db, "Skyborne"))

    def test_learned_localization_is_used(self):
        self.lua.execute('DB.learn.raceLoc2File = { ["Небеснорожденный"] = "Skyborne" }')
        self.assertEqual("Skyborne", self.t["norm"](self.db, "Небеснорожденный"))

    def test_zone_name_is_not_a_race(self):
        zones = self.t["zones"](self.db)
        zones["Duskwood"] = True
        value, is_zone = self.t["norm"](self.db, "Duskwood")
        self.assertEqual("?", value)
        self.assertTrue(is_zone, "the caller needs to know this was a zone, not junk")

    def test_unknown_text_is_kept_for_a_new_custom_race(self):
        # a custom race we have never seen must not be thrown away
        self.assertEqual("NewRace", self.t["norm"](self.db, "NewRace"))

    def test_strict_mode_drops_unknown_text(self):
        # used by the migration for channel rows only: locally the race always
        # comes from UnitRace as a file key, so free text there means a shift
        self.assertEqual("?", self.t["norm"](self.db, "Rotkammgebirge", True))

    def test_garbage_length_is_rejected(self):
        self.assertEqual("?", self.t["norm"](self.db, string_of(40)))

    # --- 3. migration ------------------------------------------------------

    def test_migration_clears_zone_in_race_and_counts_it(self):
        self.lua.execute("""
            DB.players = {
              ["a-EU PvE"] = { name = "A", race = "Human",  zone = "Duskwood", source = "peer" },
              ["b-EU PvP"] = { name = "B", race = "Duskwood", zone = "Duskwood", source = "peer" },
              ["c-EU PvP"] = { name = "C", race = "Rotkammgebirge", source = "peer" },
              ["d-EU PvE"] = { name = "D", race = "Night Elf", source = "peer" },
            }
        """)
        players = self.db["players"]
        self.t["migrate"](self.db)
        self.assertEqual("Human", players["a-EU PvE"]["race"], "a real race must survive")
        self.assertIsNone(players["b-EU PvP"]["race"], "a zone in the race field is junk")
        self.assertIsNone(players["c-EU PvP"]["race"], "unrecognised channel text is junk")
        self.assertEqual("NightElf", players["d-EU PvE"]["race"], "localized name is canonicalised")
        self.assertEqual(2, self.db["debug"]["raceJunkCleared"], "b and c are junk")
        self.assertEqual(1, self.db["debug"]["raceCanonicalised"])

    def test_migration_is_idempotent(self):
        self.lua.execute('DB.players = { ["a-EU PvE"] = { name = "A", race = "Duskwood", source = "peer" } }')
        players = self.db["players"]
        self.t["migrate"](self.db)
        first = self.db["debug"]["raceJunkCleared"]
        self.t["migrate"](self.db)
        self.assertEqual(first, self.db["debug"]["raceJunkCleared"],
                         "a second run must not count the same rows again")

    def test_migration_keeps_local_observations_untouched(self):
        # a local row with free text is not possible, but if it happens the value
        # is left alone: strict mode is for channel rows only
        self.lua.execute('DB.players = { ["a-EU PvE"] = { name = "A", race = "SomeRace", source = "unit" } }')
        players = self.db["players"]
        self.t["migrate"](self.db)
        self.assertEqual("SomeRace", players["a-EU PvE"]["race"])


def string_of(n: int) -> str:
    return "x" * n


if __name__ == "__main__":
    unittest.main()
