# NearbySpy

A WoW addon that passively records **players you encounter** into SavedVariables.
Install and play — nothing to click. To feed the statistics site (RealmPulse,
wow.bitwolff.com) upload your `SavedVariables/NearbySpy.lua` file there after
logging out; the addon never uploads anything to a web server. Optional in-game
peer sharing is off by default.

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

1. Copy the `NearbySpy` folder into `World of Warcraft/_classic_beta_/Interface/AddOns/`.
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
| `/nspy peer on` / `off` | opt in/out of same-realm in-game channel sharing; off by default |
| `/nspy peer` | channel and queue status |
| `/nspy reset` | clear the database |

## In-game peer sharing (optional)

`/nspy peer on` joins `nearbyspydata` on the current realm. Only the first
locally discovered record with a known class and level is queued; subsequent
updates and records received from peers are not sent. Each message contains
game, realm, name, class, level, race and faction — not coordinates or chat text.
Queue limit: 60; age limit: 120 seconds; at most one send per 10 seconds,
on a mouse click. Messages are hidden from ordinary chat windows but visible
to channel members and the game server. Peer data is untrusted and can be
inaccurate. `/nspy peer off` leaves the channel and clears the pending queue.
There is no web-server upload and no cross-realm sync.

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
