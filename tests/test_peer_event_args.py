"""select() в списке аргументов разворачивается во ВСЕ значения — и это ломало счётчики.

Живой дефект (SV 20.11.2026): `seen = 0` при `valid = 161`. Канал принимал
161 запись, а счётчик «сколько сообщений получено» показывал ноль, то есть
диагностика утверждала «канал мёртв» при живом трафике.

Причина не в пачках, а в вызове обработчика:

    ReceivePeerMessage(select(1, ...), select(2, ...))

`select(1, ...)` в СПИСКЕ АРГУМЕНТОВ возвращает не одно значение, а все
оставшиеся. Значит функция получала пять аргументов вместо двух, и третий
параметр `fromBatch` получал имя языка канала ('Common' / 'Общий') — всегда
truthy. Строка `if not fromBatch then peerStats.seen = peerStats.seen + 1 end`
не выполнялась НИКОГДА для настоящих сообщений канала.

Почему старый тест это не ловил: он вызывал ReceivePeerMessage(msg, sender)
напрямую двумя аргументами, то есть проверял не ту аргументную подпись, с
которой функция вызывается в игре. Поэтому здесь проверяется ИМЕННО путь
через событие, с настоящим vararg-набором.

Что держит файл:
  - вызов из обработчика CHAT_MSG_CHANNEL передаёт РОВНО два аргумента;
  - сообщение канала увеличивает seen на единицу;
  - пачка из трёх записей увеличивает seen на единицу (не на три);
  - второй аргумент события действительно становится отправителем.
"""

from pathlib import Path
import re
import unittest

from lupa.lua51 import LuaRuntime

from nsp_helpers import CONST_PRELUDE, RACE_PRELUDE

ADDON = Path(__file__).resolve().parents[1]
SOURCE = ADDON / "NearbySpy.lua"


def receive_block() -> str:
    src = SOURCE.read_text(encoding="utf-8")
    start = src.index("local function ReceivePeerMessage(")
    end = src.index("local function JoinPeerChannel()")
    return src[start:end] + "\n" + src[src.index("function ReceivePeerGear(fields, sender)"):
                                      src.index("local function JoinPeerChannel()")]


# Аргументы ровно в том порядке, в каком их присылает CHAT_MSG_CHANNEL:
# text, playerName, languageName, channelName, ...
EVENT_ARGS = ("N7;f;0;Wolfrider Alpha;h;30;a;a;1429;-;-;tonugm",
              "Tester", "Common", "nearbyspya")

HARNESS = """
-- Часы харнеса — ПОЗЖЕ метки в пакете: иначе честный приём отвечает
-- Reject("time in future") на PEER_CLOCK_SKEW, и тест «записи не приняты»
-- падал бы не из-за проверяемого кода, а из-за расхождения часов.
time = function() return 1795167302 end
UnitName = function() return 'Me', nil end
function PlayerRealm() return 'CAMWOW EU5 Realm 1 PvE' end
function PeerChannelName() return 'nearbyspya' end
PEER_BATCH_SEP = ','
PEER_TAIL_SEP = '~'
ZONE_NAMES = { [1429] = 'Goldshire Inn' }
function ZoneNameById(id) return ZONE_NAMES[tonumber(id)] end
function PeerCoord(v) return string.format('%.4f', v) end
function ClassLocFromFile() return nil end
PEER_BATCH_MAX, PEER_CLOCK_SKEW = 5, 3600
peerStats = {seen = 0, valid = 0, received = 0, merged = 0, rejected = 0,
             foreign = 0, selfEcho = 0, inStart = 0, inCount = 0, rejectLogged = {}}
function PeerSync() end
local function D() end
function PeerEsc(s, n) return tostring(s) end
DB = {peerEnabled = true, peerAllRealms = true, game = 'forever', players = {}, debug = {}}
function GetDB() return DB end
QueuePeerNew = function() end
function UpsertPlayer(db, data)
  db.players[data.name .. '-' .. data.realm] = { name = data.name }
  return true
end
NSP_INSPECT = nil
"""


