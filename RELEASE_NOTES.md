1.6.1

- Fixed: gear and talent snapshots were dropped by every receiver when the
  sending client did not report its realm. The realm field came out empty and
  the packet was rejected as unreadable, so sharing silently delivered nothing
  while the sender still counted it as sent. Records with an empty realm also
  landed in the database twice, under a name plus an empty realm.
- Fixed: a realm that the client reports as an empty string is no longer taken
  at face value; the last known realm is kept, and a one-time pass repairs
  records already saved without one.
- Improved: packets with an empty realm are now accepted and stored under the
  reading client's realm, marked as such, so data from older clients is not
  lost. Updated clients send the realm properly and carry no mark.

## NearbySpy 1.6.0

### New: gear and talent builds of the players you meet

- The addon now silently inspects players you encounter — target, focus,
  mouseover, group, nameplates — and keeps their equipped items and talent
  build next to their name. No window is opened and nothing is clicked: the
  client is asked directly, once per player, with a pause between requests.
- Items are stored as ids, not links, because a link only resolves for items
  already in the client cache. Anything unknown is resolved later, on demand.
- A request the server never answers is recorded as a timeout, never as
  "inspected, empty". The two mean opposite things.
- The snapshots travel to the site with the SavedVariables upload you already
  make. They are bounded (2000 snapshots, oldest dropped first), so the file
  cannot grow without limit.
- `/nspy gear` shows the counters, `/nspy gear on|off` turns collection off,
  and `/nspy peer gear` does the same for sharing.

### New: gear and builds are shared over the peer channel

- A second packet type carries a snapshot between addon users, so a player
  someone else inspected reaches you too.
- Equipment is packed as a bit stream: a bitmap of the filled slots, the item
  level, then one 20-bit id per item. Measured on 849 real snapshots the text
  form took 115 characters and this one takes 51, which is what keeps the
  worst real snapshot inside a single channel message.
- The talent import string is sent as-is: it is already built from a 6-bit
  alphabet, so re-encoding it would return the same bits.
- A snapshot from a peer is never re-sent, and an incoming one is applied only
  when it is newer than the one already stored — a stale packet cannot
  overwrite your own inspection.
- `/nspy peer seed N` re-queues N snapshots you already collected.

### Improved: two and a half times more records per channel message

- The realm now travels as a one-byte code instead of its full name in every
  message, the observation time as base36 instead of ten digits, and a zone
  name is announced once per zone instead of in every record.
- On live data a message carries five records where it used to carry two, at
  the same interval between sends. The older formats are still accepted, so a
  client that has not been updated keeps working in both directions.
- `/nspy peer proto` switches sending to the text format if the channel still
  has old clients.

### Improved: item names and diagnostics

- The item dictionary is keyed by client language, and the per-run ceiling
  covers the whole dictionary instead of stopping early.
- `/nspy count` shows what the SavedVariables file actually occupies.
- `/nspy prune` optionally drops records not seen for N days. It is OFF by
  default and deletes nothing until you enable it.

### Fixed: the "Interface action failed because of an AddOn" popup

- Only a click in the world is a real hardware event for the client. The addon
  also tried to send on target changes, spell casts and loot rolls: in one
  session that was 10 422 attempts, 134 refusals and not a single send, and
  every refusal raised the dialog. Those triggers are gone; the world click
  stays and still works.
- The client does not always name the blocked addon — hundreds of blocks
  arrived as `UNKNOWN()`, so our own refusals were filed as somebody else's
  and the dialog was never hidden. An unnamed block within a second of our own
  send is now treated as ours and the dialog is suppressed.

### Fixed: peer counters that lied

- `seen` stayed at zero while the channel was delivering: the call site leaked
  the channel's language name into the "came from a batch" argument, so the
  message counter never ran. The counters now agree.
- Gear counters, the batch counter and the throttle counter never reached
  SavedVariables at all, so every gear diagnostic disappeared on logout.

### Fixed: gear sharing starved

- Gear used to be sent only while the meeting queue was empty. With a
  hardware-gated sender that queue rarely empties, so in a live session it
  never sent anything while its own queue filled up and evicted snapshots.
  Sending turns are now shared: gear takes every third one, every second when
  its queue is full, and immediately when the meeting queue is empty.

### Fixed: two silent errors on secret strings

- The chat handler compared the speaker with an empty string before checking
  whether the value was readable, which throws on a secret value. The check
  now runs first — also for map names on the zone lookup.
- `/nspy debug` prints the age of each recorded error, so a fixed error stops
  looking live.

### Fixed: smaller repairs

- `/nspy who` no longer asks the server for class and race pairs that do not
  exist.
- Item tooltip lines are cut by characters instead of bytes, so a Cyrillic
  name is no longer split in half.
