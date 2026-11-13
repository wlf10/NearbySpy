"""Сбор данных мира: вендоры и рыбалка — Lua 5.1.

Блок коллекторов вынимается из NearbySpy.lua по маркерам и исполняется в
настоящем Lua 5.1 (lupa) с моками клиентского API. Моки повторяют то, что
проба сняла с живого клиента 1.60.1: GetItemInfo и GetMerchantItemInfo
отсутствуют, есть C_Item.* и GetMerchantItemID.

Проверяется поведение, а не реализация: itemID берётся из GetMerchantItemID,
классы числовые из GetItemInfoInstant, обычный лут с трупов в базу не идёт,
лимиты держат размер SV, повторный визит не дублирует позиции.
"""

from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

SOURCE = Path(__file__).resolve().parents[1] / "NearbySpy.lua"
START = "-- ============ world data: vendors and fishing"
END = "-- localized class name -> file key"


def collectors_block() -> str:
    src = SOURCE.read_text(encoding="utf-8")
    i = src.index(START)
    j = src.index(END, i)
    return src[i:j]


def nkeys(tbl) -> int:
    """Число ключей Lua-таблицы.

    Встроенный len() в lupa отдаёт оператор #, то есть только массивную часть:
    у таблицы со строковыми ключами он всегда 0. Считаем ключи итерацией.
    """
    return len(list(tbl))


PRELUDE = """
local DB = { debug = {} }
function GetDB() return DB end
local t = 1794000000
function time() t = t + 1 return t end
local ZONE, ZONEID = "Stormwind City", 1519
function PlayerZone() return ZONE end
function PlayerZoneId() return ZONEID end
local ERRS = {}
function DbgErr(src, err) ERRS[#ERRS + 1] = tostring(src) .. ": " .. tostring(err) end
function SetZone(name, id) ZONE, ZONEID = name, id end
local function Round4(v) return math.floor(v * 10000 + 0.5) / 10000 end
local PLAYER_X, PLAYER_Y = 0.5, 0.5
-- PLAYER_XY_OFF — «клиент не даёт и позицию игрока»: коллектор тогда обязан
-- оставить координаты пустыми, а не выдумать 0/0
function PlayerXY()
    if PLAYER_XY_OFF then return nil, nil end
    return PLAYER_X, PLAYER_Y
end
function SetPlayerXY(x, y) PLAYER_X, PLAYER_Y = x, y end
-- Карта: по умолчанию отдаёт позицию NPC. Стабы условные — тест может
-- задать свой C_Map/MAP_STRICT, и prelude их не перезапишет.
if MAP_STRICT == nil then MAP_STRICT = false end
if C_Map == nil then
    C_Map = {
        GetBestMapForUnit = function(unit) return 1519 end,
        GetPlayerMapPosition = function(mapID, unit)
            if MAP_STRICT then return nil end
            if unit == "npc" then return {GetXY = function() return 0.6183, 0.4271 end} end
            return {GetXY = function() return 0.5, 0.5 end}
        end,
    }
end
"""


def classes_lua() -> str:
    """Мини-справочник предметов в том виде, в каком его отдаёт C_Item."""
    return """
    local ITEMS = {
        [159]   = {name="Освежающая ключевая вода", class="Расходуемые",   cid=0, sid=5, q=1, st=20},
        [2678]  = {name="Пряные травы",             class="Реагенты",      cid=7, sid=11, q=1, st=10},
        [18253] = {name="Рецепт: мощное зелье",     class="Рецепты",       cid=9, sid=6, q=2, st=1},
    }
    C_Item = {
        GetItemInfoInstant = function(id)
            local it = ITEMS[id]
            if not it then return nil end
            return id, it.class, "Archaeology", "INVTYPE_NON_EQUIP", "134939", it.cid, it.sid
        end,
        GetItemNameByID = function(id)
            local it = ITEMS[id]
            return it and it.name or nil
        end,
        GetItemInfo = function(id)
            local it = ITEMS[id]
            if not it then return nil end
            return it.name, "|Hitem:" .. id .. ":0|h[" .. it.name .. "]|h", it.q, 20, 1,
                   it.class, "Archaeology", it.st, "INVTYPE_NON_EQUIP", "134939"
        end,
    }
    """


