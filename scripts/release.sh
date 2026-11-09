#!/usr/bin/env bash
# Builds a release of PlayerIdentity.app and packages it (spec §26):
#   Developer ID available  → sign (hardened runtime, timestamp) → zip → notarize (--wait) → staple → verify → zip
#   no Developer ID identity → ad-hoc build → zip (marked "adhoc")
# Used locally and in CI. Secrets come only from the environment and are never printed.
#
# Environment (all optional):
#   APPLE_TEAM_ID        team of the Developer ID certificate (default GJ3Y762WQ9)
#   SIGN_IDENTITY        codesign identity (name or SHA-1); default: first "Developer ID Application … (TEAM)"
#   SIGN_KEYCHAIN        keychain that holds the identity (CI temporary keychain)
#   ASC_KEY_PATH         App Store Connect API key (.p8) for notarytool
#   ASC_KEY_ID, ASC_ISSUER_ID
#   NOTARIZE             1 = require notarization, 0 = skip; default: 1 if the ASC_* values are set
#   OUTPUT_DIR           default: dist
#   NOTARY_TIMEOUT       notarytool --timeout (default 60m)
#
# Outputs in $OUTPUT_DIR: PlayerIdentity-<version>-macos.zip, SHA256SUMS.txt, release-status.txt
# (notarized | signed | adhoc), notary-submission.json (when notarized).
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
TEAM_ID=${APPLE_TEAM_ID:-GJ3Y762WQ9}
OUTPUT_DIR=${OUTPUT_DIR:-dist}
DERIVED=${DERIVED_DATA:-.build-release}
NOTARY_TIMEOUT=${NOTARY_TIMEOUT:-60m}
ENTITLEMENTS="$ROOT/PlayerIdentity/PlayerIdentity.entitlements"

log() { printf '==> %s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v xcodegen >/dev/null || fail "xcodegen not found"
log "Generating Xcode project"
xcodegen generate >/dev/null

keychain_args=()
[[ -n "${SIGN_KEYCHAIN:-}" ]] && keychain_args=("$SIGN_KEYCHAIN")
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning ${keychain_args[@]+"${keychain_args[@]}"} 2>/dev/null \
        | awk -v team="($TEAM_ID)\"" '/"Developer ID Application: / && index($0, team) { print $2; exit }') || true
fi
if [[ -n "${SIGN_IDENTITY:-}" ]]; then MODE=devid; else MODE=adhoc; fi

