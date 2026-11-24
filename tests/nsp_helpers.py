"""Shared helpers for the Lua 5.1 tests.

Since 09.11.2026 the addon is two files: NearbySpy_Locale.lua (the UI strings
and the shared constants table NSP_CONST) and NearbySpy.lua (the logic). The
tests slice pieces OUT of NearbySpy.lua and run them in isolation, so the
sliced chunk no longer sees anything declared ABOVE (or BELOW) the slice.

Use CONST_PRELUDE in the Lua source you execute:

    self.lua.execute(CONST_PRELUDE + "\\n" + block + "\\nTestX = X\\n")

The prelude defines NSP_CONST only; it does not touch the client's globals.

RACE_PRELUDE does the same for the race helpers. `ReceivePeerMessage` calls
`NspNormalizeRace`, which lives further down the file (next to RACE_LOCALE), so
any harness that slices the receiver must load it too — otherwise the tests die
on "attempt to call global 'NspNormalizeRace' (a nil value)" and prove nothing.
"""

from pathlib import Path

ADDON_DIR = Path(__file__).resolve().parents[1]
LOCALE_FILE = ADDON_DIR / "NearbySpy_Locale.lua"
ADDON_FILE = ADDON_DIR / "NearbySpy.lua"


def const_prelude() -> str:
    """The NSP_CONST table as Lua source, ready to execute before a chunk."""
    src = LOCALE_FILE.read_text(encoding="utf-8")
    start = src.index("NSP_CONST = {")
    end = src.index("\n}", start) + 2
    return src[start:end]


def race_prelude() -> str:
    """RACE_LOCALE plus the race normaliser, as one Lua chunk.

    Both pieces are cut from the addon so the tests exercise the real tables and
    the real function, not a copy. Empty when the tree predates them (a harness
    must still load and then fail on its assertions, not on a missing marker).
    """
    src = ADDON_FILE.read_text(encoding="utf-8")
    parts = []
    # NspNormalizeRace reads the code tables and PeerField, both declared above the
    # slice in production — so they travel with it here.
    if "NSP_PEER_CODES = {" in src:
        parts.append(src[src.index("NSP_PEER_CODES = {"):src.index("-- Peers now carry the place as well")])
    if "local function PeerField(s, maxLen)" in src:
        parts.append(src[src.index("local function PeerField(s, maxLen)"):
                          src.index("-- ── Коды для класса, расы и фракции")])
    if "local RACE_LOCALE = {" in src:
        parts.append(src[src.index("local RACE_LOCALE = {"):src.index("-- LearnedFactions")])
    if "function NspZoneNameSet(db)" in src:
        parts.append(src[src.index("function NspZoneNameSet(db)"):
                          src.index("-- Раньше хранилась ОДНА фракция на расу")])
    return "\n".join(parts)


def rec_prelude() -> str:
    """Позиционная схема записи (NSP_REC) плюс её конструктор, одним куском.

    С 1.7.0 запись игрока — массив из 23 слотов, и `UpsertPlayer` создаёт её
    через `NspNewPlayerRec`. Любой харнес, который вырезает `UpsertPlayer`,
    обязан принести и то, и другое: иначе он падает на
    "attempt to call global 'NspNewPlayerRec' (a nil value)" и не проверяет
    ничего о самом апсерте.

    Слоты берутся из настоящего файла локалей (там же метатаблица), а
    конструктор — из настоящего `NearbySpy.lua`: переписанная копия схемы в
    тесте разошлась бы с продакшном на первой правке порядка слотов.
    """
    loc = LOCALE_FILE.read_text(encoding="utf-8")
    start = loc.index("NSP_REC = {")
    end = loc.index("NSP_LOCALE = {", start)
    rec_block = loc[start:end]

    src = ADDON_FILE.read_text(encoding="utf-8")
    parts = [rec_block]
    marker = "function NspNewPlayerRec(key, data, observed, nowT)"
    if marker in src:
        ctor_start = src.index(marker)
        ctor_end = src.index("-- Приведение базы к позиционной схеме", ctor_start)
        parts.append(src[ctor_start:ctor_end])
    return "\n".join(parts)


CONST_PRELUDE = const_prelude()
RACE_PRELUDE = race_prelude()
REC_PRELUDE = rec_prelude()
