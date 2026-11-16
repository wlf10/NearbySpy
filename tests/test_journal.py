#!/usr/bin/env python3
"""NearbySpy_Journal.lua — the per-character journal must count honestly.

The journal (1.5.7) is a new SavedVariables section: playtime, zones, level,
encounters and progress per character. It has no UI of its own — it is read by
`/nspy me` and, later, by the site from the same SV file the addon uploads.
That makes the counters the only thing the player can check, so the rules below
are the contract:

  - playtime is accumulated from heartbeats, not from "login until logout": a
    client that is killed leaves the session open in SV, and the next login must
    close it at its LAST BEAT (marked truncated), never at the new login time —
    otherwise hours spent offline would be counted as playtime;
  - zone seconds always add up to the session length (no time is lost on a zone
    change, none is counted twice);
  - an encounter is a player seen WITH OUR OWN EYES: peer packets are excluded
    at the call site, and repeat sightings of the same player within one session
    count once;
  - the rings are bounded (40 sessions, 30 days, 25 zones per character,
    12 characters), so the journal can never grow the SV file without limit.

Run: python tests/test_journal.py
"""
import unittest
from pathlib import Path

from lupa.lua51 import LuaRuntime

JOURNAL_FILE = Path(__file__).resolve().parents[1] / "NearbySpy_Journal.lua"
SRC = JOURNAL_FILE.read_text(encoding="utf-8")

PRELUDE = """
NOW = 1000
time = function() return NOW end
date = os.date
-- the character the client reports; tests move these to simulate play
PC = { name = "Wolfy", tail = nil, realm = "Dreamscythe",
       level = 20, class = "PALADIN", xp = 0, xpmax = 100, money = 1000 }
UnitName = function() return PC.name, PC.tail end
GetRealmName = function() return PC.realm end
UnitLevel = function() return PC.level end
UnitClass = function() return "Paladin", PC.class end
UnitXP = function() return PC.xp end
UnitXPMax = function() return PC.xpmax end
GetMoney = function() return PC.money end
LOCALIZED_CLASS_NAMES_MALE = { PALADIN = "Paladin" }
"""


class JournalTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(PRELUDE)
        self.J = self.lua.execute(SRC)          # the file ends with `return J`
        self.g = self.lua.globals()
        self.db = self.lua.table()

    # -- helpers ------------------------------------------------------------
    def at(self, ts):
        self.g["NOW"] = ts

    def login(self, ts=1000, zone="Elwynn Forest", zone_id=1):
        self.at(ts)
        return self.J["Login"](self.db, zone, zone_id)

    def logout(self, ts):
        self.at(ts)
        return self.J["Logout"](self.db)

    def beat(self, ts, zone="Elwynn Forest", zone_id=1):
        self.at(ts)
        return self.J["Beat"](self.db, zone, zone_id)

    def zone(self, ts, name, zone_id):
        self.at(ts)
        return self.J["Zone"](self.db, name, zone_id)

    def journal(self):
        return self.db["journal"]

    def char(self):
        j = self.journal()
        key = None
        for k, v in j["c"].items():
            key = k
        return j["c"][key]

    # -- session lifecycle --------------------------------------------------
    def test_numbers_are_floaty_in_lupa_but_lua_sees_integers(self):
        # guard against a silent type change in the counters (lupa converts Lua
        # numbers to Python floats; the addon itself always writes integers)
        self.login(1000)
        self.logout(1000 + 3600)
        self.assertEqual(int(self.char()["s"]), 3600)

    def test_logout_settles_the_session(self):
        self.login(1000)
        self.logout(1000 + 3600)
        j = self.journal()
        self.assertIsNone(j["o"])
        self.assertEqual(len(list(j["s"].values())), 1)
        rec = list(j["s"].values())[0]
        self.assertEqual(int(rec["s"]), 3600)
        self.assertIsNone(rec["tr"])
        ch = self.char()
        self.assertEqual(int(ch["s"]), 3600)
        self.assertEqual(int(ch["ss"]), 1)

    def test_beat_accumulates_zone_and_day_time(self):
        self.login(1000)
        self.beat(1300)
        self.beat(1900)
        ch = self.char()
        self.assertEqual(int(ch["z"][1]["s"]), 900)
        day = self.journal()["d"][self.g["date"]("%Y-%m-%d", 1900)]
        self.assertEqual(int(day["s"]), 900)
        # session still open: nothing in the ring yet
        self.assertEqual(len(list(self.journal()["s"].values())), 0)

    def test_visits_count_entries_not_beats(self):
        # a one-hour stay must read as ONE visit, however many heartbeats ran
        self.login(1000, "Elwynn Forest", 1)
        for i in range(1, 6):
            self.beat(1000 + i * 600)
        self.logout(1000 + 3600)
        z = self.char()["z"][1]
        self.assertEqual(int(z["v"]), 1)
        self.assertEqual(int(z["s"]), 3600)
        # coming back to the same zone later is a second visit
        self.login(5000, "Elwynn Forest", 1)
        self.logout(5100)
        self.assertEqual(int(self.char()["z"][1]["v"]), 2)

    def test_zone_change_splits_time_without_loss(self):
        self.login(1000, "Elwynn Forest", 1)
        self.zone(1600, "Stormwind City", 2)
        self.logout(2000)
        ch = self.char()
        self.assertEqual(int(ch["z"][1]["s"]), 600)   # Elwynn: 1000..1600
        self.assertEqual(int(ch["z"][2]["s"]), 400)   # Stormwind: 1600..2000
        rec = list(self.journal()["s"].values())[0]
        self.assertEqual(int(rec["s"]), 1000)         # whole session
        self.assertEqual(int(rec["z"]), 2)            # two zones visited
        self.assertEqual(rec["zn"], "Elwynn Forest")  # the longest one

    def test_crashed_session_is_closed_at_its_last_beat(self):
        # login, one heartbeat, then the client is killed: SV still holds the
        # open session. Three hours later the player logs back in.
        self.login(1000)
        self.beat(1300)
        self.login(1000 + 3 * 3600)
        j = self.journal()
        rec = list(j["s"].values())[0]
        self.assertEqual(int(rec["s"]), 300)     # last beat, not 3 hours
        self.assertEqual(int(rec["tr"]), 1)      # marked truncated
        day = j["d"][self.g["date"]("%Y-%m-%d", 1300)]
        self.assertEqual(int(day["s"]), 300)     # no double counting
        # and a fresh session is open for the new login
        self.assertIsNotNone(j["o"])
        self.assertEqual(int(j["o"]["a"]), 1000 + 3 * 3600)

    def test_reload_cycles_do_not_inflate_playtime(self):
        # /reload fires PLAYER_LOGOUT then PLAYER_LOGIN 5 seconds later
        self.login(1000)
        self.logout(2000)
        self.login(2005)
        self.logout(3000)
        ch = self.char()
        self.assertEqual(int(ch["s"]), 1000 + 995)
        self.assertEqual(int(ch["ss"]), 2)
        self.assertEqual(len(list(self.journal()["s"].values())), 2)

    # -- encounters ---------------------------------------------------------
    def test_encounters_count_distinct_players_per_session(self):
        self.login(1000)
        for _ in range(3):
            self.J["Encounter"](self.db, "Ann-Dreamscythe", True)
        self.J["Encounter"](self.db, "Bob-Dreamscythe", False)
        o = self.journal()["o"]
        self.assertEqual(int(o["e"]), 2)   # three sightings of Ann are one
        self.assertEqual(int(o["n"]), 1)   # only Ann was new to the database
        day = self.journal()["d"][self.g["date"]("%Y-%m-%d", 1000)]
        self.assertEqual(int(day["e"]), 2)
        self.assertEqual(int(day["n"]), 1)

    def test_encounter_set_is_capped_but_the_counter_keeps_running(self):
        self.login(1000)
        for i in range(400):
            self.J["Encounter"](self.db, "P%d" % i, False)
        self.assertEqual(int(self.journal()["o"]["e"]), 400)
        # beyond the cap the key is not stored, so the sighting still counts
        self.J["Encounter"](self.db, "P401", False)
        self.assertEqual(int(self.journal()["o"]["e"]), 401)

    def test_encounter_without_an_open_session_is_ignored(self):
        self.J["Encounter"](self.db, "Ann-Dreamscythe", True)
        j = self.journal()
        self.assertIsNone(j["o"])
        self.assertEqual(len(list(j["c"].values())), 0)   # no character card
        self.assertEqual(len(list(j["d"].values())), 0)   # no day rollup

    # -- progress -----------------------------------------------------------
    def test_level_up_and_death_are_recorded(self):
        self.login(1000)
        self.g["PC"]["level"] = 21
        self.J["LevelUp"](self.db, 21)
        self.J["Died"](self.db)
        self.logout(2000)
        ch = self.char()
        self.assertEqual(int(ch["lv"]), 21)
        self.assertEqual(int(ch["lu"]), 1)
        self.assertEqual(int(ch["dth"]), 1)
        rec = list(self.journal()["s"].values())[0]
        self.assertEqual(int(rec["l0"]), 20)
        self.assertEqual(int(rec["l1"]), 21)
        self.assertEqual(int(rec["d"]), 1)

    def test_xp_percent_and_money_come_from_the_client(self):
        self.g["PC"]["xp"] = 47
        self.g["PC"]["money"] = 123456
        self.login(1000)
        ch = self.char()
        self.assertEqual(int(ch["xp"]), 47)
        self.assertEqual(int(ch["mo"]), 123456)
        # money earned during the session is a delta, not the total
        self.g["PC"]["money"] = 124456
        self.logout(2000)
        ch = self.char()
        self.assertEqual(int(ch["mo"]), 124456)
        rec = list(self.journal()["s"].values())[0]
        self.assertEqual(int(rec["m1"]) - int(rec["m0"]), 1000)

    # -- bounded storage ----------------------------------------------------
    def test_session_ring_keeps_the_last_forty(self):
        t = 1000
        for _ in range(45):
            self.login(t)
            self.logout(t + 60)
            t += 100
        j = self.journal()
        sessions = list(j["s"].values())
        self.assertEqual(len(sessions), 40)
        self.assertEqual(int(sessions[0]["a"]), 1000 + 5 * 100)  # oldest dropped
        self.assertEqual(int(self.char()["ss"]), 45)             # counter intact

    def test_day_ring_keeps_thirty_days(self):
        start = 1700000000
        for i in range(35):
            day = start + i * 86400
            self.login(day)
            self.logout(day + 60)
        self.assertEqual(len(list(self.journal()["d"].values())), 30)

    def test_character_zones_keep_the_busiest(self):
        self.login(1000, "Z1", 1)
        t = 1000
        for i in range(2, 31):          # 29 short hops, 10 s each
            t += 10
            self.zone(t, "Z%d" % i, i)
        t += 5000                       # then a long stay in the last zone
        self.logout(t)
        zones = self.char()["z"]
        self.assertTrue(len(list(zones.values())) <= 25)
        # the busiest zone survives the prune, the short hops are the ones lost
        self.assertIsNotNone(zones[30])
        self.assertEqual(int(zones[30]["s"]), 5000)

    # -- formatting and reporting -------------------------------------------
    def test_duration_and_money_formatting(self):
        self.assertEqual(self.J["Dur"](45), "45s")
        self.assertEqual(self.J["Dur"](600), "10m")
        self.assertEqual(self.J["Dur"](3900), "1h 05m")
        self.assertEqual(self.J["MoneyText"](123456), "12g 34s 56c")

    def test_report_lines_are_localized_through_the_injected_lookup(self):
        self.lua.execute("""
            LINES = {}
            FMT = {
                ME_TITLE = "Journal: %s (%s, %s)",
                ME_TIME = "Tracked: %s in %d sessions (first %s)",
                ME_NOW = "Session %s | today %s | week %s",
                ME_ENC = "Met %d this session, %d total, new %d",
                ME_ZONES = "Top zones: %s",
                ME_PROG = "Level %d (%d%% xp), deaths %d, money %s",
                ME_NONE = "no journal data yet",
            }
        """)
        self.J["L"] = self.lua.eval("function(k) return FMT[k] or ('K:' .. k) end")
        self.J["P"] = self.lua.eval("function(m) LINES[#LINES+1] = m end")
        self.login(1000)
        self.beat(1300)
        self.J["Encounter"](self.db, "Ann-Dreamscythe", True)
        lines = self.J["Report"](self.db)
        n = self.lua.eval("function(t) return #t end")(lines)
        texts = [lines[i] for i in range(1, n + 1)]
        self.assertIn("Wolfy", texts[0])
        self.assertIn("Paladin", texts[0])
        self.assertTrue(texts[1].startswith("Tracked: 5m"))
        self.assertIn("Met 1 this session, 1 total, new 1", texts[3])
        self.assertIn("Top zones: Elwynn Forest 5m", " ".join(texts))
        # the chat printer got every line
        self.assertEqual(len(list(self.g["LINES"].values())), len(texts))

    def test_two_word_names_keep_the_real_realm(self):
        self.g["PC"]["name"] = "Randaz"
        self.g["PC"]["tail"] = "Windlance"
        self.login(1000)
        j = self.journal()
        keys = list(j["c"].keys())
        self.assertEqual(keys, ["Randaz Windlance-Dreamscythe"])
        self.assertEqual(j["c"][keys[0]]["n"], "Randaz Windlance")
        self.assertEqual(j["c"][keys[0]]["r"], "Dreamscythe")

    def test_empty_journal_reports_no_data(self):
        self.J["L"] = self.lua.eval("function(k) return 'K:' .. k end")
        lines = self.J["Lines"](self.db)
        self.assertEqual(lines[1], "K:ME_NONE")


if __name__ == "__main__":
    unittest.main(verbosity=2)
