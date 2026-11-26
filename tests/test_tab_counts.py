"""Число на табе обязано совпадать с числом строк в списке (Lua 5.1).

Живой случай 26.11.2026 (жалоба владельца): «в табе число отличается от списка
в обмене». Причина: табы считались по ВСЕЙ базе (63 391 запись), а список
строится из буфера последних 500. На вкладке «Обмен новые» стояло 1520, а строк
в списке было 462 — расхождение структурное, а не косметическое.

Правило: число на табе = длина списка, который откроется по клику. Проверяем не
реализацию, а инвариант: для каждого режима число равно количеству строк буфера,
проходящих фильтр этого режима (буфер ≤ 500 = предел списка, поэтому список и
есть «все подходящие строки буфера»).
"""

from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

ADDON = Path(__file__).resolve().parents[1]
SOURCE = ADDON / "NearbySpy.lua"
LOCALE = ADDON / "NearbySpy_Locale.lua"

NOW = 1795717180


def cut(src: str, a: str, b: str) -> str:
    i = src.index(a)
    j = src.index(b, i)
    return src[i:j]


def ui_block() -> str:
    """NSP_RECENT + эффективное время + отбор + TacticalVisible + NspTabCounts."""
    return cut(SOURCE.read_text(encoding="utf-8"),
               "NSP_RECENT = { list = {", "-- Relative time for the contact column")


def schema_block() -> str:
    return cut(LOCALE.read_text(encoding="utf-8"), "NSP_REC = {", "\nNSP_LOCALE = {")


STUBS = """
NSP_CONST = { MAX_ROWS = 500 }
TACTICAL_FRESH = 300
NOW = 0
time = function() return NOW end
DB = { players = {}, peerAllRealms = true }
function GetDB() return DB end
tactical = { started = 0, filter = "all" }
"""

MODES = ("all", "fresh", "new", "peern")


class TabCountTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(STUBS)
        self.lua.execute(schema_block())
        # ⚠️ Срез сам объявляет `local tactical`, поэтому глобальная заглушка его
        # НЕ перекрывает: без явного TestTactical «начало сессии» остаётся 0, и
        # любая запись проходит фильтр «Новые». Ошибка ловилась тестом.
        self.lua.execute(ui_block() + "\nTestVisible = TacticalVisible\nTestTactical = tactical\n")
        self.g = self.lua.globals()
        self.g["NOW"] = NOW
        self.g["TestTactical"]["started"] = NOW - 3600
        self.lua.execute("for _, p in pairs(DB.players) do setmetatable(p, NSP_REC.MT) end")

    # ── помощники ────────────────────────────────────────────────────────────
    def seen(self, name, last_seen, first_seen=None):
        self.lua.execute("""
        local n, ls, fs = ...
        DB.players[n] = {name = n, lastSeen = ls, firstSeen = fs or ls, source = "seen"}
        NspRecentTouch(n, DB.players[n])
        """, name, last_seen, first_seen or last_seen)

    def peer(self, name, peer_at, new=True):
        self.lua.execute("""
        local n, pa, pn = ...
        DB.players[n] = {name = n, lastSeen = 0, peerAt = pa, peerNew = pn}
        NspRecentTouch(n, DB.players[n])
        """, name, peer_at, new)

    def tab_counts(self):
        c = self.g["NspTabCounts"](NOW)
        return {m: c[m] for m in MODES}

    def buffer_match(self, mode):
        """Сколько строк буфера проходит фильтр режима — эталон для таба."""
        return self.lua.execute("""
        local mode = ...
        local n = 0
        for i = 1, #NSP_RECENT.list do
            if TestVisible(NSP_RECENT.list[i].p, NOW, mode) then n = n + 1 end
        end
        return n
        """, mode)

    # ── инвариант ────────────────────────────────────────────────────────────
    def test_every_tab_equals_its_list(self):
        for i in range(700):
            self.seen("Seen%d" % i, NOW - 100 - i)
        for i in range(700):
            self.peer("Peer%d" % i, NOW - 200 - i)
        counts = self.tab_counts()
        for mode in MODES:
            with self.subTest(mode=mode):
                self.assertEqual(
                    self.buffer_match(mode), counts[mode],
                    "таб %s: число %s не равно длине списка %s"
                    % (mode, counts[mode], self.buffer_match(mode)))

    def test_peer_tab_does_not_count_the_whole_database(self):
        """Регрессия: в базе 700 записей канала, в буфере — ни одной.

        Раньше таб показывал 700 (счёт по базе), хотя список был пуст.
        """
        # 500 свежих собственных встреч вытесняют все записи канала из буфера
        for i in range(500):
            self.seen("Seen%d" % i, NOW - 10 - i)
        for i in range(700):
            self.peer("Peer%d" % i, NOW - 1000 - i)
        self.assertEqual(0, self.tab_counts()["peern"],
                         "таб считает записи канала, которых нет в списке")
        # но сами записи из базы никуда не делись
        self.assertEqual(700, self.lua.execute("""
        local n = 0
        for _, p in pairs(DB.players) do
            if (tonumber(p.peerAt) or 0) > 0 then n = n + 1 end
        end
        return n
        """))

    def test_small_base_everything_counts(self):
        """На маленькой базе список полон, поэтому таб = число в базе."""
        for i in range(3):
            self.seen("S%d" % i, NOW - 60 - i)
        for i in range(2):
            self.peer("P%d" % i, NOW - 30 - i)
        counts = self.tab_counts()
        self.assertEqual(5, counts["all"])
        self.assertEqual(5, counts["fresh"])   # все в пределах 5 минут
        self.assertEqual(3, counts["new"])
        self.assertEqual(2, counts["peern"])
        for mode in MODES:
            self.assertEqual(self.buffer_match(mode), counts[mode])

    def test_all_tab_matches_a_full_buffer(self):
        """Буфер полон — таб «Все» показывает предел списка, а не размер базы."""
        for i in range(1200):
            self.seen("S%d" % i, NOW - 10 - i)
        counts = self.tab_counts()
        self.assertEqual(500, counts["all"],
                         "таб «Все» показывает размер базы вместо длины списка")

    def test_foreign_records_are_not_counted_when_the_flag_is_off(self):
        self.lua.execute("DB.peerAllRealms = false")
        self.peer("Local", NOW - 10)
        self.lua.execute("""
        DB.players['Foreign'] = {name = 'Foreign', lastSeen = 0, peerAt = ..., peerNew = true, peerForeign = true}
        NspRecentTouch('Foreign', DB.players['Foreign'])
        """, NOW - 20)
        counts = self.tab_counts()
        self.assertEqual(1, counts["peern"],
                         "чужая запись посчитана, хотя список её не показывает")
        self.assertEqual(self.buffer_match("peern"), counts["peern"])

    def test_counts_use_the_filter_argument_not_the_global_mode(self):
        """Счётчики считают все четыре режима за один проход."""
        for i in range(4):
            self.seen("S%d" % i, NOW - 10 - i)
        for i in range(2):
            self.peer("P%d" % i, NOW - 5 - i)
        self.g["TestTactical"]["filter"] = "peern"
        counts = self.tab_counts()
        self.assertEqual(6, counts["all"], "режим окна протёк в чужой счётчик")


if __name__ == "__main__":
    unittest.main()
