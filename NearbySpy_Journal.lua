-- NearbySpy_Journal.lua
-- Per-character activity journal (1.6.0, 16.11.2026): how long this character
-- played, where, whom it met and how it progressed. The data lives in the
-- SavedVariables table the addon already writes, so the site receives it with
-- the same file it already accepts — the addon itself has no HTTP and never
-- will (see the world-data reference: SavedVariables is the only transport).
--
-- WHY A SEPARATE FILE: the main chunk of NearbySpy.lua sits at the Lua 5.1
-- ceiling of 200 top-level locals (194 at 1.6.0, measured by
-- scripts/count_locals.py). Both the journal state helpers and the reporters
-- would need a dozen more. So the journal is its own chunk behind the global
-- NSP_JOURNAL, and NearbySpy.lua injects what it needs:
--
--   NSP_JOURNAL.P  -- the addon's P() (chat + SavedVariables ring)
--   NSP_JOURNAL.L  -- the addon's L() (UI locale lookup, key from LOCALE table)
--
-- NOTHING HERE touches addon locals: zone, level, class and unit data come in
-- as arguments, and the client API used is only the plain one (UnitName,
-- UnitLevel, GetRealmName, GetMoney, UnitXP...). That keeps the chunk runnable
-- in a bare Lua 5.1 runtime, which is how tests/test_journal.py exercises it.
--
-- SAVEDVARIABLES SCHEMA (v1, short keys on purpose — the file is a budget):
--   db.journal = {
--     v  = 1,
--     at = <last write ts>,
--     c  = { [charKey] = char },              -- per character, max 12
--     s  = { session, ... },                  -- ring of 40 finished sessions
--     d  = { ["YYYY-MM-DD"] = day, ... },     -- rollups, last 30 days
--     o  = openSession or nil,                -- current session
--   }
--   char    = { n=name, r=realm, g=game, cl=class, f=firstSeen, l=lastSeen,
--               s=sec, ss=sessions, e=encounters, nw=newPlayers, lv=level,
--               lv0=firstLevel, xp=<percent in level>, mo=money, dth=deaths,
--               lu=levelUps, z={ [zoneKey] = zone } }
--   zone    = { n=name, s=sec, v=visits, last=ts }
--   session = { a=start, b=end, s=sec, c=charKey, l0=levelStart, l1=levelEnd,
--               x0=xpStart, x1=xpEnd, z=zonesVisited, zn=mainZone, e=encounters,
--               n=newPlayers, d=deaths, m0=moneyStart, m1=moneyEnd, tr=1 }
--   day     = { s=sec, e=encounters, n=newPlayers, z={ [zoneKey] = zone } }
--   open    = { a=start, b=lastBeat, c=charKey, z=zoneKey, zn=zoneName,
--               zt=zoneEnteredAt, zs={ [zoneKey] = zone }, k={ [playerKey]=1 },
--               e=, n=, d=, l0=, x0=, m0= }
--
-- Counters are monotonic per character; sessions and days are bounded rings,
-- so the journal can never grow the SavedVariables file without limit.

local J = {}
NSP_JOURNAL = J

J.SCHEMA = 1

local SESS_KEEP   = 40   -- finished sessions kept
local DAYS_KEEP   = 30   -- day rollups kept
local CHARS_KEEP  = 12   -- characters kept (oldest pruned by lastSeen)
local ZONES_CHAR  = 25   -- zones kept per character
local ZONES_DAY   = 8    -- zones kept per day
local ENC_KEYS    = 400  -- distinct player keys tracked per session

-- Lua 5.1: tonumber(nil) RAISES, so every client value goes through this
-- guard. Same rule as the rest of the addon (references/lua-code-verification).
local function Num(v)
    if v == nil then return nil end
    return tonumber(v)
end

local function Count(t)
    if type(t) ~= "table" then return 0 end
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local function EnsureJournal(db)
    if type(db) ~= "table" then return nil end
    local j = db.journal
    if type(j) ~= "table" then
        j = {}
        db.journal = j
    end
    if type(j.c) ~= "table" then j.c = {} end
    if type(j.s) ~= "table" then j.s = {} end
    if type(j.d) ~= "table" then j.d = {} end
    j.v = J.SCHEMA
    return j
