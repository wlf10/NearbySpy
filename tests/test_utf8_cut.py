#!/usr/bin/env python3
"""Обрезка строк для диагностики не должна рвать UTF-8 символ пополам.

Живой SavedVariables 25.11.2026 содержал 6 некорректных UTF-8
последовательностей: `string.sub` считает БАЙТЫ, поэтому кириллица резалась
пополам и в файл попадал байт-огрызок (0xD1 без пары). Файл перестаёт быть
валидным UTF-8: Python-парсер выгрузки читает с errors="replace" и терпит,
а Go на сайте подставил бы U+FFFD — то есть испортил бы текст молча.

NspCut режет по байтам, но отступает от незавершённой последовательности.
Тест гоняет настоящую функцию из NearbySpy.lua в реальном Lua 5.1 и проверяет
ВСЕ длины префиксов: результат обязан быть валидным UTF-8 при любом лимите.

Run: python tests/test_utf8_cut.py
"""
from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

SOURCE = Path(__file__).resolve().parents[1] / "NearbySpy.lua"


def cut_block() -> str:
    src = SOURCE.read_text(encoding="utf-8")
    start = src.index("function NspCut(s, n)")
    end = src.index("-- Untrusted chat text", start)
    return "function NspCut(s, n)" + src[start + len("function NspCut(s, n)"):end]


def is_valid_utf8(raw: bytes) -> bool:
    try:
        raw.decode("utf-8")
        return True
    except UnicodeDecodeError:
        return False


class NspCutTest(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(cut_block())
        self.cut = self.lua.globals()["NspCut"]

    def cut_text(self, text: str, n: int) -> str:
        """NspCut в Lua, результат как Python-строка (bytes -> utf-8)."""
        res = self.cut(text, n)
        return str(res)

    def test_ascii_is_cut_exactly(self):
        self.assertEqual("abcd", self.cut_text("abcdef", 4))

    def test_short_string_is_untouched(self):
        self.assertEqual("Привет", self.cut_text("Привет", 100))
        self.assertEqual("Привет", self.cut_text("Привет", 12))

    def test_cyrillic_never_splits_a_letter(self):
        """«Привет» при лимите 3 байта: «П» (2 байта), а не «П» + половина «р»."""
        self.assertEqual("П", self.cut_text("Привет", 3))
        self.assertEqual("Пр", self.cut_text("Привет", 4))
        # 5 байт = D0 9F D1 80 D0: последняя «и» начата и не завершена
        self.assertEqual("Пр", self.cut_text("Привет", 5))
        self.assertEqual("При", self.cut_text("Привет", 6))

    def test_cjk_three_byte_characters(self):
        self.assertEqual("日", self.cut_text("日本語", 4))
        self.assertEqual("日本", self.cut_text("日本語", 7))

    def test_four_byte_character_is_dropped_whole(self):
        # 😀 = f0 9f 98 80; лимит 2 байта не даёт ни одного целого символа
        self.assertEqual("", self.cut_text("😀abc", 2))
        self.assertEqual("😀", self.cut_text("😀abc", 4))

    def test_every_prefix_of_a_mixed_string_is_valid_utf8(self):
        """Главное утверждение: при ЛЮБОМ лимите результат — целый UTF-8."""
        sample = "Туралион Драконоборец, Оргриммар — 日本 😀 ok"
        raw_len = len(sample.encode("utf-8"))
        for n in range(1, raw_len):
            res = self.cut_text(sample, n)
            self.assertTrue(is_valid_utf8(res.encode("utf-8")),
                            f"лимит {n} байт дал битый UTF-8: {res.encode('utf-8')!r}")

    def test_result_never_longer_than_limit(self):
        sample = "Туралион Драконоборец"
        for n in range(1, 40):
            res = self.cut_text(sample, n)
            self.assertLessEqual(len(res.encode("utf-8")), n)

    def test_bad_arguments_are_returned_as_is(self):
        self.assertIsNone(self.cut(None, 10))
        self.assertEqual(42, int(self.cut(42, 10)))
        self.assertEqual("Привет", self.cut_text("Привет", 0))


class PeerEscStillEscapes(unittest.TestCase):
    """PeerEsc после перехода на NspCut обязан сохранить свою работу."""

    def setUp(self):
        src = SOURCE.read_text(encoding="utf-8")
        start = src.index("function PeerEsc(s, maxLen)")
        end = src.index("local function PeerField(s, maxLen)", start)
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(cut_block())
        self.lua.execute("canaccessvalue = nil\n" + src[start:end])
        self.esc = self.lua.globals()["PeerEsc"]

    def test_pipe_and_control_chars_are_replaced(self):
        self.assertEqual("a?b", str(self.esc("a|b", 60)))
        self.assertEqual("a?b", str(self.esc("a\nb", 60)))

    def test_long_name_is_cut_with_ellipsis_and_stays_valid(self):
        name = "Туралион Драконоборец из Оргриммара"
        res = str(self.esc(name, 20))
        self.assertTrue(res.endswith("..."))
        self.assertTrue(is_valid_utf8(res.encode("utf-8")), res.encode("utf-8"))
        self.assertLessEqual(len(res.encode("utf-8")), 23)

    def test_non_string_is_stringified(self):
        self.assertEqual("42", str(self.esc(42, 60)))


if __name__ == "__main__":
    unittest.main(verbosity=2)
