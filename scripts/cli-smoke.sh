#!/usr/bin/env bash
# Smoke test of the bundled CLI (spec §34). Offline: no network, no identity file, fixture snapshots only.
#   scripts/cli-smoke.sh [path/to/playeridentityctl]
# Default binary: .build/Build/Products/Debug/PlayerIdentity.app/Contents/Helpers/playeridentityctl
set -uo pipefail

cd "$(dirname "$0")/.."
CTL=${1:-.build/Build/Products/Debug/PlayerIdentity.app/Contents/Helpers/playeridentityctl}
FIXTURES=PlayerIdentityTests/Fixtures
[[ -x "$CTL" ]] || { echo "error: $CTL not found (build the PlayerIdentity scheme first)" >&2; exit 1; }

failures=0
# expect <exit code> <command…>; stdin is /dev/null (the never-closed-stdin case is covered by CLITests)
expect() {
    local want=$1; shift
    local out
    out=$("$@" </dev/null 2>&1)
    local got=$?
    if [[ "$got" == "$want" ]]; then
        printf 'ok   (exit %s) %s\n' "$got" "$*"
    else
        printf 'FAIL (exit %s, want %s) %s\n%s\n' "$got" "$want" "$*" "$out"
        failures=$((failures + 1))
    fi
}

expect 0 "$CTL" --version
expect 0 "$CTL" cid 51.68.190.91 --raw-id 0 --json
expect 0 env PLAYERIDENTITYCTL_SNAPSHOT="$FIXTURES/cli-status-profile.json" "$CTL" status --json
expect 3 env PLAYERIDENTITYCTL_SNAPSHOT="$FIXTURES/cli-status-banned.json" "$CTL" status
expect 2 env PLAYERIDENTITYCTL_SNAPSHOT="$FIXTURES/does-not-exist.json" "$CTL" status --json
expect 1 "$CTL" cid
expect 1 "$CTL" ban 192.0.2.1:99999
expect 1 "$CTL" frobnicate

cid=$("$CTL" cid 51.68.190.91 --raw-id 0 </dev/null)
if [[ "$cid" == "d9de0eb4419608a8423241430581e91c" ]]; then echo "ok   cid vector"; else echo "FAIL cid vector: $cid"; failures=$((failures + 1)); fi

[[ $failures == 0 ]] && echo "cli smoke: all passed" || echo "cli smoke: $failures failed"
exit $((failures > 0))