class CollectTest(unittest.TestCase):
    def load(self, extra: str = "", store: str = None):
        lua = LuaRuntime(unpack_returned_tuples=True)
        chunk = (
            PRELUDE
            + collectors_block()
            + "\nreturn {vendor=WR.CollectVendor, fishing=WR.CollectFishing, counts=WR.Counts,"
              " item=WR.Item, price=WR.Price, db=DB, errors=ERRS,"
              " caps={v=WORLD_LIM.vendors, per=WORLD_LIM.perVendor,"
              " total=WORLD_LIM.items, fish=WORLD_LIM.fish}}\n"
        )
        mod = lua.execute(classes_lua() + (extra or "") + "\n" + chunk)
        return lua, mod

    # --- вендоры -----------------------------------------------------------
    def test_vendor_snapshot_records_name_class_and_price(self):
        lua, mod = self.load(
            """
            UnitGUID = function(unit) return "Creature-0-7088-2991-2-251905-BE0B212834" end
            UnitName = function(unit) return "Зеррил Нежный Ветерок" end
            GetMerchantNumItems = function() return 3 end
            GetMerchantItemID = function(i) return ({159, 2678, 18253})[i] end
            GetMerchantItemMaxStack = function(i) return 5 end
            MerchantItem1MoneyFrame = {GetMoney = function() return 1 end}
            MerchantItem2MoneyFrame = {GetMoney = function() return 400 end}
            MerchantItem3MoneyFrame = {GetMoney = function() return 25000 end}
            """
        )
        mod["vendor"]()
        vendors = mod["db"]["world"]["vendors"]
        self.assertEqual(nkeys(vendors), 1)
        v = vendors["Creature-0-7088-2991-2-251905-BE0B212834"]
        self.assertEqual(str(v["n"]), "Зеррил Нежный Ветерок")
        self.assertEqual(int(v["z"]), 1519)
        self.assertEqual(int(v["seen"]), 1)
        items = v["items"]
        self.assertEqual(nkeys(items), 3)
        recipe = items[18253]
        self.assertEqual(int(recipe["c"]), 9)      # classID рецепта
        self.assertEqual(int(recipe["q"]), 2)
        self.assertEqual(str(recipe["n"]), "Рецепт: мощное зелье")
        self.assertEqual(int(recipe["p"]), 25000)  # цена в меди
        self.assertEqual(int(items[159]["p"]), 1)

    def test_vendor_repeat_visit_does_not_duplicate(self):
        lua, mod = self.load(
            """
            UnitGUID = function() return "Creature-1" end
            UnitName = function() return "Vendor" end
            GetMerchantNumItems = function() return 2 end
            GetMerchantItemID = function(i) return ({159, 2678})[i] end
            MerchantItem1MoneyFrame = {GetMoney = function() return 1 end}
            MerchantItem2MoneyFrame = {GetMoney = function() return 400 end}
            """
        )
        mod["vendor"]()
        mod["vendor"]()
        v = mod["db"]["world"]["vendors"]["Creature-1"]
        self.assertEqual(nkeys(v["items"]), 2)
        self.assertEqual(int(v["seen"]), 2)
        self.assertEqual(int(v["items"][159]["seen"]), 2)

    def test_vendor_key_falls_back_to_name_and_zone(self):
        lua, mod = self.load(
            """
            UnitGUID = function() error("no guid for npc") end
            UnitName = function() return "Бродячий торговец" end
            GetMerchantNumItems = function() return 1 end
            GetMerchantItemID = function() return 159 end
            """
        )
        mod["vendor"]()
        vendors = mod["db"]["world"]["vendors"]
        self.assertEqual(nkeys(vendors), 1)
        self.assertIn("Бродячий торговец@1519", list(vendors.keys())[0])

    def test_missing_price_is_not_invented(self):
        lua, mod = self.load(
            """
            UnitGUID = function() return "Creature-2" end
            UnitName = function() return "Vendor" end
            GetMerchantNumItems = function() return 1 end
            GetMerchantItemID = function() return 159 end
            """
        )
        mod["vendor"]()
        item = mod["db"]["world"]["vendors"]["Creature-2"]["items"][159]
        self.assertIsNone(item["p"])  # ни MoneyFrame, ни C_MerchantFrame — цена пустая

    def test_price_from_c_merchantframe_when_moneyframe_absent(self):
        """Цена берётся из таблицы C_MerchantFrame.GetItemInfo.

        Регрессия с живой игры 08.11.2026: клиент 1.60.1 возвращает ОДНУ
        таблицу {name, price, stackCount, ...}, а код читал позиционные
        возвраты — цен не было ни у одной позиции.
        """
        lua, mod = self.load(
            """
            UnitGUID = function() return "Creature-3" end
            UnitName = function() return "Vendor" end
            GetMerchantNumItems = function() return 1 end
            GetMerchantItemID = function() return 159 end
            C_MerchantFrame = {GetItemInfo = function(i)
                return {name = "Освежающая ключевая вода", price = 25,
                        stackCount = 5, numAvailable = -1, isPurchasable = true}
            end}
            """
        )
        mod["vendor"]()
        item = mod["db"]["world"]["vendors"]["Creature-3"]["items"][159]
        self.assertEqual(int(item["p"]), 25)
        # цена относится к лоту покупки — размер лота нужен для цены за штуку
        self.assertEqual(int(item["bs"]), 5)

    def test_price_survives_client_refusal(self):
        """Отказ клиента в GetItemInfo не должен ломать снимок позиции."""
        lua, mod = self.load(
            """
            UnitGUID = function() return "Creature-4" end
            UnitName = function() return "Vendor" end
            GetMerchantNumItems = function() return 1 end
            GetMerchantItemID = function() return 159 end
            C_MerchantFrame = {GetItemInfo = function(i) error("client gate") end}
            """
        )
        mod["vendor"]()
        item = mod["db"]["world"]["vendors"]["Creature-4"]["items"][159]
        self.assertIsNone(item["p"])
        self.assertEqual(int(item["id"]), 159)

    def test_free_item_keeps_price_empty(self):
        """price = 0 не пишем: это «нет данных», иначе цена за штуку станет нулевой."""
        lua, mod = self.load(
            """
            UnitGUID = function() return "Creature-5" end
            UnitName = function() return "Vendor" end
            GetMerchantNumItems = function() return 1 end
            GetMerchantItemID = function() return 159 end
            C_MerchantFrame = {GetItemInfo = function(i)
                return {name = "X", price = 0, stackCount = 1}
            end}
            """
        )
        mod["vendor"]()
        item = mod["db"]["world"]["vendors"]["Creature-5"]["items"][159]
        self.assertIsNone(item["p"])

    # --- рыбалка ----------------------------------------------------------
    def test_fishing_loot_is_recorded_per_zone(self):
        lua, mod = self.load(
            """
            IsFishingLoot = function() return true end
            GetNumLootItems = function() return 1 end
            GetLootSlotLink = function(i) return "|cnIQ1:|Hitem:6291::::::::8:1484|h[Сырая блестящая рыбка]|h|r" end
            """
        )
        mod["fishing"]()
        mod["fishing"]()
        fish = mod["db"]["world"]["fish"]
        self.assertEqual(nkeys(fish), 1)
        row = fish["1519:6291"]
        self.assertEqual(int(row["cnt"]), 2)
        self.assertEqual(int(row["z"]), 1519)
        self.assertEqual(str(row["zn"]), "Stormwind City")

    def test_corpse_loot_is_ignored(self):
        lua, mod = self.load(
            """
            IsFishingLoot = function() return false end
            GetNumLootItems = function() return 3 end
            GetLootSlotLink = function(i) return "|Hitem:" .. i .. ":0|h[x]|h" end
            """
        )
        mod["fishing"]()
        self.assertIsNone(mod["db"]["world"])

    def test_is_fishing_loot_error_is_survivable(self):
        lua, mod = self.load(
            """
            IsFishingLoot = function() error("secret value") end
            GetNumLootItems = function() return 1 end
            """
        )
        mod["fishing"]()  # не должно бросить наружу
        self.assertIsNone(mod["db"]["world"])

    def test_loot_without_link_is_skipped(self):
        lua, mod = self.load(
            """
            IsFishingLoot = function() return true end
            GetNumLootItems = function() return 2 end
            GetLootSlotLink = function(i) if i == 2 then return nil end return "|Hitem:6289:0|h[x]|h" end
            """
        )
        mod["fishing"]()
        fish = mod["db"]["world"]["fish"]
        self.assertEqual(nkeys(fish), 1)
        self.assertEqual(int(fish["1519:6289"]["cnt"]), 1)

    def test_same_item_in_two_zones_are_separate_rows(self):
        lua, mod = self.load(
            """
            IsFishingLoot = function() return true end
            GetNumLootItems = function() return 1 end
            GetLootSlotLink = function() return "|Hitem:6291:0|h[x]|h" end
            """
        )
        mod["fishing"]()
        lua.execute('SetZone("Durotar", 1411)')
        mod["fishing"]()
        fish = mod["db"]["world"]["fish"]
        self.assertEqual(nkeys(fish), 2)

    # --- лимиты -----------------------------------------------------------
    def test_vendor_cap_is_enforced(self):
        lua, mod = self.load(
            """
            UnitGUID = function() return "Creature-" .. tostring(math.random(1, 1e6)) end
            UnitName = function() return "Vendor" end
            GetMerchantNumItems = function() return 1 end
            GetMerchantItemID = function() return 159 end
            """
        )
        lua.execute("math.randomseed(7)")
        for _ in range(310):
            mod["vendor"]()
        vendors = mod["db"]["world"]["vendors"]
        caps = mod["caps"]
        self.assertLessEqual(nkeys(vendors), int(caps["v"]))
        self.assertGreaterEqual(int(mod["db"]["debug"]["vendorsDropped"]), 1)

    def test_fishing_cap_is_enforced(self):
        lua, mod = self.load(
            """
            IsFishingLoot = function() return true end
            GetNumLootItems = function() return 1 end
            GetLootSlotLink = function() return "|Hitem:" .. tostring(math.random(1, 1e9)) .. ":0|h[x]|h" end
            """
        )
        lua.execute("math.randomseed(11)")
        for _ in range(3010):
            mod["fishing"]()
        fish = mod["db"]["world"]["fish"]
        self.assertLessEqual(nkeys(fish), int(mod["caps"]["fish"]))
        self.assertGreaterEqual(int(mod["db"]["debug"]["fishDropped"]), 1)

    def test_counts_reports_three_numbers(self):
        lua, mod = self.load(
            """
            UnitGUID = function() return "Creature-9" end
            UnitName = function() return "Vendor" end
            GetMerchantNumItems = function() return 2 end
            GetMerchantItemID = function(i) return ({159, 2678})[i] end
            IsFishingLoot = function() return true end
            GetNumLootItems = function() return 1 end
            GetLootSlotLink = function() return "|Hitem:6291:0|h[x]|h" end
            """
        )
        mod["vendor"]()
        mod["fishing"]()
        vendors, items, fish, mc_new = mod["counts"]()
        self.assertEqual((int(vendors), int(items), int(fish)), (1, 2, 1))
        # четвёртое значение — счётчик торговцев, которых нет в базе MasterCraft
        self.assertEqual(0, int(mc_new), "без снимка MasterCraft счётчик остаётся нулевым")

    def test_world_item_without_c_item_returns_id_only(self):
        lua, mod = self.load("C_Item = nil")
        out = mod["item"](159)
        self.assertEqual(int(out["id"]), 159)
        self.assertIsNone(out["n"])


