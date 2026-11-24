#!/usr/bin/env python3
"""zoneId должен описывать ту же зону, что и текст записи.

Дефект, найденный по живому SavedVariables 25.11.2026: у 361 записи из 59 375
текст зоны принадлежал одной зоне, а zoneId — другой. Живые примеры из файла:

    Xana Thar   text='Штормград'  zoneId=1436   (настоящий Stormwind — 1453)
    Wynn Fury   text="Шен'дралас" zoneId=1453   (настоящий — 2652)

Причина — в UpsertPlayer: ростер гильдии отдаёт зону ТЕКСТОМ и вообще без id
(HandleGuildRoster), /who до появления вшитой таблицы резолвил не всякое имя.
Текст обновлялся, а id оставался от прежнего наблюдения.

Почему это стало важным именно сейчас: 1.6.3 перевела колонку ZONE и подсказку
на ZoneDisplay(id) — имя строится по id, поэтому запись с расхождением начала
показывать ЧУЖУЮ зону (до этого показывался текст, и он был верный), а на сайт
уходил неверный zoneId.

Тест держит две вещи:
  1. NspFixZoneIds — разовый проход по базе: конфликт решается в пользу текста,
     отсутствующий id досстанавливается, след снятой пробы (probe/probeOn)
     удаляется, повторный вызов ничего не считает;
  2. UpsertPlayer — новый конфликт больше не создаётся: источник без id
     (ростер гильдии) пересчитывает id по тексту.

Run: python tests/test_zone_id_fix.py
"""
from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

from nsp_helpers import CONST_PRELUDE, REC_PRELUDE

ADDON = Path(__file__).resolve().parents[1]
SOURCE = ADDON / "NearbySpy.lua"
ZONES = ADDON / "NearbySpy_Zones.lua"


def zone_names_block() -> str:
    """Настоящая таблица зон билда + настоящая ZoneIdByName (не заглушка)."""
    src = SOURCE.read_text(encoding="utf-8")
    start = src.index("function ZoneIdByName(name)")
    end = src.index("-- ZoneNameById", start)
    return ("ZoneMapRefresh = function() end\n"
            "ZoneMapInit = function() return {}, {} end\n"
            + ZONES.read_text(encoding="utf-8") + "\n" + src[start:end])


def fix_block() -> str:
    """Настоящий NspFixZoneIds целиком (вместе с версией)."""
    src = SOURCE.read_text(encoding="utf-8")
    start = src.index("NSP_ZONE_FIX_VERSION = 1")
    end = src.index("-- ============ helpers shared with world collection", start)
    return src[start:end]


def resolve_block() -> str:
    """Настоящий NspResolveZoneId: при СОЗДАНИИ записи id ставит он, а не фикс
    в UpsertPlayer. Заглушка из REC_PRELUDE сделала бы тест слепым к этому пути."""
    src = SOURCE.read_text(encoding="utf-8")
    start = src.index("function NspResolveZoneId(entry)")
    end = src.index("-- Версия разового прохода", start)
    return src[start:end]


def upsert_block() -> str:
    src = SOURCE.read_text(encoding="utf-8")
    start = src.index("local QueuePeerNew -- assigned below")
    end = src.index("-- Opt-in, realm-local peer exchange.")
    return src[start:end]


