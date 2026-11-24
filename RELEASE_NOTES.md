## NearbySpy 1.6.2

### The saved-variables file and the client's memory are much smaller

- Records are now stored as a fixed layout instead of a table with a named field
  per value, and two fields that always duplicated another value were dropped.
  Measured on a real save of 53 570 players: the player section shrank from
  16.1 MB to 11.6 MB, so the file goes from 18.6 MB to about 14.2 MB.
- The memory the addon holds in the client dropped from 30.4 MB to 17.4 MB on
  the same save. That win came from crossing a threshold, not from trimming
  bytes: Lua sizes a table's array part to a power of two, so a record with 17
  to 32 slots costs the same as one with 17. The layout now uses 16.
- Saves written by 1.6.1 stored every field by name and are larger still, so the
  reduction there is bigger than the numbers above.
- Coordinates are no longer stored per player. They were the observer's position
  at the time of the encounter, not the player's own, and nothing ever read them
  back — including the site, which has no column for them.

### New: records older than 7 days are removed automatically

- The player list was the only part of the save that grows with every encounter,
  and it grows forever. Old records are pruned on logout; the default retention
  is 7 days. **This is a change in behaviour: if you have been collecting for
  longer, records past the window will be gone after the first logout.**
- `/nspy retain` shows the setting and how many records would be removed without
  removing anything. `/nspy retain 30` keeps a month, `/nspy retain off` disables
  pruning entirely (your file will keep growing).
- Back up a full snapshot before the first logout if you want to keep the
  history: the pruning is not reversible.

### Improved: far more players show equipment on the site

- Snapshots of gear and talent builds are kept for 6 000 players instead of
  2 000. The old cap silently discarded the oldest snapshots as new ones came in,
  which is why a character you had met many times could still show "no snapshot
  yet". The cost is about 0.8 MB of file size.

### New: ask other clients for what they have seen recently

- `/nspy peer ask` sends a request over the sharing channel and the other running
  clients answer with their most recent sightings from that window — up to 15
  encounters and 5 gear snapshots, which fits in under a minute of channel
  traffic. `/nspy peer ask status` shows the counters.
- `/nspy peer ask <name> [minutes]` asks one player only, so clients can be
  visited one at a time instead of everyone answering at once. `/nspy peer ask
  list` prints who has been talking in the channel. Double names work as they
  appear in chat ("Youtchi Zerling"), with or without the hyphen, in any case.
- Answers travel under their own packet type, so clients that did not ask for
  them drop them instead of writing them into their database. Only the client
  that made the request accepts the reply.
- Nothing about your own database changes: records received this way are marked
  as someone else's observation, exactly like the regular sharing channel.

### New: NearbySpy settings in the game's own AddOns tab

- The options are now also available under Settings → AddOns → NearbySpy, where
  every other addon keeps them, and `/nspy settings` opens that tab. They are the
  same options as in the addon's own window: sharing, accept other realms,
  minimap icon, interface language, heatmap timezone.
- On clients whose settings API is missing entirely, the command falls back to
  the addon's own window instead of doing nothing.

### Fixed: a snapshot without a realm was accepted but never stored

- When a packet arrived without a realm, the addon guessed its own realm to make
  the packet readable — but the resulting key did not exist when the player was
  known under a different realm of the cluster. A recorded session showed 68
  packets received and 68 orphans: all accepted, none stored.
- Such snapshots are now attached by name when exactly one player matches. If the
  name exists on several realms, nothing is guessed. A player the database has
  never seen still gets no row: a snapshot alone carries no class or level.

### Cleanup: removed the finished diagnostics

- The talent/inspect probe and the debug dumps it left behind are gone from the
  save. SavedVariables merges rather than overwrites, so old probe output stayed
  in the file even after the code that wrote it was removed — about 98 KB of
  accumulated debug data is cleaned up once.
