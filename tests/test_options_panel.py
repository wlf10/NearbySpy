"""Вкладка NearbySpy в меню модификаций клиента (Lua 5.1, настоящий код).

Зачем: у всех аддонов настройки живут в Settings → AddOns. Свой фрейм с
галочками у NearbySpy был, но в меню клиента его не было — игрок искал
настройки там, где они у остальных.

Порядок ветвей взят из ЖИВОГО клиента (ForeverDungeonJournal/Systems/
OptionsPanel.lua): сначала современная Settings-API, при её отсутствии — старая
InterfaceOptions. Оба API в этом клиенте есть, но проверять надо ОБА пути и
третий — «нет ни одного», иначе на другом билде настройки молча исчезнут.

Что держит этот файл:
  - с современной API регистрируется категория через
    Settings.RegisterCanvasLayoutCategory + RegisterAddOnCategory, у категории
    есть ID (по нему Settings.OpenToCategory находит вкладку);
  - со старой — InterfaceOptions_AddCategory, и у панели заполнено `name`
    (старая API берёт заголовок только оттуда, иначе вкладка безымянная);
  - без обеих API регистрация честно возвращает false, а команда открывает
    собственное окно аддона (молчаливое «ничего не произошло» запрещено);
  - у панели СВОИ имена дропдаунов: два фрейма с одинаковым именем в WoW —
    ошибка «duplicate name», и панель не построится, если окно уже открывали;
  - панель строится из того же списка строк, что и окно аддона, поэтому набор
    опций в двух местах не может разойтись;
  - переключение языка переписывает подписи в обоих местах.
"""

from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

SOURCE = Path(__file__).resolve().parents[1] / "NearbySpy.lua"

# Срез: общий список строк + раскладка + окно + панель. Виджеты и клиентские
# API — заглушки, логика регистрации и раскладки — настоящая.
PRELUDE = r"""
opt, optRows, optWin = {}, {}, nil
CHECK_ROWS, SELECT_ROWS = {}, {}
NAMES = {}          -- имена созданных фреймов: проверка на дубли
PANEL = { size = nil, scripts = {} }
CREATED = {}
TEXT = {}

function L(k) return "L:" .. k end
function P() end
function DbgErr() end
function GetDB() return DB end
DB = { peerEnabled = false, peerAllRealms = true, minimapHide = false }
hub = { Refresh = function() end }
function JoinPeerChannel() end
function LeaveChannelByName() end
function PeerChannelName() return "nearbyspy" end
function TacticalUpdate() end
function BuildMinimapButton() end
function MinimapButton_Update() end
function SolidUnderlay() end
function StackWindow() end
function NspKeyboardPropagate() end
function BuildSettingsWindowStub() end
function ShowSettingsWindow() SHOW_WINDOW = (SHOW_WINDOW or 0) + 1 end
local function LangEntries() return { { value = "AUTO", text = "Auto" } } end
local function TzEntries() return { { value = "AUTO", text = "Auto" } } end
function OptTextHeight() return 14 end

local function W()
    local w = {}
    w.SetText = function(self, t) self.text = t end
    w.SetPoint = function() end
    w.SetSize = function(self, a, b) self.size = { a, b } end
    w.SetWidth = function() end
    w.SetHeight = function() end
    w.SetJustifyH = function() end
    w.SetScript = function(self, ev, fn) self.scripts = self.scripts or {}; self.scripts[ev] = fn end
    w.Show = function(self) self.shown = true end
    w.Hide = function(self) self.shown = false end
    w.IsShown = function() return false end
    w.CreateTexture = function() return W() end
    w.SetChecked = function(self, v) self.checked = v and true or false end
    w.GetChecked = function(self) return self.checked end
    return w
end
function CreateFrame(kind, name, parent, template)
    if name then
        if NAMES[name] then error("duplicate frame name: " .. tostring(name), 0) end
        NAMES[name] = true
    end
    local w = W()
    w.__kind, w.__name, w.__template = kind, name, template
    w.TitleText, w.Bg, w.CloseButton = W(), W(), W()
    w.StartMoving, w.StopMovingOrSizing = function() end, function() end
    w.SetFrameStrata, w.SetMovable, w.EnableMouse = function() end, function() end, function() end
    w.RegisterForDrag, w.EnableKeyboard = function() end, function() end
    CREATED[#CREATED + 1] = w
    return w
end
function NewText(parent, size, r, g, b)
    local w = W()
    TEXT[#TEXT + 1] = w
    return w
end
function OptCheck(parent, x, y, labelKey, descKey, getter, setter)
    local cb, label, desc = W(), W(), W()
    label.text, desc.text = L(labelKey), L(descKey)
    cb:SetChecked(getter())
    cb.__setter = setter
    CHECK_ROWS[#CHECK_ROWS + 1] = { key = labelKey, y = y, parent = parent }
    return cb, label, desc
end
function OptSelect(parent, y, name, labelKey, descKey, width, entriesFn, getCur, onPick)
    if name then
        if NAMES[name] then error("duplicate frame name: " .. tostring(name), 0) end
        NAMES[name] = true
    end
    local label, desc = W(), W()
    label.text, desc.text = L(labelKey), L(descKey)
    SELECT_ROWS[#SELECT_ROWS + 1] = { key = labelKey, y = y, parent = parent, dd = name }
    return { label = label, desc = desc, Refresh = function() end }
end
"""


