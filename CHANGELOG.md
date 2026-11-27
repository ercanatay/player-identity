# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.27.2] - 2026-11-27

### Fixed
- **The broker runs in its own folder** (spec §78): the app starts the broker with the folder of its binary as working directory, so a broker that looks for its Steam library next to itself finds it.
- **The ticket generator is always set explicitly** (spec §78): both methods put `+set cl_ticket_generator <value>` on the launch line — `revemu2013` for Standard, `steam` for Steam — so a value the engine saved in `config.cfg` can no longer turn a Standard join into a Steam one. The app still writes nothing to the game folder.

### Added
- **A broker outdated by a Steam restart is noticed** (spec §79): a broker whose process started before the Steam client is *stale* (read-only check of the two start times; no Steam credential or ticket is read). When Steam quits, a broker the app started is stopped; one you started yourself is only marked stale.
- The row menu then reads **With Steam identity (restart broker)**, and Settings › Connection Paths shows "Steam restarted — restart the broker" with a **Restart** button (restarts with the `<host>:<port>` argument). Nothing is started or connected until you choose it; a failure shows a clear message with a pointer to the settings.
- 5 new localization keys (`steam.join.steamAuthRestart`, `steam.state.stale`, `steam.settings.stale`, `steam.settings.restart`, `steam.error.stale`).

## [2.27.1] - 2026-11-27

### Added
- **Broker discovery** (spec §77): the usual places are checked read-only (`~/Documents/steam-broker/steam-broker`, `~/Applications/Steam Broker.app/Contents/MacOS/steam-broker`, `/opt/homebrew/bin/steam-broker`, `/usr/local/bin/steam-broker`); only executable regular files count (no symbolic links or folders). Settings › Connection Paths has **Use Found Broker**, which writes the first candidate with your confirmation and never replaces a path that is already set (it only tells you that another broker was found).
- **Clearer Steam entry in the row menu**: without a broker path it is disabled with the help text "Choose the Steam broker path in Settings › Connection Paths"; with a path and a stopped broker it reads **With Steam identity (start broker)** and starts the broker after the privacy consent; a broker that fails to start or listen shows an error with a button to the settings.
- 7 new localization keys (`steam.join.steamAuthStart`, `steam.settings.useFound*`, `steam.settings.notFound`, `steam.settings.foundOther`, `steam.error.settingsHint`); `steam.join.disabledHint` reworded.

## [2.27.0] - 2026-11-27

### Added
- **Join with a Steam identity** (spec §76, optional, off by default): the server row's context menu has **Join with ▾ › Standard / With Steam identity / Steam broker settings…**. The Steam method connects through a local Steam broker the user provides (a third-party tool; the app ships no broker code and no Steam library) and adds only `+set cl_ticket_generator steam` to the launch line — no game configuration file is written and no bind is touched. The **Standard** method's launch line is unchanged. The Steam entry is disabled with a hint until a broker binary path is set, and is marked *Recommended* on GoldSrc 48 servers (the choice stays with the user).
- **Privacy consent at every selection** (no "always" option): connecting with a Steam identity reports the SteamID of the real Steam account to the server. Nothing is started before the user confirms.
- **Settings › Connection Paths**: broker binary path (text field + chooser), port (default 27420 on `127.0.0.1`), live state (not configured / not running / listening / unreachable / *Steam session required*), **Start Broker**, **Stop Broker**, **Check Path**. The app stops only a broker it started itself; the Steam session is estimated only from whether the Steam client process runs (no Steam ID, ticket or cookie is read or stored).
- **Per-server memory** (`identity-memory.json`): last method, last result and date per server; the server row shows **Steam ✓** / **Steam ✗** from the real answer in `engine.log` (connected, disconnect reason, or timeout = undecided). The file holds nothing but the server key, the method, the result and the date.
- **CLI**: `playeridentityctl join --server <host:port> [--identity standard|steam-auth] [--yes] [--json]`; the JSON has an `identity` field (`standard` / `steam_auth`). `steam-auth` fails with a clear error when no broker is configured, and never starts the broker.
- 34 new localization keys (`steam.*`) in all 26 languages.

## [2.26.1] - 2026-11-27

