"""Воронка /nspy who speed: полосы уровней → классы → расы — Lua 5.1.

Режим введён 09.11.2026 и переработан по уточнению пользователя: срез класса
тоже идёт полосами по 10 уровней (а не сплошным 1-60), и раскрытие идёт сверху
вниз.

Ступени:
  1. полоса уровней шириной 10 от капа вниз: 51-60, 41-50, 31-40, …
  2. полоса упёрлась в серверный лимит 50 строк → она раскрывается по классам,
     и снова полосами по 10 от верха (к-"Воин" 51-60, 41-50 …)
  3. срез класса упёрся в лимит → к нему добавляется раса, тоже полосой по 10
  4. дальше детализации нет — срез принимается как есть

Плюс жёсткий потолок раскрытия (SCAN.SPEED_MAX): без него плотный сервер
развернул бы «поверхностный слой» в большее число запросов, чем полная
перепись (~110).
"""

from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

SOURCE = Path(__file__).resolve().parents[1] / "NearbySpy.lua"


def scan_block() -> str:
    """От LearnedFactions до конца SCAN.SpeedTrim (вся логика воронки)."""
    src = SOURCE.read_text(encoding="utf-8")
    start = src.index("-- LearnedFactions — НАБОР фракций")
    end = src.index("-- ============ scan persistence ============", start)
    return src[start:end]


# все расы сервера (для «фона»: в реальной базе каждая наблюдалась сотни раз)
ALL_RACES = ("Dwarf", "Gnome", "Human", "NightElf", "Scourge", "Troll",
             "Orc", "Tauren", "Skyborne")

PRELUDE = """
RACE_FACTION = {
    Human = "Alliance", Dwarf = "Alliance", NightElf = "Alliance", Gnome = "Alliance",
    Orc = "Horde", Scourge = "Horde", Tauren = "Horde", Troll = "Horde",
}
RACE_BY_LOCALE = {
    ruRU = {
        Human = "Человек", Dwarf = "Дворф", NightElf = "Ночной эльф",
        Gnome = "Гном",
        Orc = "Орк", Scourge = "Нежить", Tauren = "Таурен",
        Troll = "Тролль",
    },
}
LOCALIZED_CLASS_NAMES_MALE = {
    WARRIOR = "Воин", PALADIN = "Паладин", HUNTER = "Охотник",
    ROGUE = "Разбойник", PRIEST = "Жрец", SHAMAN = "Шаман",
    MAGE = "Маг", WARLOCK = "Чернокнижник", DRUID = "Друид",
}
WHO_TOKEN_CLASS = "к-"
WHO_TOKEN_RACE = "р-"
function GetLocale() return "ruRU" end
-- стабим НЕ PlayerFaction: настоящая определена внутри scan_block и перекрыла
-- бы заглушку. Фракция приходит из UnitFactionGroup, как в клиенте.
function UnitFactionGroup(unit) return "Horde" end
LEARN = {
    raceLoc2File = {
        ["Таурен"] = "Tauren", ["Tauren"] = "Tauren",
        ["Нежить"] = "Scourge", ["Орк"] = "Orc", ["Орчиха"] = "Orc",
        ["Тролль"] = "Troll",
        -- Skyborne есть в реальном SV: русское написание лежит в learn, а в
        -- эталонной таблице локали его нет (раса серверная, не классическая)
        ["Небеснорожденный из Высшего ордена"] = "Skyborne",
        ["Небеснорожденная из Высшего ордена"] = "Skyborne",
    },
    raceFactions = { Tauren = {Horde = true}, Scourge = {Horde = true},
                     Orc = {Horde = true}, Troll = {Horde = true},
                     Skyborne = {Alliance = true} },
}
"""


def initial_plan(ml=60, band=None):
    lua = LuaRuntime(unpack_returned_tuples=True)
    chunk = (
        PRELUDE + scan_block()
        + "\nlocal db = {learn = LEARN}\n"
        + "local q = SCAN.Speed(db, %d%s)\n" % (ml, (", %d" % band) if band else "")
        + "local out = {}\n"
        + "for i = 1, #q do local e = q[i]\n"
        + "  out[#out+1] = string.format('%s|%d|%d|%d|%s', tostring(e.base or ''),"
        + " e.lo, e.hi, e.tier, tostring(e.kind)) end\n"
        + "return out\n"
    )
    return [str(x).split("|") for x in lua.execute(chunk).values()]


