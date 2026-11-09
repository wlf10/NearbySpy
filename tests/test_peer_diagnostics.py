"""Peer transport diagnostics in the real Lua 5.1 peer functions."""

from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

SOURCE = Path(__file__).resolve().parents[1] / "NearbySpy.lua"


class PeerDiagnosticsTests(unittest.TestCase):
    def setUp(self):
        source = SOURCE.read_text(encoding="utf-8")
        peer = source[source.index("-- shared record/upsert") : source.index("-- Race -> faction")]
        filtering = source[source.index("local function IsPeerChannel") : source.index("if WorldFrame and WorldFrame.HookScript")]
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(
            "local REAP_SECONDS, newThisSession = 600, 0\n"
            "time = function() return 1000 end\n"
            "local function Round4(x) return x end\n"
            "local function PlayerRealm() return 'Home' end\n"
            "LOCALIZED_CLASS_NAMES_MALE = {MAGE='Маг', DRUID='Друид'}\n"
            "function ClassLocFromFile(f) return (LOCALIZED_CLASS_NAMES_MALE or {})[f] end\n"
            "ME, SURNAME = 'Me', nil\n"
            "UnitName = function(unit) return ME, SURNAME end\n"
            "local function P(_) end\n"
            "local DLOG = {}\n"
            "local function D(msg) DLOG[#DLOG + 1] = tostring(msg) end\n"
            "local function DbgErr(_, _) end\n"
            "local DB = {players = {}, debug = {}, peerEnabled = true, game = 'forever', peerAllRealms = true}\n"
            "local function GetDB() return DB end\n"
            "local PEER_CHANNEL = 'nearbyspydata'\n"
            "GetChannelName = function(_) return 1, '1. nearbyspydata' end\n"
            "JoinChannelByName = function(_) end\n"
            "REMOVES, MESSAGES = {}, {}\n"
            "ChatFrame_RemoveChannel = function(_, name) REMOVES[#REMOVES + 1] = name end\n"
            "ChatFrame_AddChannel = nil\n"
            "DEFAULT_CHAT_FRAME = { AddMessage = function(_, message) MESSAGES[#MESSAGES + 1] = message end }\n"
            "ChatFrame1 = DEFAULT_CHAT_FRAME\n"
            "local function AddFilter(_, callback) _G.TestFilter = callback end\n"
            "ChatFrame_AddMessageEventFilter = AddFilter\n"
            + peer + "\n"
            + filtering + "\n"
            "TestReceive = ReceivePeerMessage\n"
            "TestDB = DB\n"
            "TestStats = peerStats\n"
            "TestShow = SetPeerChatVisible\n"
            "TestDLog = DLOG\n"
        )

    def receive(self, message):
        self.lua.globals()["TestReceive"](message, "Other-Home")

    def test_valid_duplicate_and_foreign_packets_are_distinguishable(self):
        payload = "N2;forever;Home;Alice;MAGE;20;Human;Alliance"
        self.receive(payload)
        self.receive(payload)
        # a foreign realm is no longer rejected: the channel is cluster-wide
        self.receive("N2;forever;Elsewhere;Bob;MAGE;20;Human;Alliance")
        stats = self.lua.globals()["TestStats"]
        self.assertEqual(3, stats["seen"])
        self.assertEqual(3, stats["valid"])
        self.assertEqual(2, stats["received"])
        self.assertEqual(1, stats["merged"])
        self.assertEqual(0, stats["rejected"])
        self.assertEqual(1, stats["foreign"])

    def test_reports_last_sender_of_seen_peer_message(self):
        self.receive("N2;forever;Home;Alice;MAGE;20;Human;Alliance")
        self.assertEqual("Other-Home", self.lua.globals()["TestStats"]["lastSender"])

    def test_missing_channel_add_api_still_shows_received_messages_only_when_enabled(self):
        callback = self.lua.globals()["TestFilter"]
        self.assertTrue(callback(None, None, None, None, None, "1. nearbyspydata"))
        self.receive("N2;forever;Home;Alice;MAGE;20;Human;Alliance")
        self.assertEqual(0, len(self.lua.globals()["MESSAGES"]))
        self.assertTrue(self.lua.globals()["TestShow"](True))
        self.assertTrue(callback(None, None, None, None, None, "1. nearbyspydata"))
        self.receive("N2;forever;Home;Bob;MAGE;20;Human;Alliance")
        self.assertIn("Bob", self.lua.globals()["MESSAGES"][1])
        self.assertTrue(callback(None, None, None, None, None, "1. General") is False)
        self.lua.globals()["TestShow"](False)
        self.assertTrue(callback(None, None, None, None, None, "1. nearbyspydata"))
        self.receive("N2;forever;Home;Carol;MAGE;20;Human;Alliance")
        self.assertEqual(1, len(self.lua.globals()["MESSAGES"]))

    # --- debug-mode diagnostics (1.5.1) -------------------------------
    def dlog(self):
        return [str(line) for line in self.lua.globals()["TestDLog"].values()]

    def test_refreshed_record_is_counted_as_merged_not_new(self):
        payload = "N2;forever;Home;Alice;MAGE;20;Human;Alliance"
        self.receive(payload)
        self.receive(payload)
        stats = self.lua.globals()["TestStats"]
        self.assertEqual(1, stats["received"])
        self.assertEqual(1, stats["merged"])
        log = self.dlog()
        self.assertTrue(any("Peer in:" in line and line.endswith("new") for line in log))
        self.assertTrue(any("Peer in:" in line and line.endswith("merged") for line in log))

    def test_foreign_realm_record_is_kept_and_marked(self):
        self.receive("N2;forever;Elsewhere;Bob;MAGE;20;Human;Alliance")
        players = self.lua.globals()["TestDB"]["players"]
        row = players["Bob-Elsewhere"]
        self.assertTrue(row is not None, "foreign realm record must be stored")
        self.assertEqual("Elsewhere", row["realm"])
        self.assertEqual("Elsewhere", row["peerRealm"])
        self.assertTrue(row["peerForeign"])
        # our own realm must not be flagged
        self.receive("N2;forever;Home;Alice;MAGE;20;Human;Alliance")
        home = players["Alice-Home"]
        self.assertIsNone(home["peerForeign"])

    def test_counters_are_snapshotted_into_savedvariables(self):
        self.receive("N2;forever;Home;Alice;MAGE;20;Human;Alliance")
        snapshot = self.lua.globals()["TestDB"]["debug"]["peer"]
        self.assertEqual(1, snapshot["received"])
        self.assertEqual(1, snapshot["seen"])
        self.assertEqual(1, snapshot["valid"])
        self.assertEqual(1, snapshot["channel"])
        self.assertEqual(True, snapshot["enabled"])

    def test_foreign_packet_is_dropped_when_the_setting_is_off(self):
        db = self.lua.globals()["TestDB"]
        db["peerAllRealms"] = False
        self.receive("N2;forever;Elsewhere;Bob;MAGE;20;Human;Alliance")
        stats = self.lua.globals()["TestStats"]
        self.assertEqual(1, stats["rejected"])
        self.assertEqual(0, stats["received"])
        self.assertEqual(0, stats["foreign"])
        self.assertTrue(self.lua.globals()["TestDB"]["players"]["Bob-Elsewhere"] is None)
        # our own realm keeps working with the setting off
        self.receive("N2;forever;Home;Alice;MAGE;20;Human;Alliance")
        self.assertEqual(1, self.lua.globals()["TestStats"]["received"])

    def test_own_packet_echo_is_not_counted_as_a_peer_record(self):
        # The channel echoes our own message back. On the live save this showed up
        # as merged=1 with the "peer" being the player we had just reported, which
        # made the counters read as "someone else is in the channel".
        payload = "N3;forever;Home;Alice;MAGE;20;Human;Alliance;1429;Elwynn;0.5;0.5"
        self.lua.globals()["ME"] = "Me"
        self.lua.globals()["TestReceive"](payload, "Me")
        stats = self.lua.globals()["TestStats"]
        self.assertEqual(1, stats["seen"])
        self.assertEqual(1, stats["selfEcho"])
        self.assertEqual(0, stats["valid"])
        self.assertEqual(0, stats["received"])
        self.assertEqual(0, stats["merged"])
        self.assertTrue(self.lua.globals()["TestDB"]["players"]["Alice-Home"] is None)

    def test_own_packet_with_surname_is_also_ignored(self):
        self.lua.globals()["ME"] = "Alice"
        self.lua.globals()["SURNAME"] = "Smith"
        self.lua.globals()["TestReceive"](
            "N2;forever;Home;Bob;MAGE;20;Human;Alliance", "Alice Smith")
        self.assertEqual(1, self.lua.globals()["TestStats"]["selfEcho"])
        self.assertTrue(self.lua.globals()["TestDB"]["players"]["Bob-Home"] is None)

    def test_absent_setting_means_on_not_off(self):
        # SavedVariables written by an older build has no peerAllRealms key at
        # all; treating nil as "off" would silently reject every foreign packet
        # after an upgrade.
        db = self.lua.globals()["TestDB"]
        db["peerAllRealms"] = None
        self.receive("N2;forever;Elsewhere;Bob;MAGE;20;Human;Alliance")
        stats = self.lua.globals()["TestStats"]
        self.assertEqual(0, stats["rejected"])
        self.assertEqual(1, stats["received"])
        self.assertEqual(1, stats["foreign"])

    def test_snapshot_survives_getchannelname_returning_two_values(self):
        # GetChannelName(id_or_name) returns (channelNumber, channelName). Feeding
        # it straight into tonumber() puts the name into the BASE argument and
        # raises "bad argument #2 to 'tonumber'", which aborted the whole peer
        # handler inside its pcall (seen in game 09.11.2026 at 12:45:43).
        self.receive("N2;forever;Home;Alice;MAGE;20;Human;Alliance")
        snapshot = self.lua.globals()["TestDB"]["debug"]["peer"]
        self.assertEqual(1, snapshot["channel"])


if __name__ == "__main__":
    unittest.main()
