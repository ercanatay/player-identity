#!/usr/bin/env bash
# Generate GitHub release notes for a version from CHANGELOG.md.
# Usage: scripts/release-notes.sh <version> [--out <path|->] [--sums <path>] [--signing <text>]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHANGELOG="$ROOT/CHANGELOG.md"
RAW="https://raw.githubusercontent.com/ercanatay/player-identity/main/docs/screenshots"

VERSION=""
OUT="$ROOT/dist/release-notes.md"
SUMS="$ROOT/dist/SHA256SUMS.txt"
SIGNING=""

usage() { echo "usage: $0 <version> [--out <path|->] [--sums <path>] [--signing <text>]" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="${2:?--out needs a value}"; shift 2 ;;
    --sums) SUMS="${2:?--sums needs a value}"; shift 2 ;;
    --signing) SIGNING="${2:?--signing needs a value}"; shift 2 ;;
    -h|--help) usage; echo "Appends docs/release-notes/v<version>.md after the SHA-256 section when that file exists." >&2; exit 0 ;;
    -*) echo "error: unknown option $1" >&2; usage; exit 2 ;;
    *) [ -z "$VERSION" ] || { usage; exit 2; }; VERSION="${1#v}"; shift ;;
  esac
done
[ -n "$VERSION" ] || { usage; exit 2; }
[ -f "$CHANGELOG" ] || { echo "error: $CHANGELOG not found" >&2; exit 1; }

BODY="$(awk -v v="$VERSION" '
  /^## \[/ {
    if (on) exit
    if (index($0, "## [" v "]") == 1) { on = 1; next }
  }
  on { print }
' "$CHANGELOG")"
# Trim leading/trailing blank lines.
BODY="$(printf '%s\n' "$BODY" | sed -e '/./,$!d' | sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}')"

if [ -z "${BODY//[$' \t\n']/}" ]; then
  echo "error: no section '## [$VERSION]' with content in CHANGELOG.md" >&2
  exit 1
fi

render() {
  printf '## Cybokron Player Identity %s\n\n' "$VERSION"
  [ -z "$SIGNING" ] || printf '**Signing:** %s\n\n' "$SIGNING"
  printf '%s\n\n' "$BODY"
  cat <<MD
### Screenshots

![Main window]($RAW/main-light.png)
![Connection diagnosis]($RAW/diagnosis-verdict-light.png)
![Ban matrix with the last 7 days]($RAW/ban-matrix-trend-light.png)

### Requirements

macOS 14 or later · Apple Silicon or Intel · notarized by Apple, opens without a Gatekeeper warning · no telemetry
MD
  if [ -f "$SUMS" ]; then
    printf '\n### SHA-256\n\n```\n'
    cat "$SUMS"
    printf '```\n'
  else
    echo "note: $SUMS not found, skipping SHA-256 section" >&2
  fi
  local legacy="$ROOT/docs/release-notes/v$VERSION.md"
  if [ -f "$legacy" ]; then
    printf '\n---\n\n'
    cat "$legacy"
  fi
}

if [ "$OUT" = "-" ]; then
  render
else
  mkdir -p "$(dirname "$OUT")"
  render > "$OUT"
  echo "wrote $OUT" >&2
fi