### Added
- **Share card: STATUS and BAN TYPE** (spec §33.1): the 1200×630 card now shows the row's ban status and ban type next to the server, read from the last ban check (no network call). STATUS: **Banned** (IP, range, CID or GoldSrc server ban), **Not banned** (CID OK), **Could not be verified** (GoldSrc unverified, CID unknown, unknown, unreachable), **Not checked**. BAN TYPE: **IP ban**, **IP range ban** (when a range ban is known from the current Fix result or from the history; it wins over a plain IP ban), **CID ban**, **Server connection ban (type unknown)** for GoldSrc (no account, SteamID or IP claim), **Could not be determined**, or "—". A GoldSrc 48 server never reads "Not banned", and there only the GoldSrc ban proof counts: an older Source result saved for the server (e.g. a CID ban) reads *Could not be verified* / *Could not be determined*.
- Colour is never the only signal: a banned status is red with an octagon symbol, an unverified status or uncertain type orange with a triangle; definite IP/CID types red.

### Changed
- **GoldSrc 48 card**: no CID row at all (previously "N/A"), and the QR holds a status-only text — `sunucu=<name>`, `adres=<host:port>`, `durum=<banned|clear|unverified|notChecked>`, `ban=<ip|ipRange|cid|goldSrc|unknown|none>`, `surum=goldsrc48` — never a CID, raw ID, serial, ticket, password or path; a note under the QR says so. **Source 49 cards** keep the CID row and the CID QR unchanged, with STATUS and BAN TYPE added.
- Card layout: server name, status and ban type are measured whole (no character cut before the layout) and wrap to two lines; when the block still does not fit, it shrinks step by step to 75 % (floor), and only then a line ends with "…". The player name and the date never shrink: they wrap to two lines in their own columns. Captions are upper-cased in the card language (Turkish "TARİH").
- A Source 49 row without a CID has no CID row (no "—" placeholder) and no QR.
- The share card is rendered once, after the range ban kept in the history is read; until then the sheet shows a progress indicator and **Copy** / **Save** are disabled.
- 12 new localization keys (`shareCard.status*`, `shareCard.banType*`, `shareCard.qr.statusOnly`) in all 26 languages.

## [2.26.0] - 2026-11-26

