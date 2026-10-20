#!/usr/bin/env python3
"""Server census window (/nspy server) — lupa lua5.1 harness.

Extracts the server-window block from NearbySpy.lua, stubs the WoW API and
the addon helpers it consumes (NewText/ApplyFont/L/P/GetDB/ClassColorRGB),
feeds the REAL datapack lua (/api/datapack.lua shape) and asserts:
  - window builds and shows without errors (P never gets ERR_WINDOW)
  - totals / peak / first class row match the snapshot data
  - heat peak cell alpha is the brightest
  - without NearbySpyData the "no data module" message shows

Run:  ~/.hermes/profiles/develop/cache/scratch/lupavenv/bin/python3 tests/test_server_window.py
"""
import re
import sys
from pathlib import Path

from lupa.lua51 import LuaRuntime

SRC = Path(__file__).resolve().parent.parent / "NearbySpy.lua"
DATAPACK = Path(__file__).resolve().parent / "fixtures" / "datapack.lua"

STUBS = r"""
-- ---- WoW API + addon helper stubs ----
local ERRORS = {}
date = os.date   -- WoW exposes os.date/os.time as the bare globals date()/time()
time = os.time
UIParent = {}
GameFontNormal = {}
BreakUpLargeNumbers = nil -- exercise the tostring fallback
RAID_CLASS_COLORS = { PALADIN = { r = 0.96, g = 0.55, b = 0.73 }, WARRIOR = { r = 0.78, g = 0.61, b = 0.43 } }
LOCALIZED_CLASS_NAMES_MALE = nil -- exercise the file-key fallback

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

local function NewWidget()
    local w = { __shown = false }
    w.SetText = function(self, t) self.__text = t end
    w.GetText = function(self) return self.__text end
    w.SetColorTexture = function(self, r, g, b, a) self.__color = { r, g, b, a } end
    w.Show = function(self) self.__shown = true end
    w.Hide = function(self) self.__shown = false end
    return setmetatable(w, { __index = function(t, k)
        local f
        if k == "CreateTexture" or k == "CreateFontString" then
            f = function(...) return NewWidget() end
        else
            f = MockAny()
        end
        rawset(t, k, f)
        return f
    end })
end

function CreateFrame(kind, name, parent, template)
    return NewWidget()
end

local LOCALE_EN = {
    SVR_TITLE = "Server census", SVR_SNAPSHOT = "RealmPulse snapshot: %s", SVR_TOTAL = "PLAYERS",
    SVR_PRIME = "PRIME TIME (28 DAYS)", SVR_CLASSES = "CLASSES", SVR_ZONES = "TOP ZONES",
    SVR_PEAK = "Peak: %s %02d:00 - %d players",
    SVR_NODATA = "No data module found. Install NearbySpy_Data (datapack-latest release) next to NearbySpy.",
    SVR_STALE = "snapshot %d days old - update NearbySpy_Data",
    SVR_D1 = "Mon", SVR_D2 = "Tue", SVR_D3 = "Wed", SVR_D4 = "Thu", SVR_D5 = "Fri", SVR_D6 = "Sat", SVR_D7 = "Sun",
    ALLIANCE = "Alliance", HORDE = "Horde",
    ERR_WINDOW = "window ERROR: ",
}
local function L(key) return LOCALE_EN[key] or key end
local function NewText(parent, size, r, g, b) return NewWidget() end
local function ApplyFont(fs, size, flags) end
local function ClassColorRGB(file)
    local c = RAID_CLASS_COLORS[file]
    if c then return c.r, c.g, c.b end
    return 1, 1, 1
end
local function P(msg) ERRORS[#ERRORS + 1] = msg end
local function SolidUnderlay(f)
    local t = f:CreateTexture(nil, "BACKGROUND", -7)
    t:SetAllPoints()
    t:SetColorTexture(0.03, 0.025, 0.02, 1)
end
local function StackWindow(f, level)
    if f.SetToplevel then pcall(f.SetToplevel, f, true) end
    if f.SetFrameLevel then pcall(f.SetFrameLevel, f, level) end
end
"""

EXPORTS = r"""
_G.__TEST = {
    Show = ShowServerWindow,
    Fill = FillServerWindow,
    svr = svr,
    win = function() return serverWin end,
    errors = ERRORS,
}
"""


def load_block(lua, game="forever"):
    src = SRC.read_text(encoding="utf-8")
    # the block ends where the hub window begins — stop there, not at the
    # slash dispatcher (that would drag hub/settings/minimap into this test)
    m = re.search(
        r"-- ============ server census window.*?\n(.*?)-- ============ hub window",
        src, re.S,
    )
    assert m, "server window block not found"
    lua.execute(
        STUBS
        + f'GetDB = function() return {{ game = "{game}" }} end\n'
        + m.group(1)
        + EXPORTS
    )


