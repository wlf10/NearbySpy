#!/usr/bin/env python3
"""Hub window + minimap button — lupa lua5.1 harness.

Extracts the hub/minimap block from NearbySpy.lua, stubs the WoW API and the
addon locals it consumes (ShowWindow, peer locals, etc.), then drives:
  - minimap button build + ring position + drag angle + click suppression
  - hub window: 4 cells, status line, peer toggle via cell click
  - /nspy minimap hide behaviour (db.minimapHide)

Run: lupavenv/bin/python3 tests/test_hub_minimap.py
"""
import re
import sys
from pathlib import Path

ADDON_DIR = Path(__file__).resolve().parent.parent
ADDON = ADDON_DIR / "NearbySpy.lua"
LOCALE_FILE = ADDON_DIR / "NearbySpy_Locale.lua"
TOC_FILE = ADDON_DIR / "NearbySpy.toc"

from lupa.lua51 import LuaRuntime  # noqa: E402

src = ADDON.read_text(encoding="utf-8")
start = src.index("-- ============ hub window + minimap button")
end = src.index('SLASH_NEARBYSPY1 = ')
BLOCK = src[start:end]

# Version comes from the TOC, not from a literal: a hardcoded one turned this
# test red at every release (it still said 1.3.0 with 1.5.4 shipped).
VERSION = re.search(r"^## Version:\s*(\S+)", TOC_FILE.read_text(encoding="utf-8"), re.M).group(1)

# Real enUS locale table for the L() stub (letters/labels must be real text).
# Since 09.11.2026 the strings live in NearbySpy_Locale.lua, and the search is
# scoped to the LOCALE table: an unscoped "    enUS = {" also matches the /who
# token table in the main file, which has no UI keys — L() then returns the key
# itself and every label check silently compares against "HUB_STATUS".
loc_src = LOCALE_FILE.read_text(encoding="utf-8")
loc_start = loc_src.index("LOCALE = {")
m = re.search(r"    enUS = \{(.*?)\n    \},", loc_src[loc_start:], re.S)
if not m:
    sys.exit("FAIL: enUS block not found in the LOCALE table")
en_entries = dict(re.findall(r'([A-Z][A-Z0-9_]+) = "((?:[^"\\]|\\.)*)"', m.group(1)))
if "HUB_STATUS" not in en_entries:
    sys.exit("FAIL: HUB_STATUS missing from the extracted enUS table")

lua_en = "{\n" + "\n".join(
    f'  ["{k}"] = "{v}",' for k, v in en_entries.items()) + "\n}"