class OptionsPanelTests(unittest.TestCase):
    def build(self, modern=True, old=True):
        lua = LuaRuntime(unpack_returned_tuples=True)
        g = lua.globals()
        self.lua = lua
        # клиентские API: подставляем ДО выполнения среза
        if modern:
            lua.execute("""
Settings = {}
Settings.REGISTERED = {}
Settings.OPENED = {}
Settings.NEXT_ID = 0
function Settings.RegisterCanvasLayoutCategory(panel, title)
    -- В живом клиенте категория отдаёт СВОЙ идентификатор через GetID(), и
    -- именно его принимает Settings.OpenToCategory (так делает TalkingHeadRu).
    Settings.NEXT_ID = Settings.NEXT_ID + 1
    local cat = { panel = panel, title = title, nid = Settings.NEXT_ID }
    function cat.GetID(self) return self.nid end
    Settings.REGISTERED[#Settings.REGISTERED + 1] = cat
    return cat
end
function Settings.RegisterAddOnCategory(cat)
    cat.registered = true
    Settings.ADDON_CAT = cat
end
function Settings.OpenToCategory(id) Settings.OPENED[#Settings.OPENED + 1] = id end
""")
        if old:
            lua.execute("""
InterfaceOptions_AddCategory = function(panel) OLD_ADDED = panel end
InterfaceOptionsFrame_OpenToCategory = function(panel)
    OLD_OPENED = (OLD_OPENED or 0) + 1
end
""")
        src = SOURCE.read_text(encoding="utf-8")
        start = src.index("function NspSetRows()")
        end = src.index("function MinimapButton_Update()", start)
        lua.execute(PRELUDE + "\n" + src[start:end]
                    + "\nTestBuildWindow = BuildSettingsWindow\n")
        return lua, g

    def rows(self, table):
        """Элементы lua-таблицы по порядку.

        Итерация lua-таблицы из Python отдаёт КЛЮЧИ, а не значения, поэтому
        индексы берём явно — иначе тест сравнивает «1» с "NearbySpy" и
        выглядит как сломанная регистрация.
        """
        n = self.lua.eval("function(t) return #t end")(table)
        return [table[i] for i in range(1, n + 1)]

    # --- современная API ------------------------------------------------
    def test_modern_settings_api_registers_a_category(self):
        _, g = self.build(modern=True, old=False)
        self.assertTrue(g["NspRegisterOptions"]())
        cats = g["Settings"]["REGISTERED"]
        self.assertEqual(1, len(cats))
        cat = cats[1]
        self.assertEqual("NearbySpy", str(cat["title"]))
        self.assertTrue(cat["registered"], "категория обязана попасть в список AddOns")
        # ID нужен Settings.OpenToCategory — без него вкладка не открывается
        self.assertEqual("NearbySpy", str(cat["ID"]))

    def test_modern_api_opens_with_the_category_get_id(self):
        # Строковое имя система молча не находит: pcall не падает, окно не
        # открывается — и команда «сработала», ничего не показав.
        _, g = self.build(modern=True, old=False)
        g["NspRegisterOptions"]()
        self.assertTrue(g["NspOpenOptions"]())
        opened = self.rows(g["Settings"]["OPENED"])
        self.assertEqual(1, len(opened))
        self.assertEqual(g["NspOptCategory"]["nid"], opened[0])
        self.assertNotEqual("NearbySpy", str(opened[0]))

    def test_falls_back_to_ID_when_category_has_no_GetID(self):
        lua, g = self.build(modern=True, old=False)
        g["NspRegisterOptions"]()
        # категория без GetID (другая сборка API) — открываем по полю ID
        lua.execute("NspOptCategory.GetID = nil")
        self.assertTrue(g["NspOpenOptions"]())
        self.assertEqual(["NearbySpy"], [str(x) for x in self.rows(g["Settings"]["OPENED"])])

    def test_panel_is_created_hidden(self):
        # Так делают оба аддона-образца (Mastercraft, TalkingHeadRu): холст
        # показывает сама система при открытии вкладки. Видимая панель висела бы
        # поверх игры сразу после входа.
        _, g = self.build(modern=True, old=True)
        g["NspRegisterOptions"]()
        self.assertEqual(False, g["NspOptPanel"]["shown"],
                         "панель настроек обязана создаваться скрытой")

    def test_panel_has_its_own_panel_name_for_the_old_api(self):
        _, g = self.build(modern=True, old=True)
        g["NspRegisterOptions"]()
        panel = g["NspOptPanel"]
        self.assertEqual("NearbySpy", str(panel["name"]))

    # --- старая API -----------------------------------------------------
    def test_old_interface_options_api_is_used_when_settings_absent(self):
        _, g = self.build(modern=False, old=True)
        self.assertTrue(g["NspRegisterOptions"]())
        self.assertIsNotNone(g["OLD_ADDED"], "панель обязана уйти в InterfaceOptions_AddCategory")

    def test_old_api_is_opened_twice_so_the_tab_is_selected(self):
        # известная особенность старой API: первый вызов открывает окно, второй
        # выбирает вкладку; с одним вызовом игрок видит список категорий
        _, g = self.build(modern=False, old=True)
        g["NspRegisterOptions"]()
        g["NspOpenOptions"]()
        self.assertEqual(2, g["OLD_OPENED"])

    # --- ни одной API ---------------------------------------------------
    def test_without_any_api_registration_reports_failure(self):
        _, g = self.build(modern=False, old=False)
        self.assertFalse(g["NspRegisterOptions"]())

    def test_without_any_api_the_command_opens_the_addon_window(self):
        # срез переопределяет ShowSettingsWindow настоящей функцией, поэтому
        # проверяем её следствие: собственное окно аддона построено (иначе
        # игрок нажал бы «настройки» и не увидел ничего).
        _, g = self.build(modern=False, old=False)
        self.assertFalse(g["NspOpenOptions"]())
        self.assertIsNotNone(g["optWin"], "должно открыться собственное окно аддона")

    def test_registration_is_idempotent(self):
        _, g = self.build(modern=True, old=True)
        self.assertTrue(g["NspRegisterOptions"]())
        self.assertTrue(g["NspRegisterOptions"]())
        self.assertEqual(1, len(self.rows(g["Settings"]["REGISTERED"])), "вкладка не должна дублироваться")

    # --- строки ---------------------------------------------------------
    def test_panel_shows_the_same_rows_as_the_window(self):
        _, g = self.build()
        g["NspRegisterOptions"]()
        self.assertEqual("NearbySpy", str(g["NspOptPanel"]["name"]))
        from_panel = [r for r in self.rows(g["CHECK_ROWS"])
                      if str(r["parent"]["name"]) == "NearbySpy"]
        selects_panel = [r for r in self.rows(g["SELECT_ROWS"])
                         if str(r["parent"]["name"]) == "NearbySpy"]
        rows = self.rows(g["NspSetRows"]())
        checks_expected = sum(1 for r in rows if r["kind"] == "check")
        selects_expected = sum(1 for r in rows if r["kind"] == "select")
        self.assertEqual(checks_expected, len(from_panel))
        self.assertEqual(selects_expected, len(selects_panel))

    def test_panel_widgets_are_stored_separately_from_the_window(self):
        # общая таблица означала бы, что последний построенный хозяин затирает
        # виджеты другого: перестают обновляться либо окно, либо панель
        _, g = self.build()
        g["NspRegisterOptions"]()
        self.assertIsNotNone(g["optRows"]["peer"])
        self.assertIsNone(g["opt"]["peer"])

    def test_panel_dropdowns_do_not_reuse_window_names(self):
        _, g = self.build()
        # окно первым: его дропдауны занимают имена NearbySpyLangDD/NearbySpyTzDD
        g["TestBuildWindow"]()
        g["NspRegisterOptions"]()      # не должно упасть на duplicate name
        names = [str(r["dd"]) for r in self.rows(g["SELECT_ROWS"])]
        self.assertEqual(len(names), len(set(names)), names)
        self.assertIn("NearbySpyLangDDOpt", names)

    def test_language_switch_relabels_both_hosts(self):
        # Язык переключается в одном месте, а подписи живут в двух: если
        # переписать только окно, вкладка в меню клиента останется на старом
        # языке до /reload — и наоборот.
        lua, g = self.build()
        g["TestBuildWindow"]()
        g["NspRegisterOptions"]()
        lua.execute("function L(k) return 'NEW:' .. k end")
        g["NspRelabelRows"](g["optRows"])
        g["NspRelabelRows"](g["opt"])
        self.assertEqual("NEW:SET_PEER", str(g["optRows"]["peerLabel"]["text"]))
        self.assertEqual("NEW:SET_PEER_D", str(g["optRows"]["peerDesc"]["text"]))
        self.assertEqual("NEW:SET_PEER", str(g["opt"]["peerLabel"]["text"]))
        self.assertEqual("NEW:SET_LANG", str(g["optRows"]["lang"]["label"]["text"]))

    def test_panel_values_follow_the_saved_settings(self):
        _, g = self.build()
        g["DB"]["peerEnabled"] = False
        g["NspRegisterOptions"]()
        g["NspSyncRowValues"](g["optRows"])
        self.assertEqual(False, g["optRows"]["peer"]["checked"])
        g["DB"]["peerEnabled"] = True
        g["NspSyncRowValues"](g["optRows"])
        self.assertEqual(True, g["optRows"]["peer"]["checked"])


if __name__ == "__main__":
    unittest.main()
