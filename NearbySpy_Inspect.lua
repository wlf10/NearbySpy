-- NearbySpy_Inspect.lua
-- Passive inspection: gear and talent build of players we MEET, collected
-- without the player doing anything and without opening any window.
--
-- The API path (measured on the live client, 19.11.2026):
--   CanInspect(unit, true) → NotifyInspect(unit) → event INSPECT_READY
--   → GetInventoryItemID(unit, slot) for slots 1..19
--   → C_PaperDollInfo.GetInspectItemLevel(unit)
--   → C_Traits.GenerateInspectImportString(unit)   -- the whole talent build
-- None of these need a UI frame: the client's own inspect window calls the
-- same functions, it just draws the result. Verified in game: NotifyInspect
-- called from code gets answered (no hardware gate, unlike /who).
--
-- THREE RULES THIS FILE EXISTS TO ENFORCE:
--
--   1) THROTTLE. The client's inspect code warns that the server DROPS inspect
--      data when requests are flooded. So requests go one at a time with a
--      randomised 2.5–4.5 s gap, each player is inspected at most once per
--      PER_PLAYER_COOLDOWN, and a session stops after MAX_PER_SESSION.
--   2) SILENCE IS A FINDING. A request that never gets INSPECT_READY is
--      recorded as a timeout — never as "inspected, empty". The two mean
--      opposite things (server ignoring us vs. server saying "no gear").
--   3) IDS, NOT LINKS. GetInventoryItemLink only resolves items already in the
--      client's cache: a measured case returned 0 links for 10 valid IDs.
--      So the slot map is stored as numeric IDs; a link is resolved lazily
--      when something wants to show it.
--
-- SavedVariables shape (inside the existing player record, so the site gets it
-- with the file it already accepts):
--   db.players[key].gear = { at = <unix>, ilvl = 57, ids = "5:3283,7:5941", imp = "C0cB..." }
-- Growth is bounded by MAX_GEAR: the oldest snapshots are dropped from the
-- record (the player row itself stays), tracked by db.gearRing.
--
-- WHY A SEPARATE FILE: NearbySpy.lua sits at the Lua 5.1 ceiling of 200
-- top-level locals, so this lives behind the global NSP_INSPECT and
-- NearbySpy.lua injects what it needs:
--
--   NSP_INSPECT.P       -- the addon's P() (chat + SavedVariables ring)
--   NSP_INSPECT.GetDB   -- the addon's GetDB()
--   NSP_INSPECT.DbgErr  -- the addon's per-source error recorder

NSP_INSPECT = NSP_INSPECT or {}
local J = NSP_INSPECT

-- Pacing between requests. Полевые замеры 19.11.2026 (счётчики за все сессии):
--   sent=614, ok=266 → КПД 43%, из потерь timeout всего 24 (3.9%).
-- То есть сервер НЕ флудится даже на 1.5–3.0 с, а теряются запросы на том,
-- что игрок уходит между отправкой и ответом (lostAfterEvent=300).
-- Запас по таймаутам есть, поэтому шаг уменьшен: больше запросов в минуту.
-- ⚠️ Если `timeout` вырастет выше ~10% от sent — вернуть 1.5/3.0.
local GAP_MIN, GAP_MAX = 0.9, 1.8
local PER_PLAYER_COOLDOWN = 6 * 3600   -- same player: at most once per 6 hours
-- Очередь: сколько запросов копится. Было 40, но при шаге ~1 с это 40 секунд
-- ожидания для последнего, и он гарантированно уходит до запроса. Подняли до
-- 80 и ОДНОВРЕМЕННО ужесточили MAX_AGE (см. ниже) — держать длинную очередь
-- имеет смысл только если старые записи в ней отбрасываются быстро.
local MAX_QUEUE = 80                   -- pending requests, rest are dropped
local MAX_PER_SESSION = 200            -- hard stop: never flood the server
-- Сколько снимков экипировки держать в SavedVariables.
--
-- Было 2000, и это оказалось узким местом: встреч в файле ~55 тысяч, снимков
-- в SV — 2643, то есть у 96% записей снимка нет вообще. На сайте это выглядит
-- как «Снимка пока нет: аддон соберёт при следующей встрече» у игроков,
-- которых встречали десятки раз, — снимок снят и вытеснен кольцом.
--
-- Замер цены (24.11.2026): снимок в файле ≈ 200 байт (at, ilvl, ids, slots,
-- imp), 2000 → 2643 снимка это ~0.5 МБ при файле 23.4 МБ. 6000 добавит
-- ~0.8 МБ — на фоне лимита SV 128 МБ и 26 МБ живого файла это ничто, а
-- покрытие вырастает втрое.
--
-- Верхнюю границу всё равно держим: без кольца файл растёт с каждой новой
-- встречей, а это единственная часть SV, которая растёт с цензом.
local MAX_GEAR = 6000                  -- snapshots kept in SavedVariables
local SLOT_FIRST, SLOT_LAST = 1, 19
local TIMEOUT = 8                      -- seconds to wait for INSPECT_READY
-- A queued request older than this describes a player who has already walked
-- away. Field data 19.11.2026: with 60 s the queue processed ghosts — 35 of 52
-- queued requests ended as "player gone" and 12 more lost the answer because
-- the unit vanished between request and INSPECT_READY.
-- Запись в очереди живёт 12 с (было 20). Это ключевая правка: замер показал
-- lostAfterEvent=300 из 348 потерь — сервер отвечает, но игрока уже нет.
-- Долгая очередь при коротком шаге бессмысленна: к моменту запроса человека
-- рядом уже нет, и вызов тратится впустую. 12 с = несколько шагов очереди.
local MAX_AGE = 12

