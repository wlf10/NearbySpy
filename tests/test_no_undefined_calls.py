"""Окно не должно вызывать несуществующие функции (Lua 5.1, статический разбор).

Живой случай 26.11.2026: при удалении фильтров мира/класса/уровня я вырезал
блок по маркерам и вместе с селекторами унёс `TacticalFilter` — функцию,
которая рисует ТАБЫ списка. Компилятор этого не видит: вызов глобальной
функции — это просто `attempt to call a nil value` в рантайме, и SavedVariables
показал его как

    ОШИБКА окна: Interface/AddOns/NearbySpy/NearbySpy.lua:7158: attempt to call a nil value

то есть окно строилось до первого таба и дальше падало — «ничего не
показывается». Тесты этого не ловили, потому что каждый тест вырезает свой
блок и подставляет заглушки, а целостность файла не проверял никто.

Этот тест закрывает дыру: собирает ВСЕ имена, которые вызываются в файле, и
требует, чтобы каждое было либо определено в нём, либо объявлено локально
(forward-объявление вида `local TacticalUpdate`).
"""

from pathlib import Path
import re
import unittest

ADDON = Path(__file__).resolve().parents[1]
FILES = ["NearbySpy.lua", "NearbySpy_Locale.lua", "NearbySpy_Inspect.lua",
         "NearbySpy_Journal.lua", "NearbySpy_Items.lua", "NearbySpy_MC.lua",
         "NearbySpy_Zones.lua"]


def read(name):
    return (ADDON / name).read_text(encoding="utf-8")


def strip_comments(src: str) -> str:
    """Убрать комментарии: упоминания функций в тексте — не вызовы."""
    src = re.sub(r"--\[\[.*?\]\]", "", src, flags=re.S)
    out = []
    for line in src.splitlines():
        # строка целиком в комментарии
        if line.strip().startswith("--"):
            out.append("")
            continue
        # хвостовой комментарий после кода
        cut = line.find("--")
        if cut > 0 and line[:cut].count('"') % 2 == 0:
            line = line[:cut]
        out.append(line)
    return "\n".join(out)


def defined_names(src: str) -> set:
    """Всё, что объявлено: функции, forward-локали, глобалы-присваивания."""
    names = set()
    names |= set(re.findall(r"(?:^|\s)(?:local\s+)?function\s+([A-Za-z_]\w*)\s*\(", src))
    names |= set(re.findall(r"([A-Za-z_]\w*)\s*=\s*function\s*\(", src))
    # `local X` и `local X, Y` — forward-объявления и обычные локали
    for decl in re.findall(r"^\s*local\s+([\w\s,]+?)(?:\s*=|\s*$)", src, re.M):
        for part in decl.split(","):
            part = part.strip()
            if re.fullmatch(r"[A-Za-z_]\w*", part):
                names.add(part)
    return names


# Имена, которые приходят из клиента WoW или из Lua-стандарта. Список не
# пытается быть полным: он покрывает то, что реально вызывается в аддоне.
CLIENT = set("""
pairs ipairs next select type tostring tonumber unpack rawget rawset setmetatable
getmetatable print error assert pcall xpcall require string table math os io
date time random floor ceil abs max min sort concat sub upper lower gsub gmatch
find format rep match byte char len insert remove select
CreateFrame GameTooltip UIParent GetLocale GetBuildInfo GetTime UnitName UnitClass
UnitLevel UnitExists UnitIsUnit UnitGUID UnitFactionGroup UnitRace UnitPosition
UnitIsPlayer UnitIsFriend UnitCanAttack UnitIsDead UnitIsConnected UnitHealth
UnitHealthMax UnitPower UnitPowerMax GetRealmName GetChannelName GetChannelList
JoinChannelByName LeaveChannelByName SendChatMessage ChatFrame_AddMessageEventFilter
ChatFrame_RemoveChannel DEFAULT_CHAT_FRAME GetCVar SetCVar GetCVarBool
GetPlayerMapPosition C_Map C_Timer C_ChatInfo C_TooltipInfo C_Traits C_Item
C_Container C_Spell C_QuestLog C_AddOns C_System InCombatLockdown IsInInstance
GetZoneText GetRealZoneText GetMinimapZoneText GetInstanceInfo GetGuildRosterInfo
GuildRoster RequestGuildRosterInfo IsInGuild GetNumGuildMembers
GetGuildRosterMOTD GetGuildRosterLastOnline GetGuildRosterShowOffline
NotifyInspect INSPECT_READY CanInspect CheckInteractDistance
PlaySound SlashCmdList hooksecurefunc strfind strsub strmatch strformat strlower
strupper strrep tinsert tremove sort wipe strsplit strupper format
GetInventoryItemLink GetInventoryItemID GetItemInfo GetItemInfoInstant
GetItemCount GetItemStats GetItemIconByID GetItemNameByID
LOCALIZED_CLASS_NAMES_MALE RAID_CLASS_COLORS UnitAffectingCombat
IsShiftKeyDown IsControlKeyDown IsAltKeyDown GetMouseFocus GetCursorPosition
UIFrameFadeIn UIFrameFadeOut StaticPopup_Hide StaticPopup_Show
InterfaceOptions_AddCategory InterfaceOptionsFrame_OpenToCategory
Settings RegisterAddonMessagePrefix IsAddonMessagePrefixRegistered
GetAddOnMetadata LoadAddOn IsAddOnLoaded
LFGParentFrameTab3_OnClick UIDropDownMenu_AddButton UIDropDownMenu_CreateInfo
UIDropDownMenu_Initialize UIDropDownMenu_SetText UIDropDownMenu_SetWidth
canaccessvalue
""".split())

