"""Словарь зон и адаптивный интервал отправки (Lua 5.1, real код).

Два дефекта найдены живым прогоном 10.11.2026:

1. Словарь зон собрал 60 карт из 3000 (found=60). В базе 821 уникальная зона,
   значит первый скан захватил огрызок: на кастомном клиенте C_Map может отдать
   данные не сразу после входа. Счётчик без списка id не отвечал на вопрос,
   ЧТО именно нашлось, поэтому в диагностику добавлен sample.

2. Очередь росла до 43 записей и дошла до «queue full»: /who-скан кладёт
   десятки записей залпом, а при интервале 10 сек уходит лишь 24/мин. Теперь
   при большой очереди интервал 4 сек (60/мин), в обычной игре — 10.

Что держит файл:
  - словарь строится и находимые id попадают в диагностику;
  - при неполном словаре разрешён повторный скан, но не чаще раза в минуту;
  - полный словарь НЕ пересканируется (перебор 3000 id не бесплатный);
  - интервал отправки зависит от длины очереди;
  - при отсутствии C_Map аддон не падает и отдаёт пустой словарь.
"""

from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime


ADDON = Path(__file__).resolve().parents[1]
SOURCE = ADDON / "NearbySpy.lua"


def zone_block() -> str:
    src = SOURCE.read_text(encoding="utf-8")
    start = src.index("NSP_ZONE_BY_NAME = nil")
    end = src.index("local function Round4(v)")
    return src[start:end]


def drain_gap_block() -> str:
    """Строки, отвечающие за выбор интервала."""
    src = SOURCE.read_text(encoding="utf-8")
    start = src.index("    local nowT = time()\n    -- Адаптивный интервал")
    end = src.index("    while #peerQueue > 0", start)
    return src[start:end]


HARNESS = """
time = function() return 1794300000 end
canaccessvalue = nil
DB = {debug = {}}
function GetDB() return DB end
-- Клиент предоставляет Enum.UIMapType; в коде типы карт перебираются из него.
Enum = { UIMapType = { Cosmic = 0, World = 1, Continent = 2, Zone = 3,
                       Dungeon = 4, Micro = 5, Orphan = 6 } }
"""


