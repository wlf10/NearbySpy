"""Статус-строка внизу окна: подписи читаются человеком (Lua 5.1, real код).

Было:  "+ СБОР АКТИВЕН ; Кто кормит: unit 1798, guild 0, chat 358, who 12179"

Три проблемы, и все видны только в живом окне:
  - "Кто кормит" — калька с "who feeds", по-русски так не говорят;
  - КАПС в строке статуса кричит;
  - названия источников (unit/who/chat/guild) — технические ключи из SV.

Что держит файл:
  - UI_LIVE и SRC_LINE не в капсе и не калька (проверяется по ruRU);
  - названия источников берутся из локалей, а не из ключей SV;
  - неизвестный источник печатается сырым ключом, а не исчезает;
  - нулевой источник не засоряет строку, а пустой набор даёт понятный текст.
"""

from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

from nsp_helpers import CONST_PRELUDE

ADDON = Path(__file__).resolve().parents[1]
SOURCE = ADDON / "NearbySpy.lua"
LOCALE = ADDON / "NearbySpy_Locale.lua"


def sources_block() -> str:
    src = SOURCE.read_text(encoding="utf-8")
    start = src.index("local function TacticalSources()")
    end = src.index("\nend\n", start) + len("\nend\n")
    return src[start:end]


def locale_table() -> str:
    """Таблица NSP_LOCALE целиком (все шесть языков)."""
    src = LOCALE.read_text(encoding="utf-8")
    start = src.index("NSP_LOCALE = {")
    end = src.index("\n}\n", start) + 3
    return src[start:end]


class SourceLineTests(unittest.TestCase):
    def lua_for(self, locale_code):
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute(
            CONST_PRELUDE + "\n" + locale_table() + "\n"
            "LOCALE = NSP_LOCALE\n"
            "CURRENT = '%s'\n" % locale_code
            + "function L(key)\n"
            "  local t = LOCALE[CURRENT] or LOCALE.enUS\n"
            "  return t[key] or LOCALE.enUS[key] or key\n"
            "end\n"
            "SRC = {}\n"
            "function GetDB() return { debug = { src = SRC } } end\n"
            + sources_block() + "\n"
            "TestSources = TacticalSources\n"
        )
        return lua

    def line(self, locale_code, counts):
        lua = self.lua_for(locale_code)
        src = lua.globals()["SRC"]
        for k, v in counts.items():
            src[k] = v
        return str(lua.globals()["TestSources"]())

    # --- собственно жалоба владельца --------------------------------------

    def test_no_shouting_caps_in_the_status_line(self):
        # Проверяем именно КРИК (вся строка заглавными). Только языки с
        # регистром: в китайском и корейском `.upper()` не меняет строку, и
        # сравнение ложно срабатывало бы на любом тексте. Регистр первой буквы
        # не проверяем — фраза стоит после "+" как продолжение строки статуса,
        # а в немецком существительные пишутся с большой.
        for code in ("enUS", "ruRU", "deDE", "frFR"):
            lua = self.lua_for(code)
            live = str(lua.globals()["LOCALE"][code]["UI_LIVE"])
            self.assertNotEqual(live, live.upper(),
                                "%s: UI_LIVE целиком в капсе (%r)" % (code, live))

    def test_russian_line_reads_naturally(self):
        line = self.line("ruRU", {"unit": 1798, "chat": 358, "who": 12179, "peer": 1436})
        self.assertNotIn("Кто кормит", line, "калька с 'who feeds' вернулась")
        self.assertIn("источники", line.lower())
        self.assertIn("увидено 1798", line)
        self.assertIn("/who 12179", line)
        self.assertIn("чат 358", line)
        self.assertIn("обмен 1436", line)

    # --- названия источников ---------------------------------------------

    def test_source_names_are_localized_not_raw_keys(self):
        line = self.line("ruRU", {"who": 5})
        self.assertIn("/who 5", line)          # /who одинаков во всех языках
        line_en = self.line("enUS", {"chat": 7})
        self.assertIn("chat 7", line_en)

    def test_unknown_source_is_printed_raw(self):
        # новый источник не должен молча исчезать из строки статуса
        line = self.line("ruRU", {"who": 1, "loot": 3})
        self.assertIn("loot 3", line)

    def test_zero_sources_are_skipped(self):
        line = self.line("ruRU", {"unit": 0, "guild": 0, "chat": 4})
        self.assertNotIn("гильдия 0", line)
        self.assertNotIn("увидено 0", line)
        self.assertIn("чат 4", line)

    def test_empty_sources_give_a_readable_text(self):
        line = self.line("ruRU", {})
        self.assertIn("пока ничего", line)
        self.assertNotIn(": ;", line)


if __name__ == "__main__":
    unittest.main()
