"""Транспорт обмена: аддон-сообщение по префиксу + приём с обоих путей (Lua 5.1).

С 26.11.2026 отправка идёт `C_ChatInfo.SendAddonMessage` (префикс NearbySpy),
потому что замер зондом NSGateProbe показал: этот транспорт НЕ требует
hardware-события, тогда как `SendChatMessage` клиент пускает только с клика по
миру (живой SV: queued=60 при sent=0).

Что держат эти тесты:
  - запись и Q1-запрос уходят ИМЕННО аддон-сообщением (префикс, тип CHANNEL,
    номер канала), а старый `SendChatMessage` не вызывается вовсе;
  - без API аддон-сообщений отправка падает в канал (фолбэк), а не молчит;
  - `db.peerViaAddon = false` принудительно возвращает старый транспорт —
    откат одной настройкой, без переустановки;
  - регистрация префикса вызывает API и пишет результат в SV;
  - слив идёт из C_Timer (без клика) и останавливается, когда очередь пуста;
  - в приёме зарегистрирован CHAT_MSG_ADDON и вызывается ТОТ ЖЕ
    ReceivePeerMessage, что и для канала.
"""

from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

from nsp_helpers import (ADDON_FILE, CONST_PRELUDE, PEER_PRELUDE, PEER_STUBS,
                         peer_module)


SOURCE = ADDON_FILE


def transport_block() -> str:
    """PeerWireSend / PeerRegisterPrefix / PeerStartTimer / PeerWireTimerSend.

    Все четыре объявлены подряд (до замера возврата канала), вырезаем одним
    куском, чтобы они видели друг друга и локалы peer-секции.
    """
    src = SOURCE.read_text(encoding="utf-8")
    start = src.index("function PeerWireSend(db, payload, channel)")
    end = src.index("-- Замер возврата канала", start)
    return src[start:end]


def drain_timer_block() -> str:
    """DrainPeerTimer — слив по таймеру (обходит PEER_GAP старого транспорта)."""
    src = SOURCE.read_text(encoding="utf-8")
    start = src.index("function DrainPeerTimer()")
    end = src.index("-- ── Запрос базы у пиров", start)
    return src[start:end]


STUBS = r"""
TestAddonSent, TestChatSent, TestBlocked, TestTimers = {}, {}, {}, {}
ADDON_API = "ok"          -- ok | missing | throws
DbgErr = function(src, err) TestBlocked[#TestBlocked + 1] = tostring(src) .. ":" .. tostring(err) end
GetBuildInfo = function() return "1.60.1", "70291" end

TestEchoAddon = function(text, sender)
    local fr = TestFrame
    fr.on(fr, "CHAT_MSG_ADDON", "NearbySpy", text, "CHANNEL", sender or "Wolfy Fang")
end

function MakeChatInfo()
    local ci = {
        SendAddonMessage = function(prefix, text, chatType, chan)
            TestAddonSent[#TestAddonSent + 1] = {p = prefix, t = text, c = chatType, ch = chan}
            if ADDON_API == "throws" then error("boom") end
            return true
        end,
        SendChatMessage = function(text, chatType, lang, chan)
            TestChatSent[#TestChatSent + 1] = {t = text, c = chatType, ch = chan}
            return nil
        end,
        RegisterAddonMessagePrefix = function(p) TestRegistered = p; return true end,
        IsAddonMessagePrefixRegistered = function(p) return true end,
    }
    return ci
end
C_ChatInfo = MakeChatInfo()

TestBuild = function()
    TestAddonSent, TestChatSent, TestBlocked, TestTimers = {}, {}, {}, {}
    -- НЕ `(ADDON_API == "missing") and nil or MakeChatInfo()`: в Lua `x and nil or y`
    -- всегда даёт y, поэтому «API нет» никогда бы не воспроизвелось.
    if ADDON_API == "missing" then
        C_ChatInfo = nil
    else
        C_ChatInfo = MakeChatInfo()
    end
end

-- Таймер клиента: сюда складываются запланированные шаги слива.
C_Timer = { After = function(delay, fn) TestTimers[#TestTimers + 1] = {d = delay, f = fn} end }

-- Глобальный SendChatMessage (в клиенте есть и отдельно от C_ChatInfo): на него
-- падает фолбэк PeerWireSend, когда C_ChatInfo отсутствует целиком.
SendChatMessage = function(text, chatType, lang, chan)
    TestChatSent[#TestChatSent + 1] = {t = text, c = chatType, ch = chan}
    return nil
end
"""


