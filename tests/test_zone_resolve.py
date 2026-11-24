"""Зона без id: таблица билда не должна конфликтовать с кэшем клиента.

Два дефекта, найденные по живому SV 24.11.2026 (оба мои):

1. КРИТИЧНО — имя глобала. Вшитая таблица называлась `NSP_ZONE_BY_NAME`, а это
   имя УЖЕ занято кэшем клиентского словаря (`ZoneMapInit` проверяет его как
   флаг «словарь построен» и обнуляет в `ZoneMapRefresh`). `NearbySpy.lua`
   объявляет `NSP_ZONE_BY_NAME = nil` при загрузке — то есть таблица из 7749
   имён стиралась через мгновение после создания и не работала НИКОГДА.
   Тест держит имена разными: таблица — `NSP_ZONE_TABLE`, кэш — `..._BY_NAME`.

2. Записи с зоной-текстом и без id оставались без id: peer-пакет с zoneId=0,
   чат. Резолв делает `NspResolveZoneId`. Замер: 72 записи из 209.
"""

from pathlib import Path
import re
import unittest

from lupa.lua51 import LuaRuntime

HERE = Path(__file__).resolve().parents[1]
SOURCE = HERE / "NearbySpy.lua"
ZONES = HERE / "NearbySpy_Zones.lua"


def zone_id_block() -> str:
    src = SOURCE.read_text(encoding="utf-8")
    start = src.index("function ZoneIdByName(name)")
    end = src.index("-- ZoneNameById", start)
    return src[start:end]


def resolve_block() -> str:
    src = SOURCE.read_text(encoding="utf-8")
    start = src.index("function NspResolveZoneId(entry)")
    end = src.index("-- ============ helpers shared with world collection", start)
    return src[start:end]


class NameCollisionTest(unittest.TestCase):
    """Таблица билда и кэш клиента — РАЗНЫЕ глобалы."""

    def test_table_uses_its_own_global(self):
        src = ZONES.read_text(encoding="utf-8")
        self.assertIn("NSP_ZONE_TABLE", src)
        self.assertNotIn(
            "NSP_ZONE_BY_NAME", src,
            "таблица пишет в глобал кэша клиента — он её обнулит при загрузке")

    def test_main_file_nils_the_cache_not_the_table(self):
        """`NSP_ZONE_BY_NAME = nil` в NearbySpy.lua не должен убивать таблицу.

        Строка-обнуление — это инициализация кэша клиента; проверяем, что
        таблица билда живёт в другом имени и не упоминается в этих строках.
        """
        src = SOURCE.read_text(encoding="utf-8")
        for m in re.finditer(r"^\s*(local\s+)?NSP_ZONE_BY_NAME,\s*NSP_ZONE_NAME_BY_ID\s*=\s*nil",
                             src, re.M):
            line = m.group(0)
            self.assertNotIn("NSP_ZONE_TABLE", line)
        # и обратное: таблица читается под своим именем
        self.assertIn("local t = NSP_ZONE_TABLE", src)

    def test_table_survives_cache_reset(self):
        """Сброс кэша клиента (ZoneMapRefresh) не трогает таблицу билда.

        Воспроизводим порядок загрузки: сначала таблица (NearbySpy_Zones.lua),
        затем строка инициализации кэша из NearbySpy.lua.
        """
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute(ZONES.read_text(encoding="utf-8"))
        before = lua.eval('(function() local c=0 for _ in pairs(NSP_ZONE_TABLE) do c=c+1 end return c end)()')
        self.assertEqual(int(before), 7749, "таблица не загрузилась")
        # ровно то, что делает NearbySpy.lua при старте и в ZoneMapRefresh
        lua.execute("NSP_ZONE_BY_NAME, NSP_ZONE_NAME_BY_ID = nil, nil")
        after = lua.eval('(function() local c=0 for _ in pairs(NSP_ZONE_TABLE) do c=c+1 end return c end)()')
        self.assertEqual(int(after), 7749, "сброс кэша уничтожил таблицу билда")
        self.assertEqual(int(lua.eval('NSP_ZONE_TABLE["tirisfal"]')), 1420)


class ResolveZoneIdTest(unittest.TestCase):
    """Запись с зоной-текстом и без id получает id из таблицы."""

    def make(self):
        lua = LuaRuntime(unpack_returned_tuples=True)
        prelude = (
            "ZoneMapRefresh = function() end\n"
            "ZoneMapInit = function() return {}, {} end\n"
        )
        lua.execute(prelude + ZONES.read_text(encoding="utf-8") + "\n"
                    + zone_id_block() + "\n" + resolve_block() + "\n")
        return lua

    def run_resolve(self, zone, zone_id=None):
        lua = self.make()
        g = lua.globals()
        entry = lua.table(zone=zone)
        if zone_id is not None:
            entry["zoneId"] = zone_id
        g["NspResolveZoneId"](entry)
        return entry["zoneId"]

    def test_peer_record_without_id_gets_it(self):
        """Peer прислал имя, но не id (zoneId=0) — id восстанавливается."""
        self.assertEqual(int(self.run_resolve("Orgrimmar", False)), 1454)
        self.assertEqual(int(self.run_resolve("Durotar", False)), 1411)
        self.assertEqual(int(self.run_resolve("Feralas", False)), 1444)
        self.assertEqual(int(self.run_resolve("The Barrens", False)), 1413)

    def test_chat_record_zone_gets_id(self):
        """Зона, доехавшая от другого источника, тоже получает id."""
        self.assertEqual(int(self.run_resolve("Tirisfal", 0)), 1420)
        self.assertEqual(int(self.run_resolve("Klingenhügel")), 1411)

    def test_existing_id_is_never_overwritten(self):
        """Известный id — факт наблюдения, текст его не перебивает."""
        self.assertEqual(int(self.run_resolve("Orgrimmar", 1413)), 1413,
                         "известный zoneId перезаписан по тексту зоны")

    def test_unknown_and_empty_zone_is_left_alone(self):
        lua = self.make()
        g = lua.globals()
        for zone in ("Такой зоны нет", "", "?"):
            entry = lua.table(zone=zone)
            g["NspResolveZoneId"](entry)
            self.assertFalse(entry["zoneId"], "появился id у зоны %r" % zone)
        # запись без зоны вовсе: не падаем
        entry = lua.table()
        g["NspResolveZoneId"](entry)
        self.assertFalse(entry["zoneId"])

    def test_non_table_is_ignored(self):
        """Защита от мусора: pcall-пути передают что угодно."""
        lua = self.make()
        g = lua.globals()
        for bad in (None, 42, "Orgrimmar"):
            g["NspResolveZoneId"](bad)  # не должно бросить


if __name__ == "__main__":
    unittest.main(verbosity=2)
