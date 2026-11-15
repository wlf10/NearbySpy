#!/usr/bin/env python3
"""DbgErr must never lose an error behind an older one.

The defect (15.11.2026): `db.debug.err[src]` was written only when that source had
no entry yet. One stale entry — `err.chat` carried a `tonumber` failure from
09.11 — therefore swallowed every later error of the same source: nothing was
counted, nothing reached the ring, and no timestamp moved. "There was an error in
the log" became unprovable, because the log could not record it.

Now:
  - `errCount[src]` counts every occurrence;
  - `errLast[src]` always holds the latest text;
  - `errAt[src]` always moves;
  - `err[src]` keeps the first one ever, for history;
  - the ring gets a line at most once a minute per source (a flood of identical
    errors must not push everything else out of a 200-line ring).

Run: python tests/test_debug_err.py
"""
import re
from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

SOURCE = Path(__file__).resolve().parents[1] / "NearbySpy.lua"
SRC = SOURCE.read_text(encoding="utf-8")

PRELUDE = """
NOW = 1000
time = function() return NOW end
DB = { debug = {} }
function GetDB() return DB end
RING = {}
local function D(msg) RING[#RING + 1] = tostring(msg) end
"""


def dbg_block() -> str:
    start = SRC.index("local function DbgErr(src, err)")
    end = SRC.index("\nend\n", start) + len("\nend\n")
    return SRC[start:end]


class DbgErrTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(PRELUDE + dbg_block() + "\n_G.DbgErr = DbgErr\n")
        self.g = self.lua.globals()

    def err(self, src, text, now=None):
        if now is not None:
            self.g["NOW"] = now
        self.g["DbgErr"](src, text)

    def dbg(self):
        return self.g["DB"]["debug"]

    def test_a_new_error_after_a_stale_one_is_still_counted(self):
        # this is the actual defect: the second call used to be a no-op
        self.err("chat", "old failure")
        self.err("chat", "new failure")
        self.assertEqual(2, self.dbg()["errCount"]["chat"])
        self.assertEqual("new failure", self.dbg()["errLast"]["chat"])

    def test_first_ever_text_is_kept_for_history(self):
        self.err("chat", "old failure")
        self.err("chat", "new failure")
        self.assertEqual("old failure", self.dbg()["err"]["chat"])

    def test_timestamp_moves_with_every_error(self):
        self.err("chat", "first", now=1000)
        self.err("chat", "second", now=5000)
        self.assertEqual(5000, self.dbg()["errAt"]["chat"])

    def test_sources_are_counted_separately(self):
        self.err("chat", "a")
        self.err("vendor", "b")
        self.err("chat", "c")
        self.assertEqual(2, self.dbg()["errCount"]["chat"])
        self.assertEqual(1, self.dbg()["errCount"]["vendor"])

    def test_ring_gets_one_line_then_backs_off(self):
        # a repeating error must not flood a 200-line ring
        self.err("chat", "boom", now=1000)
        self.err("chat", "boom", now=1010)
        self.err("chat", "boom", now=1020)
        self.assertEqual(1, len(self.g["RING"]), "three errors produced more than one ring line")
        self.err("chat", "boom", now=1200)
        self.assertEqual(2, len(self.g["RING"]), "an error a minute later should be logged again")

    def test_long_text_is_truncated(self):
        self.err("chat", "x" * 500)
        self.assertEqual(200, len(self.dbg()["errLast"]["chat"]))
        self.assertEqual(200, len(self.dbg()["err"]["chat"]))

    def test_missing_debug_table_does_not_raise(self):
        self.lua.execute("DB = {}")
        self.g["DbgErr"]("chat", "boom")   # must not throw

    def test_count_is_visible_in_the_command_output(self):
        # /nspy count prints error[src] xN: last — the format is what makes the
        # failure checkable from chat instead of a SavedVariables hunt
        self.err("chat", "bad argument #2 to 'tonumber'")
        out = self.lua.execute("""
            local parts = {}
            for src, n in pairs(DB.debug.errCount) do
                parts[#parts + 1] = string.format("error[%s] x%d: %s", src, n,
                    tostring((DB.debug.errLast or {})[src] or "?"))
            end
            return parts[1]
        """)
        self.assertEqual("error[chat] x1: bad argument #2 to 'tonumber'", out)


if __name__ == "__main__":
    unittest.main()
