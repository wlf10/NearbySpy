"""Какие каналы аддон считает своими (Lua 5.1, real IsPeerChannel).

После разделения канала по фракциям (10.11.2026) появилось три имени:
nearbyspydata (базовое), nearbyspydata_a (Альянс), nearbyspydata_h (Орда).
Входящие данные полезны независимо от того, кто их прислал, поэтому аддон
обязан принимать ЛЮБОЙ вариант — иначе после разделения он отрезал бы половину
канала и «peer перестал работать» у той фракции, которую не перечислили.

Что держит файл:
  - базовое имя и оба суффикса распознаются;
  - клиентский префикс "1. " не мешает;
  - чужие каналы не считаются своими (иначе фильтр чата съел бы обычный чат);
  - имя с суффиксом, которого ещё нет, тоже принимается — новый суффикс не
    должен требовать правки распознавания.
"""

from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime


SOURCE = Path(__file__).resolve().parents[1] / "NearbySpy.lua"


class IsPeerChannelTests(unittest.TestCase):
    def setUp(self):
        source = SOURCE.read_text(encoding="utf-8")
        block = source[
            source.index("local function IsPeerChannel(channelName)"):
            source.index("-- Hide only our data messages")
        ]
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(
            'PEER_CHANNEL_BASE = "nearbyspydata"\n'
            "canaccessvalue = nil\n"
            + block + "\nTestIsPeer = IsPeerChannel\n"
        )

    def is_peer(self, name):
        return bool(self.lua.globals()["TestIsPeer"](name))

    def test_base_channel(self):
        self.assertTrue(self.is_peer("nearbyspydata"))

    def test_faction_suffixes(self):
        self.assertTrue(self.is_peer("nearbyspydata_a"))
        self.assertTrue(self.is_peer("nearbyspydata_h"))

    def test_client_prefix_is_stripped(self):
        # клиент отдаёт имя как "1. nearbyspydata" и как голое имя
        self.assertTrue(self.is_peer("1. nearbyspydata"))
        self.assertTrue(self.is_peer("46. nearbyspydata_h"))

    def test_case_insensitive(self):
        self.assertTrue(self.is_peer("NearbySpyData_H"))

    def test_future_suffix_is_accepted(self):
        # новый суффикс (третья фракция, тестовый канал) не должен требовать
        # правки распознавания
        self.assertTrue(self.is_peer("nearbyspydata_x"))

    def test_other_channels_are_not_peer(self):
        # фильтр CHAT_MSG_CHANNEL использует эту же функцию: ошибка здесь
        # съела бы обычный чат
        for name in ("General", "Trade", "1. General", "nearbyspydataX",
                     "nearbyspydata_extra_deep", "worlddefense", ""):
            self.assertFalse(self.is_peer(name), name)

    def test_non_string_is_not_peer(self):
        self.assertFalse(self.is_peer(None))
        self.assertFalse(self.is_peer(0))


if __name__ == "__main__":
    unittest.main()
