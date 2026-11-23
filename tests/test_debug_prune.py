#!/usr/bin/env python3
"""NspPruneDebug — SavedVariables keep keys the code no longer writes.

Why this exists: WoW merges SavedVariables on load, so a `db.debug.<key>` written
by an older build stays in the file forever. The live file carried 98 KB of
debug data, ~70 KB of it dumps from the removed talent/inspect probe
(`/nspy talex`, `/nspy inspecttest`), plus leftovers of features that are gone
(`cv_nameplateShow*`). Deleting the code does not delete the file.

The migration deletes every `db.debug` key outside a whitelist. That makes the
whitelist load-bearing in BOTH directions:

  - a counter the code writes but the list forgets is silently wiped on the next
    login (diagnostics disappear from the file that support reads);
  - a key the code no longer writes but the list keeps is never cleaned (the
    bloat this migration exists for).

So the first test is a parity check against the sources themselves, not a copy
of the list: it greps every `debug.<key>` in the addon and compares the sets.
The rest of the file runs the real sliced function in Lua 5.1 and checks the
behaviour: stale keys go, live keys stay, working data is untouched, and a
second call is a no-op.

Run: python tests/test_debug_prune.py
"""
import re
import unittest
from pathlib import Path

from lupa.lua51 import LuaRuntime

ADDON_DIR = Path(__file__).resolve().parents[1]
ADDON_FILE = ADDON_DIR / "NearbySpy.lua"


def prune_function_source(lua_text: str) -> str:
    """The real NspPruneDebug body, sliced from the addon by explicit markers."""
    start_marker = "NSP_DEBUG_PRUNE_VERSION = 2\nfunction NspPruneDebug(db)"
    if start_marker not in lua_text:
        raise AssertionError(
            "в NearbySpy.lua нет NspPruneDebug — миграция чистки db.debug отсутствует, "
            "старые ключи из SavedVariables никогда не удалятся")
    start = lua_text.index(start_marker)
    end_marker = "\n\n-- Раньше хранилась ОДНА фракция на расу"
    end = lua_text.index(end_marker, start)
    return lua_text[start:end]


def whitelist_from_source(lua_text: str) -> set:
    """Keys of the `local keep = { ... }` table inside NspPruneDebug."""
    body = prune_function_source(lua_text)
    table_start = body.index("local keep = {")
    table_end = body.index("\n    }", table_start)
    return set(re.findall(r"(\w+)\s*=\s*true", body[table_start:table_end]))


def written_debug_keys() -> set:
    """Every db.debug key the addon code writes, taken from the sources."""
    keys = set()
    files = list(ADDON_DIR.glob("*.lua")) + list(ADDON_DIR.glob("NearbySpy_Data/*.lua"))
    for path in files:
        text = path.read_text(encoding="utf-8")
        keys.update(re.findall(r"debug\.([A-Za-z_]\w*)", text))
        keys.update(re.findall(r'debug\["([A-Za-z_]\w*)"\]', text))
    return keys


class WhitelistParity(unittest.TestCase):
    """The whitelist must match the sources exactly — no drift in either direction."""

    def setUp(self):
        self.text = ADDON_FILE.read_text(encoding="utf-8")
        self.keep = whitelist_from_source(self.text)
        self.written = written_debug_keys()

    def test_every_written_key_is_kept(self):
        missing = self.written - self.keep
        self.assertEqual(
            set(), missing,
            "код пишет debug.<key>, которого нет в белом списке prune — "
            "счётчик будет стёрт при следующем входе: " + ", ".join(sorted(missing)))

    def test_no_dead_key_in_whitelist(self):
        dead = self.keep - self.written
        self.assertEqual(
            set(), dead,
            "в белом списке есть ключ, который код больше не пишет — эта миграция "
            "существует именно чтобы такие убирать: " + ", ".join(sorted(dead)))

    def test_removed_probe_keys_are_not_whitelisted(self):
        """The probe dumps are the reason for this migration: they must not stay."""
        for key in ("talentTrees", "talentTruth", "talentSolve", "inspect",
                    "players", "playerOrder", "mcGap", "fonts"):
            self.assertNotIn(key, self.keep, f"{key} — дамп снятой пробы, не белый список")

    def test_probe_module_is_gone(self):
        """A leftover TOC entry or command would load/reach a deleted chunk."""
        toc = (ADDON_DIR / "NearbySpy.toc").read_text(encoding="utf-8")
        self.assertNotIn("NearbySpy_Probe.lua", toc)
        self.assertFalse((ADDON_DIR / "NearbySpy_Probe.lua").exists())
        for cmd in ("talex", "inspecttest"):
            self.assertNotIn(f'msg == "{cmd}"', self.text, f"команда /nspy {cmd} осталась")


