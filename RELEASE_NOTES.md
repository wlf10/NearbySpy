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
