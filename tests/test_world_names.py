"""Резервный путь для имени предмета через тултип — Lua 5.1.

Регрессия с живых данных 08.11.2026: у вендора «Зеррил Нежный Ветерок»
23 позиции, а C_Item.GetItemNameByID ответил только для 8. Имя есть в первой
строке тултипа торговой позиции, поэтому сбор догадывает его через
SetMerchantItem. Проверяется: догадка срабатывает только для безымянных,
лимит соблюдается, ошибка клиента не ломает снимок вендора.
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
    return len(list(tbl))


PRELUDE = """
local DB = { debug = {} }
function GetDB() return DB end
local t = 1794000000
function time() t = t + 1 return t end
function PlayerZone() return "Stormwind City" end
function PlayerZoneId() return 1519 end
local function Round4(v) return math.floor(v * 10000 + 0.5) / 10000 end
function PlayerXY() return 0.5, 0.5 end
C_Map = { GetBestMapForUnit = function() return 1519 end,
          GetPlayerMapPosition = function() return {GetXY = function() return 0.5, 0.5 end} end }
function DbgErr() end
-- тултип: SetMerchantItem пишет в лог, TextLeft1 отдаёт имя по индексу
TIPLOG = {}
local tip = { name = "NearbySpyProbeTip" }
if TIP_RAISE then
    function tip:SetMerchantItem() error("client gate") end
