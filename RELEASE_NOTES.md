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
