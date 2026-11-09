## NearbySpy 1.5.3

Delta against 1.5.2. Everything below is visible to players; internal
development noise is left out.

### New: filter the player list by class and by level

- Two selectors now sit next to the realm selector: class and level.
- The class selector walks the classes actually present in your database, most
  frequent first. Records with no known class are reachable as their own entry
  instead of disappearing.
- The level selector walks bands of ten (1-10, 11-20, ... 51-60). For one exact
  level, click its column in the level histogram; click the same column again to
  clear it.
- Clicking a row in the CLASSES panel filters by that class, and the selected
  class is highlighted so the filter is visible at a glance.
- All filters combine: class + level + realm + freshness/new/peer.

### New: the sharing channel remembers who reported a record

- Every record that arrives over the player-sharing channel keeps the character
  whose addon sent it, so a record can be traced to its source later.
- `/nspy peer new` lists what the channel taught you — players you had never met
  yourself. `/nspy peer list` lists everything the channel delivered, updates
  included.
- The "New" filter now answers "whom did I discover": players somebody else met
  have their own tabs.
- `/nspy peer send` forces the pending queue out, for when the world-click gate
  has not fired and packets sit in the queue.

### Fixed: a shared record is not your own meeting

- A record that arrived over the channel was stamped with the receive time and
  counted as an encounter, so a player somebody else met read as "seen just now"
  and inflated your own encounter count. 522 rows in a live save were affected.
- Such a record now carries no sighting of yours: the packet time is kept
  separately, and your encounter count stays untouched until you really meet the
  player.
- When you do meet them, your observation replaces the "came from the channel"
  mark, so the source keeps saying what is actually known about the player.

### Fixed: the sharing channel is per faction

- The server does not let a character join a channel created by the other
  faction. Playing the other side left the addon with a dead channel while it
  still reported being joined — and nothing in the interface said so.
- Each faction now has its own channel, and the addon checks that the join
  actually happened instead of assuming it did.
- `/nspy peer` shows the channel the character is really in, so a refused join
  is visible instead of silent.
