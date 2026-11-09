"""Офлайн-гильдия не должна считаться встречей (Lua 5.1).

Ростер гильдии отдаёт уровень/класс/зону ВСЕХ согильдийцев, включая офлайн.
До этой правки флаг online (9-й возврат GetGuildRosterInfo) выбрасывался, и
каждый refresh ростера обновлял lastSeen/count ста человек, которых игрок не
видел. Правка: офлайн-запись обогащает профиль (class/level/guid), но не
двигает lastSeen/count/zone и не попадает в peer-очередь.
"""

from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

from nsp_helpers import CONST_PRELUDE


SOURCE = Path(__file__).resolve().parents[1] / "NearbySpy.lua"

STUBS = """
local REAP_SECONDS, newThisSession = 600, 0
local NOW = 1000
time = function() return NOW end
function SetNow(t) NOW = t end
local function Round4(x) return x end
local function P(s) end
local function L(k) return k end
FIRST_SEEN = "%s"
LVL_PREFIX = "lvl "
local ROSTER = {}
function SetRoster(list) ROSTER = list end
IsInGuild = function() return true end
GetNumGuildMembers = function() return #ROSTER end
GetGuildRosterInfo = function(i)
    local r = ROSTER[i]
    -- name, rank, rankIdx, level, classLoc, zone, note, onote, online,
    -- status, classFile, achPts, achRank, mobile, soR, rep, guid
    return r.name, "Member", 5, r.level, r.classLoc, r.zone, "", "",
        r.online, "", r.class, 0, 0, false, 0, 0, r.guid
end
PlayerRealm = function() return "TestRealm" end
GetFaction = function() return "Alliance" end
local DB
function SetDB(d) DB = d end
GetDB = function() return DB end
"""


class GuildPresenceTests(unittest.TestCase):
    def setUp(self):
        source = SOURCE.read_text(encoding="utf-8")
        block = source[
            source.index("-- localized class name -> file key") :
            source.index("local function RequestGuildRoster")
        ]
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(
            CONST_PRELUDE + "\n" + STUBS
            + block
            + "\nTestGuild = RecordGuild\nTestUpsert = UpsertPlayer\n"
        )
        self.g = self.lua.globals()
        self.db = self.lua.table_from({
            "players": self.lua.table(),
            "debug": self.lua.table(),
            "announce": False,
            "peerEnabled": False,
        })
        self.g["SetDB"](self.db)

    def roster(self, rows):
        self.g["SetRoster"](
            self.lua.table_from([
                self.lua.table_from({
                    "name": r["name"],
                    "level": r.get("level", 30),
                    "classLoc": r.get("classLoc", "Маг"),
                    "class": r.get("class", "MAGE"),
                    "zone": r.get("zone", "Elwynn Forest"),
                    "online": r.get("online", False),
                    "guid": "Player-0000-%05d" % i,
                })
                for i, r in enumerate(rows, start=1)
            ])
        )

    def entry(self, name):
        return self.db["players"][name + "-TestRealm"]

    def test_offline_guildmate_is_not_a_meeting(self):
        self.roster([{"name": "Offline", "online": False}])
        self.g["TestGuild"]()
        p = self.entry("Offline")
        self.assertIsNotNone(p)
        self.assertEqual(0, p["count"])
        self.assertEqual(0, p["lastSeen"])
        self.assertEqual(30, p["level"])

    def test_offline_refresh_does_not_bump_known_player(self):
        # игрок реально встречен в 1000 в Западном крае
        self.lua.execute(
            "TestUpsert(GetDB(), {key='Known-TestRealm', name='Known',"
            " realm='TestRealm', level=30, ['class']='MAGE', source='unit',"
            " zone='Westfall'})"
        )
        before = self.entry("Known")
        self.assertEqual(1, before["count"])
        self.assertEqual(1000, before["lastSeen"])
        self.assertEqual("Westfall", before["zone"])

        # через 20 минут ростер отдаёт его офлайн с зоной выхода
        self.g["SetNow"](2200)
        self.roster([{"name": "Known", "online": False, "level": 31}])
        self.g["TestGuild"]()
        after = self.entry("Known")
        self.assertEqual(1, after["count"], "офлайн-ростер не добавляет встречу")
        self.assertEqual(1000, after["lastSeen"], "офлайн-ростер не освежает контакт")
        self.assertEqual(31, after["level"], "профиль при этом обогащается")
        self.assertEqual("Westfall", after["zone"],
                         "зона офлайн-игрока не подменяется зоной выхода")

    def test_online_guildmate_is_a_meeting(self):
        self.roster([{"name": "Online", "online": True}])
        self.g["TestGuild"]()
        p = self.entry("Online")
        self.assertEqual(1, p["count"])
        self.assertEqual(1000, p["lastSeen"])
        self.assertEqual("Elwynn Forest", p["zone"])

    def test_online_after_offline_starts_counting(self):
        self.roster([{"name": "Late", "online": False}])
        self.g["TestGuild"]()
        self.assertEqual(0, self.entry("Late")["count"])

        self.g["SetNow"](1100)
        self.roster([{"name": "Late", "online": True}])
        self.g["TestGuild"]()
        p = self.entry("Late")
        self.assertEqual(1, p["count"], "первая реальная встреча считается с нуля")
        self.assertEqual(1100, p["lastSeen"])

    def test_empty_roster_zone_does_not_erase_known_zone(self):
        self.roster([{"name": "Nozone", "online": True, "zone": ""}])
        self.g["TestGuild"]()
        p = self.entry("Nozone")
        self.assertIsNone(p["zone"])


if __name__ == "__main__":
    unittest.main()