end

local function DayKey(ts)
    return date("%Y-%m-%d", ts or time())
end

local function DayRow(j, ts)
    local key = DayKey(ts)
    local d = j.d
    if type(d[key]) ~= "table" then
        d[key] = { s = 0, e = 0, n = 0, z = {} }
    end
    local row = d[key]
    if type(row.z) ~= "table" then row.z = {} end
    return row
end

-- Zone key: the numeric uiMapID when we have one (it is locale independent and
-- is what the site's heatmap uses), otherwise the localized name. Both forms
-- are plain Lua keys, so the SV writer and the tolerant parser handle them.
local function ZoneKey(zoneId, zoneName)
    local id = Num(zoneId)
    if id and id > 0 then return id end
    if type(zoneName) == "string" and zoneName ~= "" then return "n:" .. zoneName end
    return nil
end

-- Seconds in a zone and the number of VISITS are different things: heartbeats
-- add time every minute, but a visit is only the moment the player entered the
-- zone. Mixing them made a one-hour stay look like 60 visits.
local function ZoneEntry(list, key, name, now)
    if type(list) ~= "table" or key == nil then return nil end
    local z = list[key]
    if type(z) ~= "table" then
        z = { n = name or "?", s = 0, v = 0 }
        list[key] = z
    end
    if (z.n == nil or z.n == "?") and name then z.n = name end
    return z
end

local function AddZoneTime(list, key, name, sec, now)
    local z = ZoneEntry(list, key, name, now)
    if not z then return end
    z.s = (z.s or 0) + sec
    z.last = now
end

local function CountVisit(list, key, name, now)
    local z = ZoneEntry(list, key, name, now)
    if not z then return end
    z.v = (z.v or 0) + 1
    z.last = now
end

-- Kept for the settle paths that add time and (on first touch) a visit at once.
local function BumpZone(list, key, name, sec, now)
    AddZoneTime(list, key, name, sec, now)
end

-- Keep the N busiest zones, drop the rest: an adventurer visits dozens of
-- zones per character and the SV file is a hard budget.
local function PruneZones(list, keep)
    if type(list) ~= "table" then return end
    local keys = {}
    for k in pairs(list) do keys[#keys + 1] = k end
    if #keys <= keep then return end
    table.sort(keys, function(a, b)
        return (list[a] and list[a].s or 0) > (list[b] and list[b].s or 0)
    end)
    for i = keep + 1, #keys do list[keys[i]] = nil end
end

local function PruneDays(j)
    local keys = {}
    for k in pairs(j.d) do keys[#keys + 1] = k end
    if #keys <= DAYS_KEEP then return end
    table.sort(keys)                      -- "YYYY-MM-DD" sorts chronologically
    for i = 1, #keys - DAYS_KEEP do j.d[keys[i]] = nil end
end

local function PruneChars(j)
    local keys = {}
    for k in pairs(j.c) do keys[#keys + 1] = k end
    if #keys <= CHARS_KEEP then return end
    table.sort(keys, function(a, b)
        return (j.c[a] and j.c[a].l or 0) > (j.c[b] and j.c[b].l or 0)
    end)
    for i = CHARS_KEEP + 1, #keys do j.c[keys[i]] = nil end
end

local function ClassFileName()
    local ok, file = pcall(UnitClass, "player")
    if not ok then return nil end
    return file
end

local function ClassDisplay()
    local file = ClassFileName()
    local t = LOCALIZED_CLASS_NAMES_MALE
    local loc = (t and file) and t[file] or nil
    return loc or file
end

-- Identity of the character being played.
-- Camelot allows two-word names and the client returns the SURNAME in
-- UnitName's second slot ("Randaz", "Windlance"), so the real realm comes only
-- from GetRealmName(); the display name is name .. " " .. surname. The key uses
-- exactly the same shape as the player records (name .. "-" .. realm), so the
-- journal and the encounter list speak one language.
local function Identity()
    local ok, name, tail = pcall(UnitName, "player")
    if not ok or type(name) ~= "string" or name == "" then return nil end
    local okR, realm = pcall(GetRealmName)
    if not okR or type(realm) ~= "string" or realm == "" then realm = "?" end
    local display = name
    if type(tail) == "string" and tail ~= "" and tail ~= realm then
        display = name .. " " .. tail
    end
    return display .. "-" .. realm, display, realm
end

local function XpPercent()
    local okC, cur = pcall(UnitXP, "player")
    if not okC then return nil end
    local okM, mx = pcall(UnitXPMax, "player")
    if not okM then return nil end
    cur, mx = Num(cur), Num(mx)
    if not cur or not mx or mx <= 0 then return nil end
    return math.floor(cur / mx * 100 + 0.5)
end

local function Money()
    local ok, v = pcall(GetMoney)
    if not ok then return nil end
    return Num(v)
end

-- Called at the end of PLAYER_LOGIN and on every heartbeat: refreshes the
-- character card from the client (level, xp, money, class, game tag).
local function RefreshChar(db, ch)
    if type(ch) ~= "table" then return end
    local okL, lvl = pcall(UnitLevel, "player")
    if okL then ch.lv = Num(lvl) or ch.lv end
    if not ch.lv0 then ch.lv0 = ch.lv end
    ch.cl = ch.cl or ClassDisplay()
    ch.g = ch.g or db.game
    local xp = XpPercent()
    if xp then ch.xp = xp end
    local mo = Money()
    if mo then ch.mo = mo end
end

--------------------------------------------------------------------------------
-- session lifecycle
--------------------------------------------------------------------------------

-- Settle the open session into the ring and the day rollup.
--   endAt     -- when the session ended (heartbeat time for a crashed session)
--   truncated -- true when the session was closed by the NEXT login, i.e. the
--                client died or was killed: the record says so instead of
--                pretending the player stayed until the next login
local function Settle(db, endAt, truncated)
    local j = EnsureJournal(db)
    if not j then return false end
    local o = j.o
    if type(o) ~= "table" or not o.a then return false end
    endAt = endAt or time()
    if endAt < o.a then endAt = o.a end
    local ch = j.c[o.c]

    -- Zone time is accounted from the last zone tick to endAt. This is the only
    -- place playtime is accumulated, so a crash cannot double count: the next
    -- login settles the old session at its LAST HEARTBEAT, not at "now".
    local delta = endAt - (o.zt or endAt)
    if delta > 0 and o.z ~= nil then
        if type(ch) == "table" then BumpZone(ch.z, o.z, o.zn, delta, endAt) end
        local day = DayRow(j, endAt)
        BumpZone(day.z, o.z, o.zn, delta, endAt)
        day.s = (day.s or 0) + delta
    end
    o.zt = endAt

    local sec = endAt - o.a

    -- main zone of the session: the one we spent the most time in
    local mainZone, mainSec = nil, -1
    local zonesVisited = 0
    for _, z in pairs(type(o.zs) == "table" and o.zs or {}) do
        zonesVisited = zonesVisited + 1
        if (z.s or 0) > mainSec then mainSec = z.s or 0; mainZone = z.n end
    end

    local rec = {
        a = o.a, b = endAt, s = sec, c = o.c,
        l0 = o.l0, l1 = (type(ch) == "table") and ch.lv or nil,
        x0 = o.x0, x1 = (type(ch) == "table") and ch.xp or nil,
        z = zonesVisited, zn = mainZone,
        e = o.e or 0, n = o.n or 0, d = o.d or 0,
        m0 = o.m0, m1 = (type(ch) == "table") and ch.mo or nil,
    }
    if truncated then rec.tr = 1 end
    j.s[#j.s + 1] = rec
    while #j.s > SESS_KEEP do table.remove(j.s, 1) end

    if type(ch) == "table" then
        ch.s = (ch.s or 0) + sec
        ch.ss = (ch.ss or 0) + 1
        ch.e = (ch.e or 0) + (o.e or 0)
        ch.nw = (ch.nw or 0) + (o.n or 0)
        ch.dth = (ch.dth or 0) + (o.d or 0)
        ch.l = endAt
        PruneZones(ch.z, ZONES_CHAR)
    end
    for _, row in pairs(j.d) do PruneZones(row.z, ZONES_DAY) end
    PruneDays(j)
    j.o = nil
    j.at = endAt
    return true
end

-- PLAYER_LOGIN: close a session left open by a crash, then start a new one.
function J.Login(db, zoneName, zoneId)
    local j = EnsureJournal(db)
    if not j then return false end
    local key, display, realm = Identity()
    if not key then return false end
    local now = time()
    -- A session is still open: the client was killed (SV was written by /reload
    -- or by the previous login, never by the logout handler). Close it at its
    -- last heartbeat and mark it truncated — better an honest short session
    -- than playtime counted up to the next login.
    if type(j.o) == "table" and j.o.a then
        Settle(db, j.o.b or j.o.a, true)
    end

    local ch = j.c[key]
    if type(ch) ~= "table" then
        ch = { n = display, r = realm, f = now, z = {} }
        j.c[key] = ch
    end
    ch.n, ch.r = display or ch.n, realm or ch.r
    ch.l = now
    ch.lu = ch.lu or 0
    RefreshChar(db, ch)

    local zkey = ZoneKey(zoneId, zoneName)
    j.o = {
        a = now, b = now, c = key,
        z = zkey, zn = zoneName, zt = now,
        zs = {}, k = {},
        e = 0, n = 0, d = 0,
        l0 = ch.lv, x0 = ch.xp, m0 = ch.mo,
    }
    if zkey ~= nil then
        CountVisit(j.o.zs, zkey, zoneName, now)
        CountVisit(ch.z, zkey, zoneName, now)
    end
    PruneChars(j)
    j.at = now
    return true
end

-- ZONE_CHANGED_NEW_AREA (or a heartbeat that notices a different zone).
function J.Zone(db, zoneName, zoneId)
    local j = EnsureJournal(db)
    if not j then return false end
    local o = j.o
    if type(o) ~= "table" or not o.a then return false end
    local now = time()
    local ch = j.c[o.c]
    local newKey = ZoneKey(zoneId, zoneName)
    if newKey == nil then return false end
    if newKey == o.z then
        -- same zone, only the clock moves
        local delta = now - (o.zt or now)
        if delta > 0 then
            BumpZone(o.zs, o.z, o.zn, delta, now)
            if type(ch) == "table" then BumpZone(ch.z, o.z, o.zn, delta, now) end
            local day = DayRow(j, now)
            BumpZone(day.z, o.z, o.zn, delta, now)
            day.s = (day.s or 0) + delta
        end
        o.zt = now
        return true
    end
    -- settle the zone we are leaving
    local delta = now - (o.zt or now)
    if delta > 0 and o.z ~= nil then
        BumpZone(o.zs, o.z, o.zn, delta, now)
        if type(ch) == "table" then BumpZone(ch.z, o.z, o.zn, delta, now) end
        local day = DayRow(j, now)
        BumpZone(day.z, o.z, o.zn, delta, now)
        day.s = (day.s or 0) + delta
    end
    o.z, o.zn, o.zt = newKey, zoneName, now
    if type(o.zs) ~= "table" then o.zs = {} end
    CountVisit(o.zs, newKey, zoneName, now)
    if type(ch) == "table" then CountVisit(ch.z, newKey, zoneName, now) end
    return true
end

-- Heartbeat (every 60 s from ScheduleTick): keeps playtime honest when the
-- client dies without firing PLAYER_LOGOUT, and refreshes level/xp/money.
function J.Beat(db, zoneName, zoneId)
    local j = EnsureJournal(db)
    if not j then return false end
    local o = j.o
    if type(o) ~= "table" or not o.a then return false end
    -- A zone change can be missed (loading screen zones, /who jumps): compare
    -- and settle instead of logging the new zone under the old key.
    local curKey = ZoneKey(zoneId, zoneName)
    if curKey ~= nil and curKey ~= o.z then
        J.Zone(db, zoneName, zoneId)
    else
        local now = time()
        local delta = now - (o.zt or now)
        if delta > 0 and o.z ~= nil then
            BumpZone(o.zs, o.z, o.zn, delta, now)
            local ch = j.c[o.c]
            if type(ch) == "table" then BumpZone(ch.z, o.z, o.zn, delta, now) end
            local day = DayRow(j, now)
            BumpZone(day.z, o.z, o.zn, delta, now)
            day.s = (day.s or 0) + delta
        end
        o.zt = now
    end
    local ch = j.c[o.c]
    RefreshChar(db, ch)
    o.b = time()
    j.at = o.b
    return true
end

-- PLAYER_LOGOUT (fires on /reload too — the SavedVariables write follows it).
function J.Logout(db)
    local j = EnsureJournal(db)
    if not j then return false end
    local o = j.o
    if type(o) ~= "table" or not o.a then return false end
    local ch = j.c[o.c]
    RefreshChar(db, ch)
    return Settle(db, time(), false)
end

function J.LevelUp(db, level)
    local j = EnsureJournal(db)
    if not j then return false end
    local o = j.o
    local ch = type(o) == "table" and j.c[o.c] or nil
    local lvl = Num(level)
    if type(ch) ~= "table" then return false end
    ch.lu = (ch.lu or 0) + 1
    if lvl then ch.lv = lvl end
    ch.xp = 0
    if type(o) == "table" then o.x0 = o.x0 or 0 end
    return true
end

function J.Died(db)
    local j = EnsureJournal(db)
    if not j then return false end
    local o = j.o
    if type(o) ~= "table" or not o.a then return false end
    o.d = (o.d or 0) + 1
    return true
end

-- A player seen with our own eyes (never a peer packet: someone else reporting
-- an encounter is not our meeting). `isNew` marks a record new to the database.
function J.Encounter(db, key, isNew)
    local j = EnsureJournal(db)
    if not j then return false end
    local o = j.o
    if type(o) ~= "table" or not o.a then return false end
    if type(key) ~= "string" or key == "" then return false end
    if type(o.k) ~= "table" then o.k = {} end
    local seen = o.k
    local known = seen[key] ~= nil
    if not known and Count(seen) < ENC_KEYS then seen[key] = 1 end
    if not known then
        o.e = (o.e or 0) + 1
        -- "new to the database" is counted once per player, exactly like the
        -- sightings: a caller that repeats isNew for a player already met in
        -- this session must not inflate the number.
        if isNew then o.n = (o.n or 0) + 1 end
    end
    local day = DayRow(j, time())
    if not known then
        day.e = (day.e or 0) + 1
        if isNew then day.n = (day.n or 0) + 1 end
    end
    return true
end

--------------------------------------------------------------------------------
-- reporting
--------------------------------------------------------------------------------

function J.Dur(sec)
    local s = math.floor(Num(sec) or 0)
    if s < 0 then s = 0 end
    if s < 60 then return ("%ds"):format(s) end
    local m = math.floor(s / 60)
    if m < 60 then return ("%dm"):format(m) end
    local h = math.floor(m / 60)
    return ("%dh %02dm"):format(h, m % 60)
end

function J.MoneyText(copper)
    local c = math.floor(Num(copper) or 0)
    if c < 0 then c = 0 end
    return ("%dg %ds %dc"):format(math.floor(c / 10000),
        math.floor((c % 10000) / 100), c % 100)
end

local function Text(key, ...)
    local f = J.L
    local s = (type(f) == "function") and f(key) or key
    if select("#", ...) == 0 then return s end
    local ok, out = pcall(string.format, s, ...)
    if ok then return out end
    return s
end

-- Seconds played on a given date (day rollup) and over the last N days.
local function DaySeconds(db, dayKey)
    local j = db and db.journal
    local row = j and j.d and j.d[dayKey]
    return (type(row) == "table" and Num(row.s)) or 0
end

local function WeekSeconds(db)
    local j = db and db.journal
    if not (j and type(j.d) == "table") then return 0 end
    local now = time()
    local total = 0
    for i = 0, 6 do
        local ts = now - i * 86400
        total = total + DaySeconds(db, DayKey(ts))
    end
    return total
end

local function TopZones(ch, limit)
    if type(ch) ~= "table" or type(ch.z) ~= "table" then return nil end
    local rows = {}
    for _, z in pairs(ch.z) do
        if type(z) == "table" and (z.s or 0) > 0 then rows[#rows + 1] = z end
    end
    table.sort(rows, function(a, b) return (a.s or 0) > (b.s or 0) end)
    local parts = {}
    for i = 1, math.min(limit or 5, #rows) do
        local z = rows[i]
        parts[#parts + 1] = ("%s %s"):format(tostring(z.n or "?"), J.Dur(z.s))
    end
    if #parts == 0 then return nil end
    return table.concat(parts, ", ")
end

-- Lines for the chat (and the SV ring through P). Returns a table of strings so
-- tests can assert on the numbers without parsing chat output.
function J.Lines(db)
    local lines = {}
    local j = db and db.journal
    if type(j) ~= "table" or type(j.c) ~= "table" then
        lines[#lines + 1] = Text("ME_NONE")
        return lines
    end
    local key = nil
    local _, display, realm = Identity()
    if display then key = display .. "-" .. (realm or "?") end
    local ch = key and j.c[key] or nil
    if type(ch) ~= "table" then
        -- Not the character playing now? Show the most recently played one.
        local best
        for _, v in pairs(j.c) do
            if type(v) == "table" and (not best or (v.l or 0) > (best.l or 0)) then best = v end
        end
        ch = best
    end
    if type(ch) ~= "table" then
        lines[#lines + 1] = Text("ME_NONE")
        return lines
    end

    local lvl = Num(ch.lv) or 0
    local xp = Num(ch.xp)
    local lvlText = xp and ("lvl %d, %d%% xp"):format(lvl, xp) or ("lvl %d"):format(lvl)
    lines[#lines + 1] = Text("ME_TITLE", tostring(ch.n or "?"),
        tostring(ch.cl or "?"), lvlText)

    -- The running session is not in the character totals yet (they settle at
    -- logout): count it here, otherwise a fresh install reports "0s" until the
    -- first /reload.
    local o = j.o
    local sessionSec = 0
    if type(o) == "table" and o.a then
        sessionSec = (o.b or time()) - o.a
        if sessionSec < 0 then sessionSec = 0 end
    end

    local first = Num(ch.f)
    lines[#lines + 1] = Text("ME_TIME", J.Dur((Num(ch.s) or 0) + sessionSec),
        Num(ch.ss) or 0, first and date("%Y-%m-%d", first) or "?")
    lines[#lines + 1] = Text("ME_NOW", J.Dur(sessionSec),
        J.Dur(DaySeconds(db, DayKey())), J.Dur(WeekSeconds(db)))

    -- Same rule for the encounter totals: the running session is added on top
    -- of the settled ones, so the numbers match what the player just did.
    local oEnc = (type(o) == "table" and (o.e or 0)) or 0
    local oNew = (type(o) == "table" and (o.n or 0)) or 0
    lines[#lines + 1] = Text("ME_ENC", oEnc,
        (Num(ch.e) or 0) + oEnc, (Num(ch.nw) or 0) + oNew)

    local top = TopZones(ch, 5)
    if top then lines[#lines + 1] = Text("ME_ZONES", top) end
    lines[#lines + 1] = Text("ME_PROG", lvl, xp or 0, Num(ch.dth) or 0,
        J.MoneyText(ch.mo))

    -- session vs character money: only the session delta is interesting
    if type(o) == "table" and o.m0 and ch.mo then
        local delta = ch.mo - o.m0
        if delta ~= 0 then
            lines[#lines + 1] = Text("ME_MONEY_SESSION",
                (delta >= 0 and "+" or "-") .. J.MoneyText(math.abs(delta)))
        end
    end
    return lines
end

-- Print the journal to chat (and the SV ring). Called by /nspy me.
function J.Report(db)
    local lines = J.Lines(db)
    local P = J.P
    for _, line in ipairs(lines) do
        if type(P) == "function" then
            P(line)
        else
            print(line)
        end
    end
    return lines
end

return J