def load(lua):
    """peer-секция + транспорт в ОДНОМ чанке: так видны локалы очереди."""
    lua.execute(CONST_PRELUDE + "\n" + PEER_STUBS + "\n" + PEER_PRELUDE + "\n"
                + transport_block() + "\n" + drain_timer_block() + "\n" + STUBS)


class PeerWireSendTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.db = peer_module(self.lua)
        load(self.lua)
        self.g = self.lua.globals()

    def sent_addon(self):
        t = self.g["TestAddonSent"]
        return [dict(t[i]) for i in range(1, len(t) + 1)]

    def sent_chat(self):
        t = self.g["TestChatSent"]
        return [dict(t[i]) for i in range(1, len(t) + 1)]

    def test_packet_goes_as_addon_message(self):
        ok, res, transport = self.g["PeerWireSend"](self.db, "N7;f;r;rec", 7)
        self.assertTrue(ok)
        self.assertEqual("addon", str(transport))
        msgs = self.sent_addon()
        self.assertEqual(1, len(msgs), msgs)
        self.assertEqual("NearbySpy", msgs[0]["p"])
        self.assertEqual("N7;f;r;rec", msgs[0]["t"])
        self.assertEqual("CHANNEL", msgs[0]["c"])
        self.assertEqual(7, msgs[0]["ch"])
        # Старый транспорт при живом API не трогается вовсе.
        self.assertEqual([], self.sent_chat())

    def test_falls_back_to_channel_when_api_missing(self):
        self.lua.execute('ADDON_API = "missing"; TestBuild()')
        ok, res, transport = self.g["PeerWireSend"](self.db, "x", 7)
        self.assertTrue(ok)
        self.assertEqual("channel", str(transport))
        self.assertEqual([], self.sent_addon())
        self.assertEqual(1, len(self.sent_chat()))

    def test_setting_forces_the_old_transport(self):
        # Откат одной настройкой: если новый путь на живом клиенте не пойдёт,
        # достаточно db.peerViaAddon = false, без переустановки аддона.
        self.db["peerViaAddon"] = False
        ok, res, transport = self.g["PeerWireSend"](self.db, "x", 7)
        self.assertEqual("channel", str(transport))
        self.assertEqual([], self.sent_addon())
        self.assertEqual(1, len(self.sent_chat()))

    def test_exception_inside_api_is_reported_not_raised(self):
        self.lua.execute('ADDON_API = "throws"; TestBuild()')
        ok, res, transport = self.g["PeerWireSend"](self.db, "x", 7)
        self.assertFalse(ok)
        self.assertIn("boom", str(res))

    def test_transport_counters_land_in_debug(self):
        self.g["PeerWireSend"](self.db, "x", 7)
        self.g["PeerWireSend"](self.db, "y", 7)
        stats = self.g["TestPeerStats"]
        self.assertEqual(2, stats["viaAddon"])
        self.assertEqual("addon", str(self.db["debug"]["peerTransport"]))


class PeerRegisterPrefixTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.db = peer_module(self.lua)
        load(self.lua)
        self.g = self.lua.globals()

    def test_registers_the_prefix_from_const(self):
        ok = self.g["PeerRegisterPrefix"](self.db)
        self.assertTrue(ok)
        self.assertEqual("NearbySpy", str(self.g["TestRegistered"]))
        self.assertIn("NearbySpy", str(self.db["debug"]["prefix"]))

    def test_missing_api_is_recorded(self):
        self.lua.execute('ADDON_API = "missing"; TestBuild()')
        ok = self.g["PeerRegisterPrefix"](self.db)
        self.assertFalse(ok)
        self.assertIn("api missing", str(self.db["debug"]["prefix"]))


class TimerDrainTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.db = peer_module(self.lua)
        load(self.lua)
        self.g = self.lua.globals()

    def fill(self, n=3):
        for i in range(n):
            self.g["QueuePeerNew"](self.db, self.lua.table_from({
                "key": f"T{i}-TestRealm PvP", "name": f"T {i}",
                "realm": "TestRealm PvP", "class": "MAGE", "level": 60,
                "race": "Human", "faction": "Alliance", "zone": "TestZone",
                "zoneId": 12, "observedAt": 1000000,
            }))

    def run_timers(self, steps=8):
        """Прокрутить таймеры, но ОГРАНИЧЕННО: Step перепланирует сам себя
        (это и есть работа таймера), поэтому без потолка прогон не кончается —
        первый заход так и завис."""
        for _ in range(steps):
            t = self.g["TestTimers"]
            n = len(t)
            if n == 0:
                return
            # ближайший по времени шаг
            idx = min(range(1, n + 1), key=lambda i: t[i]["d"])
            fn = t[idx]["f"]
            # сдвигаем очередь: удаляем выполненный
            rest = [t[i] for i in range(1, n + 1) if i != idx]
            self.lua.execute("TestTimers = {}")
            t = self.g["TestTimers"]
            for k, item in enumerate(rest):
                t[k + 1] = item
            fn()

    def test_timer_starts_and_reschedules(self):
        self.assertTrue(self.g["PeerStartTimer"]())
        self.assertGreater(len(self.g["TestTimers"]), 0, "таймер не запланировал шаг")

    def test_timer_drains_queue_without_any_click(self):
        # Клик не эмулируется вообще: очередь обязана уйти сама.
        self.fill(3)
        self.g["PeerStartTimer"]()
        self.run_timers()
        self.assertGreater(len(self.g["TestAddonSent"]), 0, "таймер не отправил ни одного сообщения")
        self.assertEqual(0, len(self.g["TestPeerQueue"]), "очередь не опустела")

    def test_timer_sends_nothing_when_queue_is_empty(self):
        self.g["PeerStartTimer"]()
        self.run_timers()
        self.assertEqual([], [i for i in range(1, len(self.g["TestAddonSent"]) + 1)])


class ReceivesBothWaysTests(unittest.TestCase):
    """Статические проверки ветки приёма: она живёт в общем OnEvent-обработчике,
    который срезом не поднять (тянет полфайла), поэтому держим маркеры."""

    def setUp(self):
        self.src = SOURCE.read_text(encoding="utf-8")

    def test_addon_event_is_registered(self):
        self.assertIn('RegisterEvent("CHAT_MSG_ADDON")', self.src)

    def test_old_channel_receive_is_kept(self):
        self.assertIn('RegisterEvent("CHAT_MSG_CHANNEL")', self.src)
        self.assertIn("IsPeerChannel(select(9, ...))", self.src)

    def test_addon_branch_calls_the_shared_receiver(self):
        start = self.src.index('if ev == "CHAT_MSG_ADDON" then')
        end = self.src.index('if ev == "CHAT_MSG_CHANNEL"', start)
        branch = self.src[start:end]
        self.assertIn("ReceivePeerMessage(text, sender)", branch)
        # Фильтр по префиксу, а не по имени канала: в CHAT_MSG_ADDON имени
        # канала нет, там тип рассылки.
        self.assertIn("NSP_CONST.PEER_PREFIX", branch)
        self.assertNotIn("IsPeerChannel", branch)

    def test_addon_branch_guards_secret_strings_and_type(self):
        start = self.src.index('if ev == "CHAT_MSG_ADDON" then')
        end = self.src.index('if ev == "CHAT_MSG_CHANNEL"', start)
        branch = self.src[start:end]
        self.assertIn("canaccessvalue", branch)
        self.assertLess(branch.index("canaccessvalue"), branch.index("text == \"\""))


if __name__ == "__main__":
    unittest.main()
