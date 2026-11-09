## NearbySpy 1.5.2

Delta against 1.4.0. Everything below is visible to players; internal
development noise is left out.

### New: world data — vendor prices and fishing catches

- Opening a merchant records its stock: item names, quality, stack size and
  price in copper. Recipes are included like any other item.
- Every fishing catch is recorded as a zone + item pair, so "what bites where"
  becomes measurable.
- `/nspy world` shows the counters. The data travels to the statistics site with
  your next SavedVariables upload; nothing is sent by the addon itself.
- Prices come from the merchant frame and `C_MerchantFrame`; when neither
  answers, the price is left empty instead of being guessed.

### New: `/nspy who speed` — a fast sweep instead of a full census

- Starts from the level cap and walks down in bands of ten. A band that hits the
  server's 50-row reply cap expands into its classes, and a capped class slice
  expands into races. That is the depth limit; a capped slice is accepted as is.
- A full picture now takes far fewer queries than a level-by-level census.
- An unfinished sweep survives `/reload` and a relog: the remaining queue is
  saved and the next `/nspy who` continues where it stopped. `/nspy who new`
  starts over.

### Improved: `/who` coverage and race handling

- Levels are swept top-down, so an interrupted run keeps the endgame part.
- A crowded class slice is narrowed by level range instead of keeping the first
  50 rows and moving on.
- Race names are kept in one spelling per client language, and races that exist
  in both factions are swept in both.
- A `/who` entry whose race cannot be resolved keeps its faction instead of being
  stored with an empty one.

### Improved: peer sharing

- The player window has a **Peer** filter and `/nspy peer new` lists what arrived
  over the channel. Both are stored with the player record, so they answer after
  a relog as well.
- Peer messages now carry the zone: zone id (a number, identical in every client
  language) and the localized zone name. Map coordinates travel only when the
  game exposes the other player's own position (a unit you can see); a /who
  entry has the player's zone but no position, so no coordinates are invented for
  it. Older clients in the channel keep working — their messages are still
  accepted.
- The channel turned out to be shared by the whole cluster, so records from other
  realms can arrive. They are accepted and marked with their realm; a new
  **Accept other realms** setting rejects and hides them if you prefer.
- Sharing counters and per-reason rejections are saved with your data, and
  `/nspy peer` shows both the current session and the previous one.

### Improved: server census window

- Prime time is a per-realm number, and the window now says which realm it shows
  ("PRIME TIME — your realm" or "— All realms").
- When the data module has no slice for your realm, the aggregate is still drawn
  but labelled as such instead of quietly mixing realms.
- The bundled `NearbySpy_Data` snapshot is refreshed for the current realm.

### Improved: interface

- The settings window gains a minimap icon switch and the "Accept other realms"
  checkbox.
- The minimap button was rebuilt to match the standard addon button geometry:
  a round masked icon with a soft transparency and the ring sitting exactly on it.
- The menu window fits longer Cyrillic and German labels.

### Install

Unzip the archive into `Interface/AddOns/` — it contains both `NearbySpy` and
`NearbySpy_Data`. Enable them in the in-game AddOns list. If the client flags the
addon as out of date, tick "Load out of date add-ons".

Full instructions in your language: https://foragerstats.com/docs/install
Statistics site fed by this addon: https://foragerstats.com
