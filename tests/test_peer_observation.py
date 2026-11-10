"""Peer packets are observations, not our meetings (Lua 5.1, real Upsert/Receive).

The channel tells us about players somebody else met. Before 1.5.3 a packet
called UpsertPlayer WITHOUT observe=false, so the receiver stamped the record
with local time: lastSeen = receive time and count +1. The row then claimed
"seen right now" — and via the export a sighting we never had.

What this holds:
  - a NEW row from a packet keeps lastSeen = 0 and count = 0 (the site accepts
    such rows by peerAt, never as a local sighting);
  - a row WE saw keeps its own lastSeen/count: a packet cannot move them;
  - the packet still carries what only it knows: peerAt, sender, place, profile;
  - a packet never overwrites our own zone/position (unchanged behaviour).
"""

from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

from nsp_helpers import CONST_PRELUDE

SOURCE = Path(__file__).resolve().parents[1] / "NearbySpy.lua"

PRELUDE = r"""
local REAP_SECONDS, newThisSession = 600, 0
time = function() return 1000 end
local function Round4(v) if v == nil then return nil end return math.floor(v * 10000 + 0.5) / 10000 end
local function PlayerRealm() return "CAMWOW EU5 Realm 1 PvE" end
LOCALIZED_CLASS_NAMES_MALE = {MAGE="Маг", DRUID="Друид", WARRIOR="Воин", HUNTER="Охотник", PRIEST="Жрец", WARLOCK="Чернокнижник", PALADIN="Паладин", SHAMAN="Шаман", ROGUE="Разбойник"}
function ClassLocFromFile(f) return (LOCALIZED_CLASS_NAMES_MALE or {})[f] end
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

KEY = "Alice-CAMWOW EU5 Realm 1 PvE"


def block() -> str:
    src = SOURCE.read_text(encoding="utf-8")
    return src[src.index("-- shared record/upsert"):src.index("-- Race -> faction")]


class PeerObservationTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(CONST_PRELUDE + "\n" + PRELUDE + "\n"
                         "function ZoneNameById(id) return nil end\n"
                         + block() + "\n"
                         "TestReceive = ReceivePeerMessage\n"
                         "TestUpsert = UpsertPlayer\n"
                         "TestDB = DB\n")

    def recv(self, message, sender="Sender-Realm"):
        self.lua.globals()["TestReceive"](message, sender)

    def row(self, key=KEY):
        return self.lua.globals()["TestDB"]["players"][key]

    def packet(self, name="Alice", realm="CAMWOW EU5 Realm 1 PvE"):
        return ("N3;forever;%s;%s;MAGE;20;Human;Alliance;1429;Elwynn;0.5231;0.7113"
                % (realm, name))

    def test_new_peer_row_claims_no_local_meeting(self):
        self.recv(self.packet())
        row = self.row()
        self.assertIsNotNone(row)
        self.assertEqual("peer", row["source"])
        # the whole point: no local sighting was invented
        self.assertEqual(0, row["lastSeen"])
        self.assertEqual(0, row["firstSeen"])
        self.assertEqual(0, row["count"])
        # ...while the packet's own facts are kept
        self.assertEqual(1000, row["peerAt"])
        self.assertEqual(1, row["peerNew"])
        self.assertEqual("Sender-Realm", row["peerFrom"])
        self.assertEqual("Elwynn", row["zone"])
        self.assertEqual(1429, row["zoneId"])
        self.assertEqual("MAGE", row["class"])
        self.assertEqual(20, row["level"])

    def test_packet_does_not_move_our_own_sighting(self):
        db = self.lua.globals()["TestDB"]
        db["players"][KEY] = self.lua.table_from({
            "name": "Alice", "realm": "CAMWOW EU5 Realm 1 PvE", "class": "MAGE",
            "level": 20, "zone": "Stormwind", "zoneId": 1519, "x": 0.4, "y": 0.6,
            "lastSeen": 900, "firstSeen": 800, "count": 2, "source": "unit",
        })
        self.lua.execute("time = function() return 1000 end")
        self.recv(self.packet())
        row = self.row()
        self.assertEqual(900, row["lastSeen"], "пакет сдвинул нашу встречу")
        self.assertEqual(800, row["firstSeen"])
        self.assertEqual(2, row["count"], "пакет накрутил счётчик встреч")
        self.assertEqual("unit", row["source"], "пакет понизил наш источник")
        self.assertEqual("Stormwind", row["zone"], "пакет затёр нашу зону")
        self.assertEqual(1519, row["zoneId"])
        # provenиенс и время пакета всё равно записаны
        self.assertEqual(1000, row["peerAt"])
        self.assertEqual("Sender-Realm", row["peerFrom"])

    def test_our_own_sighting_replaces_peer_source(self):
        # The row was created from a packet (source="peer"), and later we met
        # the player ourselves. The source must then say "who/unit", not stay
        # "peer" forever — otherwise the site treats our own meeting as a
        # foreign observation (and the row is judged by peerAt).
        db = self.lua.globals()["TestDB"]
        db["players"][KEY] = self.lua.table_from({
            "name": "Alice", "realm": "CAMWOW EU5 Realm 1 PvE", "class": "MAGE",
            "level": 20, "zone": "Stormwind", "source": "peer",
            "count": 0, "lastSeen": 0, "firstSeen": 0, "peerAt": 500,
        })
        # our own sighting goes through UpsertPlayer with observe = true
        self.lua.globals()["TestUpsert"](
            self.lua.globals()["TestDB"],
            self.lua.table_from({
                "key": KEY, "name": "Alice", "realm": "CAMWOW EU5 Realm 1 PvE",
                "class": "MAGE", "level": 21, "faction": "Horde", "race": "Human",
                "zone": "Durotar", "zoneId": 14, "source": "who",
            }))
        row = self.row()
        self.assertEqual("who", row["source"], "наша встреча не вытеснила source=peer")
        self.assertEqual(1000, row["lastSeen"])
        self.assertEqual(1, row["count"])
        self.assertEqual("Durotar", row["zone"])

    def test_packet_on_stale_row_still_records_arrival(self):
        db = self.lua.globals()["TestDB"]
        db["players"][KEY] = self.lua.table_from({
            "name": "Alice", "realm": "CAMWOW EU5 Realm 1 PvE", "class": "MAGE",
            "level": 20, "lastSeen": 100, "firstSeen": 50, "count": 5,
            "source": "who", "zone": "Elwynn",
        })
        self.recv(self.packet())
        row = self.row()
        self.assertEqual(100, row["lastSeen"])
        self.assertEqual(5, row["count"])
        self.assertEqual("who", row["source"])
        self.assertEqual(1000, row["peerAt"])

    def test_packet_fills_place_of_row_we_never_saw(self):
        db = self.lua.globals()["TestDB"]
        db["players"][KEY] = self.lua.table_from({
            "name": "Alice", "realm": "CAMWOW EU5 Realm 1 PvE", "class": "MAGE",
            "level": 20, "source": "chat", "count": 1, "lastSeen": 500,
        })
        self.recv(self.packet())
        row = self.row()
        self.assertEqual("Elwynn", row["zone"])
        self.assertEqual(1429, row["zoneId"])
        # место заполнено, но встреча не переписана
        self.assertEqual(500, row["lastSeen"])

    def test_n2_packet_without_place_keeps_profile_only(self):
        self.recv("N2;forever;CAMWOW EU5 Realm 1 PvE;Bob;HUNTER;12;Orc;Horde")
        row = self.row("Bob-CAMWOW EU5 Realm 1 PvE")
        self.assertIsNotNone(row)
        self.assertEqual(0, row["count"])
        self.assertEqual(0, row["lastSeen"])
        self.assertEqual(1000, row["peerAt"])
        self.assertIsNone(row["zone"])


if __name__ == "__main__":
    unittest.main()
