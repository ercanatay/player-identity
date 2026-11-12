# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
