"""Shared helpers for the Lua 5.1 tests.

Since 09.11.2026 the addon is two files: NearbySpy_Locale.lua (the UI strings
and the shared constants table NSP_CONST) and NearbySpy.lua (the logic). The
tests slice pieces OUT of NearbySpy.lua and run them in isolation, so the
sliced chunk no longer sees the constants table — every such test has to load
it first.

Use CONST_PRELUDE in the Lua source you execute:

    self.lua.execute(CONST_PRELUDE + "\\n" + block + "\\nTestX = X\\n")

The prelude defines NSP_CONST only; it does not touch the client's globals.
"""

from pathlib import Path

ADDON_DIR = Path(__file__).resolve().parents[1]
LOCALE_FILE = ADDON_DIR / "NearbySpy_Locale.lua"


def const_prelude() -> str:
    """The NSP_CONST table as Lua source, ready to execute before a chunk."""
    src = LOCALE_FILE.read_text(encoding="utf-8")
    start = src.index("NSP_CONST = {")
    end = src.index("\n}", start) + 2
    return src[start:end]


CONST_PRELUDE = const_prelude()
