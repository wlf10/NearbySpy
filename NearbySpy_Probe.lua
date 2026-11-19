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
