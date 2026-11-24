"""Запрос базы у пиров: приём Q1 и его гейты (Lua 5.1, настоящий код).

Запрос — единственный новый пакет фичи, поэтому каждый отказ обязан быть
НАЗВАН: молча проигнорированный Q1 выглядит как «пир не отвечает», и диагноз
уходит не туда (соседний урок — шесть silent `return` в `ReceivePeerGear`,
из-за которых `gearIn=0` не отличался от «G7 не приходит»).

Раскладка: `Q1;минуты;nonce[;имя]` — игры и мира в пакете НЕТ (требование
владельца 24.11.2026): канал сам определяет слышимость, а мир едет в записях
ответа. Поэтому проверок «чужая игра»/«чужой мир» здесь больше не существует —
вместо них проверяется адресат.

  - валидный запрос ставит ответ в ожидание (с задержкой, не сразу);
  - битый состав полей, выключенный обмен и нулевое окно — отказ с причиной;
  - окно из пакета клампится 5…1440 минут;
  - адресный запрос обрабатывает ТОЛЬКО названный игрок (остальные считают
    askNotMe и молчат) — это и позволяет обходить пиров по очереди;
  - повторный запрос того же отправителя раньше ASK_SENDER_GAP ответа не даёт;
  - второй запрос, пока первый ещё в ожидании, не создаёт второй ответ;
  - счётчики доезжают до `db.debug.peer` (иначе живут только в памяти).
"""

from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

from nsp_helpers import lua_fields, peer_module


SOURCE = Path(__file__).resolve().parents[1] / "NearbySpy.lua"


class PeerAskReceiveTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.db = peer_module(self.lua)
        self.globals = self.lua.globals()
        self.stats = self.globals["TestPeerStats"]

    # --- helpers -------------------------------------------------------
    def deliver(self, payload, sender="PeerGuy"):
        table = lua_fields(self.lua, payload)
        return self.globals["ReceivePeerAsk"](table, sender)

    def reason_logged(self, reason):
        logged = self.stats["rejectLogged"]
        return bool(logged and logged["ask:" + reason])

    def pending(self):
        return self.stats["askPending"]

    def clear_pending(self):
        self.stats["askPending"] = None

    # --- счастливый путь -----------------------------------------------
    def test_valid_request_is_scheduled_not_answered_in_place(self):
        self.deliver("Q1;1o;abc")
        req = self.pending()
        self.assertIsNotNone(req)
        self.assertEqual(60, req["minutes"])
        self.assertEqual("abc", str(req["nonce"]))
        self.assertEqual("PeerGuy", str(req["sender"]))
        self.assertEqual(1, self.stats["askReqIn"])

    def test_request_without_realm_and_game_is_accepted(self):
        # Именно этого требует владелец: в запросе нет ни игры, ни мира, и это
        # НЕ повод для отказа.
        self.deliver("Q1;1o;abc")
        self.assertIsNotNone(self.pending())
        self.assertEqual(0, self.stats["askIgnored"] or 0)

    def test_window_from_packet_is_clamped(self):
        self.deliver("Q1;1;abc")            # 1 минута → 5
        self.assertEqual(5, self.pending()["minutes"])
        self.clear_pending()
        self.deliver("Q1;zzzz;def", sender="PeerTwo")  # абсурд → 1440
        self.assertEqual(1440, self.pending()["minutes"])

    # --- адресат -------------------------------------------------------
    def test_named_peer_answers_only_to_its_own_name(self):
        # UnitName в харнессе = "Me": адресованный нам запрос — принимаем
        self.deliver("Q1;1o;abc;Me")
        self.assertIsNotNone(self.pending())
        self.assertEqual("Me", str(self.pending()["target"]))

    def test_named_to_someone_else_is_silently_skipped(self):
        # Запрос назвал другого игрока — отвечать НЕЛЬЗЯ, иначе «спросить по
        # очереди» снова превращается в залп от всех.
        self.deliver("Q1;1o;abc;Somebody Else")
        self.assertIsNone(self.pending())
        self.assertEqual(1, self.stats["askNotMe"])
        # и это не отказ: пакет корректный, просто не нам
        self.assertEqual(0, self.stats["askIgnored"] or 0)

    def test_target_name_is_case_insensitive(self):
        self.deliver("Q1;1o;abc;me")
        self.assertIsNotNone(self.pending())

    def test_broadcast_request_has_no_target(self):
        self.deliver("Q1;1o;abc")
        self.assertIsNone(self.pending()["target"])

    # --- отказы --------------------------------------------------------
    def test_bad_field_count_is_rejected_with_a_reason(self):
        self.deliver("Q1;1o")               # 2 поля: нет nonce
        self.assertIsNone(self.pending())
        self.assertTrue(self.reason_logged("field count"))

    def test_old_five_field_shape_is_rejected(self):
        # Прежняя раскладка с игрой и миром больше не принимается: иначе
        # «минуты» прочитались бы из поля игры.
        self.deliver("Q1;f;TestRealm PvP;1o;abc")
        self.assertIsNone(self.pending())
        self.assertTrue(self.reason_logged("field count"))

    def test_sharing_off_is_rejected(self):
        self.db["peerEnabled"] = False
        self.deliver("Q1;1o;abc")
        self.assertIsNone(self.pending())
        self.assertTrue(self.reason_logged("sharing disabled"))

    def test_non_positive_window_is_rejected(self):
        self.deliver("Q1;0;abc")
        self.assertIsNone(self.pending())
        self.assertTrue(self.reason_logged("bad window"))

    def test_empty_nonce_is_rejected(self):
        self.deliver("Q1;1o;")
        self.assertIsNone(self.pending())
        self.assertTrue(self.reason_logged("bad nonce"))

    def test_same_sender_cannot_ask_again_within_the_sender_gap(self):
        self.deliver("Q1;1o;abc")
        self.clear_pending()
        self.lua.execute("TestClock = TestClock + 60")
        self.deliver("Q1;1o;def")
        self.assertIsNone(self.pending())
        self.assertTrue(self.reason_logged("request from this sender too soon"))

    def test_another_sender_while_pending_is_counted_as_skipped(self):
        self.deliver("Q1;1o;abc")
        before = self.stats["askSkipped"] or 0
        self.deliver("Q1;1o;zzz", sender="PeerTwo")
        self.assertEqual(before + 1, self.stats["askSkipped"])
        # отвечаем всё равно на ПЕРВЫЙ запрос: склеивать два ответа нельзя
        self.assertEqual("abc", str(self.pending()["nonce"]))

    # --- диагностика ---------------------------------------------------
    def test_counters_reach_saved_variables(self):
        self.deliver("Q1;1o;abc")
        self.deliver("Q1", sender="PeerTwo")  # отказ по полям (1 поле)
        peer = self.db["debug"]["peer"]
        self.assertIsNotNone(peer)
        self.assertEqual(2, peer["askReqIn"])
        self.assertEqual(1, peer["askIgnored"])
        self.assertIsNotNone(peer["askNotMe"])


if __name__ == "__main__":
    unittest.main()
