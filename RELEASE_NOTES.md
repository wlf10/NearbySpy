## NearbySpy 1.5.5

### Fixed: fewer records lost on the way to the channel

- 1.5.4 made the sender go faster while the send queue was long, and the channel
  would not take it: the server answered THROTTLED and dropped the messages. In
  one recorded session five of eighteen sends were refused and 39 records never
  left the client. The interval now follows the server's own signal — after a
  refusal it waits 15 seconds instead of pushing at the same rate, and returns
  to the normal interval after 90 seconds without refusals.
- The interval used while the queue is long drops from 4 to 7 seconds, which is
  what this channel actually tolerates.
- Refusals are counted and reported by `/nspy peer`. Before, "the server refused
  us" and "there was nothing to send" looked exactly the same.

### Fixed: a race no longer costs you the whole encounter

- One unrecognised race used to reject the entire packet, so the player was never
  recorded. Worse, the check behind it also threw away genuine values: the
  localized "Night Elf" (it has a space) and custom races written in Cyrillic.
  Those records never even left the sender.
- Now the name, realm, class and level stay strict, while race and faction are
  normalized: a localized name becomes the standard value, and anything we do
  not know is stored as unknown instead of dropping the encounter.
- Records that had a zone name stored in the race field ("Duskwood", "Wetlands")
  are cleaned up automatically on the first login — 388 such records were found
  and removed from the live database.

### Changed: realms are shown by region and ruleset

- The cluster has a dozen realms that differ only by shard and number. The
  selector multiplied that difference into a dozen near-identical entries.
- The realm under a player's name and the realm selector now use "EU PvE",
  "EU PvP" and "EU RP PvP", with your own realm first in the list.
- Stored data is untouched: the full realm name still travels with every record,
  so the statistics site keeps its per-realm accounting.

### Changed: one exchange tab instead of two

- The player window has a single exchange tab now. The second one ("Peer" —
  everything the channel ever delivered) is gone: it mixed records of unknown
  age with fresh ones and answered nothing the session view does not.
- The remaining tab shows only what the channel taught you during the current
  session, ordered by arrival, and its counter follows the same rule.
- `/nspy peer list` still prints everything the channel ever delivered.

### Changed: the menu closes when it opens a window

- Picking a tile in the main menu no longer leaves the menu sitting behind the
  window it opened — one click less every time.

### Install

Unzip the archive into `Interface/AddOns/` — it contains both `NearbySpy` and
`NearbySpy_Data`. Enable them in the in-game AddOns list. If the client flags the
addon as out of date, tick "Load out of date add-ons".

Full instructions in your language: https://foragerstats.com/docs/install
Statistics site fed by this addon: https://foragerstats.com
