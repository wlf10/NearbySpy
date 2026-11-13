#!/usr/bin/env python3
"""Compile every addon lua file in the real Lua 5.1 runtime.

Why not a Lua parser: luaparser accepts constructs the client rejects (a bare
`...` inside a non-vararg closure passed the parser and failed to load in game
on 11.10.2026, taking the whole addon down). This runs the same loadstring()
the client runs, so a green result means the file actually loads.

Usage: python tests/lua51_compile.py   (exit 1 on any failure)
Requires lupa (pip install lupa).
"""
from pathlib import Path
import sys

from lupa.lua51 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]
FILES = sorted(ROOT.glob("*.lua")) + sorted((ROOT / "NearbySpy_Data").glob("*.lua"))

failed = 0
for path in FILES:
    lua = LuaRuntime()
    lua.globals()["CHUNK"] = path.read_text(encoding="utf-8")
    try:
        lua.execute("local f, err = loadstring(CHUNK); if not f then error(err, 0) end")
        print(f"COMPILE OK   {path.relative_to(ROOT)}")
    except Exception as exc:  # noqa: BLE001 - any failure means "client rejects the file"
        failed += 1
        print(f"COMPILE FAIL {path.relative_to(ROOT)}: {exc}")

if not FILES:
    print("no lua files found")
    sys.exit(1)
sys.exit(1 if failed else 0)