STUBS = r"""
-- ---- WoW API + addon-local stubs ----
local ERRORS = {}
local CLICKS = { players = 0, server = 0, help = 0 }
local PEER_JOINS, PEER_LEAVES = 0, 0
UIParent = {}
CURSOR = { x = 0, y = 0 }
TOOLTIP_LINES = {}

-- callable+indexable mock: any chain x.Foo.Bar(...) resolves to a callable
local function MockAny()
    return setmetatable({}, {
        __call = function(...) return nil end,
        __index = function(t, k)
            local f = MockAny()
            rawset(t, k, f)
            return f
        end,
    })
end

ALL_WIDGETS = {}
local function NewWidget(parent)
    local w = { __shown = false, __parent = parent, __scripts = {}, __w = 0, __h = 0 }
    w.SetText = function(self, t) self.__text = t end
    w.GetText = function(self) return self.__text end
    w.SetSize = function(self, a, b) self.__w, self.__h = a, b end
    -- записываем: без этого MockAny молча глотает вызов, и тест на перенос
    -- текста проверяет пустоту
    w.SetWidth = function(self, v) self.__width = v end
    -- сырое чтение: __index-мок отдаёт таблицу на ЛЮБОЙ отсутствующий ключ,
    -- поэтому w["__width"] для виджета без ширины вернул бы truthy-таблицу
    w.RawWidth = function(self) return rawget(self, "__width") end
    w.SetScript = function(self, k, fn) self.__scripts[k] = fn end
    w.SetColorTexture = function(self, r, g, b, a) self.__color = { r, g, b, a } end
    w.SetTexture = function(self, p) self.__tex = p end
    w.Show = function(self) self.__shown = true end
    w.Hide = function(self) self.__shown = false end
    w.IsShown = function(self) return self.__shown end
    w.__checked = false
    w.SetChecked = function(self, v) self.__checked = v and true or false end
    w.GetChecked = function(self) return self.__checked end
    table.insert(ALL_WIDGETS, w)
    return setmetatable(w, { __index = function(t, k)
        local f
        if k == "CreateTexture" or k == "CreateFontString" then
            f = function(...) return NewWidget(t) end
        elseif k == "GetHighlightTexture" then
            f = function(...) return NewWidget(t) end
        else
            f = MockAny()
        end
        rawset(t, k, f)
        return f
    end })
end

function CreateFrame(kind, name, parent, template)
    -- no modern DropdownButton mixin in the harness: tier-1 must fail over to
    -- the UIDropDownMenu tier that the tests exercise
    if kind == "DropdownButton" then error("DropdownButton not in harness") end
    return NewWidget(parent)
end

-- minimap: fixed geometry
Minimap = NewWidget(nil)
Minimap.GetWidth = function() return 140 end
Minimap.GetCenter = function() return 100, 100 end
Minimap.GetEffectiveScale = function() return 1 end

function GetCursorPosition() return CURSOR.x, CURSOR.y end
function GetAddOnMetadata(addon, field) return "__VERSION__" end
GameTooltip = setmetatable({}, { __index = function(t, k)
    if k == "AddLine" then
        return function(self, txt) table.insert(TOOLTIP_LINES, txt) end
    end
    local f = function(...) return nil end
    rawset(t, k, f)
    return f
end })

-- Global helper defined ABOVE the sliced block (production line ~3.7k), so the
-- block cannot see it: without this stub every window build that touches the
-- keyboard dies with "attempt to call global 'NspKeyboardPropagate' (a nil
-- value)" — that is exactly how the combat guard broke this harness.
function NspKeyboardPropagate(frame, value)
    if frame and frame.SetPropagateKeyboardInput then
        frame:SetPropagateKeyboardInput(value)
    end
end

-- ---- addon-local stubs ----
local LOCALE_EN = __EN__
local function L(key) return LOCALE_EN[key] or key end
local function P(msg) table.insert(ERRORS, tostring(msg)) end
local function DbgErr(tag, err) table.insert(ERRORS, tag .. ": " .. tostring(err)) end
local function CountPlayers() return 42 end
local win = nil
local function ShowWindow() CLICKS.players = CLICKS.players + 1 end
local function ShowServerWindow() CLICKS.server = CLICKS.server + 1 end
local function ShowHelpWindow() CLICKS.help = CLICKS.help + 1 end
local peerQueue, peerQueued = {}, {}
local function PeerChannelName() return "nearbyspya" end
local function JoinPeerChannel() PEER_JOINS = PEER_JOINS + 1 end
function LeaveChannelByName(_) PEER_LEAVES = PEER_LEAVES + 1 end

-- db with peer default applied (as GetDB does now)
local DB = { players = {}, peerEnabled = true }
local function GetDB() return DB end

local function NewText(parent, size, r, g, b)
    return NewWidget(parent)
end
local function ApplyFont() end
local function SolidUnderlay(f)
    local t = f:CreateTexture(nil, "BACKGROUND", -7)
    t:SetAllPoints()
    t:SetColorTexture(0.03, 0.025, 0.02, 1)
end
local function StackWindow(f, level)
    if f.SetToplevel then pcall(f.SetToplevel, f, true) end
    if f.SetFrameLevel then pcall(f.SetFrameLevel, f, level) end
end
function GetLocale() return "ruRU" end
local function HeatOffsetHours() return 4 end -- system clock stub: UTC+4

-- UIDropDownMenu stubs: init fn captured on the frame, menu items collected
DD_INFOS = {}
function UIDropDownMenu_Initialize(f, fn) f.__init = fn end
function UIDropDownMenu_CreateInfo() return {} end
function UIDropDownMenu_AddButton(info) table.insert(DD_INFOS, info) end
function UIDropDownMenu_SetText(f, t) f.__text = t end
function UIDropDownMenu_SetWidth(f, w) f.__ddw = w end

TEST = {
    errors = ERRORS, clicks = CLICKS, widgets = ALL_WIDGETS,
    tooltip = TOOLTIP_LINES, db = DB,
    joins = function() return PEER_JOINS end,
    leaves = function() return PEER_LEAVES end,
}
"""

