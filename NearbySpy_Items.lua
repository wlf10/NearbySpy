-- NearbySpy_Items.lua
-- Сбор имён предметов по ID — ПО ЗАПРОСУ, а не в фоне.
--
-- Зачем: в SavedVariables экипировка лежит ЧИСЛАМИ (item_id), потому что имя
-- живёт только в клиенте игры. Сайт получает 754 разных ID и не может
-- показать ни одного названия. Этот модуль спрашивает имена у клиента и
-- складывает их в словарь db.itemNames[id] = "Имя".
--
-- Почему словарь, а не имена в записях игроков: один ID встречается у многих
-- игроков. 754 предмета × ~25 байт ≈ 19 КБ на весь файл, тогда как имена по
-- слотам в каждой записи росли бы вместе с числом встреченных игроков.
--
-- Почему по запросу, а не в фоне: сбор имён — разовая операция (новые ID
-- появляются редко), а фоновый опрос на каждой встрече грузил бы клиент без
-- пользы. Владелец запускает `/nspy itemnames`, когда нужно.
--
-- Асинхронность: C_Item.RequestLoadItemDataByID только ПРОСИТ клиент загрузить
-- данные; в том же кадре имени ещё нет. Поэтому чтение идёт с задержкой и
-- повторами — иначе половина имён «не находится» на ровном месте.

NSP_ITEMS = NSP_ITEMS or {}
local J = NSP_ITEMS

local GAP = 0.12        -- пауза между предметами
local RETRY = 0.25      -- сколько ждать данные после запроса
local RETRIES = 3       -- попыток на один предмет
-- Потолок за один прогон. Изначально стоял 800, и на живых данных это
-- оказалось мало: предметов в снимках 1460, то есть прогон обрывался на
-- половине и требовал второго захода. Замер скорости: 800 предметов за 178 с
-- (~4.5/с), значит 2000 — это ~7 минут, приемлемо для явной команды.
-- Потолок всё равно нужен: он страхует от зависания на гигантском файле.
local MAX_PER_RUN = 2000

local queue = {}        -- ID, которые надо спросить
local pending = nil     -- {id=..., tries=...}
local run = nil         -- статистика текущего прогона: ok, fail, asked

-- ── инфраструктура ──────────────────────────────────────────────────────────

function J.Say(msg)
    if type(J.P) == "function" then
        local ok = pcall(J.P, msg)
        if ok then return end
    end
    local chat = rawget(_G, "DEFAULT_CHAT_FRAME")
    if chat and chat.AddMessage then
        pcall(chat.AddMessage, chat, "NearbySpy " .. tostring(msg))
    end
end

function J.DB()
    if type(J.GetDB) == "function" then
        local ok, d = pcall(J.GetDB)
        if ok and type(d) == "table" then return d end
    end
    local g = rawget(_G, "NearbySpy")
    if type(g) == "table" then return g end
    return nil
end

local function After(seconds, fn)
    local timer = rawget(_G, "C_Timer")
    if timer and timer.After then
        timer.After(seconds, fn)
    else
        fn()
    end
end

-- ── локали ──────────────────────────────────────────────────────────────────
-- Имя предмета приходит на ЯЗЫКЕ КЛИЕНТА и другого варианта клиент не отдаёт.
-- Поэтому словарь хранится ПО ЛОКАЛЯМ: db.itemNames["ruRU"]["49"] = "...".
-- Иначе клиент с другим языком интерфейса перезаписал бы чужие названия —
-- а на сайте языков шесть, и имена нужны на всех.
--
-- Плоский формат (первая версия модуля) мигрирует в локаль, записанную в
-- db.itemNamesLocale: она фиксируется при первом запуске, потому что позже
-- клиент могли переключить и угадать язык старых данных было бы нельзя.

local function LocaleKey()
    local ok, loc = pcall(function() return GetLocale() end)
    if ok and type(loc) == "string" and loc ~= "" then
        return loc
    end
    return "enUS"
end