else
    function tip:SetMerchantItem(i) TIPLOG[#TIPLOG + 1] = i end
end
function tip:GetName() return self.name end
function tip:SetOwner() end
if CreateFrame == nil then CreateFrame = function() return tip end end
if canaccessvalue == nil then canaccessvalue = function() return true end end
-- ProbeTip/ProbeText живут выше маркера блока (в probe-коде) — в тесте стабы
function ProbeTip() return tip end
function ProbeText(fs)
    if not fs or type(fs.GetText) ~= "function" then return nil end
    local ok, txt = pcall(fs.GetText, fs)
    if not ok or txt == nil then return nil end
    if type(txt) ~= "string" then return "[secret]" end
    if canaccessvalue and not canaccessvalue(txt) then return "[secret]" end
    return txt
end
-- имена: часть предметов отдаётся C_Item, часть только тултипом
KNOWN_NAMES = { [159] = "Освежающая ключевая вода" }
TIP_NAMES = { [4606] = "Напиток из грибов", [3770] = "Мясо барана" }
C_Item = {
    GetItemInfoInstant = function(id) return id, "Расходуемые", "Еда", "X", "1", 0, 5 end,
    GetItemNameByID = function(id) return KNOWN_NAMES[id] end,
    GetItemInfo = function(id) return KNOWN_NAMES[id], "link", 1, 20, 1, "Расходуемые", "Еда", 20, "X", "1" end,
}
"""


class NameFallbackTest(unittest.TestCase):
    def load(self, extra: str = ""):
        lua = LuaRuntime(unpack_returned_tuples=True)
        chunk = (
            PRELUDE
            + collectors_block()
            + "\nreturn {vendor=WR.CollectVendor, db=DB, tiplog=TIPLOG, lim=WORLD_LIM}\n"
        )
        mod = lua.execute(extra + "\n" + chunk)
        return lua, mod

    def stub_merchant(self, items_lua: str, names_lua: str, tooltip_lua: str, extra: str = ""):
        # ⚠️ extra выполняется ДО PRELUDE, а PRELUDE задаёт свой TIP_NAMES —
        # имена из names_lua для ключей вне PRELUDE не выживают. Берите предметы,
        # которые уже есть в TIP_NAMES (4606, 3770), либо переопределяйте их
        # в extra вместе с самим списком.
        return self.load(
            """
            UnitGUID = function() return "Creature-1" end
            UnitName = function() return "Vendor" end
            GetMerchantNumItems = function() return #({%s}) end
            GetMerchantItemID = function(i) return ({ %s })[i] end
            TIP_NAMES = { %s }
            _G["NearbySpyProbeTipTextLeft1"] = {GetText = function()
                local idx = TIPLOG[#TIPLOG]
                local id = ({ %s })[idx]
                if TIP_PLACEHOLDER then return "Получение сведений о предмете" end
                return TIP_NAMES[id]
            end}
            -- вторая строка тултипа: у известного предмета есть (тип/применение),
            -- у заглушки пуста — по этому и отличаем
            _G["NearbySpyProbeTipTextLeft2"] = {GetText = function()
                if TIP_PLACEHOLDER then return nil end
                return "Используется для ремесел"
            end}
            %s
            """ % (items_lua, items_lua, names_lua, items_lua, extra)
        )

    def test_nameless_item_gets_name_from_tooltip(self):
        lua, mod = self.stub_merchant("159, 4606", "[4606]='Напиток из грибов'", "")
        mod["vendor"]()
        items = mod["db"]["world"]["vendors"]["Creature-1"]["items"]
        self.assertEqual(str(items[159]["n"]), "Освежающая ключевая вода")
        self.assertEqual(str(items[4606]["n"]), "Напиток из грибов")

    def test_named_item_does_not_touch_tooltip(self):
        """Уже названный предмет не должен дёргать отрисовку тултипа."""
        lua, mod = self.stub_merchant("159", "{}", "")
        mod["vendor"]()
        self.assertEqual([int(x) for x in mod["tiplog"]], [])
        items = mod["db"]["world"]["vendors"]["Creature-1"]["items"]
        self.assertEqual(str(items[159]["n"]), "Освежающая ключевая вода")

    def test_lookup_limit_is_respected(self):
        many = ", ".join(str(9000 + i) for i in range(60))
        lua, mod = self.stub_merchant(many, "{}", "")
        limit = int(mod["lim"]["nameLookup"])
        mod["vendor"]()
        calls = [int(x) for x in mod["tiplog"]]
        self.assertLessEqual(len(calls), limit)

    def test_placeholder_tooltip_is_not_used_as_name(self):
        """Заглушка «Получение сведений о предмете» не должна стать именем.

        Регрессия с живой игры 09.11.2026: у предметов вне кэша клиента тултип
        состоит из ОДНОЙ служебной строки, и она уехала в базу как название
        (13 позиций у четырёх торговцев). Признак — пустая вторая строка.
        """
        lua, mod = self.stub_merchant(
            "6325", "{}", "", extra='TIP_PLACEHOLDER = true')
        mod["vendor"]()
        items = mod["db"]["world"]["vendors"]["Creature-1"]["items"]
        self.assertIsNone(items[6325]["n"])

    def test_tooltip_error_does_not_break_snapshot(self):
        """Отказ клиента в SetMerchantItem не должен ломать снимок вендора."""
        lua, mod = self.stub_merchant(
            "159, 4606", "[4606]='Напиток из грибов'", "", extra="TIP_RAISE = true")
        mod["vendor"]()
        items = mod["db"]["world"]["vendors"]["Creature-1"]["items"]
        self.assertEqual(nkeys(items), 2)
        self.assertEqual(str(items[159]["n"]), "Освежающая ключевая вода")
        self.assertIsNone(items[4606]["n"])  # имени нет — поле пустое, не выдумано

    def test_secret_tooltip_line_is_not_used_as_name(self):
        lua, mod = self.load(
            """
            UnitGUID = function() return "Creature-2" end
            UnitName = function() return "Vendor" end
            GetMerchantNumItems = function() return 1 end
            GetMerchantItemID = function() return 4606 end
            _G["NearbySpyProbeTipTextLeft1"] = {GetText = function() return "текст" end}
            canaccessvalue = function() return false end
            """
        )
        mod["vendor"]()
        items = mod["db"]["world"]["vendors"]["Creature-2"]["items"]
        self.assertIsNone(items[4606]["n"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
