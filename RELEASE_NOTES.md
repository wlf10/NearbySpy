## NearbySpy 1.5.4

### New: a bigger player window

- The window grew from 700x668 to 880x800: about four more rows visible, and the
  zone column finally has room (it was the first thing to be cut).
- The five filter tabs now fit on one line in every language. They used to wrap
  inside their buttons, and the counter in the corner was taking the space.
- The level histogram is wider and its columns are bigger, so picking one exact
  level by clicking a column is easier rather than harder.
- The top-3 classes panel was made narrower: it holds three rows, while the
  histogram is the part you interact with.

### New: your catches are compared with MasterCraft

- NearbySpy keeps recording vendors, but MasterCraft already ships a vendor
  database. The interesting part is the difference: this server is custom, and
  seven of the ten vendors caught so far are absent from MasterCraft's list.
- Opening a merchant that MasterCraft does not know now prints a single notice
  with its zone, so a new vendor is noticed instead of silently piling up.
- `/nspy world` shows how many such vendors were found and which MasterCraft
  version the comparison used.

### Improved: sharing over the channel

- Several records can now travel in one message. Previously one record left per
  ten seconds, so a /who sweep overflowed the queue and the rest expired unsent.
- Players you already know are shared again when their level or zone changes.
  Before, only the first sighting of a player was ever sent, so everyone else
  kept a stale level forever.
- The queue is released on ordinary play (moving, casting, changing target),
  not only on a click into the 3D world. Many players never clicked, and their
  queue simply expired.
- A record is much smaller: class, race, faction and game travel as single
  characters instead of words, and the zone travels as its id.

### Improved: zones in your language

- A record carries the zone id as its key with the zone name alongside. On
  arrival your own client resolves the id first, so a zone another player
  reported in their language shows up in your client's language.
- If your client does not know that id, the name the sender saw is used, so a
  zone is never left blank.
- `/nspy zones` shows what your client knows about zones, without running a
  /who query.

### Compatibility

- Messages of every previous format are still accepted, so older clients in the
  channel keep reaching you. But an older client cannot read the new records
  until it is updated, so update all of your own clients.

### Install

Unzip the archive into `Interface/AddOns/` — it contains both `NearbySpy` and
`NearbySpy_Data`. Enable them in the in-game AddOns list. If the client flags the
addon as out of date, tick "Load out of date add-ons".

Full instructions in your language: https://foragerstats.com/docs/install
Statistics site fed by this addon: https://foragerstats.com
