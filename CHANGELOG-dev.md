# NearbySpy: internal version history

Cut from the NearbySpy.lua header when the version was publicly reset to 1.0.0 (2026-10-11): the first public version starts from a clean slate, the history of internal development lives here.

## Public releases

    1.2.2 (2026-10-15):
      - /nspy who|whoclass|whorace routed to assisted (suggest) mode: programmatic
        who sending is dead as of build 70291 (hardware gate), so every scan
        command now types the query and waits for a click on the magnifier;
        repeating the command stops the scan. Removed dead code:
        WhoSendRaw/WhoPress/WhoSearchButton/WHO_PATHS/WHO_GAP (−190 lines) and
        the SCAN_*/MODE_*/SUGGEST_PROG_BLOCK keys. Help texts updated in all 6
        locales.
      (intermediately tagged as 1.2.3, renumbered back on request)
      - In-game export REMOVED (/nspy export, copy window, Copy button,
        BuildExportText, EXPORT_*/BTN_COPY keys in all locales, help-window
        entry): an EditBox with ~9k lines crashed the client; data now reaches
        RealmPulse only via a SavedVariables file upload (the site accepts a raw
        NearbySpy.lua, up to 10 MB, with validation). README/CURSEFORGE.md
        updated.

    1.2.1 (2026-10-15):
      - the window was repainted from teal to the "lamp-lit" Blizzard Classic
        style: the frame uses the BasicFrameTemplateWithInset template (present
        in the Forever build, verified against FrameXML sources), with a
        hand-rolled gold frame as fallback; gold/brown palette, NORMAL_FONT gold
        title, gold histogram peak.

    1.2.0 (2026-10-15):
      - full redesign of the main window (Scout/Tactical variant per the mockup):
        metric cards (total / active ≤5 min / factions), level histogram with
        tinting, top-3 classes in class colors with icons (CLASS_ICON_TCOORDS +
        UI-Classes-Circles), All/Fresh/New filters, rows with a class icon,
        zebra striping, hover and GameTooltip (first encounter, source,
        encounters), a "contact" column colored by freshness.
      - the review subagent found a blocker before deploy: TimeAgo left together
        with the old block; also fixes: Copy button fallback branch (via okBtn,
        not SetText), restored the source-line subtitle/other keys, restored
        WIN_HINT, aligned table headers with the columns, filter label and
        subtitle widths, removed dead keys WIN_TOTAL/WIN_FRESH/WIN_DEMO.
      - "New" = firstSeen >= addon load time (reset on /reload).

