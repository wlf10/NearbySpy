# NearbySpy

A WoW addon that passively records **players you encounter** into SavedVariables.
Install and play — nothing to click. To feed the statistics site (RealmPulse,
foragerstats.com) upload your `SavedVariables/NearbySpy.lua` file there after
logging out; the addon never uploads anything to a web server. Optional in-game
peer sharing is on by default (`/nspy peer off` to disable).

## What it does

Passive collection (the main mode, works on its own):

- **Target, focus, mouseover** — everyone you look at.
- **Nameplates** (`nameplate1..40` + a 2-second tick) — exact coordinates;
  in the current beta nameplate events are silent, kept in case they return.
- **Party/raid** — the full roster on changes.
- **Guild** — roster (level, class, zone of every guildmate), refreshed every 10 min.
- **Chat** (`CHAT_MSG_SAY/YELL/CHANNEL`) — the speaker's name from /say, /yell
  and channels (trade, local defense, etc.) without class/level/zone: city
  channels show players the other sources never reach.

For each player it stores: name-realm, class, level, faction, race, zone/map,
coordinates, first/last seen time, encounter counter (a new encounter = a gap
longer than 10 minutes), source (unit/who/guild/chat).

Everything is written to `WTF/.../SavedVariables/NearbySpy.lua` (the global
`NearbySpy` table).

## Assisted mode: /nspy suggest

Since build 1.60.1.70291 the server answers `/who` **only to a physical click**
(a hardware gate — programmatic who is dead). So it works like this:

1. Type `/nspy suggest`.
2. The addon types the next query into the who search box (splitting
   overflowed replies by class) and tells you in chat to click the button.
3. You click the search button — the addon collects the reply and types the
   next query.
4. Stop: type `/nspy suggest` again.

Your only job is clicking the search button — no typing required.

## Installation

1. Copy BOTH folders — `NearbySpy` and `NearbySpy_Data` — into
   `World of Warcraft/_classic_beta_/Interface/AddOns/`. `NearbySpy_Data` is the
   weekly census snapshot behind `/nspy server`; without it the other windows work
   normally and that one window says the module is missing.
2. Enable the addon on the character select screen (if flagged "out of date" —
   tick "Load out of date add-ons").
3. Enter the game — no startup chat message unless debug mode is enabled.
   Existing `announce` settings are preserved; `/nspy announce` toggles encounter messages.

## Commands

| Command | What it does |
|---|---|
| `/nspy` (or `/nearbyspy`) | window listing recorded players |
| `/nspy help` | in-game command reference window |
| `/nspy suggest` | assisted /who mode: the addon types the query, you click search |
| `/nspy count` | counters + debug summary |
| `/nspy announce` | toggle "first seen nearby" chat messages |
| `/nspy debug` | debug mode: on → logs (digests, scan progress, gate blocks) in chat; off → stealth mode, logs only to the SV ring |
| `/nspy peer on` / `off` | opt in/out of in-game channel sharing; on by default |
| `/nspy peer new` | list what arrived over the channel (persisted, survives relog) |
| `/nspy peer` | channel and queue status |
| `/nspy reset` | clear the database |
| `/nspy server` | server census window (ships with the NearbySpy_Data module) |
| `/nspy menu` | hub menu window (also: left-click the minimap button) |
| `/nspy minimap` | show/hide the minimap button |
| `/nspy settings` | settings window (peer sharing, interface language, heatmap timezone) |

## In-game peer sharing (on by default)

The channel is joined automatically on login (`/nspy peer off` opts out).
`/nspy peer on` re-joins `nearbyspydata` on the current realm. Only the first
locally discovered record with a known class and level is queued; subsequent
updates and records received from peers are not sent.

Message format, protocol **N3** (12 fields, `;`-separated):

```
N3;game;realm;name;class;level;race;faction;zoneId;zone;x;y
```

`zoneId` is the map id (a number, identical in every client language), `zone` is
the localized zone name as the sender saw it, `x`/`y` are map coordinates 0..1.
`0`, `?` and `-` mean "the sender did not know" — nothing is invented. No chat
text is ever sent, and the packet is capped at 240 bytes (a chat message is
limited to 255 bytes by the client). An oversized packet loses the zone name
first, then the coordinates, instead of being dropped whole.

The older **N2** format (8 fields, no place) is still accepted, so a client that
has not been updated keeps working in both directions.
Queue limit: 60; age limit: 120 seconds; at most one send per 10 seconds,
on a mouse click. Messages are hidden from ordinary chat windows but visible
to channel members and the game server. Peer data is untrusted and can be
inaccurate. `/nspy peer off` leaves the channel and clears the pending queue.
There is no web-server upload. The channel itself is shared by the whole
cluster, so packets from other realms can arrive too: they are accepted and
marked with their realm unless you turn off *Accept other realms* in the
settings. Received records are never re-sent.

### Diagnosing the peer channel

`/nspy debug` prints peer activity to chat (and always into the SavedVariables
ring, so it can be read after logout even in stealth mode):

- `Peer queued: Name (MAGE 20, forever) q=3` — a record passed every gate and
  waits for a mouse click;
- `Peer sent: Name q=2 sent=7`, `Peer send blocked: channel nearbyspydata not
  joined` (once a minute), `Peer send error: …`;
- `Peer in: Name MAGE 20 (Alliance) new` / `… merged` — `merged` means a valid
  packet refreshed a player already in the database: that is the proof the
  channel is alive, because such rows keep their original source;
- `Peer in: … [realm=CAMWOW EU4 Realm 6 PvP]` — the realm suffix appears only
  for another realm; the channel is cluster-wide, so such packets are kept and
  marked `peerRealm` / `peerForeign` on the row;
- `Peer rejected: bad level` (and the other gate names) — logged once per
  session, never per packet;
- `Channel notice: …` — join/leave notices for the channel, i.e. who is in it.

`/nspy peer` prints the live counters plus the counters of the previous session
(persisted in `db.debug.peer`).

The player window has a **Peer** filter (4th tile, next to All/Fresh/New) and
`/nspy peer new` prints the same list in chat. Both read `peerAt`/`peerNew`,
which are stored on the player row, so the list survives a relog:

- rows first learned from a peer carry `peerNew` (tag `new` in the list);
- a packet that only refreshed a player we already knew sets `peerAt` alone
  (tag `upd`) — that is the honest answer to "is the channel alive";
- the CONTACT column in the Peer list shows the packet arrival time, not our own
  last sighting;
- the settings window has **Accept other realms** (`db.peerAllRealms`, on by
  default). Off rejects foreign packets at the gate and hides the rows already
  stored (nothing is deleted), and the export skips them too;
- a row from another realm of the cluster gets a short dim tag next to the name
  (`Im Lapiz EU4 Realm 6 PvP`), with the full realm in the tooltip. The ZONE
  column always means a location: peer packets carry no zone, so those rows show
  `?` there.

## Sharing the data

File: `WTF/Account/<ACCOUNT>/SavedVariables/NearbySpy.lua`
(written on logout or `/reload`).

## Limitations (honest list)

- Programmatic `/who` is dead since build 1.60.1.70291 — physical click only (see suggest).
- `/who` shows only your own faction — full coverage needs characters of both factions.
- Sees only what the client exposes: mouseover/target within visibility range,
  combat log participants, your own guild only.
- Cannot see stealthed players (the Blizzard API doesn't expose them).
- Level is unavailable from the combat log — those entries have class/race but no level.

## Localization

English (default), Simplified Chinese, Russian, German, French, Korean.
The window uses the client's own font, so every client locale renders natively.

## License

MIT.
