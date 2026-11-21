## NearbySpy 1.6.1

### Fixed: gear and talent sharing delivered nothing

- Every receiver rejected the snapshots, our own client included: when the
  sending client did not report its realm, the realm field came out empty and
  the packet was thrown away as unreadable. The sender still counted it as
  sent, so sharing looked alive while nothing arrived. A recorded session shows
  the whole picture — 9 packets in the channel, 9 rejected, 0 accepted.
- Records saved without a realm also split in two: the same player appeared
  once under the proper realm and once under a name with an empty one, and the
  second copy reached the site as a separate player.

### Fixed: a realm reported as an empty string is no longer trusted

- The client is asked for the realm name and sometimes answers with an empty
  string, which was stored as if it were a real value. The last known realm is
  kept now, and a one-time pass repairs the records that were already saved
  without one — 729 of them in a real save, with 54 names duplicated.

### Improved: packets from older clients are accepted instead of dropped

- A snapshot that arrives with an empty realm is stored under the reading
  client's realm and marked as such, so data from clients that have not been
  updated is not lost. Updated clients send the realm properly and carry no
  mark; `/nspy peer` shows how much of the traffic still comes in unmarked.
