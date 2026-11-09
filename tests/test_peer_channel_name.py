"""Какие каналы аддон считает своими (Lua 5.1, real IsPeerChannel).

Имена канала (10.11.2026): nearbyspy — база, nearbyspya — Альянс, nearbyspyh —
Орда. Суффикс приклеен БЕЗ подчёркивания: такое имя клиент не принимает.

Что держит файл:
  - базовое имя и фракционные варианты распознаются;
  - клиентский префикс "N. " не мешает, регистр не важен;
  - принимается любой ОДНОсимвольный суффикс — новая фракция не должна
    требовать правки распознавания;
  - старые имена (nearbyspydata и его варианты) тоже прячутся из чата: это тот
    же протокол, и после переименования старые строки не должны сыпаться
    игроку;
  - чужие каналы своими НЕ считаются, иначе фильтр чата съел бы обычный чат.
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
            'PEER_CHANNEL_BASE = "nearbyspy"\n'
            'PEER_CHANNEL_LEGACY = { "nearbyspydata", "nearbyspydata_a", "nearbyspydata_h" }\n'
            "canaccessvalue = nil\n"
            + block + "\nTestIsPeer = IsPeerChannel\n"
        )

    def is_peer(self, name):
        return bool(self.lua.globals()["TestIsPeer"](name))

    def test_base_channel(self):
        self.assertTrue(self.is_peer("nearbyspy"))

    def test_faction_channels(self):
        self.assertTrue(self.is_peer("nearbyspya"))
        self.assertTrue(self.is_peer("nearbyspyh"))

    def test_client_prefix_is_stripped(self):
        # клиент отдаёт имя как "1. nearbyspy" и как голое имя
        self.assertTrue(self.is_peer("1. nearbyspy"))
        self.assertTrue(self.is_peer("46. nearbyspyh"))

    def test_case_insensitive(self):
        self.assertTrue(self.is_peer("NearbySpyH"))

    def test_future_suffix_is_accepted(self):
        # новая фракция/тестовый канал не должен требовать правки распознавания
        self.assertTrue(self.is_peer("nearbyspyx"))

    def test_underscore_variant_is_not_a_channel(self):
        # подчёркивание клиент не принимает — такое имя не может быть каналом
        self.assertFalse(self.is_peer("nearbyspy_h"))

    def test_legacy_names_are_hidden_too(self):
        # старый канал того же протокола: его строки тоже не должны попадать
        # в чат после переименования
        for name in ("nearbyspydata", "nearbyspydata_a", "nearbyspydata_h"):
            self.assertTrue(self.is_peer(name), name)

    def test_other_channels_are_not_peer(self):
        # фильтр CHAT_MSG_CHANNEL использует эту же функцию: ошибка здесь
        # съела бы обычный чат
        for name in ("General", "Trade", "1. General", "nearbyspyzz",
                     "nearbyspyh_deep", "worlddefense", ""):
            self.assertFalse(self.is_peer(name), name)

    def test_non_string_is_not_peer(self):
        self.assertFalse(self.is_peer(None))
        self.assertFalse(self.is_peer(0))


if __name__ == "__main__":
    unittest.main()
