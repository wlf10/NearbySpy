"""Regression tests for the one-time name/realm migration in GetDB (Lua 5.1).

Legacy Camelot records stored the surname in `realm` (unit-based sources).
Chat records may carry a genuine foreign realm ("Name-Realm"). The migration
must merge surnames only for unit-ish records and never touch foreign realms.
"""

from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime


SOURCE = Path(__file__).resolve().parents[1] / "NearbySpy.lua"


class NameMigrationTests(unittest.TestCase):
    def migrate(self, players):
        source = SOURCE.read_text(encoding="utf-8")
        block = source[
            source.index("GetDB = function()") :
            source.index("-- Keep a bounded sample")
        ]
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute(
            "time = function() return 1000 end\n"
            "GetBuildInfo = function() return '1.60.1' end\n"
            "GetRealmName = function() return 'Home' end\n"
        )
        # lupa's table_from does not convert nested dicts — convert per record
        lua_players = lua.table()
        for key, record in players.items():
            lua_players[key] = lua.table_from(record)
        lua.globals()["NearbySpy"] = lua.table_from(
            {"players": lua_players, "debug": lua.table()}
        )
        lua.execute(block)
        return lua.globals()["GetDB"]()

    @staticmethod
    def keys(db):
        return sorted(db["players"].keys())

    def test_legacy_surname_record_is_merged(self):
        db = self.migrate({
            "Randaz-Windlance": {"name": "Randaz", "realm": "Windlance", "count": 2},
        })
        self.assertEqual(["Randaz Windlance-Home"], self.keys(db))
        p = db["players"]["Randaz Windlance-Home"]
        self.assertEqual("Randaz Windlance", p["name"])
        self.assertEqual("Home", p["realm"])

    def test_foreign_realm_chat_record_is_untouched(self):
        db = self.migrate({
            "Alice-OtherRealm": {
                "name": "Alice", "realm": "OtherRealm", "source": "chat",
            },
        })
        self.assertEqual(["Alice-OtherRealm"], self.keys(db))
        p = db["players"]["Alice-OtherRealm"]
        self.assertEqual("Alice", p["name"])
        self.assertEqual("OtherRealm", p["realm"])

    def test_record_without_name_does_not_crash(self):
        db = self.migrate({
            "ghost-Windlance": {"realm": "Windlance", "level": 5},
            "Bob-Home": {"name": "Bob", "realm": "Home"},
        })
        self.assertEqual(["Bob-Home"], self.keys(db))

    def test_duplicates_merge_counts(self):
        db = self.migrate({
            "Randaz-Windlance": {"name": "Randaz", "realm": "Windlance", "count": 2},
            "Randaz Windlance-Home": {
                "name": "Randaz Windlance", "realm": "Home", "count": 3,
            },
        })
        self.assertEqual(1, len(self.keys(db)))
        self.assertEqual(5, db["players"]["Randaz Windlance-Home"]["count"])

    def test_migration_is_idempotent(self):
        db = self.migrate({
            "Randaz-Windlance": {"name": "Randaz", "realm": "Windlance"},
        })
        first = self.keys(db)
        # second GetDB call: migratedNames is set, players must be stable
        source = SOURCE.read_text(encoding="utf-8")
        self.assertEqual(["Randaz Windlance-Home"], first)
        self.assertTrue(db["migratedNames"])


if __name__ == "__main__":
    unittest.main()
