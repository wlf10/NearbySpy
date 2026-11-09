"""Peer protocol N3: place in the packet (Lua 5.1, real QueuePeerNew/Receive).

N2 carried identity only (8 fields). N3 adds zone id, zone name and map
coordinates. What this holds:
  - the packet has 12 fields and carries a real zone and position;
  - a Cyrillic zone name is measured in BYTES (the client caps chat at 255), and
    an oversized packet degrades in a fixed order instead of vanishing;
  - receiving accepts both N2 and N3, rejects bad zone id / out-of-range coords;
  - a peer's place fills a gap but never overwrites our own observation.
"""

from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

SOURCE = Path(__file__).resolve().parents[1] / "NearbySpy.lua"

PRELUDE = r"""
local REAP_SECONDS, newThisSession = 600, 0
time = function() return 1000 end
local function Round4(v) if v == nil then return nil end return math.floor(v * 10000 + 0.5) / 10000 end
local function PlayerRealm() return "CAMWOW EU5 Realm 1 PvE" end
-- the receive path ignores packets we sent ourselves; make the local player
-- clearly someone else so real peer packets are not mistaken for self-echoes
UnitName = function() return "Localhero", nil end
local function P() end
LOG = {}
local function D(msg) LOG[#LOG + 1] = tostring(msg) end
local function DbgErr() end
DB = {players = {}, debug = {}, peerEnabled = true, peerAllRealms = true, game = "forever"}
function GetDB() return DB end
PEER_CHANNEL = "nearbyspydata"
GetChannelName = function() return 1, "1. nearbyspydata" end
JoinChannelByName = function() end
ChatFrame_RemoveChannel = function() end
DEFAULT_CHAT_FRAME = { AddMessage = function() end }
QUEUED = {}
SendChatMessage = function(payload) QUEUED[#QUEUED + 1] = payload end
"""


def block() -> str:
    src = SOURCE.read_text(encoding="utf-8")
    return src[src.index("-- shared record/upsert"):src.index("-- Race -> faction")]


class PeerPlaceTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(PRELUDE + "\n" + block() + "\n"
                         "TestQueue = QueuePeerNew\n"
                         # NB: `DrainPeerQueue = DrainPeerQueue` is a NO-OP: with a
                         # local of that name in scope the left side resolves to the
                         # local too (Lua 5.1), so the global stays nil. Export under
                         # a different name.
                         "TestDrain = DrainPeerQueue\n"
                         "TestReceive = ReceivePeerMessage\n"
                         "TestStats = peerStats\n"
                         "TestDB = DB\n")

    def queue(self, **fields):
        data = {"key": "Alice-Home", "name": "Alice", "realm": "CAMWOW EU5 Realm 1 PvE",
                "class": "MAGE", "level": 20, "race": "Human", "faction": "Alliance",
                "source": "unit"}
        data.update(fields)
        self.lua.globals()["TestQueue"](self.lua.globals()["TestDB"], self.lua.table_from(data))

    def test_packet_carries_zone_and_position(self):
        self.queue(zone="Таверна \"Гордость льва\"", zoneId=1429, x=0.52314, y=0.71129)
        self.lua.execute("time = function() return 1100 end")
        self.lua.globals()["TestDrain"]()
        sent = [str(p) for p in self.lua.globals()["QUEUED"].values()]
        self.assertEqual(1, len(sent))
        parts = sent[0].split(";")
        self.assertEqual(12, len(parts))
        self.assertEqual("N3", parts[0])
        self.assertEqual("1429", parts[8])
        self.assertEqual("Таверна \"Гордость льва\"", parts[9])
        self.assertEqual("0.5231", parts[10])
        self.assertEqual("0.7113", parts[11])

    def test_missing_place_is_marked_not_invented(self):
        parts = self.sent_parts(**{})
        self.assertEqual("0", parts[8])
        self.assertEqual("?", parts[9])
        self.assertEqual("-", parts[10])
        self.assertEqual("-", parts[11])

    def sent_parts(self, **fields):
        self.queue(**fields)
        self.lua.execute("time = function() return 1100 end")
        self.lua.globals()["TestDrain"]()
        sent = [str(p) for p in self.lua.globals()["QUEUED"].values()]
        return sent[0].split(";")

    def test_packet_never_exceeds_the_chat_byte_limit(self):
        # long Cyrillic zone name: 60 chars = 120 bytes, plus a long name/realm
        zone = "З" * 60
        parts = self.sent_parts(zone=zone, zoneId=1429, x=0.5, y=0.5)
        joined = ";".join(parts)
        self.assertLessEqual(len(joined.encode("utf-8")), 240)
        # the id survives: it is what the site needs to place the record
        self.assertEqual("1429", parts[8])

    def test_receive_accepts_n2_without_place(self):
        self.recv("N2;forever;CAMWOW EU5 Realm 1 PvE;Alice;MAGE;20;Human;Alliance")
        row = self.lua.globals()["TestDB"]["players"]["Alice-CAMWOW EU5 Realm 1 PvE"]
        self.assertTrue(row is not None)
        self.assertIsNone(row["zone"])
        self.assertIsNone(row["zoneId"])

    def test_receive_stores_place_from_n3(self):
        self.recv("N3;forever;CAMWOW EU5 Realm 1 PvE;Alice;MAGE;20;Human;Alliance;1429;Elwynn;0.5231;0.7113")
        row = self.lua.globals()["TestDB"]["players"]["Alice-CAMWOW EU5 Realm 1 PvE"]
        self.assertEqual("Elwynn", row["zone"])
        self.assertEqual(1429, row["zoneId"])
        self.assertAlmostEqual(0.5231, row["x"], places=4)
        self.assertAlmostEqual(0.7113, row["y"], places=4)

    def recv(self, message):
        self.lua.globals()["TestReceive"](message, "Sender-Realm")

    def test_receive_rejects_out_of_range_coordinates(self):
        self.recv("N3;forever;CAMWOW EU5 Realm 1 PvE;Alice;MAGE;20;Human;Alliance;1429;Elwynn;1.5;0.2")
        stats = self.lua.globals()["TestStats"]
        self.assertEqual(1, stats["rejected"])
        self.assertIsNone(self.lua.globals()["TestDB"]["players"]["Alice-CAMWOW EU5 Realm 1 PvE"])

    def test_receive_rejects_bad_zone_id(self):
        self.recv("N3;forever;CAMWOW EU5 Realm 1 PvE;Alice;MAGE;20;Human;Alliance;abc;Elwynn;0.5;0.5")
        self.assertEqual(1, self.lua.globals()["TestStats"]["rejected"])

    def test_peer_place_does_not_overwrite_our_own_sighting(self):
        db = self.lua.globals()["TestDB"]
        db["players"]["Alice-CAMWOW EU5 Realm 1 PvE"] = self.lua.table_from({
            "name": "Alice", "realm": "CAMWOW EU5 Realm 1 PvE", "class": "MAGE", "level": 20,
            "zone": "Stormwind", "zoneId": 1519, "x": 0.4, "y": 0.6,
            "lastSeen": 900, "firstSeen": 800, "count": 2, "source": "unit",
        })
        self.recv("N3;forever;CAMWOW EU5 Realm 1 PvE;Alice;MAGE;20;Human;Alliance;1429;Elwynn;0.9;0.1")
        row = db["players"]["Alice-CAMWOW EU5 Realm 1 PvE"]
        self.assertEqual("Stormwind", row["zone"])
        self.assertEqual(1519, row["zoneId"])
        self.assertAlmostEqual(0.4, row["x"], places=4)

    def test_peer_place_fills_an_empty_field(self):
        db = self.lua.globals()["TestDB"]
        db["players"]["Alice-CAMWOW EU5 Realm 1 PvE"] = self.lua.table_from({
            "name": "Alice", "realm": "CAMWOW EU5 Realm 1 PvE", "class": "MAGE", "level": 20,
            "lastSeen": 900, "firstSeen": 800, "count": 1, "source": "chat",
        })
        self.recv("N3;forever;CAMWOW EU5 Realm 1 PvE;Alice;MAGE;20;Human;Alliance;1429;Elwynn;0.9;0.1")
        row = db["players"]["Alice-CAMWOW EU5 Realm 1 PvE"]
        self.assertEqual("Elwynn", row["zone"])
        self.assertEqual(1429, row["zoneId"])


if __name__ == "__main__":
    unittest.main()
