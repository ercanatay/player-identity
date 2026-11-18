# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.22.0] - 2026-11-18

### Added
- **Folder-based sync** (spec §71): keep profiles, servers, watched servers, notes and preferences in sync through `playeridentity-sync.json` in a folder you choose (iCloud Drive, a network disk or USB). Records merge by last write, deletions propagate, writes are atomic and a damaged remote file is kept aside instead of overwriting local data.
- **Privacy by design**: ban-list tokens, RCON passwords, CIDs, history and metrics are never written to the sync file, and the interface states that the file is unencrypted plain JSON.

### Notes
- No CloudKit or App Group is used; the file lives in a folder you control.

## [2.21.0] - 2026-11-18

### Added
- **Server browser** (spec §70): query the GoldSrc master server, enrich results with A2S_INFO (map, players, ping, password), then filter and sort them; add a server, diagnose it or refresh it from the list. Addresses are cached in memory for five minutes and on disk for 24 hours (addresses only).
- The browser is localized into all 26 languages.

## [2.20.0] - 2026-11-18

### Added
- **Ban-expiry reminders** (spec §69.1): a timed ban from the ban record schedules a notification ten minutes before it ends and once when it ends, with quiet-hours deferral, per-server opt-out and no duplicate alerts.
- **WidgetKit widget** (spec §69.2): small and medium widgets show the overall status, a shortened CID and your first servers with their ban state, fed by a local snapshot (no IP addresses, no network from the widget).
- Both features are localized into all 26 languages.

### Notes
- Expiry reminders are planned while the app runs; nothing is scheduled while it is closed (documented limit).

## [2.19.0] - 2026-11-17

### Added
- **Server details** (spec §68.1): player list (name, score, time) and searchable server rules via A2S_PLAYER/A2S_RULES, with a `passwordProtected` verdict when `sv_password` is set.
- **Ban record lookup** (spec §68.2): per-server JSON endpoint (`{cid}`/`{ip}` template, optional Keychain token) showing reason, admin, start and remaining time; the unban message is enriched and errors are surfaced.
- **VPN guidance** (spec §68.3): explains that changing the VPN cannot lift a CID ban but may help against an IP ban.

## [2.18.0] - 2026-11-17

### Added
- **CLI diagnosis tools** (spec §67): `diagnose`, `trend` and `report` commands with `--json` (`schemaVersion: 1`) and exit codes `0/4/1/2/3`, so the app can be automated from scripts.
- **Launch the game with logging**: one button opens Xash3D with `-condebug` and confirms when `qconsole.log` appears.
- **Launch summary**: if a server collected two or more ban verdicts in the last seven days, the main window opens with a summary card (dismissible for the day).
- **Spotlight indexing**: servers are searchable in Spotlight and open the matching detail view.

## [2.17.1] - 2026-11-17

### Fixed
- **Right-to-left layout now follows the app language** (not the system language): selecting Arabic or Persian mirrors the whole interface even on an English macOS.
- **Long labels are guarded by a test**: 26 languages are checked against a 190 pt label width, and four translations were shortened (pt/el/uk "copy raw ID", ru "connection diagnosis").

### Changed
- Release notes are generated from `CHANGELOG.md` by `scripts/release-notes.sh` (screenshots and SHA-256 included), so every release body stays consistent.

## [2.17.0] - 2026-11-14

### Added
- **26 languages** (spec §62.2): Azerbaijani and Vietnamese join the interface, so the app now matches cybokron.com exactly — every string (977 keys), every Siri phrase and every bundle name is localized.

## [2.16.0] - 2026-11-14

### Added
- **Siri and Shortcuts phrases in 24 languages** (spec §62.1): every App Intent phrase is now localized, with a `--check` gate that verifies keys, empty values and the `${applicationName}` placeholder.

### Fixed
- **History writes are serialized** (spec §63.1): concurrent `load`, `append` and `compact` no longer race, so rows written during a refresh are kept. Covered by two regression tests.

