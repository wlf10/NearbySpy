"""Имя зоны в окне — всегда на языке текущего клиента (Lua 5.1).

Дефект: в колонке ZONE и в подсказке выводился сырой текст из записи, а записи
копились сессиями на разных клиентах. На немецком клиенте это выглядело
смешанным набором языков — замер по живому SV 24.11.2026:

    1417 -> «Нагорье Арати» ×447, «Arathihochland» ×5, «Arathi Highlands» ×1
    1420 -> «Тирисфальские леса» ×1732, «Тихий Омут» ×4, ...

uiMapID одинаков в любой локали, поэтому имя берётся по нему через
C_Map.GetMapInfo(id).name (на deDE клиент сам отдаёт «Arathihochland»).

Фолбэк на сохранённый текст обязателен: zoneId есть у 82% записей, а у записи
из канала зоны нет вовсе — такое должно честно показывать «?».
"""

from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

SOURCE = Path(__file__).resolve().parents[1] / "NearbySpy.lua"


def display_block() -> str:
    """Настоящий код: ZoneNameById + ZoneDisplay (порядок в файле сохранён)."""
    src = SOURCE.read_text(encoding="utf-8")
    start = src.index("function ZoneNameById(id)")
    end = src.index("-- ============ helpers shared with world collection")
    return src[start:end]


class ZoneDisplayTest(unittest.TestCase):
    def make(self, names: dict, locale_names: bool = True):
        """C_Map с заданным словарём id -> имя (как его отдаёт клиент)."""
        lua = LuaRuntime(unpack_returned_tuples=True)
        entries = ",".join("[%d]=%r" % (k, v) for k, v in names.items())
        prelude = (
            "MAP = {%s}\n" % entries.replace("'", '"')
            + "C_Map = { GetMapInfo = function(id) "
            "  if MAP[id] then return { mapID = id, name = MAP[id] } end "
            "  return nil end }\n"
            + "canaccessvalue = nil\n"
            + "ZoneMapInit = function() return {}, {} end\n"
        )
        lua.execute(prelude + display_block() + "\n")
        return lua

    def test_german_client_shows_german_name(self):
        """Русский текст в записи, немецкий клиент → немецкое имя из клиента."""
        lua = self.make({1417: "Arathihochland", 1429: "Wald von Elwynn"})
        d = lua.globals()["ZoneDisplay"]
        self.assertEqual(str(d(1417, "Нагорье Арати")), "Arathihochland")
        self.assertEqual(str(d(1429, "Элвиннский лес")), "Wald von Elwynn")

    def test_id_wins_over_saved_text(self):
        """Даже если сохранённый текст на языке клиента — берём имя по id.

        Иначе одна и та же зона показывалась бы двумя разными строками в
        зависимости от того, какой сессией сделана запись.
        """
        lua = self.make({1420: "Tirisfal"})
        d = lua.globals()["ZoneDisplay"]
        self.assertEqual(str(d(1420, "Tirisfal")), "Tirisfal")
        # подлокация в слоте («Тихий Омут») схлопывается в имя своей зоны
        self.assertEqual(str(d(1420, "Тихий Омут")), "Tirisfal")

    def test_unknown_id_falls_back_to_text(self):
        """id есть, но клиент его не знает — показываем сохранённый текст."""
        lua = self.make({})
        d = lua.globals()["ZoneDisplay"]
        self.assertEqual(str(d(99999, "Дуротар")), "Дуротар")

    def test_no_id_keeps_text(self):
        """18% базы без zoneId — текст остаётся, зона не теряется."""
        lua = self.make({})
        d = lua.globals()["ZoneDisplay"]
        for zid in (0, None, False, "0"):
            self.assertEqual(str(d(zid, "Дуротар")), "Дуротар",
                             "зона потеряна при zoneId=%r" % (zid,))

    def test_peer_record_without_zone_is_question_mark(self):
        """Запись из канала: ни id, ни зоны — честный «?», без выдумки."""
        lua = self.make({})
        d = lua.globals()["ZoneDisplay"]
        for zid, ztext in ((0, None), (0, ""), (0, "?"), (None, None)):
            self.assertEqual(str(d(zid, ztext)), "?",
                             "ожидался «?» при (%r, %r)" % (zid, ztext))

    def test_zone_text_is_a_number_string(self):
        """Слоты позиционные: id может прийти строкой из SV — не падаем."""
        lua = self.make({1454: "Orgrimmar"})
        d = lua.globals()["ZoneDisplay"]
        self.assertEqual(str(d("1454", "Оргриммар")), "Orgrimmar")
        self.assertEqual(str(d("abc", "Оргриммар")), "Оргриммар")


if __name__ == "__main__":
    unittest.main(verbosity=2)
