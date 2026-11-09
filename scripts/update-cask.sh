#!/usr/bin/env bash
# Updates Casks/player-identity.rb with a release version and the SHA-256 of its zip (spec §41).
#   scripts/update-cask.sh <version> <sha256>
#   scripts/update-cask.sh <version> --from <dist dir>    (reads SHA256SUMS.txt)
# No secrets, no network. Prints the new cask lines; exits non-zero on malformed input.
set -euo pipefail

cd "$(dirname "$0")/.."
CASK=${CASK_FILE:-Casks/player-identity.rb}
VERSION=${1:-}
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: version must be X.Y.Z, got '$VERSION'" >&2; exit 1; }
if [[ "${2:-}" == "--from" ]]; then
    SUMS="${3:?dist dir missing}/SHA256SUMS.txt"
    SHA=$(awk -v f="PlayerIdentity-$VERSION-macos.zip" '$2 == f { print $1 }' "$SUMS")
else
    SHA=${2:-}
fi
[[ "$SHA" =~ ^[0-9a-f]{64}$ ]] || { echo "error: sha256 must be 64 lowercase hex characters, got '$SHA'" >&2; exit 1; }
[[ -f "$CASK" ]] || { echo "error: $CASK not found" >&2; exit 1; }

tmp=$(mktemp)
sed -E -e "s/^  version \"[^\"]*\"/  version \"$VERSION\"/" \
       -e "s/^  sha256 \"[^\"]*\"/  sha256 \"$SHA\"/" "$CASK" > "$tmp"
grep -q "^  version \"$VERSION\"$" "$tmp" && grep -q "^  sha256 \"$SHA\"$" "$tmp" \
    || { rm -f "$tmp"; echo "error: could not update $CASK" >&2; exit 1; }
mv "$tmp" "$CASK"
if command -v ruby >/dev/null; then ruby -c "$CASK" >/dev/null; fi
grep -E '^  (version|sha256) ' "$CASK"
