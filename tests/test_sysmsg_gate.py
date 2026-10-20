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


if __name__ == "__main__":
    unittest.main()
