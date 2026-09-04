#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT="$ROOT/.build/test"
APP="$TEST_ROOT/CodexUsage.app"
OUTPUT="$TEST_ROOT/fixture-output.json"

for script in "$ROOT"/Scripts/*.sh; do
    bash -n "$script"
done
plutil -lint "$ROOT/Resources/Info.plist" >/dev/null

if grep -RInE --exclude=test.sh --exclude-dir=.build --exclude-dir=.git \
    '/Users/|Asia/Seoul|com\.yulepapa|\.aside/' "$ROOT"; then
    echo "Machine-specific value found in public source" >&2
    exit 1
fi

rm -rf "$TEST_ROOT"
mkdir -p "$TEST_ROOT"
BUILD_ROOT="$TEST_ROOT/build" "$ROOT/Scripts/build.sh" "$APP"
"$APP/Contents/MacOS/CodexUsage" \
    --parse-fixture "$ROOT/Tests/Fixtures/rate-limits.json" > "$OUTPUT"

[ "$(plutil -extract windows.0.usedPercent raw -o - "$OUTPUT")" = "34" ]
[ "$(plutil -extract windows.1.usedPercent raw -o - "$OUTPUT")" = "77" ]
[ "$(plutil -extract credits.availableCount raw -o - "$OUTPUT")" = "2" ]
[ "$(plutil -extract bucketLabel raw -o - "$OUTPUT")" = "Codex" ]

ORIGINAL_HASH="$(shasum -a 256 "$APP/Contents/MacOS/CodexUsage" | awk '{print $1}')"
if ARCHS=unsupported "$ROOT/Scripts/build.sh" "$APP" >/dev/null 2>&1; then
    echo "Invalid architecture unexpectedly succeeded" >&2
    exit 1
fi
PRESERVED_HASH="$(shasum -a 256 "$APP/Contents/MacOS/CodexUsage" | awk '{print $1}')"
[ "$ORIGINAL_HASH" = "$PRESERVED_HASH" ] || {
    echo "A failed build replaced the last good app" >&2
    exit 1
}

if [ "${LIVE:-0}" = "1" ]; then
    "$APP/Contents/MacOS/CodexUsage" --print-usage
fi

echo "All tests passed"