class ZoneDictionaryTests(unittest.TestCase):
    def make(self, maps, with_api=True, children=None):
        """maps: {id = name} — что отдаёт фейковый C_Map.
        children: {parentId = {{mapID=, name=, mapType=}, ...}} — дерево."""
        lua = LuaRuntime(unpack_returned_tuples=True)
        entries = ", ".join("[%d] = { name = %r, mapType = 3, mapID = %d }" % (i, n, i)
                            for i, n in maps.items())
        kids = ""
        if children:
            parts = []
            for parent, lst in children.items():
                items = ", ".join(
                    "{ mapID = %d, name = %r, mapType = %d }" % (c["mapID"], c["name"], c.get("mapType", 3))
                    for c in lst)
                parts.append("[%d] = { %s }" % (parent, items))
            kids = "CHILDREN = { %s }\n" % ", ".join(parts)
        api = ("C_Map = { GetMapInfo = function(id) return ({ %s })[id] end,\n"
               "          RequestPreloadMap = function() end,\n"
               "          GetMapChildrenInfo = function(id) return (CHILDREN or {})[id] or {} end }\n" % entries
               if with_api else "C_Map = nil\n")
        lua.execute(HARNESS + kids + api + zone_block() + "\n"
                    "TestInit = ZoneMapInit\n"
                    "TestRefresh = ZoneMapRefresh\n"
                    "TestReady = ZoneMapReady\n"
                    "TestByName = ZoneIdByName\n"
                    "TestById = ZoneNameById\n"
                    "TestDbg = DB\n")
        return lua

    # --- построение --------------------------------------------------------

    def test_dictionary_maps_both_directions(self):
        lua = self.make({1420: "Elwynn Forest", 1413: "Durotar", 2665: "Zephras Isle"})
        self.assertEqual(1413, lua.globals()["TestByName"]("Durotar"))
        self.assertEqual("Zephras Isle", lua.globals()["TestById"](2665))

    # --- обход дерева ------------------------------------------------------

    def test_children_are_collected_from_the_tree(self):
        # GetMapChildrenInfo(parent, nil, true) отдаёт поддерево; карты, которых
        # нет в корневом диапазоне, должны попасть в словарь именно так
        lua = self.make(
            {1414: "Kalimdor"},
            children={1414: [
                {"mapID": 1413, "name": "Durotar"},
                {"mapID": 1412, "name": "Mulgore"},
            ]},
        )
        self.assertEqual(1413, lua.globals()["TestByName"]("Durotar"))
        self.assertEqual("Mulgore", lua.globals()["TestById"](1412))

    def test_nested_children_are_reached_when_not_pre_expanded(self):
        # если клиент вернёт только прямых детей (без allDescendants), обход
        # обязан спуститься сам — иначе микро-зоны потеряются
        lua = self.make(
            {1414: "Kalimdor"},
            children={
                1414: [{"mapID": 1413, "name": "Durotar"}],
                1413: [{"mapID": 9999, "name": "Sen'jin Village"}],
            },
        )
        self.assertEqual(9999, lua.globals()["TestByName"]("Sen'jin Village"))

    def test_tree_walk_terminates_on_a_cycle(self):
        # защита от петли в данных: клиент не должен подвесить аддон
        lua = self.make(
            {1414: "Kalimdor"},
            children={1414: [{"mapID": 1414, "name": "Kalimdor"}]},
        )
        self.assertEqual(1414, lua.globals()["TestByName"]("Kalimdor"))

    def test_roots_counter_is_reported(self):
        lua = self.make({1414: "Kalimdor", 1415: "Eastern Kingdoms"})
        lua.globals()["TestInit"]()
        self.assertEqual(2, int(lua.globals()["TestDbg"]["debug"]["zoneMap"]["roots"]))

    def test_zone_name_resolves_without_the_dictionary(self):
        # на приёме словоарь не нужен: GetMapInfo(id) отвечает напрямую
        lua = self.make({2665: "Zephras Isle"})
        self.assertEqual("Zephras Isle", lua.globals()["TestById"](2665))

    def test_map_type_is_passed_explicitly(self):
        # Blizzard сам вызывает GetMapChildrenInfo с Enum.UIMapType.Zone, а не с
        # nil. С nil клиент отдавал пустое поддерево — это и была причина
        # found=117. Проверяем, что тип доходит до API.
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute(HARNESS + """
SEEN_TYPES = {}
C_Map = {
    GetMapInfo = function(id)
        if id == 1414 then return { name = "Kalimdor", mapType = 2, mapID = 1414 } end
    end,
    RequestPreloadMap = function() end,
    GetMapChildrenInfo = function(id, mapType, all)
        SEEN_TYPES[#SEEN_TYPES + 1] = tostring(mapType)
        if mapType == 3 then return { { mapID = 1413, name = "Durotar", mapType = 3 } } end
        return {}
    end,
}
""" + zone_block() + "\nTestInit = ZoneMapInit\nTestSeen = SEEN_TYPES\n")
        lua.globals()["TestInit"]()
        seen = lua.globals()["TestSeen"]
        vals = [str(seen[i]) for i in range(1, len(seen) + 1)]
        self.assertTrue(vals, "GetMapChildrenInfo вообще не вызывался")
        self.assertFalse(all(v == "nil" for v in vals),
                         "тип карты ни разу не передан: %s" % vals)
        # и тип Zone (3) обязан быть среди запрошенных
        self.assertIn("3", vals, "Enum.UIMapType.Zone не запрашивался: %s" % vals)

    def test_preload_is_requested_for_roots(self):
        # карты грузятся по требованию: без RequestPreloadMap поддерево пустое
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute(HARNESS + """
PRELOADED = {}
C_Map = {
    GetMapInfo = function(id)
        if id == 1414 then return { name = "Kalimdor", mapType = 2, mapID = 1414 } end
    end,
    RequestPreloadMap = function(id) PRELOADED[#PRELOADED + 1] = id end,
    GetMapChildrenInfo = function() return {} end,
}
""" + zone_block() + "\nTestInit = ZoneMapInit\nTestPre = PRELOADED\n")
        lua.globals()["TestInit"]()
        pre = lua.globals()["TestPre"]
        vals = [int(pre[i]) for i in range(1, len(pre) + 1)]
        self.assertIn(1414, vals, "preload не запрошен для корневой карты: %s" % vals)

    def test_diagnostic_reports_enum_and_preload_availability(self):
        lua = self.make({1414: "Kalimdor"})
        lua.globals()["TestInit"]()
        dbg = lua.globals()["TestDbg"]["debug"]["zoneMap"]
        self.assertTrue(bool(dbg["hasPreload"]))
        self.assertTrue(bool(dbg["hasEnum"]))
        types = [str(dbg["types"][i]) for i in range(1, len(dbg["types"]) + 1)]
        self.assertIn("3", types, "тип Zone не попал в диагностику: %s" % types)

    def test_diagnostic_records_which_ids_were_found(self):
        # именно этой информации не хватало: found=60 без списка — непонятно,
        # покрыт словарь частично или скан прошёл слишком рано
        lua = self.make({1420: "Elwynn Forest", 1413: "Durotar"})
        lua.globals()["TestInit"]()
        dbg = lua.globals()["TestDbg"]["debug"]["zoneMap"]
        self.assertEqual(2, int(dbg["found"]))
        sample = [str(dbg["sample"][i]) for i in range(1, len(dbg["sample"]) + 1)]
        self.assertTrue(any("1420=" in s for s in sample), sample)

    def test_unknown_name_returns_nil(self):
        lua = self.make({1420: "Elwynn Forest"})
        self.assertIsNone(lua.globals()["TestByName"]("Нет такой зоны"))

    def test_unknown_id_returns_nil(self):
        lua = self.make({1420: "Elwynn Forest"})
        self.assertIsNone(lua.globals()["TestById"](999999))

    def test_missing_api_gives_empty_dictionary_without_crash(self):
        lua = self.make({}, with_api=False)
        self.assertIsNone(lua.globals()["TestByName"]("Elwynn Forest"))
        self.assertFalse(bool(lua.globals()["TestReady"]()))

    # --- пересканирование --------------------------------------------------

    def test_incomplete_dictionary_is_refreshed(self):
        # первый скан дал огрызок (2 карты < порога), второй — полный
        lua = self.make({1420: "Elwynn Forest", 1413: "Durotar"})
        lua.globals()["TestInit"]()
        self.assertFalse(bool(lua.globals()["TestReady"]()),
                         "2 карты не должны считаться полным словарём")
        # имитируем «клиент догрузился»: подменяем API на полный
        lua.execute('C_Map.GetMapInfo = function(id) if id == 1519 then '
                    'return { name = "Stormwind", mapType = 3, mapID = 1519 } end end')
        lua.globals()["TestRefresh"]()
        self.assertEqual(1519, lua.globals()["TestByName"]("Stormwind"),
                         "повторный скан не подхватил догруженную карту")

    def test_refresh_is_rate_limited(self):
        # второй вызов в ту же секунду не пересканирует: 3000 id не бесплатны
        lua = self.make({1420: "Elwynn Forest"})
        lua.globals()["TestInit"]()
        lua.globals()["TestRefresh"]()
        before = int(lua.globals()["TestDbg"]["debug"]["zoneMap"]["found"])
        lua.execute('C_Map.GetMapInfo = function(id) if id == 1519 then '
                    'return { name = "Stormwind", mapType = 3, mapID = 1519 } end end')
        lua.globals()["TestRefresh"]()   # в ту же секунду — должен быть пропущен
        self.assertIsNone(lua.globals()["TestByName"]("Stormwind"))


class AdaptiveGapTests(unittest.TestCase):
    def gap_for(self, queue_len):
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute(
            "PEER_GAP, PEER_GAP_BUSY, PEER_BUSY_LEN = 10, 4, 20\n"
            "time = function() return 1794300000 end\n"
            "peerStats = { lastSend = 0 }\n"
            "peerQueue = {}\n"
            "for i = 1, " + str(queue_len) + " do peerQueue[i] = {} end\n"
            "work = function()\n" + drain_gap_block() + "\nreturn gap end\n")
        return int(lua.globals()["work"]())

    def test_small_queue_uses_the_normal_gap(self):
        self.assertEqual(10, self.gap_for(1))

    def test_full_queue_sends_faster(self):
        # /who-скан выдаёт десятки записей залпом; при 10 сек уходит лишь 24/мин
        self.assertEqual(4, self.gap_for(25))


if __name__ == "__main__":
    unittest.main()
