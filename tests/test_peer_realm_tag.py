"""Realm tag for foreign peer rows (Lua 5.1, real PeerRealmTag)."""

from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

SOURCE = Path(__file__).resolve().parents[1] / "NearbySpy.lua"

OURS = "CAMWOW EU5 Realm 1 PvE"


class RealmTagTests(unittest.TestCase):
    def setUp(self):
        source = SOURCE.read_text(encoding="utf-8")
        start = source.index("function PeerRealmTag(realm, mine)")
        end = source.index("local function TacticalVisible(p, now)", start)
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(source[start:end] + "\nTestTag = PeerRealmTag\n")

    def tag(self, realm, mine=OURS):
        return self.lua.globals()["TestTag"](realm, mine)

    def test_own_realm_gets_no_tag(self):
        self.assertIsNone(self.tag(OURS))

    def test_shared_prefix_is_dropped(self):
        # the real realms observed in the nearbyspydata channel on 09.11.2026
        self.assertEqual("EU4 Realm 6 PvP", self.tag("CAMWOW EU4 Realm 6 PvP"))
        self.assertEqual("EU5 Realm 2 PvE", self.tag("CAMWOW EU5 Realm 2 PvE"))

    def test_unrelated_realm_is_kept_whole(self):
        self.assertEqual("Someotherrealm", self.tag("Someotherrealm"))

    def test_long_tag_is_clipped(self):
        tag = self.tag("CAMWOW EU4 Realm 6 PvP Extremely Long Suffix")
        self.assertLessEqual(len(tag), 27)
        self.assertTrue(tag.endswith("..."))

    def test_missing_realm_is_tolerated(self):
        self.assertIsNone(self.tag(None))
        self.assertIsNone(self.tag(""))


if __name__ == "__main__":
    unittest.main()