-- Unit tokens worth searching when the token we queued has been reassigned.
-- Measured 19.11.2026: 78 of 102 queued requests died on "unit changed" because
-- target/mouseover are recycled long before the paced queue reaches them. The
-- player is usually still in the world — just under a different token — so the
-- GUID is searched again instead of dropping the request.
local SEARCH_UNITS = { "target", "mouseover", "focus", "player" }

local queue, queuedGuid = {}, {}
local pending = nil      -- { guid, key, unit, at, token }
local token = 0          -- identifies the request in flight (see NextStep)
local sentThisSession = 0
local NextStep           -- forward: the timers below call it

-- ─────────────────────────────────────────────────────────────────────────────
-- plumbing
-- ─────────────────────────────────────────────────────────────────────────────

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

local function Err(src, err)
    if type(J.DbgErr) == "function" then
        pcall(J.DbgErr, src, err)
    end
end

local function After(seconds, fn)
    local timer = rawget(_G, "C_Timer")
    if timer and timer.After then
        timer.After(seconds, fn)
    else
        fn()
    end
end

local function Counter(name)
    local db = J.DB()
    if not db then return end
    db.debug = db.debug or {}
    db.debug.inspectQueue = db.debug.inspectQueue or {}
    local c = db.debug.inspectQueue
    c[name] = (c[name] or 0) + 1
end

-- Which live unit token currently carries this GUID? The queued token may have
-- been recycled (target/mouseover are), but the player is usually still on
-- screen under another one. Returns nil when the player is truly gone.
local function FindUnit(guid)
    if type(guid) ~= "string" or guid == "" then return nil end
    if type(UnitGUID) ~= "function" then return nil end
    for _, base in ipairs(SEARCH_UNITS) do
        local ok, g = pcall(UnitGUID, base)
        if ok and g == guid and UnitExists(base) then return base end
    end
    for i = 1, 4 do
        local t = "party" .. i
        local ok, g = pcall(UnitGUID, t)
        if ok and g == guid and UnitExists(t) then return t end
    end
    for i = 1, 40 do
        local t = "raid" .. i
        local ok, g = pcall(UnitGUID, t)
        if ok and g == guid and UnitExists(t) then return t end
    end
    for i = 1, 40 do
        local t = "nameplate" .. i
        local ok, g = pcall(UnitGUID, t)
        if ok and g == guid and UnitExists(t) then return t end
    end
    return nil
end

J.FindUnit = FindUnit

-- ─────────────────────────────────────────────────────────────────────────────
-- storage
-- ─────────────────────────────────────────────────────────────────────────────