class ZoneIdFixMigration(unittest.TestCase):
    """NspFixZoneIds: разовый проход по базе (настоящий код в Lua 5.1)."""

    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        # REC_PRELUDE даёт настоящую позиционную схему NSP_REC вместе с её
        # метатаблицей: миграция читает rec.zone / rec.zoneId по ИМЕНАМ полей,
        # и на голой таблице с числовыми слотами она не увидела бы ничего
        # (тест доказывал бы работу на данных, которых в файле не бывает).
        self.lua.execute(
            "RING = {}\n"
            "function R(msg) RING[#RING + 1] = tostring(msg) end\n"
            + REC_PRELUDE + "\n"
            + zone_names_block() + "\n"
            + fix_block() + "\n"
            "function mk(t) return setmetatable(t, NSP_REC.MT) end\n"
        )
        self.g = self.lua.globals()

    def db_with(self, players_lua: str, probe: bool = False) -> None:
        extra = "probe = { namespaces = { C_Map = 'x' } }, probeOn = true," if probe else ""
        self.lua.execute("DB = { players = { " + players_lua + " }, debug = {}, " + extra + " }")

    def rec(self, key: str):
        return self.g["DB"]["players"][key]

    def test_conflicting_id_is_corrected_by_zone_text(self):
        """Текст «Штормград», id 1436 → id становится 1453 (настоящий Stormwind)."""
        self.db_with('["Xana Thar-R"] = mk{ [1] = "Xana Thar", [5] = "Штормград", [6] = 1436 },')
        self.g["NspFixZoneIds"](self.g["DB"])
        self.assertEqual(1453, int(self.rec("Xana Thar-R")[6]))
        self.assertEqual(1, int(self.g["DB"]["debug"]["zoneIdFixed"]))

    def test_conflict_with_apostrophe_zone_is_corrected(self):
        """«Шен'дралас» с id Штормграда — реальный случай из файла."""
        self.db_with('["Wynn Fury-R"] = mk{ [5] = "Шен\'дралас", [6] = 1453 },')
        self.g["NspFixZoneIds"](self.g["DB"])
        self.assertEqual(2652, int(self.rec("Wynn Fury-R")[6]))

    def test_missing_id_is_restored(self):
        """Запись с текстом и без id получает его тем же проходом."""
        self.db_with('["Nobody-R"] = mk{ [5] = "Durotar" },')
        self.g["NspFixZoneIds"](self.g["DB"])
        self.assertEqual(1411, int(self.rec("Nobody-R")[6]))
        self.assertEqual(1, int(self.g["DB"]["debug"]["zoneIdAdded"]))

    def test_consistent_record_is_left_alone(self):
        """Текст и id описывают одну зону — трогать нечего, счётчики молчат."""
        self.db_with('["Ok-R"] = mk{ [5] = "Durotar", [6] = 1411 },')
        self.g["NspFixZoneIds"](self.g["DB"])
        self.assertEqual(1411, int(self.rec("Ok-R")[6]))
        self.assertEqual(0, int(self.g["DB"]["debug"]["zoneIdFixed"]))
        self.assertEqual(0, int(self.g["DB"]["debug"]["zoneIdAdded"]))
        self.assertEqual(0, int(self.lua.eval("#RING")))

    def test_record_without_zone_survives(self):
        """Запись из чата/пира без зоны: ни id, ни падения."""
        self.db_with('["Ghost-R"] = mk{ [1] = "Ghost" },')
        self.g["NspFixZoneIds"](self.g["DB"])  # не должно бросить
        self.assertIsNone(self.rec("Ghost-R")[6])

    def test_probe_leftovers_are_removed(self):
        """След снятой API-пробы (08.11) в коде не читается — вычищается."""
        self.db_with("", probe=True)
        self.g["NspFixZoneIds"](self.g["DB"])
        self.assertIsNone(self.g["DB"]["probe"], "probe остался в файле")
        self.assertIsNone(self.g["DB"]["probeOn"], "probeOn остался в файле")
        self.assertTrue(self.g["DB"]["debug"]["probePruned"])

    def test_second_call_is_a_noop(self):
        """Флаг версии: повторный вход не пересчитывает базу заново."""
        self.db_with('["Xana Thar-R"] = mk{ [5] = "Штормград", [6] = 1436 },')
        self.g["NspFixZoneIds"](self.g["DB"])
        self.assertEqual(1, int(self.g["DB"]["zoneIdFixed"]))
        self.g["NspFixZoneIds"](self.g["DB"])
        self.assertEqual(1, int(self.g["DB"]["zoneIdFixed"]), "проход выполнен дважды")
        self.assertEqual(1, int(self.g["DB"]["zoneIdFixed"]))

    def test_reports_to_the_diagnostic_ring(self):
        self.db_with('["Xana Thar-R"] = mk{ [5] = "Штормград", [6] = 1436 },')
        self.g["NspFixZoneIds"](self.g["DB"])
        ring = self.lua.eval("RING[#RING]")
        self.assertIn("zoneId fix: 1 corrected", ring)

    def test_non_table_and_empty_db(self):
        self.g["NspFixZoneIds"](None)      # не должно бросить
        self.g["NspFixZoneIds"](42)
        self.lua.execute("DB = {}")
        self.g["NspFixZoneIds"](self.g["DB"])
        self.assertEqual(1, int(self.g["DB"]["zoneIdFixed"]), "флаг не выставлен — проход повторится впустую")