def expand(tier, lo, hi, base="", left=999):
    lua = LuaRuntime(unpack_returned_tuples=True)
    chunk = (
        PRELUDE + scan_block()
        + "\nlocal db = {learn = LEARN}\n"
        # base содержит двойные кавычки (к-"Охотник") — экранируем для Lua
        + "local q = {tier = %d, lo = %d, hi = %d, base = %s}\n" % (
            tier, lo, hi, ('"' + base.replace('"', '\\"') + '"') if base else "nil")
        + "local s = SCAN.SpeedTrim(SCAN.SpeedExpand(db, q, %d), %d)\n" % (left, left)
        + "if not s then return {} end\n"
        + "local out = {}\n"
        + "for i = 1, #s do local e = s[i]\n"
        + "  out[#out+1] = string.format('%s|%d|%d|%d|%s|%s', tostring(e.base or ''),"
        + " e.lo, e.hi, e.tier, tostring(e.kind), tostring(e.race or '')) end\n"
        + "return out\n"
    )
    return [str(x).split("|") for x in lua.execute(chunk).values()]


class SpeedInitialPlanTest(unittest.TestCase):
    def test_only_level_bands_first(self):
        """Стартовый план — только полосы уровней: классы добавляются по факту."""
        rows = initial_plan()
        kinds = {r[4] for r in rows}
        self.assertEqual(kinds, {"level"}, "в старте лишние срезы: %s" % kinds)
        tiers = {r[3] for r in rows}
        self.assertEqual(tiers, {"1"}, "старт должен быть одной ступенью")

    def test_bands_go_down_from_cap_by_ten(self):
        """Сверху вниз по 10: 51-60, 41-50, … — так просил пользователь."""
        rows = initial_plan()
        got = [(int(r[1]), int(r[2])) for r in rows]
        self.assertEqual(got, [(51, 60), (41, 50), (31, 40), (21, 30), (11, 20), (1, 10)])

    def test_bands_cover_cap_without_gaps_or_overlap(self):
        rows = initial_plan()
        pairs = [(int(r[1]), int(r[2])) for r in rows]
        for lo, hi in pairs[:-1]:
            self.assertEqual(hi - lo + 1, 10, "полоса не по 10: %s" % ((lo, hi),))
        for a, b in zip(pairs, pairs[1:]):
            self.assertEqual(b[1] + 1, a[0], "разрыв или перекрытие: %s и %s" % (a, b))
        self.assertEqual(pairs[-1][0], 1, "нижняя граница не 1")
        self.assertEqual(pairs[0][1], 60, "верхняя граница не кап")

    def test_custom_cap_and_band(self):
        rows = initial_plan(ml=45, band=10)
        got = [(int(r[1]), int(r[2])) for r in rows]
        self.assertEqual(got, [(36, 45), (26, 35), (16, 25), (6, 15), (1, 5)])

    def test_plan_is_deterministic(self):
        self.assertEqual(initial_plan(), initial_plan())


