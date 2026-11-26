#!/bin/bash
# AC-75.R1 — opt-in, user-confirmed release gate for GoldSrc 48 support (spec §75.10, §75.13). NOT part of the unit
# suite or CI. It checks the PRODUCTION path, not a hand-made engine command:
#
# 1. APFS-clones the game data into a private temporary folder (the real data is only read).
# 2. Builds `scripts/goldsrc-gate/main.swift` with PlayerIdentity/Core and runs the app's own code: the A2S check decides
#    the protocol, GameLauncher builds the Join Game plan and the allowlisted runner launches the installed engine
#    through `/usr/bin/open --env XASH3D_BASEDIR=<clone> -a <engine> --args -game <dir> -dev 1 -log +connect <ip:port> gs`
#    (exactly what "Join Game" runs). Asserted: the argv, the running engine's arguments (no `-dev 2`), that
#    `<clone>/engine.log` is written (and not `/engine.log`), "Trying to connect with GoldSrc 48 protocol" in it, and that
#    GoldSrcEngineLog reads the server's answer for this server after this launch.
# 3. Runs `playeridentityctl diagnose <host:port> --confirm --json` twice: the null-ticket probe alone must never say
#    "not banned" (`banned` null unless the server sent a ban text); with the clone's engine.log the app must reach the
#    engine's answer (a ban is a ban).
# 4. Quits the engine and checks that the real engine app, the real game data and the real identity files are
#    unchanged (the engine reads the real identity, as Join Game does; its data root is the clone).
#
# Network: the target server only. Evidence: a temporary folder (never the repository).
# Usage:  scripts/verify-goldsrc-connection.sh --confirm [host:port]
# Env:    PI_GS_TARGET (default 51.68.190.91:27015), PI_GS_DATA (default ~/Library/Application Support/Xash3D FWGS),
#         PI_GS_GAMEDIR (default valve), PI_GS_WAIT (seconds, default 40), PI_GS_CTL (a playeridentityctl inside an app
#         bundle; default: built into the work folder), PI_GS_WORK, PI_GS_KEEP=1 (keep the clone).
# Exit:   0 PASS, 1 FAIL, 4 NOT CONFIGURED (not confirmed, engine/data missing, engine running, no APFS clone).
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$(pwd)"

CONFIRMED="${PI_GS_CONFIRM:-}"
TARGET="${PI_GS_TARGET:-51.68.190.91:27015}"
for arg in "$@"; do
    case "$arg" in
        --confirm) CONFIRMED=yes ;;
        -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
        -*) echo "unknown option $arg" >&2; exit 4 ;;
        *) TARGET="$arg" ;;
    esac
done
if [[ "$CONFIRMED" != "yes" ]]; then
    echo "NOT CONFIGURED: this gate starts the engine through Join Game and probes $TARGET; run it with --confirm"
    exit 4
fi
[[ "$TARGET" =~ ^[0-9A-Za-z.-]+:[0-9]{1,5}$ ]] || { echo "NOT CONFIGURED: invalid target $TARGET"; exit 4; }

ENGINE="/Applications/Xash3D-FWGS.app"
DATA="${PI_GS_DATA:-$HOME/Library/Application Support/Xash3D FWGS}"
GAMEDIR="${PI_GS_GAMEDIR:-valve}"
WAIT="${PI_GS_WAIT:-40}"
[[ -x "$ENGINE/Contents/MacOS/xash3d" ]] || { echo "NOT CONFIGURED: no engine at $ENGINE (Join Game uses it)"; exit 4; }
[[ -d "$DATA/$GAMEDIR" ]] || { echo "NOT CONFIGURED: no game data at $DATA/$GAMEDIR"; exit 4; }
if pgrep -x xash3d >/dev/null 2>&1; then echo "NOT CONFIGURED: quit the running engine first"; exit 4; fi

mkdir -p "${PI_GS_WORK:-${TMPDIR:-/tmp}}"
WORK="$(cd "$(mktemp -d "${PI_GS_WORK:-${TMPDIR:-/tmp}}/pi-goldsrc-gate.XXXXXX")" && pwd -P)"
chmod 700 "$WORK"
EVIDENCE="$WORK/evidence"
mkdir -p "$EVIDENCE"
echo "work + evidence: $WORK"

stop_engine() {
    pkill -f "$ENGINE/Contents/MacOS/xash3d" 2>/dev/null || true
    for _ in 1 2 3 4 5; do pgrep -f "$ENGINE/Contents/MacOS/xash3d" >/dev/null || return 0; sleep 1; done
    pkill -9 -f "$ENGINE/Contents/MacOS/xash3d" 2>/dev/null || true
}
cleanup() {
    stop_engine
    find "$WORK/data" -name .xash_id -type f -delete 2>/dev/null || true
    if [[ "${PI_GS_KEEP:-}" != 1 ]]; then rm -rf "$WORK/data" "$WORK/dd" "$WORK/empty-data" "$WORK/gate"; fi
}
trap cleanup EXIT

