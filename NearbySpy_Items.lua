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
local MAX_PER_RUN = 800 -- предохранитель: один запуск не должен висеть вечно

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

-- Имя по ID. Оба пути в pcall: набор функций отличается от билда к билду,
-- и падать на отсутствующей не надо. Дополнительно снимаем привязку к
-- формату ссылки — она может быть секретной строкой в этом клиенте.
local function NameOf(id)
    local ci = rawget(_G, "C_Item")
    if type(ci) ~= "table" then return nil end
    if type(ci.GetItemNameByID) == "function" then
        local ok, name = pcall(ci.GetItemNameByID, id)
        if ok and type(name) == "string" and name ~= "" then
            if not (canaccessvalue and not canaccessvalue(name)) then
                return name
            end
        end
    end
    if type(ci.GetItemInfo) == "function" then
        local ok, name = pcall(ci.GetItemInfo, id)
        if ok and type(name) == "string" and name ~= "" then
            if not (canaccessvalue and not canaccessvalue(name)) then
                return name
            end
        end
    end
    return nil
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
    local seen, out = {}, {}
    for _, p in pairs(type(db.players) == "table" and db.players or {}) do
        if type(p) == "table" and type(p.gear) == "table" and type(p.gear.ids) == "string" then
            for _, idTxt in p.gear.ids:gmatch("(%d+):(%d+)") do
                local id = tonumber(idTxt)
                if id and id > 0 and not seen[id] and not names[tostring(id)] then
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
        After(RETRY, Step)     -- данные приходят не мгновенно
        return
    end

    local id = pending.id
    local name = NameOf(id)
    if name then
        local db = J.DB()
        if db then
            local names = NamesFor(db, true)
            if names then names[tostring(id)] = name:sub(1, 120) end
        end
        run.ok = run.ok + 1
        pending = nil
        After(GAP, Step)
        return
    end

    pending.tries = pending.tries + 1
    if pending.tries < RETRIES then
        RequestData(id)        -- попросить ещё раз и подождать
        After(RETRY, Step)
        return
    end
    -- клиент так и не отдал имя: ID не существует или данные недоступны
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
    J.Say(("itemnames: [%s] неизвестных %d, в этой локали уже %d; иду по одному, ~%.0f с")
        :format(LocaleKey(), #queue, have, #queue * (GAP + RETRY)))
    Step()
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
    J.Say(("itemnames: [%s] собрано %d, неизвестных %d; всего %d в %d локалях")
        :format(LocaleKey(), have, unknown, total, locs))
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
