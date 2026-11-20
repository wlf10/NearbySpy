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

## NearbySpy 1.5.7

### New: a journal of your own character

- `/nspy me` prints your character's own record: playtime (this session, today,
  last 7 days, all time), the zones you spent that time in, how often you
  entered them, your level and XP, level-ups, deaths, money — and the players
  you met, split into "this session" and "new to the database".
- Playtime is counted while you play, in one-minute steps, so a crash or a
  force-quit cannot add your offline hours: the next login closes that session
  where it actually stopped and marks it as cut short.
- `/reload` neither adds sessions nor invents seconds.
- The journal is a compact, bounded section of the same SavedVariables file, so
  it travels to the site with the upload you already make. 40 sessions, 30 days
  and 25 zones per character are kept — the oldest goes first, the file cannot
  grow without limit.

### Fixed: two silent errors on secret strings

- A server message delivered as a secret value made the throttle detector throw
  before it could log anything, so the message text was lost. The value is now
  checked before it is compared.
- The peer name formatter had no such check at all and failed on the same kind
  of value; it now shows the name as `[secret]` instead of throwing.

## NearbySpy 1.5.6

### Fixed: no more "Interface action failed because of an AddOn"

- The client allows a channel send only when it comes from a real hardware event.
  The addon used to try on movement as well, and that is exactly where the dialog
  appeared: thousands of attempts a session, not one of them accepted. Sending on
  movement is gone; a click in the world still works and remains the trigger.
- The dialog itself is hidden as well, so a refusal never interrupts play.
  A block belonging to another addon is left alone — that dialog is not ours.

### Fixed: a record waits ten minutes for its turn instead of two

- After a /who sweep the queue is longer than two batches could clear at the
  channel's pace, so records expired unsent while still waiting their turn —
  five of them went in a single second in one recorded session. Ten minutes
  covers the burst and still keeps the queue finite.

### Improved: the addon no longer loses track of its own errors

- A failure was recorded only if that part of the addon had never failed before,
  so one old entry hid every later error of the same kind — which is why an error
  in the log could not be found afterwards. Every failure is counted now, with
  its time and its latest text, and `/nspy count` prints them.
