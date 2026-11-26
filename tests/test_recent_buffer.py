"""Буфер последних N записей для окна статистики (Lua 5.1, настоящий код).

Решение владельца 26.11.2026: окно показывает НЕ всю базу, а список последних
500 записей; новая запись встаёт на место по времени, хвост вытесняется.
Сортировки при показе нет вовсе.

Замеры на живом SV (61 435 записей, lupa):
    пересборка полного порядка      70–80 мс  на КАЖДЫЙ показ (до правки)
    показ из готового буфера         0.02 мс
    вставка одной записи             0.011 мс
    пересборка буфера (раз в сессию) 80 мс

Что эти тесты держат:
  - буфер совпадает с результатом полной сортировки после серии встреч,
    включая ПОВТОРНЫЕ (обновление времени у уже известного игрока);
  - размер не превышает MAX_ROWS, хвост вытесняется;
  - запись с нулевым lastSeen не попадает (это peer-only и профили без встречи);
  - массовое удаление (prune) помечает буфер негодным, и он перестраивается;
  - показ не сортирует: при готовом буфере работа — только копирование ссылок.
"""

from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

ADDON = Path(__file__).resolve().parents[1]
SOURCE = ADDON / "NearbySpy.lua"
LOCALE = ADDON / "NearbySpy_Locale.lua"


def cut(src: str, start: str, end: str) -> str:
    a = src.index(start)
    b = src.index(end, a)
    return src[a:b]


def recent_block() -> str:
    return cut(SOURCE.read_text(encoding="utf-8"),
               "NSP_RECENT = { list = {}", "\n-- ============ UI ============")


STUBS = r"""
NSP_CONST = { MAX_ROWS = 500 }
NOW = 1795705537
time = function() return NOW end
DB = { players = {} }
function GetDB() return DB end
"""


class RecentBufferTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(STUBS)
        self.lua.execute(recent_block()
                         + "\nTestTop = NspTopPlayers\nTestBase = NspBaseList\n"
                         + "TestTouch = NspRecentTouch\nTestBuild = NspRecentBuild\n"
                         + "TestInvalidate = NspRecentInvalidate\n")
        self.g = self.lua.globals()

    def touch(self, key, ts, name=None):
        """Одна встреча: запись создаётся/обновляется и встаёт в буфер."""
        self.lua.execute("""
        local k, t, nm = ...
        local e = DB.players[k]
        if not e then e = {name = nm or k}; DB.players[k] = e end
        e.lastSeen = t
        NspRecentTouch(k, e)
        """, key, ts, name or key)

    def keys(self, list_):
        return [list_[i]["name"] or list_[i].name for i in range(1, len(list_) + 1)]

    def test_starts_empty_and_builds_from_the_base(self):
        for i in range(10):
            self.g["DB"]["players"][f"P{i}"] = self.lua.table_from(
                {"name": f"P{i}", "lastSeen": 100 + i})
        base = self.g["TestBase"](self.g["DB"], "lastSeen")
        self.assertEqual(10, len(base))
        self.assertEqual("P9", base[1]["name"])

    def test_new_record_goes_to_its_place_by_time(self):
        self.touch("A", 100)
        self.touch("B", 300)
        self.touch("C", 200)
        base = self.g["TestBase"](self.g["DB"], "lastSeen")
        self.assertEqual(["B", "C", "A"], [base[i]["name"] for i in range(1, len(base) + 1)])

    def test_repeat_meeting_moves_the_record_up(self):
        self.touch("A", 100)
        self.touch("B", 200)
        self.assertEqual("B", self.g["TestBase"](self.g["DB"], "lastSeen")[1]["name"])
        self.touch("A", 300)                     # A встретили снова
        base = self.g["TestBase"](self.g["DB"], "lastSeen")
        self.assertEqual("A", base[1]["name"], "повторная встреча не подняла запись")
        self.assertEqual(2, len(base), "запись задвоилась после обновления")

    def test_size_never_exceeds_the_limit(self):
        for i in range(1200):
            self.touch(f"P{i}", 1000 + i)
        base = self.g["TestBase"](self.g["DB"], "lastSeen")
        self.assertEqual(500, len(base))
        # хвост вытесняется: в списке самые свежие
        self.assertEqual("P1199", base[1]["name"])
        names = [base[i]["name"] for i in range(1, len(base) + 1)]
        self.assertNotIn("P0", names, "самая старая запись не вытеснена")

    def test_record_without_a_meeting_is_not_shown(self):
        self.touch("Seen", 500)
        self.lua.execute("""
        local e = {name = 'PeerOnly'}; DB.players['PeerOnly'] = e
        -- lastSeen отсутствует = никогда не встречали
        NspRecentTouch('PeerOnly', e)
        """)
        base = self.g["TestBase"](self.g["DB"], "lastSeen")
        names = [base[i]["name"] for i in range(1, len(base) + 1)]
        self.assertEqual(["Seen"], names)

    def test_buffer_matches_a_full_sort_after_many_writes(self):
        """Главная проверка: инкрементальный буфер == полная сортировка."""
        import random
        random.seed(11)
        for step in range(1500):
            key = (f"P{random.randint(0, 900)}" if step % 3 else f"P{step}")
            self.touch(key, 1000 + step * 5)
        base = self.g["TestBase"](self.g["DB"], "lastSeen")
        self.lua.execute("""
        function FullSorted(db, limit)
            local all = {}
            for k, p in pairs(db.players) do
                local v = tonumber(p.lastSeen) or 0
                if v > 0 then all[#all+1] = { v = v, p = p } end
            end
            table.sort(all, function(a, b)
                if a.v == b.v then return (a.p.name or "") < (b.p.name or "") end
                return a.v > b.v
            end)
            local out = {}
            for i = 1, math.min(limit or 500, #all) do out[i] = all[i].p end
            return out
        end
        """)
        full = self.g["FullSorted"](self.g["DB"], 500)
        self.assertEqual(len(full), len(base))
        for i in range(1, len(base) + 1):
            self.assertEqual(full[i]["lastSeen"], base[i]["lastSeen"],
                             f"расхождение с полной сортировкой на позиции {i}")

    def test_invalidate_forces_a_rebuild(self):
        self.touch("A", 100)
        self.assertEqual(1, len(self.g["TestBase"](self.g["DB"], "lastSeen")))
        # имитируем prune: запись удалена из базы, буфер помечен негодным
        self.lua.execute("DB.players['A'] = nil")
        self.g["TestInvalidate"]()
        self.assertEqual(0, len(self.g["TestBase"](self.g["DB"], "lastSeen")),
                         "буфер показал удалённую запись")

    def test_peer_tab_sorts_only_the_buffer(self):
        for i in range(5):
            self.touch(f"P{i}", 100 + i)
        self.lua.execute("""
        DB.players['P0'].peerAt = 999
        DB.players['P1'].peerAt = 500
        """)
        base = self.g["TestBase"](self.g["DB"], "peerAt")
        self.assertEqual("P0", base[1]["name"], "вкладка peer не отсортирована по peerAt")


