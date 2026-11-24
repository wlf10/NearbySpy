"""Обратный поиск зоны: текст из /who -> uiMapID (Lua 5.1).

`/who` отдаёт зону только текстом на языке клиента, id в ответе нет, а C_Map
умеет лишь обратное направление (id -> имя). Поэтому в аддоне есть вшитая
таблица `NSP_ZONE_BY_NAME` (генерируется `scripts/gen_zones.py` из DB2 точного
билда). Тест проверяет именно НАСТОЯЩИЙ файл таблицы и настоящую
`ZoneIdByName`, а не их пересказ: рассинхрон генератора с клиентом иначе
остаётся незамеченным.

Живой замер 24.11.2026 (билд 1.60.1.71037): таблица разрешает 1131 название из
1189 и поднимает покрытие zoneId с 82.0% до 97.1% записей SV.
"""

from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

HERE = Path(__file__).resolve().parents[1]
SOURCE = HERE / "NearbySpy.lua"
ZONES = HERE / "NearbySpy_Zones.lua"


def zone_id_block() -> str:
    """Настоящая ZoneIdByName из NearbySpy.lua."""
    src = SOURCE.read_text(encoding="utf-8")
    start = src.index("function ZoneIdByName(name)")
    end = src.index("-- ZoneNameById", start)
    return src[start:end]


class ZoneIdByNameTest(unittest.TestCase):
    def make(self, with_table=True):
        lua = LuaRuntime(unpack_returned_tuples=True)
        prelude = (
            # клиентский словарь пуст: как на этом клиенте, где обход дерева
            # карт отдаёт только 117 загруженных карт
            "ZoneMapRefresh = function() end\n"
            "ZoneMapInit = function() return {}, {} end\n"
        )
        if with_table:
            prelude += ZONES.read_text(encoding="utf-8") + "\n"
        lua.execute(prelude + zone_id_block() + "\n")
        return lua

    def test_german_zone_names_resolve(self):
        """Немецкие имена из /who на deDE клиенте."""
        d = self.make().globals()["ZoneIdByName"]
        self.assertEqual(d("Tirisfal"), 1420)
        self.assertEqual(d("Arathihochland"), 1417)
        self.assertEqual(d("Wald von Elwynn"), 1429)
        self.assertEqual(d("Das Brachland"), 1413)

    def test_other_locale_names_resolve(self):
        """Тот же id находится по имени на любом языке: SV копит все сессии.

        В живом SV рядом лежат «Штормград», «Stormwind City»,
        «Ciudad de Ventormenta» — все про 1453.
        """
        d = self.make().globals()["ZoneIdByName"]
        for name in ("Штормград", "Stormwind City", "Ciudad de Ventormenta",
                     "Sturmwind", "Hurlevent", "暴风城"):
            self.assertEqual(d(name), 1453, "не разрешилось: %r" % name)

    def test_subzone_maps_to_its_zone(self):
        """Подлокации из /who дают id своей зоны — это и был главный пробел.

        До таблицы такие записи оставались без zoneId (18% базы): клиент их
        не знает, а «имя -> id» не умеет вовсе.
        """
        d = self.make().globals()["ZoneIdByName"]
        self.assertEqual(d("Gadgetzan"), 1446)        # Танарис
        self.assertEqual(d("Могильник"), 1420)        # Тирисфаль
        self.assertEqual(d("Долина Испытаний"), 1411)  # Дуротар

    def test_case_insensitive(self):
        """Регистр не важен: ключи таблицы в нижнем регистре."""
        d = self.make().globals()["ZoneIdByName"]
        self.assertEqual(d("TIRISFAL"), 1420)
        self.assertEqual(d("tirisfal"), 1420)
        self.assertEqual(d("TiRiSfAl"), 1420)

    def test_unknown_name_returns_nil(self):
        """Чего нет в таблице — nil, и вызывающий шлёт текст (зону не теряем)."""
        d = self.make().globals()["ZoneIdByName"]
        self.assertIsNone(d("Такой зоны нет"))
        self.assertIsNone(d(""))
        self.assertIsNone(d(None))

    def test_works_without_the_table_file(self):
        """Файл таблицы не загружен (старая установка) — аддон не падает."""
        d = self.make(with_table=False).globals()["ZoneIdByName"]
        self.assertIsNone(d("Tirisfal"))

    def test_table_is_the_generated_one(self):
        """Таблица — та, что сгенерирована, а не остаток правок руками."""
        src = ZONES.read_text(encoding="utf-8")
        self.assertIn("НЕ ПРАВИТЬ РУКАМИ", src)
        self.assertIn("1.60.1.71037", src)


if __name__ == "__main__":
    unittest.main(verbosity=2)
