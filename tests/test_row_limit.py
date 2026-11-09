"""Лимит строк списка: 500 значит ровно 500 (Lua 5.1).

Регрессия: счётчик увеличивался ДО проверки `> MAX_ROWS`, поэтому при 501
подходящей записи функция возвращала 501 и выставляла высоту списка на 501
строку, хотя отрисовано было 500 — под списком оставалась пустая полоса.
"""

from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

from nsp_helpers import CONST_PRELUDE


SOURCE = Path(__file__).resolve().parents[1] / "NearbySpy.lua"

STUBS = """
local MAX_ROWS = 500
local TACTICAL_ROW_H = 16
local tactical = {rows = {}}
local winList = {height = -1}
function winList:SetHeight(h) self.height = h end
local function Round4(x) return x end
local function L(k) return k end
local function ClassColorRGB() return 1, 1, 1 end
local function TimeAgo() return "now" end
local function TacticalClassIcon() end
time = function() return 1000 end
local PLAYERS = {}
function SetPlayers(list) PLAYERS = list end
local function GetDB() return {players = {}} end
local function SortedPlayers() return PLAYERS end
local function TacticalVisible() return true end

-- минимальный мок строки: методы-заглушки + наблюдаемые FontString'ы
function ClassLocFromFile(f) return (LOCALIZED_CLASS_NAMES_MALE or {})[f] end
function RealmBadge(realm) return realm end
function ClassDisplayName(file, fallback) return fallback or (LOCALIZED_CLASS_NAMES_MALE or {})[file] or file or "?" end
LOCALIZED_CLASS_NAMES_MALE = {MAGE = "Маг", DRUID = "Друид"}

local function FontString()
    local fs = {text = nil, shown = true}
    function fs:SetText(t) self.text = t end
    function fs:SetTextColor(...) self.color = {...} end
    function fs:Show() self.shown = true end
    function fs:Hide() self.shown = false end
    return fs
end
local function MockRow(parent, index)
    -- realm — отдельная строка под именем (с 09.11.2026); мок обязан её иметь,
    -- иначе TacticalRows падает на row.realm:SetText
    local row = {index = index, icon = {}, name = FontString(),
        realm = FontString(), profile = FontString(), zone = FontString(),
        seen = FontString(), hover = {Hide = function() end}}
    function row:ClearAllPoints() end
    function row:SetPoint(...) end
    function row:Show() self.shown = true end
    function row:Hide() self.shown = false end
    return row
end
local function TacticalRow(parent, index)
    local row = MockRow(parent, index)
    tactical.rows[index] = row
    return row
end
function RowsCount() return #tactical.rows end
function RowShown(index) return tactical.rows[index] ~= nil and tactical.rows[index].shown end
function GetWinList() return winList end
function GetTactical() return tactical end
"""


class RowLimitTests(unittest.TestCase):
    def setUp(self):
        source = SOURCE.read_text(encoding="utf-8")
        start = source.index("local function TacticalRows()")
        end = source.index("local function TacticalStats()")
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(
            CONST_PRELUDE + "\n" + STUBS + source[start:end] + "\nTestRows = TacticalRows\n"
        )
        self.g = self.lua.globals()

    def run_rows(self, count):
        self.g["SetPlayers"](self.lua.table_from(
            [self.lua.table_from({"name": "P%d" % i, "lastSeen": 1000}) for i in range(count)]
        ))
        return self.g["TestRows"](), self.g["GetWinList"]()

    def test_501_candidates_yield_500_rows(self):
        shown, win_list = self.run_rows(501)
        self.assertEqual(500, shown)
        self.assertEqual(500 * 16, win_list["height"])
        self.assertEqual(500, self.g["RowsCount"]())

    def test_exactly_500_candidates_yield_500_rows(self):
        shown, win_list = self.run_rows(500)
        self.assertEqual(500, shown)
        self.assertEqual(500 * 16, win_list["height"])

    def test_peer_row_profile_shows_the_localized_class(self):
        # a peer packet has only the file key; a locally observed row has classLoc.
        # Without the display-time translation both spellings appeared in one list.
        self.g["SetPlayers"](self.lua.table_from([
            self.lua.table_from({"name": "FromChannel", "class": "DRUID",
                                 "level": 20, "lastSeen": 1000}),
        ]))
        self.g["TestRows"]()
        row = self.g["GetTactical"]()["rows"][1]
        self.assertEqual("Друид; LVL_PREFIX20", row["profile"]["text"],
                         "a peer row must show the localized class, not DRUID")

    def test_local_row_keeps_its_own_classLoc(self):
        self.g["SetPlayers"](self.lua.table_from([
            self.lua.table_from({"name": "Seen", "class": "DRUID", "classLoc": "Друидка",
                                 "level": 20, "lastSeen": 1000}),
        ]))
        self.g["TestRows"]()
        self.assertEqual("Друидка; LVL_PREFIX20", self.g["GetTactical"]()["rows"][1]["profile"]["text"])

    def test_fewer_than_limit_is_not_truncated(self):
        shown, win_list = self.run_rows(3)
        self.assertEqual(3, shown)
        self.assertEqual(3 * 16, win_list["height"])

    def test_empty_list_keeps_minimal_height(self):
        shown, win_list = self.run_rows(0)
        self.assertEqual(0, shown)
        self.assertGreaterEqual(win_list["height"], 1)


if __name__ == "__main__":
    unittest.main()