if [[ -z "${NOTARIZE:-}" ]]; then
    if [[ -n "${ASC_KEY_PATH:-}" && -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" ]]; then NOTARIZE=1; else NOTARIZE=0; fi
fi
[[ "$MODE" == adhoc && "$NOTARIZE" == 1 ]] && fail "notarization requested but no Developer ID identity found"
if [[ "$NOTARIZE" == 1 ]]; then
    [[ -f "${ASC_KEY_PATH:-}" ]] || fail "ASC_KEY_PATH does not point to a file"
    [[ -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" ]] || fail "ASC_KEY_ID / ASC_ISSUER_ID missing"
fi
log "Signing mode: $MODE, notarize: $NOTARIZE"

build_args=(-project PlayerIdentity.xcodeproj -scheme PlayerIdentity -configuration Release
            -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED")
if [[ "$MODE" == devid ]]; then
    build_args+=("CODE_SIGN_IDENTITY=$SIGN_IDENTITY" "DEVELOPMENT_TEAM=$TEAM_ID")
    [[ -n "${SIGN_KEYCHAIN:-}" ]] && build_args+=("OTHER_CODE_SIGN_FLAGS=--timestamp --options runtime --keychain $SIGN_KEYCHAIN")
else
    build_args+=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= ENABLE_HARDENED_RUNTIME=NO
                 OTHER_CODE_SIGN_FLAGS=)
fi
log "Building (Release)"
xcodebuild "${build_args[@]}" clean build >"$DERIVED.log" 2>&1 || { tail -40 "$DERIVED.log"; fail "xcodebuild failed"; }

APP="$DERIVED/Build/Products/Release/PlayerIdentity.app"
[[ -d "$APP" ]] || fail "missing $APP"
[[ -x "$APP/Contents/Helpers/playeridentityctl" ]] || fail "missing Contents/Helpers/playeridentityctl (§34)"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")
log "Version $VERSION ($BUILD)"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
ZIP="$OUTPUT_DIR/PlayerIdentity-$VERSION-macos.zip"

if [[ "$MODE" == devid ]]; then
    log "Signing with Developer ID (hardened runtime, secure timestamp)"
    keychain_sign=()
    [[ -n "${SIGN_KEYCHAIN:-}" ]] && keychain_sign=(--keychain "$SIGN_KEYCHAIN")
    # §34: nested helpers first (no entitlements), then the app itself; the app seal covers the signed helpers.
    for helper in "$APP"/Contents/Helpers/*; do
        [[ -f "$helper" ]] || continue
        codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" ${keychain_sign[@]+"${keychain_sign[@]}"} "$helper"
    done
    sign_args=(--force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY")
    sign_args+=(${keychain_sign[@]+"${keychain_sign[@]}"})
    codesign "${sign_args[@]}" "$APP"
    codesign --verify --deep --strict --verbose=2 "$APP"
    if codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q "get-task-allow"; then
        fail "get-task-allow entitlement present"
    fi
    STATUS=signed

    if [[ "$NOTARIZE" == 1 ]]; then
        SUBMIT_ZIP="$OUTPUT_DIR/notarize-upload.zip"
        ditto -c -k --sequesterRsrc --keepParent "$APP" "$SUBMIT_ZIP"
        log "Submitting to the notary service (--wait, timeout $NOTARY_TIMEOUT)"
        xcrun notarytool submit "$SUBMIT_ZIP" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" \
            --wait --timeout "$NOTARY_TIMEOUT" --output-format json >"$OUTPUT_DIR/notary-submission.json" || true
        rm -f "$SUBMIT_ZIP"
        SUBMISSION_ID=$(/usr/bin/plutil -extract id raw -o - "$OUTPUT_DIR/notary-submission.json" 2>/dev/null || true)
        NOTARY_STATUS=$(/usr/bin/plutil -extract status raw -o - "$OUTPUT_DIR/notary-submission.json" 2>/dev/null || true)
        log "Submission ${SUBMISSION_ID:-?}: ${NOTARY_STATUS:-unknown}"
        if [[ "$NOTARY_STATUS" != "Accepted" ]]; then
            [[ -n "$SUBMISSION_ID" ]] && xcrun notarytool log "$SUBMISSION_ID" --key "$ASC_KEY_PATH" \
                --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" "$OUTPUT_DIR/notary-log.json" || true
            fail "notarization not accepted"
        fi
        log "Stapling"
        xcrun stapler staple "$APP"
        xcrun stapler validate "$APP"
        spctl -a -vv -t exec "$APP"
        STATUS=notarized
    fi
    codesign --verify --deep --strict --verbose=2 "$APP"
else
    STATUS=adhoc
fi

log "Packaging $ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(cd "$OUTPUT_DIR" && shasum -a 256 "$(basename "$ZIP")" > SHA256SUMS.txt)
echo "$STATUS" > "$OUTPUT_DIR/release-status.txt"

# §41: the Homebrew cask follows the published (notarized) asset; UPDATE_CASK=1 forces it, 0 skips it.
if [[ "${UPDATE_CASK:-}" == 1 || ( -z "${UPDATE_CASK:-}" && "$STATUS" == notarized ) ]]; then
    log "Updating Casks/player-identity.rb"
    scripts/update-cask.sh "$VERSION" --from "$OUTPUT_DIR"
fi
log "Done: $STATUS · $(cat "$OUTPUT_DIR/SHA256SUMS.txt")"