class NoSortOnShowTests(unittest.TestCase):
    """Показ не должен содержать сортировки — порядок приходит из буфера."""

    def test_base_list_does_not_sort_the_lastseen_path(self):
        src = SOURCE.read_text(encoding="utf-8")
        body = src[src.index("function NspBaseList("):
                   src.index("-- NspTopPlayers(db, key, limit, accept)")]
        code = "\n".join(line for line in body.splitlines()
                         if not line.strip().startswith("--"))
        # Ветка lastSeen обязана отдавать буфер копированием, без table.sort.
        branch = code[code.index('if key == "lastSeen" then'):code.index("local tmp = {}")]
        self.assertNotIn("table.sort", branch, "показ по времени снова сортирует")
        # Пересортировка допускается только для другого ключа (peerAt) и только
        # по буферу, а не по всей базе.
        tail = code[code.index("local tmp = {}"):]
        self.assertIn("table.sort(tmp", tail)
        self.assertNotIn("pairs(players)", tail, "вкладка peer снова идёт по всей базе")

    def test_touch_is_called_from_the_single_write_point(self):
        src = SOURCE.read_text(encoding="utf-8")
        body = src[src.index("local function UpsertPlayer(db, data)"):
                   src.index("function PeerChannelName()")]
        # Обе ветки: создание новой записи И обновление существующей.
        self.assertIn("NspRecentTouch(key, db.players[key])", body,
                      "новая запись не попадает в буфер")
        self.assertIn("NspRecentTouch(key, entry)", body,
                      "обновление записи не обновляет буфер")

    def test_prune_invalidates_the_buffer(self):
        src = SOURCE.read_text(encoding="utf-8")
        body = src[src.index("function NspPrune(db, retainDays, now)"):
                   src.index("local frame = CreateFrame(\"Frame\")")]
        self.assertIn("NspRecentInvalidate", body,
                      "после массового удаления буфер не помечается негодным")


if __name__ == "__main__":
    unittest.main()
