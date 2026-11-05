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
            "local function P(_) end\n"
            "local function DbgErr(_, _) end\n"
            "local DB = {players = {}, debug = {}, peerEnabled = true, game = 'forever'}\n"
            "local function GetDB() return DB end\n"
            "local PEER_CHANNEL = 'nearbyspydata'\n"
            "GetChannelName = function(_) return 1 end\n"
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
        )

    def receive(self, message):
        self.lua.globals()["TestReceive"](message, "Other-Home")

    def test_valid_duplicate_and_rejected_packets_are_distinguishable(self):
        payload = "N2;forever;Home;Alice;MAGE;20;Human;Alliance"
        self.receive(payload)
        self.receive(payload)
        self.receive("N2;forever;Elsewhere;Bob;MAGE;20;Human;Alliance")
        stats = self.lua.globals()["TestStats"]
        self.assertEqual(3, stats["seen"])
        self.assertEqual(2, stats["valid"])
        self.assertEqual(1, stats["received"])
        self.assertEqual(1, stats["rejected"])

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


if __name__ == "__main__":
    unittest.main()
