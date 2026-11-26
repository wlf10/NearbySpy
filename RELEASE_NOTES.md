## NearbySpy 1.6.5

### Improved: sharing no longer waits for a click

- Every outgoing packet used to go through the chat channel, and the client only
  allows a channel message from a hardware event. On a live save, all 66 893 sends
  came from 66 893 clicks on the 3D world, while moving, casting, targeting and
  rolling produced 7 000+ attempts, no sends at all, and "action blocked" popups.
  The queue therefore sat at its ceiling permanently (60 waiting, 0 sent) and
  equipment snapshots were evicted in batches.
- Packets now travel as addon messages, drained on a timer at one message per
  1.2 seconds (the measured ceiling is about 65 per minute). The old transport is
  still there as a fallback: setting `peerViaAddon` to false brings it back.
- ⚠️ Compatibility: clients older than 1.6.5 will no longer hear you. They keep
  feeding your database, so nothing is lost in that direction, but your sightings
  reach them only after they update.

### Fixed: a queued request could be destroyed by the queue it was waiting in

- A database request is inserted at the head of the queue so it leaves first, and
  freeing room removed the head. In a capital the queue is at its ceiling almost
  always, so every new encounter deleted the request itself: two requests were
  made in a live session, none left, and the log said "dropped ?".
- Eviction now skips control packets and removes the oldest ordinary record, and a
  queue made only of requests refuses a new record and says so. The window for an
  answer grew from 3 to 15 minutes, because an answer joins the tail of the
  sender's queue and the queue drains one message at a time.

### Improved: the player window no longer stalls

- Each repaint made four full passes over the database (61 435 records): a sort
  costing 74 ms here and 242 to 606 ms in the client, plus 8 001 client API calls
  for 500 rows, sixteen per row. With seven places that repaint, switching tabs
  felt like a freeze.
- The latest-players list is now held in a buffer of 500 (binary-search insert,
  tail evicted, rebuilt once per session), the list and aggregates are cached for
  three seconds by the state of the selection rather than by a data version that
  changed on every record, and row text is written only when it differs.

### Changed: the realm, class and level filters are gone

- Filtering by realm, class and level now belongs to the site, which holds the
  whole database. The window shows recent encounters. The list gained the 32 pixels
  the filter row used to take.

### Changed: tab counters mean what the list shows

- They used to count the whole database (63 401) while the list is built from the
  last 500: the exchange tab said 953 above a list of 462 rows.
- "All" carries no number, because the size of the database is not a list.
  "Fresh" and "Peer new" show the length of the list, counted by the same
  selection that builds it. "New" shows how many new players the session has in
  total, even when only 500 fit.

### Improved: big counters are written short

- 20 257 reads as "20.3k". Up to a thousand nothing changes; above that come k, M
  and B with one decimal, a point rather than a comma, and a trailing ".0" is
  dropped. A value that would round to "1000k" steps up a unit instead (999 500
  reads as "1M"). Bar widths and stored values are untouched.

### Fixed: /nspy ask did nothing

- The command existed as `peer ask`, but there was no branch for `ask`, so the
  input fell through to the help window silently. The help itself never listed the
  command under any name, so the only way to learn about it was to read someone
  else's chat message.
- Both forms now reach the same branch, argument parsing lives in its own function
  so it can be tested, and the command is listed in the help in all six languages.

### Fixed: records learned from the channel never appeared as fresh

- Age was computed as now minus the last sighting, and a record that arrived from
  another client has no sighting of our own: its last-seen time is zero, so it
  looked fifty-six years old and never entered "Fresh". Age and ordering now use
  the sighting when there is one and the packet time otherwise.

## NearbySpy 1.6.4

### Fixed: a record's zone id now describes the zone its name says

- 362 records carried one zone's name together with another zone's id, and 7 015
  records had a name and no id at all. Since the window shows the name by id,
  those records showed the wrong area, and the wrong id travelled to the site.
- The cause: the guild roster and some /who replies give a zone as text only.
  The text was updated on every sighting, the id stayed from an earlier one.
- The id is now recomputed from the text whenever a source sends text alone, and
  a one-time pass repairs the existing database, always trusting the text (it is
  written by every sighting, the id only when a source has one). On a live save
  the pass corrected 362 records and filled in 7 015, raising zone id coverage
  from 85.6% to 97.4%. It runs once, in 128 ms, and is inert on the next start.

### Fixed: equipment snapshots from other clients were thrown away

- A snapshot packet and an encounter packet travel the sharing channel
  independently, and the snapshot frequently arrives first. The addon dropped it
  because there was no player row to attach it to yet: on a live save 19 of 44
  received snapshots were lost exactly this way.
- A snapshot now waits up to 15 minutes (200 names at most, oldest dropped first)
  and is attached the moment that player is recorded. The waiting snapshot never
  creates a player row on its own — a record without class and level would be
  worse than no record — and is never sent back into the channel.
- If a fresher snapshot already exists, the waiting one does not replace it.

### Fixed: snapshots could sit in the save file forever

- Snapshots are held in a ring, and eviction removes only what the ring lists.
  642 snapshots recorded before that ring existed were outside it and could never
  be evicted, so the file held more than its own limit allowed.
- They are now entered into the ring oldest-first, so they leave in the order they
  would have left had the ring tracked them from the start. The ring also holds
  12 000 snapshots instead of 6 000 — about six days of headroom if uploads stop,
  roughly 2.4 MB.

### Improved: the inspect queue serves what it takes

- A queued request older than 12 seconds describes a player who has already walked
  away, and it is dropped. At the pacing the client allows, that is 7 to 13
  requests of useful depth — so of 160 queue slots about 150 were dead weight that
  still made the queue report itself full. In one live session a third of the
  queue expired before being served.
- Expired entries are now swept before the queue is checked for room, and their
  player is released from the "already queued" list, so they can be inspected
  again later instead of never.
- A full queue now drops its OLDEST entry rather than refusing the newcomer: the
  newcomer is the player standing in front of you and is the next one served,
  while the oldest entry would never have been served at all.

### Improved: snapshots no longer stop after five minutes of play

- Snapshots per session were capped at 200, which at the client's pacing is about
  five minutes of play — after that no new encounter was inspected for the rest of
  the session, silently. The cap is now 600 (9 to 18 minutes of play), and both
  ways of hitting a limit are counted, so "the cap was reached" is no longer
  indistinguishable from "inspecting is off".

### Fixed: text could be cut in the middle of a character

- The addon trims long strings for its diagnostics by byte count, and a byte count
  does not know where a character ends. Six places in a live save held half a
  Cyrillic character, which makes the whole file invalid UTF-8: the site would
  show a replacement glyph instead of the tail of the name.
- Trimming now steps back to the start of an unfinished character and drops it, so
  the cut is always on a character boundary. Applied to every place that trims.

### Improved: 130 KB of a removed diagnostic left the save file

- A diagnostic probe that was removed from the addon in a previous version left
  about 130 KB of its output in the saved variables. Cleaning up after removed
  features only ever covered the addon's own diagnostic section, so this data at
  the top level stayed for good. It is now removed once, on the first start.
