#!/bin/zsh
#
#  update-strings.sh
#  Disk Health
#
#  Copyright © 2026 Advandz Technologies, LLC.
#

# Re-extracts every localizable string from the sources (the same way Xcode does) and merges new keys
# into Resources/Localizable.xcstrings, keeping existing translations. Then lists strings that still
# need translating. Run it after changing user-facing text; translate in Xcode's String Catalog editor
# (open Resources/Localizable.xcstrings) or by editing the JSON.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CATALOG="$ROOT/Resources/Localizable.xcstrings"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "▸ Extracting strings (clean build)…"
swift build --package-path "$ROOT" --scratch-path "$TMP/build" \
  -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$TMP/strings" >/dev/null

echo "▸ Syncing $CATALOG…"
xcrun xcstringstool sync "$CATALOG" --stringsdata "$TMP/strings"/*.stringsdata 2>&1 | grep -v '^notice' || true

python3 - "$CATALOG" <<'PY'
import json, sys
catalog = json.load(open(sys.argv[1], encoding="utf-8"))
strings = catalog["strings"]
langs = sorted({l for v in strings.values() for l in v.get("localizations", {})} - {"en"})
stale = [k for k, v in strings.items() if v.get("extractionState") == "stale"]
print(f"▸ {len(strings)} strings, languages: {', '.join(langs)}")
if stale:
    print(f"  {len(stale)} stale (no longer in the code): " + "; ".join(stale[:10]))
for lang in langs:
    missing = [k for k, v in strings.items()
               if lang not in v.get("localizations", {}) and v.get("extractionState") != "stale"]
    if missing:
        print(f"  {lang}: {len(missing)} untranslated, e.g. " + "; ".join(missing[:5]))
PY
