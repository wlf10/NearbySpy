## NearbySpy 1.6.3

### Zone names in the window are always in your client's language

- The zone column and the tooltip showed the raw text stored with a record, and
  records accumulate over sessions on different clients. On a German client that
  was a mix of languages in one column: a single zone id held «Нагорье Арати»
  ×447, «Arathihochland» ×5 and «Arathi Highlands» ×1 side by side.
- The name is now looked up by the zone id, which is the same in every language,
  so the client renders it in its own language. Measured on a live save: the
  displayed name changes for 26 189 records out of 51 088 (51.3%) — those whose
  stored text was in a language other than the interface.
- Records without an id (peer and chat records carry none) still fall back to
  their stored text, and show "?" when there is nothing.

### Improved: zone ids now survive on records that arrive as text

- A new bundled table (`NearbySpy_Zones.lua`) carries 7 749 zone names in 10
  locales, taken from the game data of the matching client build. /who replies,
  peer packets and records made by older clients arrive as a zone name without
  an id; the id is now resolved through that table.
- On a live save the table resolves 1 131 of 1 189 distinct zone names, raising
  zone id coverage from 82% to 97%. The table is optional: without the file the
  addon works exactly as before.
- Your own zone now comes from the real zone rather than the subzone
  (`GetRealZoneText` instead of `GetZoneText`), so a record's text and its id
  finally describe the same area.

### Fixed: sharing declared a zone change where there was none

- Zone names are localized and arrive in the language of the session that
  recorded them, so one zone was stored under several names. Comparing names
  declared those records a zone change and sent an empty update over the channel
  at every repeat meeting.
- The decision is now made by zone id. When a record has no id, its old id is
  recovered from the stored name first, so "the id appeared for the first time"
  is not mistaken for a change.

### Improved: German and French clients in the assisted /who

- The addon knew race names only in Russian and English, so on a German or
  French client the race tier put a Russian or English race name into the query.
  The server answers such a query with an empty list, which wasted clicks
  exactly in the dense slices that tier exists for.
- Canonical German and French race names are now built in, plus the female
  forms, so a race reported by the unit API is stored as a race instead of raw
  text.
- Race names learned from /who replies are tagged with the locale they were
  learned on. That table accumulates across sessions, and without the tag a
  German client could take a Russian name out of it — and an English client a
  German one, since the alphabets are not distinguishable.
- The /who cooldown message is now recognised in German as well ("Wartet noch
  einen Moment…"). Before this the pause went unrecorded and the scan kept
  clicking into the throttle.