### Added
- **GoldSrc 48 servers** (spec §75): the A2S_INFO reply decides the server protocol — a legacy `0x6D` reply with the GoldSrc protocol byte (47/48) or a Source-layout `0x49` reply with protocol byte 48 is `goldsrc48`; a `0x49` reply with protocol byte 49 is `source49`; an empty, truncated, unrecognised or inconsistent reply is `unknown` (no guess). When a server sends both replies, the legacy reply is kept (it is awaited for at most 0.3 s). The parser keeps the Source 49 layout and also stores the game folder, the game description and the legacy reply's address string (never used to connect). Older records without the field read as `unknown`.
- **No real CID to GoldSrc servers**: the real CID is derived and sent only to a server that proved Source 49 (this check's A2S reply or the known protocol), and only after a **CID-less capability probe**: connect 49 with the all-zero placeholder CID (`00000000000000000000000000000000`, never derived from the identity) goes first; a server that answers it with "older protocol ( 48 )" is GoldSrc 48 and never receives the real CID (in the diagnosis it is not even computed). The real CID goes in a second packet **only** when the capability probe was explicitly accepted and the overall time budget is not used up; a ban text to the placeholder is a general/IP ban (no second packet, never a CID ban), and any other or no answer leaves the CID check undecided (`cidUnknown`, `banned: null` — never "not banned"). The automatic check and the diagnosis use the same rule (no legacy `getchallenge steam`/connect 48 without the user's confirmation). A GoldSrc 48 or unknown server gets no connect 49 at all, in the automatic check, the diagnosis and `playeridentityctl ban`. An "older protocol 48" answer makes the server's effective protocol `goldsrc48` (saved with the result: CID N/A, Join Game with `gs`; the diagnosis gives *ban status could not be verified*, not a protocol mismatch) and the result *GoldSrc: unverified*, never "No block".
- **CID on GoldSrc 48 servers**: the row says **N/A** ("CID is not used on this server"), also when its hostname no longer resolves (the protocol is decided before the address); the menu bar has no CID to copy, the share card and the appeal text say N/A, and an old saved CID of the server is removed by the next successful refresh that gets the GoldSrc reply (a failed refresh removes nothing; a failed write is logged as `serverProtocol`). Source 49 servers keep the existing CID.
- **Join game** on a GoldSrc 48 server runs `/usr/bin/open --env XASH3D_BASEDIR=<data root> -a <engine> --args -game <dir> -dev 1 -log +connect <ip>:<port> gs` (no shell; the allowlist accepts exactly this shape): the engine writes its console to `<data root>/engine.log` (with `open` the working directory is `/`, so without `XASH3D_BASEDIR` the log would be lost). Source 49 and unknown servers keep `+connect <ip>:<port>`. The newest A2S result decides; a later failed query does not undo a known GoldSrc result. When the game is running, the confirmation rebuilds the plan with the protocol known at that moment (and launches nothing if the row's address changed meanwhile).
- **GoldSrc ban status from the engine log**: after you leave the game, Refresh (and every diagnosis, also when its A2S query times out) reads the last GoldSrc connect block of `<data root>/engine.log`, read-only, once per refresh and for every server — independent of the network results (a just-added server, an A2S time-out, a DNS failure or ban checks turned off do not stop it; while the hostname does not resolve, the last resolved IP and the server's saved A2S address string are matched, IP literals only, with the row's port); only a fresh Source 49 result of the server wins over it. Only a block for this server's address (host or resolved IP and port), from a session of the last 24 hours and not older than this session's last Join Game counts; another server's or an older block is ignored. "Server issued disconnect. Reason: You have been banned from this server." makes the row **Server ban** (red). A proven ban is kept while later results are unknown, unreachable or unverified; only a newer engine session (or a server that proves Source 49) replaces it — and then with *unverified*, never "no block". A log that exists but cannot be read is written to the error log (`serverProtocol`).
- **One ban-text classifier** for probe replies, the engine log, the UI and the CLI: the standalone word "banned" not negated by one of the three words before it ("You have been banned from this server", "you are banned") — never "bandwidth limit exceeded", "unbanned (from this server)", "you were unbanned", "(you are) not banned from this server", "never banned", "no longer banned".
- **The GoldSrc decision is saved**: a refresh that decides GoldSrc 48 (A2S reply, connect answer or engine log) writes the protocol and the result into the saved record together with the removal of the legacy CID; after a restart a server that times out stays GoldSrc 48 (CID N/A, `gs`, engine log still read). A server known as GoldSrc 48 never reads as "not banned" in the CLI either (`banned: null` after an A2S time-out or a DNS failure; `status --json` derives the protocol from the saved GoldSrc result).
- **Never "no block" on GoldSrc 48**: the automatic check of a GoldSrc 48 server gives **GoldSrc: unverified** (orange, with "join the server with Join Game (gs) and leave; the app reads the engine log").
- **Diagnosis on GoldSrc 48 servers**: DNS → A2S_INFO → GoldSrc challenge (`getchallenge steam`) → one GoldSrc connect 48 probe (`connect 48 <challenge> "\prot\3\unique\-1\raw\steam\cdkey\<random 32 hex>" "\name\<player name>"` + 512-byte null ticket; no identity, no CID). Both legacy packets are sent only when you start the diagnosis (Diagnose button, menu bar, server browser) or with `playeridentityctl diagnose … --confirm`; without the confirmation no legacy packet at all; never from the automatic check, Shortcuts or a timer.
- Two GoldSrc verdicts: **`banned`** (a ban text from the probe's answer or from the engine log) and **`legacyVerificationUnavailable`** ("The GoldSrc ban status could not be verified." — silence, a ping, a refusal for another reason or an accepted null-ticket probe never mean "no ban"). The GoldSrc card shows "CID is not used on this server", the probe's own answer and its limit, the engine log evidence, the server message, a copyable request for the server administrator and the `gs` join path. The app never calls it an account, SteamID or IP ban and never claims to lift a ban.
- `playeridentityctl diagnose --json`: `protocol`, `cid` (`null` unless Source 49), `cidApplicable`, `goldSrc`, `goldSrcProbe`, `message`, `serverMessage`, `goldSrcEvidence` (`engineLog` / `probe`), `goldSrcEngineLog`, `uniqueness_verified: false`; on GoldSrc 48 `banned` is `true` or `null` (never `false`); `--fail-on-ban` exits `4` for `banned`. `ban --json` adds `protocol` and `cidApplicable` and prints `cid: null` unless the server proved Source 49 (a server saved as GoldSrc 48 never gets a CID computed); `ban --json` and `status --json` print `banned: null` for an unverified GoldSrc result.

### Release gate
- `scripts/verify-goldsrc-connection.sh --confirm` (AC-75.R1, opt-in, user-confirmed, never in CI) checks the **production path**: an APFS clone of the game data, then the app's own code (`scripts/goldsrc-gate/main.swift` built with PlayerIdentity/Core) — the A2S check decides the protocol, GameLauncher builds the Join Game plan and the allowlisted runner launches the installed engine through `open --env XASH3D_BASEDIR=<clone> … -dev 1 -log +connect <ip:port> gs`. Asserted: the argv, the running engine's arguments and environment (not the direct `-dev 2` test), `<clone>/engine.log` (and no `/engine.log`), "Trying to connect with GoldSrc 48 protocol", the server's answer read by GoldSrcEngineLog, the null-ticket probe alone never saying "not banned", the diagnosis with the engine log reaching the engine's answer, and the real engine, game data and identity files unchanged. On 2026-11-26 against 192.0.2.10:27015 it **passed**: engine "You have been banned from this server."; probe alone `legacyVerificationUnavailable` / `banned: null` / `cid: null` (the server refused the null ticket: "Sorry, no-steam p48 clients are not allowed on this server"); with the engine log `banned` / `banned: true`.

### Limits
- The probe uses a null ticket: a server that requires a Steam ticket refuses it, and a ban given after the connection is established is not visible to a probe that never opens a player session. Only the engine log of a real connection (or a ban text in the probe's answer) shows a ban.
- `engine.log` contains the console only when the engine was started with `-dev` and `-log` and `XASH3D_BASEDIR` (Join Game does this for GoldSrc 48 servers); a game started another way leaves the status unverified.
- A server whose protocol is unknown (no A2S reply, a damaged reply, or a protocol byte other than 48/49) no longer gets the CID test (connect 49); its ban status is decided by the IP check only.
- With Join Game on a GoldSrc 48 server the engine runs in developer mode 1 (extra console notices on screen).

### Notes
- New texts carry English placeholders in the 24 languages other than Turkish and English until they are translated.

## [2.25.0] - 2026-11-21

### Added
- **Install Compatible Engine** (spec §74): when the macOS hardware identity card says *Not supported* (engine without hardware-identity indicators, identity zero or missing, engine closed), the card offers **Install Compatible Engine** as its primary action; the official release page stays as a secondary link. The app reads only the release API first and shows a confirmation with the source (`FWGS/xash3d-fwgs`, `continuous` prerelease), the commit, the asset name and size, the engine path, the files that change (engine app + the 2 game libraries of the active game folder; identity files are only backed up), the backup location and the current masked CID.
- **CID change warning**: the confirmation says "This update may create a new identity (CID). A ban or account record on a server may not match the new identity." and must be accepted before anything is downloaded or written. After the install the card compares the identity before and after (masked CIDs only) and shows "The identity changed: before → after" when it changed.
- Install progress on the card (download bytes/total and percentage, SHA-256 check, extraction, signature check, pre-flight, backup, install, rollback), announced to VoiceOver. Cancel is offered only while downloading or extracting; once the backup starts the install completes or rolls back.
- The engine is never opened on its own: after the install the card asks you to open it once (an **Open Engine** button), quit it at the main menu and press Refresh. "Installed" is never "supported": the card says *Installed, verifying* until the core verification finds the global and game folder identities non-zero and equal (`identityRepaired` / `alreadyHealthy`).
- Failures, rollbacks (with the kept backup path), an incomplete rollback (critical), cancelled runs and leftovers are shown with their `EngineInstallFailure` code and written to the diagnostics error log (`engineInstall` area).
- Settings → Data → **Engine backups**: the backup inventory (newest 3 kept) and **Delete Older Backups…** with an explicit confirmation; a changed folder or a partial failure is shown, nothing is deleted automatically.
- `playeridentityctl engine status [--json]` (offline), `engine install-compatible [--yes] [--json]` (y/N with the CID warning on a terminal; without one `--yes` is required; JSON lines progress; exit `0` installed, `1` usage / no `--yes`, `2` failed or incomplete rollback, `3` cancelled / declined / rolled back, `4` not offered), `engine backups [--json]` and `engine backups delete --confirm <code>`.

### Limits
- **Gatekeeper**: the installed engine is ad-hoc signed. If macOS blocks its first launch, open System Settings → Privacy & Security → "Open Anyway" (for this app only) and open the engine again; the app never bypasses this warning. The behaviour on a clean macOS account was **not measured** for this release.
- **Intel Macs**: the install stays closed on x86_64 until the amd64 end-to-end gate passes; the official release page is offered instead.
- The `continuous` upstream build is a prerelease and can change; its digest is read from the release API on every install.

### Release gate
- `scripts/test-engine-installer-e2e.sh` (T-E-GE7, opt-in, arm64): the official asset end to end in a temporary HOME and target with writes to the real `/Applications`, game data and identity files denied; it must pass before a release. It also runs as the manual/scheduled `engine-e2e` workflow, never on every push.

### Notes
- The raw identity and the full CID are never shown, printed or logged; only masked CIDs.
- There is no random identity rotation and no uniqueness claim.
- New texts carry English placeholders in the 24 languages other than Turkish and English until they are translated.

## [2.24.0] - 2026-11-20

### Added
- **macOS hardware identity health** (spec §73): a new main-window card checks, read-only, whether the installed Xash3D engine shows static indicators of deriving the identity from the Mac's hardware (evidence K1–K4 in the engine binaries) and whether the raw identity is non-zero, zero, absent or unreadable. A zero identity is explained plainly: every Mac with a zero identity shares the same CID on each server. "Supported" means "non-zero identity and hardware-identity indicators found"; uniqueness itself is never claimed or verified.
- **Regenerate Identity**: when the engine supports the hardware identity but the identity is zero or missing, the card opens the engine (after a confirmation, only while it is closed) so the engine rebuilds the identity itself. The app never writes or deletes `.xash_id`, never quits the engine and does not refresh on its own.
- **Download Compatible Engine**: when the engine has no hardware identity support, the card opens only the official release page (`https://github.com/FWGS/xash3d-fwgs/releases/tag/continuous`); the app downloads and changes nothing.
- Settings → Data → **Engine app**: choose another Xash3D `.app` (validated: `.app` bundle, no symbolic links, an executable, not inside the data or identity folders — checked on both the written and the physical path, so a link or alias cannot escape it). A refused choice is shown on the card and logged.
- `playeridentityctl diagnose --macos-identity [--json]`: the same check from the command line with exit codes `0` supported, `1` unsupported, `2` unknown, `3` error; `PLAYERIDENTITYCTL_ENGINE_APP` checks another bundle. A rejected override never exits `0` (at least `2`, even when the default engine passes); the JSON separates `requested_engine_path`, `effective_engine_path`, `override_rejected` and `reject_reason`, and adds `process_state`, `package_readability` and `uniqueness_verified: false`.
- `scripts/calibrate-macos-identity.sh`: opt-in release-gate calibration against the real official upstream asset and the installed engine (isolated temporary bundle and identity fixtures outside the repo; upstream 4/4 `yes`, installed 0/4 `no`); `NOT CONFIGURED` (exit 4) keeps the gate closed instead of skipping.

### Safety (independent review, spec v2.25.0)
- The engine process state is a tri-state (`running` / `notRunning` / `unavailable`); a process list that cannot be read is never treated as "not running". While the engine runs (or its state is unknown) nothing is scanned, hashed or read and "Regenerate Identity" stays blocked; after a successful launch the engine is assumed to run until the user quits it and presses Refresh.
- Only a definite `ENOENT` counts as "missing": permission, I/O and other errors make the identity `unreadable` and the engine package `unknown` (unverifiable), never `unsupported` or a download suggestion.
- A non-zero identity without static evidence is now `unknown` (with the compatible engine suggestion), no longer `supported`.
- Structurally broken Mach-O files (load commands, sections, symbol or string tables out of bounds) are `unknown`, never `no`.
- The 3-second scan limit uses a monotonic clock and the scan stops on cancellation at every chunk; a refresh hides the previous result until the new one arrives, and a stale "Regenerate Identity" result never attaches to a newer check.
- A link refused by the allowlist is shown and logged, never silently ignored.
- The process state is taken before an engine override is validated: while the engine runs (or its state is unknown) no bundle, `Info.plist` or binary is read and the requested path is only reported lexically (`engine_path_validated: false`). The full refresh also keeps an unknown process state unknown.
- An identity file reached through a user link in a parent folder (`~`, `~/.config`, `~/.local`, the game folder) is `unreadable`, not followed; system aliases such as `/var` are not links.
- Mach-O checks also reject zero or inconsistent command totals, unaligned command sizes and non-empty file-backed sections or tables at offset 0; a `libxash.dylib` that is not a regular file, or an executable without an execute bit, makes the package unverifiable / not executable.
- A cancelled check (new Refresh or a cancelled CLI command) never reads the identity; a successful "Regenerate Identity" launch marks the engine as running even when its status line belongs to an older check.

### Notes
- The raw identity and the full CID are never shown, printed or logged by this feature; only a state label and a masked CID.
- There is no random identity rotation: the identity comes from the hardware, so the same Mac recreates the same identity.
- New and changed texts carry English placeholders in the 24 languages other than Turkish and English until they are translated.

## [2.23.0] - 2026-11-18

### Added
- **Read-only RCON console** (spec §72): read a server's player list, IP list and bans over RCON with fixed read-only commands (status, stats, listip, banlist, users). There is no free-text input and no write command.
- The RCON password lives only in the Keychain; it is never written to `profile.json`, the sync file, reports or logs, and a dedicated test proves it.
- The console is localized into all 26 languages.

### Notes
- RCON is plain UDP; the interface warns that the password travels unencrypted.

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

[2.23.0]: https://github.com/ercanatay/player-identity/releases/tag/v2.23.0
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
