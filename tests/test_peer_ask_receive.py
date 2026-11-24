"""Запрос базы у пиров: приём Q1 и его гейты (Lua 5.1, настоящий код).

Запрос — единственный новый пакет фичи, поэтому каждый отказ обязан быть
НАЗВАН: молча проигнорированный Q1 выглядит как «пир не отвечает», и диагноз
уходит не туда (соседний урок — шесть silent `return` в `ReceivePeerGear`,
из-за которых `gearIn=0` не отличался от «G7 не приходит»).

  - валидный запрос ставит ответ в ожидание (с задержкой, не сразу);
  - битый состав полей, чужая игра, чужой мир кластера, выключенный обмен и
    нулевое окно — отказ с причиной, а не тишина;
  - окно из пакета клампится 5…1440 минут;
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

    # --- tests ---------------------------------------------------------
    def test_valid_request_is_scheduled_not_answered_in_place(self):
        self.deliver("Q1;f;TestRealm PvP;1o;abc")
        req = self.pending()
        self.assertIsNotNone(req)
        self.assertEqual(60, req["minutes"])
        self.assertEqual("abc", str(req["nonce"]))
        self.assertEqual("PeerGuy", str(req["sender"]))
        self.assertEqual(1, self.stats["askReqIn"])

    def test_window_from_packet_is_clamped(self):
        self.deliver("Q1;f;TestRealm PvP;1;abc")       # 1 минута → 5
        self.assertEqual(5, self.pending()["minutes"])
        self.globals["TestPeerReset"]()
        self.stats["askPending"] = None
        self.deliver("Q1;f;TestRealm PvP;zzzz;def", sender="PeerTwo")  # абсурд → 1440
        self.assertEqual(1440, self.pending()["minutes"])

    def test_bad_field_count_is_rejected_with_a_reason(self):
        self.deliver("Q1;f;TestRealm PvP;1o")
        self.assertIsNone(self.pending())
        self.assertTrue(self.reason_logged("field count"))

    def test_foreign_game_is_rejected(self):
        self.deliver("Q1;r;TestRealm PvP;1o;abc")
        self.assertIsNone(self.pending())
        self.assertTrue(self.reason_logged("game mismatch"))

    def test_foreign_realm_is_rejected(self):
        self.deliver("Q1;f;CAMWOW EU4 Realm 6 PvP;1o;abc")
        self.assertIsNone(self.pending())
        self.assertTrue(self.reason_logged("foreign realm"))

    def test_sharing_off_is_rejected(self):
        self.db["peerEnabled"] = False
        self.deliver("Q1;f;TestRealm PvP;1o;abc")
        self.assertIsNone(self.pending())
        self.assertTrue(self.reason_logged("sharing disabled"))

    def test_non_positive_window_is_rejected(self):
        self.deliver("Q1;f;TestRealm PvP;0;abc")
        self.assertIsNone(self.pending())
        self.assertTrue(self.reason_logged("bad window"))

    def test_same_sender_cannot_ask_again_within_the_sender_gap(self):
        self.deliver("Q1;f;TestRealm PvP;1o;abc")
        self.stats["askPending"] = None
        self.lua.execute("TestClock = TestClock + 60")
        self.deliver("Q1;f;TestRealm PvP;1o;def")
        self.assertIsNone(self.pending())
        self.assertTrue(self.reason_logged("request from this sender too soon"))

    def test_another_sender_while_pending_is_counted_as_skipped(self):
        self.deliver("Q1;f;TestRealm PvP;1o;abc")
        before = self.stats["askSkipped"] or 0
        self.deliver("Q1;f;TestRealm PvP;1o;zzz", sender="PeerTwo")
        self.assertEqual(before + 1, self.stats["askSkipped"])
        # отвечаем всё равно на ПЕРВЫЙ запрос: склеивать два ответа нельзя
        self.assertEqual("abc", str(self.pending()["nonce"]))

    def test_counters_reach_saved_variables(self):
        self.deliver("Q1;f;TestRealm PvP;1o;abc")
        self.deliver("Q1;f;TestRealm PvP", sender="PeerTwo")  # отказ по полям
        peer = self.db["debug"]["peer"]
        self.assertIsNotNone(peer)
        self.assertEqual(2, peer["askReqIn"])
        self.assertEqual(1, peer["askIgnored"])
        self.assertTrue(self.globals["PeerSync"] is not None)


if __name__ == "__main__":
    unittest.main()
