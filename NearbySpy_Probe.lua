-- NearbySpy_Probe.lua
-- Diagnostic probe: /nspy inspecttest — can this client show another player's
-- GEAR and their TALENTS?
--
-- Measured, never guessed. Three independent things are recorded per unit:
--
--   1) GEAR — the inspect pipeline
--        CanInspect → NotifyInspect → INSPECT_READY → GetInventoryItemLink/ID
--      The client's own code warns that the server DROPS inspect data when
--      requests are flooded, so units are processed strictly one at a time.
--      Item LINKS are recorded separately from item IDs: a link only resolves
--      when the client already caches that item, so links < ids is normal and
--      means "store the ID, resolve lazily" (C_Item.RequestLoadItemData).
--
--   2) TALENTS — every candidate route, each with its own outcome:
--        C_Traits.GenerateInspectImportString(unit)  — the client's own
--          "copy inspect loadout"; a non-empty string is a complete build
--        C_Traits.HasValidInspectData()              — takes NO arguments; it
--          reports the state of the CURRENT inspect target
--        C_SpecializationInfo.GetTalentInfo(query)    — TABLE argument, not
--          positional (the client throws "Usage: ... GetTalentInfo(query)")
--      To prove the import string belongs to the TARGET and not to us, the
--      player's own string is recorded next to it for comparison.
--
--   3) NATIVE UI — whether the client can just open the target's own talent
--      window: global InspectUnit(unit) plus
--      PlayerSpellsUtil.OpenToClassTalentsTab(unit). Mode "ui" actually calls
--      them, so the answer can be seen on screen instead of inferred.
--
-- Output: a short chat summary, and the FULL matrix in SavedVariables
-- (NearbySpy.debug.inspect) — SavedVariables are written on logout, so the
-- matrix is read from the SV file afterwards. `debug.players` is a bounded
-- ring of the last MAX_PLAYERS probed units, which keeps several players
-- comparable across runs (a run on its own replaces only `lastRun`).
-- Technical lines stay English on purpose: support reads them without knowing
-- the client locale.
--
-- WHY A SEPARATE FILE: NearbySpy.lua sits at the Lua 5.1 ceiling of 200
-- top-level locals (see references/lua5-locals-limit.md), so the probe lives
-- behind the global NSP_PROBE and NearbySpy.lua injects into it:
--
--   NSP_PROBE.P      -- the addon's P() (chat + SavedVariables ring)
--   NSP_PROBE.GetDB  -- the addon's GetDB() (SavedVariables accessor)

NSP_PROBE = NSP_PROBE or {}
local J = NSP_PROBE

local SLOT_FIRST, SLOT_LAST = 1, 19
local DEFAULT_GAP = 2          -- seconds between NotifyInspect calls
local DEFAULT_TIMEOUT = 6      -- seconds to wait for INSPECT_READY
local DEFAULT_MAX_UNITS = 4
local MAX_UNITS = 10
local MAX_NAMEPLATES = 40
local MAX_PLAYERS = 8          -- SV ring: how many players stay comparable
local TIER_MAX, COLUMN_MAX = 9, 4

-- What a build may or may not have. "The function is absent" is a claim that
-- needs the whole list, so every candidate the probe knows about is listed
-- here and the snapshot records present/absent for each — a path missing from
-- the recorded table means "not asked", never "absent".
local API_GLOBALS = {
    "CanInspect", "NotifyInspect", "ClearInspectPlayer", "InspectUnit",
    "GetInventoryItemLink", "GetInventoryItemID", "GetInventoryItemTexture",
    "GetItemInfo", "GetItemStats", "UnitGUID",
    "GetNumTalentTabs", "GetTalentTabInfo", "GetTalentInfo",
    "GetInspectSpecialization", "GetTalentPreviewPanes",
}
local API_NAMESPACED = {
    "C_PaperDollInfo.GetInspectItemLevel",
    "C_PaperDollInfo.GetInspectGuildInfo",
    "C_SpecializationInfo.GetInspectSpecialization",
    "C_SpecializationInfo.GetInspectSelectedPvpTalent",
    "C_SpecializationInfo.GetTalentInfo",
    "C_SpecializationInfo.GetSpecializationInfo",
    "C_Traits.HasValidInspectData",
    "C_Traits.GenerateInspectImportString",
    "C_Traits.GenerateImportString",
    "C_Traits.GetConfigsByType",
    "C_Traits.GetNodeInfo",
    "C_ClassTalents.GetActiveConfigID",
    "C_ClassTalents.GetConfigIDsBySpecID",
    "C_Item.GetItemInfo",
    "C_Item.GetItemStats",
    "PlayerSpellsUtil.OpenToClassTalentsTab",
}

local S = nil      -- active run: { queue, i, opts, results, api, ... }
local Step         -- forward: J.Run and the timers below call it

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

-- "C_Traits.HasValidInspectData" → the value, or nil when the path breaks
local function Resolve(path)
    local cur = _G
    for part in tostring(path):gmatch("[^%.]+") do
        if type(cur) ~= "table" then return nil end
        cur = cur[part]
        if cur == nil then return nil end
    end
    return cur
end

