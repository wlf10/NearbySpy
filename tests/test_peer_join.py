"""Канал обмена: имя по фракции и вход при неготовой подсистеме каналов.

История:
  - 09.2026: на логине GetChannelName может вернуть nil (а не 0), и проверка
    `== 0` молча пропускала вход на всю сессию;
  - 10.11.2026: сервер не пускает персонажа одной фракции в канал, созданный
    другой (под Ордой вход в общий "nearbyspydata" отклонён). Канал разделён:
    _a для Альянса, _h для Орды, базовое имя — для неизвестной фракции.

Что держит файл:
  - имя канала получает суффикс фракции; фракция берётся из UnitFactionGroup,
    а не из настроек, и её отсутствие не ломает вход;
  - вход выполняется и при nil, и при 0 от GetChannelName;
  - если канал уже есть, повторного Join не происходит;
  - отправка идёт в свой канал, а входящие принимаются из ЛЮБОГО варианта
    (иначе после разделения аддон отрезал бы половину канала).
"""

from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime


SOURCE = Path(__file__).resolve().parents[1] / "NearbySpy.lua"


class PeerChannelNameTests(unittest.TestCase):
    """PeerChannelName: суффикс по фракции."""

    def name_for(self, faction_result):
        source = SOURCE.read_text(encoding="utf-8")
        block = source[
            source.index('local PEER_CHANNEL_BASE = "nearbyspydata"'):
            source.index("local PEER_QUEUE_MAX")
        ]
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute(
            "FACTION = " + faction_result + "\n"
            "UnitFactionGroup = function(_) return FACTION, FACTION end\n"
            + block
        )
        return str(lua.globals()["PeerChannelName"]())

    def test_alliance_gets_the_a_suffix(self):
        self.assertEqual("nearbyspydata_a", self.name_for("'Alliance'"))

    def test_horde_gets_the_h_suffix(self):
        self.assertEqual("nearbyspydata_h", self.name_for("'Horde'"))

    def test_unknown_faction_uses_the_base_channel(self):
        # нейтральный/нестандартный сервер: не выдумываем суффикс
        self.assertEqual("nearbyspydata", self.name_for("nil"))

    def test_broken_api_does_not_break_the_join(self):
        source = SOURCE.read_text(encoding="utf-8")
        block = source[
            source.index('local PEER_CHANNEL_BASE = "nearbyspydata"'):
            source.index("local PEER_QUEUE_MAX")
        ]
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute(
            "UnitFactionGroup = function() error('boom') end\n" + block
        )
        self.assertEqual("nearbyspydata", str(lua.globals()["PeerChannelName"]()))


class PeerJoinTests(unittest.TestCase):
    def join_with_channel_state(self, channel, channel_name="nearbyspydata_h"):
        source = SOURCE.read_text(encoding="utf-8")
        block = source[
            source.index("local function JoinPeerChannel"):
            source.index("-- Race -> faction")
        ]
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute(
            "GetDB = function() return { peerEnabled = true } end\n"
            "PEER_CHANNEL_BASE = 'nearbyspydata'\n"
            "function PeerChannelName() return CHANNEL_NAME end\n"
            "CHANNEL_NAME = '" + channel_name + "'\n"
            "CHANNEL = " + ("nil" if channel is None else str(channel)) + "\n"
            "GetChannelName = function(_) return CHANNEL end\n"
            "JOINS = {}\n"
            "JoinChannelByName = function(name) JOINS[#JOINS + 1] = name end\n"
            "ChatFrame_RemoveChannel = nil\n"
            "time = function() return 1000 end\n"
            + block + "\nTestJoin = JoinPeerChannel\n"
        )
        lua.globals()["TestJoin"]()
        joins = lua.globals()["JOINS"]
        return [joins[i] for i in range(1, len(joins) + 1)]

    def test_joins_when_channel_api_returns_nil(self):
        joined = self.join_with_channel_state(None)
        self.assertIn("nearbyspydata_h", joined)

    def test_joins_when_channel_api_returns_zero(self):
        joined = self.join_with_channel_state(0)
        self.assertIn("nearbyspydata_h", joined)

    def test_no_join_when_already_in_channel(self):
        # Уже в своём канале — повторного Join нет. Базовый канал НЕ пробуется
        # вообще: сервер отвечает NOT_ALLOWED_IN_CHANNEL и это печаталось
        # игроку ошибкой в чат (10.11.2026).
        joined = self.join_with_channel_state(5)
        self.assertEqual([], joined)

    def test_base_channel_is_never_attempted(self):
        # Канал чужой фракции недоступен по определению: попытка входа только
        # шумит ошибкой в чате и ничего не даёт.
        joined = self.join_with_channel_state(None)
        self.assertNotIn("nearbyspydata", joined)
        self.assertEqual(["nearbyspydata_h"], joined)


if __name__ == "__main__":
    unittest.main()
