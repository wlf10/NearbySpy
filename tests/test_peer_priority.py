"""Regression tests for peer updates against locally observed player data (Lua 5.1)."""

from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime


SOURCE = Path(__file__).resolve().parents[1] / "NearbySpy.lua"


class PeerPriorityTests(unittest.TestCase):
    def setUp(self):
        source = SOURCE.read_text(encoding="utf-8")
        block = source[
            source.index("-- shared record/upsert") :
            source.index("-- Opt-in, realm-local peer exchange.")
        ]
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(
            "local REAP_SECONDS, newThisSession = 600, 0\n"
            "time = function() return 1000 end\n"
            "local function Round4(x) return x end\n"
            + block + "\nTestUpsert = UpsertPlayer\n"
        )
        self.db = self.lua.table_from({
            "players": self.lua.table(),
            "debug": self.lua.table(),
            "announce": False,
        })

    def upsert(self, source, **fields):
        data = {"key": "Alice-Home", "name": "Alice", "realm": "Home", "source": source}
        data.update(fields)
        return self.lua.globals()["TestUpsert"](self.db, self.lua.table_from(data))

    def test_peer_cannot_replace_locally_observed_class_and_level(self):
        self.assertTrue(self.upsert("unit", level=60, **{"class": "MAGE"}))
        self.assertFalse(self.upsert("peer", level=1, **{"class": "WARRIOR"}))
        player = self.db["players"]["Alice-Home"]
        self.assertEqual(60, player["level"])
        self.assertEqual("MAGE", player["class"])

    def test_peer_can_fill_missing_fields_without_replacing_known_ones(self):
        self.upsert("chat")
        self.upsert("peer", level=40, **{"class": "DRUID"})
        player = self.db["players"]["Alice-Home"]
        self.assertEqual(40, player["level"])
        self.assertEqual("DRUID", player["class"])
        self.upsert("peer", level=1, **{"class": "WARRIOR"})
        self.assertEqual(40, player["level"])
        self.assertEqual("DRUID", player["class"])

    def test_local_observation_corrects_peer_data(self):
        self.upsert("peer", level=1, **{"class": "WARRIOR"})
        self.upsert("who", level=60, **{"class": "MAGE"})
        player = self.db["players"]["Alice-Home"]
        self.assertEqual(60, player["level"])
        self.assertEqual("MAGE", player["class"])


if __name__ == "__main__":
    unittest.main()
