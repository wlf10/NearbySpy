"""Фильтр имён рас по алфавиту локали клиента — Lua 5.1.

Регрессия с живой игры 09.11.2026: в /nspy who попадали запросы вида
р-«Tauren» на русском клиенте. Источник — db.learn.raceLoc2File, таблица
накопительная: она собиралась и русским, и английским клиентом, поэтому рядом
с «Таурен» лежит «Tauren». Сервер на русском клиенте понимает только
локализованное имя, английское даёт пустой ответ — половина расовых запросов
(в плотных срезах весь tier) уходила впустую и жгла троттлинг /who.

Проверяется на реальном составе db.learn из SV от 09.11.2026.
"""

from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

SOURCE = Path(__file__).resolve().parents[1] / "NearbySpy.lua"


def locale_block() -> str:
    """Фрагмент от LearnedFactions до конца RaceFilterNames.

    Начинаем с LearnedFactions, а не с NameFitsLocale: набор фракций расы —
    часть той же логики (кросс-фракционные кастомные расы), и тест должен
    исполнять реальный код, а не заглушку.
    """
    src = SOURCE.read_text(encoding="utf-8")
    start = src.index("-- LearnedFactions — НАБОР фракций")
    end = src.index("-- Full layered zone scan", start)
    return src[start:end]


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
    enUS = {
        Human = "Human", Dwarf = "Dwarf", NightElf = "Night Elf",
        Gnome = "Gnome",
        Orc = "Orc", Scourge = "Undead", Tauren = "Tauren",
        Troll = "Troll",
    },
}
CURRENT_LOCALE = "ruRU"
function GetLocale() return CURRENT_LOCALE end
function PlayerFaction() return "Horde" end
"""

# Реальный состав db.learn.raceLoc2File из SV (09.11.2026): русские и
# английские ключи вперемешку, плюс кастомная раса сервера в двух написаниях.
LEARN_REAL = """
LEARN = { raceLoc2File = {
    ["Человек"] = "Human", ["Human"] = "Human",
    ["Нежить"] = "Scourge",
    ["Дворф"] = "Dwarf", ["Dwarf"] = "Dwarf",
    ["Orc"] = "Orc",
    ["Орчиха"] = "Orc",
    ["High Order Skyborne"] = "Skyborne",
    ["Небеснорожденная из Высшего ордена"] = "Skyborne",
    ["Гном"] = "Gnome", ["Gnome"] = "Gnome",
    ["Тролль"] = "Troll", ["Troll"] = "Troll",
    ["Орк"] = "Orc",
    ["Гномка"] = "Gnome",
    ["Таурен"] = "Tauren", ["Tauren"] = "Tauren",
    ["Ночной эльф"] = "NightElf", ["Night Elf"] = "NightElf",
    ["Дворфийка"] = "Dwarf",
    ["Небеснорожденный из Высшего ордена"] = "Skyborne",
    ["Ночная эльфийка"] = "NightElf",
},
-- раса → фракция из того же SV: Skyborne — раса АЛЬЯНСА, и в очередь Horde
-- попадать не должна (/who видит только свою фракцию, запрос по чужой расе
-- всегда возвращает пустой список)
raceFaction = {
    NightElf = "Alliance", Scourge = "Horde", Orc = "Horde",
    Skyborne = "Alliance", Dwarf = "Alliance", Tauren = "Horde",
    Human = "Alliance", Troll = "Horde", Gnome = "Alliance",
} }
"""


class RaceLocaleTest(unittest.TestCase):
    def run_block(self, learn_lua: str = "", locale: str = "ruRU"):
        lua = LuaRuntime(unpack_returned_tuples=True)
        chunk = (
            PRELUDE
            + learn_lua
            + locale_block()
            + "\nreturn {names=RaceFilterNames, fits=NameFitsLocale}\n"
        )
        mod = lua.execute('CURRENT_LOCALE = "%s"\n' % locale + chunk)
        return lua, mod

    def test_name_fits_locale_ru(self):
        """Кириллица проходит, латиница нет — на русском клиенте."""
        lua, mod = self.run_block(LEARN_REAL)
        fits = mod["fits"]
        self.assertTrue(fits("Таурен", "ruRU"))
        self.assertTrue(fits("Небеснорожденная из Высшего ордена", "ruRU"))
        self.assertFalse(fits("Tauren", "ruRU"))
        self.assertFalse(fits("High Order Skyborne", "ruRU"))
        self.assertFalse(fits("", "ruRU"))
        self.assertFalse(fits(None, "ruRU"))

    def test_name_fits_locale_en(self):
        """Обратный случай: на английском клиенте кириллица не пройдёт."""
        lua, mod = self.run_block(LEARN_REAL)
        fits = mod["fits"]
        self.assertTrue(fits("Tauren", "enUS"))
        self.assertTrue(fits("Night Elf", "enUS"))
        self.assertFalse(fits("Таурен", "enUS"))
        # неизвестная локаль — не судим, пропускаем всё
        self.assertTrue(fits("Таурен", "ptBR"))
        self.assertTrue(fits("Tauren", "ptBR"))

    def test_ru_locale_excludes_english_names(self):
        """Главное: на русском клиенте в очередь скана не попадает латиница.

        Живой дефект: р-«Tauren» и р-«Human» тратили запрос и получали пустой
        ответ, потому что сервер ждёт локализованное имя.
        """
        lua = LuaRuntime(unpack_returned_tuples=True)
        chunk = (
            PRELUDE + LEARN_REAL + locale_block()
            + "\nlocal db = {learn = LEARN}\n"
            + "local out = {}\n"
            + "for name in pairs(RaceFilterNames(db, 'Horde')) do out[#out+1] = name end\n"
            + "return out\n"
        )
        got = {str(x) for x in lua.execute(chunk).values()}
        latin = {n for n in got if all(ord(c) < 128 for c in n)}
        self.assertEqual(
            latin, set(),
            "в очередь попали английские имена рас: %s" % sorted(latin))
        # русские написания Horde-рас на месте
        self.assertIn("Таурен", got)
        self.assertIn("Нежить", got)
        self.assertIn("Орк", got)
        # альянсовые расы отсечены фильтром фракции (Skyborne — раса альянса)
        self.assertNotIn("Человек", got)
        self.assertNotIn("Гном", got)
        self.assertNotIn("High Order Skyborne", got)

    def test_alliance_side(self):
        """Для альянса — свои расы, тоже только локализованные."""
        lua = LuaRuntime(unpack_returned_tuples=True)
        chunk = (
            PRELUDE + LEARN_REAL + locale_block()
            + "\nlocal db = {learn = LEARN}\n"
            + "local out = {}\n"
            + "for name in pairs(RaceFilterNames(db, 'Alliance')) do out[#out+1] = name end\n"
            + "return out\n"
        )
        got = {str(x) for x in lua.execute(chunk).values()}
        self.assertIn("Человек", got)
        self.assertIn("Ночной эльф", got)
        self.assertIn("Небеснорожденный из Высшего ордена", got)
        self.assertNotIn("Таурен", got)
        latin = {n for n in got if all(ord(c) < 128 for c in n)}
        self.assertEqual(latin, set(), "английские имена: %s" % sorted(latin))

    def test_without_learn_table(self):
        """Без db.learn работает эталонная таблица локали — и тоже без латиницы."""
        lua = LuaRuntime(unpack_returned_tuples=True)
        chunk = (
            PRELUDE + locale_block()
            + "\nlocal out = {}\n"
            + "for name in pairs(RaceFilterNames({}, 'Horde')) do out[#out+1] = name end\n"
            + "return out\n"
        )
        got = {str(x) for x in lua.execute(chunk).values()}
        self.assertEqual(got, {"Орк", "Нежить", "Таурен", "Тролль"})


class RaceDedupTest(unittest.TestCase):
    """Никаких дублей и женских форм в расовых запросах.

    Живые данные 09.11.2026 (SV, сохранённая очередь скана): на один уровень
    36 у Охотника уходило пять запросов вместо трёх —
        race="Orc" + race="Орк", race="Tauren" + race="Таурен", race="Тролль".
    Duplicates came from db.learn, where UnitRace had written the FEMALE race
    name next to the male one ("Орчиха", "Гномка", "Дворфийка"), and from the
    other client locale ("Orc", "Tauren").
    """

    def names(self, faction="Horde", learn_lua=LEARN_REAL, extra_db=""):
        lua = LuaRuntime(unpack_returned_tuples=True)
        chunk = (
            PRELUDE + learn_lua + locale_block()
            + "\nlocal db = " + (extra_db or "{learn = LEARN}") + "\n"
            + "local out = {}\n"
            + "for name in pairs(RaceFilterNames(db, '" + faction + "')) do out[#out+1] = name end\n"
            + "table.sort(out)\nreturn out\n"
        )
        return [str(x) for x in lua.execute(chunk).values()]

    def test_female_race_names_never_reach_the_queue(self):
        """«Орчиха»/«Гномка»/«Дворфийка» — не расы: это женская форма.

        UnitRace отдаёт название расы с учётом пола юнита, и learn записывал
        женские формы наравне с мужскими. /who на них не отвечает.
        """
        got = self.names("Horde")
        for bad in ("Орчиха", "Гномка", "Дворфийка", "Ночная эльфийка"):
            self.assertNotIn(bad, got, "женская форма расы попала в очередь: %s" % bad)

    def test_no_duplicate_requests_for_one_race(self):
        """Один запрос на расу. Horde: 4 стандартных, кастомных нет.

        Skyborne — альянсовая раса, в очередь Horde попадать не должна: /who
        видит только фракцию своего персонажа, запрос по чужой расе всегда пуст.
        """
        got = self.names("Horde")
        self.assertEqual(got, ["Нежить", "Орк", "Таурен", "Тролль"],
                         "состав очереди Horde: %s" % got)

    def test_custom_race_single_form_for_alliance(self):
        """Альянс: 4 стандартных + кастомная раса ровно одной формой."""
        got = self.names("Alliance")
        self.assertEqual(len(got), 5, "неверное число запросов: %s" % got)
        for ru in ("Человек", "Дворф", "Ночной эльф", "Гном"):
            self.assertIn(ru, got)
        for en in ("Human", "Dwarf", "Night Elf", "Gnome"):
            self.assertNotIn(en, got, "латинский дубль: %s" % en)
        # кастомная раса — одна форма, не обе сразу
        sky = [n for n in got if "ебеснорожден" in n]
        self.assertEqual(len(sky), 1, "форм кастомной расы: %s" % sky)
        self.assertIn("Небеснорожденный", sky[0], "выбрана женская форма: %s" % sky)
        self.assertNotIn("Таурен", got, "раса чужой фракции в очереди альянса")

    def test_who_canonical_name_wins(self):
        """Написание из ответа /who перебивает и эталон, и learn.

        Канон для кастомной расы иначе не узнать: в learn лежат обе формы
        («Небеснорожденный» и «Небеснорожденная»), а сервер понимает только ту,
        которую сам вернул в raceStr.
        """
        got = self.names(
            "Alliance",
            extra_db="""{learn = {raceLoc2File = LEARN.raceLoc2File,
                          raceFaction = LEARN.raceFaction,
                          whoName = {Skyborne = "Небеснорожденный из Высшего ордена"}}}""")
        self.assertIn(
            "Небеснорожденный из Высшего ордена", got,
            "канон из /who должен попасть в очередь: %s" % got)
        # альянс: 4 стандартных + кастомная одной формой = 5
        self.assertEqual(len(got), 5, "дубли остались: %s" % got)


class CrossFactionRaceTest(unittest.TestCase):
    """Кастомная раса бывает у обеих фракций — Skyborne есть и у Орды.

    Живой факт (09.11.2026): в базе сайта Skyborne/Alliance 698 и
    Skyborne/Horde 1, то есть раса не одноместная. learn хранил ОДНУ фракцию
    на расу, поэтому скан Орды вообще не спрашивал р-"Небеснорожденный" —
    терялось покрытие целой расы. Обратная сторона: в ответе /who фракция
    выводилась из расы, и ордынский Skyborne записывался как альянсовый.
    """

    LEARN_BOTH = """
