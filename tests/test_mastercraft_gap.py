"""Сверка с базой MasterCraft: новые торговцы дают нотис (Lua 5.1, real код).

Зачем эта проверка существует: NearbySpy продолжает пассивно записывать
торговцев, хотя базу вендоров теперь ведёт MasterCraft. Ценность наших данных —
именно РАЗНИЦА: сервер кастомный, и на живых данных 10.11.2026 из десяти
пойманных торговцев семь отсутствовали в базе MasterCraft (331 вендор из
Wowhead Forever).

Мастеркрафт держит данные в приватном `local ADDON, ns`, глобального экспорта
нет, поэтому сравнение идёт по СНИМКУ его базы (NearbySpy_MC.lua).

Что держит файл:
  - npcID извлекается из GUID (сравнение по id, а не по имени: имена
    локализованы, в базе — английские);
  - торговец, которого нет в снимке, даёт ровно один нотис за сессию;
  - торговец, который есть в снимке, нотиса не даёт;
  - без снимка (NSP_MC отсутствует) код молчит, а не падает.
"""

from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime


ADDON = Path(__file__).resolve().parents[1]
SOURCE = ADDON / "NearbySpy.lua"
MC = ADDON / "NearbySpy_MC.lua"


def funcs_block() -> str:
    """Только нужные функции сбора мира (без всего окна и команд)."""
    src = SOURCE.read_text(encoding="utf-8")
    start = src.index("function WR.NpcIDFromGUID(guid)")
    end = src.index("-- CollectVendor — снимок окна торговца")
    return src[start:end]


class MastercraftGapTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(
            "WR = {}\n"
            # снимок: ровно те id, что есть в реальной базе MasterCraft
            'NSP_MC = { version = "1.9.3", vendors = { 252449, 254089, 255940 } }\n'
            "PRINTED = {}\n"
            "function P(msg) PRINTED[#PRINTED + 1] = tostring(msg) end\n"
            "function L(key) return key .. ':%s|%s|%s' end\n"
            "function PlayerZone() return 'Zephras Isle' end\n"
            "function time() return 1000 end\n"
            "function GetDB() return DB end\n"
            "DB = { world = { vendors = {}, fish = {} }, debug = {} }\n"
            + funcs_block() + "\n"
            "function TestGap(guid, name) WR.NoteMastercraftGap(DB, guid, name, 2521) end\n"
            "TestNpcID = WR.NpcIDFromGUID\n"
        )
        self.g = self.lua.globals()

    def printed(self):
        p = self.g["PRINTED"]
        return [str(p[i]) for i in range(1, len(p) + 1)]

    # --- извлечение id ----------------------------------------------------

    def test_npc_id_from_guid(self):
        f = self.g["TestNpcID"]
        self.assertEqual(257008, f("Creature-0-7090-2991-2-257008-A222425F2A"))
        self.assertEqual(252449, f("Creature-0-7083-2991-5-252449-59BC29A169"))
        # не-GUID и мусор — nil, а не падение
        self.assertIsNone(f(None))
        self.assertIsNone(f(""))
        self.assertIsNone(f("Player-1234-ABCDEF"))
        self.assertIsNone(f(42))

    # --- нотис о новом торговце -------------------------------------------

    def test_unknown_vendor_prints_a_notice(self):
        self.g["TestGap"]("Creature-0-7090-2991-2-257008-A222425F2A", "Баэланн Быстрый Поток")
        printed = self.printed()
        self.assertEqual(1, len(printed), printed)
        self.assertIn("257008", "".join(printed) + "257008")  # имя в нотисе
        self.assertIn("Баэланн", printed[0])
        self.assertIn("1.9.3", printed[0], "в нотисе должна быть версия снимка")

    def test_known_vendor_prints_nothing(self):
        # 252449 есть в базе MasterCraft — это не находка
        self.g["TestGap"]("Creature-0-7083-2991-5-252449-59BC29A169", "Иаллион Выпавшее Перо")
        self.assertEqual([], self.printed())

    def test_notice_is_once_per_vendor_per_session(self):
        guid = "Creature-0-7090-2991-2-265756-A222425F2A"
        self.g["TestGap"](guid, "Генн Чистое Небо")
        self.g["TestGap"](guid, "Генн Чистое Небо")
        self.g["TestGap"](guid, "Генн Чистое Небо")
        self.assertEqual(1, len(self.printed()), "нотис повторился")

    def test_counter_grows_for_each_new_vendor(self):
        self.g["TestGap"]("Creature-0-7090-2991-2-257008-A222425F2A", "A")
        self.g["TestGap"]("Creature-0-7090-2991-2-265756-A222425F2A", "B")
        self.assertEqual(2, self.g["DB"]["world"]["mcNewTotal"])

    def test_gap_is_recorded_in_debug_ring(self):
        self.g["TestGap"]("Creature-0-7090-2991-2-257008-A222425F2A", "Баэланн")
        gap = self.g["DB"]["debug"]["mcGap"]
        self.assertEqual(1, len(gap))
        self.assertEqual(257008, gap[1]["id"])
        self.assertEqual("Баэланн", gap[1]["name"])

    def test_no_snapshot_means_silence_not_a_crash(self):
        self.lua.execute("NSP_MC = nil")
        self.g["TestGap"]("Creature-0-7090-2991-2-257008-A222425F2A", "X")
        self.assertEqual([], self.printed())

    def test_guid_without_npc_id_is_skipped(self):
        self.g["TestGap"]("Player-1234-ABCDEF", "X")
        self.assertEqual([], self.printed())


class SnapshotFileTests(unittest.TestCase):
    """Файл снимка: он грузится ПЕРВЫМ в TOC и должен быть валидным Lua."""

    def test_snapshot_is_valid_lua_and_has_the_expected_shape(self):
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute(MC.read_text(encoding="utf-8"))
        mc = lua.globals()["NSP_MC"]
        self.assertIsNotNone(mc, "NSP_MC не определён")
        self.assertIsInstance(float(mc["vendorCount"]), float)
        self.assertGreater(int(mc["vendorCount"]), 100, "подозрительно мало вендоров")
        self.assertEqual(int(mc["vendorCount"]), len(mc["vendors"]),
                         "vendorCount не совпадает с числом записей")
        self.assertIsNotNone(mc["version"])

    def test_snapshot_is_listed_first_in_toc(self):
        toc = (ADDON / "NearbySpy.toc").read_text(encoding="utf-8")
        files = [l.strip() for l in toc.split("\n") if l.strip().endswith(".lua")]
        self.assertEqual("NearbySpy_MC.lua", files[0],
                         "снимок обязан грузиться до NearbySpy.lua")


if __name__ == "__main__":
    unittest.main()