EXPORTS = r"""
_G.__TEST = {
    TEST = TEST,
    hub = hub,
    BuildMinimapButton = BuildMinimapButton,
    MinimapButton_Update = MinimapButton_Update,
    ShowHubWindow = ShowHubWindow,
    ToggleHubWindow = ToggleHubWindow,
    Utf8First = Utf8First,
    GetMiniBtn = function() return miniBtn end,
    GetHubWin = function() return hubWin end,
    GetOptWin = function() return optWin end,
    GetOpt = function() return opt end,
}
"""


def main():
    lua = LuaRuntime()
    # одним чанком: стабы — chunk-locals, блок должен их видеть как upvalues
    lua.execute(STUBS.replace("__EN__", lua_en).replace("__VERSION__", VERSION) + BLOCK + EXPORTS)
    t = lua.globals()["__TEST"]
    T = t["TEST"]

    def fail(msg):
        # errors from the addon's own pcall handlers are the first thing to see
        print("FAIL:", msg)
        print("addon errors:", [str(e) for e in T["errors"]])
        sys.exit(1)

    # 1. minimap button: build, shown, angle default
    t.BuildMinimapButton()
    mini = t.GetMiniBtn()
    if mini is None:
        fail("minimap button not built")
    if not mini["__shown"]:
        fail("minimap button not shown after build")
    if T["db"]["minimapAngle"] is not None:
        fail("angle should be unset before first drag")

    # 2. drag: cursor at (160, 100) with center (100,100) -> angle 0
    mini["__scripts"]["OnDragStart"](mini)
    CURSOR = lua.globals().CURSOR
    CURSOR.x, CURSOR.y = 160, 100
    mini["__scripts"]["OnUpdate"]()
    ang = T["db"]["minimapAngle"]
    if ang is None or abs(ang) > 0.5:
        fail(f"drag angle expected ~0, got {ang}")
    mini["__scripts"]["OnDragStop"](mini)

    # 3. click right after drag is suppressed
    t.ToggleHubWindow  # noqa - just ensure presence
    mini["__scripts"]["OnClick"](mini, "LeftButton")
    hub_win = t.GetHubWin()
    if hub_win is not None and hub_win["__shown"]:
        fail("click after drag should be suppressed")

    # 4. plain left click -> hub shows
    mini["__scripts"]["OnClick"](mini, "LeftButton")
    hub_win = t.GetHubWin()
    if hub_win is None or not hub_win["__shown"]:
        fail("hub window not shown after left click")
    status = t.hub["status"]["__text"] or ""
    if "42" not in status or VERSION not in status:
        fail(f"hub status text wrong: {status}")

    # hub has 4 cell buttons (lupa proxy identity is unreliable, size is unique).
    # Размер берём из прод-таблицы HUBG, а не хардкодом: иначе любая правка
    # раскладки (напр. увеличение под кириллицу) ломает тест, не ломая код.
    # Фолбэк на прежние 96x78: тогда на старом коде тест падает не «нет HUBG»,
    # а по существу — на тексте без ширины (переполнение подписи).
    m = re.search(r"local HUBG = \{ w = (\d+), h = (\d+)", BLOCK)
    cell_w, cell_h = (int(m.group(1)), int(m.group(2))) if m else (96, 78)
    cells = [w for w in T["widgets"].values()
             if w["__w"] == cell_w and w["__h"] == cell_h]
    if len(cells) != 4:
        fail(f"expected 4 hub cells ({cell_w}x{cell_h}), got {len(cells)}")

    # Кириллица шире латиницы и не влезала в кнопки: у подписи и описания
    # обязана быть задана ширина — только она включает перенос. Без SetWidth
    # FontString не переносится и вылезает за ячейку (клиппинга у него нет).
    # Сравнивать по parent нельзя: identity прокси-обёрток lupa ненадёжна,
    # поэтому смотрим все «длинные» тексты хаба (>2 символов — это не буква-
    # плитка, которая однобуквенная).
    long_texts = [w for w in T["widgets"].values()
                  if (w["__text"] or "") and len(w["__text"]) > 2]
    if not long_texts:
        fail("no long hub texts found — harness broke, check is vacuous")
    # внутренняя ширина окна: 260 минус боковые отступы по 15
    win_inner = 230
    cell_texts = 0
    for w in long_texts:
        width = w["RawWidth"](w)
        if width is None:
            fail(f"text without SetWidth (will overflow): {w['__text']!r}")
        if width > win_inner:
            fail(f"text wider than the window ({width} > {win_inner}): {w['__text']!r}")
        if width <= cell_w:
            cell_texts += 1
    # в ячейках должно быть по 2 текста с шириной (подпись + описание) — 8 всего
    if cell_texts < 8:
        fail(f"expected >=8 cell texts with width, got {cell_texts}")

    # 5. settings cell opens the settings window; peer checkbox toggles peerEnabled
    settings_cell = cells[3]  # creation order: players, server, help, settings
    # A window opened from the menu REPLACES the menu: the hub must be hidden, not
    # left sitting under the new window (user request 15.11.2026). Checked on the
    # settings cell: cells are collected from the widget list, whose iteration
    # order is not guaranteed, so keying the check on cell index would test the
    # harness rather than the behaviour.
    hub_win_now = t.GetHubWin()
    if hub_win_now is None or not hub_win_now["__shown"]:
        fail("hub should still be shown before a cell click")
    settings_cell["__scripts"]["OnClick"](settings_cell)
    if t.GetHubWin()["__shown"]:
        fail("hub stayed open after opening a window from it")
    opt_win = t.GetOptWin()
    if opt_win is None or not opt_win["__shown"]:
        fail("settings window not shown after settings cell click")
    cb = t.GetOpt()["peer"]
    if cb is None:
        fail("peer checkbox missing in settings window")
    if cb["GetChecked"](cb) is not True:
        fail("peer checkbox should start checked (peerEnabled=true)")
    # WoW auto-toggles a CheckButton before OnClick — simulate that
    cb["SetChecked"](cb, False)
    cb["__scripts"]["OnClick"](cb)
    if T["db"]["peerEnabled"] is not False:
        fail("peer checkbox click did not disable peer")
    if T.leaves() < 1:
        fail("LeaveChannelByName not called on peer off")
    cb["SetChecked"](cb, True)
    cb["__scripts"]["OnClick"](cb)
    if T["db"]["peerEnabled"] is not True or T.joins() < 1:
        fail("peer checkbox re-enable failed")

    # 5b. language dropdown: open menu, pick zhCN, check db + displayed text
    DD = lua.globals()["DD_INFOS"]
    lang = t.GetOpt()["lang"]
    dd = lang["dd"]
    if dd is None:
        fail("dropdown not used for language selector")
    if dd["__text"] is None:
        fail("language dropdown has no initial text")
    base = len(DD)
    dd["__init"]()
    n = len(DD) - base
    if n != 7:
        fail(f"language menu entries: {n} (expected 7 = Auto + 6)")
    entries = {DD[base + i]["value"]: DD[base + i] for i in range(1, n + 1)}
    if "AUTO" not in entries or "zhCN" not in entries:
        fail(f"language menu values wrong: {sorted(map(str, entries))}")
    zh = entries["zhCN"]
    zh["func"](zh)
    if T["db"]["locale"] != "zhCN":
        fail(f"language pick zhCN: db.locale={T['db']['locale']!r}")
    if dd["__text"] != "中文":
        fail(f"language dd text after pick: {dd['__text']!r}")
    # reopen: zhCN must be checked now
    base = len(DD)
    dd["__init"]()
    entries = {DD[base + i]["value"]: DD[base + i] for i in range(1, len(DD) - base + 1)}
    if entries["zhCN"]["checked"] is not True:
        fail("zhCN not checked after re-init")
    entries["AUTO"]["func"](entries["AUTO"])
    if T["db"]["locale"] is not None:
        fail(f"language back to Auto: db.locale={T['db']['locale']!r}")

    # 5c. timezone dropdown: Auto + 27 offsets; pick UTC+3, then back to Auto
    tzd = t.GetOpt()["tz"]["dd"]
    if tzd is None:
        fail("dropdown not used for timezone selector")
    base = len(DD)
    tzd["__init"]()
    n = len(DD) - base
    if n != 28:
        fail(f"tz menu entries: {n} (expected 28 = Auto + UTC-12..+14)")
    v3 = au = None
    for i in range(base + 1, len(DD) + 1):
        v = DD[i]["value"]
        if v == 3:
            v3 = DD[i]
        elif v == "AUTO":
            au = DD[i]
    v3["func"](v3)
    if T["db"]["tzOffset"] != 3:
        fail(f"tz pick UTC+3: db.tzOffset={T['db']['tzOffset']!r}")
    au["func"](au)
    if T["db"]["tzOffset"] is not None:
        fail(f"tz back to Auto: db.tzOffset={T['db']['tzOffset']!r}")

    # 6. players cell opens the main window
    cells[0]["__scripts"]["OnClick"](cells[0])
    if T["clicks"]["players"] != 1:
        fail("players cell did not call ShowWindow")

    # 7. right click on minimap -> ShowWindow
    mini["__scripts"]["OnClick"](mini, "RightButton")
    if T["clicks"]["players"] != 2:
        fail("right click did not open player list")

    # 8. toggle hub twice -> hidden again. Since a cell click hides the menu,
    # the state on entry is not "shown" any more: normalize first, otherwise the
    # check would depend on what the previous step happened to leave behind.
    if hub_win["__shown"]:
        t.ToggleHubWindow()
    if hub_win["__shown"]:
        fail("hub should be hidden before the toggle check")
    t.ToggleHubWindow()
    if not hub_win["__shown"]:
        fail("first toggle should show the hub")
    t.ToggleHubWindow()
    if hub_win["__shown"]:
        fail("hub should be hidden after second toggle")

    # 9. /nspy minimap hide path
    T["db"]["minimapHide"] = True
    t.MinimapButton_Update()
    if mini["__shown"]:
        fail("minimap button should hide when minimapHide=true")

    # 10. Utf8First on multibyte (cyrillic "И" from HUB_PLAYERS ru not loaded here;
    #     check with a literal multibyte string)
    first = t.Utf8First("Игроки")
    if first != "И":
        fail(f"Utf8First multibyte failed: {first!r}")

    errs_all = [T["errors"][i] for i in range(1, len(T["errors"]) + 1)]
    errs = [e for e in errs_all if "ОШИБКА" in e or "ERROR" in e or ":" in e[:12]]
    if errs:
        fail("errors captured: " + "; ".join(errs))

    print("HUB+MINIMAP TEST OK")


if __name__ == "__main__":
    main()
