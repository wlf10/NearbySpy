"""Проба API для сбора данных мира (вендоры/рыбалка) — Lua 5.1.

Блок `world data probe` вынимается из NearbySpy.lua по маркерам и выполняется
в настоящем Lua 5.1 (lupa) с моками клиентского API. Проверяется то, что
важно для этапа 0: состав API считается честно, itemID берётся из линка
(GetMerchantItemID может отсутствовать), порядок возвратов сохраняется как
есть, объём пробы ограничен, при выключенной пробе в SV ничего не пишется.
"""

from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

from nsp_helpers import CONST_PRELUDE

SOURCE = Path(__file__).resolve().parents[1] / "NearbySpy.lua"
START = "-- ============ world data probe"
END = "-- localized class name -> file key"


def probe_block() -> str:
    src = SOURCE.read_text(encoding="utf-8")
    i = src.index(START)
    j = src.index(END, i)
    return src[i:j]


PRELUDE = """
local DB = { probe = {}, probeOn = false }
function GetDB() return DB end
local clock = 1793000000
function time() clock = clock + 1 return clock end
function PlayerZone() return "Stormwind City" end
function PlayerZoneId() return 1519 end
function PlayerRealm() return "CAMWOW EU5 Realm 1 PvE" end
"""


class ProbeTest(unittest.TestCase):
    def run_lua(self, setup: str = ""):
        lua = LuaRuntime(unpack_returned_tuples=True)
        chunk = PRELUDE + probe_block() + "\nreturn {run=ProbeRun, merchant=ProbeMerchant, loot=ProbeLoot, api=PROBE_API, db=DB}\n"
        mod = lua.execute(CONST_PRELUDE + "\n" + setup + "\n" + chunk)
        return lua, mod

    def test_api_flags_reflect_client(self):
        lua, mod = self.run_lua(
            """
            GetMerchantNumItems = function() return 0 end
            GetMerchantItemInfo = function() end
            UnitName = function(unit) return "Vendor" end
            -- всё остальное отсутствует, как в ванильном клиенте может быть
            """
        )
        lua.execute("GetBuildInfo = function() return '1.60.1.70291', 'x' end")
        api = mod["run"]()
        flags = {str(k): int(v) for k, v in api.items()}
        self.assertEqual(flags["GetMerchantNumItems"], 1)
        self.assertEqual(flags["GetMerchantItemInfo"], 1)
        self.assertEqual(flags["UnitName"], 1)
        self.assertEqual(flags["IsFishingLoot"], 0)
        self.assertEqual(flags["GetMerchantItemLink"], 0)
        db = mod["db"]
        self.assertTrue(bool(db["probeOn"]))
        probe = db["probe"]
        self.assertEqual(str(probe["realm"]), "CAMWOW EU5 Realm 1 PvE")
        self.assertEqual(str(probe["zone"]), "Stormwind City")
        self.assertEqual(int(probe["zoneId"]), 1519)

    def test_merchant_items_use_link_for_item_id(self):
        lua, mod = self.run_lua(
            """
            UnitName = function(unit) return "Auctioneer Chilton" end
            UnitExists = function(unit) return 1 end
            GetMerchantNumItems = function() return 3 end
            GetMerchantItemInfo = function(i)
                return "Recipe " .. i, "Interface\\\\Icons\\\\inv_scroll_03", 100 * i, 1, 2, 1, 1
            end
            GetMerchantItemLink = function(i) return "|Hitem:" .. (6300 + i) .. ":0:0:0|h[Recipe]|h" end
            GetItemInfo = function(link) return "Recipe", link, 1, 20, 5, "Recipe", "Cooking", 1 end
            """
        )
        run = mod["run"]
        run()
        mod["merchant"]()
        probe = mod["db"]["probe"]
        self.assertEqual(len(probe["merchants"]), 1)
        entry = probe["merchants"][1]
        self.assertEqual(int(entry["numItems"]), 3)
        self.assertEqual(str(entry["npcName"]["v"][1]), "Auctioneer Chilton")
        self.assertEqual(len(entry["items"]), 3)
        first = entry["items"][1]
        self.assertEqual(int(first["itemId"]), 6301)
        # порядок возвратов GetMerchantItemInfo сохранён как есть (v1..v7)
        self.assertEqual(len(first["info"]["v"]), 7)
        self.assertEqual(str(first["info"]["v"][6]), "1")  # isPurchasable на 6-м месте
        self.assertEqual(str(first["item"]["v"][6]), "Recipe")  # class из GetItemInfo

    def test_merchant_events_bounded(self):
        lua, mod = self.run_lua(
            """
            UnitName = function() return "Vendor" end
            GetMerchantNumItems = function() return 0 end
            """
        )
        run, merchant = mod["run"], mod["merchant"]
        run()
        for _ in range(10):
            merchant()
        self.assertEqual(len(mod["db"]["probe"]["merchants"]), 4)

    def test_loot_fishing_sample(self):
        lua, mod = self.run_lua(
            """
            IsFishingLoot = function() return true end
            UnitExists = function(unit) return nil end
            GetNumLootItems = function() return 2 end
            GetLootSlotInfo = function(i)
                return "Interface\\\\Icons\\\\inv_misc_fish_04", "Raw Brilliant Smallfish", 1, 1, 0
            end
            GetLootSlotLink = function(i) return "|Hitem:" .. (6290 + i) .. ":0:0:0|h[Fish]|h" end
            GetItemInfo = function(link) return "Fish", link, 1, 5, 1, "Tradeskill", "Cooking", 20 end
            """
        )
        mod["run"]()
        mod["loot"]()
        entry = mod["db"]["probe"]["loots"][1]
        self.assertEqual(str(entry["isFishing"]["v"][1]), "true")
        self.assertEqual(int(entry["numLoot"]), 2)
        self.assertEqual(len(entry["slots"]), 2)
        self.assertEqual(int(entry["slots"][2]["itemId"]), 6292)
        self.assertEqual(str(entry["slots"][1]["info"]["v"][2]), "Raw Brilliant Smallfish")

    def test_probe_off_writes_nothing(self):
        lua, mod = self.run_lua(
            """
            GetMerchantNumItems = function() return 5 end
            GetNumLootItems = function() return 5 end
            """
        )
        mod["merchant"]()
        mod["loot"]()
        probe = mod["db"]["probe"]
        self.assertIsNone(probe["merchants"])
        self.assertIsNone(probe["loots"])

    def test_call_error_is_captured(self):
        lua, mod = self.run_lua(
            """
            GetMerchantNumItems = function() error("client gate") end
            UnitName = function() error("secret value") end
            """
        )
        mod["run"]()
        mod["merchant"]()
        entry = mod["db"]["probe"]["merchants"][1]
        self.assertIn("client gate", str(entry["numItemsErr"]))
        self.assertIn("secret value", str(entry["npcName"]["err"]))
        self.assertEqual(int(entry["numItems"]), 0)
        self.assertEqual(len(entry["items"]), 0)


