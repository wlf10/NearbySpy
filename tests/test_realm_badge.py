"""Realm badge under the name: every realm shrinks to its bucket.

Our own realm appears on every locally recorded row (thousands of them), so the
badge never prints the full realm name. Until 15.11.2026 our own realm showed only
the ruleset ("PvE") while a foreign one kept shard and number ("EU4 Realm 6
PvP") — the same distinction in two different shapes. Now both are the bucket
"<region> <ruleset>": "EU PvE", "EU PvP".

One list must never mix labelled and unlabelled rows — that was the state when
only foreign rows carried a badge.
"""

from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

SOURCE = Path(__file__).resolve().parents[1] / "NearbySpy.lua"

MINE = "CAMWOW EU5 Realm 1 PvE"


def blocks() -> str:
    src = SOURCE.read_text(encoding="utf-8")
    stop = src.index("local function TacticalVisible(p, now)")
    peer = src[src.index("function PeerRealmTag(realm, mine)"):stop]
    # RealmBucket lives further down (next to the realm selector); the badge calls
    # it, so both must be in the chunk for the harness to see it. Tolerant on
    # purpose: on a tree that predates the bucket the slice must still assemble,
    # so the test goes red on its ASSERTIONS (badge = full realm name) instead of
    # on a missing marker — otherwise "red" only proves the string was not found.
    if "function RealmBucket(realm)" in src:
        bucket = src[src.index("function RealmBucket(realm)"):src.index("function RealmShortName(realm)")]
    else:
        bucket = ""
    badge = src[src.index("function RealmBadge(realm)"):stop]
    return peer + "\n" + bucket + "\n" + badge


class RealmBadgeTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute('function PlayerRealm() return "' + MINE + '" end\n'
                         + blocks() + "\nTestBadge = RealmBadge\nTestBucket = RealmBucket\n")

    def badge(self, realm):
        return self.lua.globals()["TestBadge"](realm)

    def bucket(self, realm):
        return self.lua.globals()["TestBucket"](realm)

    def test_own_realm_shrinks_to_region_and_ruleset(self):
        self.assertEqual("EU PvE", self.badge(MINE))

    def test_own_pvp_character_shows_eu_pvp(self):
        # the same rule on a PvP character: the badge must not leak a realm name
        self.lua.execute('function PlayerRealm() return "CAMWOW EU4 Realm 6 PvP" end')
        self.assertEqual("EU PvP", self.badge("CAMWOW EU4 Realm 6 PvP"))

    def test_foreign_realms_collapse_to_the_same_bucket(self):
        # the point of the change: shard and realm number must not multiply labels
        for realm in ("CAMWOW EU4 Realm 6 PvP", "CAMWOW EU5 Realm 2 PvP",
                      "CAMWOW EU4 Realm 8 PvP", "EU4 Realm 6 PvP"):
            self.assertEqual("EU PvP", self.badge(realm), realm)

    def test_foreign_pve_shares_the_bucket_with_our_own(self):
        self.assertEqual("EU PvE", self.badge("CAMWOW EU5 Realm 7 PvE"))

    def test_other_ruleset_is_kept_whole(self):
        # "RP PvP" is a different ruleset, not a PvP realm — it must not merge
        self.assertEqual("EU RP PvP", self.badge("CAMWOW EU5 Realm 9 RP PvP"))

    def test_other_region_is_not_merged_into_eu(self):
        self.assertEqual("NA PvE", self.badge("CAMWOW NA1 Realm 3 PvE"))

    def test_unknown_layout_falls_back_to_a_readable_name(self):
        # a realm we cannot parse still has to display something
        self.assertEqual("SomeRealm", self.badge("SomeRealm"))

    def test_bucket_returns_a_single_value(self):
        # gsub returns (string, count); a leaked count would break
        # ("%s"):format(RealmBucket(x)) and table.concat callers
        out = self.lua.execute('local a, b = RealmBucket("CAMWOW EU5 Realm 1 PvE") '
                               'return tostring(a) .. "|" .. tostring(b)')
        self.assertEqual("EU PvE|nil", out)

    def test_missing_realm_has_no_badge(self):
        self.assertIsNone(self.badge(None))
        self.assertIsNone(self.badge(""))


if __name__ == "__main__":
    unittest.main()