LEARN = {
    raceLoc2File = {
        ["Небеснорожденный из Высшего ордена"] = "Skyborne",
        ["Небеснорожденная из Высшего ордена"] = "Skyborne",
        ["Таурен"] = "Tauren", ["Tauren"] = "Tauren",
        ["Человек"] = "Human", ["Human"] = "Human",
    },
    raceFactions = {
        Skyborne = {Alliance = true, Horde = true},
        Tauren = {Horde = true},
        Human = {Alliance = true},
    },
    -- УСТАРЕВШАЯ мапа из старого SavedVariables: Skyborne запомнился как
    -- альянсовый по первому наблюдению. Именно так выглядит реальный SV на
    -- момент обновления аддона, и именно из-за неё Орда теряла целую расу.
    raceFaction = { Skyborne = "Alliance", Tauren = "Horde", Human = "Alliance" },
}
"""

    LEARN_ONE = """
LEARN = {
    raceLoc2File = { ["Небеснорожденный из Высшего ордена"] = "Skyborne" },
    raceFactions = { Skyborne = {Alliance = true} },
}
"""

    def names(self, faction, learn_lua):
        lua = LuaRuntime(unpack_returned_tuples=True)
        chunk = (
            PRELUDE + learn_lua + locale_block()
            + "\nlocal db = {learn = LEARN}\n"
            + "local out = {}\n"
            + "for name in pairs(RaceFilterNames(db, '" + faction + "')) do out[#out+1] = name end\n"
            + "table.sort(out)\nreturn out\n"
        )
        return [str(x) for x in lua.execute(chunk).values()]

    def test_cross_faction_race_is_scanned_by_both(self):
        """Skyborne есть у Орды → скан Орды обязан его спросить."""
        horde = self.names("Horde", self.LEARN_BOTH)
        alliance = self.names("Alliance", self.LEARN_BOTH)
        self.assertTrue(any("ебеснорожден" in n for n in horde),
                        "сканируя Орду, Skyborne не спрашиваем: %s" % horde)
        self.assertTrue(any("ебеснорожден" in n for n in alliance),
                        "сканируя Альянс, Skyborne не спрашиваем: %s" % alliance)
        self.assertIn("Таурен", horde)
        self.assertNotIn("Человек", horde)
        self.assertIn("Человек", alliance)
        self.assertNotIn("Таурен", alliance)

    def test_single_faction_race_stays_limited(self):
        """Раса, наблюдённая только у Альянса, в скан Орды не попадает."""
        horde = self.names("Horde", self.LEARN_ONE)
        self.assertFalse(any("ебеснорожден" in n for n in horde),
                         "альянсовая раса попала в скан Орды: %s" % horde)
        alliance = self.names("Alliance", self.LEARN_ONE)
        self.assertTrue(any("ебеснорожден" in n for n in alliance))

    def test_old_single_faction_map_still_works(self):
        """Старый SavedVariables с raceFaction читается как набор из одного."""
        legacy = """