## [2.15.0] - 2026-11-14

### Added
- **Diagnosis trend in the ban matrix** (spec §66): a "Last 7 days" column shows the run count and the dominant verdict per server (`3 · CID ban`), included in CSV and copy output.
- **Range-ban alert**: a `rangeBanned` verdict explains that the ban covers the whole `/24`–`/16` range and that renewing the IP is not enough; the notification carries a "Copy Unban Message" action.
- **Diagnosis history in reports**: shared Markdown reports now include a "History (last 10 runs)" table and the selected window.
- **Shortcuts actions**: "Diagnose Server" and "Copy Diagnosis Report" App Intents with localized Siri phrases.
- All new strings are localized into 24 languages.

## [2.14.0] - 2026-11-13

### Added
- **Diagnosis trend** (spec §65): per-server summary of past diagnoses over 7 days / 30 days / all time — run count, verdict counts and a colour strip of the last 10 runs, derived from history with no extra storage.
- **Diagnose from the menu bar**: a per-server "Diagnose" action shows progress inline, then the verdict and duration (`CID ban · 1.2 s`); ban verdicts post a single notification that respects quiet hours and per-server settings.
- Diagnostics strings for both features are localized into all 24 languages.

## [2.13.0] - 2026-11-13

### Added
- **Connection diagnosis** (spec §64): a one-click, step-by-step probe (DNS → A2S_INFO → getchallenge → connect 49) that ends in a plain-language verdict — server offline, DNS failure, timeout, protocol mismatch, IP ban, CID ban, range ban, unverified CID, VPN conflict or checks disabled — with suggested actions.
- **Engine log evidence** (read-only): reads the tail of `qconsole.log`/`console.log`, matches known engine errors and lets a direct engine message override the probe verdict.
- **Shareable diagnosis report**: masked Markdown (CID and IP shortened) that can be copied or saved, for pasting into a forum or an admin message.
- Diagnostics strings are localized into all 24 languages.

### Changed
- The l10n toolchain covers all 24 languages (`tools/l10n/<lang>.json`), with `--check` and `--add` and a CI gate.

## [2.12.0] - 2026-11-13

### Added
- **24 languages** (spec §62): the full interface is localized into the same 24 languages as cybokron.com — `tr, en, de, fr, es, it, pt, nl, sv, pl, cs, ro, hu, el, bg, uk, ru, ar, fa, hi, zh-Hans, ja, ko, id` — with 857 keys per language, native language names in Settings, `en` fallback for missing keys and RTL support for Arabic and Persian. A parity gate (`tools/check-l10n-parity.sh`) verifies keys and format placeholders.
- **Multiple profiles** (spec §61): `profiles` + `activeProfileID` in `profile.json`, migration to `Default`, toolbar picker, Settings list (add/rename/delete/default), re-resolution on switch, profile tags on history and metrics rows.
- **Ban-list template library** (spec §59): SourceBans++, AMXBans, HLstatsX and generic CID/IP templates, placeholder validation, "apply to all servers".
- **Menu bar quick actions** (spec §60): status line, copy CID/raw identity, per-server submenu, inline confirmation, clipboard errors recorded.
- **Turkish feature reference** (`docs/FEATURES.tr.md`).

### Fixed
- Update verification now survives an unavailable `spctl` (falls back to `codesign`), tolerates line-ending and casing differences, and never accepts `rejected`.
- Data backups before a version change report skipped files as a `partial` backup and ask for confirmation instead of failing silently.
- The settings-import preview and the applied result now agree on `dataRoot` (`skippedFields`).

## [2.10.3] - 2026-11-13

### Added
- **English feature reference** (`docs/FEATURES.md`): a detailed walkthrough of every window, CLI command, URL scheme, notification rule, backup format, accessibility behaviour and privacy model.
- **Live screenshots** in `docs/screenshots/` (main window light/dark, history, metrics, ban matrix, settings, backup & restore, updates, per-server notifications) plus a 1024 pt app icon.

