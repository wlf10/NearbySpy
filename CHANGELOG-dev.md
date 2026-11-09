# NearbySpy: internal version history

Cut from the NearbySpy.lua header when the version was publicly reset to 1.0.0 (2026-10-11): the first public version starts from a clean slate, the history of internal development lives here.

## Unreleased

    1.5.3 (2026-11-10) — class/level sampling; a peer packet stops posing as our meeting:
      - FEATURE: the player window has two selectors next to the realm one — class
        and level. The class selector walks the classes present in the database
        (most frequent first); records with no class are reachable as their own
        entry (238 in a live save). The level selector walks bands of ten; a
        click on a histogram column selects that exact level, a second click
        clears it; a click on a row in the CLASSES panel filters by that class and
        highlights it. All filters combine (AND).
      - FEATURE: peer records keep the sender character (peerFrom), and
        /nspy peer new (only what the channel taught us) is split from
        /nspy peer list (everything delivered, updates included). The "New"
        filter now shows only our own finds.
      - FEATURE: /nspy peer send drains the pending queue on demand — the queue
        normally drains only on a click in the 3D world, and packets can sit
        there indefinitely when that gate does not fire.
      - BUGFIX: a peer record was treated as our own meeting (lastSeen = receive
        time, count +1), so a player somebody else met read as "seen just now"
        and inflated the encounter counter. Now the packet is passed with
        observe = false: count 0, lastSeen empty, the packet time kept in peerAt.
        A local sighting also replaces source="peer" now instead of the source
        staying "peer" forever.
      - BUGFIX: the peer channel is per faction — the server refuses to let a
        character join a channel created by the other faction, and the addon
        reported the channel as joined while it was dead (the return value of
        JoinChannelByName was discarded). Channels are now nearbyspy (base),
        nearbyspya (Alliance), nearbyspyh (Horde); the join result is stored in
        db.debug.peerJoin and shown by /nspy peer; inbound messages are accepted
        from any single-character suffix, and stale legacy channel memberships
        are left on sight.
      - INTERNAL: the addon is split into NearbySpy_Locale.lua (UI strings in six
        languages plus the shared constants table NSP_CONST) and NearbySpy.lua
        (logic), because the main chunk was ONE top-level local short of the Lua
        5.1 limit of 200 — the next such edit would have broken the whole addon
        at compile time. Free locals went from 1 to 14.

    1.5.2 (dev, 2026-11-09) — peer stops sharing the observer's position; settings rows fit their text:
      - BUGFIX: coordinates went into the peer packet for ANY record, including
        /who entries. A /who reply carries the player's zone but no position, so
        its x/y is where WE stood: the packet told the receiver "this stranger is
        at these coordinates", placing them on the observer's own map spot. On the
        live database 10 428 of 12 173 records are /who, so this was the default
        behaviour, not an edge case. Chat entries and any record whose position
        fell back to the observer were equally wrong.
      - Record() now remembers whether the position came from the UNIT itself
        (coordsFromUnit), and only such a position is shared. Everything else
        sends "-" for x/y in the 11th and 12th fields, while the zone (id + name)
        still travels — the zone is the player's own, taken from /who or from the
        map, and it is correct.
      - The zone id for /who rows was already only set when the zone matched ours,
        so a foreign-zone entry sends zoneId 0 and the name; unchanged.
      - Local data is untouched: the player's database still stores the observer
        point for /who rows (the site uses it as the observer's position).
      - BUGFIX: settings rows were placed at hard-coded offsets with a 52px step,
        but a description wraps by its own length: the new "Accept other realms"
        text is 136 chars in French and 112 in Russian, which needs ~65px and ran
        into the row below. Rows are now stacked by the MEASURED height of the
        label and description (FontString:GetStringHeight, with a conservative
        fallback when the widget cannot measure itself), and the window grows to
        fit its content instead of clipping the last selector.
      - the descriptions were shortened in all six locales: 178-200 chars was
        more text than a 290px column should carry in a settings list.
      - BUGFIX (the real reason "smaller font" was impossible): ApplyFont ignored
        its size argument and applied GameFontNormal to every label, so the whole
        window rendered at one size and the "8pt realm tag against a 12pt name" was
        a fiction. Sizes are now honoured through Blizzard FONT OBJECTS — <=7 gets
        GameFontNormalSmall, >=14 GameFontNormalLarge, everything else
        GameFontNormal — never through SetFont(path, size), which renders nothing
        for the first 10-20s after a cold login on this client. A missing variant
        degrades to the normal object, and the chosen object per size is recorded
        once in db.debug.fonts so it can be verified from SavedVariables.
      - the realm tag under the player name is now 7pt (was 8) and the name moved
        5px up to keep the pair centred in the 30px row.
      - BUGFIX: peer rows showed the class FILE KEY ("DRUID") in the PROFILE
        column while locally recorded rows showed the localized name ("Друид") —
        same column, two spellings. A peer packet carries only the key, and the
        display fell back to it. The key is now translated at display time
        (ClassLocFromFile, male table first, then female), so records already in
        SavedVariables are fixed too, and at intake so new peer records store
        classLoc like a local observation does.
      - provenance for channel data: every record received from the peer channel
        now stores the character whose addon sent it (peerFrom in SavedVariables,
        peer_from on the site), plus a per-sender tally in db.debug.peerSenders.
        Received records are never re-sent, so the sender IS the discoverer — this
        is the only way to answer "whose data is this row" later, and to remove a
        whole contributor's data without guessing by timestamp. The admin players
        page can filter by sender and purge every record of one sender.
      - 5th filter tab "Peer new": the channel rows that were NEW to us. The Peer
        tab keeps everything the channel delivered (updates included), New stays
        our own finds, and the new tab is the intersection people ask about: players
        I learned from others and had never seen myself. The counter on the button
        uses the existing peerNewN figure. `/nspy peer new` now prints the same
        subset, `/nspy peer list` keeps the full list — the two commands were
        identical before, which read as a bug next to the two tabs.
      - the New filter shows only OUR OWN finds. A peer record gets firstSeen at
        the moment the packet arrives, so it satisfied the time check and filled
        "New" with players somebody else met — 215 of them in the live save. The
        counter next to the button follows the same rule. Channel rows keep their
        own Peer filter.
      - DECISION (user, 09.11.2026): names taken from the game — class and zone —
        stay in the CLIENT's language. Switching the interface language changes the
        addon's own labels, not game data: with a Russian client the class reads
        "Маг" even when the interface is English. A translation table for classes
        was written and then removed for this reason; an earlier build briefly
        translated them.
      - peer packets carry only the class FILE KEY ("DRUID"), so the key is turned
        into the CLIENT's localized string — otherwise a channel row showed
        "DRUID" next to "Друид" for a locally recorded one. This is not an addon
        translation, it is the client's own name for the key.
      - the realm badge under the player name now appears on EVERY row, not only
        on rows from another realm: one list must not mix labelled and unlabelled
        entries. Our own realm shrinks to its ruleset ("PvE" / "PvP") — repeating
        "CAMWOW EU5 Realm 1 PvE" under thousands of rows is noise — while a foreign
        realm keeps the part that identifies it ("EU4 Realm 6 PvP").
      - realm filter in the player window: a cycler button under the toolbar walks
        "all realms -> our realm -> each other realm -> all". The list is rebuilt
        from the database on every click, so a newly arrived realm appears without
        /reload, and our own realm is always first. Both the list and the counters
        obey the selection — a "Peer 12" badge over three visible rows would be a
        lie. A second row was used instead of another toolbar tile: the four
        filters plus the counter already fill the 668px strip.
      - the realm of a foreign peer row is now a separate line UNDER the player
        name, rendered in a smaller font (8pt against the name's 12pt), instead of
        a colour code appended to the name. One FontString cannot carry two sizes,
        and appending the tag took width from the 142px name column and pushed the
        name itself out. The tag keeps its own 142px width and is hidden for rows
        from our own realm, so a recycled list row never shows a stale realm.
      - the SavedVariables root now carries `db.realm` (the realm of the last
        character played). Player records already carry their own realm, but the
        world directory (vendor prices, fishing) had only the players fallback —
        and on an account-level file the world tag has to be explicit.
      - BUGFIX: unchecking that checkbox printed "ОШИБКА списка: ...
        attempt to index field 'total' (a nil value)" and left the list stale.
        The handler tested `win` — the SETTINGS window, which is by definition
        shown — and then repainted a player window that may never have been
        built: its widgets (tactical.total and friends) exist only after
        BuildWindow(). The repaint now asks _G.NearbySpyWindow, and
        TacticalUpdate itself returns early while its widgets are missing, so any
        caller running before the window was opened is harmless. A real failure
        inside the update still reaches chat.

    1.5.1 (dev, 2026-11-09) — peer channel observability:
      - the peer path had no logging at all: /nspy debug turned on chat output for
        /who scanning and errors only, while queueing, sending and receiving were
        silent, and peerStats lived in memory, so a logout erased every trace of
        channel activity. The channel could carry traffic for hours and leave no
        evidence in SavedVariables.
      - every peer event is now logged through D(), i.e. into chat only in debug
        mode and always into the SV ring: queued (name, class, level, game,
        queue depth), sent, expired before send, queue-full drop, send error,
        "channel not joined" (once a minute, not on every mouse click).
      - inbound: accepted records are logged as `new` or `merged`. A valid packet
        that only refreshed a known player is the real proof the channel is
        alive — such rows keep their original source, so source="peer" never
        appears for them and the previous build could not tell the two apart.
      - rejections are logged once per session with the reason: protocol, game
        mismatch, realm mismatch (both spellings printed), field count, bad
        name/class/level/race/faction, rate limit. A realm-name mismatch was the
        one failure mode that silently discarded every packet from other users.
      - peer counters are snapshotted into db.debug.peer on every event and
        survive logout; `/nspy peer` prints the current session plus the previous
        one (sent/received/merged/seen/valid/rejected/channel/lastSender).
      - CHAT_MSG_CHANNEL_NOTICE is logged (raw args, one line per notice): join
        and leave notices name the addon users actually sitting in
        nearbyspydata, which is the only reliable answer to "is anyone there".
      - no protocol change, no change to the send cadence or payload; all
        inbound chat text is escaped (control chars and pipes) before it reaches
        chat or the ring.
      - peer state that was three separate locals (peerIncoming, lastPeerSend,
        per-session reject set) is folded into peerStats: the main chunk had
        reached the Lua 5.1 ceiling of 200 locals and the new helpers pushed the
        file into a compile error ("main function has more than 200 local
        variables") that only a real 5.1 load reveals.
      - NEW: the player window gets a Peer filter (4th tile next to All/Fresh/
        New) and /nspy peer new prints the list. Both read peerAt/peerNew, which
        UpsertPlayer stores on the row itself, so the list survives a relog and
        answers "what did the channel actually deliver" instead of "what is in
        memory right now". peerNew marks rows first learned from a peer; a peer
        refresh of an already-known player sets peerAt only and keeps the
        original provenance. In the Peer list the CONTACT column shows the
        packet arrival time (peerAt), because lastSeen belongs to our own
        sighting and would be misleading there.
      - NEW setting "Accept other realms" (db.peerAllRealms, on by default), next
        to Peer sharing in the settings window. On: foreign-realm packets are
        accepted and the row carries the realm (short dim tag by the name, full
        realm in the tooltip). Off: such packets are rejected before they touch
        the database, ordinary rows keep flowing, and foreign rows accepted
        earlier are hidden from every filter and from the Peer counter. Nothing
        is deleted — turning the flag back on brings them back. The export obeys
        the same flag: parse_nearbyspy.py drops peer_foreign rows while
        db.peerAllRealms is false, so the site never receives data the owner
        decided not to collect.
      - BUGFIX: our own packet comes back through the channel as a normal chat
        message, and it was counted as a received peer record — the live save
        showed merged=1 right after the first send, with the "peer" being the
        player we had just reported ourselves. Self-echoes are now recognised by
        the speaker's name and never touch the database or the counters; they get
        their own `selfEcho` counter so the echo is visible instead of confusing.
      - prime time is a per-realm number and is now labelled as such: two realms
        of one cluster peak at different hours, so the heat title carries its
        scope ("PRIME TIME — CAMWOW EU5 Realm 1 PvE" or "— All realms"). When the
        data module has no slice for the player's realm (an older NearbySpy_Data,
        format 1, or a realm added after the weekly datapack) the aggregate is
        still drawn — better than an empty panel — but the line under the
        snapshot names the realm that has no slice, instead of quietly mixing
        realms behind a title that reads like this realm.
      - NEW protocol N3: the packet now carries the place — zone id (a number,
        language-independent), localized zone name, and map coordinates x/y
        (12 fields instead of 8). N2 stays accepted in both directions, so an
        un-updated client keeps working. A place is stored only when it does not
        contradict our own sighting: a peer fills an empty zone/position of a
        known row but never overwrites one we observed ourselves.
      - packet size: the client caps a chat message at 255 bytes, and #s in Lua
        counts bytes (a Cyrillic zone name costs two per character). The payload
        is built against a 240-byte budget and degrades in a fixed order — zone
        name first, then coordinates — instead of being dropped whole.
      - BUGFIX found by the new test: `observed` is true for peer packets as well
        (it means "not a profile-only row"), so a peer packet overwrote the zone
        and coordinates we had seen ourselves. Place writes in the observation
        branch are now restricted to non-peer sources.
      - BUGFIX: the gate read `not db.peerAllRealms`, so a SavedVariables file
        without that key (every file written by an older build — the live one
        showed no key at all) meant "off" and would silently drop every foreign
        packet after an upgrade. Only an explicit false disables the setting now.
      - the realm of a foreign peer row is shown as a short dim tag next to the
        NAME (PeerRealmTag drops only the shared cluster prefix, so
        "CAMWOW EU4 Realm 6 PvP" becomes "EU4 Realm 6 PvP"), full realm in the
        tooltip. The ZONE column keeps showing zone and nothing else: peer
        packets carry no position or zone at all, so such a row honestly shows
        "?" there.
      - the channel turned out to be cluster-wide, not realm-local: on 09.11.2026
        a packet arrived from CAMWOW EU4 Realm 6 PvP while we sit on CAMWOW EU5
        Realm 1 PvE. Foreign-realm packets are now ACCEPTED instead of rejected
        and the row is marked (peerRealm = the reporting realm, peerForeign when
        it is not ours, counter peerStats.foreign). Records keep their own realm
        in the key, so two realms never overwrite each other, and a received
        record is still never re-queued, so nothing is relayed further.
      - BUGFIX: PeerSync fed GetChannelName() straight into tonumber(), and that
        API returns TWO values (id, display name) — the name landed in the BASE
        argument, so every peer event died with "bad argument #2 to 'tonumber'"
        inside the chat handler's pcall and no counters were ever saved. The
        first packet the channel delivered (09.11.2026 12:45) hit exactly this.
        The id now goes through a local, which keeps one value.
      - debug.err entries are stamped in debug.errAt: the map persists in
        SavedVariables, so an old failure used to read exactly like a fresh one.

    1.5.0 (dev, 2026-11-08) — world data collection (vendors + fishing):
      - vendors: on MERCHANT_SHOW the merchant window is snapshotted into
        db.world.vendors — npc GUID and name, zone, and EVERY item with its
        name, numeric item class/subclass, quality, max stack and price in
        copper. Recipes are not filtered here: the site shows them by
        classID 9, and filtering in the addon would lose the rest of the
        vendor's stock. Key is the creature GUID, so the same vendor found in
        two zones stays one record; a repeat visit updates counters instead of
        duplicating rows.
      - coordinates: a vendor row keeps its own point on the zone map — the
        position of the NPC itself (C_Map.GetPlayerMapPosition accepts any
        unit), falling back to the player's position, which stands at the
        counter. A fishing row keeps the point of the LAST catch in that zone
        (rows are aggregated per zone+item, so one fresh point instead of a
        growing list of every catch). Values are 0..1 like the player
        coordinates. A 0/0 reply is treated as "no data": the field stays
        empty rather than placing the marker in the map corner.
      - item names for items the client has not cached are NOT taken from the
        tooltip placeholder ("Retrieving item information"): a known item always
        renders a multi-line tooltip, so an empty second line means the name is
        genuinely unknown — it stays empty and is filled on a later visit
        instead of writing the placeholder into the database.
      - race slices in /nspy who use exactly ONE name per race, and only in the
        client's own language. Two sources of duplicates were killing half the
        race queries: UnitRace returns the race name with the unit's GENDER, so
        db.learn held "Орчиха"/"Гномка"/"Дворфийка" next to "Орк"/"Гном", and
        the cumulative table also kept the other client locale ("Orc",
        "Tauren"). The saved scan queue in SavedVariables showed it plainly:
        race="Orc" + race="Орк", race="Tauren" + race="Таурен" for one level —
        five queries where three were needed. Standard races now take the
        canonical name only; custom races take the spelling the server itself
        returned in raceStr (learn.whoName), because that is the form it accepts.
      - races can be cross-faction: the faction is now learned as a SET, not as
        one value per race. Skyborne was remembered as Alliance after the first
        sighting, so a Horde scan never asked р-"Небеснорожденный" and lost a
        whole race of coverage; and because /who entries derived the faction
        FROM the race, a Horde Skyborne was stored on the site as Alliance.
        Known classic races keep the deterministic reference table, custom races
        use the learned set, and a race seen in both factions is scanned by both.
      - units whose name the client does not expose are skipped: UnitName
        returns the localized placeholder ("Неизвестно"/"Unknown"), which used
        to land in the database as a player named "Unknown".
      - new scan mode `/nspy who speed`: a three-tier funnel instead of a full
        census, descending from the top. Tier 1 is level bands of 10 (51-60,
        41-50, … 1-10). When a band hits the server's 50-row cap it expands into
        its 9 classes, and each class slice keeps ITS OWN band (class × 51-60,
        not class × 1-60). A capped class slice then expands into races of that
        same class and band. That is the depth limit — the slice is accepted as
        is. Class and race lists are sorted so a resumed queue after /reload is
        identical between runs, and tier/kind are persisted with the queue.
        Tier 3 also respects real class×race combinations: a race gets a slice
        only if that class has actually been seen with it (druid exists for far
        fewer races than warrior). The table is learned from observed players
        rather than hardcoded, because this server is not classic — Dwarf shaman
        and paladin, Undead paladin, Skyborne druid all exist here. A race with
        too few observations is never filtered out, otherwise the scan would
        never ask for a pair it has not seen and could never learn it.
        The canonical spelling of a custom race now prefers the male form
        ("Небеснорожденный", not "Небеснорожденная"), matching raceStr in /who
        replies; the check looks for the feminine ending at a word boundary, so
        a leading adjective like "Небеснорожденная из Высшего ордена" is caught.
      - /who entries whose race cannot be resolved no longer lose their faction:
        /who only ever returns the player's own faction, so faction falls back to
        PlayerFaction(). Such entries are now counted in debug.raceUnresolved /
        debug.raceEmpty, and the first one without a race is dumped in full to
        debug.whoSampleNoRace — without that dump the missing race names are
        invisible and every one of those players also lost its faction.
        SCAN.SPEED_MAX caps the number of expansion slices: without it a dense
        server could turn the "surface layer" into more queries than the full
        ~110-query census.
      - hub window fits Cyrillic labels: cells grew from 96x78 to 110x96 (window
        228x252 -> 260x274) and every label, description and the status line now
        carry an explicit SetWidth. Without a width a FontString does not wrap —
        it has no clipping either — so longer Russian text (and German) simply
        ran outside the cell and over its neighbour.
      - minimap button ring sits exactly on the icon: MiniMap-TrackingBorder is
        NOT a symmetric texture — the visible ring is drawn offset toward the
        texture's top-left corner, so anchoring it CENTER put the TEXTURE's
        centre on the button centre and the ring drifted right-down. Now it
        follows the LibDBIcon geometry (ring 53x53 at TOPLEFT, background 20x20
        at (7,-5), icon 17x17 at (7,-6)), which is what Blizzard's own offset of
        11,-12 for a CENTER anchor implies.
      - minimap button icon grew from 17x17 to 24x24 (background 20x20 -> 26x26);
        all three elements are centred by formula on the ring's visible centre
        (15.5, -14.5), so the size can change without the ring drifting again.
        24 is the practical ceiling — the ring's inner opening is about 25px.
      - minimap icon is semi-transparent (alpha 0.85) so it reads as if it sits
        under the ring's glass. Button layout now matches Mastercraft and
        LibDBIcon exactly: 31x31 frame at level 8, background and icon on CENTER
        anchors, ring 53x53 on TOPLEFT with no offset. That works because the
        drawn ring is NOT centred in its texture — Blizzard's own CENTER offset
        of 11,-12 puts it at (15.5, 14.5) from the texture corner, which equals
        the centre of a 31px button. An earlier attempt computed that offset as
        10px, which put the ring 6px off the icon ("ring is offset").
      - the icon sits 1px right of centre inside the ring: the drawn rim is not
        uniform in thickness, so the mathematical centre reads as "icon is too
        far left". The value is inlined at the SetPoint call — no separate
        constant or setting, one pixel does not need a knob. The dark background
        stays exactly centred.
      - the minimap icon is now 27x27 and CIRCULAR: the source art is a fully
        opaque 64x64 square (no alpha, no padding), so enlarging it showed the
        picture's own light edges as a frame on the sides and pushed its corners
        past the ring. A round mask (Interface\CharacterFrame\
        TempPortraitAlphaMask via Texture:SetMask, used ~80 times in FrameXML)
        cuts the corners; the dark background gets the same mask and size so no
        square corners peek out from underneath. 30 filled the ring's opening
        completely, so the icon now leaves a small gap to the rim. Where SetMask
        is unavailable the icon falls back to 24x24 and the background to 23x23,
        which stay inside the ring.
      - fishing: on LOOT_OPENED the catch is recorded only when IsFishingLoot()
        is true (corpse loot never reaches the database) as zone+item rows with
        a per-zone catch counter, so "what fish bites where" is measurable.
      - /nspy world prints vendor/item/fishing counts.
      - SavedVariables caps: 300 vendors, 200 items per vendor, 4000 items
        total, 3000 fishing rows; dropped entries are counted in debug.
      - API facts measured on the live 1.60.1 client (not assumed): GetItemInfo,
        GetMerchantItemInfo and GetLootSlot DO NOT EXIST; item data comes from
        C_Item.GetItemInfoInstant / GetItemNameByID / GetItemInfo, itemID from
        GetMerchantItemID. GetMerchantItemLink returns nil until the row is
        drawn by a tooltip, so links are not used. Price: the merchant
        MoneyFrame first, then C_MerchantFrame.GetItemInfo; when neither
        answers the price is left empty instead of guessed.
      - the whole world-data block is guarded: every client call goes through
        pcall, a missing C_* namespace degrades to an id-only record.

    1.5.0 — step 0 (API probe):
      - new /nspy probe: writes into SavedVariables which client functions
        actually exist (GetMerchantNumItems, GetMerchantItemLink,
        GetMerchantItemID, GetItemInfo, GetLootSlotInfo/Link, IsFishingLoot,
        UnitGUID/UnitName("npc"), ...) together with the client build, locale,
        realm and zone. FrameXML is not shipped with the client (only
        Interface/AddOns), so the API had to be measured in game instead of
        assumed from another era's documentation.
      - with the probe on, MERCHANT_SHOW and LOOT_OPENED are sampled: the first
        vendor/loot windows (4 each, 8 items each) are recorded with every
        return value IN ORDER (v1..vn). Signature order differs between builds,
        so the probe stores raw returns and the field meaning is decided from
        the data, not from a guess.
      - itemID is taken from the item link (|Hitem:NNNN:...), because
        GetMerchantItemID may be missing in this client; a client error inside
        a probed call is stored as numItemsErr/err instead of raising.
      - /nspy probe off stops sampling but keeps what was recorded.
      - no player-data code touched; probe handlers return immediately while
        the probe is off.

    1.4.1 (dev, 2026-11-05):
      - an unfinished /who scan now survives /reload and a relog: the remaining
        queue is mirrored into SavedVariables on every step, so the next
        /nspy who continues where the previous one stopped instead of starting
        from the top level again. A plan older than 12 hours, or of a different
        kind (who vs whoclass), is discarded; /nspy who new forgets the saved
        plan and starts fresh. Progress counters carry over too.
      - the settings window has a checkbox for the minimap icon, so hiding it
        no longer needs a slash command. The flag is stored inverted
        (minimapHide) so saved variables from earlier versions keep working,
        and turning it back on builds the icon if it never existed.
      - /nspy who now walks the levels FIRST, TOP-DOWN: the plan starts at the
        level cap (60) and goes down, and classes are the inner loop of an
        overfull level. An interrupted run therefore keeps the endgame part of
        the server. Counts come from the local database, so each class keeps its
        range open while the running total stays under the 50-row cap — on the
        live population that is ~110 queries for full coverage instead of 195.
        Sparse levels are taken whole, without a class filter.
      - a class + single level that is still overfull (10 such pairs: PALADIN
        levels 1-9, HUNTER level 10; max 78 players) is now split by RACE, so the
        last gap in coverage closes instead of silently losing rows.
      - the scan summary reports both split counters (by level, by race).
      - /nspy who, /nspy suggest and /nspy whoclass now narrow a crowded class
        slice by LEVEL RANGE instead of taking the first 50 rows and moving on.
        A class slice that hits the 50-row reply cap is halved recursively until
        every part fits (level + class always fits: the densest class-level pair
        on the surveyed realm holds 41 players), so a level-dense class no longer
        silently loses half its population. The lower half of each range is
        scanned first, so stopping the scan early still covers the levels most
        players occupy, and repeating the command stops it at any point.
      - the scan stops a branch instead of burning clicks if a narrower level
        range returns exactly the same players as its parent (that means the
        server did not apply the range); the scan summary reports how many splits
        were made and whether the level filter was ignored.
      - the /who scan ceiling is now the game's level cap (60 on Forever and
        classic, 80 on retail) instead of the highest level in the local
        database rounded up to 10. That rule deadlocked: the ceiling was
        derived from data the scan itself collects, so it could never reach a
        level the scan had not already found (it sat at 30 while the cap was
        60). Level ranges are still worthless on Forever — the server ignores
        them — but the ceiling no longer hides higher-level players if it
        starts doing so.

## Public releases

    1.5.1 (2026-11-09) — released to CurseForge:
      - delta against 1.4.0 (the previous released build); the detailed
        internal history of 1.4.1 / 1.5.0 / 1.5.1 stays in the dev section
        above. Bugs introduced and fixed inside this cycle (they never reached
        users) are deliberately absent from the public changelog: the GetChannelName
        multi-return in PeerSync, the self-echo counted as a received record, the
        peerAllRealms nil-as-off gate, and the peer packet overwriting our own
        zone/coordinates.
        1.4.1: an unfinished /who sweep survives /reload; minimap checkbox in
          settings; the sweep walks levels top-down; a crowded class slice is
          split by level range, then by race; the ceiling is the game's level cap.
        1.5.0: world data — vendor stock with prices and fishing catches per zone
          (/nspy world); /nspy who speed (level bands, then classes, then races);
          one spelling per race in the client's language, cross-faction races,
          unresolved-race entries keep their faction; hub window fits Cyrillic;
          minimap button rebuilt to the LibDBIcon geometry with a round masked icon.
        1.5.1: peer counters and per-reason rejections persisted in SV, the Peer
          filter and /nspy peer new, protocol N3 with zone and coordinates, the
          "Accept other realms" setting (the channel is cluster-wide), prime time
          labelled with its realm scope, and the bundled NearbySpy_Data snapshot
          refreshed to the current realm.
      - the release zip carries a fresh NearbySpy_Data snapshot; the data addon
        is also published as a separate CF project, versioned by snapshot date.

    1.4.0 (2026-11-05):
      - the release zip carries runtime files only: .pkgmeta uses shell-style
        globs and "tests/" never matched anything, so every zip since 1.3.x
        shipped the whole test suite. The pattern is now "tests" (no trailing
        slash), verified with a local packager run.
      - an offline guildmate is no longer counted as a meeting: the roster's
        online flag (9th return of GetGuildRosterInfo) was discarded, so every
        roster refresh refreshed lastSeen/encounters of every guildmate,
        including players who were offline. Roster data now enriches the
        profile (class/level/zone) of an offline player without claiming a
        sighting, and such records are not uploaded until the player is
        actually met.
      - the player list stops at exactly 500 rows: the counter was incremented
        before the limit check, so 501 matching records reported 501 and sized
        the scroll list for one row that was never drawn.
      - a locally observed race/faction now corrects a value that came from
        another installation: previously race and faction were only filled when
        empty, so a wrong peer value stayed forever while class and level were
        already being corrected.
      - /nspy server reads datapack format 2: when the snapshot carries a
        per-realm slice (games[game].realms[realm]), the window shows the
        CURRENT mega-realm (e.g. "Classic Beta PvE 2") instead of the
        whole-game aggregate; the title names the scope ("Server census —
        Classic Beta PvE 2", or "All realms" on the aggregate fallback).
        Older format-1 datapacks keep working unchanged.

    1.3.2 (2026-10-20):
      - the help window follows the interface language override and relabels
        on every show, so switching the language no longer needs /reload;
        /nspy peer replies are localized in all six locales.
      - system messages the client hands over as secret values are no longer
        run through string operations: the throttle handlers bail out on
        inaccessible strings before touching them. The peer channel join treats
        "channels not ready" right after login as a retry instead of a failure.
      - the one-time name migration keeps genuine cross-realm records intact
        (only unit-sourced names are merged) and drops nameless records with a
        debug counter instead of crashing.
      - peer data can no longer overwrite a class/level observed from
        unit/who/guild; peer updates only fill missing fields.
      - the bottom status and hint lines no longer clip, and the removed
        whoclass/whorace commands are gone from the help window.

    1.3.1 (2026-10-18):
      - settings window (hub tile 4 or /nspy settings): peer sharing checkbox
        (same switch as /nspy peer on|off), interface language selector
        (Auto = follow the client, then en/zh/ru/de/fr/ko; the settings window
        relabels live, other windows rebuild after /reload) and heatmap
        timezone selector (Auto = system clock, or fixed UTC-12..UTC+14 for
        the prime-time map in /nspy server). Selectors are default-style
        dropdowns with left/right arrow steppers (classic list / ASCII
        stepper fallbacks when a template is cut on the client).
      - overlapping windows no longer blend into each other: every window has
        its own solid underlay (the template background renders transparent
        on some clients), plus click-to-raise and distinct frame levels.

    1.3.0 (2026-10-17):
      - new /nspy server window: server census from the companion data module
        NearbySpy_Data (weekly aggregated snapshot, rolling release
        datapack-latest) — prime-time heatmap (7 days x 24 hours), class
        distribution, faction split and top zones, with the snapshot date and
        a staleness hint. Works in all 6 locales; without the data module the
        window shows an install hint instead.
      - companion addon NearbySpy_Data added to the repository: its lua is
        rendered by the RealmPulse site from the shared database and refreshed
        weekly by CI (the addon itself has no HTTP access).
      - peer sharing is now ON by default for new/untouched installs (opt-out:
        /nspy peer off); an explicit off setting is respected.
      - hub menu window (/nspy menu or the new minimap button): a grid of
        section tiles — player list, server census, help, peer toggle — with a
        status line (records, peer state, version).
      - minimap button (standalone, no LibDBIcon): drag along the minimap ring
        (angle saved in SV), left-click opens the hub, right-click the player
        list; /nspy minimap shows/hides the button.

    1.2.3 (2026-10-16):
      - main-window texts now use the client's own font object (GameFontNormal)
        instead of an explicit SetFont on a file path: measured on the ruRU
        beta, file-path fonts render nothing during the first 10-20 s after a
        cold login (FRIZQT__.TTF never renders at all), while the client font
        draws Cyrillic from second zero — no more invisible text on the first
        open. The bundled NearbySpySans.ttf is removed (it had no zh/ko glyphs
        anyway; zhCN/koKR clients get their native fonts automatically).
      - window strings no longer use glyphs missing from the client font
        (≤, ·, ●, ×, en/em dashes, Ø) — replaced with ASCII equivalents in all
        6 locales; chat output is untouched (the chat font has full coverage).
      - top-class bars moved to the native StatusBar widget; the row value now
        shows count + share of all players ("3026 (15%)") inside the bar (XP-bar
        style, light text with shadow). The top classes are nearly equal
        (3026/2992/2894), so a plain max-relative bar looked flat.

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
