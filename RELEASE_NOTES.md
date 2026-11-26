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