-- Словарь текущей локали; create=false — не создавать, если пусто
local function NamesFor(db, create)
    if type(db) ~= "table" then return nil end
    local loc = LocaleKey()
    if type(db.itemNames) ~= "table" then
        if not create then return nil end
        db.itemNames = {}
    end
    -- миграция плоского формата: числовые ключи = id предметов
    if type(db.itemNames[1]) ~= "table" and db.itemNames[loc] == nil then
        local flat = db.itemNames
        local isFlat = false
        for k in pairs(flat) do
            if type(k) == "string" and k:match("^%d+$") then isFlat = true break end
        end
        if isFlat then
            local oldLoc = db.itemNamesLocale
            if type(oldLoc) ~= "string" or oldLoc == "" then oldLoc = loc end
            db.itemNamesLocale = oldLoc
            db.itemNames = { [oldLoc] = flat }
            loc = LocaleKey()
        end
    end
    if type(db.itemNames[loc]) ~= "table" then
        if not create then return nil end
        db.itemNames[loc] = {}
    end
    return db.itemNames[loc]
end

-- Сколько имён собрано во всех локалях
local function CountAll(db)
    if type(db) ~= "table" or type(db.itemNames) ~= "table" then return 0, 0 end
    local total, locs = 0, 0
    for _, tbl in pairs(db.itemNames) do
        if type(tbl) == "table" then
            locs = locs + 1
            for _ in pairs(tbl) do total = total + 1 end
        end
    end
    return total, locs
end

-- ── чтение имени у клиента ──────────────────────────────────────────────────