LEARN = {
    raceLoc2File = { ["Небеснорожденный из Высшего ордена"] = "Skyborne" },
    raceFaction = { Skyborne = "Alliance" },
}
"""
        horde = self.names("Horde", legacy)
        self.assertFalse(any("ебеснорожден" in n for n in horde),
                         "старая одиночная мапа должна ограничивать: %s" % horde)
        alliance = self.names("Alliance", legacy)
        self.assertTrue(any("ебеснорожден" in n for n in alliance))

    def test_learn_records_set_of_factions(self):
        """LearnRace копит НАБОР: вторая фракция не затирает первую."""
        lua = LuaRuntime(unpack_returned_tuples=True)
        chunk = (
            PRELUDE + locale_block()
            + "\nlocal db = {}\n"
            + "LearnRace(db, 'Небеснорожденный', 'Skyborne', 'Alliance')\n"
            + "LearnRace(db, 'Небеснорожденный', 'Skyborne', 'Horde')\n"
            + "local set = db.learn.raceFactions['Skyborne']\n"
            + "return { a = tostring(set['Alliance']), h = tostring(set['Horde']),\n"
            + "         legacy = tostring(db.learn.raceFaction['Skyborne']) }\n"
        )
        r = lua.execute(chunk)
        self.assertEqual(str(r["a"]), "true", "Альянс потерян")
        self.assertEqual(str(r["h"]), "true", "Орда потеряна")
        self.assertIn(str(r["legacy"]), ("nil", "None"),
                      "у кросс-фракционной расы не должно быть одной фракции")


if __name__ == "__main__":
    unittest.main(verbosity=2)