class SpeedFunnelTest(unittest.TestCase):
    def test_tier1_expands_to_classes_same_band(self):
        """Полоса упёрлась в лимит → классы, и полоса та же (не 1-60!)."""
        rows = expand(tier=1, lo=51, hi=60)
        self.assertEqual(len(rows), 9, "ожидалось 9 классов: %s" % rows)
        for r in rows:
            self.assertEqual((int(r[1]), int(r[2])), (51, 60),
                             "класс должен сохранить полосу родителя: %s" % r)
            self.assertEqual(r[3], "2", "класс — ступень 2")
        bases = [r[0] for r in rows]
        self.assertIn('к-"Охотник"', bases)
        self.assertEqual(bases, sorted(bases), "порядок классов не фиксирован")

    def test_tier2_expands_to_races_same_band(self):
        """Срез класса упёрся в лимит → расы того же класса и той же полосы."""
        rows = expand(tier=2, lo=41, hi=50, base='к-"Охотник"')
        self.assertTrue(rows, "раскрытие по расам пустое")
        for r in rows:
            self.assertEqual(r[0], 'к-"Охотник"', "потерян класс-родитель: %s" % r)
            self.assertEqual((int(r[1]), int(r[2])), (41, 50), "полоса не сохранена")
            self.assertEqual(r[3], "3", "раса — ступень 3")
            self.assertTrue(r[5], "не задана раса: %s" % r)

    def test_race_expansion_filtered_by_faction_and_locale(self):
        rows = expand(tier=2, lo=41, hi=50, base='к-"Охотник"')
        races = {r[5] for r in rows}
        self.assertEqual(races, {"Нежить", "Орк", "Таурен", "Тролль"},
                         "расы не отфильтрованы: %s" % races)
        self.assertNotIn("Tauren", races, "латинский дубль")
        self.assertNotIn("Орчиха", races, "женская форма")
        self.assertNotIn("Человек", races, "раса чужой фракции")

    def test_tier3_does_not_expand(self):
        """Предел детализации: дальше дробить нечем."""
        self.assertEqual(expand(tier=3, lo=41, hi=50, base='к-"Охотник"'), [])

    def test_budget_caps_expansion(self):
        """Потолок бюджета: раскрытие урезается, а не игнорируется."""
        rows = expand(tier=1, lo=1, hi=10, left=4)
        self.assertEqual(len(rows), 4, "бюджет не применён: %s" % rows)
        rows = expand(tier=1, lo=1, hi=10, left=0)
        self.assertEqual(rows, [], "при нулевом бюджете раскрытия быть не должно")


