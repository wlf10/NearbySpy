#!/usr/bin/env python3
"""Позиционная схема записи игрока: создание, чтение, миграция.

Зачем схема: база игроков — единственный раздел SavedVariables, который растёт
с числом встреч. Замер на живом файле (81 347 записей): hash-запись со всеми
полями занимает ~1.3 КБ памяти клиента, раздел целиком — 104.8 МБ из 113.
Позиционный массив из тех же значений — 0.6 КБ (Lua округляет array-часть до
степени двойки: 23 слота = 32 ячейки), раздел ≈ 61 МБ.

Правила, которые здесь закреплены (нарушение любого = тихая порча данных):

  1. все слоты заполнены всегда: `false` вместо nil — дырка в array-части
     обрывает и `#`, и запись SavedVariables;
  2. наружу `false` читается как nil — «нет данных» не должно отличаться от
     того, что видел старый код;
  3. `0` остаётся `0`: в Lua он truthy, поэтому сентинел «профиль без встречи»
     (count = 0) не путается с отсутствующим полем;
  4. чтение идёт по прежним именам (`p.class`), запись — тоже (`p.zone = x`):
     весь существующий код обязан работать без правок;
  5. hash-схема, уже лежащая в файлах игроков, переносится без потерь;
  6. миграция идемпотентна: второй прогон ничего не меняет;
  7. v2 (23 слота, с classLoc и key) переезжает в v3 (21 слот): classLoc и key
     НЕ переносятся — они выводимы (ClassLocFromFile, ключ таблицы), и именно
     их отсутствие даёт экономию памяти и файла.

Запуск: python tests/test_rec_schema.py
"""
import unittest

from lupa.lua51 import LuaRuntime

from nsp_helpers import REC_PRELUDE


def migration_source() -> str:
    """NspMigrateRecords целиком — по явным маркерам, не подсчётом `end`."""
    src = (__import__("pathlib").Path(__file__).resolve().parents[1] / "NearbySpy.lua").read_text(encoding="utf-8")
    start = src.index("function NspMigrateRecords(db)")
    end = src.index("-- shared record/upsert", start)
    return src[start:end]


class RecSchemaTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(REC_PRELUDE)
        self.lua.execute(migration_source())
        self.lua.execute("function time() return 1000 end")
        self.migrate = self.lua.globals()["NspMigrateRecords"]
        self.new_rec = self.lua.globals()["NspNewPlayerRec"]
        self.slots = int(self.lua.eval("NSP_REC.SLOTS"))

    # -- helpers -----------------------------------------------------------
    def make(self, data):
        return self.new_rec(data.get("key"), self.lua.table_from(data), True, 1000)

    def get(self, rec, field):
        return self.lua.eval(f'(function(r) return r["{field}"] end)')(rec)

    # -- создание ----------------------------------------------------------
    def test_all_slots_are_filled(self):
        rec = self.make({"key": "A-Realm", "name": "A", "source": "unit"})
        length = int(self.lua.eval("(function(r) return #r end)")(rec))
        self.assertEqual(length, self.slots, "array-часть короче SLOTS — слоты съедут")
        nil_count = int(self.lua.eval(
            "(function(r) local n=0 for i=1,NSP_REC.SLOTS do if rawget(r,i)==nil then n=n+1 end end return n end)")(rec))
        self.assertEqual(nil_count, 0, "в array-части есть nil — запись SV сломается")

    def test_fields_read_back_by_name(self):
        rec = self.make({"key": "A-Realm", "name": "A", "class": "MAGE",
                         "classLoc": "Маг", "level": 30, "realm": "Realm",
                         "zone": "Элвинн", "zoneId": 1429, "source": "unit",
                         "race": "Human", "faction": "Alliance", "guid": "P-1"})
        self.assertEqual(self.get(rec, "name"), "A")
        self.assertEqual(self.get(rec, "class"), "MAGE")
        # classLoc с v3 не хранится: ClassDisplayName выводит его из class
        self.assertIsNone(self.get(rec, "classLoc"))
        self.assertEqual(int(self.get(rec, "level")), 30)
        self.assertEqual(self.get(rec, "realm"), "Realm")
        self.assertEqual(self.get(rec, "zone"), "Элвинн")
        self.assertEqual(int(self.get(rec, "zoneId")), 1429)
        self.assertEqual(self.get(rec, "source"), "unit")
        self.assertEqual(self.get(rec, "guid"), "P-1")

    def test_missing_field_reads_as_nil(self):
        rec = self.make({"key": "A-Realm", "name": "A", "source": "unit"})
        for field in ("guid", "peerAt", "peerNew", "peerRealm", "peerForeign",
                      "peerFrom", "zone", "zoneId", "gear"):
            self.assertIsNone(self.get(rec, field),
                              f"{field} должен читаться как nil, а не false")

    def test_zero_is_not_nil(self):
        # профиль без встречи: count = 0 обязан остаться нулём (он truthy)
        rec = self.lua.globals()["NspNewPlayerRec"](
            "P-Realm", self.lua.table_from({"name": "P", "source": "peer"}), False, 1000)
        count = self.get(rec, "count")
        self.assertIsNotNone(count, "count = 0 потерялся — стал nil")
        self.assertEqual(int(count), 0)
        self.assertEqual(int(self.get(rec, "lastSeen")), 0)

    def test_peer_packet_fills_place_and_provenance(self):
        rec = self.make({"key": "P-Realm", "name": "P", "source": "peer",
                         "realm": "EU4", "zone": "Дуротар", "zoneId": 1411,
                         "x": 0.123456, "y": 0.654321,
                         "peerRealm": "EU4", "peerForeign": True,
                         "peerFrom": "Sender"})
        self.assertEqual(self.get(rec, "zone"), "Дуротар")
        self.assertTrue(self.get(rec, "peerNew"))
        self.assertTrue(self.get(rec, "peerForeign"))
        self.assertEqual(self.get(rec, "peerFrom"), "Sender")
        self.assertAlmostEqual(float(self.get(rec, "x")), 0.1235, places=4)

    def test_profile_only_has_no_place(self):
        # observe=false (ростер гильдии): места нет, встреча не засчитана
        rec = self.lua.globals()["NspNewPlayerRec"](
            "G-Realm", self.lua.table_from({"name": "G", "source": "guild",
                                            "zone": "Элвинн", "zoneId": 1429}), False, 1000)
        self.assertIsNone(self.get(rec, "zone"))
        self.assertIsNone(self.get(rec, "zoneId"))
        self.assertEqual(int(self.get(rec, "count")), 0)

    def test_key_and_classloc_are_not_stored(self):
        # v3: оба поля выводимы, поэтому слотов под них нет. Проверяем и чтение,
        # и ЛЮБУЮ попытку записать их по имени: запись мимо слота завела бы в
        # таблице именованный ключ, и SavedVariables записался бы словарём.
        rec = self.make({"key": "A-Realm", "name": "A", "class": "MAGE",
                         "classLoc": "Маг", "source": "unit"})
        self.assertIsNone(self.get(rec, "key"))
        self.assertIsNone(self.get(rec, "classLoc"))
        self.lua.eval('(function(r) r.key = "X"; r.classLoc = "Y" end)')(rec)
        # безымянных ключей в таблице быть не должно: только 1..SLOTS
        named = int(self.lua.eval(
            "(function(r) local n=0 for k,_ in pairs(r) do if type(k)~='number' then n=n+1 end end return n end)")(rec))
        self.assertEqual(named, 0, "появился именованный ключ — SV запишется словарём")

    # -- запись через метатаблицу -----------------------------------------
    def test_assignment_by_name_lands_in_slot(self):
        rec = self.make({"key": "A-Realm", "name": "A", "source": "unit"})
        self.lua.eval('(function(r) r.zone = "Оргриммар" end)')(rec)
        self.assertEqual(self.get(rec, "zone"), "Оргриммар")
        zone_raw = self.lua.eval('(function(r) return rawget(r, NSP_REC.zone) end)')(rec)
        self.assertEqual(zone_raw, "Оргриммар", "значение попало не в свой слот")

    def test_assigning_nil_writes_false(self):
        rec = self.make({"key": "A-Realm", "name": "A", "source": "unit",
                         "zone": "Элвинн"})
        self.lua.eval("(function(r) r.zone = nil end)")(rec)
        raw = self.lua.eval('(function(r) return rawget(r, NSP_REC.zone) end)')(rec)
        self.assertIs(raw, False, "nil в слоте рвёт array-часть")

    # -- миграция ---------------------------------------------------------
    def test_hash_record_is_converted_without_loss(self):
        db = self.lua.table()
        db["players"] = self.lua.table()
        db["players"]["Old-Realm"] = self.lua.table_from({
            "name": "Old", "class": "MAGE", "classLoc": "Маг", "level": 30,
            "realm": "Realm", "zone": "Элвинн", "zoneId": 1429,
            "lastSeen": 900, "firstSeen": 800, "count": 3,
            "source": "who", "race": "Human", "faction": "Alliance",
        })
        self.migrate(db)
        rec = db["players"]["Old-Realm"]
        self.assertEqual(self.get(rec, "name"), "Old")
        self.assertEqual(self.get(rec, "class"), "MAGE")
        self.assertEqual(self.get(rec, "zone"), "Элвинн")
        self.assertEqual(int(rec["lastSeen"]), 900)
        self.assertEqual(int(rec["count"]), 3)
        # classLoc и key в v3 не переносятся — они выводимы
        self.assertIsNone(self.get(rec, "key"))
        self.assertIsNone(self.get(rec, "classLoc"))
        self.assertEqual(int(db["recSchema"]), 3)

    def test_migration_is_idempotent(self):
        db = self.lua.table()
        db["players"] = self.lua.table()
        db["players"]["A-Realm"] = self.lua.table_from({
            "name": "A", "class": "MAGE", "level": 5, "realm": "Realm",
            "source": "unit", "count": 1, "lastSeen": 900,
        })
        self.migrate(db)
        first = self.lua.eval('(function(d) local r=d.players["A-Realm"] '
                              'return tostring(r.name).."|"..tostring(r.level) end)')(db)
        conv2, _ = self.migrate(db)
        second = self.lua.eval('(function(d) local r=d.players["A-Realm"] '
                               'return tostring(r.name).."|"..tostring(r.level) end)')(db)
        self.assertEqual(int(conv2), 0, "второй прогон снова что-то конвертировал")
        self.assertEqual(first, second)

    def test_metatable_is_reattached_after_reload(self):
        # После перезапуска игры записи приходят голыми массивами: клиент не
        # сохраняет метатаблицу. Проход обязан вернуть её, иначе p.class = nil.
        db = self.lua.table()
        db["players"] = self.lua.table()
        # v3: 21 слот, без classLoc и key
        db["players"]["A-Realm"] = self.lua.table_from(["A", "MAGE", 30,
                                                        "Realm", "Элвинн", 1429,
                                                        900, 800, 1, 0.5, 0.5,
                                                        "unit", "Human", "Alliance",
                                                        "P-1", False, False, False,
                                                        False, False, False])
        db["recSchema"] = 3
        self.assertIsNone(self.lua.eval('(function(d) return d.players["A-Realm"].class end)')(db))
        self.migrate(db)
        self.assertEqual(self.lua.eval('(function(d) return d.players["A-Realm"].class end)')(db), "MAGE")

    def test_v2_record_migrates_to_v3_layout(self):
        """Запись v2 (23 слота) переезжает в v3 (21) без сдвига полей.

        Ровно здесь ломается тихо: если переложить по индексам v2, но объявить
        v3, то level окажется на месте realm и вся запись поедет — без ошибки.
        Поэтому проверяем КАЖДОЕ поле, а не только имя.
        """
        db = self.lua.table()
        db["players"] = self.lua.table()
        db["players"]["A-Realm"] = self.lua.table_from([
            "A", "MAGE", "Маг", 30, "Realm", "Элвинн", 1429,
            900, 800, 3, 0.5, 0.25, "unit", "Human", "Alliance",
            "P-1", False, False, False, False, False, "A-Realm", False,
        ])
        db["recSchema"] = 2
        conv, _ = self.migrate(db)
        self.assertEqual(int(conv), 1, "запись v2 не была переложена")
        rec = db["players"]["A-Realm"]
        self.assertEqual(self.get(rec, "name"), "A")
        self.assertEqual(self.get(rec, "class"), "MAGE")
        self.assertEqual(int(self.get(rec, "level")), 30)
        self.assertEqual(self.get(rec, "realm"), "Realm")
        self.assertEqual(self.get(rec, "zone"), "Элвинн")
        self.assertEqual(int(self.get(rec, "zoneId")), 1429)
        self.assertEqual(int(self.get(rec, "lastSeen")), 900)
        self.assertEqual(int(self.get(rec, "firstSeen")), 800)
        self.assertEqual(int(self.get(rec, "count")), 3)
        self.assertAlmostEqual(float(self.get(rec, "x")), 0.5, places=4)
        self.assertAlmostEqual(float(self.get(rec, "y")), 0.25, places=4)
        self.assertEqual(self.get(rec, "source"), "unit")
        self.assertEqual(self.get(rec, "race"), "Human")
        self.assertEqual(self.get(rec, "faction"), "Alliance")
        self.assertEqual(self.get(rec, "guid"), "P-1")
        # выводимые поля исчезли
        self.assertIsNone(self.get(rec, "classLoc"))
        self.assertIsNone(self.get(rec, "key"))
        self.assertIsNone(self.get(rec, "gear"))
        length = int(self.lua.eval("(function(r) return #r end)")(rec))
        self.assertEqual(length, 21, "длина записи не равна SLOTS новой схемы")
        self.assertEqual(int(db["recSchema"]), 3)

    def test_v3_record_without_schema_marker_is_not_reindexed(self):
        """Запись v3 без метки recSchema не должна переезжать по индексам v2.

        Признак старой схемы — 23-й слот, а не только метка: иначе потерянная
        метка разложила бы v3 по чужой раскладке и перепутала поля.
        """
        db = self.lua.table()
        db["players"] = self.lua.table()
        db["players"]["A-Realm"] = self.lua.table_from([
            "A", "MAGE", 30, "Realm", "Элвинн", 1429,
            900, 800, 1, 0.5, 0.5, "unit", "Human", "Alliance",
            "P-1", False, False, False, False, False, False,
        ])
        # recSchema отсутствует — как будто метку потеряли
        self.migrate(db)
        rec = db["players"]["A-Realm"]
        self.assertEqual(int(self.get(rec, "level")), 30, "level уехал на чужой слот")
        self.assertEqual(self.get(rec, "realm"), "Realm")
        self.assertEqual(int(self.get(rec, "zoneId")), 1429)

    def test_short_array_is_padded(self):
        # база, сохранённая версией с меньшим числом слотов
        db = self.lua.table()
        db["players"] = self.lua.table()
        db["players"]["A-Realm"] = self.lua.table_from(["A", "MAGE"])
        self.migrate(db)
        rec = db["players"]["A-Realm"]
        length = int(self.lua.eval("(function(r) return #r end)")(rec))
        self.assertEqual(length, self.slots, "короткая запись не добита до SLOTS")