class UpsertKeepsZoneIdInSync(unittest.TestCase):
    """UpsertPlayer: апдейт без id (ростер гильдии) пересчитывает id по тексту."""

    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(
            CONST_PRELUDE + "\n" + REC_PRELUDE + "\n" + zone_names_block() + "\n"
            + resolve_block() + "\n"
            "time = function() return 1000 end\n"
            "function Round4(v) if v == nil then return nil end "
            "return math.floor(v * 10000 + 0.5) / 10000 end\n"
            "local function P() end\n"
            "local function D() end\n"
            "local function DbgErr() end\n"
            "function PeerEsc(s) return tostring(s) end\n"
            "function ClassLocFromFile() return nil end\n"
            "function PlayerRealm() return 'R' end\n"
            "newThisSession = 0\n"
            "DB = {players = {}, debug = {}, game = 'forever'}\n"
            "function GetDB() return DB end\n"
            + upsert_block().replace(
                "local QueuePeerNew -- assigned below; only local discoveries may call it",
                "local QueuePeerNew")
            + "\nQueuePeerNew = function() end\n"
            "TestUpsert = UpsertPlayer\n"
            "TestDB = DB\n"
        )
        self.g = self.lua.globals()

    def upsert(self, **fields):
        data = {"key": "Alice-R", "name": "Alice", "realm": "R", "class": "MAGE",
                "level": 20, "faction": "Alliance", "source": "guild", "silent": True}
        data.update(fields)
        self.g["TestUpsert"](self.g["TestDB"], self.lua.table_from(data))
        return self.g["TestDB"]["players"]["Alice-R"]

    def test_guild_update_without_id_resolves_zone_text(self):
        """Ростер отдаёт зону без id: id обязан следовать за текстом."""
        rec = self.upsert(zone="Штормград")
        self.assertEqual(1453, int(rec.zoneId),
                         "id не пересчитан по тексту — окно покажет чужую зону")

    def test_guild_move_to_another_zone_updates_id(self):
        """Игрок переехал (по ростеру) — id не должен остаться от прежней зоны."""
        self.upsert(zone="Штормград")
        rec = self.upsert(zone="Durotar")
        self.assertEqual(1411, int(rec.zoneId), "id остался от прежней зоны")
        self.assertEqual("Durotar", rec.zone)

    def test_explicit_id_beats_zone_text(self):
        """Пришедший от источника id приоритетнее догадки по названию."""
        rec = self.upsert(zone="Штормград", zoneId=1420)
        self.assertEqual(1420, int(rec.zoneId))

    def test_unknown_zone_text_does_not_wipe_id(self):
        """Имя, которого нет в таблице, не обнуляет известный id."""
        self.upsert(zone="Штормград")
        rec = self.upsert(zone="Какая-то новая зона")
        self.assertEqual(1453, int(rec.zoneId), "известный id потерян на незнакомом имени")


if __name__ == "__main__":
    unittest.main(verbosity=2)