-- Slots as "slot:id,slot:id,..." — compact enough for ~2000 players in SV and
-- still trivial to parse on the site side.
local function SlotMap(unit)
    local parts, count = {}, 0
    for slot = SLOT_FIRST, SLOT_LAST do
        local ok, id = pcall(GetInventoryItemID, unit, slot)
        if ok and type(id) == "number" and id > 0 then
            parts[#parts + 1] = slot .. ":" .. id
            count = count + 1
        end
    end
    return table.concat(parts, ","), count
end

-- Bounded ring of keys that carry a gear snapshot: the player row stays, only
-- the snapshot is dropped. Without this the SV file grows with every new
-- player ever inspected.
local function Evict(db)
    db.gearRing = db.gearRing or {}
    while #db.gearRing > MAX_GEAR do
        local oldKey = table.remove(db.gearRing, 1)
        local entry = oldKey and db.players and db.players[oldKey]
        if entry then entry.gear = nil end
    end
end

local function Store(key, snapshot)
    local db = J.DB()
    if not db or type(key) ~= "string" or key == "" then return false end
    local entry = db.players and db.players[key]
    if type(entry) ~= "table" then return false end
    entry.gear = snapshot
    db.gearRing = db.gearRing or {}
    local seen = false
    for _, k in ipairs(db.gearRing) do
        if k == key then seen = true break end
    end
    if not seen then db.gearRing[#db.gearRing + 1] = key end
    Evict(db)
    return true
end

-- Тот же путь записи нужен приёму peer-снапшотов (NearbySpy.lua): снапшот от
-- пира обязан попадать в gearRing, иначе вытеснение его не видит и файл растёт.
-- Объявление стоит ПОСЛЕ local function Store: ссылка выше него разрешилась бы
-- в nil-глобал (Lua 5.1 видит только уже объявленные локалы).
J.Store = function(key, snapshot) return Store(key, snapshot) end

local function RecentGear(key)
    local db = J.DB()
    if not db or type(db.players) ~= "table" then return nil end
    local entry = db.players[key]
    return type(entry) == "table" and entry.gear or nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- queue
-- ─────────────────────────────────────────────────────────────────────────────

-- Counters are per SESSION: /nspy gear must answer "how did it go today", not
-- "since the addon was installed". The running totals are kept apart so nothing
-- is lost.
function J.Start()
    local db = J.DB()
    if not db then return end
    db.debug = db.debug or {}
    local done = db.debug.inspectQueue
    if type(done) == "table" then
        db.debug.inspectTotal = db.debug.inspectTotal or {}
        for k, v in pairs(done) do
            db.debug.inspectTotal[k] = (db.debug.inspectTotal[k] or 0) + (v or 0)
        end
    end
    db.debug.inspectQueue = {}
    sentThisSession = 0
end

function J.Enabled()
    local db = J.DB()
    if db and db.gearOff then return false end
    return rawget(_G, "NotifyInspect") ~= nil
end

-- Called from the addon's Record() for every player it meets. Everything cheap
-- happens here; the actual request is paced by NextStep.
function J.Request(unit, key)
    if not J.Enabled() then return end
    if type(unit) ~= "string" or type(key) ~= "string" or key == "" then return end
    if sentThisSession >= MAX_PER_SESSION then return end
    if pending then
        if pending.guid and pending.guid == (UnitGUID(unit) or "") then return end
    end
    if queuedGuid[key] then return end
    if #queue >= MAX_QUEUE then
        Counter("droppedFull")
        return
    end
    -- freshness: a snapshot younger than the cooldown is not worth a request
    local gear = RecentGear(key)
    if type(gear) == "table" and gear.at then
        if time() - gear.at < PER_PLAYER_COOLDOWN then
            Counter("skipCooldown")
            return
        end
    end
    if type(UnitGUID) == "function" then
        local guid = UnitGUID(unit)
        if type(guid) ~= "string" or guid == "" then return end
        if type(UnitIsUnit) == "function" and UnitIsUnit(unit, "player") then return end
        if type(UnitIsPlayer) == "function" and not UnitIsPlayer(unit) then return end
        queue[#queue + 1] = { unit = unit, key = key, guid = guid, at = time() }
        queuedGuid[key] = true
        Counter("queued")
        J.Pump()
    end
end

-- Start the next request unless one is already in flight.
function J.Pump()
    if pending or #queue == 0 then return end
    NextStep()
end

function NextStep()
    if pending then return end
    -- LIFO, not FIFO: the queue is filled by encounters (nameplate, target,
    -- mouseover) and drained at one request per 2.5-4.5 s, so a FIFO queue
    -- spends its requests on players who left the screen first — measured
    -- 19.11.2026: 17 requests, 2 snapshots, 35 "player gone". The newest entry
    -- is the one most likely still standing in front of us.
    local item = table.remove(queue)
    if not item then return end
    queuedGuid[item.key] = nil
    if sentThisSession >= MAX_PER_SESSION then return end

    -- a request that waited in the queue too long describes a moment that has
    -- passed; asking the server about it wastes one of the few allowed calls
    if item.at and time() - item.at > MAX_AGE then
        Counter("expired")
        After(0.1, NextStep)
        return
    end

    -- Resolve the player AGAIN: the token we queued may now point at someone
    -- else. The GUID is what identifies the player, the token is just a handle.
    local unit = item.unit
    local okG, curGuid = pcall(UnitGUID, unit)
    if not okG or curGuid ~= item.guid or not UnitExists(unit) then
        unit = FindUnit(item.guid)
        if not unit then
            Counter("skipGone")
            After(0.1, NextStep)
            return
        end
        Counter("relocated")
    end
    if type(UnitIsUnit) == "function" and UnitIsUnit(unit, "player") then
        Counter("skipSelf")
        After(0.1, NextStep)
        return
    end
    local okCan, can = pcall(CanInspect, unit, true)
    if not okCan or not can then
        Counter("skipCannot")
        After(0.1, NextStep)
        return
    end
    local okNotify, errNotify = pcall(NotifyInspect, unit)
    if not okNotify then
        Counter("notifyError")
        Err("inspectNotify", errNotify)
        After(0.1, NextStep)
        return
    end
    sentThisSession = sentThisSession + 1
    Counter("sent")
    -- a token, not a field of `pending`: the timeout closure must recognise ITS
    -- OWN request. Comparing fields instead would let a newer request (same
    -- player re-queued) satisfy the old timer and eat its answer.
    token = token + 1
    pending = { guid = item.guid, key = item.key, unit = unit, at = time(), token = token }

    -- silence is a finding: a missing INSPECT_READY is a timeout, not "empty"
    local myToken = token
    After(TIMEOUT, function()
        if not pending or pending.token ~= myToken then return end
        pending = nil
        Counter("timeout")
        After(GAP_MIN + math.random() * (GAP_MAX - GAP_MIN), NextStep)
    end)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- reading the answer
-- ─────────────────────────────────────────────────────────────────────────────

function J.OnInspectReady(guid)
    if not pending then return end
    local p = pending
    pending = nil
    -- the GUID separates OUR answer from any other inspect that happens to
    -- finish meanwhile (another addon, or the player opening the window)
    if type(guid) == "string" and p.guid and guid ~= p.guid then
        Counter("staleEvent")
        After(GAP_MIN + math.random() * (GAP_MAX - GAP_MIN), NextStep)
        return
    end
    local ok, err = pcall(function()
        -- Resolve the player by GUID: the token we asked about is often
        -- reassigned during the ~1 s the server takes. Reading the token blindly
        -- attached one player's gear to another (that is what skipChanged=78 in
        -- the 19.11.2026 field run was), so the GUID decides, not the token.
        local unit = p.unit
        local okG, curGuid = pcall(UnitGUID, unit)
        if not okG or curGuid ~= p.guid then
            unit = FindUnit(p.guid)
            if not unit then
                Counter("lostAfterEvent")
                return
            end
            Counter("relocatedOnRead")
        end
        local slotMap, count = SlotMap(unit)
        if count == 0 then
            Counter("emptySlots")
            return
        end
        local snapshot = {
            at = time(),
            ids = slotMap,
            slots = count,
        }
        local pd = rawget(_G, "C_PaperDollInfo")
        if pd and type(pd.GetInspectItemLevel) == "function" then
            local okI, ilvl = pcall(pd.GetInspectItemLevel, unit)
            if okI and type(ilvl) == "number" and ilvl > 0 then snapshot.ilvl = ilvl end
        end
        local ct = rawget(_G, "C_Traits")
        if ct and type(ct.GenerateInspectImportString) == "function" then
            local okS, imp = pcall(ct.GenerateInspectImportString, unit)
            if okS and type(imp) == "string" and imp ~= "" then
                -- a secret string must not reach SV or a string operation
                if not (canaccessvalue and not canaccessvalue(imp)) then
                    snapshot.imp = imp:sub(1, 120)
                end
            end
        end
        if Store(p.key, snapshot) then
            Counter("ok")
            -- Отдать снапшот в peer-канал (экипировка + билд). Функция приходит
            -- из NearbySpy.lua инъекцией: этот файл не знает ни очередей, ни
            -- протокола, и при выключенном обмене её просто нет.
            if J.QueuePeerGear then pcall(J.QueuePeerGear, p.key, snapshot) end
        else
            Counter("noRecord")
        end
    end)
    if not ok then Err("inspectRead", err) end
    After(GAP_MIN + math.random() * (GAP_MAX - GAP_MIN), NextStep)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- reporting (/nspy gear)
-- ─────────────────────────────────────────────────────────────────────────────

function J.Report()
    local db = J.DB()
    local c = (db and db.debug and db.debug.inspectQueue) or {}
    local stored = 0
    if db and type(db.gearRing) == "table" then stored = #db.gearRing end
    local withImp = 0
    if db and type(db.players) == "table" then
        for _, e in pairs(db.players) do
            if type(e) == "table" and type(e.gear) == "table" and e.gear.imp then
                withImp = withImp + 1
            end
        end
    end
    J.Say(("gear: %s, queued=%d, in flight=%s, sent this session=%d/%d, snapshots=%d (with build: %d)")
        :format(J.Enabled() and "on" or "off", #queue,
            pending and ("yes (" .. tostring(pending.key) .. ")") or "no",
            sentThisSession, MAX_PER_SESSION, stored, withImp))
    J.Say(("gear counters: queued=%d sent=%d ok=%d empty=%d timeout=%d cannot=%d gone=%d relocated=%d lostAfterEvent=%d expired=%d cooldown=%d full=%d stale=%d")
        :format(c.queued or 0, c.sent or 0, c.ok or 0, c.emptySlots or 0, c.timeout or 0,
            c.skipCannot or 0, c.skipGone or 0,
            (c.relocated or 0) + (c.relocatedOnRead or 0), c.lostAfterEvent or 0,
            c.expired or 0, c.skipCooldown or 0, c.droppedFull or 0, c.staleEvent or 0))
    -- The number that matters: how many answers turned into a stored snapshot.
    -- A low ratio means the queue is chasing players who are already gone.
    if (c.sent or 0) > 0 then
        J.Say(("gear efficiency (this session): %d of %d requests stored (%.0f%%)")
            :format(c.ok or 0, c.sent or 0, 100 * (c.ok or 0) / (c.sent or 1)))
    end
    local t = (db and db.debug and db.debug.inspectTotal) or {}
    if (t.sent or 0) > 0 then
        J.Say(("gear totals (all sessions): stored=%d sent=%d")
            :format(t.ok or 0, t.sent or 0))
    end
end

function J.Toggle(on)
    local db = J.DB()
    if not db then return end
    if on == nil then on = db.gearOff and true or false end
    db.gearOff = (not on) or nil
    J.Say("gear: " .. (J.Enabled() and "on" or "off"))
end

function J.Counters()
    local db = J.DB()
    return (db and db.debug and db.debug.inspectQueue) or {}, sentThisSession
end

-- ─────────────────────────────────────────────────────────────────────────────
-- events
-- ─────────────────────────────────────────────────────────────────────────────

if CreateFrame then
    local f = CreateFrame("Frame")
    f:RegisterEvent("INSPECT_READY")
    f:SetScript("OnEvent", function(_, event, arg1)
        if event ~= "INSPECT_READY" then return end
        local ok, err = pcall(J.OnInspectReady, arg1)
        if not ok then Err("inspectEvent", err) end
    end)
end

return J