class ProbeV2Test(unittest.TestCase):
    """Проба v2: тултип торговой позиции и перечисление клиентских глобалов."""

    TIP_STUBS = """
    UIParent = {}
    local tip = { name = "NearbySpyProbeTip", setCalls = {} }
    function tip:SetOwner() end
    function tip:SetMerchantItem(i) self.setCalls[#self.setCalls + 1] = i end
    function tip:GetName() return self.name end
    CreateFrame = function(kind, name, parent, tmpl) return tip end
    CAN_ACCESS = true
    canaccessvalue = function(s) return CAN_ACCESS end
    """

    def run_v2(self, extra: str):
        lua = LuaRuntime(unpack_returned_tuples=True)
        chunk = (
            PRELUDE
            + self.TIP_STUBS
            + probe_block()
            + "\nreturn {run=ProbeRun, merchant=ProbeMerchant, tip=ProbeTooltip,"
              " globals=ProbeGlobals, itemFuncs=ProbeItemFuncs, db=DB}\n"
        )
        mod = lua.execute(CONST_PRELUDE + "\n" + extra + "\n" + chunk)
        return lua, mod

    def test_tooltip_lines_read_and_link_retried(self):
        lua, mod = self.run_v2(
            """
            _G["NearbySpyProbeTipTextLeft1"] = {GetText = function() return "|cffffffffОсвежающая вода|r" end}
            _G["NearbySpyProbeTipTextLeft2"] = {GetText = function() return "Используется: 5" end}
            _G["NearbySpyProbeTipTextLeft3"] = {GetText = function() return nil end}
            GetMerchantItemLink = function(i) return "|Hitem:" .. (6000 + i) .. ":0:0|h[x]|h" end
            """
        )
        res = mod["tip"](2)
        self.assertEqual(len(res), 2)
        first = res[1]
        self.assertEqual(int(first["setOk"]), 1)
        self.assertEqual(len(first["lines"]), 2)
        self.assertIn("Освежающая вода", str(first["lines"][1]))
        # линк перезапрашивается ПОСЛЕ SetMerchantItem (гипотеза ленивого кеша)
        self.assertEqual(str(first["linkAfter"]["v"][1]), "|Hitem:6001:0:0|h[x]|h")

    def test_secret_tooltip_line_is_marked_not_compared(self):
        lua, mod = self.run_v2(
            """
            _G["NearbySpyProbeTipTextLeft1"] = {GetText = function() return "текст" end}
            """
        )
        lua.execute("CAN_ACCESS = false")  # после загрузки чанка: стаб не перезапишет
        res = mod["tip"](1)
        self.assertEqual(str(res[1]["lines"][1]), "[secret]")

    def test_gettext_error_does_not_raise(self):
        lua, mod = self.run_v2(
            """
            _G["NearbySpyProbeTipTextLeft1"] = {GetText = function() error("global string") end}
            _G["NearbySpyProbeTipTextLeft2"] = {GetText = function() return "ok" end}
            """
        )
        res = mod["tip"](1)
        self.assertEqual(len(res[1]["lines"]), 1)
        self.assertEqual(str(res[1]["lines"][1]), "ok")

    def test_namespaces_are_enumerated_fully(self):
        """Перечисляются ВСЕ пространства C_* с ключами (без среза).

        Регрессия: первый вариант перебирал _G по шаблонам и резал на 260
        имён — pairs() отдаёт произвольный порядок, поэтому C_Item в срез не
        попал, и проба ошибочно сообщила «C_Item нет».
        """
        lua, mod = self.run_v2(
            """
            C_Item = { GetItemNameByID = function() end, GetItemInfo = function() end,
                       GetItemInfoInstant = function() end }
            C_MerchantFrame = { GetItemInfo = function() end }
            SomeUnrelatedThing = function() end
            """
        )
        mod["globals"]()
        ns = mod["db"]["probe"]["namespaces"]
        self.assertIn("GetItemNameByID", str(ns["C_Item"]))
        self.assertIn("GetItemInfoInstant", str(ns["C_Item"]))
        self.assertEqual(str(ns["C_MerchantFrame"]), "GetItemInfo")
        self.assertIsNone(ns["SomeUnrelatedThing"])
        self.assertEqual(int(mod["db"]["probe"]["namespacesCount"]), 2)

    def test_item_funcs_tries_alternatives(self):
        lua, mod = self.run_v2(
            """
            GetItemInfoInstant = function(id) return id, "Recipe: x", 1, 20, 5, 9, 6 end
            """
        )
        out = mod["itemFuncs"](6301)
        self.assertEqual(len(out["GetItemInfoInstant"]["v"]), 7)
        self.assertEqual(str(out["GetItemInfoInstant"]["v"][6]), "9")


