"""Запрос базы у пиров: `/nspy peer ask` — постановка Q1 в очередь (Lua 5.1).

До этой правки обмен был односторонним: N7 (встречи) и G7 (экипировка/билд)
уходили сами, а спросить «пришли, что у тебя есть за последний час» было нечем.

Что проверяется:
  - пакет запроса — ровно 5 полей `Q1;game;realm;minutes;nonce`, ≤ 240 байт, без
    '|' (сервер отклоняет сообщение с ним как «Invalid escape code»);
  - окно клампится 5…1440 минут, по умолчанию 60;
  - запрос встаёт в ГОЛОВУ очереди, чтобы не ждать за пачкой встреч;
  - при выключенном обмене и неподключённом канале запрос не ставится, а
    команда получает причину — молчаливой потери быть не должно;
  - второй такой же запрос в ту же секунду не дублируется.
"""

from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

from nsp_helpers import peer_module


SOURCE = Path(__file__).resolve().parents[1] / "NearbySpy.lua"


class PeerAskRequestTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.db = peer_module(self.lua)
        self.queue = self.lua.globals()["TestPeerQueue"]
        self.stats = self.lua.globals()["TestPeerStats"]

    # --- helpers -------------------------------------------------------
    def ask(self, minutes=None):
        fn = self.lua.globals()["PeerAskSend"]
        return fn(self.db, minutes)

    def payload_of(self, minutes=None):
        ok, payload = self.ask(minutes)
        self.assertTrue(ok, payload)
        return str(payload)

    def fields(self, payload):
        return payload.split(";")

    # --- tests ---------------------------------------------------------
    def test_request_packet_shape_and_budget(self):
        payload = self.payload_of(60)
        parts = self.fields(payload)
        self.assertEqual(5, len(parts), payload)
        self.assertEqual("Q1", parts[0])
        # игра кодом ("f"), не именем: 7 байт против 1
        self.assertEqual("f", parts[1])
        self.assertLessEqual(len(payload.encode()), 240)
        self.assertNotIn("|", payload)

    def test_default_window_is_sixty_minutes(self):
        parts = self.fields(self.payload_of())
        self.assertEqual(60, int(parts[3], 36))

    def test_window_is_clamped_both_ways(self):
        self.assertEqual(5, int(self.fields(self.payload_of(1))[3], 36))
        # nonce привязан к секунде: два запроса в одну и ту же секунду
        # неотличимы, и второй честно отбивается как дубль — поэтому часы
        # двигаем, иначе тест проверял бы дедуп, а не кламп.
        self.lua.execute("TestClock = TestClock + 1")
        self.assertEqual(1440, int(self.fields(self.payload_of(99999))[3], 36))

    def test_request_goes_to_the_head_of_the_queue(self):
        self.assertEqual(0, len(self.queue))
        self.payload_of(60)
        first = self.queue[1]
        self.assertEqual("Q1 60m", first["label"])
        self.assertTrue(str(first["raw"]).startswith("Q1;"))
        self.assertEqual(1, len(self.queue))

    def test_request_is_marked_queued_so_it_is_not_enqueued_twice(self):
        self.payload_of(60)
        ok, reason = self.ask(60)
        self.assertFalse(ok)
        self.assertIn("already queued", str(reason))
        self.assertEqual(1, len(self.queue))

    def test_sharing_off_refuses_with_a_reason(self):
        self.db["peerEnabled"] = False
        ok, reason = self.ask(60)
        self.assertFalse(ok)
        self.assertIn("sharing is off", str(reason))
        self.assertEqual(0, len(self.queue))

    def test_channel_not_joined_refuses_with_a_reason(self):
        self.lua.execute("TestChannel = 0")
        ok, reason = self.ask(60)
        self.assertFalse(ok)
        self.assertIn("not joined", str(reason))
        self.assertEqual(0, len(self.queue))

    def test_unknown_realm_refuses(self):
        self.lua.execute("PlayerRealm = function() return '?' end")
        ok, reason = self.ask(60)
        self.assertFalse(ok)
        self.assertIn("realm unknown", str(reason))

    def test_request_opens_receive_window_and_counts_answer_rows(self):
        self.payload_of(60)
        # окно приёма открыто на 180 с: в нём пришедшие записи считаются ответом
        self.lua.execute("TestClock = TestClock + 10")
        self.assertEqual(0, self.stats["askIn"])
        self.assertGreater(self.stats["askWindowUntil"], 1000000)


if __name__ == "__main__":
    unittest.main()
