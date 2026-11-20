"""Порядок гейта секретных строк: canaccessvalue ДО первой строковой операции.

Живой дефект (errLast в SV 20.11.2026):

    chat   ...: attempt to compare local 'speaker' (a secret string value,
               while execution tainted by 'NearbySpy')
    sysmsg ...: attempt to compare local 'msg'   (исправлено 16.11.2026)

Клиент Forever (Midnight-стиль) может отдать значение СЕКРЕТНОЙ строкой: на ней
бросает любая строковая операция — `== ""`, `:find`, `#`, конкатенация. `type()`
секретную строку пропускает, поэтому «сначала type, потом сравнение» НЕ спасает:
сравнение всё равно выполняется. Гейт `canaccessvalue` обязан стоять первым.

Почему проверка статическая, а не через исполнение: в ванильном Lua 5.1 строки
не имеют собственных метаметодов (метатаблица строк одна на всех, `__eq` для
строк не вызывается), поэтому «строку, которая бросает на операции» в харнессе
не сымитировать — любой поддельный объект отсекается проверкой `type(speaker)
~= "string"`. Значит проверяем ПОРЯДОК в исходнике: это единственное, что можно
проверить достоверно, и именно порядок был дефектом.

Что держит файл:
  - в обработчике чата гейт идёт раньше `speaker == ""` и раньше type();
  - в ZoneNameById гейт идёт раньше `info.name ~= ""`;
  - в LogSysMsg и CheckWhoThrottle гейт идёт раньше `msg == ""` и `msg:find`;
  - errLast показывает ВОЗРАСТ ошибки, иначе починенный баг читается как живой.
"""

from pathlib import Path
import re
import unittest

from lupa.lua51 import LuaRuntime

from nsp_helpers import CONST_PRELUDE

ADDON = Path(__file__).resolve().parents[1]
SOURCE = ADDON / "NearbySpy.lua"


def source() -> str:
    return SOURCE.read_text(encoding="utf-8")


def strip_comments(text: str) -> str:
    """Убрать комментарии: в них ЦИТИРУЕТСЯ код (`msg == ""`), и поиск по
    сырому тексту находил комментарий вместо строки кода — тест падал на
    собственном якоре, а не на дефекте.
    """
    text = re.sub(r"--\[\[.*?\]\]", "", text, flags=re.S)
    return re.sub(r"--[^\n]*", "", text)


def function_body(src: str, header: str) -> str:
    """Тело функции от заголовка до закрывающей `end\nend` или следующей функции.

    Режем по маркеру следующего определения, а не по балансу скобок: у этих
    функций внутри есть `pcall(... function() ... end)`, и счётчик скобок
    промахнулся бы.
    """
    start = src.index(header)
    tail = src[start:]
    m = re.search(r"\nend\n", tail)
    body = tail[:m.end()] if m else tail[:4000]
    return strip_comments(body)


class SecretGateOrderTests(unittest.TestCase):
    def setUp(self):
        self.src = source()

    def assertGateBefore(self, body: str, needles, label: str):
        if isinstance(needles, str):
            needles = (needles,)
        gate = body.find("canaccessvalue")
        self.assertNotEqual(-1, gate, "%s: гейта canaccessvalue нет вообще" % label)
        positions = [(body.find(n), n) for n in needles if body.find(n) != -1]
        self.assertTrue(positions, "%s: не нашёл ни одного из %r" % (label, needles))
        pos, needle = min(positions)
        self.assertLess(gate, pos,
                        "%s: гейт секретной строки стоит ПОСЛЕ %r — на секретной "
                        "строке это бросит (порядок и был дефектом)" % (label, needle))

    def test_chat_speaker_gate_precedes_the_emptiness_check(self):
        # именно это бросало: speaker == "" до гейта
        start = self.src.index("local speaker = select(2, ...)")
        body = strip_comments(self.src[start:start + 900])
        self.assertGateBefore(body, '== ""', "обработчик чата")

    def test_chat_speaker_gate_precedes_type_check(self):
        # type() секретную строку пропускает — гейт должен быть ДО него,
        # иначе сравнение всё равно выполнится
        start = self.src.index("local speaker = select(2, ...)")
        body = strip_comments(self.src[start:start + 900])
        gate = body.find("canaccessvalue")
        ty = body.find('type(speaker)')
        self.assertLess(gate, ty, "обработчик чата: гейт должен идти до type()")

    def test_zone_name_gate_precedes_the_emptiness_check(self):
        body = function_body(self.src, "function ZoneNameById(")
        self.assertGateBefore(body, ('== ""', '~= ""'), "ZoneNameById")

    def test_system_message_gate_precedes_string_ops(self):
        for header, label in (("local function LogSysMsg(", "LogSysMsg"),
                              ("local function CheckWhoThrottle(", "CheckWhoThrottle")):
            body = function_body(self.src, header)
            self.assertGateBefore(body, ('== ""', ":find"), label)

    def test_peer_receive_gates_before_any_string_op(self):
        body = function_body(self.src, "local function ReceivePeerMessage(")
        gate = body.find("canaccessvalue")
        # первая строковая операция над текстом сообщения — проверка длины
        length = body.find("#message")
        self.assertLess(gate, length,
                        "приём peer: гейт должен идти до #message")


class StaleErrorVisibilityTests(unittest.TestCase):
    """errLast переживает логаут — без возраста он врёт о своей актуальности."""

    def setUp(self):
        self.src = source()

    def test_error_report_shows_the_age(self):
        start = self.src.index('P(("error[%s] x%d')
        block = self.src[max(0, start - 900):start + 260]
        self.assertIn("errAt", block,
                      "вывод ошибок не читает errAt — возраст не показывается")
        self.assertIn("TimeAgo", block,
                      "вывод ошибок не форматирует возраст")

    def test_time_ago_is_declared_before_it_is_used(self):
        # Lua 5.1: local, объявленный ниже места вызова, в вызове — nil-глобал
        decl = self.src.index("local function TimeAgo(")
        use = self.src.index('TimeAgo(tonumber(at))')
        self.assertLess(decl, use, "TimeAgo используется выше своего объявления")


if __name__ == "__main__":
    unittest.main()
