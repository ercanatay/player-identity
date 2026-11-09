# Player Identity (macOS)

[![CI](https://github.com/ercanatay/player-identity/actions/workflows/ci.yml/badge.svg)](https://github.com/ercanatay/player-identity/actions/workflows/ci.yml)

A SwiftUI app that shows the identity data of the Xash3D FWGS game client in a single window (player name,
player model, raw identity, public/local IPs, per-server CIDs), keeps an on-disk record (snapshot) via **Save**,
and on **Refresh** re-reads everything, compares it with the record and summarizes the result with a single
status icon.

The app does **not** modify game files, with one exception: name/model editing writes only the `name`/`model`
lines in `config.cfg` and (if present) `userconfig.cfg`. Besides that it writes only its own record
(`profile.json`) and `*.appbak` backups.

## Requirements
macOS 14+, Xcode (Swift 6), [XcodeGen](https://github.com/yonaskolb/XcodeGen). No external dependencies.

## Build and test
```sh
xcodegen generate
xcodebuild -project PlayerIdentity.xcodeproj -scheme PlayerIdentity -destination 'platform=macOS' -derivedDataPath .build build
xcodebuild -project PlayerIdentity.xcodeproj -scheme PlayerIdentity -destination 'platform=macOS' -derivedDataPath .build test
```
The `.xcodeproj` is generated and not tracked in git. Tests never touch the network or the user's real files
(temporary fixture folders, fake HTTP/UDP clients, fake command runner). Total: **279** tests.
The scheme runs tests with the Turkish test language (most assertions compare the Turkish source texts);
`LocalizationTests` switch languages explicitly.

## Run
```sh
open .build/Build/Products/Debug/PlayerIdentity.app
```
Ad-hoc signed; App Sandbox and hardened runtime are disabled. Bundle id: `tr.ercanatay.playeridentity`.
One refresh runs at launch.

Start in a specific language (see [Localization](#localization)):
```sh
open -n .build/Build/Products/Debug/PlayerIdentity.app --args -AppleLanguages '(en)'
open -n .build/Build/Products/Debug/PlayerIdentity.app --args -AppleLanguages '(tr)'
```

| Shortcut | Action |
|---|---|
| ⌘R | Refresh (pressing it during a refresh cancels the previous one; the latest request wins) |
| ⌘S | Save |
| ⌘⏎ | Apply name/model |

## Features
- Single status (green / orange / red) with a list of reasons and a "what to do" suggestion for each reason.
- Ban check (IP / CID) per server, plus a **Fix** flow on banned/unreachable rows.
- IP range display (`/24`, `/16`; IPv6 `/64`, `/48`) and IP range ban detection.
- Name/model dropdowns and **Apply** to update `config.cfg` / `userconfig.cfg`.
- Model previews: BMP thumbnails in the model dropdown and the profile card.
- Server hosts may be hostnames: resolved via DNS (first IPv4, else IPv6, cached 5 min); the row shows
  `host → IP` and, from the ban check's A2S_INFO reply, `map · players/max · ping` (server name in the tooltip).
- **History** window (Window menu, ⌘Y): state changes from `history.jsonl` (5000 entries / 90 days), filter by
  type and server, export as JSON or Markdown.
- **Apply** first shows a preview of the lines to be written (`-`/`+`, line numbers); nothing is written until
  **Write**.
- Update check against GitHub Releases at most once a day at launch and from the app menu; a banner offers
  **Download** / **Ignore**. Network errors are silent; nothing is downloaded automatically.
- Notifications for ban detected/lifted, public IP change, identity change and fix results (not on first run,
  not repeated within 10 minutes); Settings > **Notifications** turns them off.

## Data sources
- **Identity file** (priority order): `~/.config/.xash_id` → `~/.local/.xash_id` → `~/.xash_id` → `<gamedir>/.xash_id`.
  The first readable and valid (16 hex characters) file is used.
- **Name / model:** `config.cfg` in the selected gamedir (`name`, `model`); `userconfig.cfg` overrides it.
- **Public IP:** `https://api.ipify.org?format=json`, fallback `https://ifconfig.me/ip` (8 s timeout).
- **Local IPs:** system interfaces, excluding `lo0` and `fe80::/10`.
- **CID:** `MD5(raw identity, 8 bytes little-endian + IPv4 4 / IPv6 16 bytes)`, 32 lowercase hex characters.

## Data root
The default data root is `~/Library/Application Support/Xash3D FWGS`. Another root can be chosen from the profile
card; the choice is stored in UserDefaults (`dataRoot`) and in the record on Save. Changing it rediscovers the
gamedirs and refreshes. The gamedir is chosen from the picker on the profile card (`valve` is the default if present).

Note: identity files under `~/.config`, `~/.local` and `~` take precedence over the gamedir, so changing only the
data root does not hide an identity file in the home folder.

## Data files
- **Record:** `~/Library/Application Support/tr.ercanatay.playeridentity/profile.json`
  (JSON, `schemaVersion: 1`, atomic write).
  - Only **Save** writes it; Refresh never changes the record.
  - Unsaved changes (data root, gamedir, server list, applied name/model, fix results) show an "unsaved" badge,
    and quitting asks for confirmation.
  - Missing file → "no record" (orange); corrupt file or unsupported schema → red warning. The app keeps running
    and Save creates a new record.
- **Settings (UserDefaults domain `tr.ercanatay.playeridentity`):** `dataRoot`, `banCheckEnabled`,
  `recentNames`, `migration.v2.completed`.

### Migration from the previous bundle
Earlier builds used the bundle id `tr.ercanatay.oyuncukimlik`. On first launch the app migrates once:
- `~/Library/Application Support/tr.ercanatay.oyuncukimlik/profile.json` is copied atomically to the new location
  **only if the new file does not exist yet**. The legacy file is never modified or deleted. A corrupt or
  unsupported legacy record is skipped.
- `dataRoot`, `banCheckEnabled` and `recentNames` are copied from the legacy UserDefaults domain unless the new
  domain already has a value.
- `migration.v2.completed` is then set in the new domain, so the migration never runs again. If copying fails
  (I/O error), the flag stays unset and the next launch retries; the app keeps working either way.
- The migration is skipped while running tests.

## Status colors
| Status | Icon | Meaning |
|---|---|---|
| Green | `checkmark.circle.fill` | No critical issue; every field matches the record |
| Orange | `exclamationmark.triangle.fill` | Non-critical difference/warning: no record, IP/name/model changed, raw identity 0, server CID changed, no local IP, server unreachable |
| Red | `xmark.octagon.fill` | Identity file missing/invalid, public IP unavailable, record unreadable, server ban |

The status is always shown with an icon **and** text. Server rows use the same icons: invalid host → red (does not
affect the overall status), CID different from the record or saved CID empty → orange, equal → green. A server CID is
written to the record only after the row was checked by a Refresh.

## Name and model editing
The app's only write exception: the `name` / `model` lines in `config.cfg` and (if present) `userconfig.cfg` of the
selected gamedir.
- **Effective value:** the engine runs `userconfig.cfg` after `config.cfg`, so a key there wins; the profile card
  shows the source.
- **Dropdowns:** the model list comes from the folder names under `<gamedir>/models/player/` (alphabetical; a current
  model not in the list is shown first; manual entry when the folder is missing). The name list contains the current
  name, the saved name, the last 10 used names (UserDefaults `recentNames`) and a "new name" entry.
- **Apply (⌘⏎):** only changed keys are written; if a key exists in both files both get the same value, if in neither
  it is appended to `config.cfg`. All occurrences are updated; the rest of the file is preserved byte for byte,
  including its line ending style. Writes are atomic; the previous version of every changed file is kept as
  `<file>.appbak` (the game's own `config.cfg.bak` is never touched). Writing is refused while an `xash3d` process
  is running, and a warning banner is shown.
- **Validation:** name 1–31 characters and ≤ 31 bytes (UTF-8), no `"`, `\`, newlines or control characters; model
  1–32 characters, only `A-Z a-z 0-9 _ -`. Apply is disabled when invalid.
- After Apply the files are re-read and the record becomes "unsaved"; Save writes the new name/model to `profile.json`.

## Ban check
On every Refresh, one UDP check triple runs for each server row with a valid IP (no retries, never joins the game):
1. **A2S_INFO** — is the server up; no reply → unreachable.
2. **getchallenge** — a reply containing `banned` → IP ban; a challenge → no IP block.
3. **connect 49** (only if a challenge was received) — handshake with the row's CID; stops immediately on
   `client_connect`.

4 s per step, at most 12 s in total; at least 10 s between two checks of the same server; cancelling the refresh
cancels the check.

| Ban column | Meaning | Effect on overall status |
|---|---|---|
| IP ban / CID ban | The server banned this IP / CID | Red + reason |
| No block | No IP block; CID handshake succeeded or the CID check does not apply to this server | — |
| Unreachable / Unknown | No reply / result undetermined | Orange + reason |

The result is stored in the row's `banCheck` field (`status`, `checkedAt`, `detail`) and goes into `profile.json` on
Save (schema 1; older records without this field are still read). The **Ban check** toggle in Settings (on by
default, UserDefaults `banCheckEnabled`) stops all UDP packets when off; previous results stay visible.

## Fix
A **Fix** button appears under the ban icon only for IP ban, CID ban and unreachable rows. Fix is not an unban; the
app reports "resolved" only when the IP really changed and the recheck shows no IP block.
- **IP ban:** confirmation sheet (current IP, steps, 5–20 s outage, risk) → old IP is recorded, the default interface
  is found (`route get default`); Wi-Fi: `networksetup -setairportpower <if> off` → 3 s → `on`; Ethernet:
  `ipconfig set <if> DHCP` (macOS administrator dialog). The app waits up to 45 s for the network (public IP every
  3 s), compares the new IP and rechecks the server if it changed. On error, cancellation or timeout Wi-Fi is always
  turned back on. If the IP did not change, router page / VPN / waiting are suggested.
- **IP range ban:** if the IP changed but is still banned within the same `/16` (IPv6 `/48`), the result is an IP
  range ban; renewing the IP is not suggested, a different network (hotspot/VPN) and an appeal are.
  A new IP in a different range that is still banned lists three possible causes (range ban, plugin/SQL ban,
  `sv_filterban`).
- **CID ban:** no network command. Explanation, copyable appeal text (server, local + UTC time, name, CID, egress IP,
  client, raw reply, check type and an admin checklist), server page (GameTracker) and recheck.
- **Unreachable:** recheck and server page only.
- **Safety:** one fix at a time, at least 60 s between starts, cancellable. Commands come from a fixed allowlist (the
  interface name is read from system output and validated; no user input reaches a command, no shell). The password
  is entered only in the macOS dialog. No server command (banid/removeid etc.) is ever run.

## Model preview
Each row of the model dropdown shows a 20×24 thumbnail; the profile card shows a 56×68 preview of the selected model
(8 pt corners, dark `#1B2432` background, 1 px border; source file path in the tooltip).
- **Source:** the first `.bmp` in `<gamedir>/models/player/<model>/`, case-insensitive in file name and extension,
  alphabetical (e.g. `Robo.bmp`, `TMCM.bmp`, `gman.BMP`). Missing or corrupt image → SF Symbol
  `person.crop.square` placeholder, no error message.
- Decoded with ImageIO, aspect ratio kept, drawn with high-quality interpolation; no 3D rendering.
- **Cache:** in memory only, keyed by (gamedir, model, file mtime); loading runs in the background. Changing the
  gamedir reloads the list and images. Files are read-only.
- macOS 27 hides menu item images by default, so the dropdown uses a native `NSPopUpButton` with
  `preferredImageVisibility = .visible`.

## Suggestions
Each reason has a small gray `→ suggestion` line with a concrete action. Clicking the status label in the top bar
opens a popover listing the suggestions for all current reasons; **Copy** puts the list on the pasteboard as plain
text. All suggestion texts live in one exhaustive mapping (`PlayerIdentity/Core/Suggestions.swift`); adding a reason
code without a suggestion breaks the build.

## Localization
- **Languages:** Turkish (`tr`, the source texts) and English (`en`). App name: tr "Oyuncu Kimlik Kartı",
  en "Player Identity" (`InfoPlist.strings`: `CFBundleDisplayName`, `CFBundleName`).
- **Default:** the system language; any unsupported language falls back to English (`developmentRegion: en`,
  `CFBundleLocalizations: [en, tr]`). Override per launch with `-AppleLanguages '(en)'` or `'(tr)'`.
- **Keys:** English, `area.item` form, e.g. `status.green.title`, `error.identityMissing`, `suggestion.ipBanned`,
  `fix.ipBan.step1`, `appeal.checklist.removeid`, `profile.model`, `network.range`, `server.add`, `a11y.ban`.
  Every user-visible text goes through them: buttons, labels, titles, errors, suggestions, confirmations, sheets,
  empty states, tooltips, menu commands, accessibility labels, the ban appeal text and the admin checklist.
- **Code access:** `L10n.text(.statusGreenTitle)` / `L10n.format(.topbarLastCheck, time)`. Keys are cases of the
  generated `L10nKey` enum, so a typo does not compile. Tests can resolve another language with
  `L10n.$bundle.withValue(L10n.languageBundle("en")!) { … }`.
- **Single source:** `tools/l10n_keys.py` holds every key with its Turkish and English value and generates
  `PlayerIdentity/Core/L10nKey.swift` and `PlayerIdentity/Resources/<lang>.lproj/{Localizable,InfoPlist}.strings`.
  Do not edit the generated files by hand.
- **Checks (`LocalizationTests`):** every key has a non-empty value in every language and no table has extra keys;
  placeholders match across languages; English values contain no Turkish letters; Turkish values match the spec
  texts verbatim; English follows the glossary; language selection and fallback; accessibility labels; a source
  scan that fails on user-facing string literals in `PlayerIdentity/App` and `PlayerIdentity/Core`.

### Adding a language
1. Add a column for the new language to each entry in `tools/l10n_keys.py` (and to `INFOPLIST`), and write it
   out in `main()` like `tr`/`en`.
2. Run `python3 tools/l10n_keys.py` to generate `PlayerIdentity/Resources/<lang>.lproj/`.
3. Add the language code to `CFBundleLocalizations` in `project.yml`, then run `xcodegen generate`.
4. Add the language to `LocalizationTests.languages` and run the tests.

## Project layout
```
PlayerIdentity/
  App/            PlayerIdentityApp, AppModel, Views/
  Core/           identity, config, CID, network, snapshot, status, ban check, fix, migration, L10n
  Resources/      tr.lproj, en.lproj (Localizable.strings, InfoPlist.strings; generated)
  Assets.xcassets
PlayerIdentityTests/
tools/            l10n_keys.py (localization source of truth)
project.yml       XcodeGen spec
```

## Known limits (out of scope)
- Writing identity files, launching or joining the game (spawn). No packets are sent to servers except the ban check.
- Multiple profiles, iCloud sync, App Store distribution, sandbox, auto-update.
- Dedicated UI for IPv6 server rows (the CID logic is the same).
- Notifications/timers, periodic background refresh.
- A domain name can be entered as host but is not resolved; CIDs are computed for IP addresses only (a domain-name
  row is shown red as an invalid server address).

## Download

Grab the latest build from [Releases](https://github.com/ercanatay/player-identity/releases/latest):
unzip, move `PlayerIdentity.app` to `/Applications`, then right-click → **Open** on first launch
(the build is ad-hoc signed, not notarized).

## Install (local build)

```bash
xcodegen generate
xcodebuild -project PlayerIdentity.xcodeproj -scheme PlayerIdentity \
  -destination 'platform=macOS' -configuration Release -derivedDataPath .build-release build
ditto .build-release/Build/Products/Release/PlayerIdentity.app /Applications/PlayerIdentity.app
codesign --force --deep --sign - /Applications/PlayerIdentity.app
open /Applications/PlayerIdentity.app
```

The app is ad-hoc signed (not notarized). On first launch macOS may ask for confirmation:
right-click → **Open**, or allow it in **System Settings → Privacy & Security**.

## Design spec

The full design/behaviour specification (Turkish) is in [`docs/spec.md`](docs/spec.md).
It is the single source of truth for behaviour, status colours, localization keys and acceptance criteria.

## License

[MIT](LICENSE) © 2026 Test Player
