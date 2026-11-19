#!/usr/bin/env python3
"""NspPrune — чистка старых записей: что удаляется, а что обязано остаться.

Прунинг необратим: локальный SavedVariables — единственная копия, которую можно
переслать повторно, а peer-записи на сайт больше НЕ приходят. Поэтому правила
ниже — контракт, а не описание кода:

  1. удаляется ТОЛЬКО запись, чьё последнее наблюдение старше срока;
  2. по умолчанию (срок не задан) не удаляется НИЧЕГО;
  3. свежие записи не трогаются, даже если они peer-ные;
  4. справочники (world, learn), журнал (journal) и диагностика (debug)
     не удаляются никогда — они не растут с числом встреч;
  5. кольцо экипировки не копит ключи удалённых записей;
  6. запись без единого времени наблюдения НЕ удаляется: неизвестно, старая
     она или нет, а «неизвестно» в пользу сохранения.

Запуск: python tests/test_prune.py
"""
import unittest
from pathlib import Path

from lupa.lua51 import LuaRuntime

ADDON = Path(__file__).resolve().parents[1] / "NearbySpy.lua"

PRELUDE = """
NOW = 1795080000
time = function() return NOW end
date = os.date
function PStub() end
DEFAULT_CHAT_FRAME = { AddMessage = function() end }
NSP_CONST = { PREFIX = "NearbySpy: " }
NSP_LOCALE = { enUS = {} }
GetLocale = function() return "enUS" end
GetBuildInfo = function() return "1.60.1", "70291", "Nov 13 2026", 16001 end
GetRealmName = function() return "Test Realm" end
CreateFrame = function() return { RegisterEvent = function() end,
    SetScript = function() end, HookScript = function() end } end
UIParent = {}
WorldFrame = { HookScript = function() end }
C_Timer = { After = function() end }
SlashCmdList = {}
PlayerUtil = { GetCurrentSpecID = function() return 0 end }
canaccessvalue = function() return true end
Enum = { TraitNodeType = { Single = 0, Tiered = 1, Selection = 2 } }
"""


def prune_source() -> str:
    """Вырезает функцию NspPrune из аддона целиком.

    Границы берутся по ЯВНЫМ маркерам, а не подсчётом `end`: в теле есть
    `end)` внутри pcall-подобных конструкций и многострочные условия, из-за
    чего наивный счётчик промахивается (проверено — тест не собирался).
    """
    src = ADDON.read_text(encoding="utf-8")
    start = src.index("function NspPrune(db, retainDays, now)")
    tail_marker = 'local frame = CreateFrame("Frame")'
    end = src.index(tail_marker, start)
    return src[start:end]


class PruneTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(PRELUDE)
        self.lua.execute(prune_source())
        self.prune = self.lua.globals()["NspPrune"]
        self.db = self.lua.table()
        self.db["players"] = self.lua.table()

    # -- helpers -----------------------------------------------------------
    def player(self, key, seen_days_ago, source="unit", **extra):
        now = int(self.lua.eval("NOW"))
        seen = now - int(seen_days_ago * 86400)
        rec = {"name": key, "realm": "Test Realm", "class": "MAGE",
               "level": 30, "source": source, "count": 1, "lastSeen": seen,
               "firstSeen": seen}
        for k, v in extra.items():
            rec[k] = v
        self.db["players"][key] = self.lua.table_from(rec)

    def run_prune(self, days, now=None):
        if now is None:
            now = int(self.lua.eval("NOW"))
        return self.prune(self.db, days, now)

    def count(self):
        return len(list(self.db["players"].values()))

    # -- rules -------------------------------------------------------------
    def test_nothing_is_deleted_when_disabled(self):
        for i in range(5):
            self.player(f"old{i}", 100)
        removed, kept = self.prune(self.db, None, int(self.lua.eval("NOW")))
        self.assertEqual((int(removed), self.count()), (0, 5))
        removed, kept = self.prune(self.db, 0, int(self.lua.eval("NOW")))
        self.assertEqual((int(removed), self.count()), (0, 5))

    def test_old_records_are_removed_recent_are_kept(self):
        self.player("ancient", 40)
        self.player("recent", 1)
        self.player("borderline", 13)
        removed, kept = self.run_prune(14)
        self.assertEqual(int(removed), 1)          # только ancient
        self.assertEqual(self.count(), 2)
        self.assertIsNotNone(self.db["players"]["recent"])
        self.assertIsNotNone(self.db["players"]["borderline"])
        self.assertIsNone(self.db["players"]["ancient"])

    def test_peer_records_older_than_window_go_too(self):
        # peer-записи весят больше всего в живом файле, поэтому окно их и чистит
        self.player("peerold", 30, source="peer", peerAt=1795080000 - 30 * 86400)
        self.player("peernew", 2, source="peer", peerAt=1795080000 - 2 * 86400)
        removed, _ = self.run_prune(14)
        self.assertEqual(int(removed), 1)
        self.assertIsNone(self.db["players"]["peerold"])
        self.assertIsNotNone(self.db["players"]["peernew"])

    def test_peer_at_is_used_when_last_seen_is_empty(self):
        # у peer-записи lastSeen пуст, время держит peerAt
        self.player("peeronly", 0, source="peer")
        rec = self.db["players"]["peeronly"]
        rec["lastSeen"] = 0
        rec["count"] = 0
        rec["peerAt"] = 1795080000 - 60 * 86400
        removed, _ = self.run_prune(14)
        self.assertEqual(int(removed), 1)
        self.assertIsNone(self.db["players"]["peeronly"])

    def test_record_without_any_time_is_kept(self):
        # «неизвестно, когда видели» — не повод удалять: решаем в пользу данных
        self.player("notime", 0)
        rec = self.db["players"]["notime"]
        rec["lastSeen"] = 0
        rec["firstSeen"] = 0
        removed, _ = self.run_prune(14)
        self.assertEqual(int(removed), 0)
        self.assertIsNotNone(self.db["players"]["notime"])

    def test_reference_and_journal_sections_are_never_touched(self):
        self.player("old", 100)
        self.db["world"] = self.lua.table_from({"vendors": {"1": {"name": "Trader"}}})
        self.db["learn"] = self.lua.table_from({"race": {"X": "HUMAN"}})
        self.db["journal"] = self.lua.table_from({"c": {"Wolfy": {"s": 3600}}})
        self.db["debug"] = self.lua.table_from({"printRing": {"line"}})
        self.run_prune(14)
        for key in ("world", "learn", "journal", "debug"):
            self.assertIsNotNone(self.db[key], f"{key} не должен удаляться")
        self.assertIsNone(self.db["players"]["old"])

    def test_gear_ring_drops_keys_of_removed_players(self):
        self.player("keep", 1)
        self.player("gone", 100)
        self.db["gearRing"] = self.lua.table_from(["keep", "gone"])
        self.run_prune(14)
        ring = [str(v) for v in self.db["gearRing"].values()]
        self.assertEqual(ring, ["keep"])

    def test_prune_is_idempotent_and_counted(self):
        for i in range(3):
            self.player(f"old{i}", 90)
        self.player("fresh", 1)
        r1, _ = self.run_prune(14)
        r2, _ = self.run_prune(14)          # второй прогон ничего не находит
        self.assertEqual(int(r1), 3)
        self.assertEqual(int(r2), 0)
        self.assertEqual(self.count(), 1)
        self.assertEqual(int(self.db["debug"]["pruned"]), 3)

    def test_non_table_record_is_dropped(self):
        self.db["players"]["junk"] = "not a table"
        removed, _ = self.run_prune(14)
        self.assertEqual(int(removed), 1)
        self.assertIsNone(self.db["players"]["junk"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
