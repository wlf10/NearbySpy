"""Запрос базы у пиров: `/nspy peer ask [имя] [минуты]` — постановка Q1 (Lua 5.1).

До этой правки обмен был односторонним: N7 (встречи) и G7 (экипировка/билд)
уходили сами, а спросить «пришли, что у тебя есть за последний час» было нечем.

Пакет запроса МИНИМАЛЬНЫЙ — `Q1;минуты;nonce[;имя]`. Игры и мира в нём нет
(требование владельца 24.11.2026): канал сам определяет, кто слышит запрос, а
мир каждой записи едет в самих ответах N7. Тест держит число полей — иначе
лишнее поле вернётся молча.

Что проверяется:
  - ровно три поля (четыре с адресатом), ≤ 240 байт, без '|' (сервер отклоняет
    сообщение с ним как «Invalid escape code»);
  - окно клампится 5…1440 минут, по умолчанию 60;
  - имя адресата уходит последним полем, двусловное имя не режется;
  - запрос встаёт в ГОЛОВУ очереди и не дублируется;
  - при выключенном обмене и неподключённом канале запрос не ставится, причина
    печатается;
  - открытые запросы копятся в таблице (обход по очереди), а не затирают друг
    друга.
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
    def ask(self, minutes=None, target=None):
        return self.lua.globals()["PeerAskSend"](self.db, minutes, target)

    def payload_of(self, minutes=None, target=None):
        ok, payload = self.ask(minutes, target)
        self.assertTrue(ok, payload)
        return str(payload)

    def fields(self, payload):
        return payload.split(";")

    def open_count(self):
        """Сколько записей в таблице открытых запросов (счёт по Lua, не Python)."""
        return self.lua.eval("(function(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end)")(self.stats["askOpen"])

    # --- форма пакета --------------------------------------------------
    def test_request_carries_no_game_and_no_realm(self):
        parts = self.fields(self.payload_of(60))
        self.assertEqual(3, len(parts), parts)
        self.assertEqual("Q1", parts[0])
        # ни имени мира, ни кода игры: их место — в записях ответа, не в запросе
        self.assertNotIn("TestRealm PvP", parts)
        self.assertNotIn("forever", parts)
        self.assertEqual(60, int(parts[1], 36))
        self.assertNotIn("|", ";".join(parts))

    def test_request_is_short_enough_for_the_channel(self):
        payload = self.payload_of(1440)
        self.assertLessEqual(len(payload.encode()), 30, payload)

    def test_default_window_is_sixty_minutes(self):
        self.assertEqual(60, int(self.fields(self.payload_of())[1], 36))

    def test_window_is_clamped_both_ways(self):
        self.assertEqual(5, int(self.fields(self.payload_of(1))[1], 36))
        # Гейт адресата («всем» — тот же интервал) отбил бы второй запрос, если
        # часы не сдвинуть: проверяем кламп, а не гейт.
        self.lua.execute("TestClock = TestClock + 30")
        self.assertEqual(1440, int(self.fields(self.payload_of(99999))[1], 36))

    # --- адресат -------------------------------------------------------
    def test_named_target_is_the_last_field(self):
        parts = self.fields(self.payload_of(60, "Wolff"))
        self.assertEqual(4, len(parts), parts)
        self.assertEqual("Q1", parts[0])
        # регистр сохраняется как ввёл игрок (к нижнему регистру приводит
        # диспетчер команд), а сравнение на приёме регистронезависимое
        self.assertEqual("Wolff", parts[3])

    def test_two_word_target_is_not_truncated(self):
        # Регистр сохраняется как ввёл игрок: к нижнему регистру ввод приводит
        # диспетчер команд, а не сама отправка. Сравнение на приёме
        # регистронезависимое, поэтому это не мешает.
        parts = self.fields(self.payload_of(60, "Wolff Magy"))
        self.assertEqual(4, len(parts), parts)
        self.assertEqual("Wolff Magy", parts[3])

    def test_asking_yourself_is_refused(self):
        # UnitName в харнессе = "Me"; просить у себя бессмысленно — ответ придёт
        # от нас же и будет отброшен как собственное эхо.
        ok, reason = self.ask(60, "Me")
        self.assertFalse(ok)
        self.assertIn("your own character", str(reason))

    def test_name_with_separator_is_refused(self):
        ok, reason = self.ask(60, "Bad;Name")
        self.assertFalse(ok)
        self.assertIn("bad player name", str(reason))

    def test_same_target_twice_in_a_row_is_refused(self):
        self.payload_of(60, "Wolff")
        self.lua.execute("TestClock = TestClock + 1")
        ok, reason = self.ask(60, "Wolff")
        self.assertFalse(ok)
        self.assertIn("already asked", str(reason))

    # --- очередь и окна ------------------------------------------------
    def test_request_goes_to_the_head_of_the_queue(self):
        self.assertEqual(0, len(self.queue))
        self.payload_of(60)
        first = self.queue[1]
        self.assertTrue(str(first["label"]).startswith("Q1 60m"), first["label"])
        self.assertTrue(str(first["raw"]).startswith("Q1;"))
        self.assertEqual(1, len(self.queue))

    def test_second_request_in_a_row_is_refused(self):
        # Запрос «всем» дороже всех (отвечают все сразу), поэтому повтор в
        # пределах ASK_TARGET_GAP отбивается — иначе канал забивается запросами.
        self.payload_of(60)
        ok, reason = self.ask(60)
        self.assertFalse(ok)
        self.assertIn("already asked", str(reason))
        self.assertEqual(1, len(self.queue))

    def test_two_requests_stay_open_together(self):
        # Обход по очереди: второй запрос НЕ закрывает окно первого, иначе ответ
        # первому пришёл бы уже «чужим».
        self.payload_of(60, "Wolff")
        self.lua.execute("TestClock = TestClock + 30")
        self.payload_of(60, "Magy")
        self.assertEqual(2, self.open_count())

    def test_open_requests_are_capped(self):
        for i in range(12):
            self.lua.execute("TestClock = TestClock + 30")
            self.ask(60, "Peer%d" % i)
        self.assertLessEqual(self.open_count(), 8)

    # --- отказы --------------------------------------------------------
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

    def test_unknown_realm_no_longer_blocks_the_request(self):
        # Мир в пакете не едет, значит его отсутствие не повод отказывать.
        self.lua.execute("PlayerRealm = function() return '?' end")
        ok, payload = self.ask(60)
        self.assertTrue(ok, payload)
        self.assertEqual(3, len(self.fields(str(payload))))


if __name__ == "__main__":
    unittest.main()
