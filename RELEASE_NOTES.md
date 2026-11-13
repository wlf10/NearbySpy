## NearbySpy 1.5.5

### Fixed: sharing is no longer refused by the channel

1.5.4 made the sender go faster while the send queue was long, and the channel
would not take it: the server answered THROTTLED and dropped the messages. In
one recorded session five of eighteen sends were refused and 39 records never
left the client.

- After a refusal the addon backs off to 15 seconds between messages instead of
  pushing at the same rate, and returns to the normal interval after 90 seconds
  without refusals.
- The interval used while the queue is long drops from 4 to 7 seconds, which is
  what this channel actually tolerates.

### Improved: refusals are visible instead of guessed

- Refused messages are counted, the counter is saved with your data on logout,
  and both `/nspy peer` and its "last session" line report it. Before, a
  refusal lived only in memory, so "the server refused us" looked exactly like
  "there was nothing to send".

### Install

Unzip the archive into `Interface/AddOns/` — it contains both `NearbySpy` and
`NearbySpy_Data`. Enable them in the in-game AddOns list. If the client flags the
addon as out of date, tick "Load out of date add-ons".

Full instructions in your language: https://foragerstats.com/docs/install
Statistics site fed by this addon: https://foragerstats.com
