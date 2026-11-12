#!/usr/bin/env bash
# LEGACY TAP: the main flow no longer needs this — this repository is the tap
# (brew tap ercanatay/tap https://github.com/ercanatay/player-identity). Kept only for the old homebrew-tap repo.
# Sync Casks/player-identity.rb to ercanatay/homebrew-tap using the local gh login.
# Usage: scripts/sync-tap.sh [--dry-run]
set -euo pipefail
cd "$(dirname "$0")/.."
TAP_REPO=${TAP_REPO:-ercanatay/homebrew-tap}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
gh repo clone "$TAP_REPO" "$TMP/tap" -- --depth 1 >/dev/null
mkdir -p "$TMP/tap/Casks"
cp Casks/player-identity.rb "$TMP/tap/Casks/player-identity.rb"
cd "$TMP/tap"
VERSION=$(awk -F'"' '/^  version /{print $2}' Casks/player-identity.rb)
# status (not diff): also catches a brand-new cask file that git diff would miss
if [[ -z "$(git status --porcelain -- Casks/player-identity.rb)" ]]; then echo "tap already up to date ($VERSION)"; exit 0; fi
if [[ "${1:-}" == "--dry-run" ]]; then git --no-pager diff --stat; git status --short -- Casks/player-identity.rb; exit 0; fi
git config user.name "Ercan ATAY"
git config user.email "github@cybokron.com"
git add Casks/player-identity.rb
git commit -m "player-identity $VERSION"
git push origin HEAD:main
echo "tap updated to $VERSION"