# Fingerprint of the real engine, real game data and real identity files (names, sizes, mtimes, inodes; identity
# files by hash). Values are never printed, only compared.
fingerprint() {
    {
        for id in "$HOME/.config/.xash_id" "$HOME/.local/.xash_id" "$HOME/.xash_id" "$DATA"/*/.xash_id; do
            [[ -f "$id" ]] && shasum -a 256 "$id"
        done
        find "$ENGINE" -exec stat -f "%N %z %m %i %p" {} + 2>/dev/null
        find "$DATA" -exec stat -f "%N %z %m %i %p" {} + 2>/dev/null
    } | shasum -a 256 | cut -c1-16
}
BEFORE="$(fingerprint)"

if ! cp -c -R "$DATA" "$WORK/data" 2>"$EVIDENCE/clone.err"; then
    echo "NOT CONFIGURED: APFS clone failed ($(head -1 "$EVIDENCE/clone.err"))"
    exit 4
fi
rm -f "$WORK/data/engine.log"
echo "ok   game data cloned (APFS): $WORK/data"

echo "building the production-path driver with PlayerIdentity/Core…"
xcrun swiftc -swift-version 6 -O -target "$(uname -m)-apple-macos14.0" -module-name GoldSrcGate \
    PlayerIdentity/Core/*.swift scripts/goldsrc-gate/main.swift -o "$WORK/gate" >"$EVIDENCE/build-gate.log" 2>&1 \
    || { tail -20 "$EVIDENCE/build-gate.log"; echo "GATE RESULT: FAIL (driver build)"; exit 1; }

set +e
"$WORK/gate" "$TARGET" "$WORK/data" "$GAMEDIR" "$WAIT" | tee "$EVIDENCE/production-path.txt"
DRIVER_STATUS=${PIPESTATUS[0]}
set -e
stop_engine
value() { grep -m1 "^$1=" "$EVIDENCE/production-path.txt" | cut -d= -f2- || true; }
ENGINE_OUTCOME="$(value engine_outcome)"
ENGINE_REASON="$(value engine_reason)"
cp "$WORK/data/engine.log" "$EVIDENCE/engine-console.log" 2>/dev/null || true

CTL="${PI_GS_CTL:-}"
if [[ -z "$CTL" ]]; then
    echo "building playeridentityctl…"
    xcodebuild -project "$REPO/PlayerIdentity.xcodeproj" -scheme PlayerIdentity -configuration Debug \
        -derivedDataPath "$WORK/dd" build >"$EVIDENCE/build.log" 2>&1 \
        || { tail -20 "$EVIDENCE/build.log"; echo "GATE RESULT: FAIL (build)"; exit 1; }
    CTL="$WORK/dd/Build/Products/Debug/PlayerIdentity.app/Contents/Helpers/playeridentityctl"
fi

# Two diagnoses (history goes to the work folder, never to the app's data).
record() {
    mkdir -p "$WORK/record-$1"
    python3 - "$WORK/record-$1/profile.json" "$2" <<'PY'
import json, sys
json.dump({"schemaVersion": 1, "savedAt": "2026-01-01T00:00:00Z", "gamedir": "valve", "dataRoot": sys.argv[2],
           "displayName": "", "model": "", "rawID": "", "identitySource": "",
           "network": {"publicIP": "", "lanIPs": []}, "servers": []}, open(sys.argv[1], "w"))
PY
}
mkdir -p "$WORK/empty-data/valve"
record probe "$WORK/empty-data"
record log "$WORK/data"
field() { python3 -c 'import json,sys; v=json.load(open(sys.argv[1])).get(sys.argv[2]); print("null" if v is None else (str(v).lower() if isinstance(v,bool) else v))' "$1" "$2" 2>/dev/null || echo none; }
sleep 5   # servers rate-limit A2S_INFO; back-to-back queries can go unanswered
set +e
PLAYERIDENTITYCTL_SNAPSHOT="$WORK/record-probe/profile.json" "$CTL" diagnose "$TARGET" --confirm --json >"$EVIDENCE/probe.json" 2>"$EVIDENCE/probe.err"
PROBE_STATUS=$?
sleep 5
PLAYERIDENTITYCTL_SNAPSHOT="$WORK/record-log/profile.json" "$CTL" diagnose "$TARGET" --confirm --json >"$EVIDENCE/probe-with-engine-log.json" 2>"$EVIDENCE/probe-with-engine-log.err"
LOG_STATUS=$?
set -e
PROBE_PROTOCOL="$(field "$EVIDENCE/probe.json" protocol)"
PROBE_OUTCOME="$(field "$EVIDENCE/probe.json" goldSrcProbe)"
PROBE_VERDICT="$(field "$EVIDENCE/probe.json" verdict)"
PROBE_BANNED="$(field "$EVIDENCE/probe.json" banned)"
PROBE_CID="$(field "$EVIDENCE/probe.json" cid)"
PROBE_MESSAGE="$(field "$EVIDENCE/probe.json" message)"
LOG_VERDICT="$(field "$EVIDENCE/probe-with-engine-log.json" verdict)"
LOG_BANNED="$(field "$EVIDENCE/probe-with-engine-log.json" banned)"
LOG_EVIDENCE="$(field "$EVIDENCE/probe-with-engine-log.json" goldSrcEvidence)"
LOG_MESSAGE="$(field "$EVIDENCE/probe-with-engine-log.json" serverMessage)"
echo "probe only:       exit=$PROBE_STATUS protocol=$PROBE_PROTOCOL probe=$PROBE_OUTCOME verdict=$PROBE_VERDICT banned=$PROBE_BANNED cid=$PROBE_CID message=$PROBE_MESSAGE"
echo "with engine log:  exit=$LOG_STATUS verdict=$LOG_VERDICT banned=$LOG_BANNED evidence=$LOG_EVIDENCE serverMessage=$LOG_MESSAGE"
EXPECTED_VERDICT=legacyVerificationUnavailable
[[ "$ENGINE_OUTCOME" == banned ]] && EXPECTED_VERDICT=banned

AFTER="$(fingerprint)"
STATUS=0
check() { if [[ "$1" == yes ]]; then echo "ok   $2"; else echo "FAIL $2"; STATUS=1; fi; }
yes_if() { if "$@"; then echo yes; else echo no; fi; }
check "$(yes_if test "$DRIVER_STATUS" = 0)" "production Join Game path (argv, engine arguments, <data root>/engine.log, evidence)"
check "$(yes_if test -n "$ENGINE_OUTCOME" -a "$ENGINE_OUTCOME" != none)" "engine answer read from <data root>/engine.log ($ENGINE_OUTCOME: $ENGINE_REASON)"
check "$(yes_if test "$PROBE_PROTOCOL" = goldsrc48)" "diagnosis detects goldsrc48"
check "$(yes_if test "$PROBE_CID" = null)" "no CID in the GoldSrc diagnosis"
check "$(yes_if test "$PROBE_BANNED" != false -a "$PROBE_VERDICT" != noBan)" "null-ticket probe alone never says \"not banned\" (banned=$PROBE_BANNED, verdict=$PROBE_VERDICT)"
check "$(yes_if test "$LOG_VERDICT" = "$EXPECTED_VERDICT")" "diagnosis with the engine log = engine answer ($LOG_VERDICT, expected $EXPECTED_VERDICT)"
check "$(yes_if test "$BEFORE" = "$AFTER")" "real engine, real game data and real identity files unchanged"

GS_TARGET="$TARGET" GS_ENGINE_OUTCOME="$ENGINE_OUTCOME" GS_ENGINE_REASON="$ENGINE_REASON" \
GS_PROTOCOL="$PROBE_PROTOCOL" GS_OUTCOME="$PROBE_OUTCOME" GS_PVERDICT="$PROBE_VERDICT" GS_PBANNED="$PROBE_BANNED" \
GS_MESSAGE="$PROBE_MESSAGE" GS_LVERDICT="$LOG_VERDICT" GS_LBANNED="$LOG_BANNED" GS_LMESSAGE="$LOG_MESSAGE" \
GS_UNCHANGED="$(yes_if test "$BEFORE" = "$AFTER")" GS_DRIVER="$DRIVER_STATUS" GS_PASS="$STATUS" \
python3 - "$EVIDENCE/summary.json" <<'PY'
import json, os, sys
e = os.environ
json.dump({"target": e["GS_TARGET"], "path": "production Join Game (open --env XASH3D_BASEDIR, -dev 1 -log, gs)",
           "production_path_checks_passed": e["GS_DRIVER"] == "0",
           "engine_outcome": e["GS_ENGINE_OUTCOME"], "engine_reason": e["GS_ENGINE_REASON"],
           "probe_protocol": e["GS_PROTOCOL"], "probe_outcome": e["GS_OUTCOME"], "probe_verdict": e["GS_PVERDICT"],
           "probe_banned": e["GS_PBANNED"], "probe_message": e["GS_MESSAGE"], "engine_log_verdict": e["GS_LVERDICT"],
           "engine_log_banned": e["GS_LBANNED"], "engine_log_server_message": e["GS_LMESSAGE"],
           "real_system_unchanged": e["GS_UNCHANGED"] == "yes", "pass": e["GS_PASS"] == "0"},
          open(sys.argv[1], "w"), indent=2)
PY
# Only the matching console lines are kept as evidence (no config, no identity).
grep -E "Game started at|Trying to connect with GoldSrc 48 protocol|Server issued disconnect|Server message|Spooling demo header|Connecting to" \
    "$EVIDENCE/engine-console.log" >"$EVIDENCE/engine-excerpt.txt" 2>/dev/null || true
rm -f "$EVIDENCE/engine-console.log"
echo "evidence: $EVIDENCE"
[[ $STATUS -eq 0 ]] && echo "GATE RESULT: PASS" || echo "GATE RESULT: FAIL"
exit $STATUS
