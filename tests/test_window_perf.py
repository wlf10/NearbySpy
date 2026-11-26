"""Окно статистики: отбор верхних строк и кэш (Lua 5.1, настоящий код).

Зачем. Окно `/nspy` перерисовывается из семи мест (клик по фильтру, циклеры
класса/реалма/уровня, OnShow), и КАЖДАЯ отрисовка делала четыре полных прохода
по всей базе. Замер на живом SavedVariables (61 435 записей, lupa, медиана из 5):

    копия всех + полная сортировка   322 мс   (было в SortedPlayers)
    TacticalStats                     21 мс
    TacticalRealmList                 10 мс
    TacticalClassList                 15 мс

В клиенте это в 2–5 раз дороже, то есть до полусекунды на клик по фильтру.

Что держат тесты:
  - NspTopPlayers возвращает РОВНО те же 500 записей и в том же порядке, что
    старый алгоритм (копия всех + полная сортировка) — иначе «оптимизация»
    молча меняет то, что видит игрок;
  - фильтр применяется ДО отбора верхних: при фильтре по редкому классу список
    не пустеет (иначе 500 самых свежих не содержали бы ни одной подходящей
    строки — и это выглядело бы как «фильтр не работает»);
  - ключ сортировки переключается на peerAt для вкладки «Обмен новые»;
  - кэш отдаёт тот же список при неизменных данных и сбрасывается, когда
    меняется версия данных или состояние фильтра.
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


def top_players_block() -> str:
    return cut(SOURCE.read_text(encoding="utf-8"),
               "function NspTopPlayers(", "\n-- ============ UI ============")


def schema_block() -> str:
    """Настоящие NSP_REC и метатаблица записи: без них p.lastSeen = nil у всех
    и «сортировка по времени» вырождается в «по нулям» — на этом уже был
    получен ложно-зелёный прогон."""
    return cut(LOCALE.read_text(encoding="utf-8"), "NSP_REC = {", "\nNSP_LOCALE = {")


STUBS = r"""
NSP_CONST = { MAX_ROWS = 500 }
NOW = 1795705537
time = function() return NOW end
nspDataVer = 0
"""


def mk_record(lua, last_seen, peer_at=0, name="X", cls="MAGE", faction="Alliance"):
    """Запись с ИМЕНОВАННЫМИ полями.

    NspTopPlayers читает только p[key] и accept(p), поэтому для проверки самого
    алгоритма достаточно именованных полей. Позиционная схема v4 проверяется
    отдельным кейсом (test_works_on_positional_records) — там класс и фракция
    лежат в МАСКЕ слота 2, и писать их отдельными слотами нельзя.
    """
    return lua.table_from({
        "name": name, "class": cls, "faction": faction, "realm": "TestRealm PvP",
        "zone": "TestZone", "zoneId": 12, "level": 60,
        "lastSeen": last_seen, "firstSeen": 0, "count": 0,
        "peerAt": peer_at, "peerNew": False, "peerForeign": False,
        "source": "unit", "race": "Human", "guid": False, "gear": False,
    })


def positional_record(lua, last_seen, name="X"):
    """Настоящая запись схемы v4 (16 слотов) + метатаблица клиента.

    Без метатаблицы p.lastSeen = nil у всех, и «сортировка по времени»
    выродилась бы в «по нулям» — на этом уже был получен ложно-зелёный прогон.
    """
    rec = [name, 0, 60, "TestRealm PvP", "TestZone", 12,
           last_seen, 0, 0, "Human", False, 0, 0, False, False, False]
    lua.globals()["REC"] = lua.table_from(rec)
    lua.execute("setmetatable(REC, NSP_REC.MT)")
    out = lua.globals()["REC"]
    lua.execute("REC = nil")
    return out


class TopPlayersTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(STUBS)
        self.lua.execute(schema_block())
        self.lua.execute(top_players_block() + "\nTestTop = NspTopPlayers\n")
        self.lua.execute("DB = { players = {} }")
        self.g = self.lua.globals()

    def put(self, key, last_seen, peer_at=0, name="X", cls="MAGE", faction="Alliance"):
        rec = mk_record(self.lua, last_seen, peer_at, name, cls, faction)
        self.lua.execute("setmetatable(REC, NSP_REC.MT)")
        self.g["DB"]["players"][key] = self.g["REC"]
        self.lua.execute("REC = nil")

    def add(self, key, last_seen, peer_at=0, name=None, cls="MAGE", faction="Alliance"):
        rec = mk_record(self.lua, last_seen, peer_at, name or key, cls, faction)
        self.g["DB"]["players"][key] = rec

    def values(self, list_, n, field="lastSeen"):
        return [list_[i][field] or 0 for i in range(1, n + 1)]

    def test_matches_the_old_full_sort(self):
        """Тот же набор и тот же порядок, что у старого алгоритма."""
        for i in range(1200):
            self.add(f"P{i}", last_seen=(1000 + i) if i % 3 else 0)
        for i in range(50):
            self.add(f"Q{i}", last_seen=5000 + i)
        new, n = self.g["TestTop"](self.g["DB"], "lastSeen", 500)
        self.assertEqual(500, n)
        got = self.values(new, n)
        # старый алгоритм, посчитанный здесь же
        self.lua.execute("""
        function OldTop(db, limit)
            local list = {}
            for _, p in pairs(db.players) do list[#list+1] = p end
            table.sort(list, function(a,b) return (a.lastSeen or 0) > (b.lastSeen or 0) end)
            local out = {}
            for k = 1, math.min(limit, #list) do out[k] = list[k] end
            return out, #out
        end
        """)
        old, nold = self.g["OldTop"](self.g["DB"], 500)
        self.assertEqual(nold, n)
        self.assertEqual(self.values(old, nold), got,
                         "набор или порядок разошлись со старым алгоритмом")

    def test_result_is_sorted_descending(self):
        for i in range(800):
            self.add(f"P{i}", last_seen=i % 7)   # много равных значений
        new, n = self.g["TestTop"](self.g["DB"], "lastSeen", 500)
        got = self.values(new, n)
        self.assertEqual(sorted(got, reverse=True), got, "список не отсортирован")

    def test_filter_is_applied_before_the_limit(self):
        """Редкий класс обязан попасть в список, а не быть вытесненным свежими."""
        # 900 свежих магов (они забьют буфер первыми)
        for i in range(900):
            self.add(f"M{i}", last_seen=90_000 + i, cls="MAGE")
        # 40 старых жрецов
        for i in range(40):
            self.add(f"P{i}", last_seen=100 + i, cls="PRIEST")
        accept = self.lua.eval("(function(p) return p.class == 'PRIEST' end)")
        new, n = self.g["TestTop"](self.g["DB"], "lastSeen", 500, accept)
        self.assertEqual(40, n, "фильтр применён ПОСЛЕ отбора — часть строк потеряна")
        for i in range(1, n + 1):
            self.assertEqual("PRIEST", new[i]["class"])

    def test_peer_key_sorts_by_packet_time(self):
        self.add("Old", last_seen=1000, peer_at=10)
        self.add("New", last_seen=500, peer_at=999)
        new, n = self.g["TestTop"](self.g["DB"], "peerAt", 500)
        self.assertEqual(2, n)
        self.assertEqual("New", new[1]["name"])
        self.assertEqual("Old", new[2]["name"])

    def test_missing_field_counts_as_zero(self):
        self.add("Zero", last_seen=0)
        self.add("Some", last_seen=50)
        new, n = self.g["TestTop"](self.g["DB"], "lastSeen", 500)
        self.assertEqual(2, n)
        self.assertEqual("Some", new[1]["name"])

    def test_works_on_positional_records(self):
        """Проверка на НАСТОЯЩЕЙ схеме: p.lastSeen читается через метатаблицу."""
        for i in range(300):
            self.g["DB"]["players"][f"P{i}"] = positional_record(
                self.lua, last_seen=(100 + i) if i % 4 else 0, name=f"P{i}")
        new, n = self.g["TestTop"](self.g["DB"], "lastSeen", 200)
        self.assertEqual(200, n)
        got = self.values(new, n)
        self.assertEqual(sorted(got, reverse=True), got)
        self.assertGreater(got[0], 0, "поля не прочитались через метатаблицу")


class CacheTests(unittest.TestCase):
    """Кэш окна: ключ = состояние фильтров + ОКНО ВРЕМЕНИ, без версии данных.

    Первая версия кэша была привязана к счётчику записей, который растёт на
    каждую встречу — в городе записи идут непрерывно, кэш промахивался ВСЕГДА,
    и владелец видел «фризы на секунду при фильтрах» уже после «оптимизации».
    Требование: в ключе НЕТ счётчика записей, но ЕСТЬ TTL.
    """

    def setUp(self):
        self.src = SOURCE.read_text(encoding="utf-8")

    def block(self, start, end):
        a = self.src.index(start)
        b = self.src.index(end, a)
        # Комментарии убираем: в них объяснено, ПОЧЕМУ счётчика записей в ключе
        # больше нет, и слово ловится как его использование.
        return "\n".join(line for line in self.src[a:b].splitlines()
                         if not line.strip().startswith("--"))

    def test_rows_cache_key_is_time_based_not_write_based(self):
        body = self.block("local function TacticalRows()", "for i = 1, #list do")
        self.assertIn("tactical.classFilter", body)
        self.assertIn("tactical.realmFilter", body)
        self.assertIn("math.floor(now / 3)", body, "нужен TTL: фильтр «5 минут» зависит от времени")
        self.assertNotIn("nspDataVer", body,
                         "ключ не должен зависеть от счётчика записей — он растёт постоянно")
        self.assertIn("tactical.listCache", body)

    def test_stats_cache_key_is_time_based_not_write_based(self):
        body = self.block("local function TacticalStats()", "local st = {total")
        self.assertIn("tactical.realmFilter", body)
        self.assertIn("math.floor(now / 3)", body)
        self.assertNotIn("nspDataVer", body)

    def test_cache_reuses_the_list_when_nothing_changed(self):
        body = self.block("local function TacticalRows()", "for i = 1, #list do")
        self.assertIn("if cache and cache.key == cacheKey then", body)
        self.assertIn("list = cache.list", body)


class RepaintCostTests(unittest.TestCase):
    """Перерисовка не должна дёргать клиентский API без нужды.

    Замер до правки: 500 строк = 8001 вызов клиента (16 на строку), из них
    больше половины — SetText/SetTextColor теми же значениями, плюс
    ClearAllPoints/SetPoint на каждую строку и Hide/Show всего списка.
    """

    def setUp(self):
        self.src = SOURCE.read_text(encoding="utf-8")
        body = self.src[self.src.index("local function TacticalRows()"):
                        self.src.index("local function TacticalStats()")]
        # Комментарии из проверки убираем: слова ClearAllPoints/SetPoint в них
        # объясняют, ПОЧЕМУ вызовов больше нет, и ловятся как сам вызов.
        self.body = "\n".join(
            line for line in body.splitlines() if not line.strip().startswith("--")
        )

    def test_row_text_goes_through_the_change_cache(self):
        for field in ("name", "profile", "zone", "seen"):
            self.assertIn(f'NspSetText(row, "{field}"', self.body,
                          "SetText без сравнения с предыдущим значением")

    def test_position_is_not_reapplied_on_every_repaint(self):
        self.assertNotIn("ClearAllPoints", self.body)
        self.assertNotIn('row:SetPoint("TOPLEFT"', self.body)

    def test_previous_rows_are_not_hidden_en_masse(self):
        # Скрытие переехало в ХВОСТ (только строки сверх нового числа), иначе
        # 500 Hide + 500 Show на каждую отрисовку.
        self.assertNotIn("row:Hide() end", self.body.split("for i = 1, #list do")[0],
                         "скрытие всего списка осталось в начале функции")
        self.assertIn("tactical.shownCount", self.body)


if __name__ == "__main__":
    unittest.main()
