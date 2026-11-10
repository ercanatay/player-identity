# Player Identity (macOS)

[![CI](https://github.com/ercanatay/player-identity/actions/workflows/ci.yml/badge.svg)](https://github.com/ercanatay/player-identity/actions/workflows/ci.yml)
[![UI Tests](https://github.com/ercanatay/player-identity/actions/workflows/ui-tests.yml/badge.svg)](https://github.com/ercanatay/player-identity/actions/workflows/ui-tests.yml)
[![Release](https://img.shields.io/github/v/release/ercanatay/player-identity)](https://github.com/ercanatay/player-identity/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black)

A native SwiftUI utility for **Xash3D FWGS / GoldSrc** players on macOS. It shows the identity the game
client actually uses, derives the per-server **CID** (the value servers see and ban by), checks **IP and CID
bans**, and helps you act on the result — renewing an IP, spotting a range ban, or generating a precise unban
appeal for the server admin.

It is a **read-only tool by default**. The only game files it ever writes are the `name` and `model` lines of
`config.cfg` / `userconfig.cfg`, and only when you press **Apply**. Everything else lives in the app's own
folder (`profile.json`, history, metrics, updates).

**Turkish and English UI** — follows the system language by default and can be switched at runtime.

---

## What's new in v2.7.0

- **Redesigned History, Ban Matrix and Metrics windows** using the same design language as the main window: new toolbar, filter chips, narrow-width behaviour, and a chart card for metrics.

## What's new in v2.6.0

- **Redesigned main window and Settings** following the Claude Design handoff: new layout, light and dark appearance, Turkish and English UI.
- **Design tokens** (colours, spacing, typography) shared across the main window and Settings.
- **Reset Settings** and **Erase All Data** in Settings (see spec §47).

## What's new in v2.5.0

- **Settings and server export/import**: choose the scope (Settings only, or Settings + servers), export to JSON, and import with merge or replace.
- Preview of what will change, plus a result summary after import.
- Replace mode keeps a `profile.json.appbak-*` backup of the previous data.

## Contents

- [Features at a glance](#features-at-a-glance)
- [Requirements](#requirements)
- [Install](#install)
- [How it works](#how-it-works)
  - [Identity and CID](#identity-and-cid)
  - [Status colours and suggestions](#status-colours-and-suggestions)
  - [Ban checks](#ban-checks)
  - [Fix: what can and cannot be fixed](#fix-what-can-and-cannot-be-fixed)
  - [Servers: groups, favourites, filters](#servers-groups-favourites-filters)
  - [Notes and appeal tracking](#notes-and-appeal-tracking)
  - [Watched servers and notifications](#watched-servers-and-notifications)
  - [History](#history)
  - [Metrics and charts](#metrics-and-charts)
  - [Ban matrix](#ban-matrix)
  - [Name and model editing](#name-and-model-editing)
  - [Model catalogue and previews](#model-catalogue-and-previews)
  - [Join game](#join-game)
  - [Settings export/import](#settings-exportimport)
  - [Share card](#share-card)
  - [Menu bar and launch at login](#menu-bar-and-launch-at-login)
  - [Updates and downgrade](#updates-and-downgrade)
  - [Language](#language)
  - [Diagnostics](#diagnostics)
  - [Shortcuts and Siri](#shortcuts-and-siri)
  - [Command-line tool](#command-line-tool)
- [Data and privacy](#data-and-privacy)
- [Security and signing](#security-and-signing)
- [Troubleshooting](#troubleshooting)
- [Build and test](#build-and-test)
- [Project layout](#project-layout)
- [Releases and Homebrew](#releases-and-homebrew)
- [Design spec](#design-spec)
- [License](#license)

---

## Features at a glance

| Area | What it does |
|---|---|
| **Identity** | Reads the engine's `.xash_id` files, decodes the raw 64-bit identity and shows where it comes from |
| **CID** | Derives the 32-hex MD5 the server sees, per server, for IPv4 and IPv6 |
| **Ban checks** | UDP probes: A2S_INFO, `getchallenge` (IP ban) and `connect 49` (CID ban), with strict rate limits |
| **Fix** | Tries an honest IP renewal, detects `/16` range bans, and writes a complete admin appeal |
| **Servers** | Groups, favourites, ordering, filters (banned / favourite / watched), notes, appeals |
| **Monitoring** | Watched servers notify on ban changes, online/offline and map changes; quiet hours |
| **History** | Append-only event log with filters and JSON/Markdown export |
| **Metrics** | Ping and player-count samples with charts and 24-hour uptime |
| **Ban matrix** | One table of every server × ban type, CSV/copy export |
| **Name/model** | Dropdowns, effective-source detection, override removal, diff preview, atomic writes |
| **Models** | Catalogue and thumbnails from the game folder **and** downloaded (`valve_downloads`) models |
| **Game** | One-click “Join game” with `+connect`; “Fix” and ban helpers |
| **Sharing** | 1200×630 PNG card with the CID and a QR code |
| **Updates** | Signed, checksum-verified in-app updates with rollback; version history and downgrade with data backup |
| **i18n** | Turkish and English, switchable at runtime (System / Türkçe / English) |
| **Automation** | `playeridentityctl` CLI and three Shortcuts/Siri actions |
| **Diagnostics** | Redacted support bundle (ZIP) |

---

## Requirements

- **macOS 14 or newer**
- **Xash3D FWGS** (`/Applications/Xash3D-FWGS.app`) with a `valve` (or `gearbox`) data folder
- For building: Xcode 16 or newer (Swift 6) and [XcodeGen](https://github.com/yonaskolb/XcodeGen)

No third-party runtime dependencies. The app is not sandboxed because it must read the game folder and
optionally update itself in `/Applications`.

---

## Install

### Homebrew (recommended)

```sh
brew tap ercanatay/tap
brew install --cask ercanatay/tap/player-identity
```

This installs `PlayerIdentity.app` into `/Applications` and links the CLI to `/opt/homebrew/bin/playeridentityctl`.
Upgrade later with:

```sh
brew upgrade --cask player-identity
```

### Direct download

Download the latest notarized build from [Releases](https://github.com/ercanatay/player-identity/releases/latest),
unzip it, move `PlayerIdentity.app` to `/Applications` and open it.

### Local build

```sh
git clone https://github.com/ercanatay/player-identity.git
cd player-identity
xcodegen generate
xcodebuild -project PlayerIdentity.xcodeproj -scheme PlayerIdentity \
  -destination 'platform=macOS' -configuration Release -derivedDataPath .build-release build
ditto .build-release/Build/Products/Release/PlayerIdentity.app /Applications/PlayerIdentity.app
codesign --force --deep --sign - /Applications/PlayerIdentity.app
open /Applications/PlayerIdentity.app
```

### Uninstall

```sh
brew uninstall --cask player-identity            # Homebrew install
rm -rf "$HOME/Library/Application Support/tr.ercanatay.playeridentity"   # app data, optional
```

---

## How it works

### Identity and CID

Xash3D stores a 16-character hex value in a file and XORs it with a fixed mask. The app reads the files in the
engine's priority order:

1. `~/.config/.xash_id`
2. `~/.local/.xash_id`
3. `~/.xash_id`
4. `<data root>/<gamedir>/.xash_id`

The raw 64-bit identity is `file value ^ mask`, using `0x10331C2DCE4C91DB` for the home files and
`0x7FFC48FBAC1711F1` for the per-gamedir file.

The value a server sees is **not** the raw identity. It is derived per server:

```
CID = lowerHex( MD5( littleEndian64(rawIdentity) || serverIPBytes ) )
```

- IPv4 → 4 address bytes, IPv6 → 16 bytes
- “Local machine” (no address) → only the 8 identity bytes
- Always 32 lowercase hex characters

Because the server address is part of the hash, **the same player has a different CID on every server**.
Hostnames are resolved first (IPv4 preferred, then IPv6) and cached for five minutes; the resolved address is
shown next to the server and used for both the CID and the ban check.

> **macOS note.** The engine build shipped for macOS has no hardware serial source, so the raw identity
> collapses to `0000000000000000` and the `.xash_id` files contain only the mask. In practice **all macOS
> clients derive the same CID for a given server**. The app detects this and shows a permanent
> “shared identity” warning instead of pretending the identity is unique.

### Status colours and suggestions

One overall state is computed from all checks:

| Colour | Meaning |
|---|---|
| 🟢 Green | All critical checks passed and everything matches the saved record |
| 🟠 Orange | Something differs or is unverifiable (changed IP, changed name/model, no record yet, shared identity, unreachable server) |
| 🔴 Red | A critical failure: identity file missing/invalid, no public IP, corrupt record, or a ban |

Every reason is listed with an icon and text, plus a one-line **suggestion** (for example “renew your IP”,
“appeal with this text”, “save a baseline”). The status label opens a **What should I do?** popover with all
current suggestions and a copy button.

### Ban checks

For every server the app performs one UDP probe sequence, reusing the A2S_INFO reply for server details:

1. **A2S_INFO** — is the server alive? Also yields name, map, players and ping.
2. **getchallenge** — the reply text is inspected; `banned` means the **IP is banned**.
3. **connect 49** — a modern-protocol connect packet carrying the CID; the reply distinguishes
   *no block* (`client_connect`), *CID banned* (`errormsg`/`disconnect` mentioning a ban), or
   *CID check not applicable* (GoldSrc protocol 48 servers, which never see a raw CID).

Constraints: 4 seconds per step, 12 seconds total, **one attempt per server per refresh**, at least 10 seconds
between attempts, no retries, and no spawn packet. The whole check can be disabled in Settings.

### Fix: what can and cannot be fixed

**No client can remove a server-side ban.** “Fix” is honest about this:

- **IP ban** — the app offers to renew the network (Wi-Fi off/on or a DHCP lease renewal, with a macOS admin
  prompt), waits up to 45 seconds for the network to come back, compares the new public IP and re-runs the ban
  check. If the IP did not change, it says so and points to the router page and VPN options. If the IP changed
  but the same `/16` is still banned, it reports a **range ban** — reloading the IP cannot help there.
- **CID ban** — cannot be fixed locally. The app produces a ready-to-send appeal containing the server, your
  name, CID, egress IP, timestamp, the raw server reply, and a checklist for the admin:
  `listid`/`listip`, `removeid` + `writeid`, `removeip` + `writeip`, AMXX `amx_unban`, SQL/AMXBans removal,
  `sv_filterban`, and verification after a restart.
- **Unreachable** — no network command is attempted; only a re-check and the server page are offered.

A single fix can run at a time, is cancellable, and always leaves the network interface enabled.

### Servers: groups, favourites, filters

- Add, edit and delete servers (`host:port`, IPv4, IPv6 or hostname).
- Assign a **group** (or “No group”); groups are shown as sorted sections, with ungrouped servers last.
- Mark **favourites**; they sort first and can be filtered.
- Reorder rows with ▲/▼ inside a section; the order is persisted.
- Filters: **only banned**, **only favourites**, **only watched** — they combine.
- Per-server detail sheet shows the resolved IP, group, notes, appeals and metrics.

### Notes and appeal tracking

- A free-form note per server (up to 2000 characters); changes are recorded in history.
- An **appeal** record with channel (Discord, Telegram, forum, e-mail, other), status
  (sent → answered → accepted/rejected), sent date, follow-up date and a summary.
- The appeal has a **timeline** of status changes and “postpone +1 day / +3 days” buttons.
- When a follow-up date passes, a single notification is produced (respecting notification settings and
  quiet hours); the reminder is not repeated.
- The §17.9-style **unban message** can be copied from the same sheet.

### Watched servers and notifications

Mark any server with the 🔔 switch (row, context menu or detail sheet). On every full refresh — including the
menu-bar 30-minute loop — the app compares the new state with the previously stored one and can notify you
about:

- **ban appeared** (IP or CID, type included in the text)
- **ban lifted**
- **server offline**
- **server back online** (only after at least 10 minutes offline)
- **map changed** (old → new)

The baseline is stored in `watch-state.json`. The first observation never notifies. Identical transitions are
deduplicated within 10 minutes. Notification categories can be toggled individually (ban / online / map);
the master switch and **quiet hours** (default 23:00–08:00, may cross midnight) apply on top. History entries
are written even when notifications are muted.

### History

An append-only `history.jsonl` records meaningful transitions: refreshes, IP changes, ban appeared/lifted,
identity/name/model changes, applies, fix attempts, appeals, notes, config-override removals, watched-server
events and update availability. The **History** window (⌘Y) lists newest first, filters by server and type,
and exports JSON or Markdown. Retention: 5,000 entries or 90 days.

### Metrics and charts

Every ban check also appends a sample to `metrics.jsonl`: timestamp, server, online, ping, players/max and map.
The app, the Fix flow and the CLI all feed it (deduplicated per server per second; `--no-metrics` opts out).
Retention: 5,000 samples per server or 30 days.

The server detail sheet shows **Swift Charts** graphs for ping and player count, offline gaps marked, and the
**24-hour uptime** percentage. Data can be exported as JSON or CSV.

### Ban matrix

A separate window shows every server against **IP ban**, **CID ban**, **range** and last check. Banned servers
sort first; “ban type unverified” rows are marked; unreachable cells show “—”. Export as RFC 4180 CSV or copy
the table to the clipboard.

### Name and model editing

The profile card exposes the player name and the player model as dropdowns plus **Apply (⌘⏎)**.

- The **effective value** is resolved with the game's execution order: `userconfig.cfg` runs after
  `config.cfg`, so if it contains `name`/`model`, that value wins. The UI always shows the source.
- **Override handling.** If `userconfig.cfg` overrides the value, a prominent warning explains that in-game
  changes will not stick and offers **“Remove line”**: it backs the file up to `userconfig.cfg.appbak-<stamp>`,
  comments out only that key, and records a `configOverrideRemoved` event. Refused while the game is running.
- **Apply** shows a **diff preview** (line numbers, `-`/`+`) before writing. Nothing is written until you
  confirm.
- Writes are byte-preserving: only the target keys change, line endings are kept, all occurrences are updated,
  missing keys are appended, the write is atomic, and a single rolling `*.appbak` is kept per file. The game's
  own `config.cfg.bak` is never touched.
- Writing is refused while the game is running, because the engine rewrites `config.cfg` on exit.

### Model catalogue and previews

The model dropdown merges folder names from:

1. `<gamedir>/models/player/`
2. `<data root>/valve_downloads/models/player/`
3. `<data root>/<gamedir>_downloads/models/player/`

Names are de-duplicated and sorted; the current value is kept even if it is not in any folder. The row and the
card show a thumbnail from the model's own BMP preview (case-insensitive extension), with the file path in a
tooltip; a person icon is used when no preview exists. Downloaded models such as custom server models are
therefore both selectable and previewed. A note reminds you that some servers force a model server-side.

### Join game

Select a server and press **Join game**: the app runs
`open -a /Applications/Xash3D-FWGS.app --args -game <gamedir> +connect <host>:<port>`.
If the game is already running, a confirmation warns that the current session will be replaced. If Xash3D is
not installed, the action is hidden.

### Share card

“Create share card” renders a **1200×630 PNG** with the app icon, server name and address, CID (monospaced),
player name, timestamp and a **QR code** of the CID. Copy it to the clipboard or save it with a save panel.

### Menu bar and launch at login

Optional menu bar item with a colour-coded status icon (green/orange/red) and a menu containing the status,
last check time, **Refresh (⌘R)**, **Settings**, **Show** and **Quit**. While enabled, the app also refreshes
every 30 minutes. **Launch at login** uses `SMAppService`; registration errors are shown in Settings.

### Updates and downgrade

- **Feed:** the GitHub releases API (stable releases, semantic-version sorted).
- **Verification before installing:** HTTPS only, asset size, SHA-256 from `SHA256SUMS.txt`, unzip, then
  `codesign --verify --deep --strict`, **TeamIdentifier**, bundle identifier and version equality. Any failure
  aborts and deletes the download.
- **Install:** the current app is moved to `updates/backup/`, the new one is put in place, quarantine is
  cleared, and the app relaunches. Failures roll back automatically.
- **Schedule:** check at launch (24-hour throttle) and every 6 hours while running. Automatic *download* is
  opt-in; automatic *install* never happens.
- **Version history and downgrade:** the last 20 stable releases are listed. “Go back to this version” asks for
  confirmation, optionally (by default) backs up `profile.json`, `history.jsonl` and defaults into
  `updates/backups/data-<from>-to-<to>-<stamp>/`, installs the older build with the same verification, and can
  offer a restore if the current record schema is unsupported. Up to 10 data backups are kept.

### Language

**Settings → General → Language**: `System (default)`, `Türkçe`, `English`. The default follows the system
language (`tr*` → Turkish, anything else → English). The switch is immediate; the app name in the Dock/menu
bar follows the system language by design.

### Diagnostics

**Settings → General → Create diagnostics bundle…** produces a ZIP with app version/build, OS/architecture,
a **redacted** snapshot (IPs and the home path masked), history and metrics tails, and update state. Useful
for bug reports without leaking personal data.

### Shortcuts and Siri

Three App Intents are exposed to Shortcuts and Siri:

- **Check server ban** (with a server parameter)
- **Show my CID** (with a server parameter)
- **Refresh**

Phrases are localized in Turkish and English and use the app name automatically.

### Command-line tool

`playeridentityctl` ships inside the app (`Contents/Helpers`) and is linked into `PATH` by the Homebrew cask.

```sh
playeridentityctl cid 198.51.100.10 --json
playeridentityctl ban example.com:27015 --json
playeridentityctl ban 203.0.113.10:27015 --no-metrics
playeridentityctl status --json
playeridentityctl --version
```

- `cid <ip>` — derive the CID for an address (uses the local identity unless `--raw-id <hex>` is given)
- `ban <host:port>` — run the ban checks; `--cid`, `--timeout`, `--json`, `--no-metrics`
- `status` — summarize the saved record (servers, ban states, watched count)
- Exit codes: `0` success, `1` usage error, `2` network/resolution error, `3` a ban was found
- JSON output uses a stable `schemaVersion: 1`

The CLI appends a metrics sample for successful A2S replies unless `--no-metrics` is used.

---

### Settings export/import

Exports settings and, optionally, the server list to a JSON file named `playeridentity-settings-*.json`.

- **Scope**: *Settings only*, or *Settings + servers*.
- `dataRoot` is excluded by default, so a file exported on one Mac does not point another Mac at a local folder.
- **Merge**: servers are matched by `host:port`; matching entries are updated and new ones are added.
- **Replace**: the current data is replaced. Before replacing, the previous `profile.json` is kept as `profile.json.appbak-*`.
- A preview lists the planned changes before anything is written, and a result summary follows the import.
- Identity (CID), history and metrics are **not** exported or imported.

## Data and privacy

Everything the app writes lives in:

```
~/Library/Application Support/tr.ercanatay.playeridentity/
├── profile.json        # your record (identity, servers, notes, appeals, settings snapshot)
├── history.jsonl       # append-only event log
├── metrics.jsonl       # ping/player samples
├── watch-state.json    # last seen state per watched server
├── updates/            # downloads, staging, app backups, data backups
└── *.appbak            # backups of config files it edited
```

Game data is read from `~/Library/Application Support/Xash3D FWGS/<gamedir>` and, for models, from
`valve_downloads` / `<gamedir>_downloads`.

**Network endpoints used**

| Purpose | Endpoint |
|---|---|
| Public IP | `https://api.ipify.org?format=json`, fallback `https://ifconfig.me/ip` |
| Release feed | `https://api.github.com/repos/ercanatay/player-identity/releases` |
| Ban checks | the server you configured, UDP |
| Hostnames | system DNS resolver |

There is **no telemetry**. The app never uploads your record, notes or history. Diagnostics are only created
when you ask for them, and they are redacted.

---

## Security and signing

- Released builds are **signed with a Developer ID certificate and notarized by Apple**, then stapled.
- Hardened runtime is enabled; the app is not sandboxed because it needs the game folder and self-updates.
- In-app updates verify the code signature, the signing team, the bundle identifier and the version before
  replacing anything, and roll back on failure.
- Writes to game files are limited to `name`/`model` in `config.cfg` / `userconfig.cfg`, with backups.

Verify a download yourself:

```sh
codesign --verify --deep --strict /Applications/PlayerIdentity.app
spctl -a -vv -t exec /Applications/PlayerIdentity.app     # accepted, Notarized Developer ID
xcrun stapler validate /Applications/PlayerIdentity.app
shasum -a 256 -c SHA256SUMS.txt
```

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Name or model keeps reverting after joining a server | `userconfig.cfg` sets `name`/`model` and runs after `config.cfg`. The app shows a warning and **Remove line** fixes it (with a backup). |
| Name changes in-game but not on the next launch | The game rewrites `config.cfg` on exit. Change values from the app while the game is **closed**, or use the override removal. |
| Model changes do not appear on one server | Many mods force the player model server-side. The app cannot override that. |
| `IP ban` even after the IP changed | Likely a **range ban** (same `/16`). Use a different network (mobile hotspot / VPN outside the range) or ask the admin. |
| `CID check not applicable` | The server uses the GoldSrc 48 protocol and never sees a raw CID. Only the IP check applies there. |
| “Shared identity” warning | The macOS engine build has no hardware serial; all macOS clients derive the same raw identity. This is expected. |
| Gatekeeper warning | Use the notarized release or the Homebrew cask. Local ad-hoc builds need right-click → Open once. |
| App asks for Documents access | Only the test host asks while scanning sources for the localization test; the app itself never reads Documents. Deny it. |
| UI smoke test fails in CI | Known runner limitation: the app window is visible via `open`, but XCTest sees `windows=0` on GitHub macOS runners. The workflow is best-effort; run it locally. |
| Shortcuts do not list the app | Launch the app once, then quit and reopen Shortcuts. App Shortcuts are indexed by the system after first launch. |

---

## Build and test

```sh
xcodegen generate
xcodebuild -project PlayerIdentity.xcodeproj -scheme PlayerIdentity \
  -destination 'platform=macOS' -derivedDataPath .build build
xcodebuild -project PlayerIdentity.xcodeproj -scheme PlayerIdentity \
  -destination 'platform=macOS' -derivedDataPath .build test
```

- The `.xcodeproj` is generated and not tracked in git.
- Tests are isolated: temporary fixture folders, fake HTTP/UDP clients, fake command runner, no network.
- **556 tests** in the main scheme. Most assertions compare Turkish source strings, so the scheme runs tests
  with Turkish; `LocalizationTests` switch languages explicitly.

### UI tests

Separate scheme, not part of the main CI:

```sh
xcodebuild test -project PlayerIdentity.xcodeproj -scheme PlayerIdentityUITests \
  -destination 'platform=macOS' -derivedDataPath .build-ui
```

or run the `ui-tests.yml` workflow manually. The smoke test launches the app, opens Settings and checks the
Updates pane. It passes locally; GitHub macOS runners cannot see the app window from XCTest, so the workflow
is best-effort and uploads diagnostics (`ui-diagnostics`, `ui-test-results`) for inspection.

### CI

| Workflow | Trigger | What it does |
|---|---|---|
| `ci.yml` | push / PR | XcodeGen, build, 556 tests on `macos-26` |
| `release.yml` | `v*` tag | Release build, Developer ID signing, notarization, stapling, verification, GitHub release, cask update |
| `ui-tests.yml` | manual | UI smoke test (best-effort) with diagnostics |

---

## Project layout

```
PlayerIdentity/
  App/            SwiftUI app, model, views, intents
  Core/           identity, CID, config, ban checks, fix, history, metrics, updates, …
  Resources/      tr/en Localizable.strings, AppShortcuts.strings
  Assets.xcassets app icon
PlayerIdentityTests/      Unit tests (556)
PlayerIdentityUITests/    XCUITest smoke test
CLI/                      playeridentityctl sources
Casks/                    Homebrew cask
docs/spec.md              Design/behaviour specification (Turkish)
scripts/                  release, cask, CLI smoke, icon tooling
```

---

## Releases and Homebrew

- Every `vX.Y.Z` tag builds and publishes a **signed, notarized** ZIP plus `SHA256SUMS.txt`.
- The cask is updated automatically by the release workflow; the public tap is
  [`ercanatay/homebrew-tap`](https://github.com/ercanatay/homebrew-tap).
- Version history inside the app can install older stable releases with the same verification and a data backup.

---

## Design

- [`docs/design/ui-brief.md`](docs/design/ui-brief.md): UI brief for the redesign.
- [`docs/design/claude-design-prompt.md`](docs/design/claude-design-prompt.md): prompt used with Claude Design.
- [`docs/design/handoff/`](docs/design/handoff/): handoff bundle: `tokens.css`, `MainWindow.dc.html`, `SettingsWindow.dc.html`, `icons.js`, and `Player Identity Canvas.dc.html` (canvas notes).
- **Deviations from the handoff:** the light theme uses teal tones adjusted for contrast; the Fix action opens an inline popover instead of a separate sheet.

## Design spec

The full behaviour specification — status rules, localization keys, ban checks, update/downgrade rules,
acceptance criteria — is in [`docs/spec.md`](docs/spec.md) (Turkish). It is the single source of truth for the
implementation.

---

## License

[MIT](LICENSE) © 2026 Ercan ATAY
