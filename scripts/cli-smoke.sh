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
# §51: parse errors and the refused --install (stdin is not a terminal) stay offline; --check needs the network
expect 1 "$CTL" update
expect 1 "$CTL" update --check --install
expect 1 "$CTL" update --install
# §52: offline data commands that never write the real data (missing files, read-only list, refused remove)
expect 1 "$CTL" restore
expect 3 "$CTL" restore "$FIXTURES/does-not-exist.zip" --yes
expect 1 "$CTL" servers
expect 1 "$CTL" servers frobnicate
expect 3 env PLAYERIDENTITYCTL_SNAPSHOT="$FIXTURES/does-not-exist.json" "$CTL" servers list
expect 0 env PLAYERIDENTITYCTL_SNAPSHOT="$FIXTURES/cli-status-profile.json" "$CTL" servers list --json
expect 1 env PLAYERIDENTITYCTL_SNAPSHOT="$FIXTURES/cli-status-profile.json" "$CTL" servers remove 1
expect 2 env PLAYERIDENTITYCTL_SNAPSHOT="$FIXTURES/cli-status-profile.json" "$CTL" servers add 2001:db8::9
expect 3 env PLAYERIDENTITYCTL_SNAPSHOT="$FIXTURES/cli-status-profile.json" "$CTL" servers add 192.0.2.20
expect 1 "$CTL" diagnostics --yes

cid=$("$CTL" cid 51.68.190.91 --raw-id 0 </dev/null)
if [[ "$cid" == "d9de0eb4419608a8423241430581e91c" ]]; then echo "ok   cid vector"; else echo "FAIL cid vector: $cid"; failures=$((failures + 1)); fi

[[ $failures == 0 ]] && echo "cli smoke: all passed" || echo "cli smoke: $failures failed"
exit $((failures > 0))
