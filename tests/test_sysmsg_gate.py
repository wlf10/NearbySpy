"""Regression tests: system messages must respect secret-value gates (Lua 5.1).

The Forever client can deliver secret strings in UI_ERROR_MESSAGE /
CHAT_MSG_SYSTEM. CheckWhoThrottle/LogSysMsg must consult canaccessvalue
before string operations, like the chat path does. The harness cannot
reproduce a real secret string (Lua 5.1 strings are always accessible),
so the test asserts the gate is consulted: with canaccessvalue -> false,
the handlers must not process the message at all.
"""

from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime


SOURCE = Path(__file__).resolve().parents[1] / "NearbySpy.lua"


class SecretSysMsgTests(unittest.TestCase):
    def setUp(self):
        source = SOURCE.read_text(encoding="utf-8")
        throttle = source[
            source.index("-- catch the server's anti-bot message") :
            source.index("local function WhoPauseLeft")
        ]
        logmsg = source[
            source.index("-- diagnostics: log recent system messages") :
            source.index("local function PumpWhoQueue")
        ]
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(
            "local whoScan, lastWhoSent = nil, 0\n"
            "local db = { debug = {}, whoPauseUntil = 0 }\n"
            "GetDB = function() return db end\n"
            "time = function() return 1000 end\n"
            "P = function() end\n"
            "L = function(k) return k end\n"
            "FinishZoneScan = function() end\n"
            "ACCESSIBLE = true\n"
            "canaccessvalue = function(v) return ACCESSIBLE end\n"
            + throttle + logmsg + "\n"
            "TestThrottle, TestLog = CheckWhoThrottle, LogSysMsg\n"
        )
        self.db = self.lua.globals()["GetDB"]()

    def test_throttle_gate_skips_inaccessible_message(self):
        g = self.lua.globals()
        g["ACCESSIBLE"] = False
        handled = g["TestThrottle"]("Интересная операция, связанная с модификацией")
        self.assertFalse(bool(handled))
        self.assertIsNone(self.db["debug"]["whoThrottled"])
        self.assertEqual(0, self.db["whoPauseUntil"])

    def test_throttle_still_works_for_plain_strings(self):
        g = self.lua.globals()
        handled = g["TestThrottle"]("Интересная операция, связанная с модификацией")
        self.assertTrue(bool(handled))
        self.assertEqual(1, self.db["debug"]["whoThrottled"])

    def test_syslog_gate_skips_inaccessible_message(self):
        g = self.lua.globals()
        g["ACCESSIBLE"] = False
        g["TestLog"]("sys", "Подождите 5 сек")
        self.assertIsNone(self.db["debug"]["msgLog"])

    def test_syslog_still_logs_plain_strings(self):
        self.lua.globals()["TestLog"]("sys", "Подождите 5 сек")
        self.assertEqual(1, len(self.db["debug"]["msgLog"]))

    def test_syslog_gate_runs_before_emptiness_check(self):
        """`msg == ""` is itself a string operation and throws on a secret value.

        A secret string cannot be constructed in Lua 5.1, so the regression that
        bit in game (17.11.2026: "attempt to compare local 'msg' (a secret
        string value)") is guarded by source order: the gate must come first.
        """
        source = SOURCE.read_text(encoding="utf-8")
        body = source[
            source.index("local function LogSysMsg") :
            source.index("local function PumpWhoQueue")
        ]
        # Comments mention `msg == ""` too (they explain the bug), so compare the
        # code only — otherwise the assertion measures the prose, not the order.
        code = "\n".join(
            line for line in body.splitlines() if not line.lstrip().startswith("--")
        )
        self.assertLess(
            code.index("canaccessvalue"),
            code.index('msg == ""'),
            "canaccessvalue must be consulted before any string comparison",
        )


class PeerEscSecretTests(unittest.TestCase):
    """PeerEsc must not run string operations on a secret string either.

    Lua 5.1 strings are always accessible, so the harness flips canaccessvalue
    to false and expects the placeholder. The old code ignored the gate and
    returned the escaped text (it threw in game at NearbySpy.lua:1252).
    """

    def setUp(self):
        source = SOURCE.read_text(encoding="utf-8")
        block = source[
            source.index("function PeerEsc(s, maxLen)") :
            source.index("local function PeerField")
        ]
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(
            "ACCESSIBLE = true\n"
            "canaccessvalue = function(v) return ACCESSIBLE end\n"
            + block
        )

    def test_secret_string_becomes_placeholder(self):
        g = self.lua.globals()
        g["ACCESSIBLE"] = False
        self.assertEqual("[secret]", g["PeerEsc"]("Grishnákh Soulrend", 60))

    def test_plain_string_is_escaped(self):
        self.assertEqual("bad?name", self.lua.globals()["PeerEsc"]("bad|name", 60))

    def test_plain_string_is_truncated(self):
        self.assertEqual("abc...", self.lua.globals()["PeerEsc"]("abcdef", 3))

    def test_non_string_is_tostringed(self):
        self.assertEqual("42", self.lua.globals()["PeerEsc"](42, 60))


if __name__ == "__main__":
    unittest.main()
