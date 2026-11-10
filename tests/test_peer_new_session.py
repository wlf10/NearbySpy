"""Вкладка "Peer new": только текущая сессия (Lua 5.1, real TacticalVisible).

peerNew и peerAt лежат в SavedVariables и переживают релог, поэтому фильтр
без отсечки по tactical.started показывал ВСЕ записи канала за всё время:
на живом файле 10.11.2026 это было 1451 строка за 19 часов. Список назывался
"новые", а под ним лежали чужие находки недельной давности.

Та же ошибка была у фильтра "new" (свои находки) — он проверял
firstSeen >= tactical.started и потому вёл себя правильно.

Что держит файл:
  - "Peer new" показывает только записи, пришедшие после старта сессии;
  - "Peer" (без new) по-прежнему показывает всё, что канал принёс — он для
    этого и нужен после релога;
  - запись, пришедшая до старта сессии, не попадает в "Peer new", даже если
    у неё peerNew = true.
"""

from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

from nsp_helpers import CONST_PRELUDE

SOURCE = Path(__file__).resolve().parents[1] / "NearbySpy.lua"

# Старт сессии в тесте. Значение РЕАЛЬНОЕ (как time() в игре), а не 1000:
# при маленьком числе "прошлая сессия" (start - 3600) уходила в минус, и
# защита `peerAt > 0` справедливо выбрасывала строку — тест падал не из-за
# продукта, а из-за неправдоподобной метки времени.
SESSION_START = 1_794_000_000


class PeerNewSessionTests(unittest.TestCase):
    def setUp(self):
        source = SOURCE.read_text(encoding="utf-8")
        start = source.index("local tactical = {rows = {")
        end = source.index("-- Relative time for the contact column")
        block = source[start:end]
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(
            CONST_PRELUDE + "\n"
            "time = function() return %d end\n" % SESSION_START
            + "ALL_REALMS = true\n"
            "DB = {players = {}}\n"
            "function GetDB() return DB end\n"
            + block + "\n"
            "TestVisible = TacticalVisible\n"
            "TestStat = tactical\n"
        )

    def visible(self, player, filt):
        stats = self.lua.globals()["TestStat"]
        stats["filter"] = filt
        return self.lua.globals()["TestVisible"](self.lua.table_from(player),
                                                 SESSION_START)

    # --- собственно дефект -------------------------------------------------

    def test_peer_new_from_a_previous_session_is_hidden(self):
        # пришло вчера, было новым тогда — в сегодняшней сессии его быть не должно
        old = {"peerAt": SESSION_START - 3600, "peerNew": True}
        self.assertFalse(self.visible(old, "peern"),
                         "запись прошлой сессии попала во вкладку Peer new")

    def test_peer_new_from_this_session_is_shown(self):
        fresh = {"peerAt": SESSION_START + 5, "peerNew": True}
        self.assertTrue(self.visible(fresh, "peern"))

    def test_peer_new_exactly_at_session_start_counts(self):
        edge = {"peerAt": SESSION_START, "peerNew": True}
        self.assertTrue(self.visible(edge, "peern"))

    # --- соседние фильтры не должны измениться ----------------------------

    def test_peer_filter_still_shows_everything_the_channel_delivered(self):
        # "Peer" — это всё, что канал принёс, в том числе из прошлых сессий:
        # после релога именно он отвечает "что мне присылали"
        old = {"peerAt": SESSION_START - 3600, "peerNew": True}
        self.assertTrue(self.visible(old, "peer"))

    def test_peer_new_still_requires_the_new_flag(self):
        # пришло сейчас, но игрока мы уже знали — это не "new", а обновление
        upd = {"peerAt": SESSION_START + 5}
        self.assertFalse(self.visible(upd, "peern"))
        self.assertTrue(self.visible(upd, "peer"))

    def test_own_new_filter_is_unaffected(self):
        own = {"firstSeen": SESSION_START + 5, "source": "who"}
        self.assertTrue(self.visible(own, "new"))
        old_own = {"firstSeen": SESSION_START - 3600, "source": "who"}
        self.assertFalse(self.visible(old_own, "new"))


if __name__ == "__main__":
    unittest.main()
