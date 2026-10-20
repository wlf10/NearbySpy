"""Regression test: peer channel join must happen when GetChannelName is nil.

On login the channel subsystem may not be ready: GetChannelName returns nil
(not 0). The old check `== 0` silently skipped the join for the whole session.
"""

from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime


SOURCE = Path(__file__).resolve().parents[1] / "NearbySpy.lua"


class PeerJoinTests(unittest.TestCase):
    def join_with_channel_state(self, channel):
        source = SOURCE.read_text(encoding="utf-8")
        block = source[
            source.index("local function JoinPeerChannel") :
            source.index("-- Race -> faction")
        ]
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute(
            "GetDB = function() return { peerEnabled = true } end\n"
            "PEER_CHANNEL = 'nearbyspydata'\n"
            "CHANNEL = " + ("nil" if channel is None else str(channel)) + "\n"
            "GetChannelName = function(_) return CHANNEL end\n"
            "JOINS = {}\n"
            "JoinChannelByName = function(name) JOINS[#JOINS + 1] = name end\n"
            "ChatFrame_RemoveChannel = nil\n"
            + block + "\nTestJoin = JoinPeerChannel\n"
        )
        lua.globals()["TestJoin"]()
        joins = lua.globals()["JOINS"]
        return [joins[i] for i in range(1, len(joins) + 1)]

    def test_joins_when_channel_api_returns_nil(self):
        self.assertEqual(["nearbyspydata"], self.join_with_channel_state(None))

    def test_joins_when_channel_api_returns_zero(self):
        self.assertEqual(["nearbyspydata"], self.join_with_channel_state(0))

    def test_no_join_when_already_in_channel(self):
        self.assertEqual([], self.join_with_channel_state(5))


if __name__ == "__main__":
    unittest.main()
