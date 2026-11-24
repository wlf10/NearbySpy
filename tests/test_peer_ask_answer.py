"""Запрос базы у пиров: ответ на Q1 (Lua 5.1, настоящий код очередей).

Отвечающий обязан отдать ВЕРХУШКУ своих встреч за окно, а не всю базу: канал
держит ~10 сообщений в минуту, значит 15 записей встречами и до 5 снапшотов
экипировки. Здесь проверяется именно отбор и порядок, а не транспорт:

  - в ответ попадают только СВОИ встречи в окне (`lastSeen` в пределах window,
    `source ~= "peer"`), отсортированные от свежих к старым;
  - профильные строки без встречи (ростер, `lastSeen = 0`) и peer-строки не
    уходят — иначе канал превращается в релей чужих данных;
  - записей не больше ASK_ROWS, снапшотов не больше ASK_GEAR;
  - снапшот берётся только свой (`snap.from` не пересылается) и встаёт в
    очередь ПОСЛЕ своей записи о встрече (`afterKey`), иначе получатель отбросит
    его в orphan — у него ещё нет строки;
  - координаты в ответе не отправляются: в базе у /who-строк это точка
    наблюдателя, а не игрока;
  - ключ дедупа привязан к nonce запроса, поэтому второй запрос по тому же
    игроку уходит снова (правило «одна запись за сессию» его бы заблокировало);
  - два ответа подряд канал не получает (ASK_GAP), а `peer gear off` не мешает
    уйти встречам.
"""

from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

from nsp_helpers import lua_fields, peer_module


SOURCE = Path(__file__).resolve().parents[1] / "NearbySpy.lua"
NOW = 1_000_000


class PeerAskAnswerTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.db = peer_module(self.lua)
        self.globals = self.lua.globals()
        self.queue = self.globals["TestPeerQueue"]
        self.stats = self.globals["TestPeerStats"]

    # --- helpers -------------------------------------------------------
    def add_player(self, key, last_seen, source="who", gear=None, **extra):
        entry = {
            "name": key.split("-")[0],
            "realm": "TestRealm PvP",
            "class": "MAGE",
            "level": 60,
            "race": "Human",
            "faction": "Alliance",
            "zone": "TestZone",
            "zoneId": 12,
            "lastSeen": last_seen,
            "source": source,
        }
        entry.update(extra)
        if gear is not None:
            # Снапшот обязан быть lua-таблицей: python-dict приезжает в чанк
            # как userdata, и `type(snap) == "table"` в коде ответа молча
            # отключает отправку — тест проверял бы несуществующую ветку.
            entry["gear"] = self.lua.table_from(gear)
        self.db["players"][key] = self.lua.table_from(entry)
        return entry

    def request_from_peer(self, minutes=60, sender="PeerGuy"):
        """Собрать настоящий Q1 настоящим кодом и скормить его приёму."""
        ok, payload = self.globals["PeerAskSend"](self.db, minutes)
        self.assertTrue(ok, payload)
        payload = str(payload)
        # запрос, который мы сами поставили, из очереди убираем: он не должен
        # попасть в проверки «что ушло в ответ».
        self.globals["TestPeerReset"]()
        self.globals["ReceivePeerAsk"](lua_fields(self.lua, payload), sender)
        return payload.split(";")

    def answer(self):
        return self.globals["PeerAnswerDue"](self.db)

    def rows(self):
        out = []
        for i in range(1, len(self.queue) + 1):
            item = self.queue[i]
            if item["raw"] is None:
                out.append(item)
        return out

    # --- tests ---------------------------------------------------------
    def test_only_own_sightings_inside_the_window_are_answered(self):
        self.add_player("Fresh-Home", NOW - 60)
        self.add_player("Old-Home", NOW - 7200)          # вне окна 60 минут
        self.add_player("FromPeer-Home", NOW - 30, source="peer")
        self.add_player("RosterOnly-Home", 0)            # профиль без встречи
        self.request_from_peer(60)
        self.lua.execute("TestClock = TestClock + 1")
        self.assertTrue(self.answer())
        names = {str(r["name"]) for r in self.rows()}
        self.assertEqual({"Fresh"}, names)

    def test_rows_are_sorted_newest_first(self):
        self.add_player("A-Home", NOW - 600)
        self.add_player("B-Home", NOW - 60)
        self.add_player("C-Home", NOW - 1800)
        self.request_from_peer(60)
        self.lua.execute("TestClock = TestClock + 1")
        self.answer()
        self.assertEqual(["B", "A", "C"], [str(r["name"]) for r in self.rows()])

    def test_answer_is_capped_at_ask_rows(self):
        for i in range(20):
            self.add_player(f"P{i:02d}-Home", NOW - 10 - i)
        self.request_from_peer(60)
        self.lua.execute("TestClock = TestClock + 1")
        self.answer()
        self.assertEqual(15, len(self.rows()))
        # отдаём САМЫЕ свежие, а не первые попавшиеся
        self.assertEqual("P00", str(self.rows()[0]["name"]))

    def test_coordinates_are_never_sent(self):
        self.add_player("Coord-Home", NOW - 60, x=0.4, y=0.6)
        self.request_from_peer(60)
        self.lua.execute("TestClock = TestClock + 1")
        self.answer()
        rec = str(self.rows()[0]["rec"])
        parts = rec.split(";")
        self.assertEqual("-", parts[6], rec)
        self.assertEqual("-", parts[7], rec)

    def test_answer_key_is_bound_to_the_request_nonce(self):
        self.add_player("Once-Home", NOW - 60)
        self.request_from_peer(60)
        self.lua.execute("TestClock = TestClock + 1")
        self.answer()
        first_key = str(self.rows()[0]["key"])
        self.assertIn("|a", first_key)
        # тот же игрок в следующем запросе уходит снова: ключ другой nonce
        self.lua.execute("TestClock = TestClock + 400")
        self.globals["TestPeerReset"]()
        # другой отправитель: иначе ответ отбил бы ASK_SENDER_GAP (600 с), и
        # проверялся бы не nonce, а чужой гейт
        self.request_from_peer(60, sender="PeerTwo")
        self.lua.execute("TestClock = TestClock + 1")
        self.answer()
        second_key = str(self.rows()[0]["key"])
        self.assertNotEqual(first_key, second_key)

    def test_own_gear_snapshot_follows_its_encounter_row(self):
        self.add_player("Gear-Home", NOW - 60,
                        gear={"ids": "1:100,2:200", "at": NOW - 60, "ilvl": 60})
        self.request_from_peer(60)
        self.lua.execute("TestClock = TestClock + 1")
        self.answer()
        gear_q = self.stats["gearQueue"]
        self.assertEqual(1, len(gear_q))
        entry = gear_q[1]
        enc_key = str(self.rows()[0]["key"])
        self.assertEqual(enc_key, str(entry["afterKey"]))
        self.assertEqual("Gear", str(entry["name"]))

    def test_peer_snapshot_is_never_relayed(self):
        self.add_player("Relay-Home", NOW - 60,
                        gear={"ids": "1:100", "at": NOW - 40, "from": "PeerGuy"})
        self.request_from_peer(60)
        self.lua.execute("TestClock = TestClock + 1")
        self.answer()
        self.assertEqual(1, len(self.rows()))
        self.assertEqual(0, len(self.stats["gearQueue"]))

    def test_gear_off_still_answers_encounters(self):
        self.db["peerGearOff"] = True
        self.add_player("NoGear-Home", NOW - 60,
                        gear={"ids": "1:100", "at": NOW - 60})
        self.request_from_peer(60)
        self.lua.execute("TestClock = TestClock + 1")
        self.answer()
        self.assertEqual(1, len(self.rows()))
        self.assertEqual(0, len(self.stats["gearQueue"]))

    def test_second_answer_within_gap_is_skipped(self):
        self.add_player("Gap-Home", NOW - 60)
        self.request_from_peer(60)
        self.lua.execute("TestClock = TestClock + 1")
        self.answer()
        self.globals["TestPeerReset"]()
        before = self.stats["askSkipped"]
        # второй запрос через 60 с: канал только что отвечал, ждём ASK_GAP
        self.lua.execute("TestClock = TestClock + 60")
        self.globals["ReceivePeerAsk"](
            lua_fields(self.lua, "Q1;1o;zz"), "PeerTwo")
        self.lua.execute("TestClock = TestClock + 1")
        self.assertFalse(self.answer())
        self.assertEqual(0, len(self.rows()))
        self.assertEqual(before + 1, self.stats["askSkipped"])

    def test_empty_window_is_counted_not_silent(self):
        self.add_player("Old-Home", NOW - 7200)
        self.request_from_peer(60)
        self.lua.execute("TestClock = TestClock + 1")
        self.assertFalse(self.answer())
        self.assertEqual(1, self.stats["askEmpty"])


if __name__ == "__main__":
    unittest.main()