### Changed
- The app's visible name is now **Cybokron Player Identity** (Turkish: **Cybokron Oyuncu Kimlik Kartı**): Dock, menu bar, window title, Finder, the CLI messages and the Homebrew cask name. The bundle identifier (`tr.ercanatay.playeridentity`), the `PlayerIdentity.app` file name, the data folder and the repository stay the same, so updates, settings and the Homebrew cask keep working.
- README now leads with the app icon and a screenshot gallery, and links to the feature reference.

## [2.10.2] - 2026-11-12

### Changed
- Test suite grows to 730 tests.
- README describes the deploy-key tap sync (`TAP_DEPLOY_KEY`) instead of a token-free tap.

### Fixed
- `errors.json` is now created empty (`[]` list) at launch when missing, so diagnostics always include it; an existing file is never overwritten.

## [2.10.1] - 2026-11-12

### Added
- Persistent `errors.json` error log (last 50 entries), written atomically; diagnostics report its state as `errorLogStatus`.
- Tap flow that no longer requires a `TAP_TOKEN`.

### Changed
- Test suite grows to 727 tests.

## [2.10.0] - 2026-11-12

### Added
- CLI backup, restore, servers and diagnostics commands in `playeridentityctl`.
- `playeridentity://` URL scheme.
- `errors.json` in the diagnostic bundle.
- Keyboard and VoiceOver accessibility improvements.
- Per-server notification thresholds.
- CodeQL, Dependabot and secret scanning; release cask verification.

### Changed
- Test suite grows to 720 tests.

## [2.9.3] - 2026-11-12

### Added
- CLI `update --check` and `update --install` (with `--yes`, `--app`, `--json`); documented exit codes.

### Fixed
- Stricter dataRoot symlink and preview validation.
- Updates must pass Gatekeeper as `Notarized Developer ID`.

## [2.9.2] - 2026-11-12

### Fixed
- Automatic backup and restore run in the background; failures are reported.
- Update checks use timeouts; stuck updaters are killed (SIGKILL).
- Updates are verified with Gatekeeper before install.
- Backup manifest counters are verified; old manifests are pruned by modification time.
- `autoBackupEnabled` is respected in archives.
- Settings import is locked against concurrent runs and reports its result.
- Pre-downloaded update files are cleaned up.
- Installation blocking shows the reason.

## [2.9.1] - 2026-11-11

### Fixed
- Toolbar overflow: flexible title and compact toolbar layout when space is tight.
- Restore now rolls back on failure; missing backups are warned about.
- Erase is locked and partial deletes are guarded.
- Unsaved changes prompt before closing.
- Automatic backup errors, appeal reminders, relaunch errors and cancel/error messages are reported instead of failing silently.

## [2.9.0] - 2026-11-11

### Added
- Add servers from URLs (GameTracker, `steam://connect`) or pasted `host:port` lists, with preview and duplicate/invalid detection (up to 100 entries per import).


## [2.7.0] - 2026-11-10

### Changed
- Redesigned History, Ban Matrix and Metrics windows to match the main window's design language
  (new toolbar, filter chips, narrow-width behaviour, metrics chart card).

## [2.6.0] - 2026-11-10

### Added
- Reset Settings and Erase All Data in Settings.

### Changed
- Redesigned main window and Settings following the Claude Design handoff (light and dark, TR/EN).

## [2.5.0] - 2026-11-10

### Added
- Settings and server export/import (Settings only or Settings + servers; merge or replace).
- Design briefs for the UI redesign.

## [2.4.0] - 2026-11-10

### Added
- Homebrew cask distribution.
- Previews for downloaded models.
- Notification categories and quiet hours.

## [2.3.0] - 2026-11-09