def main():
    lua = LuaRuntime()
    # real snapshot data as produced by /api/datapack.lua
    lua.execute(DATAPACK.read_text(encoding="utf-8"))
    load_block(lua)
    t = lua.globals().__TEST

    t.Show()
    errors = [t.errors[i] for i in range(1, len(t.errors) + 1)]
    assert not errors, f"P() got error output: {errors}"
    assert t.win()["__shown"], "window not shown"

    g = lua.globals().NearbySpyData["games"]["forever"]
    assert t.svr.total["__text"] == str(g["total"]), f'total text: {t.svr.total["__text"]}'
    assert t.svr.nodata["__shown"] is False

    # heat is UTC in the datapack and rotated into LOCAL hours at fill time
    # (os.date/os.time offset trick); replicate the same offset here
    import time as ptime
    off = round((ptime.mktime(ptime.localtime()) - ptime.mktime(ptime.gmtime())) / 3600)
    heat = g["heat"]
    flat = {}
    for d in range(1, 8):
        for h in range(24):
            flat[(d - 1) * 24 + h] = heat[d][h + 1] or 0
    peak = max(flat.values())
    # local cell (d,h) shows flat[(idx - off) % 168] -> peak lands at utc_idx + off
    pd, ph = divmod(([i for i, v in flat.items() if v == peak][0] + off) % 168, 24)
    pd += 1
    cell_alpha = t.svr.heatCells[pd][ph]["__color"][4]
    assert cell_alpha > 0.9, f"peak cell alpha {cell_alpha}"
    # visibility floor: every nonzero cell >= 0.2 (was the "empty heatmap" bug)
    smallest = min(v for v in flat.values() if v > 0)
    sd, sh = divmod(([i for i, v in flat.items() if v == smallest][0] + off) % 168, 24)
    sd += 1
    small_alpha = t.svr.heatCells[sd][sh]["__color"][4]
    assert small_alpha >= 0.2, f"smallest cell alpha {small_alpha}"
    # a zero cell stays at the quiet base alpha
    zero_idx = [i for i, v in flat.items() if v == 0][0]
    zd, zh = divmod((zero_idx + off) % 168, 24)
    zd += 1
    quiet = t.svr.heatCells[zd][zh]["__color"][4]
    assert quiet == 0.04, f"quiet cell alpha {quiet}"
    peak_text = t.svr.peak["__text"] or ""
    assert str(peak) in peak_text and "%02d:00" % ph in peak_text, f"peak line: {peak_text}"

    # class rows sorted desc; first row = top class
    top_class = max(g["classes"].items(), key=lambda kv: kv[1])
    row1 = t.svr.classRows[1]
    assert row1.label["__text"] == top_class[0], f'row1 label: {row1.label["__text"]}'
    assert str(top_class[1]) in row1.value["__text"], f'row1 value: {row1.value["__text"]}'
    assert row1.bar is not None  # StatusBar path taken

    # zones line mentions the top zone
    top_zone = g["zones"][1]
    assert top_zone[1] in (t.svr.zones["__text"] or ""), f'zones line: {t.svr.zones["__text"]}'

    # ---- no data module ----
    lua.execute("NearbySpyData = nil")
    t.Fill()
    nd = t.svr.nodata
    assert nd["__shown"] and "NearbySpy_Data" in (nd["__text"] or ""), f'nodata: {nd["__text"]}'
    assert (t.svr.total["__text"] or "") == ""

    # ---- retail client on a forever-only snapshot: falls back to forever ----
    lua2 = LuaRuntime()
    lua2.execute(DATAPACK.read_text(encoding="utf-8"))
    load_block(lua2, game="retail")
    t2 = lua2.globals().__TEST
    t2.Show()
    assert t2.svr.nodata["__shown"] is False, "retail should fall back to forever data"
    assert t2.svr.total["__text"] == "200", f'fallback total: {t2.svr.total["__text"]}'

    # ---- game key absent from the snapshot: forever fallback still applies ----
    lua3 = LuaRuntime()
    lua3.execute(DATAPACK.read_text(encoding="utf-8"))
    load_block(lua3, game="classic_era")
    t3 = lua3.globals().__TEST
    t3.Show()
    # classic_era is absent from the fixture -> forever fallback kicks in
    assert t3.svr.nodata["__shown"] is False
    assert t3.svr.total["__text"] == "200"

    print("SERVER WINDOW TEST OK")


if __name__ == "__main__":
    main()