class ClassRaceCombosTest(unittest.TestCase):
    """Раса для класса берётся из РЕАЛЬНО наблюдаемых комбинаций.

    Замечание пользователя 09.11.2026: «друид не у всех рас есть». Комбинации
    на этом сервере не классические — у Дворфа шаман и паладин, у Нежити
    паладин, у Skyborne друид, — поэтому статическая таблица «класс × раса»
    была бы неверной в обе стороны. Данные берутся из db.players.
    """

    # реальные пары с сервера (195.2.80.15, 09.11.2026)
    REAL_PAIRS = [
        ("DRUID", "NightElf"), ("DRUID", "Skyborne"), ("DRUID", "Tauren"),
        ("HUNTER", "Dwarf"), ("HUNTER", "Human"), ("HUNTER", "NightElf"),
        ("HUNTER", "Orc"), ("HUNTER", "Skyborne"), ("HUNTER", "Tauren"), ("HUNTER", "Troll"),
        ("MAGE", "Gnome"), ("MAGE", "Human"), ("MAGE", "Orc"), ("MAGE", "Scourge"),
        ("MAGE", "Skyborne"), ("MAGE", "Troll"),
        ("PALADIN", "Dwarf"), ("PALADIN", "Human"), ("PALADIN", "Scourge"),
        ("PRIEST", "Dwarf"), ("PRIEST", "Gnome"), ("PRIEST", "Human"),
        ("PRIEST", "NightElf"), ("PRIEST", "Scourge"), ("PRIEST", "Troll"),
        ("ROGUE", "Dwarf"), ("ROGUE", "Gnome"), ("ROGUE", "Human"), ("ROGUE", "NightElf"),
        ("ROGUE", "Orc"), ("ROGUE", "Scourge"), ("ROGUE", "Skyborne"), ("ROGUE", "Troll"),
        ("SHAMAN", "Dwarf"), ("SHAMAN", "Orc"), ("SHAMAN", "Tauren"), ("SHAMAN", "Troll"),
        ("WARLOCK", "Gnome"), ("WARLOCK", "Human"), ("WARLOCK", "Orc"),
        ("WARLOCK", "Scourge"), ("WARLOCK", "Troll"),
        ("WARRIOR", "Dwarf"), ("WARRIOR", "Gnome"), ("WARRIOR", "Human"),
        ("WARRIOR", "NightElf"), ("WARRIOR", "Orc"), ("WARRIOR", "Scourge"),
        ("WARRIOR", "Skyborne"), ("WARRIOR", "Tauren"), ("WARRIOR", "Troll"),
    ]

    def races_for(self, cls, pairs=None, repeat=40):
        """Срезы рас для класса; repeat — сколько раз кладём пару (порог 30)."""
        pairs = self.REAL_PAIRS if pairs is None else pairs
        rows = "\n".join('{class="%s", race="%s"},' % (c, r)
                         for c, r in pairs for _ in range(repeat))
        lua = LuaRuntime(unpack_returned_tuples=True)
        chunk = (
            PRELUDE + scan_block()
            + "\nlocal db = {learn = LEARN, players = { %s }}\n" % rows
            + "local q = {base = 'к-x', cls = '" + cls + "', lo = 51, hi = 60, tier = 2}\n"
            + "local s = SCAN.SpeedRaces(db, q)\n"
            + "local out = {}\n"
            + "for i = 1, #s do out[#out+1] = tostring(s[i].race) end\n"
            + "return out\n"
        )
        return {str(x) for x in lua.execute(chunk).values()}

    def test_druid_only_for_races_that_have_it(self):
        """Друид у Орды — только Таурен: у Нежити/Орка/Тролля его нет."""
        self.assertEqual(self.races_for("DRUID"), {"Таурен"},
                         "друид генерирует запросы по расам без друида")

    def test_custom_combo_paladin_undead(self):
        """Нежить-паладин — комбинация этого сервера; фильтр её обязан видеть."""
        self.assertEqual(self.races_for("PALADIN"), {"Нежить"})

    def test_shaman_skips_alliance_races(self):
        """Дворф-шаман существует, но он альянсовый — в срез Орды не идёт."""
        self.assertEqual(self.races_for("SHAMAN"), {"Орк", "Таурен", "Тролль"})

    def test_common_class_keeps_all_faction_races(self):
        self.assertEqual(self.races_for("WARRIOR"), {"Нежить", "Орк", "Таурен", "Тролль"})

    def test_unseen_combo_falls_back_to_all_races(self):
        """Пока комбинации не наблюдались — не сужаем (иначе потеряем расу)."""
        got = self.races_for("DRUID", pairs=[("HUNTER", "Orc")])
        self.assertEqual(got, {"Нежить", "Орк", "Таурен", "Тролль"},
                         "без данных фильтр не должен срезать расы: %s" % got)

    def test_rare_race_is_not_filtered_out(self):
        """Мало наблюдений по расе → пару не исключаем (защита от замкнутого круга).

        Пара «друид × тролль» не встречалась, но если троллей видели всего
        пару раз, судить нельзя: не спросили → не увидели → не спросим.
        """
        pairs = [("DRUID", "Tauren")] * 1 + [("HUNTER", "Troll")] * 1
        rows = "\n".join('{class="%s", race="%s"},' % (c, r)
                         for c, r in pairs for _ in range(1))
        lua = LuaRuntime(unpack_returned_tuples=True)
        chunk = (
            PRELUDE + scan_block()
            + "\nlocal db = {learn = LEARN, players = { %s }}\n" % rows
            + "local q = {base = 'к-x', cls = 'DRUID', lo = 51, hi = 60, tier = 2}\n"
            + "local s = SCAN.SpeedRaces(db, q)\n"
            + "local out = {}\n"
            + "for i = 1, #s do out[#out+1] = tostring(s[i].race) end\n"
            + "return out\n"
        )
        got = {str(x) for x in lua.execute(chunk).values()}
        self.assertIn("Тролль", got,
                      "редкая раса отброшена фильтром (замкнутый круг): %s" % got)

    def test_priest_races_both_factions(self):
        """Жрец: Орда — Нежить и Тролль; Альянс — четыре расы.

        Проверка по запросу пользователя 09.11.2026. Жрецов-орков и
        жрецов-тауренов на сервере нет, поэтому в ордынском срезе их быть не
        должно; у альянса жрец есть у всех четырёх рас.
        """
        pairs = [("PRIEST", "Dwarf"), ("PRIEST", "Gnome"), ("PRIEST", "Human"),
                 ("PRIEST", "NightElf"), ("PRIEST", "Scourge"), ("PRIEST", "Troll")]
        # Фон: каждая раса наблюдалась и другими классами (как в реальной базе).
        # Без фона защита от замкнутого круга (порог SCAN.RACE_MIN_OBS) не даёт
        # фильтру сузить список — и это правильно, но тест проверяет не её.
        back = [("WARRIOR", r) for r in ALL_RACES]
        rows = "\n".join('{class="%s", race="%s"},' % (c, r)
                         for c, r in pairs + back for _ in range(120))

        def races(faction):
            lua = LuaRuntime(unpack_returned_tuples=True)
            chunk = (
                PRELUDE + scan_block()
                + '\nfunction UnitFactionGroup() return "' + faction + '" end\n'
                + "local db = {learn = LEARN, players = { %s }}\n" % rows
                + "local q = {base='к-x', cls='PRIEST', lo=51, hi=60, tier=2}\n"
                + "local s = SCAN.SpeedRaces(db, q)\n"
                + "local out = {}\n"
                + "for i = 1, #s do out[#out+1] = tostring(s[i].race) end\n"
                + "return out\n"
            )
            return {str(x) for x in lua.execute(chunk).values()}

        self.assertEqual(races("Horde"), {"Нежить", "Тролль"},
                         "у жреца Орды лишние или недостающие расы")
        self.assertEqual(races("Alliance"), {"Гном", "Дворф", "Ночной эльф", "Человек"},
                         "у жреца Альянса не все расы")

    def test_druid_includes_custom_race(self):
        """Друид Альянса: Ночной эльф И Skyborne (раса сервера, не из классики)."""
        pairs = [("DRUID", "NightElf"), ("DRUID", "Skyborne"), ("DRUID", "Tauren")]
        back = [("WARRIOR", r) for r in ALL_RACES]
        rows = "\n".join('{class="%s", race="%s"},' % (c, r)
                         for c, r in pairs + back for _ in range(120))
        lua = LuaRuntime(unpack_returned_tuples=True)
        chunk = (
            PRELUDE + scan_block()
            + '\nfunction UnitFactionGroup() return "Alliance" end\n'
            + "local db = {learn = LEARN, players = { %s }}\n" % rows
            + "local q = {base='к-x', cls='DRUID', lo=51, hi=60, tier=2}\n"
            + "local s = SCAN.SpeedRaces(db, q)\n"
            + "local out = {}\n"
            + "for i = 1, #s do out[#out+1] = tostring(s[i].race) end\n"
            + "return out\n"
        )
        got = {str(x) for x in lua.execute(chunk).values()}
        self.assertEqual(got, {"Ночной эльф", "Небеснорожденный из Высшего ордена"},
                         "кастомная раса потеряна в срезе друида: %s" % got)

    def test_queue_keeps_class_key(self):
        """Файловый ключ класса должен переживать /reload: по нему ищем расы."""
        lua = LuaRuntime(unpack_returned_tuples=True)
        src = SOURCE.read_text(encoding="utf-8")
        i = src.index("local function CompactQueue(queue)")
        j = src.index("\nend\n", i) + len("\nend\n")
        chunk = (
            src[i:j]
            + "\nlocal q = {{lo=51, hi=60, base='к-Друид', tier=2, kind='class', cls='DRUID'}}\n"
            + "local c = CompactQueue(q)\n"
            + "return { tostring(c[1].cls) }\n"
        )
        got = [str(x) for x in lua.execute(chunk).values()]
        self.assertEqual(got, ["DRUID"], "cls теряется: %s" % got)


