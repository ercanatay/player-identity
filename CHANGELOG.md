# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
