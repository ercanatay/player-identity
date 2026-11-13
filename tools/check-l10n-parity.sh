#!/usr/bin/env bash
# §62 localization gate: every UI language's Localizable.strings against the `en` reference.
#   - same key set as `en` (missing / extra keys),
#   - same format specifiers per key (`%@`, `%d`, `%1$@`, …; counted by conversion, position ignored),
#   - no empty values.
# Exit 0 and prints `OK` when clean; exit 1 with a language/key list otherwise.
# Usage: tools/check-l10n-parity.sh   (from any directory)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RESOURCES="$ROOT/PlayerIdentity/Resources"
LANGUAGES="tr en de fr es it pt nl sv pl cs ro hu el bg uk ru ar fa hi zh-Hans ja ko id"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for lang in $LANGUAGES; do
  file="$RESOURCES/$lang.lproj/Localizable.strings"
  if [[ ! -f "$file" ]]; then
    echo "missing file" > "$TMP/$lang.error"
    continue
  fi
  if ! plutil -convert json -o "$TMP/$lang.json" "$file" 2>"$TMP/$lang.error"; then
    continue
  fi
  rm -f "$TMP/$lang.error"
done

python3 - "$TMP" $LANGUAGES <<'PY'
import json, os, re, sys
from collections import Counter

tmp, languages = sys.argv[1], sys.argv[2:]
spec = re.compile(r"%(?:\d+\$)?[-+ #0']*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j|L)?([@dDiuUxXoOfFeEgGcCsSpaA%])")

def specifiers(text):
    return Counter(m.group(1) for m in spec.finditer(text) if m.group(1) != "%")

problems = []
tables = {}
for lang in languages:
    error = os.path.join(tmp, lang + ".error")
    if os.path.exists(error):
        problems.append(f"{lang}: unreadable Localizable.strings ({open(error).read().strip() or 'parse error'})")
        continue
    with open(os.path.join(tmp, lang + ".json"), encoding="utf-8") as fh:
        tables[lang] = json.load(fh)

reference = tables.get("en")
if reference is None:
    problems.append("en: reference table missing")
else:
    for lang, table in tables.items():
        for key in sorted(set(reference) - set(table)):
            problems.append(f"{lang}: missing key {key}")
        for key in sorted(set(table) - set(reference)):
            problems.append(f"{lang}: extra key {key}")
        for key in sorted(set(table) & set(reference)):
            value = table[key]
            if not isinstance(value, str) or not value.strip():
                problems.append(f"{lang}: empty value {key}")
                continue
            if specifiers(value) != specifiers(reference[key]):
                problems.append(f"{lang}: format specifiers differ {key}")

if problems:
    print("\n".join(problems))
    print(f"FAILED: {len(problems)} problem(s)")
    sys.exit(1)
print("OK")
PY