class CoordinatesTest(unittest.TestCase):
    """Координаты: точка вендора и точка лова (0..1, как у игроков)."""

    def load(self, extra: str = ""):
        lua = LuaRuntime(unpack_returned_tuples=True)
        chunk = (
            PRELUDE
            + collectors_block()
            + "\nreturn {vendor=WR.CollectVendor, fishing=WR.CollectFishing, db=DB,"
              " setPlayer=SetPlayerXY}\n"
        )
        mod = lua.execute(classes_lua() + (extra or "") + "\n" + chunk)
        return lua, mod

    def test_vendor_gets_its_own_position(self):
        lua, mod = self.load(
            """
            UnitGUID = function() return "Creature-1" end
            UnitName = function() return "Vendor" end
            GetMerchantNumItems = function() return 1 end
            GetMerchantItemID = function() return 159 end
            """
        )
        mod["vendor"]()
        v = mod["db"]["world"]["vendors"]["Creature-1"]
        # позиция NPC, не игрока (игрок стоит в 0.5/0.5)
        self.assertAlmostEqual(float(v["x"]), 0.6183, places=4)
        self.assertAlmostEqual(float(v["y"]), 0.4271, places=4)

    def test_vendor_falls_back_to_player_position(self):
        lua, mod = self.load(
            """
            MAP_STRICT = true
            UnitGUID = function() return "Creature-2" end
            UnitName = function() return "Vendor" end
            GetMerchantNumItems = function() return 1 end
            GetMerchantItemID = function() return 159 end
            """
        )
        mod["setPlayer"](0.4321, 0.8765)
        mod["vendor"]()
        v = mod["db"]["world"]["vendors"]["Creature-2"]
        self.assertAlmostEqual(float(v["x"]), 0.4321, places=4)
        self.assertAlmostEqual(float(v["y"]), 0.8765, places=4)

    def test_vendor_position_missing_is_left_empty(self):
        lua, mod = self.load(
            """
            MAP_STRICT = true
            C_Map = { GetBestMapForUnit = function() return nil end,
                      GetPlayerMapPosition = function() return nil end }
            UnitGUID = function() return "Creature-3" end
            UnitName = function() return "Vendor" end
            GetMerchantNumItems = function() return 1 end
            GetMerchantItemID = function() return 159 end
            PLAYER_XY_OFF = true
            """
        )
        mod["vendor"]()
        v = mod["db"]["world"]["vendors"]["Creature-3"]
        self.assertIsNone(v["x"])
        self.assertIsNone(v["y"])

    def test_zero_zero_position_is_not_stored(self):
        """0/0 — это «нет данных», а не координата в углу карты."""
        lua, mod = self.load(
            """
            C_Map = { GetBestMapForUnit = function() return 1519 end,
                      GetPlayerMapPosition = function() return {GetXY = function() return 0, 0 end} end }
            UnitGUID = function() return "Creature-4" end
            UnitName = function() return "Vendor" end
            GetMerchantNumItems = function() return 1 end
            GetMerchantItemID = function() return 159 end
            PLAYER_XY_OFF = true
            """
        )
        mod["vendor"]()
        v = mod["db"]["world"]["vendors"]["Creature-4"]
        self.assertIsNone(v["x"])

    def test_fishing_keeps_last_catch_point(self):
        lua, mod = self.load(
            """
            IsFishingLoot = function() return true end
            GetNumLootItems = function() return 1 end
            GetLootSlotLink = function() return "|Hitem:6291:0|h[x]|h" end
            """
        )
        mod["setPlayer"](0.2, 0.3)
        mod["fishing"]()
        mod["setPlayer"](0.7, 0.8)  # переплыл, поймал ещё
        mod["fishing"]()
        row = mod["db"]["world"]["fish"]["1519:6291"]
        self.assertAlmostEqual(float(row["x"]), 0.7, places=4)
        self.assertAlmostEqual(float(row["y"]), 0.8, places=4)
        self.assertEqual(int(row["cnt"]), 2)


class MaxVTest(unittest.TestCase):
    """Лимиты объявлены одной таблицей (экономия локалов Lua 5.1)."""

    def test_caps_declared(self):
        src = SOURCE.read_text(encoding="utf-8")
        self.assertIn("local WORLD_LIM = {", src)
        for field in ("vendors =", "perVendor =", "items =", "fish ="):
            self.assertIn(field, src)

    def test_no_stale_constant_names(self):
        src = SOURCE.read_text(encoding="utf-8")
        for gone in ("WORLD_MAX_VENDORS", "WORLD_MAX_PER_VENDOR",
                     "WORLD_MAX_VENDOR_ITEMS", "WORLD_MAX_FISH"):
            self.assertNotIn(gone, src)


if __name__ == "__main__":
    unittest.main(verbosity=2)
