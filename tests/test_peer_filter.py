"""Peer filter in the player window (Lua 5.1, real TacticalVisible)."""

from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

SOURCE = Path(__file__).resolve().parents[1] / "NearbySpy.lua"


class PeerFilterTests(unittest.TestCase):
    def setUp(self):
        source = SOURCE.read_text(encoding="utf-8")
        start = source.index("local tactical = {rows = {")
        end = source.index("-- Relative time for the contact column")
        block = source[start:end]
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(
            "time = function() return 1000 end\n"
            "ALL_REALMS = true\n"
            "function GetDB() return { peerAllRealms = ALL_REALMS } end\n"
            + block + "\n"
            "TestVisible = TacticalVisible\n"
            "TestStat = tactical\n"
        )

    def visible(self, filt, player):
        stats = self.lua.globals()["TestStat"]
        stats["filter"] = filt
        return self.lua.globals()["TestVisible"](self.lua.table_from(player), 1000)

    def test_peer_filter_selects_rows_that_came_from_the_channel(self):
        self.assertTrue(self.visible("peer", {"peerAt": 900}))
        self.assertFalse(self.visible("peer", {"lastSeen": 999}))

    def test_peer_filter_ignores_rows_without_a_peer_timestamp(self):
        # a row from our own sighting has no peerAt: it must not leak into the
        # peer list just because it is fresh
        self.assertFalse(self.visible("peer", {"lastSeen": 1000, "firstSeen": 1000}))

    def test_foreign_rows_are_hidden_while_the_setting_is_off(self):
        # accepted earlier while the flag was on: turning it off must hide them
        # from every filter, not only from the peer one
        self.lua.execute("ALL_REALMS = false")
        self.assertFalse(self.visible("all", {"peerAt": 900, "peerForeign": True}))
        self.assertFalse(self.visible("peer", {"peerAt": 900, "peerForeign": True}))
        # own-realm peer rows and ordinary sightings stay visible
        self.assertTrue(self.visible("all", {"peerAt": 900, "lastSeen": 999}))
        self.assertTrue(self.visible("all", {"lastSeen": 999}))
        self.lua.execute("ALL_REALMS = true")
        self.assertTrue(self.visible("all", {"peerAt": 900, "peerForeign": True}))

    def test_new_filter_shows_only_our_own_finds(self):
        # A peer record gets firstSeen when the packet arrives, so it used to fill
        # "New" with players somebody else met. "New" = what I discovered.
        self.assertFalse(self.visible("new", {"firstSeen": 1000, "source": "peer"}),
                         "a row from the channel is not my find")
        self.assertTrue(self.visible("new", {"firstSeen": 1000, "source": "unit"}))
        self.assertTrue(self.visible("new", {"firstSeen": 1000, "source": "who"}))
        self.assertFalse(self.visible("new", {"firstSeen": 500, "source": "unit"}),
                         "found before this session started")

    def test_peer_new_shows_only_records_the_channel_taught_us(self):
        # the 5th tab: channel rows that were NEW to us IN THIS SESSION. A packet
        # that only refreshed a known player sets peerAt alone, so it must not
        # appear here. Session start in this harness is time() = 1000.
        self.assertTrue(self.visible("peern", {"peerAt": 1000, "peerNew": True}))
        self.assertFalse(self.visible("peern", {"peerAt": 1000}),
                         "a refresh of a known player is not a new find")
        self.assertFalse(self.visible("peern", {"lastSeen": 1000}),
                         "a row from our own sighting never had a packet")
        self.assertFalse(self.visible("peern", {"peerAt": 900, "peerNew": True}),
                         "arrived in a previous session — the tab is about this one")

    def test_peer_tab_still_shows_updates_too(self):
        # the two tabs must differ, otherwise the 5th adds nothing
        self.assertTrue(self.visible("peer", {"peerAt": 900, "peerNew": True}))
        self.assertTrue(self.visible("peer", {"peerAt": 900}))

    def test_other_filters_are_untouched_by_the_peer_branch(self):
        self.assertTrue(self.visible("all", {"lastSeen": 1000}))
        self.assertTrue(self.visible("fresh", {"lastSeen": 900}))
        self.assertFalse(self.visible("fresh", {"lastSeen": 100}))


if __name__ == "__main__":
    unittest.main()
