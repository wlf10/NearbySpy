"""Команда запроса базы: разбор аргументов и наличие в диспетчере (Lua 5.1).

Живой случай 26.11.2026: владелец ввёл `/nspy ask 60` и не получил ничего.
Причина — ветки для «ask» в диспетчере не было вовсе: ввод уходил в `else` и
молча открывал окно помощи. Рабочее имя было `peer ask`, и в справке аддона
команды не было ни под каким именем.

Тест закрывает обе половины: разбор аргументов (NspParseAsk) и то, что
диспетчер действительно ловит обе формы.
"""

from pathlib import Path
import re
import unittest

from lupa.lua51 import LuaRuntime

ADDON = Path(__file__).resolve().parents[1]
SOURCE = ADDON / "NearbySpy.lua"


def parse_block() -> str:
    src = SOURCE.read_text(encoding="utf-8")
    start = src.index("function NspParseAsk(rest)")
    return src[start:src.index("\nend", start) + 4]


def dispatcher_source() -> str:
    src = SOURCE.read_text(encoding="utf-8")
    start = src.index('SlashCmdList["NEARBYSPY"] = function(msg)')
    return src[start:src.index("\n-- ============ chat as a name source", start)]


class ParseAskTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(parse_block())
        self.parse = self.lua.globals()["NspParseAsk"]

    def parse_all(self, rest):
        return tuple(self.parse(rest))

    def test_bare_window(self):
        """`/nspy ask 60` — всем, за 60 минут."""
        self.assertEqual((None, "60", None), self.parse_all("60"))

    def test_no_arguments(self):
        """`/nspy ask` — окно по умолчанию."""
        self.assertEqual((None, None, None), self.parse_all(None))
        self.assertEqual((None, None, None), self.parse_all(""))
        self.assertEqual((None, None, None), self.parse_all("   "))

    def test_name_only(self):
        self.assertEqual(("wolff", None, None), self.parse_all("wolff"))

    def test_name_and_window(self):
        self.assertEqual(("wolff", "180", None), self.parse_all("wolff 180"))

    def test_two_word_name_and_window(self):
        """Имена в канале двусловные: цифры отделяем только от хвоста."""
        self.assertEqual(("wolf fang", "240", None), self.parse_all("wolf fang 240"))

    def test_extra_spaces_are_collapsed(self):
        """Копипаст из чата тащит двойные пробелы."""
        self.assertEqual(("wolf fang", None, None), self.parse_all("  wolf   fang  "))

    def test_modes(self):
        self.assertEqual((None, None, "status"), self.parse_all("status"))
        self.assertEqual((None, None, "list"), self.parse_all("list"))

    def test_name_that_looks_like_a_mode_is_still_a_name(self):
        """Игрок с ником «Status» не должен получить счётчики вместо запроса."""
        self.assertEqual(("status x", None, None), self.parse_all("status x"))

    def test_junk_is_tolerated(self):
        self.assertEqual((None, None, None), self.parse_all(42))


class DispatcherWiringTests(unittest.TestCase):
    def setUp(self):
        self.src = dispatcher_source()

    def test_both_forms_reach_the_ask_branch(self):
        """Ветка обязана ловить и `ask`, и `peer ask`."""
        # Условие разбито на две строки, поэтому собираем его до `then`.
        lines = self.src.splitlines()
        starts = [i for i, l in enumerate(lines) if "elseif" in l and "peer ask" in l]
        self.assertEqual(1, len(starts), "ветка ask не найдена или их несколько: %s" % starts)
        i = starts[0]
        cond = lines[i]
        while not cond.rstrip().endswith("then"):
            i += 1
            cond += " " + lines[i]
        line = cond
        self.assertIn('msg == "ask"', line, "нет короткой формы: %s" % line.strip())
        self.assertIn('msg:match("^ask%s")', line, "нет разбора аргументов: %s" % line.strip())
        self.assertIn('msg == "peer ask"', line, "потеряна форма peer ask")

    def test_arguments_are_read_from_either_form(self):
        line = [l for l in self.src.splitlines()
                if "local rest = msg:match" in l and "ask" in l]
        self.assertEqual(1, len(line), "разбор аргументов не найден")
        self.assertIn('"^peer ask%s+(.+)$"', line[0])
        self.assertIn('"^ask%s+(.+)$"', line[0], "короткая форма не отдаёт аргументы")

    def test_help_lists_the_command(self):
        """Команда, которой нет в справке, для игрока не существует."""
        src = SOURCE.read_text(encoding="utf-8")
        block = src[src.index("local HELP_COMMANDS = {"):]
        block = block[:block.index("\n}")]
        self.assertIn('"/nspy ask"', block, "команды ask нет в списке справки")

    def test_every_help_command_has_a_description_in_every_locale(self):
        src = SOURCE.read_text(encoding="utf-8")
        cmds = src[src.index("local HELP_COMMANDS = {"):]
        cmds = cmds[:cmds.index("\n}")]
        n_cmds = len(re.findall(r'"/nspy[^"]*"', cmds))
        texts = src[src.index("local HELP_TEXT = {"):]
        texts = texts[:texts.index("\n}")]
        for line in texts.strip().splitlines():
            if "{" not in line or "}" not in line:
                continue   # строка-открывашка `local HELP_TEXT = {`
            name = line.split("=")[0].strip()
            body = line[line.index("{") + 1:line.rindex("}")]
            n_desc = len(re.findall(r'"(?:[^"\\]|\\.)*"', body))
            with self.subTest(locale=name):
                self.assertEqual(n_cmds, n_desc,
                                 "%s: команд %d, описаний %d" % (name, n_cmds, n_desc))


if __name__ == "__main__":
    unittest.main()
