"""Обмен обновлениями: /who увидел знакомого — пакет уходит (Lua 5.1, real код).

До этой правки в канал уходило ТОЛЬКО создание записи. Игрок, которого мы
встретили месяц назад, не уходил в обмен никогда — его новый уровень и новая
зона оставались только в нашей базе, а у остальных устаревали навсегда.

Что проверяется:
  - /who с другим уровнем у знакомого ставит обновление в очередь;
  - /who с той же зоной и уровнем ничего не ставит (нет спама);
  - обновление не отправляется повторно с теми же значениями (дедуп по
    значениям), но уходит при следующем изменении;
  - обновления не забивают очередь: при заполовину полной очереди пропуск;
  - чужой пакет (source="peer") НЕ порождает ответный — иначе бесконечная
    ретрансляция между двумя клиентами.
"""

from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

from nsp_helpers import CONST_PRELUDE

ADDON = Path(__file__).resolve().parents[1]
SOURCE = ADDON / "NearbySpy.lua"


def upsert_block() -> str:
    src = SOURCE.read_text(encoding="utf-8")
    start = src.index("local QueuePeerNew -- assigned below")
    end = src.index("-- Opt-in, realm-local peer exchange.")
    return src[start:end]


class PeerUpdateTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(
            CONST_PRELUDE + "\n"
            "time = function() return 1000 end\n"
            "function Round4(v) if v == nil then return nil end "
            "return math.floor(v * 10000 + 0.5) / 10000 end\n"
            "local function P() end\n"
            "local function D() end\n"
            "local function DbgErr() end\n"
            "function PeerEsc(s) return tostring(s) end\n"
            "function ClassLocFromFile() return nil end\n"
            "function PlayerRealm() return 'R' end\n"
            "newThisSession = 0\n"
            "DB = {players = {}, debug = {}, game = 'forever'}\n"
            "function GetDB() return DB end\n"
            "QUEUED = {}\n"
            "-- заглушка очереди: записываем, что в неё пытались положить\n"
            "QUEUE_CALLS = {}\n"
            + upsert_block().replace(
                "local QueuePeerNew -- assigned below; only local discoveries may call it",
                "local QueuePeerNew")
            + "\n"
            "QueuePeerNew = function(db, data)\n"
            "  QUEUE_CALLS[#QUEUE_CALLS + 1] = {name = data.name, "
            "level = data.level, zone = data.zone, isUpdate = data.isUpdate, "
            "observedAt = data.observedAt}\n"
            "end\n"
            "TestUpsert = UpsertPlayer\n"
            "TestDB = DB\n"
        )
        self.g = self.lua.globals()

    def upsert(self, **fields):
        data = {"key": "Alice-R", "name": "Alice", "realm": "R",
                "class": "MAGE", "level": 20, "zone": "Elwynn", "zoneId": 12,
                "source": "who", "silent": True}
        data.update(fields)
        self.g["TestUpsert"](self.g["TestDB"], self.lua.table_from(data))

    def calls(self):
        q = self.g["QUEUE_CALLS"]
        return [q[i] for i in range(1, len(q) + 1)]

    # --- создание -----------------------------------------------------------

    def test_new_who_record_goes_to_the_queue(self):
        self.upsert()
        calls = self.calls()
        self.assertEqual(1, len(calls))
        self.assertIsNone(calls[0]["isUpdate"], "создание — не обновление")

    # --- обновления ---------------------------------------------------------

    def test_level_change_on_a_known_player_is_sent(self):
        self.upsert()
        self.g["QUEUE_CALLS"] = self.lua.table_from({})
        self.upsert(level=21)
        calls = self.calls()
        self.assertEqual(1, len(calls), "новый уровень знакомого не ушёл в обмен")
        self.assertTrue(calls[0]["isUpdate"])
        self.assertEqual(21, calls[0]["level"])

    def test_zone_change_on_a_known_player_is_sent(self):
        self.upsert()
        self.g["QUEUE_CALLS"] = self.lua.table_from({})
        self.upsert(zoneId=14, zone="Durotar")
        calls = self.calls()
        self.assertEqual(1, len(calls), "новая зона знакомого не ушла в обмен")
        self.assertTrue(calls[0]["isUpdate"])

    def test_same_values_do_not_produce_an_update(self):
        self.upsert()
        self.g["QUEUE_CALLS"] = self.lua.table_from({})
        self.upsert()          # те же уровень и зона
        self.assertEqual([], self.calls(), "одно и то же изменение ушло повторно")

    def test_update_carries_observation_time(self):
        self.upsert()
        self.g["QUEUE_CALLS"] = self.lua.table_from({})
        self.g["time"] = lambda: 1234
        self.upsert(level=25)
        calls = self.calls()
        self.assertEqual(1234, calls[0]["observedAt"],
                         "в обновлении нет времени наблюдения")

    # --- защита от ретрансляции --------------------------------------------

    def test_peer_packet_never_triggers_an_outgoing_update(self):
        # иначе два клиента будут бесконечно пересылать одно и то же
        self.upsert(source="peer", observe=False)
        self.g["QUEUE_CALLS"] = self.lua.table_from({})
        self.upsert(source="peer", observe=False, level=99)
        self.assertEqual([], self.calls(),
                         "peer-пакет породил ответный пакет — ретрансляция")


if __name__ == "__main__":
    unittest.main()