# Имена, которые приходят ПАРАМЕТРАМИ функции (колбэки): вызываются, но
# объявлять их в файле не нужно — они часть сигнатуры.
CALLBACK_PARAMS = set("""
accept onPick getCurrent entriesFn format
""".split())


KEYWORDS = set("""
and break do else elseif end false for function if in local nil not or repeat
return then true until while
""".split())


def strip_strings(src: str) -> str:
    """Убрать содержимое строковых литералов: слова из текстов — не вызовы."""
    out = []
    i, n = 0, len(src)
    while i < n:
        ch = src[i]
        if ch in ('"', "'"):
            quote = ch
            i += 1
            while i < n:
                if src[i] == "\\":
                    i += 2
                    continue
                if src[i] == quote:
                    i += 1
                    break
                i += 1
            out.append('""')
            continue
        out.append(ch)
        i += 1
    return "".join(out)


class NoUndefinedCallsTests(unittest.TestCase):
    """Каждый вызов в файле должен резолвиться в объявленное имя."""

    def setUp(self):
        # порядок важен: сначала строки и комментарии, потом разбор
        raw = read("NearbySpy.lua")
        self.src = strip_strings(strip_comments(raw))
        self.defined = defined_names(self.src)
        for other in FILES:
            if other == "NearbySpy.lua":
                continue
            self.defined |= defined_names(strip_strings(strip_comments(read(other))))

    def calls(self):
        """Вызовы вида `Name(`; методы (`obj:Method(`) и ключи (`t.Name(`) не в счёт."""
        names = set()
        for m in re.finditer(r"(?<![\w.:])([A-Za-z_]\w*)\s*\(", self.src):
            name = m.group(1)
            if name in KEYWORDS:
                continue
            before = self.src[max(0, m.start() - 12):m.start()]
            if re.search(r"function\s*$", before):
                continue          # это объявление, а не вызов
            if re.search(r"[=,{(]\s*$", before) and self.src[m.end():m.end()+2] == ")":
                continue          # `onPick = function()` уже покрыт выше
            names.add(name)
        return names

    def test_no_undefined_function_is_called(self):
        missing = sorted(n for n in self.calls()
                         if n not in self.defined and n not in CLIENT
                         and n not in CALLBACK_PARAMS)
        self.assertEqual([], missing,
                         "в файле вызываются несуществующие функции — это "
                         "attempt to call a nil value в рантайме, окно падает: "
                         + ", ".join(missing))

    def test_the_regression_itself(self):
        """TacticalFilter: функция ТАБОВ списка. Её удаление роняло окно."""
        self.assertIn("TacticalFilter", self.defined,
                      "TacticalFilter (табы списка) пропала из файла — окно упадёт "
                      "на построении панели фильтров")
        # Маркер проверяем в СЫРОМ тексте: в очищенном строки заменены на "",
        # и `TacticalFilter(toolbar, "all"` там не найти (поймано прогоном).
        raw = read("NearbySpy.lua")
        self.assertIn('TacticalFilter(toolbar, "all"', raw)


if __name__ == "__main__":
    unittest.main()