## Internal versions before the 1.0.0 public reset (2026-10-11)

    1.6.1:
      - debug mode /nspy debug (db.debugMode): on → logs (digests, scan progress,
        who replies, gate blocks) print to chat; off → stealth mode: chat shows
        only command replies, announcements and errors, logs go to the SV ring
        buffer (read after logout). Printing moved to the D() function.
      - window charts: level histogram 1–60 (bars built from textures, brightest
        bar = peak) + top-3 classes as horizontal bars — all from db.players, no
        new storage; window grew to 680×540 (list starts at -220).
      - font: own NearbySpySans.ttf (Liberation Sans, full Cyrillic) — beta
        client fonts lack Russian (window showed "boxes").
      - window: freshness rows (5m/15m/1h), demo slice (lvl min–max, avg + top-3
        classes), "Who feeds it" (unit/guild/chat/who from db.debug.src), right
        column shows relative time ("3 min ago", previously a date); list moved
        below the summary (-102). Filling moved to UpdateWindowUI, called from
        ShowWindow: OnShow does not fire on win:Show() in the custom 1.60 beta —
        the window was empty while the title was visible.
      - chat handler: varargs passed explicitly into the pcall lambda (vanilla
        compile error "outside of vararg" — the client rejected the whole file).
      - who probe (one-shot SendWho without a window) REMOVED: client 70291
        blocks C_FriendList.SendWho() with the ADDON_ACTION_BLOCKED gate
        (verified by SV: blocked[SendWho()]=6) — programmatic who is dead at the
        client level, only a manual click on the magnifier works.
      - digest cleanup (duplicate argument after cl-counter removal).

    1.6.0:
      - chat as a name source: CHAT_MSG_SAY/YELL/CHANNEL → UpsertPlayer(source='chat')
        without class/level/zone (nil, not "" — so already-known fields of
        previously seen players are not wiped). The speaker is the 2nd event
        argument (signature per wowpedia/warcraft.wiki); the first 15 events are
        written verbatim to db.debug.chatSample — to verify argument positions —
        readable from SV after logout.
      - removed worked-out diagnostics and dead cargo (−632 lines): commands
        /nspy whotest|whox|lfgtree|whoprime, auto-/who (SendWhoZone + tick),
        one-off API probes (apiProbeV1-V3, layerApi, unitSample, whoAreas), the
        dead combat-log path (CombatLogGetCurrentEventInfo = nil in the beta)
        and speculative auction/cast sensors. Chat speaker parsing wrapped in
        pcall (secret strings don't kill the handler, failures visible in DbgErr).

    1.5.9:
      - probe V3: auction functions (QueryAuctionItems/GetAuctionItemInfo/
        C_AuctionHouse...) and minimap + event sensors AUCTION_HOUSE_SHOW /
        AUCTION_ITEM_LIST_UPDATE / UNIT_SPELLCAST_SUCCEEDED (debug.probeEv
        counters, last spellID) — for future Auctionator/GatherMate/Spy
        features. Registration via pcall, probe flag not stored in SV.

    1.5.8:
      - IMPORTANT: the server ignores level ranges in /who (proven 2026-10-10:
        k-"Druid" 51-60 → 50 results with a cap of 30 and zero players above
        30). Level splitting removed entirely: suggest = 9 class slices, an
        overflowing class is taken as is (limit 50).
      - fix MaxLevel(): referenced the global db (nil) instead of GetDB() →
        silently returned the engine's 60 ("starting from 60 again").

    1.5.7:
      - an overflowing class slice is split NOT by bands but by single levels,
        top-down from the maximum (user decision 2026-10-09: "no 1-10 bands,
        start at 30 and decrement by one"); an overflowing single level is taken
        as is.

    1.5.6:
      - MaxLevel() no longer trusts GetMaxPlayerLevel (engine 60 with a server
        cap of 30): the ceiling = the highest level in the database, rounded up
        to a band of 10. Currently gives 30 → suggest: k-"X" 1-30, bands
        1-10/11-20/21-30. Grows by itself as the server levels up.

    1.5.5:
      - an overflowing class slice (limit 50) is split by level bands of 10:
        1-10 / 11-20 / 21-30 (user decision 2026-10-09); an overflowing band is
        taken as is (no deeper splitting).

    1.5.4:
      - /nspy suggest starts straight with class slices (k-"class" 1-60): the
        broad 1-60 on this server always overflows (even 1-1 > 50), the first
        click was wasted.

    1.5.3:
      - combat log cut from the client entirely (CombatLogGetCurrentEventInfo=nil,
        which is why Spy3 doesn't use it) — the event is registered only if the
        function exists (no dead path kept);
      - channel re-probe 30s after login (the list is empty at login) + counting
        members of custom channels via C_ChatInfo.GetChannelRosterInfo.

    1.5.2:
      - intercept the client protection gate: ADDON_ACTION_BLOCKED/FORBIDDEN,
        MACRO_ACTION_*, LUA_WARNING → function and culprit written to the ring
        buffer and debug.blocked (catching "only Blizzard extensions may use
        this").

    1.5.1:
      - full debug: per-source counters (db.debug.src), capturing first errors
        (db.debug.err — pcall no longer swallows silently), secret combat-log
        value detector (canaccessvalue, modeled on Spy3), digest to the SV ring
        buffer every 5 minutes, one-off client API probe (channels/scoreboard/
        CL API).

    1.5.0:
      - main mode = passive world collection: mouseover, party/raid, guild
        roster, combat log (previously only target/focus/nameplate);
      - auto-/who disabled by a one-shot migration, auto-start of a full scan on
        an overflowing answer replaced with a hint about /nspy suggest;
      - /nspy suggest: a queue of scan requests (overflow split by classes) typed
        into the who box one at a time — all that's left is clicking the
        magnifier.

    1.4.0:
      - bypass of the 50-row /who limit: full zone scan by level ranges (1-10,
        11-20, ...), an overflowing range is halved down to a single level;
        /nspy who now starts a full scan;
      - a single /who that hits the 50 limit starts a full scan itself (no more
        often than once per 10 min);
      - the scan summary is always printed (previously the addon stayed silent
        at 0 new).

    1.3.1:
      - UI without GameFont* objects: font set explicitly (Fonts\FRIZQT__.TTF
        with fallbacks) — in the custom beta GameFont* objects are missing/empty,
        text didn't render (empty window);
      - window creation wrapped in pcall, the error is printed to chat;
      - CVars missing from the client (GetCVar=nil) are no longer "fixed" every
        15 ticks.

    1.3.0:
      - /who zone scan (CensusPlus approach): server-side list of all players in
        the zone, independent of nameplates;
      - zone taken from GetZoneText() (UnitPosition on foreign units in the beta
        returns mapID=0 with no name);
      - coordinates = player position at record time (approximation);
      - nameplate channel kept: with nameplates enabled (V) it adds class/faction.

    1.2.0:
      - window on the standard BasicFrameTemplateWithInset (Blizzard style);
      - player list as colored strings (class color), summary on top;
      - "Copy" button → separate window with raw text for Ctrl+A/Ctrl+C;
      - EditBox without autofocus (1.1.0: autofocus grabbed focus and crashed the
        client — assert CSimpleEditBox code 11);
      - Esc/× close the window regardless of focus;
      - debug counters for ticks and nameplates in /nspy count.