class ProbeResetTest(unittest.TestCase):
    """Повторный /nspy probe начинает свежий снимок.

    Регрессия с живой игры 08.11.2026: копилки пробы ограничены четырьмя
    записями, и после нескольких прогонов новые события молча отбрасывались —
    свежие поля (структура цены) в SV так и не появились.
    """

    def run_lua(self, extra: str = ""):
        lua = LuaRuntime(unpack_returned_tuples=True)
        chunk = (
            PRELUDE
            + probe_block()
            + "\nreturn {run=ProbeRun, merchant=ProbeMerchant, loot=ProbeLoot, db=DB}\n"
        )
        mod = lua.execute(CONST_PRELUDE + "\n" + extra + "\n" + chunk)
        return lua, mod

    def test_repeat_probe_clears_previous_samples(self):
        lua, mod = self.run_lua(
            """
            UnitName = function() return "Vendor" end
            GetMerchantNumItems = function() return 0 end
            GetNumLootItems = function() return 0 end
            """
        )
        mod["run"]()
        for _ in range(4):
            mod["merchant"]()
            mod["loot"]()
        self.assertEqual(len(mod["db"]["probe"]["merchants"]), 4)
        self.assertEqual(len(mod["db"]["probe"]["loots"]), 4)
        # новая проба — старые записи уходят, иначе лимит уже исчерпан
        mod["run"]()
        probe = mod["db"]["probe"]
        self.assertEqual(len(probe["merchants"]), 0)
        self.assertEqual(len(probe["loots"]), 0)
        # и снова можно писать
        mod["merchant"]()
        self.assertEqual(len(probe["merchants"]), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
