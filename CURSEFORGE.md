# NearbySpy — материалы для CurseForge

Файл-шпаргалка для публикации проекта на www.curseforge.com
(Author Console → Projects → Create a Project → World of Warcraft → Addons).

Принцип первой публикации: **чистый лист**. Никакой истории внутренних
версий (1.0.0–1.6.x, эволюция /who, чат-источник) — только описание
того, что умеет аддон сейчас. История разработки остаётся в репо/на сайте.

## Метаданные проекта

- Name: NearbySpy
- Summary: Passive player recorder for WoW — Forever, Classic Era and
  Retail — feeding the RealmPulse realm demographics site (≤255 символов)
- Category: Addons / World of Warcraft (при загрузке файла указать версию
  клиента — у Forever это нестандартный 1.60.x, ближайший вариант
  Classic Era, в описании файла уточнить «WoW: Forever beta (1.60.x)»)

## Description (для поля описания проекта, markdown)

```
**NearbySpy** is a lightweight, passive player-recording addon built for
**World of Warcraft: Forever**. It quietly keeps a local
database of every player you meet — in the open world, in your group, in your
guild roster and in chat. You can contribute your observations (including
names) to RealmPulse, a public demographics project for the Forever server,
by uploading your SavedVariables file on the site (link at the bottom of this
page). The addon does not upload anything itself.

### Features

- Passive recording: unit frames, group/party/raid, guild roster, chat channels
- In-game window (`/nspy`): session summary, fresh-recent counters,
  level histogram (1–60) and top classes
- Zone `/who` sweep helper (`/nspy suggest`) that only prepares the query —
  you stay in control and click the search button yourself
- Full localization: English (default), Simplified Chinese, Russian, German,
  French and Korean UI (the bundled font includes Cyrillic; zhCN/koKR clients
  use the client's native fonts)
- Optional peer sharing (`/nspy peer on`): sends newly encountered players with
  a known class and level to other NearbySpy users on the same realm; off by default
- No passwords or account data — the Privacy section lists what is stored and shared

### Installation

1. Download and unpack the archive.
2. Copy the `NearbySpy` folder into `<Client>/Interface/AddOns/`.
3. Enable it in the in-game AddOns list.

Full illustrated instructions in your language are on the RealmPulse site
(link at the bottom of this page).

### Commands

- `/nspy` — toggle the main window
- `/nspy count` — counters and debug totals
- `/nspy suggest` — prepare a zone `/who` query for review
- `/nspy debug` — toggle verbose chat logging (off by default)
- `/nspy help` — open the full in-game command reference
- `/nspy peer on|off` — opt in/out of realm-local peer exchange; `/nspy peer` — status

### Privacy

Only the name, class, level, zone, realm, faction and race of *encountered*
players is stored, together with the approximate coordinates of your own
position at the time of the encounter (used to resolve the zone) and first /
last seen timestamps. Names read from chat channels also enter the database —
if that is unwanted for you, simply don't use the addon.

The addon does not upload to a web server. Peer sharing is off by default.
If you enable it with `/nspy peer on`, the addon joins an in-game channel
(`nearbyspydata`) and queues only *new local records with known class and level*.
It sends name, realm, game, class, level, race and faction, one message per
mouse click and at most one per 10 seconds. It does not send coordinates, chat
text or subsequent updates. The channel's messages are hidden from ordinary
chat windows, but channel membership and traffic are not private from other
members or the game server. Received records are not retransmitted. Other
members may submit inaccurate records. `/nspy peer off` leaves the channel.
With sharing off, your database stays in SavedVariables until you upload the
file to the site yourself.

### License

MIT (see LICENSE). Bundled font: Liberation Sans (SIL OFL 1.1).

### Links

- RealmPulse — live demographics fed by this addon: https://wow.bitwolff.com
- Installation guide (en, ru, zh, de, fr, ko): https://wow.bitwolff.com/install
```

## Changelog для первой загрузки (чистый лист, одна запись)

```
1.0.0 — Initial public release

- Passive recording of encountered players (world, group, guild, chat).
- Zone /who sweep with one-click confirmation (/nspy suggest).
- In-game summary window: totals, freshness counters, level histogram,
  top classes.
- Localizations: en (default), zhCN, ru, de, fr, ko; bundled Cyrillic-capable
  font, native client fonts on zhCN/koKR.
- Data feeds the public statistics site https://wow.bitwolff.com
  (guests see anonymized names).
```

## Иконка

`NearbySpy-icon.png` рядом с этим файлом — **400×400 PNG** (требование CF:
ровно 400×400, не сплошной цвет, без NSFW/копирайта, не webp — у CF баг
с webp). Источник: AI-вариант v6 (маска в капюшоне, MiniMax image-01),
оригинал и экспорты 256/512/400 — в `games/wow/branding/`. AI-дисклеймер
не нужен: это брендинг-аватар, не showcase-изображение геймплея.

## Порядок действий

1. Аккаунт: curseforge.com (вход через Twitch/Google/Discord/GitHub) — **делает владелец**.
2. Author Console → Projects → Create a Project → WoW → Addons, вставить
   Name/Summary/Description выше, загрузить иконку.
3. Files → Add File → `NearbySpy-1.0.1.zip` (лежит в `games/wow/dist/`),
   указать версию игры, вставить changelog ниже (для 1.0.1 — из тега
   v1.0.1 на GitHub: локализация 6 языков).
4. Модерация: от минут до рабочих дней; при отказе — причина в уведомлении.