GETDB_STUBS = r"""
NSP_CONST = NSP_CONST or { RETAIN_DAYS = 7 }
function time() return 1000 end
GetBuildInfo = function() return "1.60.1", "70291", "Nov 13 2026", 16001 end
GetRealmName = function() return "Realm" end
D = function() end
"""


def getdb_source() -> str:
    """GetDB целиком — вместе с блоком миграции записей внутри него."""
    src = (__import__("pathlib").Path(__file__).resolve().parents[1] / "NearbySpy.lua").read_text(encoding="utf-8")
    start = src.index("GetDB = function()")
    end = src.index("-- Keep a bounded sample of Blizzard HC broadcasts", start)
    return src[start:end]


class GetDBOrderTests(unittest.TestCase):
    """Порядок в GetDB: миграция записей обязана идти ДО миграции имён.

    Это не теория: миграция имён читает p.name и p.realm, а после перезапуска
    игры позиционные записи приходят БЕЗ метатаблицы (клиент её не сохраняет).
    Если проход по записям идёт после, p.name = nil у всех, и миграция имён
    выбрасывает всю базу как «unusable record (no name)» — молча, с одним
    счётчиком в debug. Тест подаёт ровно это состояние: позиционные массивы,
    снятый флаг migratedNames.
    """

    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(REC_PRELUDE)
        self.lua.execute(migration_source())
        self.lua.execute(getdb_source())
        self.lua.execute(GETDB_STUBS)

    def test_positional_db_survives_load_with_name_migration(self):
        # база позиционная, метатаблицы нет (как сразу после загрузки SV),
        # флаг миграции имён снят — худший случай
        self.lua.execute("""
        NearbySpy = {
          players = {
            ["Old-Realm"] = {"Old", "MAGE", "Маг", 30, "Realm", "Элвинн", 1429,
                             900, 800, 1, 0.5, 0.5, "unit", "Human", "Alliance",
                             false, false, false, false, false, "Old-Realm", false},
          },
        }
        """)
        db = self.lua.globals()["GetDB"]()
        count = int(self.lua.eval("(function(d) local n=0 for _ in pairs(d.players) do n=n+1 end return n end)")(db))
        self.assertEqual(count, 1, "запись потеряна при загрузке")
        name = self.lua.eval('(function(d) return d.players["Old-Realm"].name end)')(db)
        self.assertEqual(name, "Old", "поле name не читается после GetDB")

    def test_hash_db_still_converted(self):
        self.lua.execute("""
        NearbySpy = {
          players = {
            ["Old-Realm"] = { name = "Old", class = "MAGE", level = 30,
                              realm = "Realm", source = "unit", count = 1,
                              lastSeen = 900, firstSeen = 800 },
          },
        }
        """)
        db = self.lua.globals()["GetDB"]()
        name = self.lua.eval('(function(d) return d.players["Old-Realm"].name end)')(db)
        self.assertEqual(name, "Old")
        schema = int(self.lua.eval("(function(d) return d.recSchema end)")(db))
        self.assertEqual(schema, 3)


if __name__ == "__main__":
    unittest.main(verbosity=2)