class PruneBehaviour(unittest.TestCase):
    """The sliced function executed in a real Lua 5.1 runtime."""

    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        src = prune_function_source(ADDON_FILE.read_text(encoding="utf-8"))
        self.lua.execute("""
NOW = 1500
function time() return NOW end
RING = {}
function R(msg) RING[#RING + 1] = tostring(msg) end
""")
        self.lua.execute(src)
        self.prune = self.lua.globals().NspPruneDebug

    def fixture(self):
        """A db shaped like the live SavedVariables file (installed as global `db`)."""
        self.lua.execute("""
db = {
    players = { ["Алана Ли-CAMWOW EU5 Realm 1 PvE"] = { name = "Алана Ли", realm = "CAMWOW EU5 Realm 1 PvE", count = 3 } },
    world = { vendors = { [1] = { name = "Торговец" } } },
    itemNames = { ruRU = { ["236"] = "Доспех" } },
    debug = {
        -- stale: dumps of the removed probe and leftovers of dead features
        talentTrees = { [1] = { junk = true } },
        talentTruth = { [1] = true },
        talentSolve = { [1] = true },
        inspect = { [1] = true },
        players = { ["Player-1-00000001"] = {} },
        playerOrder = { "Player-1-00000001" },
        mcGap = { [1] = { id = 1 } },
        fonts = { ["7"] = "small" },
        cv_nameplateShowFriends = "1",
        cv_nameplateShowEnemies = "0",
        -- live: support reads these after a logout
        printRing = { "[10:00:00] hi" },
        errCount = { chat = 3 },
        peerGate = { n = 2 },
        src = { unit = 12 },
        whoResults = 50,
        -- a counter that also happens to sound like a probe key
        inspectTotal = { ok = 1 },
        inspectQueue = {},
    },
    debugPruned = nil,
}
""")
        return self.lua.globals().db

    def test_stale_keys_removed_live_keys_kept(self):
        db = self.fixture()
        self.prune(db)
        lua = self.lua
        for key in ("talentTrees", "talentTruth", "talentSolve", "inspect",
                    "players", "playerOrder", "mcGap", "fonts",
                    "cv_nameplateShowFriends", "cv_nameplateShowEnemies"):
            self.assertTrue(lua.eval(f'db.debug["{key}"] == nil'), f"{key} должен быть удалён")
        for key in ("printRing", "errCount", "peerGate", "src", "whoResults",
                    "inspectTotal", "inspectQueue"):
            self.assertFalse(lua.eval(f'db.debug["{key}"] == nil'), f"{key} должен остаться")

    def test_working_data_untouched(self):
        """db.debug is diagnostics only: players, world and itemNames must survive."""
        db = self.fixture()
        self.prune(db)
        self.assertTrue(self.lua.eval('db.players["Алана Ли-CAMWOW EU5 Realm 1 PvE"].count == 3'))
        self.assertTrue(self.lua.eval("db.world.vendors[1].name == 'Торговец'"))
        self.assertTrue(self.lua.eval("db.itemNames.ruRU['236'] == 'Доспех'"))

    def test_reports_what_it_dropped(self):
        db = self.fixture()
        self.prune(db)
        self.assertEqual(10, self.lua.eval("db.debug.debugPrunedCount"))
        self.assertEqual(1500, self.lua.eval("db.debug.debugPrunedAt"))
        ring = self.lua.eval("RING[#RING]")
        self.assertIn("debug prune v2: 10 key(s) removed", ring)
        self.assertIn("talentTrees", ring, "в кольце должно быть видно, что удалили")

    def test_second_call_is_a_noop(self):
        """Re-running on the same db must not count the drop twice."""
        db = self.fixture()
        self.prune(db)
        self.prune(db)
        self.assertEqual(10, self.lua.eval("db.debug.debugPrunedCount"))
        self.assertEqual(1, self.lua.eval("#RING"))

    def test_new_version_reruns(self):
        """A newer whitelist version must prune again, not trust the old flag."""
        db = self.fixture()
        self.prune(db)
        self.lua.execute("db.debug.legacyKey = 1; db.debugPruned = 1")
        self.prune(db)
        self.assertTrue(self.lua.eval("db.debug.legacyKey == nil"))

    def test_missing_debug_table_is_created(self):
        self.lua.execute("db = { players = {}, debug = nil }")
        self.prune(self.lua.globals().db)
        self.assertTrue(self.lua.eval("type(db.debug) == 'table'"))
        self.assertEqual(2, self.lua.eval("db.debugPruned"))

    def test_clean_db_writes_nothing_to_ring(self):
        """A file that has nothing to drop must not spam the diagnostic ring."""
        self.lua.execute("db = { players = {}, debug = { src = { unit = 1 } } }")
        self.prune(self.lua.globals().db)
        self.assertEqual(0, self.lua.eval("#RING"))
        self.assertTrue(self.lua.eval("db.debug.debugPrunedCount == nil"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