-- One value, shortened for SavedVariables. Secret strings (the client marks
-- combat-log-like values secret) must be gated BEFORE any string operation —
-- even `v == ""` counts as one and raises.
local function Preview(v)
    local t = type(v)
    if t == "string" then
        if canaccessvalue and not canaccessvalue(v) then return "<secret>" end
        return (v:gsub("[\r\n]+", " ")):sub(1, 70)
    elseif t == "number" or t == "boolean" then
        return tostring(v)
    elseif t == "table" then
        -- a talent info table is the interesting case: keep the fields that
        -- carry meaning instead of a bare "table(12)"
        local keys = { "name", "tier", "column", "ranks", "maxRanks",
                       "currentRank", "maxRank", "selected", "isSelected" }
        local parts = {}
        for _, k in ipairs(keys) do
            local ok, val = pcall(function() return v[k] end)
            if ok and val ~= nil and type(val) ~= "table" then
                parts[#parts + 1] = k .. "=" .. Preview(val)
            end
        end
        if #parts > 0 then return "{" .. table.concat(parts, ",") .. "}" end
        local n = 0
        for _ in pairs(v) do n = n + 1 end
        return ("table(%d)"):format(n)
    end
    return "<" .. t .. ">"
end

-- A call whose OUTCOME is the data. Three outcomes must stay distinguishable:
-- the function is absent, the function throws, the function answers.
-- ⚠️ `{ pcall(fn, ...) }` shifts every return by one: r[2] is the FIRST return.
function J.Try(label, fn, ...)
    local rec = { f = label }
    if type(fn) ~= "function" then
        rec.err = "absent (" .. type(fn) .. ")"
        return rec
    end
    local r = { pcall(fn, ...) }
    if not r[1] then
        rec.err = tostring(r[2]):sub(1, 90)
        return rec
    end
    rec.n = #r - 1
    local out = {}
    for i = 2, math.min(#r, 5) do out[#out + 1] = Preview(r[i]) end
    rec.v = table.concat(out, "|")
    return rec
end

-- ─────────────────────────────────────────────────────────────────────────────
-- argument parsing (pure — covered by tests/test_inspect_probe.py)
-- ─────────────────────────────────────────────────────────────────────────────

--   /nspy inspecttest                 target + mouseover + focus
--   /nspy inspecttest all             the above + nameplates + party
--   /nspy inspecttest nm              nameplates only
--   /nspy inspecttest party           target + mouseover + party1..4
--   /nspy inspecttest ui              target, then OPEN the native talent UI
--   /nspy inspecttest gap 3 max 6     pacing and cap, clamped in code
function J.ParseArgs(arg)
    local a = { mode = "unit", openUi = false, maxUnits = DEFAULT_MAX_UNITS,
                gap = DEFAULT_GAP, timeout = DEFAULT_TIMEOUT }
    local words = {}
    for w in tostring(arg or ""):lower():gmatch("%S+") do words[#words + 1] = w end
    local i = 1
    while i <= #words do
        local w = words[i]
        if w == "all" then
            a.mode = "all"
        elseif w == "nm" or w == "nameplates" then
            a.mode = "nm"
        elseif w == "party" then
            a.mode = "party"
        elseif w == "unit" or w == "target" then
            a.mode = "unit"
        elseif w == "ui" then
            a.openUi = true
            a.mode = "unit"
        elseif (w == "gap" or w == "max" or w == "timeout") and words[i + 1] then
            local n = tonumber(words[i + 1])
            if n then
                if w == "gap" then
                    a.gap = math.min(math.max(n, 1), 15)
                elseif w == "max" then
                    a.maxUnits = math.min(math.max(math.floor(n), 1), MAX_UNITS)
                else
                    a.timeout = math.min(math.max(n, 2), 20)
                end
            end
            i = i + 1
        end
        i = i + 1
    end
    return a
end

-- ─────────────────────────────────────────────────────────────────────────────
-- capability snapshot
-- ─────────────────────────────────────────────────────────────────────────────

function J.ApiSnapshot()
    local api, missing, present = {}, {}, 0
    local function add(path)
        local v = Resolve(path)
        api[path] = type(v)
        if v == nil then
            missing[#missing + 1] = path
        else
            present = present + 1
        end
    end
    for _, p in ipairs(API_GLOBALS) do add(p) end
    for _, p in ipairs(API_NAMESPACED) do add(p) end
    return api, missing, present
end

-- ─────────────────────────────────────────────────────────────────────────────
-- reading one inspected unit
-- ─────────────────────────────────────────────────────────────────────────────

function J.ReadItems(unit, rec)
    local r = { links = 0, ids = 0, sample = {} }
    for slot = SLOT_FIRST, SLOT_LAST do
        local okL, link = pcall(GetInventoryItemLink, unit, slot)
        if okL and type(link) == "string" and link ~= "" then
            r.links = r.links + 1
            if #r.sample < 3 then
                if canaccessvalue and not canaccessvalue(link) then
                    r.sample[#r.sample + 1] = slot .. "=<secret>"
                else
                    r.sample[#r.sample + 1] = slot .. "=" .. link:sub(1, 80)
                end
            end
        end
        local okI, id = pcall(GetInventoryItemID, unit, slot)
        if okI and type(id) == "number" and id > 0 then r.ids = r.ids + 1 end
    end
    r.sampleText = table.concat(r.sample, " ; ")
    r.sample = nil
    rec.items = r
    local pd = rawget(_G, "C_PaperDollInfo")
    rec.ilvl = J.Try("pd.GetInspectItemLevel", pd and pd.GetInspectItemLevel, unit)
end

-- The player's own build string: the reference point that proves the inspect
-- string belongs to the TARGET (for another player the two must differ).
function J.OwnImportString()
    local ct = rawget(_G, "C_Traits")
    local cc = rawget(_G, "C_ClassTalents")
    if type(ct) ~= "table" or type(ct.GenerateImportString) ~= "function" then return nil end
    if type(cc) ~= "table" or type(cc.GetActiveConfigID) ~= "function" then return nil end
    local okId, configID = pcall(cc.GetActiveConfigID)
    if not okId or type(configID) ~= "number" then return nil end
    local okS, str = pcall(ct.GenerateImportString, configID)
    if not okS or type(str) ~= "string" then return nil end
    if canaccessvalue and not canaccessvalue(str) then return "<secret>" end
    return str:sub(1, 70)
end

-- Talent tiers through the TABLE-argument API. The client throws
-- "Usage: local result = C_SpecializationInfo.GetTalentInfo(query)" on
-- positional calls, so the query table is the only shape worth probing; each
-- shape below is one that a Blizzard talent frame in this repo actually uses.
function J.ReadTalentGrid(unit, rec)
    local cs = rawget(_G, "C_SpecializationInfo")
    local fn = cs and cs.GetTalentInfo
    if type(fn) ~= "function" then
        rec.grid = { err = "C_SpecializationInfo.GetTalentInfo absent" }
        return
    end
    local found = {}
    for tier = 1, TIER_MAX do
        for column = 1, COLUMN_MAX do
            local shapes = {
                { "ml", { tier = tier, column = column, groupIndex = 1, isInspect = true, target = unit } },
                { "std", { tier = tier, column = column, specializationIndex = 1, isInspect = true, target = unit } },
                { "cat", { tier = tier, column = column, groupIndex = 1, isInspect = true, isPet = false } },
                { "spec", { specializationIndex = 1, talentIndex = (tier - 1) * COLUMN_MAX + column, isInspect = true, target = unit } },
            }
            for _, s in ipairs(shapes) do
                local ok, info = pcall(fn, s[2])
                if ok and type(info) == "table" then
                    local okN, name = pcall(function() return info.name end)
                    if okN and type(name) == "string" and name ~= ""
                        and (canaccessvalue == nil or canaccessvalue(name)) then
                        found[#found + 1] = ("%s %d/%d %s rank=%s/%s")
                            :format(s[1], tier, column, name,
                                tostring(info.ranks or info.currentRank or "?"),
                                tostring(info.maxRanks or info.maxRank or "?"))
                    end
                end
            end
        end
    end
    rec.grid = { hits = #found, first = found[1],
                 sample = table.concat(found, " ; "):sub(1, 240) }
end

-- Every talent route at once. A route that answers is the finding; a route that
-- throws keeps its error text, so "wrong signature" and "no data" stay apart.
function J.ReadTalents(unit, rec)
    local cs = rawget(_G, "C_SpecializationInfo")
    local ct = rawget(_G, "C_Traits")
    rec.talents = {
        -- the client's own "copy inspect loadout": a build string is the prize
        J.Try("traits.GenerateInspectImportString", ct and ct.GenerateInspectImportString, unit),
        -- no arguments: reports the state of the CURRENT inspect target
        J.Try("traits.HasValidInspectData()", ct and ct.HasValidInspectData),
        J.Try("spec.GetInspectSpecialization", cs and cs.GetInspectSpecialization, unit),
        J.Try("spec.GetSpecializationInfo(1,true)", cs and cs.GetSpecializationInfo, 1, true),
        J.Try("spec.GetInspectSelectedPvpTalent(1)", cs and cs.GetInspectSelectedPvpTalent, unit, 1),
        -- table-argument API, two documented field layouts
        J.Try("spec.GetTalentInfo{ml}", cs and cs.GetTalentInfo,
            { tier = 1, column = 1, groupIndex = 1, isInspect = true, target = unit }),
        J.Try("spec.GetTalentInfo{std}", cs and cs.GetTalentInfo,
            { tier = 1, column = 1, specializationIndex = 1, isInspect = true, target = unit }),
        -- legacy vanilla globals (deprecated, expected to be nil)
        J.Try("g.GetNumTalentTabs(true,unit)", rawget(_G, "GetNumTalentTabs"), true, unit),
        J.Try("g.GetTalentTabInfo(1,true,1,unit)", rawget(_G, "GetTalentTabInfo"), 1, true, 1, unit),
        J.Try("g.GetTalentInfo(1,1,true,1,unit)", rawget(_G, "GetTalentInfo"), 1, 1, true, 1, unit),
        J.Try("g.GetInspectSpecialization", rawget(_G, "GetInspectSpecialization"), unit),
    }
    rec.ownString = J.OwnImportString()
    J.ReadTalentGrid(unit, rec)
end

-- Mode "ui": the client's own path for looking at someone's talents — the same
-- two calls InspectPaperDollFrame makes (InspectUnit, then open the talent tab).
function J.OpenNative(unit, rec)
    local n = {}
    rec.native = n
    n.inspectUnit = J.Try("InspectUnit", rawget(_G, "InspectUnit"), unit)
    local psu = rawget(_G, "PlayerSpellsUtil")
    n.talentTab = J.Try("PlayerSpellsUtil.OpenToClassTalentsTab",
        psu and psu.OpenToClassTalentsTab, unit)
    local frame = rawget(_G, "PlayerSpellsFrame")
    n.frameLoaded = tostring(frame ~= nil)
    if type(frame) == "table" and frame.IsInspecting then
        local ok, insp = pcall(frame.IsInspecting, frame)
        n.isInspecting = ok and tostring(insp) or "err"
        if frame.GetInspectUnit then
            local ok2, u = pcall(frame.GetInspectUnit, frame)
            n.inspectUnitNow = ok2 and tostring(u) or "err"
        end
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- the run
-- ─────────────────────────────────────────────────────────────────────────────

local function After(seconds, fn)
    local timer = rawget(_G, "C_Timer")
    if timer and timer.After then
        timer.After(seconds, fn)
    else
        fn()
    end
end

local function BuildQueue(a)
    local q, seen = {}, {}
    local function add(unit)
        if #q >= a.maxUnits then return end
        if type(unit) ~= "string" or seen[unit] then return end
        if not UnitExists(unit) then return end
        seen[unit] = true
        q[#q + 1] = unit
    end
    if a.mode == "nm" then
        for i = 1, MAX_NAMEPLATES do add("nameplate" .. i) end
    elseif a.mode == "party" then
        add("target"); add("mouseover")
        for i = 1, 4 do add("party" .. i) end
    else
        add("target"); add("mouseover"); add("focus")
        if a.mode == "all" then
            for i = 1, MAX_NAMEPLATES do add("nameplate" .. i) end
            for i = 1, 4 do add("party" .. i) end
        end
    end
    return q
end

function Step()
    if not S then return end
    S.i = S.i + 1
    local unit = S.queue[S.i]
    if not unit then
        S.pending = nil
        J.Report(S)
        return
    end
    local rec = { unit = unit, attemptAt = time() }
    S.results[#S.results + 1] = rec
    local okN, name = pcall(UnitName, unit)
    rec.name = (okN and type(name) == "string") and name or nil
    rec.guid = (type(UnitGUID) == "function") and UnitGUID(unit) or nil
    rec.class = (type(UnitClass) == "function") and UnitClass(unit) or nil
    rec.level = (type(UnitLevel) == "function") and UnitLevel(unit) or nil
    if not UnitExists(unit) or not rec.guid then
        rec.skip = "unit gone"
        Step()
        return
    end
    if type(UnitIsUnit) == "function" and UnitIsUnit(unit, "player") then
        rec.skip = "self"
        Step()
        return
    end
    local okC, can = pcall(CanInspect, unit, true)
    rec.canInspect = okC and Preview(can) or ("err: " .. tostring(can))
    local okI, errI = pcall(NotifyInspect, unit)
    rec.notify = okI and "ok" or ("err: " .. tostring(errI))
    if not okI then
        Step()
        return
    end
    S.token = S.token + 1
    local token = S.token
    S.pending = { unit = unit, guid = rec.guid, rec = rec, token = token }
    -- The answer arrives as an event. Silence is a finding too: it is recorded
    -- as a timeout, which keeps "the server never answered" apart from
    -- "the server answered with empty slots".
    After(S.opts.timeout, function()
        if not S or not S.pending or S.pending.token ~= token then return end
        S.pending.rec.event = ("timeout %ds"):format(S.opts.timeout)
        S.pending = nil
        After(0.5, Step)
    end)
end

function J.OnInspectReady(guid)
    if not S then return end
    local p = S.pending
    if not p then
        -- another addon (or the player) inspected someone — not our answer
        S.unsolicited = (S.unsolicited or 0) + 1
        return
    end
    S.pending = nil
    p.rec.event = "INSPECT_READY"
    p.rec.eventGuid = Preview(guid)
    if type(guid) == "string" and p.guid and guid ~= p.guid then
        -- stale request or a different unit: still read, but say so
        p.rec.guidMismatch = true
    end
    local ok, err = pcall(function()
        J.ReadItems(p.unit, p.rec)
        J.ReadTalents(p.unit, p.rec)
        if S.opts.openUi then J.OpenNative(p.unit, p.rec) end
    end)
    if not ok then p.rec.readError = tostring(err):sub(0, 120) end
    -- the client's own inspect code warns the server drops data when requests
    -- are flooded: pace the next unit instead of chainsawing through them
    After(S.opts.gap, Step)
end

-- How many talent routes answered with real data — the chat line's verdict.
function TalentHit(rec)
    local hit, tried = 0, 0
    for _, t in ipairs(rec.talents or {}) do
        tried = tried + 1
        if type(t.v) == "string" and t.v ~= "" and t.v ~= "nil" and t.v ~= "false"
            and not t.v:find("^table%(0%)") then hit = hit + 1 end
    end
    return ("%d/%d"):format(hit, tried)
end

-- Bounded ring of probed players keyed by GUID: one run replaces `lastRun`
-- only, so several players stay comparable without growing the SV file.
local function StorePlayers(db, results)
    db.debug.players = db.debug.players or {}
    db.debug.playerOrder = db.debug.playerOrder or {}
    for _, rec in ipairs(results) do
        if rec.guid and rec.items then
            db.debug.players[rec.guid] = {
                at = rec.attemptAt,
                name = rec.name,
                class = rec.class,
                level = rec.level,
                ilvl = rec.ilvl and (rec.ilvl.v or rec.ilvl.err) or nil,
                links = rec.items.links,
                ids = rec.items.ids,
                sample = rec.items.sampleText,
                importString = rec.talents and rec.talents[1] and rec.talents[1].v or nil,
                ownString = rec.ownString,
                gridHits = rec.grid and rec.grid.hits or 0,
                gridSample = rec.grid and rec.grid.sample or nil,
            }
            local seen = false
            for _, g in ipairs(db.debug.playerOrder) do
                if g == rec.guid then seen = true break end
            end
            if not seen then
                db.debug.playerOrder[#db.debug.playerOrder + 1] = rec.guid
            end
        end
    end
    while #db.debug.playerOrder > MAX_PLAYERS do
        local old = table.remove(db.debug.playerOrder, 1)
        db.debug.players[old] = nil
    end
end

function J.Report(run)
    run = run or S
    if not run then return end
    local answered = 0
    for _, rec in ipairs(run.results) do
        if rec.items then answered = answered + 1 end
    end
    local db = J.DB()
    if db then
        db.debug = db.debug or {}
        -- one snapshot per run: the SV file must not grow with every probe
        db.debug.inspect = {
            at = time(),
            build = tostring(select(3, GetBuildInfo())),
            api = run.api,
            apiPresent = run.apiPresent,
            answered = answered,
            total = #run.results,
            unsolicited = run.unsolicited or 0,
            lastRun = run.results,
        }
        StorePlayers(db, run.results)
    end
    J.Say(("inspecttest: gear answered for %d of %d unit(s); api present=%s, missing=%s")
        :format(answered, #run.results, tostring(run.apiPresent),
            (#(run.apiMissing or {}) > 0 and table.concat(run.apiMissing, ",") or "none")))
    for _, rec in ipairs(run.results) do
        J.Say(("inspecttest [%s] %s: notify=%s event=%s slots=%s ids=%s ilvl=%s talents=%s import=%s grid=%s")
            :format(rec.unit, tostring(rec.name or "?"),
                tostring(rec.notify or rec.skip or "n/a"),
                tostring(rec.event or "-"),
                rec.items and tostring(rec.items.links) or "-",
                rec.items and tostring(rec.items.ids) or "-",
                (rec.ilvl and (rec.ilvl.v or rec.ilvl.err)) or "-",
                TalentHit(rec),
                (rec.talents and rec.talents[1] and (rec.talents[1].v or rec.talents[1].err)) or "-",
                rec.grid and tostring(rec.grid.hits) or "-"))
        if rec.native then
            J.Say(("inspecttest [%s] native: InspectUnit=%s, talentTab=%s, frame=%s, inspecting=%s")
                :format(rec.unit,
                    tostring(rec.native.inspectUnit and (rec.native.inspectUnit.v or rec.native.inspectUnit.err)),
                    tostring(rec.native.talentTab and (rec.native.talentTab.v or rec.native.talentTab.err)),
                    tostring(rec.native.frameLoaded), tostring(rec.native.isInspecting)))
        end
    end
    J.Say("inspecttest: talent variants, item samples and the player ring are in SavedVariables → debug.inspect / debug.players")
    S = nil
end

function J.Run(arg)
    if S then
        S = nil
        J.Say("inspecttest: cancelled")
        return
    end
    local a = J.ParseArgs(arg)
    local queue = BuildQueue(a)
    if #queue == 0 then
        J.Say("inspecttest: no unit to probe — target/hover a player (nameplates: /nspy inspecttest all)")
        return
    end
    local api, missing, present = J.ApiSnapshot()
    S = { queue = queue, i = 0, opts = a, results = {}, token = 0,
          api = api, apiMissing = missing, apiPresent = present }
    J.Say(("inspecttest: %d unit(s), gap=%ds, timeout=%ds, ui=%s, build=%s")
        :format(#queue, a.gap, a.timeout, tostring(a.openUi and true or false),
            tostring(select(3, GetBuildInfo()))))
    Step()
end

-- ─────────────────────────────────────────────────────────────────────────────
-- talent tree export (/nspy talex)
-- ─────────────────────────────────────────────────────────────────────────────
-- WHY: the import string a build comes as is a bit-packed stream (Blizzard
-- documents it in Blizzard_ClassTalentImportExport.lua). Its HEADER decodes
-- with no external data at all: 8 bits serialization version, 16 bits specID,
-- 128 bits tree hash. The CONTENT section, however, is written node by node in
-- the exact order of C_Traits.GetTreeNodes() and depends on each node's
-- maxRanks and type — data that exists only inside the client.
--
-- So this export captures that dictionary once, and then any import string can
-- be decoded offline (see the site's talent decoder). Forever is a custom
-- server with its own specIDs (measured 1482..1491, not the retail 62..267),
-- so public talent trees from Wowhead do NOT apply — the tree has to come from
-- this client.
--
-- The stream format (from ExportUtil.lua, not guessed):
--   header  152 bits: version(8) specID(16) treeHash(16 x 8)
--   content per node: selected(1) [purchased(1) [partial(1) [ranks(6)]
--                      choice(1) [entryIndex(2)]]]
-- Each CHARACTER of the string carries 6 bits, least significant first —
-- which is why an ordinary base64 decoder mangles these strings.

local TALEX_LEVEL = 60          -- level used to initialise the view loadout

-- VIEW_TRAIT_CONFIG_ID is a client constant (documented as -3). Prefer the
-- real constant when the build exposes it, fall back to the documented value.
local function ViewConfigID()
    local c = rawget(_G, "Constants")
    local t = type(c) == "table" and c.TraitConsts
    if type(t) == "table" and type(t.VIEW_TRAIT_CONFIG_ID) == "number" then
        return t.VIEW_TRAIT_CONFIG_ID
    end
    return -3
end

-- Every specID this client knows. Two routes on purpose: the documented
-- enumeration, and a sweep of the numeric range that the client accepts.
-- The sweep is what makes the export complete on a custom server: a spec that
-- GetAllClassIDs does not list would otherwise be missing from the dictionary
-- and its import strings would stay undecodable.
local function CollectSpecIDs()
    local seen, out = {}, {}
    local function add(id)
        if type(id) == "number" and id > 0 and not seen[id] then
            seen[id] = true
            out[#out + 1] = id
        end
    end
    local cs = rawget(_G, "C_SpecializationInfo")
    if type(cs) == "table" then
        local ok, classIDs = pcall(function() return cs.GetAllClassIDs and cs.GetAllClassIDs() end)
        if ok and type(classIDs) == "table" then
            for _, classID in ipairs(classIDs) do
                local okS, specs = pcall(function() return cs.GetSpecIDs and cs.GetSpecIDs(classID) end)
                if okS and type(specs) == "table" then
                    for _, specID in ipairs(specs) do add(specID) end
                end
            end
        end
        -- active spec of the current character. GetSpecialization() returns an
        -- INDEX, and the specID lives behind GetSpecializationInfo — passing the
        -- index around would look like a valid id (1..4) and pollute the sweep.
        local okA, specIndex = pcall(function() return cs.GetSpecialization and cs.GetSpecialization() end)
        if okA and type(specIndex) == "number" and type(cs.GetSpecializationInfo) == "function" then
            local okI, specID = pcall(cs.GetSpecializationInfo, specIndex)
            if okI then add(specID) end
        end
    end
    local nEnum = #out
    -- numeric sweep: GetTraitTreeForSpec() is the filter that rejects non-specs
    local cc = rawget(_G, "C_ClassTalents")
    if type(cc) == "table" and type(cc.GetTraitTreeForSpec) == "function" then
        for id = 1400, 1600 do
            if not seen[id] then
                local ok, treeID = pcall(cc.GetTraitTreeForSpec, id)
                if ok and type(treeID) == "number" and treeID > 0 then add(id) end
            end
        end
    end
    return out, nEnum
end

-- Human name of one trait entry: overrideName first (the client's own label),
-- then the spell name behind the definition.
local function EntryName(configID, entryID)
    local ct = rawget(_G, "C_Traits")
    if type(ct) ~= "table" then return nil end
    local okE, entry = pcall(ct.GetEntryInfo, configID, entryID)
    if not okE or type(entry) ~= "table" or type(entry.definitionID) ~= "number" then
        return nil
    end
    local okD, def = pcall(ct.GetDefinitionInfo, entry.definitionID)
    if not okD or type(def) ~= "table" then return nil end
    if type(def.overrideName) == "string" and def.overrideName ~= "" then
        return def.overrideName
    end
    local spellID = def.spellID or def.overriddenSpellID
    local cs = rawget(_G, "C_Spell")
    if type(spellID) == "number" and type(cs) == "table" then
        local okS, nm = pcall(cs.GetSpellName, spellID)
        if okS and type(nm) == "string" and nm ~= "" then return nm end
    end
    return nil
end

-- One node: the fields the decoder needs, plus names for display.
local function ReadNode(configID, nodeID)
    local ct = rawget(_G, "C_Traits")
    local ok, node = pcall(ct.GetNodeInfo, configID, nodeID)
    if not ok or type(node) ~= "table" then return nil end
    local rec = {
        id = nodeID,
        max = tonumber(node.maxRanks) or 1,
        type = tonumber(node.type) or 0,
        entries = {},
    }
    -- entryIDs matter for choice nodes: the string stores an INDEX into this
    -- list, so the order must be preserved exactly as the client gives it
    if type(node.entryIDs) == "table" then
        for i, entryID in ipairs(node.entryIDs) do
            if i <= 4 then
                rec.entries[i] = entryID
                local nm = EntryName(configID, entryID)
                if nm then rec.name = rec.name or nm end
            end
        end
    end
    return rec
end

-- Export the tree of one specID. Returns a record or nil + reason.
--
-- ⚠️ View loadout is ASYNCHRONOUS: InitializeViewLoadout() only STARTS the
-- switch, and reading GetNodeInfo in the same frame returns the PREVIOUS config
-- (measured 19.11.2026: every node came back with type=0 and a single entryID,
-- which is the "not ready" shape — real trees have Tiered and Selection nodes).
-- So this is called one spec at a time from a paced loop (see J.ExportTalentTrees),
-- never in a tight for-loop.
local function ExportOneSpec(specID, level)
    local cc = rawget(_G, "C_ClassTalents")
    local ct = rawget(_G, "C_Traits")
    if type(cc) ~= "table" or type(ct) ~= "table" then return nil, "no API" end
    local okT, treeID = pcall(cc.GetTraitTreeForSpec, specID)
    if not okT or type(treeID) ~= "number" or treeID <= 0 then return nil, "no tree" end

    local configID = ViewConfigID()
    local okN, nodeIDs = pcall(ct.GetTreeNodes, treeID)
    if not okN or type(nodeIDs) ~= "table" or #nodeIDs == 0 then return nil, "no nodes" end

    local nodes, withName, types = {}, 0, {}
    for _, nodeID in ipairs(nodeIDs) do
        local rec = ReadNode(configID, nodeID)
        if rec then
            nodes[#nodes + 1] = rec
            if rec.name then withName = withName + 1 end
            types[rec.type] = (types[rec.type] or 0) + 1
        else
            -- a node the client refuses to describe would shift every following
            -- node in the bit stream, so keep a placeholder instead of skipping:
            -- the decoder needs the POSITION, not the data
            nodes[#nodes + 1] = { id = nodeID, max = 1, type = 0, entries = {}, missing = true }
            types.missing = (types.missing or 0) + 1
        end
    end
    -- типы одним полем: по нему видно, отдал ли клиент настоящие Tiered/Selection
    local typeList = {}
    for t, n in pairs(types) do typeList[#typeList + 1] = tostring(t) .. ":" .. n end
    table.sort(typeList)
    return {
        treeID = treeID,
        count = #nodes,
        named = withName,
        types = table.concat(typeList, " "),
        nodes = nodes,
    }, nil
end

-- Enum values, so the export says what the numbers MEAN instead of leaving a
-- bare 0/1/2 that has to be guessed later.
local function TypeEnumDump()
    local e = rawget(_G, "Enum")
    local t = type(e) == "table" and e.TraitNodeType
    if type(t) ~= "table" then return "no Enum.TraitNodeType" end
    local parts = {}
    for k, v in pairs(t) do
        if type(v) == "number" then parts[#parts + 1] = k .. "=" .. v end
    end
    table.sort(parts)
    return table.concat(parts, " ")
end

local TALEX_GAP = 0.4      -- seconds between specs: the view switch must settle

-- Paced export: one spec per timer tick. A tight loop reads the previous
-- config for every spec (see the note above ExportOneSpec), which silently
-- produces trees with no Tiered/Selection nodes.
function J.ExportTalentTrees(level)
    local ct = rawget(_G, "C_Traits")
    local cc = rawget(_G, "C_ClassTalents")
    if type(ct) ~= "table" or type(cc) ~= "table" then
        J.Say("talex: C_Traits/C_ClassTalents unavailable in this client")
        return
    end
    level = tonumber(level) or TALEX_LEVEL
    local specIDs, nEnum = CollectSpecIDs()
    J.Say(("talex: %d specIDs (%d from class enumeration), level=%d, config=%d, gap=%.1fs — ~%.0fs total")
        :format(#specIDs, nEnum, level, ViewConfigID(), TALEX_GAP, #specIDs * TALEX_GAP))
    J.Say("talex: node types in this client — " .. TypeEnumDump())

    local db = J.DB()
    if not db then J.Say("talex: no SavedVariables table") return end
    db.debug = db.debug or {}
    local state = { trees = {}, failed = {}, i = 0, level = level,
                    specIDs = specIDs, done = 0 }

    local function finish()
        local totalNodes, named = 0, 0
        for _, tr in pairs(state.trees) do
            totalNodes = totalNodes + (tr.count or 0)
            named = named + (tr.named or 0)
        end
        db.debug.talentTrees = {
            at = time(),
            build = tostring(select(3, GetBuildInfo())),
            level = state.level,
            types = TypeEnumDump(),
            specs = state.done,
            failed = table.concat(state.failed, ","):sub(1, 400),
            trees = state.trees,
        }
        J.Say(("talex: exported %d tree(s), %d nodes (%d named)")
            :format(state.done, totalNodes, named))
        J.Say("talex: dictionary is in SavedVariables → debug.talentTrees (logout writes the file)")
        if #state.failed > 0 then
            J.Say("talex: failed — " .. table.concat(state.failed, ","):sub(1, 200))
        end
    end

    local step      -- forward
    step = function()
        state.i = state.i + 1
        local specID = state.specIDs[state.i]
        if not specID then finish() return end

        local okInit, errInit = pcall(cc.InitializeViewLoadout, specID, state.level)
        if not okInit then
            state.failed[#state.failed + 1] = specID .. ":init"
            After(TALEX_GAP, step)
            return
        end
        -- the switch needs a frame (or several) to land before the nodes are read
        After(TALEX_GAP, function()
            local rec, why = ExportOneSpec(specID, state.level)
            if rec then
                state.trees[tostring(specID)] = rec
                state.done = state.done + 1
            else
                state.failed[#state.failed + 1] = specID .. ":" .. tostring(why)
            end
            step()
        end)
    end
    step()
end


-- Dump EVERY field of one node. Needed because the export kept reporting
-- type=0 for all 470 nodes while names resolved fine: that means the node
-- structure itself is being read from the wrong place, and guessing which
-- field is wrong is slower than printing all of them once.
local function DumpNode(configID, nodeID, tag)
    local ct = rawget(_G, "C_Traits")
    local ok, node = pcall(ct.GetNodeInfo, configID, nodeID)
    if not ok or type(node) ~= "table" then
        return ("%s node %s: ERROR %s"):format(tag, tostring(nodeID), tostring(node):sub(1, 60))
    end
    local parts = {}
    for k, v in pairs(node) do
        local t = type(v)
        if t == "table" then
            local n = 0
            for _ in pairs(v) do n = n + 1 end
            -- для массивов показываем первые элементы: именно там entryIDs
            local items = {}
            for i = 1, math.min(n, 4) do
                if type(v[i]) ~= "table" then items[#items + 1] = tostring(v[i]) end
            end
            v = ("tb(%d)[%s]"):format(n, table.concat(items, ","))
        elseif t == "table" or v == nil then
            v = "<nil>"
        end
        parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
    end
    table.sort(parts)
    return ("%s node %s: %s"):format(tag, tostring(nodeID), table.concat(parts, " "):sub(1, 320))
end

-- /nspy talex diag — why is every node type 0?
function J.TalexDiag()
    local ct = rawget(_G, "C_Traits")
    local cc = rawget(_G, "C_ClassTalents")
    local cs = rawget(_G, "C_SpecializationInfo")
    if type(ct) ~= "table" or type(cc) ~= "table" then
        J.Say("talex diag: API missing")
        return
    end
    -- активный персонаж: спек и его реальный конфиг
    local specIndex = select(1, cs.GetSpecialization and cs.GetSpecialization() or nil)
    local specID = select(1, cs.GetSpecializationInfo and cs.GetSpecializationInfo(specIndex) or nil)
    local activeConfig = select(1, cc.GetActiveConfigID and cc.GetActiveConfigID() or nil)
    J.Say(("talex diag: active spec=%s config=%s, view=%s, tree=%s")
        :format(tostring(specID), tostring(activeConfig), tostring(ViewConfigID()),
            tostring(select(1, cc.GetTraitTreeForSpec(specID or 0) or nil))))

    local treeID = cc.GetTraitTreeForSpec(specID or 0)
    if type(treeID) ~= "number" then
        J.Say("talex diag: no tree for the active spec — stand on a character with talents")
        return
    end
    local okN, nodeIDs = pcall(ct.GetTreeNodes, treeID)
    if not okN or type(nodeIDs) ~= "table" or #nodeIDs == 0 then
        J.Say("talex diag: GetTreeNodes returned nothing")
        return
    end
    J.Say(("talex diag: tree %s has %d nodes"):format(tostring(treeID), #nodeIDs))

    -- сравнение: реальный конфиг персонажа против view-конфига
    local first = nodeIDs[1]
    J.Say(DumpNode(activeConfig or 0, first, "ACTIVE"))
    J.Say(DumpNode(ViewConfigID(), first, "VIEW"))
    -- и типы по всему дереву в обоих режимах
    local function typeHist(cfg)
        local h = {}
        for _, id in ipairs(nodeIDs) do
            local ok, n = pcall(ct.GetNodeInfo, cfg, id)
            local t = (ok and type(n) == "table") and (tonumber(n.type) or -1) or -2
            h[t] = (h[t] or 0) + 1
        end
        local out = {}
        for t, c in pairs(h) do out[#out + 1] = tostring(t) .. ":" .. c end
        table.sort(out)
        return table.concat(out, " ")
    end
    J.Say("talex diag: ACTIVE types = " .. typeHist(activeConfig or 0))
    J.Say("talex diag: VIEW types   = " .. typeHist(ViewConfigID()))
    -- entryInfo — второй источник maxRank/типа
    local node2 = select(2, pcall(function() return ct.GetNodeInfo(ViewConfigID(), first) end))
    if type(node2) == "table" and type(node2.entryIDs) == "table" and node2.entryIDs[1] then
        local e = select(2, pcall(ct.GetEntryInfo, ViewConfigID(), node2.entryIDs[1]))
        if type(e) == "table" then
            local ep = {}
            for k, v in pairs(e) do
                if type(v) ~= "table" then ep[#ep + 1] = tostring(k) .. "=" .. tostring(v) end
            end
            table.sort(ep)
            J.Say("talex diag: entry " .. tostring(node2.entryIDs[1]) .. " → " .. table.concat(ep, " "):sub(1, 200))
        end
    end
end


-- GROUND TRUTH: my own build string + the per-node ranks that produced it.
--
-- Why this exists: the bit layout of an import string cannot be reverse
-- engineered from strings alone — several plausible layouts "mostly" fit and
-- then drift. With one string AND its known node ranks, the layout becomes a
-- solvable question instead of a guess.
--
-- The active config (not the view config) is the one that reports ranks:
-- measured 19.11.2026 — view config returns no node data at all, while the
-- active config returns ranksPurchased/maxRanks correctly even though its
-- `type` field comes back 0 for every node (this client does not fill it, and
-- on a classic tree all nodes ARE single anyway).
function J.TalexTruth()
    local ct = rawget(_G, "C_Traits")
    local cc = rawget(_G, "C_ClassTalents")
    local cs = rawget(_G, "C_SpecializationInfo")
    if type(ct) ~= "table" or type(cc) ~= "table" or type(cs) ~= "table" then
        J.Say("talex truth: API missing")
        return
    end
    local specIndex = select(1, cs.GetSpecialization and cs.GetSpecialization() or nil)
    local specID = select(1, cs.GetSpecializationInfo and cs.GetSpecializationInfo(specIndex) or nil)
    local configID = select(1, cc.GetActiveConfigID and cc.GetActiveConfigID() or nil)
    if type(specID) ~= "number" or type(configID) ~= "number" then
        J.Say("talex truth: no active spec/config")
        return
    end
    local treeID = select(1, cc.GetTraitTreeForSpec(specID) or nil)
    if type(treeID) ~= "number" then
        J.Say("talex truth: no tree for spec " .. tostring(specID))
        return
    end
    -- строка СВОЕГО билда: тем же API, что и у всех
    local okS, imp = pcall(ct.GenerateImportString, configID)
    if not okS or type(imp) ~= "string" or imp == "" then
        J.Say("talex truth: GenerateImportString failed: " .. tostring(imp):sub(1, 80))
        return
    end
    local okN, nodeIDs = pcall(ct.GetTreeNodes, treeID)
    if not okN or type(nodeIDs) ~= "table" then
        J.Say("talex truth: GetTreeNodes failed")
        return
    end
    -- ранги по узлам: это эталон для проверки раскладки битов
    local nodes, totalRanks, selected = {}, 0, 0
    for _, nodeID in ipairs(nodeIDs) do
        local okI, n = pcall(ct.GetNodeInfo, configID, nodeID)
        if okI and type(n) == "table" then
            local maxR = tonumber(n.maxRanks) or 0
            local bought = tonumber(n.ranksPurchased) or 0
            local active = tonumber(n.activeRank) or 0
            if bought > 0 or active > 0 then selected = selected + 1 end
            totalRanks = totalRanks + bought + math.max(active - bought, 0)
            nodes[#nodes + 1] = {
                id = nodeID, max = maxR, bought = bought, active = active,
                granted = math.max(active - bought, 0),
                entries = (type(n.entryIDs) == "table") and n.entryIDs[1] or nil,
                name = (function()
                    if type(n.entryIDs) ~= "table" or not n.entryIDs[1] then return nil end
                    return EntryName(configID, n.entryIDs[1])
                end)(),
            }
        else
            nodes[#nodes + 1] = { id = nodeID, max = 0, bought = -1, active = -1 }
        end
    end
    local db = J.DB()
    if db then
        db.debug = db.debug or {}
        db.debug.talentTruth = {
            at = time(),
            build = tostring(select(3, GetBuildInfo())),
            specID = specID, treeID = treeID, configID = configID,
            importString = imp,
            importLen = #imp,
            nodeCount = #nodeIDs,
            selected = selected,
            totalRanks = totalRanks,
            nodes = nodes,
        }
    end
    J.Say(("talex truth: spec=%d tree=%d config=%d — %d nodes, %d touched, %d ranks")
        :format(specID, treeID, configID, #nodeIDs, selected, totalRanks))
    J.Say("talex truth: own string (" .. #imp .. " chars): " .. imp)
    J.Say("talex truth: ground truth is in SavedVariables → debug.talentTruth")
end


-- DECODER SOLVER: find the real layout by brute force ON THE CLIENT.
--
-- Why here and not offline: the bit layout depends on the ORDER of the nodes in
-- the stream, and measurements show it is NOT the order of C_Traits.GetTreeNodes
-- (the touched nodes land on different positions than their ranks say). The
-- client is the only place that has both the string and the per-node truth, so
-- the search runs here — one command, no more round trips.
--
-- Everything under test: node ordering (5 candidates), header length, rank width,
-- and whether a "purchased" bit exists. A combination wins only if it reproduces
-- the recorded ranks EXACTLY for every node.

local TALEX_ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local ALPHA_IDX = {}
for i = 1, #TALEX_ALPHA do ALPHA_IDX[TALEX_ALPHA:sub(i, i)] = i - 1 end

-- The string is 6 bits per character, least significant bit first (ExportUtil).
local function ToBits(str)
    local bits = {}
    for i = 1, #str do
        local v = ALPHA_IDX[str:sub(i, i)]
        if not v then return nil end
        for k = 0, 5 do
            bits[#bits + 1] = math.floor(v / (2 ^ k)) % 2
        end
    end
    return bits
end

local function Extract(bits, pos, width)
    local out = 0
    for k = 0, width - 1 do
        local b = bits[pos + k + 1]
        if b == nil then return nil end
        out = out + b * (2 ^ k)
    end
    return out
end

-- Decode with one grammar. Returns a map nodeID -> ranks, or nil on a
-- malformed read (a rank above maxRanks means the stream has drifted).
local function DecodeWith(imp, order, header, rankWidth, readPurchased)
    local bits = ToBits(imp)
    if not bits then return nil, "bad chars" end
    local pos = header
    local out = {}
    for _, n in ipairs(order) do
        local sel = Extract(bits, pos, 1)
        if sel == nil then return nil, "eof" end
        pos = pos + 1
        if sel == 1 then
            local purchased = 1
            if readPurchased then
                purchased = Extract(bits, pos, 1)
                if purchased == nil then return nil, "eof" end
                pos = pos + 1
            end
            if purchased == 1 then
                local r = Extract(bits, pos, rankWidth)
                if r == nil then return nil, "eof" end
                pos = pos + rankWidth
                if r < 1 or r > (n.max or 1) then return nil, "rank>max" end
                out[n.id] = r
            else
                out[n.id] = 1     -- granted, no rank bits
            end
        end
    end
    return out, nil
end

function J.TalexSolve()
    local ct = rawget(_G, "C_Traits")
    local cc = rawget(_G, "C_ClassTalents")
    local cs = rawget(_G, "C_SpecializationInfo")
    if type(ct) ~= "table" or type(cc) ~= "table" then J.Say("talex solve: API missing") return end
    local specIndex = select(1, cs.GetSpecialization and cs.GetSpecialization() or nil)
    local specID = select(1, cs.GetSpecializationInfo and cs.GetSpecializationInfo(specIndex) or nil)
    local configID = select(1, cc.GetActiveConfigID and cc.GetActiveConfigID() or nil)
    local treeID = specID and select(1, cc.GetTraitTreeForSpec(specID) or nil)
    if type(treeID) ~= "number" or type(configID) ~= "number" then
        J.Say("talex solve: no active spec/config") return
    end
    local okS, imp = pcall(ct.GenerateImportString, configID)
    if not okS or type(imp) ~= "string" or imp == "" then
        J.Say("talex solve: no import string") return
    end
    local okN, nodeIDs = pcall(ct.GetTreeNodes, treeID)
    if not okN or type(nodeIDs) ~= "table" then J.Say("talex solve: no nodes") return end

    -- truth + geometry (posX/posY) for every node, read from the ACTIVE config
    local all, truth = {}, {}
    for _, nodeID in ipairs(nodeIDs) do
        local ok, n = pcall(ct.GetNodeInfo, configID, nodeID)
        if ok and type(n) == "table" then
            local rec = {
                id = nodeID,
                max = tonumber(n.maxRanks) or 1,
                x = tonumber(n.posX) or 0,
                y = tonumber(n.posY) or 0,
            }
            -- granted ranks count too: the stream writes them as selected
            local bought = tonumber(n.ranksPurchased) or 0
            local active = tonumber(n.activeRank) or 0
            local granted = math.max(active - bought, 0)
            rec.ranks = bought + granted
            all[#all + 1] = rec
            if rec.ranks > 0 then truth[nodeID] = rec.ranks end
        end
    end
    J.Say(("talex solve: spec=%d tree=%d — %d nodes, %d touched, string %d chars")
        :format(specID, treeID, #all, (function() local c = 0 for _ in pairs(truth) do c = c + 1 end return c end)(), #imp))
    if next(truth) == nil then
        J.Say("talex solve: no talents on this character — stand on a character WITH talents")
        return
    end

    -- node orderings to try: the API order, and by position on the tree
    local orders = {}
    orders[#orders + 1] = { name = "api", list = all }
    local byY = {}; for i, n in ipairs(all) do byY[i] = n end
    table.sort(byY, function(a, b)
        if a.y ~= b.y then return a.y < b.y end
        if a.x ~= b.x then return a.x < b.x end
        return a.id < b.id
    end)
    orders[#orders + 1] = { name = "y,x", list = byY }
    local byX = {}; for i, n in ipairs(all) do byX[i] = n end
    table.sort(byX, function(a, b)
        if a.x ~= b.x then return a.x < b.x end
        if a.y ~= b.y then return a.y < b.y end
        return a.id < b.id
    end)
    orders[#orders + 1] = { name = "x,y", list = byX }
    local byIDdesc = {}; for i, n in ipairs(all) do byIDdesc[i] = n end
    table.sort(byIDdesc, function(a, b) return a.id > b.id end)
    orders[#orders + 1] = { name = "id desc", list = byIDdesc }

    local wins = {}
    for _, ord in ipairs(orders) do
        for header = 0, 200 do
            for rw = 4, 8 do
                for rp = 0, 1 do
                    local got = DecodeWith(imp, ord.list, header, rw, rp == 1)
                    if got then
                        local same, diff = 0, 0
                        for id, r in pairs(truth) do
                            if got[id] == r then same = same + 1 else diff = diff + 1 end
                        end
                        for id in pairs(got) do
                            if truth[id] == nil then diff = diff + 1 end
                        end
                        if diff == 0 and same > 0 then
                            wins[#wins + 1] = ("%s|hdr=%d|rw=%d|purch=%d|hits=%d")
                                :format(ord.name, header, rw, rp, same)
                        end
                    end
                end
            end
        end
    end

    local db = J.DB()
    if db then
        db.debug = db.debug or {}
        db.debug.talentSolve = {
            at = time(), specID = specID, treeID = treeID,
            importString = imp,
            truthCount = (function() local c = 0 for _ in pairs(truth) do c = c + 1 end return c end)(),
            wins = table.concat(wins, ","):sub(1, 400),
            nodes = all,
        }
    end
    if #wins == 0 then
        J.Say("talex solve: NO combination reproduces the ranks — the stream layout differs from the documented one")
    else
        J.Say(("talex solve: %d combination(s) reproduce ALL %d ranks: %s")
            :format(#wins, (function() local c = 0 for _ in pairs(truth) do c = c + 1 end return c end)(),
                table.concat(wins, " ; "):sub(1, 260)))
    end
    J.Say("talex solve: details in SavedVariables → debug.talentSolve")
end

-- ─────────────────────────────────────────────────────────────────────────────
-- events (INSPECT_READY arrives on its own frame: the main one handles enough)
-- ─────────────────────────────────────────────────────────────────────────────

if CreateFrame then
    local probeFrame = CreateFrame("Frame")
    probeFrame:RegisterEvent("INSPECT_READY")
    probeFrame:SetScript("OnEvent", function(_, event, arg1)
        if event ~= "INSPECT_READY" then return end
        local ok, err = pcall(J.OnInspectReady, arg1)
        if not ok then J.Say("inspecttest: event handler error " .. tostring(err)) end
    end)
end

return J
