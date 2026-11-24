"""Запрос базы у пиров: что РЕАЛЬНО уходит в канал (Lua 5.1, настоящий транспорт).

Отбор записей проверяют соседние тесты, а здесь проверяется физика канала: у
сервера сообщение ограничено 255 байтами, `|` в тексте отклоняется целиком
(«Invalid escape code in chat message»), а частота — около 10 сообщений в
минуту. Поэтому ответ обязан быть коротким и уходить ТЕМИ ЖЕ тегами, что обычный
обмен (N7 — встречи, G7 — экипировка и билд), иначе клиенты без поддержки
запроса не поймут ответ.

Тест гоняет настоящую `DrainPeerQueue` с перехваченным SendChatMessage:
  - каждое сообщение ≤ 240 байт и без '|';
  - теги только Q1/N7/G7;
  - ответ на 15 записей + 5 снапшотов укладывается в ~12 сообщений канала;
  - снапшот G7 физически уходит ПОСЛЕ своей записи N7 (иначе получатель
    отбросит его в orphan — у него ещё нет строки).
"""

from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

from nsp_helpers import lua_fields, peer_module


SOURCE = Path(__file__).resolve().parents[1] / "NearbySpy.lua"
NOW = 1_000_000

CAPTURE = r"""
TestSent = {}
C_ChatInfo = {SendChatMessage = function(payload) TestSent[#TestSent + 1] = payload end}
"""


class PeerAskTransportTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.db = peer_module(self.lua)
        self.globals = self.lua.globals()
        self.lua.execute(CAPTURE)
        self.sent = self.globals["TestSent"]

    # --- helpers -------------------------------------------------------
    def add_player(self, key, last_seen, gear=None):
        entry = {
            "name": key.split("-")[0], "realm": "TestRealm PvP",
            "class": "MAGE", "level": 60, "race": "Human", "faction": "Alliance",
            "zone": "TestZone", "zoneId": 12, "lastSeen": last_seen, "source": "who",
        }
        if gear is not None:
            entry["gear"] = self.lua.table_from(gear)
        self.db["players"][key] = self.lua.table_from(entry)

    def run_asks(self):
        """Запрос от пира → задержка → разгрузка очереди, пока она не опустеет."""
        ok, payload = self.globals["PeerAskSend"](self.db, 60)
        self.assertTrue(ok, payload)
        self.globals["TestPeerReset"]()
        self.globals["ReceivePeerAsk"](lua_fields(self.lua, str(payload)), "PeerGuy")
        self.lua.execute("TestClock = TestClock + 1")
        self.assertTrue(self.globals["PeerAnswerDue"](self.db))
        for _ in range(20):
            self.globals["TestDrain"]()
            self.lua.execute("TestClock = TestClock + 11")

    def messages(self):
        return [str(self.sent[i]) for i in range(1, len(self.sent) + 1)]

    @staticmethod
    def inner_tag(msg):
        """Тег внутреннего пакета: A1;nonce;<TAG>;… → TAG."""
        return msg.split(";")[2] if msg.startswith("A1;") else msg.split(";")[0]

    # --- tests ---------------------------------------------------------
    def test_whole_answer_fits_the_channel_budget(self):
        for i in range(15):
            gear = {"ids": "1:100,2:200,3:300", "at": NOW - 60, "ilvl": 60}
            self.add_player(f"P{i:02d}-Home", NOW - 10 - i, gear=gear)
        self.run_asks()
        msgs = self.messages()
        self.assertGreater(len(msgs), 0)
        for m in msgs:
            self.assertLessEqual(len(m.encode()), 240, m)
            self.assertNotIn("|", m)
        # Снаружи ВСЁ — тег A1 (ответ адресный), внутри обычный N7/G7: так
        # посторонний клиент выбрасывает пакет, а наш разбор переиспользуется.
        self.assertEqual({"A1"}, {m.split(";")[0] for m in msgs})
        inner = {m.split(";")[2].split(";")[0] for m in msgs}
        self.assertEqual({"N7", "G7"}, inner)
        # 15 записей ≈ 5 сообщений + 5 снапшотов = 10, запас на заголовки
        self.assertLessEqual(len(msgs), 12, msgs)

    def test_every_answer_packet_carries_the_request_nonce(self):
        self.add_player("Nonce-Home", NOW - 10,
                        gear={"ids": "1:100,2:200", "at": NOW - 10, "ilvl": 60})
        ok, payload = self.globals["PeerAskSend"](self.db, 60)
        nonce = str(payload).split(";")[4]
        self.globals["TestPeerReset"]()
        self.globals["ReceivePeerAsk"](lua_fields(self.lua, str(payload)), "PeerGuy")
        self.lua.execute("TestClock = TestClock + 1")
        self.assertTrue(self.globals["PeerAnswerDue"](self.db))
        for _ in range(20):
            self.globals["TestDrain"]()
            self.lua.execute("TestClock = TestClock + 11")
        msgs = self.messages()
        self.assertTrue(msgs)
        for m in msgs:
            self.assertEqual(nonce, m.split(";")[1], m)

    def test_gear_packet_never_overtakes_its_encounter_record(self):
        self.add_player("GearOnly-Home", NOW - 10,
                        gear={"ids": "1:100,2:200", "at": NOW - 10, "ilvl": 60})
        self.run_asks()
        msgs = self.messages()
        # сравнивать надо ВНУТРЕННИЙ пакет: снаружи у всех ответов тег A1
        n7 = [i for i, m in enumerate(msgs) if self.inner_tag(m) == "N7" and "GearOnly" in m]
        g7 = [i for i, m in enumerate(msgs) if self.inner_tag(m) == "G7" and "GearOnly" in m]
        self.assertTrue(n7, msgs)
        self.assertTrue(g7, msgs)
        self.assertLess(n7[0], g7[0], msgs)

    def test_answer_records_carry_no_coordinates(self):
        self.add_player("Plain-Home", NOW - 10, gear=None)
        self.run_asks()
        # A1;nonce;N7;game;realm;rec1,rec2 → отрезаем обёртку и заголовок N7
        msg = self.messages()[0]
        self.assertEqual("A1", msg.split(";")[0])
        records = msg.split(";", 5)[5].split(",")
        parts = records[0].split(";")
        self.assertEqual("-", parts[6], records[0])
        self.assertEqual("-", parts[7], records[0])


if __name__ == "__main__":
    unittest.main()