-- Полные свойства предмета по ID: имя + тип/подтип + слот + качество + ilvl.
--
-- Два источника и оба нужны:
--   * C_Item.GetItemInfoInstant даёт тип/подтип/слот/иконку СРАЗУ, без загрузки
--     данных — то есть «ткань/кожа/латы» и слот известны даже без кэша;
--   * C_Item.GetItemNameByID / GetItemQualityByID / GetDetailedItemLevelInfo
--     требуют загруженных данных, поэтому читаются внутри ContinueOnItemLoad.
--
-- subClassID — то, ради чего всё: 1=Cloth, 2=Leather, 3=Mail, 4=Plate для
-- брони (classID=4). Строковый itemSubType локализован («Ткань»), поэтому
-- едут оба: число для логики и фильтров, строка для показа.
local function ReadItem(id)
    local ci = rawget(_G, "C_Item")
    if type(ci) ~= "table" then return nil end

    local rec = { id = id }

    -- мгновенная часть: не требует загрузки
    if type(ci.GetItemInfoInstant) == "function" then
        local ok, _, itemType, itemSubType, equipLoc, _, classID, subClassID =
            pcall(ci.GetItemInfoInstant, id)
        if ok then
            if type(itemType) == "string" and itemType ~= "" then rec.t = itemType end
            if type(itemSubType) == "string" and itemSubType ~= "" then rec.st = itemSubType end
            if type(equipLoc) == "string" and equipLoc ~= "" then rec.loc = equipLoc end
            if type(classID) == "number" and classID > 0 then rec.c = classID end
            if type(subClassID) == "number" and subClassID > 0 then rec.sc = subClassID end
        end
    end

    -- имя: несколько путей, набор отличается от билда к билду
    if type(ci.GetItemNameByID) == "function" then
        local ok, name = pcall(ci.GetItemNameByID, id)
        if ok and type(name) == "string" and name ~= "" then
            if not (canaccessvalue and not canaccessvalue(name)) then
                rec.name = name:sub(1, 120)
                rec.iname = name:sub(1, 120)   -- совместимость с прежним полем
            end
        end
    end
    if not rec.name and type(ci.GetItemInfo) == "function" then
        local ok, name = pcall(ci.GetItemInfo, id)
        if ok and type(name) == "string" and name ~= "" then
            if not (canaccessvalue and not canaccessvalue(name)) then
                rec.name = name:sub(1, 120)
                rec.iname = name:sub(1, 120)
            end
        end
    end

    -- качество и ilvl: тоже доступны по ID
    if type(ci.GetItemQualityByID) == "function" then
        local ok, q = pcall(ci.GetItemQualityByID, id)
        if ok and type(q) == "number" and q >= 0 and q <= 7 then rec.q = q end
    end
    if type(ci.GetDetailedItemLevelInfo) == "function" then
        local ok, lvl = pcall(ci.GetDetailedItemLevelInfo, id)
        if ok and type(lvl) == "number" and lvl > 0 then rec.ilvl = lvl end
    end

    -- признак «данные загружены»: по нему решаем, ждать ли колбэка
    if type(ci.IsItemDataCachedByID) == "function" then
        local ok, cached = pcall(ci.IsItemDataCachedByID, id)
        rec.cached = ok and cached == true
    end

    -- Статы: C_Item.GetItemStats принимает ССЫЛКУ, не ID. Ссылку даёт
    -- GetItemInfo (второй возврат). Ключи статов — числа внутреннего enum
    -- клиента, названий в исходниках нет: на Forever значения могут отличаться
    -- от retail, поэтому ключи сохраняются как есть, а их смысл выясняется по
    -- собранным данным (см. /nspy itemstats).
    if type(ci.GetItemInfo) == "function" and type(ci.GetItemStats) == "function" then
        local okI, _, link = pcall(ci.GetItemInfo, id)
        if okI and type(link) == "string" and link ~= "" then
            if not (canaccessvalue and not canaccessvalue(link)) then
                local okS, stats = pcall(ci.GetItemStats, link)
                if okS and type(stats) == "table" then
                    local list = {}
                    for k, v in pairs(stats) do
                        -- ключ — число (enum) или строка; значение — число
                        if type(v) == "number" and v ~= 0 then
                            local key = (type(k) == "number") and k or nil
                            if key then list[#list + 1] = key .. ":" .. v end
                        end
                    end
                    if #list > 0 then
                        table.sort(list)
                        rec.stats = table.concat(list, ","):sub(1, 200)
                    end
                end
            end
        end
    end

    return rec
end

local function RequestData(id)
    local ci = rawget(_G, "C_Item")
    if type(ci) ~= "table" then return false end
    if type(ci.RequestLoadItemDataByID) == "function" then
        local ok = pcall(ci.RequestLoadItemDataByID, id)
        if ok then return true end
    end
    if type(ci.RequestLoadItemData) == "function" then
        local ok = pcall(ci.RequestLoadItemData, "item:" .. id)
        if ok then return true end
    end
    return false
end

-- ── сбор списка неизвестных ID ──────────────────────────────────────────────

-- Все item_id из снимков экипировки, для которых ещё нет имени.
-- Источник — сами снимки: аддон уже собрал их при встречах, отдельного
-- хранилища ID не нужно.
local function CollectUnknown(db, limit)
    local names = NamesFor(db, false) or {}
    local props = type(db.itemProps) == "table" and db.itemProps or {}
    local seen, out = {}, {}
    for _, p in pairs(type(db.players) == "table" and db.players or {}) do
        if type(p) == "table" and type(p.gear) == "table" and type(p.gear.ids) == "string" then
            for _, idTxt in p.gear.ids:gmatch("(%d+):(%d+)") do
                local id = tonumber(idTxt)
                -- спрашиваем, если нет ЛИБО имени, ЛИБО свойств: имена и
                -- свойства собираются одним запросом, поэтому «нет свойств» —
                -- такой же повод спросить, как «нет имени»
                local key = id and tostring(id)
                local missing = key and (not names[key] or not props[key])
                if id and id > 0 and not seen[id] and missing then
                    seen[id] = true
                    out[#out + 1] = id
                    if limit and #out >= limit then return out end
                end
            end
        end
    end
    -- стабильный порядок: иначе прогоны не сравнимы между собой
    table.sort(out)
    return out
end

-- ── прогон ──────────────────────────────────────────────────────────────────

local Step  -- forward: вызывается из Finish/таймеров ниже

local function Finish()
    if not run then return end
    local db = J.DB()
    local collected, locs = CountAll(db)
    if db then
        db.debug = db.debug or {}
        db.debug.itemNamesRun = {
            at = time(),
            asked = run.asked,
            ok = run.ok,
            fail = run.fail,
            total = collected,
            locale = LocaleKey(),
        }
    end
    J.Say(("itemnames: [%s] спрошено %d, получено %d, без имени %d; в словаре %d имён в %d локалях")
        :format(LocaleKey(), run.asked, run.ok, run.fail, collected, locs))
    if run.fail > 0 then
        J.Say("itemnames: часть ID клиент не знает — повторный запуск попробует снова")
    end
    J.Say("itemnames: словарь в SavedVariables → debug/../itemNames (запись при выходе из игры)")
    run = nil
end

Step = function()
    if not run then return end
    if not pending then
        local id = table.remove(queue, 1)
        if not id then Finish() return end
        if run.asked >= MAX_PER_RUN then
            J.Say(("itemnames: достигнут предел %d за прогон, останавливаюсь"):format(MAX_PER_RUN))
            Finish()
            return
        end
        run.asked = run.asked + 1
        RequestData(id)
        pending = { id = id, tries = 0 }
        -- ContinueOnItemLoad — официальный колбэк «данные предмета загружены»:
        -- срабатывает и сразу, если уже в кэше, и позже, когда клиент догрузит.
        -- Он надёжнее таймера с повторами (таймер оставлен ниже как страховка
        -- на случай, если объект Item в билде отсутствует).
        local used = false
        local itemProto = rawget(_G, "Item")
        if type(itemProto) == "table" and type(itemProto.CreateFromItemID) == "function" then
            local okC, obj = pcall(itemProto.CreateFromItemID, itemProto, id)
            if okC and type(obj) == "table" and type(obj.ContinueOnItemLoad) == "function" then
                local okK = pcall(obj.ContinueOnItemLoad, obj, function()
                    if not run or not pending or pending.id ~= id then return end
                    After(0.05, Step)
                end)
                used = okK
            end
        end
        if not used then
            After(RETRY, Step)     -- страховка без объекта Item
        end
        return
    end

    local id = pending.id
    local rec = ReadItem(id)
    -- имя — основной признак успеха: без него запись бесполезна для сайта
    if rec and rec.name then
        local db = J.DB()
        if db then
            local names = NamesFor(db, true)
            if names then
                -- имя отдельным словарём (как раньше), свойства — своим
                names[tostring(id)] = rec.name
            end
            -- свойства предмета: тип, подтип, слот, качество, ilvl.
            -- Отдельно от имён: имена по локалям, свойства — одинаковы везде.
            db.itemProps = db.itemProps or {}
            local props = db.itemProps[tostring(id)] or {}
            if rec.c then props.c = rec.c end
            if rec.sc then props.sc = rec.sc end
            if rec.t then props.t = rec.t end
            if rec.st then props.st = rec.st end
            if rec.loc then props.loc = rec.loc end
            if rec.q then props.q = rec.q end
            if rec.ilvl then props.ilvl = rec.ilvl end
            if rec.stats then props.stats = rec.stats end
            db.itemProps[tostring(id)] = props
        end
        run.ok = run.ok + 1
        pending = nil
        -- прогресс: прогон на 1500+ предметов идёт минутами, и молчание всё
        -- это время выглядит как зависание
        if run.ok % 200 == 0 then
            local left = #queue
            J.Say(("itemnames: собрано %d, в очереди осталось %d"):format(run.ok, left))
        end
        After(GAP, Step)
        return
    end

    pending.tries = pending.tries + 1
    if pending.tries < RETRIES then
        RequestData(id)
        After(RETRY, Step)
        return
    end
    -- клиент не отдал даже имя: считаем пропущенным, но свойства могли прийти
    if rec and (rec.c or rec.loc) then
        local db = J.DB()
        if db then
            db.itemProps = db.itemProps or {}
            local props = db.itemProps[tostring(id)] or {}
            if rec.c then props.c = rec.c end
            if rec.sc then props.sc = rec.sc end
            if rec.t then props.t = rec.t end
            if rec.st then props.st = rec.st end
            if rec.loc then props.loc = rec.loc end
            if rec.q then props.q = rec.q end
            if rec.ilvl then props.ilvl = rec.ilvl end
            if rec.stats then props.stats = rec.stats end
            db.itemProps[tostring(id)] = props
        end
    end
    run.fail = run.fail + 1
    pending = nil
    After(GAP, Step)
end

-- /nspy itemnames [max] — спросить имена для неизвестных ID
function J.Run(limit)
    if run then
        run = nil
        queue = {}
        pending = nil
        J.Say("itemnames: остановлено")
        return
    end
    local db = J.DB()
    if not db then J.Say("itemnames: нет таблицы SavedVariables") return end
    local ci = rawget(_G, "C_Item")
    if type(ci) ~= "table" then
        J.Say("itemnames: в этом клиенте нет C_Item — имена недоступны")
        return
    end
    local n = tonumber(limit) or MAX_PER_RUN
    if n < 1 then n = 1 end
    if n > MAX_PER_RUN then n = MAX_PER_RUN end
    queue = CollectUnknown(db, n)
    if #queue == 0 then
        J.Say("itemnames: все известные ID уже имеют имена")
        return
    end
    run = { asked = 0, ok = 0, fail = 0 }
    local have = 0
    local cur = NamesFor(db, false)
    if cur then for _ in pairs(cur) do have = have + 1 end end
    J.Say(("itemnames: [%s] неизвестных %d, в этой локали уже %d; ~%.0f мин")
        :format(LocaleKey(), #queue, have, #queue * GAP / 60))
    Step()
end



-- /nspy itemstats probe — ЧТО реально возвращает GetItemStats.
--
-- Первый прогон дал «статов нет ни у одного»: сбор писал только числовые ключи
-- (type(k)=="number"), и если клиент отдаёт ключи СТРОКАМИ ("ITEM_MOD_...")
-- или таблицу другой формы, всё молча отбрасывалось. Эта проба печатает
-- сырой ответ на живом предмете — форма, ключи, типы.
function J.ProbeStats()
    local ci = rawget(_G, "C_Item")
    if type(ci) ~= "table" or type(ci.GetItemStats) ~= "function" then
        J.Say("probe: C_Item.GetItemStats отсутствует")
        return
    end
    local db = J.DB()
    -- берём любой предмет из снимков, лучше надетый на игрока
    local id
    for _, p in pairs(type(db) == "table" and db.players or {}) do
        if type(p) == "table" and type(p.gear) == "table" and type(p.gear.ids) == "string" then
            local first = p.gear.ids:match("%d+:(%d+)")
            if first then id = tonumber(first) break end
        end
    end
    if not id then J.Say("probe: нет снимков одежды") return end

    J.Say("probe: предмет id=" .. id)

    -- 1. ссылка
    local link
    if type(ci.GetItemInfo) == "function" then
        local ok, _, l = pcall(ci.GetItemInfo, id)
        if ok and type(l) == "string" then link = l end
    end
    if not link then
        J.Say("probe: GetItemInfo не дал ссылку (данные не загружены?)")
        return
    end
    J.Say("probe: ссылка = " .. link:sub(1, 90))

    -- 2. что вернёт GetItemStats
    local ok, stats = pcall(ci.GetItemStats, link)
    if not ok then
        J.Say("probe: ошибка GetItemStats: " .. tostring(stats):sub(1, 120))
        return
    end
    if type(stats) ~= "table" then
        J.Say("probe: GetItemStats вернул " .. type(stats) .. ", не таблицу")
        return
    end
    local n = 0
    local shown = 0
    for k, v in pairs(stats) do
        n = n + 1
        if shown < 12 then
            shown = shown + 1
            J.Say(("probe:   ключ [%s] %s = [%s] %s")
                :format(type(k), tostring(k), type(v), tostring(v):sub(0, 40)))
        end
    end
    J.Say(("probe: всего записей в таблице: %d"):format(n))
    if n == 0 then
        J.Say("probe: таблица ПУСТАЯ — GetItemStats на этом клиенте не отдаёт статов")
    end
end

-- /nspy itemstats — разбор ключей статов по собранным данным.
--
-- Зачем: C_Item.GetItemStats отдаёт таблицу «ключ enum клиента → значение», и
-- НАЗВАНИЙ этих ключей в клиенте нет. На retail известно, что 3=Agility,
-- 4=Strength, 7=Stamina, но Forever — кастомный сервер, и слепо переносить
-- retail-таблицу нельзя: при ошибке статы на сайте будут перепутаны.
--
-- Поэтому смотрим ФАКТЫ: какие ключи реально встречаются, с какими пределами
-- значений и на каких предметах. По этим данным ключ опознаётся однозначно:
--   * Strength/Agility/Stamina/Intellect/Spirit — десятки на высоких уровнях;
--   * крит/хаст/меткость — небольшие числа;
--   * броня — сотни, только на броне.
function J.ReportStats()
    local db = J.DB()
    if not db or type(db.itemProps) ~= "table" then
        J.Say("itemstats: свойств ещё нет — запусти /nspy itemnames")
        return
    end
    local names = NamesFor(db, false) or {}
    local byKey = {}   -- key → { count, max, sample={id=value} }
    local total, withStats = 0, 0
    for id, pr in pairs(db.itemProps) do
        if type(pr) == "table" then
            total = total + 1
            local s = pr.stats
            if type(s) == "string" and s ~= "" then
                withStats = withStats + 1
                for pair in s:gmatch("[^,]+") do
                    local k, v = pair:match("^(%d+):(%-?%d+)$")
                    if k then
                        k, v = tonumber(k), tonumber(v)
                        local e = byKey[k]
                        if not e then e = { count = 0, max = 0, min = 1e9, sample = {} }
                            byKey[k] = e end
                        e.count = e.count + 1
                        if v > e.max then e.max = v end
                        if v < e.min then e.min = v end
                        if #e.sample < 3 then
                            e.sample[#e.sample + 1] = (names[tostring(id)] or ("#" .. id)) .. "=" .. v
                        end
                    end
                end
            end
        end
    end
    if withStats == 0 then
        J.Say(("itemstats: свойств %d, но статов нет ни у одного — API не отдал"):format(total))
        return
    end
    local keys = {}
    for k in pairs(byKey) do keys[#keys + 1] = k end
    table.sort(keys)
    J.Say(("itemstats: предметов со статами %d из %d, разных ключей %d")
        :format(withStats, total, #keys))
    for _, k in ipairs(keys) do
        local e = byKey[k]
        J.Say(("  ключ %2d: предметов %3d, значения %d..%d, примеры: %s")
            :format(k, e.count, e.min, e.max, table.concat(e.sample, "; ")))
    end
    if db.debug then
        db.debug.itemStatsKeys = { at = time(), keys = #keys, withStats = withStats }
    end
end

-- Отчёт без запросов: что уже собрано
function J.Report()
    local db = J.DB()
    local have, sample = 0, {}
    local cur = NamesFor(db, false)
    if cur then
        for id, name in pairs(cur) do
            have = have + 1
            if #sample < 5 then sample[#sample + 1] = id .. "=" .. tostring(name) end
        end
    end
    local unknown = 0
    if db then unknown = #CollectUnknown(db, nil) end
    local total, locs = CountAll(db)
    -- по локалям: видно, какие языки уже есть и сколько в каждом
    local per = {}
    if db and type(db.itemNames) == "table" then
        for loc, tbl in pairs(db.itemNames) do
            if type(tbl) == "table" then
                local n = 0
                for _ in pairs(tbl) do n = n + 1 end
                per[#per + 1] = loc .. "=" .. n
            end
        end
        table.sort(per)
    end
    local propsN, withType, withSlot = 0, 0, 0
    if db and type(db.itemProps) == "table" then
        for _, pr in pairs(db.itemProps) do
            if type(pr) == "table" then
                propsN = propsN + 1
                if pr.sc or pr.c then withType = withType + 1 end
                if pr.loc then withSlot = withSlot + 1 end
            end
        end
    end
    J.Say(("itemnames: [%s] собрано %d, неизвестных %d; всего %d в %d локалях")
        :format(LocaleKey(), have, unknown, total, locs))
    J.Say(("itemprops: свойств %d (тип %d, слот %d)")
        :format(propsN, withType, withSlot))
    if #per > 0 then J.Say("itemnames: по локалям — " .. table.concat(per, ", ")) end
    if unknown > 0 then
        J.Say("itemnames: другая локаль добирается запуском команды на клиенте с тем языком")
    end
    if #sample > 0 then
        table.sort(sample)
        J.Say("itemnames: пример — " .. table.concat(sample, "; "))
    end
end

return J