class EventArgumentTests(unittest.TestCase):
    """Вызов из обработчика события — с vararg, как в игре."""

    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        # Харнес идёт ПЕРЕД срезом: в Lua 5.1 `local function D()` виден только
        # ниже своего объявления, поэтому обратный порядок дал бы
        # "attempt to call global 'D' (a nil value)" при первом же пакете.
        self.lua.execute(CONST_PRELUDE + "\n" + RACE_PRELUDE + "\n"
                         + HARNESS + "\n" + receive_block() + "\n"
                         # Вызов РОВНО в той форме, что в обработчике события:
                         # select() в списке аргументов, без скобок.
                         """
                         function ViaEvent(...)
                             ReceivePeerMessage(select(1, ...), select(2, ...))
                         end
                         function ViaEventFixed(...)
                             ReceivePeerMessage((select(1, ...)), (select(2, ...)))
                         end
                         TestStats = peerStats
                         TestDB = DB
                         """)
        self.g = self.lua.globals()

    def event_args(self, message, sender="Tester"):
        return (message, sender, "Common", "nearbyspya")

    def test_unparenthesised_select_leaks_extra_arguments(self):
        # Это и был живой баг: третий параметр получал имя языка.
        self.lua.execute("""
            function ArgsProbe(a, b, c) return tostring(c) end
            function ProbeLeak(...) return ArgsProbe(select(1, ...), select(2, ...)) end
            function ProbeFixed(...) return ArgsProbe((select(1, ...)), (select(2, ...))) end
        """)
        leak = self.g["ProbeLeak"](*self.event_args("x"))
        fixed = self.g["ProbeFixed"](*self.event_args("x"))
        self.assertEqual("Common", str(leak), "ловушка не воспроизвелась — тест бесполезен")
        # без скобок третий аргумент = имя языка; со скобками его нет вовсе
        self.assertEqual("nil", str(fixed), "скобки должны оставлять ровно одно значение")

    def test_channel_message_counts_as_seen_with_the_fixed_call(self):
        self.g["ViaEventFixed"](*self.event_args(EVENT_ARGS[0]))
        self.assertEqual(1, self.g["TestStats"]["seen"],
                         "сообщение канала не посчитано в seen")

    def test_channel_message_counts_as_seen_through_the_real_handler_form(self):
        # Без скобок seen остаётся нулём — это регресс-охранник самой ловушки.
        self.g["ViaEvent"](*self.event_args(EVENT_ARGS[0]))
        self.assertEqual(0, self.g["TestStats"]["seen"],
                         "ловушка изменила поведение — перепроверь обработчик")

    def test_batch_counts_as_one_message_not_three(self):
        msg = "N7;f;0;" + ",".join([
            "Wolfrider Alpha;h;30;a;a;1429;-;-;tonugm",
            "Robert Terwilliger;e;33;h;h;1454;-;-;tonugm",
            "Albino Pentti;a;15;g;h;1411;-;-;tonugm",
        ])
        self.g["ViaEventFixed"](*self.event_args(msg))
        self.assertEqual(1, self.g["TestStats"]["seen"], "пачка посчитана как N сообщений")
        self.assertEqual(3, self.g["TestStats"]["valid"], "записи пачки не приняты")

    def test_sender_comes_from_the_second_event_argument(self):
        self.g["ViaEventFixed"](*self.event_args(EVENT_ARGS[0], sender="Real Sender"))
        self.assertEqual("Real Sender", str(self.g["TestStats"]["lastSender"]),
                         "отправитель взят не из второго аргумента события")


class HandlerCallSiteTests(unittest.TestCase):
    """Статическая проверка: в обработчике select() обязан быть в скобках."""

    def test_handler_parenthesises_select(self):
        src = SOURCE.read_text(encoding="utf-8")
        i = src.index('if ev == "CHAT_MSG_CHANNEL" and')
        block = src[i:i + 900]
        body = re.sub(r"--[^\n]*", "", block)
        self.assertIn("ReceivePeerMessage((select(1, ...)), (select(2, ...)))",
                      body,
                      "в обработчике вызов без скобок: select развернётся во все "
                      "значения и fromBatch получит имя языка")
        self.assertNotIn("ReceivePeerMessage(select(1, ...), select(2, ...))",
                         body,
                         "остался вызов без скобок")


if __name__ == "__main__":
    unittest.main()
