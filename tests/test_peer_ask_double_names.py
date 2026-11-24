"""Двойные имена Camelot в адресном запросе (Lua 5.1, настоящий код).

Замер по живому SavedVariables (24.11.2026, 240 отправителей в канале):
  - ВСЕ имена двусловные и приходят через ОДИН пробел — «Youtchi Zerling»,
    «Minifrege Nitales», «Grishnákh Soulrend» (есть не-ASCII: á в имени);
  - ни одного дефиса, ни одной цифры, ни одного двойного пробела в именах;
  - в базе ключ склеен так же, но перед миром стоит дефис:
    «Uncc Benn-CAMWOW EU5 Realm 1 PvE».

Отсюда требования к адресату:
  - «имя фамилия» из канала/`list` обязано совпасть с UnitName()+фамилия;
  - дефисная форма («Wolff-Magy», внутренний формат клиента) — тоже совпасть;
  - лишний пробел из копипаста не должен мешать;
  - а ГОЛОЕ имя при наличии фамилии совпадать НЕ должно: иначе запрос «Wolff»
    получил бы ответ и от «Wolff», и от «Wolff Magy», и адресность потеряла бы
    смысл ровно там, ради чего делалась.
"""

from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

from nsp_helpers import peer_module


SOURCE = Path(__file__).resolve().parents[1] / "NearbySpy.lua"


class DoubleNameTests(unittest.TestCase):
    def build(self, me, surname=None):
        lua = LuaRuntime(unpack_returned_tuples=True)
        peer_module(lua)
        g = lua.globals()
        # UnitName в клиенте отдаёт ДВА значения: имя и фамилию
        if surname:
            lua.execute(f"UnitName = function() return '{me}', '{surname}' end")
        else:
            lua.execute(f"UnitName = function() return '{me}', nil end")
        return g

    def is_me(self, g, name):
        return bool(g["PeerIsMe"](name))

    # --- двойное имя ---------------------------------------------------
    def test_full_double_name_matches(self):
        g = self.build("Wolff", "Magy")
        self.assertTrue(self.is_me(g, "Wolff Magy"))

    def test_double_name_is_case_insensitive(self):
        g = self.build("Wolff", "Magy")
        self.assertTrue(self.is_me(g, "wolff magy"))

    def test_double_name_with_hyphen_matches(self):
        # внутри клиента двойное имя хранится через дефис — игрок может набрать так
        g = self.build("Wolff", "Magy")
        self.assertTrue(self.is_me(g, "Wolff-Magy"))

    def test_extra_spaces_do_not_break_the_match(self):
        # копипаст из чата тащит двойной пробел
        g = self.build("Wolff", "Magy")
        self.assertTrue(self.is_me(g, "Wolff  Magy"))
        self.assertTrue(self.is_me(g, "  Wolff Magy  "))

    def test_bare_first_name_does_not_match_a_double_name(self):
        # Иначе «спросить одного» отвечали бы двое — см. докстринг модуля.
        g = self.build("Wolff", "Magy")
        self.assertFalse(self.is_me(g, "Wolff"))

    def test_bare_surname_does_not_match(self):
        g = self.build("Wolff", "Magy")
        self.assertFalse(self.is_me(g, "Magy"))

    def test_another_double_name_does_not_match(self):
        g = self.build("Wolff", "Magy")
        self.assertFalse(self.is_me(g, "Minifrege Nitales"))
        self.assertFalse(self.is_me(g, "Wolff Nightclaw"))

    # --- реальные образцы из живого SV --------------------------------
    def test_live_name_with_accent_matches_itself(self):
        # «Grishnákh Soulrend» из живого SV: á — два байта UTF-8, регистр
        # средствами Lua не меняется, но обе стороны сравниваются байт в байт
        g = self.build("Grishnákh", "Soulrend")
        self.assertTrue(self.is_me(g, "Grishnákh Soulrend"))

    def test_live_name_with_accent_is_not_confused_with_ascii_spelling(self):
        g = self.build("Grishnákh", "Soulrend")
        self.assertFalse(self.is_me(g, "Grishnakh Soulrend"))

    # --- однословный персонаж ------------------------------------------
    def test_single_word_character_matches_bare_name(self):
        g = self.build("Wolff")
        self.assertTrue(self.is_me(g, "Wolff"))
        self.assertFalse(self.is_me(g, "Wolff Magy"))

    def test_single_word_character_matches_name_with_realm(self):
        g = self.build("Wolff")
        self.assertTrue(self.is_me(g, "Wolff-TestRealm PvP"))

    # --- отправка и приём целиком --------------------------------------
    def test_double_name_survives_the_round_trip_through_the_packet(self):
        """Имя едет в пакете как есть и узнаётся на другой стороне."""
        lua_send = LuaRuntime(unpack_returned_tuples=True)
        db = peer_module(lua_send)
        gs = lua_send.globals()
        lua_send.execute("UnitName = function() return 'Sender', 'Hero' end")
        ok, payload = gs["PeerAskSend"](db, 60, "Wolff Magy")
        self.assertTrue(ok, payload)
        payload = str(payload)
        # имя не развалилось на два поля: разделитель — ';', а не пробел
        self.assertEqual(4, len(payload.split(";")), payload)
        self.assertEqual("Wolff Magy", payload.split(";")[3])

        lua_recv = LuaRuntime(unpack_returned_tuples=True)
        db2 = peer_module(lua_recv)
        gr = lua_recv.globals()
        lua_recv.execute("UnitName = function() return 'Wolff', 'Magy' end")
        gr["ReceivePeerAsk"](
            lua_recv.eval(
                "(function(s) local t = {} for p in (s .. ';'):gmatch('(.-);') do t[#t+1] = p end return t end)"
            )(payload),
            "Sender")
        self.assertIsNotNone(gr["TestPeerStats"]["askPending"])
        self.assertEqual(0, gr["TestPeerStats"]["askNotMe"] or 0)


if __name__ == "__main__":
    unittest.main()
