#!/usr/bin/env bash
# §73 / spec v2.25 §12 release gate: calibrates the macOS hardware identity check against the REAL official upstream
# build and the INSTALLED engine (T-K1–T-K6). Opt-in and separate from the unit tests (CI never runs it, so the unit
# suite has no skipped test for it); the release checklist runs it and keeps its evidence folder.
#
#   scripts/calibrate-macos-identity.sh
#
# What it does (read-only for the real system, nothing is launched):
#   1. Gets the official upstream "continuous" Apple arm64 asset into a work folder OUTSIDE the repo (reused when the
#      file is already there), records its SHA-256 (and checks a pinned one when given).
#   2. Builds an isolated temporary Upstream.app (Contents/MacOS/xash3d + libxash.dylib + Info.plist) and synthetic
#      identity fixture folders (zero / non-zero / absent) in the work folder. The upstream binary never enters the repo.
#   3. Builds playeridentityctl with DerivedData outside the repo (or uses PI_CAL_CTL) and runs
#      `diagnose --macos-identity --json` with PLAYERIDENTITYCTL_ENGINE_APP / PLAYERIDENTITYCTL_IDENTITY_HOME /
#      PLAYERIDENTITYCTL_SNAPSHOT pointing at the fixtures: the real identity files, game data and app record are
#      never read or written. The installed app is only read (its binaries are hashed before and after).
#   4. Expects: upstream 4/4 static `yes`; installed 0/4 static `no`; upstream+nonzero → supported;
#      upstream+zero → unknown + regenerate; installed+zero/absent → unsupported; installed+nonzero → unknown +
#      download (v2.25 AC-2).
#
# Exit codes: 0 PASS · 1 FAIL (an expectation or a step failed) · 4 NOT CONFIGURED (asset or installed app missing and
# not obtainable): the release gate stays closed, it is never a silent skip.
#
# Environment overrides:
#   PI_CAL_WORK              work folder (default: $TMPDIR/player-identity-calibration); must be outside the repo
#   PI_CAL_ASSET_NAME        default: xash3d-fwgs-apple-arm64.tar.xz
#   PI_CAL_ASSET_URL         default: https://github.com/FWGS/xash3d-fwgs/releases/download/continuous/<name>
#   PI_CAL_UPSTREAM_ASSET    path of an already downloaded asset (default: <work>/<name>; reused when present)
#   PI_CAL_UPSTREAM_SHA256   expected SHA-256 of the asset (optional pin; mismatch = FAIL)
#   PI_CAL_DOWNLOAD          1 (default) download when missing · 0 never download (missing = NOT CONFIGURED)
#   PI_CAL_INSTALLED_APP     default: /Applications/Xash3D-FWGS.app
#   PI_CAL_CTL               playeridentityctl to use (default: build it)
#   PI_CAL_DERIVED_DATA      DerivedData of that build (default: <work>/DerivedData)
#   PI_CAL_EVIDENCE_DIR      evidence folder (default: <work>/evidence-<UTC time>)
set -uo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd -P)

log() { printf '==> %s\n' "$*"; }

