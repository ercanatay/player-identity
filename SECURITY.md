# Security Policy

## Supported versions

Only the **latest released version** receives security fixes. Older versions are not patched; update to the
latest release (in-app update or `brew upgrade --cask player-identity`).

| Version | Supported |
|---|---|
| Latest release (see [Releases](https://github.com/ercanatay/player-identity/releases/latest)) | Yes |
| Older releases | No |

## Reporting a vulnerability

Please **do not** open a public issue for security problems.

Report privately through GitHub's **private vulnerability reporting**:

1. Go to the repository's **Security** tab.
2. Choose **Report a vulnerability**.
3. Describe the issue, the affected version, the macOS version and steps to reproduce.

Include a `playeridentityctl --version` or the app version from *About*. If the report contains personal data
(IP addresses, CID, home paths), redact it or use the redacted diagnostics bundle from *Settings → General*.

## Verifying a release

Released builds are signed with a Developer ID certificate, notarized by Apple and stapled. Verify a download
before running it:

```sh
# Code signature (deep, strict)
codesign --verify --deep --strict --verbose=2 /Applications/PlayerIdentity.app

# Gatekeeper assessment: expect "accepted" and "source=Notarized Developer ID"
spctl -a -vv -t exec /Applications/PlayerIdentity.app

# Notarization ticket is stapled
xcrun stapler validate /Applications/PlayerIdentity.app

# Checksum of the downloaded ZIP against the published SHA256SUMS.txt
shasum -a 256 -c SHA256SUMS.txt
```

The Homebrew cask installs the same notarized build and its checksum is pinned in the cask.

## What the app writes

The app is read-only by default. Files it writes:

| Path | Purpose |
|---|---|
| `~/Library/Application Support/tr.ercanatay.playeridentity/profile.json` | Your record: identity, servers, notes, appeals, settings |
| `.../history.jsonl`, `.../metrics.jsonl`, `.../watch-state.json` | Event log, ping/player samples, watched-server baseline |
| `.../updates/` | Update downloads, staging, app and data backups |
| `.../*.appbak-*` | Backups made before the app changes a file |
| `config.cfg`, `userconfig.cfg` (game folder) | Only the `name` and `model` lines, and only after you confirm **Apply** or **Remove line**. Backups are kept as `*.appbak`. |
| Diagnostics ZIP | Only when you ask for it; IPs and the home path are redacted |

Writes to game files are refused while the game is running. The game's own `config.cfg.bak` is never touched.

## Network access

| Purpose | Destination |
|---|---|
| Public IP lookup | `api.ipify.org`, fallback `ifconfig.me` (HTTPS) |
| Release feed | `api.github.com` (HTTPS) |
| Ban and server checks | The servers you add, over UDP, rate-limited |
| Hostname resolution | System DNS resolver |

The app sends no telemetry and does not upload your record, notes or history anywhere.

## Update verification chain

In-app updates only install a build that passes every step; any failure aborts and deletes the download:

1. Download over **HTTPS** only from the GitHub release feed.
2. Check the asset **size**.
3. Compare the **SHA-256** with the entry in `SHA256SUMS.txt`.
4. Unzip, then run `codesign --verify --deep --strict`.
5. Check the **TeamIdentifier** and the **bundle identifier**.
6. Check that the **version** equals the release being installed.

The current app is moved to `updates/backup/` before replacement, the quarantine attribute is cleared, and the
app rolls back automatically if the install fails. Automatic install never happens without your action;
automatic download is opt-in.

## Scope

In scope: the macOS app, `playeridentityctl`, the update mechanism, the Homebrew cask and release workflow.
Out of scope: Xash3D FWGS itself and game servers, which are third-party software.