class SpeedPersistenceTest(unittest.TestCase):
    def test_queue_keeps_tier_and_kind(self):
        """tier/kind должны переживать /reload, иначе воронка ломается."""
        lua = LuaRuntime(unpack_returned_tuples=True)
        src = SOURCE.read_text(encoding="utf-8")
        i = src.index("local function CompactQueue(queue)")
        j = src.index("\nend\n", i) + len("\nend\n")
        body = src[i:j]
        chunk = (
            body
            + "\nlocal q = {{lo=51, hi=60, tier=1, kind='level'},\n"
            + "            {lo=41, hi=50, base='к-Воин', tier=2, kind='class'}}\n"
            + "local c = CompactQueue(q)\n"
            + "return { tostring(c[1].tier) .. '/' .. tostring(c[1].kind),\n"
            + "         tostring(c[2].tier) .. '/' .. tostring(c[2].kind) }\n"
        )
        got = [str(x) for x in lua.execute(chunk).values()]
        self.assertEqual(got, ["1/level", "2/class"],
                         "tier/kind теряются при сохранении очереди: %s" % got)


class LevelFirstRaceSplitTest(unittest.TestCase):
    """Расовое дробление в level-first плане (/nspy who, режим по умолчанию).

    Дефект 20.11.2026: переполненный срез «класс × уровень» дробился по ВСЕМ
    расам фракции, а не по тем, что реально бывают у класса — в очередь попадали
    пары вида «Друид × Орк», которых на сервере нет. Плюс при делении среза по
    уровням терялся файл-ключ класса (`cls`), поэтому фильтровать было нечем.
    SCAN.RaceNames — общий список рас для обеих воронок.
    """

    BACK = [("WARRIOR", r) for r in ALL_RACES]

    def names(self, cls_lua):
        rows = "\n".join('{class="%s", race="%s"},' % (c, r)
                         for c, r in ClassRaceCombosTest.REAL_PAIRS + self.BACK
                         for _ in range(120))
        lua = LuaRuntime(unpack_returned_tuples=True)
        chunk = (
            PRELUDE + scan_block()
            + "\nlocal db = {learn = LEARN, players = { %s }}\n" % rows
            + "local out = {}\n"
            + "for _, n in ipairs(SCAN.RaceNames(db, %s)) do out[#out+1] = n end\n" % cls_lua
            + "return out\n"
        )
        return {str(x) for x in lua.execute(chunk).values()}

    def test_known_class_skips_impossible_pairs(self):
        """Друид Орды: только Таурен — Орк/Нежить/Тролль отсечены."""
        got = self.names("'DRUID'")
        self.assertEqual(got, {"Таурен"},
                         "level-first спрашивает расы, у которых друида нет: %s" % got)

    def test_nil_class_keeps_old_behaviour(self):
        """План из старого SV без cls: не сужаем, берём все расы фракции."""
        got = self.names("nil")
        self.assertEqual(got, {"Нежить", "Орк", "Таурен", "Тролль"},
                         "без класса список рас сломан: %s" % got)

    def test_level_split_carries_the_class(self):
        """Деление среза по уровням обязано переносить cls в оба дочерних среза."""
        src = SOURCE.read_text(encoding="utf-8")
        i = src.index("local mid = math.floor((q.lo + q.hi) / 2)")
        j = src.index("whoScan.splits = (whoScan.splits or 0) + 1", i)
        block = src[i:j]
        self.assertEqual(block.count("cls = q.cls"), 2,
                         "дочерние срезы теряют класс:\n%s" % block)

    def test_class_split_carries_the_class(self):
        """Классовые срезы из широкого ответа тоже обязаны нести cls."""
        src = SOURCE.read_text(encoding="utf-8")
        i = src.index("elseif not (q.base and q.base:find(WHO_TOKEN_CLASS, 1, true)) then")
        j = src.index("whoScan.splits = (whoScan.splits or 0) + 1", i)
        block = src[i:j]
        self.assertIn("cls = cls", block,
                      "классовый срез без файл-ключа класса:\n%s" % block)

    def test_race_split_filters_by_class(self):
        """Расовый срез level-first берёт список из SCAN.RaceNames, а не из RaceFilterNames."""
        src = SOURCE.read_text(encoding="utf-8")
        i = src.index("elseif not q.race and q.base then")
        j = src.index("whoScan.raceSplits = (whoScan.raceSplits or 0) + 1", i)
        block = src[i:j]
        self.assertIn("SCAN.RaceNames(db, q.cls)", block,
                      "расовый срез не фильтруется по классу:\n%s" % block)
        self.assertNotIn("RaceFilterNames", block,
                         "расовый срез снова берёт все расы фракции:\n%s" % block)


if __name__ == "__main__":
    unittest.main(verbosity=2)
