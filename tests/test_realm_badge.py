"""Realm badge under the name for every row, own realm shortened to its ruleset.

Our own realm appears on every locally recorded row (thousands of them), so the
badge shows only the ruleset ("PvE") there; a foreign realm keeps the part that
identifies it ("EU4 Realm 6 PvP"). One list must never mix labelled and unlabelled
rows — that was the state when only foreign rows carried a badge.
"""

from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

SOURCE = Path(__file__).resolve().parents[1] / "NearbySpy.lua"

MINE = "CAMWOW EU5 Realm 1 PvE"


def blocks() -> str:
    src = SOURCE.read_text(encoding="utf-8")
    peer = src[src.index("function PeerRealmTag(realm, mine)"):src.index("local function TacticalVisible(p, now)")]
    badge = src[src.index("function RealmBadge(realm)"):src.index("local function TacticalVisible(p, now)")]
    return peer + "\n" + badge


class RealmBadgeTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute('function PlayerRealm() return "' + MINE + '" end\n'
                         + blocks() + "\nTestBadge = RealmBadge\n")

    def badge(self, realm):
        return self.lua.globals()["TestBadge"](realm)

    def test_own_realm_shrinks_to_the_ruleset(self):
        self.assertEqual("PvE", self.badge(MINE))

    def test_own_pvp_realm_shrinks_to_pvp(self):
        # the same rule on a PvP character: the badge must not leak a realm name
        self.lua.execute('function PlayerRealm() return "CAMWOW EU4 Realm 6 PvP" end')
        self.assertEqual("PvP", self.badge("CAMWOW EU4 Realm 6 PvP"))

    def test_foreign_realm_keeps_its_identifying_part(self):
        self.assertEqual("EU4 Realm 6 PvP", self.badge("CAMWOW EU4 Realm 6 PvP"))

    def test_missing_realm_has_no_badge(self):
        self.assertIsNone(self.badge(None))
        self.assertIsNone(self.badge(""))


if __name__ == "__main__":
    unittest.main()