### Added
- Watched servers with change notifications (ban changes, online/offline, map changes).
- Multi-source model catalogue.
- Userconfig override removal (remove `name`/`model` override lines, with backup).

## [2.2.2] - 2026-11-09

### Changed
- Formatted release notes in the update sheet.

## [2.2.1] - 2026-11-09

### Added
- Metrics sampling for Fix and CLI runs.
- Expanded Shortcuts phrases.
- UI smoke test.

## [2.2.0] - 2026-11-09

### Added
- Appeal tracking with reminders.
- Interfaces/VPN information.
- Ban matrix.
- Metrics charts.
- Ban-list URL.
- Diagnostics bundle.
- App Intents (Shortcuts and Siri).

## [2.1.0] - 2026-11-09

### Added
- Runtime language selector (Turkish / English).

## [2.0.0] - 2026-11-09

### Added
- Join game (`+connect`).
- Menu bar item and launch at login.
- Server groups and favourites.
- Notes and appeals.
- Share card (1200×630 PNG with CID and QR code).
- `playeridentityctl` command-line tool.

## [1.2.1] - 2026-11-09

### Fixed
- Clean termination of the app during an update.

### Changed
- Unified manual update check.

## [1.2.0] - 2026-11-09

### Added
- In-app updates and downgrade, with data backup before installing an older version.

## [1.1.0] - 2026-11-09

### Added
- Developer ID signing and notarization.
- First public release.

## [1.0.0] - 2026-11-08

### Added
- Initial release.

[2.22.0]: https://github.com/ercanatay/player-identity/releases/tag/v2.22.0
[2.21.0]: https://github.com/ercanatay/player-identity/releases/tag/v2.21.0
[2.20.0]: https://github.com/ercanatay/player-identity/releases/tag/v2.20.0
[2.19.0]: https://github.com/ercanatay/player-identity/releases/tag/v2.19.0
[2.18.0]: https://github.com/ercanatay/player-identity/releases/tag/v2.18.0
[2.17.1]: https://github.com/ercanatay/player-identity/releases/tag/v2.17.1
[2.17.0]: https://github.com/ercanatay/player-identity/releases/tag/v2.17.0
[2.16.0]: https://github.com/ercanatay/player-identity/releases/tag/v2.16.0
[2.15.0]: https://github.com/ercanatay/player-identity/releases/tag/v2.15.0
[2.14.0]: https://github.com/ercanatay/player-identity/releases/tag/v2.14.0
[2.13.0]: https://github.com/ercanatay/player-identity/releases/tag/v2.13.0
[2.12.0]: https://github.com/ercanatay/player-identity/releases/tag/v2.12.0
[2.7.0]: https://github.com/ercanatay/player-identity/releases/tag/v2.7.0
[2.6.0]: https://github.com/ercanatay/player-identity/releases/tag/v2.6.0
[2.5.0]: https://github.com/ercanatay/player-identity/releases/tag/v2.5.0
[2.4.0]: https://github.com/ercanatay/player-identity/releases/tag/v2.4.0
[2.3.0]: https://github.com/ercanatay/player-identity/releases/tag/v2.3.0
[2.2.2]: https://github.com/ercanatay/player-identity/releases/tag/v2.2.2
[2.2.1]: https://github.com/ercanatay/player-identity/releases/tag/v2.2.1
[2.2.0]: https://github.com/ercanatay/player-identity/releases/tag/v2.2.0
[2.1.0]: https://github.com/ercanatay/player-identity/releases/tag/v2.1.0
[2.0.0]: https://github.com/ercanatay/player-identity/releases/tag/v2.0.0
[1.2.1]: https://github.com/ercanatay/player-identity/releases/tag/v1.2.1
[1.2.0]: https://github.com/ercanatay/player-identity/releases/tag/v1.2.0
[1.1.0]: https://github.com/ercanatay/player-identity/releases/tag/v1.1.0
[1.0.0]: https://github.com/ercanatay/player-identity/releases/tag/v1.0.0