physical() { python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1"; }
outside_repo() {
    case "$(physical "$1")/" in "$ROOT"/*) echo "error: $2 ($1) must be outside the repository" >&2; exit 1 ;; esac
}

TMP_BASE=${TMPDIR:-/tmp}
WORK=${PI_CAL_WORK:-$TMP_BASE/player-identity-calibration}
outside_repo "$WORK" PI_CAL_WORK
mkdir -p "$WORK" || { echo "error: cannot create $WORK" >&2; exit 1; }
WORK=$(physical "$WORK")

ASSET_NAME=${PI_CAL_ASSET_NAME:-xash3d-fwgs-apple-arm64.tar.xz}
ASSET_URL=${PI_CAL_ASSET_URL:-https://github.com/FWGS/xash3d-fwgs/releases/download/continuous/$ASSET_NAME}
ASSET=${PI_CAL_UPSTREAM_ASSET:-$WORK/$ASSET_NAME}
EXPECTED_SHA=${PI_CAL_UPSTREAM_SHA256:-}
DOWNLOAD=${PI_CAL_DOWNLOAD:-1}
INSTALLED=${PI_CAL_INSTALLED_APP:-/Applications/Xash3D-FWGS.app}
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
EVIDENCE=${PI_CAL_EVIDENCE_DIR:-$WORK/evidence-$STAMP}
outside_repo "$EVIDENCE" PI_CAL_EVIDENCE_DIR
mkdir -p "$EVIDENCE" || { echo "error: cannot create $EVIDENCE" >&2; exit 1; }
EVIDENCE=$(physical "$EVIDENCE")
SUMMARY="$EVIDENCE/summary.txt"
: >"$SUMMARY"
note() { printf '%s\n' "$*" | tee -a "$SUMMARY"; }

not_configured() {
    note "RESULT: NOT CONFIGURED — $1"
    note "release gate: CLOSED (T-K6; configure the asset/installed app and run again)"
    note "evidence: $EVIDENCE"
    exit 4
}

note "macOS hardware identity calibration (spec v2.25 §12) — $STAMP"
note "repo: $ROOT ($(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo '?'))"
note "work: $WORK"

# 1. Upstream asset ---------------------------------------------------------------------------------------------------
if [[ ! -f "$ASSET" ]]; then
    [[ "$DOWNLOAD" == 1 ]] || not_configured "upstream asset $ASSET missing and PI_CAL_DOWNLOAD=0"
    log "Downloading $ASSET_URL"
    case "$ASSET_URL" in https://*) ;; *) note "RESULT: FAIL — asset URL must be https"; exit 1 ;; esac
    if ! curl -fL --retry 3 --proto '=https' --tlsv1.2 -o "$ASSET.part" "$ASSET_URL"; then
        rm -f "$ASSET.part"
        not_configured "upstream asset could not be downloaded from $ASSET_URL"
    fi
    mv "$ASSET.part" "$ASSET"
    note "asset: downloaded $ASSET_URL"
else
    note "asset: reused $ASSET"
fi
ASSET_SHA=$(shasum -a 256 "$ASSET" | awk '{print $1}')
printf '%s  %s\n' "$ASSET_SHA" "$(basename "$ASSET")" >"$EVIDENCE/asset.sha256"
printf '%s\n' "$ASSET_URL" >"$EVIDENCE/asset-url.txt"
note "asset sha256: $ASSET_SHA"
if [[ -n "$EXPECTED_SHA" && "$EXPECTED_SHA" != "$ASSET_SHA" ]]; then
    note "RESULT: FAIL — asset SHA-256 differs from PI_CAL_UPSTREAM_SHA256 ($EXPECTED_SHA)"
    exit 1
fi

[[ -d "$INSTALLED" && ! -L "$INSTALLED" ]] || not_configured "installed engine $INSTALLED missing"

# 2. Isolated fixtures ------------------------------------------------------------------------------------------------
RUN="$WORK/run-$STAMP"
rm -rf "$RUN"
mkdir -p "$RUN/extract" "$RUN/Upstream.app/Contents/MacOS"
if ! tar -xJf "$ASSET" -C "$RUN/extract" ./xash3d ./libxash.dylib 2>"$EVIDENCE/extract.log"; then
    note "RESULT: FAIL — the asset does not contain ./xash3d and ./libxash.dylib (see extract.log)"
    exit 1
fi
for binary in xash3d libxash.dylib; do
    source="$RUN/extract/$binary"
    if [[ ! -f "$source" || -L "$source" ]]; then note "RESULT: FAIL — $binary is not a regular file"; exit 1; fi
    cp "$source" "$RUN/Upstream.app/Contents/MacOS/$binary"
done
cat >"$RUN/Upstream.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>xash3d</string>
<key>CFBundleShortVersionString</key><string>continuous</string>
</dict></plist>
PLIST
chmod -R a-w "$RUN/Upstream.app"
UPSTREAM="$RUN/Upstream.app"
(cd "$RUN/Upstream.app/Contents/MacOS" && shasum -a 256 xash3d libxash.dylib) >"$EVIDENCE/upstream-binaries.sha256"

# Synthetic identity files (home mask 0x10331C2DCE4C91DB): `zero` stores the mask (raw 0), `nonzero` a fixed value.
mkdir -p "$RUN/home-zero/.config" "$RUN/home-nonzero/.config" "$RUN/home-absent"
printf '10331C2DCE4C91DB\n' >"$RUN/home-zero/.config/.xash_id"
printf '00000000000000AB\n' >"$RUN/home-nonzero/.config/.xash_id"

installed_hashes() {
    (cd "$INSTALLED/Contents/MacOS" && for f in xash3d libxash.dylib; do [[ -f "$f" ]] && shasum -a 256 "$f"; done)
}
installed_hashes >"$EVIDENCE/installed-binaries.before.sha256"

# 3. playeridentityctl ------------------------------------------------------------------------------------------------
CTL=${PI_CAL_CTL:-}
if [[ -z "$CTL" ]]; then
    DERIVED=${PI_CAL_DERIVED_DATA:-$WORK/DerivedData}
    outside_repo "$DERIVED" PI_CAL_DERIVED_DATA
    [[ -d PlayerIdentity.xcodeproj ]] || xcodegen generate >/dev/null
    log "Building playeridentityctl (DerivedData: $DERIVED)"
    if ! xcodebuild -project PlayerIdentity.xcodeproj -scheme PlayerIdentity -configuration Debug \
            -destination 'platform=macOS' -derivedDataPath "$DERIVED" build >"$EVIDENCE/build.log" 2>&1; then
        note "RESULT: FAIL — build failed (see build.log)"
        exit 1
    fi
    CTL="$DERIVED/Build/Products/Debug/PlayerIdentity.app/Contents/Helpers/playeridentityctl"
fi
[[ -x "$CTL" ]] || { note "RESULT: FAIL — playeridentityctl not found at $CTL"; exit 1; }
note "ctl: $CTL ($("$CTL" --version 2>/dev/null | head -1))"

# 4. Cases ------------------------------------------------------------------------------------------------------------
failures=0
mkdir -p "$EVIDENCE/cases"
: >"$EVIDENCE/commands.txt"

# run_case <name> <engine app> <identity home> <expected exit> <expected state> <expected static> <expected count>
#          <expected finding> <expected action>
run_case() {
    local name=$1 app=$2 home=$3 want_exit=$4
    local out="$EVIDENCE/cases/$name.json"
    local command=(env PLAYERIDENTITYCTL_ENGINE_APP="$app" PLAYERIDENTITYCTL_IDENTITY_HOME="$home"
                   PLAYERIDENTITYCTL_SNAPSHOT="$RUN/no-profile.json" "$CTL" diagnose --macos-identity --json)
    printf '%s\n' "${command[*]}" >>"$EVIDENCE/commands.txt"
    "${command[@]}" >"$out" 2>"$EVIDENCE/cases/$name.stderr" </dev/null
    local got_exit=$?
    printf '%s\n' "$got_exit" >"$EVIDENCE/cases/$name.exit"
    local verdict
    verdict=$(python3 - "$out" "$got_exit" "$@" <<'PY'
import json, sys
path, got_exit, name, app, home, want_exit, state, static, count, finding, action = sys.argv[1:12]
try:
    data = json.load(open(path))
except Exception as error:
    print(f"FAIL {name}: unreadable JSON ({error})"); sys.exit(0)
problems = []
def expect(key, value, actual):
    if str(actual) != str(value):
        problems.append(f"{key}={actual} (want {value})")
if data.get("process_state") != "notRunning":
    problems.append(f"process_state={data.get('process_state')} (quit the engine and retry)")
expect("exit", want_exit, got_exit)
expect("state", state, data.get("state"))
expect("static_support", static, data.get("static_support"))
evidence = data.get("evidence") or {}
expect("evidence.count", count, evidence.get("count"))
expect("finding", finding, data.get("finding"))
expect("action", action, data.get("action"))
expect("override_rejected", False, data.get("override_rejected"))
for forbidden in ("raw", "raw_id", "cid", "serial"):
    if forbidden in data:
        problems.append(f"forbidden field {forbidden}")
text = open(path).read().lower()
for secret in ("10331c2dce4c91db", "00000000000000ab"):
    if secret in text:
        problems.append("a fixture value leaked into the output")
k = [evidence.get(key) for key in ("k1_iokit_linked", "k2_corefoundation_linked", "k3_ioregistry_access",
                                     "k4_platform_serial_string")]
summary = (f"{name}: state={data.get('state')} finding={data.get('finding')} action={data.get('action')} "
           f"static={data.get('static_support')} {evidence.get('count')}/4 K1-K4={k} "
           f"hash={data.get('engine_hash_short')} exit={got_exit}")
print(("FAIL " + summary + " :: " + "; ".join(problems)) if problems else ("ok   " + summary))
PY
)
    note "$verdict"
    [[ "$verdict" == ok* ]] || failures=$((failures + 1))
}

#        name               app          home                 exit state        static count finding                  action
run_case upstream-nonzero   "$UPSTREAM"  "$RUN/home-nonzero"  0    supported    yes    4     healthy                  none            # T-K1, T-K3
run_case upstream-zero      "$UPSTREAM"  "$RUN/home-zero"     2    unknown      yes    4     zero                     regenerate      # T-K4
run_case upstream-absent    "$UPSTREAM"  "$RUN/home-absent"   2    unknown      yes    4     notGenerated             regenerate
run_case installed-zero     "$INSTALLED" "$RUN/home-zero"     1    unsupported  no     0     unsupported              downloadEngine  # T-K2, T-K5
run_case installed-absent   "$INSTALLED" "$RUN/home-absent"   1    unsupported  no     0     unsupported              downloadEngine  # T-K5
run_case installed-nonzero  "$INSTALLED" "$RUN/home-nonzero"  2    unknown      no     0     nonzeroWithoutEvidence   downloadEngine  # AC-2

installed_hashes >"$EVIDENCE/installed-binaries.after.sha256"
if cmp -s "$EVIDENCE/installed-binaries.before.sha256" "$EVIDENCE/installed-binaries.after.sha256"; then
    note "ok   installed engine binaries unchanged (sha256 before = after)"
else
    note "FAIL installed engine binaries changed during the run"
    failures=$((failures + 1))
fi
for fixture in "$RUN/home-zero/.config/.xash_id" "$RUN/home-nonzero/.config/.xash_id"; do
    shasum -a 256 "$fixture" >>"$EVIDENCE/fixtures.sha256"
done
[[ -e "$RUN/home-absent/.config/.xash_id" ]] && { note "FAIL the absent fixture gained an identity file"; failures=$((failures + 1)); }

python3 - "$EVIDENCE" "$failures" "$ASSET_SHA" "$ASSET_URL" "$INSTALLED" "$STAMP" <<'PY'
import glob, json, os, sys
evidence, failures, sha, url, installed, stamp = sys.argv[1:7]
cases = {}
for path in sorted(glob.glob(os.path.join(evidence, "cases", "*.json"))):
    name = os.path.basename(path)[:-5]
    try:
        data = json.load(open(path))
    except Exception:
        data = {}
    exit_code = open(os.path.join(evidence, "cases", name + ".exit")).read().strip()
    cases[name] = {key: data.get(key) for key in ("state", "finding", "action", "static_support", "evidence",
                                                   "engine_hash_short", "process_state", "raw_state")}
    cases[name]["exit"] = int(exit_code) if exit_code.lstrip("-").isdigit() else exit_code
json.dump({"timestamp": stamp, "result": "PASS" if failures == "0" else "FAIL", "asset_url": url,
           "asset_sha256": sha, "installed_app": installed, "cases": cases},
          open(os.path.join(evidence, "summary.json"), "w"), indent=2, sort_keys=True)
PY

if [[ "$failures" == 0 ]]; then
    note "RESULT: PASS — upstream 4/4 yes, installed 0/4 no; release gate T-K1–T-K5 satisfied"
    status=0
else
    note "RESULT: FAIL — $failures problem(s); release gate CLOSED"
    status=1
fi
note "evidence: $EVIDENCE"
chmod -R u+w "$RUN" 2>/dev/null
exit "$status"
