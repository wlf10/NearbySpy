"""Канал обмена: имя по фракции, вход при неготовой подсистеме каналов.

История:
  - 09.2026: на логине GetChannelName может вернуть nil (а не 0), и проверка
    `== 0` молча пропускала вход на всю сессию;
  - 10.11.2026: сервер не пускает персонажа одной фракции в канал, созданный
    другой (под Ордой вход в общий канал отклонён). Канал разделён по фракции:
    nearbyspya для Альянса, nearbyspyh для Орды;
  - подчёркивание в имени канала клиент не принимает, поэтому суффикс
    приклеивается БЕЗ разделителя (nearbyspya, а не nearbyspy_a).

Что держит файл:
  - имя канала получает суффикс фракции; фракция берётся из UnitFactionGroup,
    а не из настроек, и её отсутствие не ломает вход;
  - в имени НЕТ подчёркивания — клиент такое имя отвергает;
  - вход выполняется и при nil, и при 0 от GetChannelName;
  - если канал уже есть, повторного Join не происходит;
  - вход в канал чужой фракции не делается вообще (сервер отвечает
    NOT_ALLOWED_IN_CHANNEL и печатает это игроку);
  - из старых каналов, где персонаж остался с прошлых сессий, аддон выходит.
"""

from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime


SOURCE = Path(__file__).resolve().parents[1] / "NearbySpy.lua"


def lua_map(d):
    """Lua-таблица {ключ = число} из питоновского словаря."""
    d = d or {}
    if not d:
        return "{}"
    return "{ " + ", ".join("['%s'] = %d" % (k, v) for k, v in d.items()) + " }"


class PeerChannelNameTests(unittest.TestCase):
    """PeerChannelName: суффикс по фракции, без подчёркивания."""

    def name_for(self, faction_expr):
        source = SOURCE.read_text(encoding="utf-8")
        block = source[
            source.index('local PEER_CHANNEL_BASE = "nearbyspy"'):
            source.index("local PEER_QUEUE_MAX")
        ]
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute(
            "FACTION = " + faction_expr + "\n"
            "UnitFactionGroup = function(_) return FACTION, FACTION end\n"
            + block
        )
        return str(lua.globals()["PeerChannelName"]())

    def test_alliance_channel(self):
        self.assertEqual("nearbyspya", self.name_for("'Alliance'"))

    def test_horde_channel(self):
        self.assertEqual("nearbyspyh", self.name_for("'Horde'"))

    def test_unknown_faction_uses_the_base_channel(self):
        # нейтральный/нестандартный сервер: не выдумываем суффикс
        self.assertEqual("nearbyspy", self.name_for("nil"))

    def test_no_underscore_in_any_name(self):
        # клиент не принимает подчёркивание в имени канала — это и была ошибка
        for faction in ("'Alliance'", "'Horde'", "nil"):
            self.assertNotIn("_", self.name_for(faction))

    def test_broken_api_does_not_break_the_join(self):
        source = SOURCE.read_text(encoding="utf-8")
        block = source[
            source.index('local PEER_CHANNEL_BASE = "nearbyspy"'):
            source.index("local PEER_QUEUE_MAX")
        ]
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute("UnitFactionGroup = function() error('boom') end\n" + block)
        self.assertEqual("nearbyspy", str(lua.globals()["PeerChannelName"]()))


class PeerJoinTests(unittest.TestCase):
    def join(self, channel, legacy=None, channel_name="nearbyspyh"):
        source = SOURCE.read_text(encoding="utf-8")
        block = source[
            source.index("local function JoinPeerChannel"):
            source.index("-- Race -> faction")
        ]
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute(
            "GetDB = function() return { peerEnabled = true } end\n"
            "PEER_CHANNEL_LEGACY = { 'nearbyspydata', 'nearbyspydata_a', 'nearbyspydata_h' }\n"
            "PEER_CHANNEL_BASE = 'nearbyspy'\n"
            "peerStats = { leftStale = nil }\n"
            "LEAVES = {}\n"
            "LeaveChannelByName = function(n) LEAVES[#LEAVES + 1] = n end\n"
            "CHANNEL_NAME = '" + channel_name + "'\n"
            "function PeerChannelName() return CHANNEL_NAME end\n"
            "CHANNELS = { ['" + channel_name + "'] = " + str(channel) + " }\n"
            "for k, v in pairs(" + lua_map(legacy) + ") do CHANNELS[k] = v end\n"
            "GetChannelName = function(n) return CHANNELS[n] end\n"
            "JOINS = {}\n"
            "JoinChannelByName = function(n) JOINS[#JOINS + 1] = n end\n"
            "ChatFrame_RemoveChannel = nil\n"
            "time = function() return 1000 end\n"
            + block + "\nTestJoin = JoinPeerChannel\n"
        )
        lua.globals()["TestJoin"]()
        joins = lua.globals()["JOINS"]
        leaves = lua.globals()["LEAVES"]
        return ([joins[i] for i in range(1, len(joins) + 1)],
                [leaves[i] for i in range(1, len(leaves) + 1)])

    def test_joins_when_channel_api_returns_nil(self):
        joins, _ = self.join(None)
        self.assertIn("nearbyspyh", joins)

    def test_joins_when_channel_api_returns_zero(self):
        joins, _ = self.join(0)
        self.assertIn("nearbyspyh", joins)

    def test_no_join_when_already_in_channel(self):
        joins, _ = self.join(5)
        self.assertEqual([], joins)

    def test_foreign_faction_channel_is_never_attempted(self):
        # Канал другой фракции недоступен по определению: попытка входа только
        # шумит ошибкой NOT_ALLOWED_IN_CHANNEL в чате игрока.
        joins, _ = self.join(None)
        for name in ("nearbyspya", "nearbyspydata", "nearbyspydata_h"):
            self.assertNotIn(name, joins)

    def test_stale_legacy_channels_are_left(self):
        # Персонаж мог остаться в старых каналах с прошлых сессий: пока
        # membership есть, сервер отвечает NOT_ALLOWED_IN_CHANNEL в чат.
        _, leaves = self.join(5, legacy={"nearbyspydata": 6, "nearbyspydata_h": 7})
        self.assertEqual(["nearbyspydata", "nearbyspydata_h"], leaves)

    def test_no_leave_when_member_of_nothing_stale(self):
        _, leaves = self.join(5, legacy={})
        self.assertEqual([], leaves)


if __name__ == "__main__":
    unittest.main()
