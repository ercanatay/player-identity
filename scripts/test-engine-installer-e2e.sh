#!/bin/bash
# T-E-GE7 — opt-in release gate for "Install Compatible Engine" (spec E19.9, E20). NOT part of the unit suite.
#
# Live official release API (api.github.com, FWGS/xash3d-fwgs, tag continuous) → exact arm64 asset → API digest →
# pre-scan → extraction → real archive policy → isolated temporary target app with the real bundle topology →
# SDL2 rebuild → codesign verify → exact bundle fallback libraries → engine run with a temporary HOME/data root
# (sandboxed: writes to the real home folder and /Applications are denied; real game data is read-only via -rodir,
# identity and config files excluded) → global/gamedir raw non-zero and equal (masked CID only) → atomic replace +
# injected rollback → the real /Applications engine, the real game data and the real identity files are unchanged.
#
# Network: only the official GitHub API and release-asset hosts. Output and evidence: a temporary folder.
# Usage: scripts/test-engine-installer-e2e.sh
set -euo pipefail
cd "$(dirname "$0")/.."

[[ "$(uname -m)" == "arm64" ]] || { echo "SKIPPED-GATE: arm64 only (D5); the gate is not passed"; exit 3; }

# Physical path: the installer refuses targets reached through a link or alias (/var → /private/var).
WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/pi-engine-e2e.XXXXXX")" && pwd -P)"
EVIDENCE="$WORK/evidence"
mkdir -p "$EVIDENCE"
chmod 700 "$WORK"
echo "work + evidence: $WORK"

REAL_DATA="$HOME/Library/Application Support/Xash3D FWGS"
REAL_APP="/Applications/Xash3D-FWGS.app"

# Fast fingerprint of the real engine, real game data and real identity files (names, sizes, mtimes, inodes; file
# hashes for identity files only). Values are never printed, only compared.
fingerprint() {
    {
        for id in "$HOME/.config/.xash_id" "$HOME/.local/.xash_id" "$HOME/.xash_id" "$REAL_DATA"/*/.xash_id; do
            [[ -f "$id" ]] && shasum -a 256 "$id"
        done
        [[ -e "$REAL_APP" ]] && find "$REAL_APP" -exec stat -f "%N %z %m %i %p" {} + 2>/dev/null
        [[ -e "$REAL_DATA" ]] && find "$REAL_DATA" -exec stat -f "%N %z %m %i %p" {} + 2>/dev/null
    } | shasum -a 256 | cut -c1-16
}
BEFORE="$(fingerprint)"

# Independent API read (the expected commit and digest the driver must see).
curl -fsS --proto '=https' -H "Accept: application/vnd.github+json" \
    https://api.github.com/repos/FWGS/xash3d-fwgs/releases/tags/continuous -o "$EVIDENCE/release.json"
read -r COMMIT DIGEST < <(python3 - "$EVIDENCE/release.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
a = [x for x in d["assets"] if x["name"] == "xash3d-fwgs-apple-arm64.tar.xz"]
print(d["target_commitish"], a[0]["digest"] if len(a) == 1 else "missing")
PY
)
echo "API commit=$COMMIT digest=$DIGEST"

echo "building the driver with PlayerIdentity/Core…"
xcrun swiftc -swift-version 6 -O -target arm64-apple-macos14.0 -module-name EngineE2E \
    PlayerIdentity/Core/*.swift scripts/engine-installer-e2e/main.swift -o "$WORK/e2e" >"$EVIDENCE/build.log" 2>&1 \
    || { tail -30 "$EVIDENCE/build.log"; echo "E2E RESULT: FAIL (build)"; exit 1; }

set +e
"$WORK/e2e" "$WORK/run" "$COMMIT" "$DIGEST" | tee "$EVIDENCE/e2e.log"
STATUS=${PIPESTATUS[0]}
set -e

AFTER="$(fingerprint)"
if [[ "$BEFORE" == "$AFTER" ]]; then
    echo "PASS real /Applications engine, real game data and real identity files unchanged" | tee -a "$EVIDENCE/e2e.log"
else
    echo "FAIL the real system changed during the run" | tee -a "$EVIDENCE/e2e.log"
    STATUS=1
fi
echo "evidence: $EVIDENCE"
[[ $STATUS -eq 0 ]] && echo "T-E-GE7: PASS" || echo "T-E-GE7: FAIL"
exit $STATUS
