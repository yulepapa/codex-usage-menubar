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

if grep -RInE --exclude=test.sh --exclude=.git --exclude-dir=.build --exclude-dir=.git --exclude-dir=__pycache__ \
    '/Users/|com\.yulepapa|\.aside/' "$ROOT"; then
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

xcrun swiftc -swift-version 5 -O \
    "$ROOT/Sources/CodexUsage/UsageModels.swift" \
    "$ROOT/Sources/CodexUsage/ResetAutomation.swift" \
    "$ROOT/Tests/ResetStatusTests.swift" -o "$TEST_ROOT/reset-status-tests"
"$TEST_ROOT/reset-status-tests"

xcrun swiftc -swift-version 5 -O \
    "$ROOT/Sources/CodexUsage/UsageModels.swift" \
    "$ROOT/Sources/CodexUsage/ResetEngine.swift" \
    "$ROOT/Tests/ResetEngineTests.swift" -o "$TEST_ROOT/reset-engine-tests"
"$TEST_ROOT/reset-engine-tests"

xcrun swiftc -swift-version 5 -O \
    "$ROOT/Sources/CodexUsage/UsageModels.swift" \
    "$ROOT/Sources/CodexUsage/ResetEngine.swift" \
    "$ROOT/Sources/CodexUsage/ResetAutomation.swift" \
    "$ROOT/Sources/CodexUsage/CodexClient.swift" \
    "$ROOT/Sources/CodexUsage/MenuPresentation.swift" \
    "$ROOT/Tests/MenuPresentationTests.swift" -o "$TEST_ROOT/menu-presentation-tests"
"$TEST_ROOT/menu-presentation-tests"

# A mock app-server records every request. Repeated reads must never dispatch
# consumption, notification, or schedule mutations.
cat > "$TEST_ROOT/mock-codex" <<'MOCK'
#!/bin/bash
while IFS= read -r line; do
    printf '%s\n' "$line" >> "$CODEX_USAGE_MOCK_REQUESTS"
    method="$(printf '%s\n' "$line" | plutil -extract method raw -o - -)"
    case "$method" in
        initialize) printf '%s\n' '{"id":1,"result":{}}' ;;
        initialized) ;;
        account/rateLimits/read) cat "$CODEX_USAGE_MOCK_RESPONSE" ;;
        account/rateLimitResetCredit/consume)
            [ "${CODEX_USAGE_EXPECT_CONSUME:-0}" = "1" ] || { touch "$CODEX_USAGE_MOCK_FORBIDDEN"; exit 1; }
            [ "$(printf '%s\n' "$line" | plutil -extract params.creditId raw -o - -)" = "synthetic-credit" ] || exit 1
            [ "$(printf '%s\n' "$line" | plutil -extract params.idempotencyKey raw -o - -)" = "synthetic-attempt" ] || exit 1
            printf '%s\n' '{"id":2,"result":{"outcome":"alreadyRedeemed"}}' ;;
        *) touch "$CODEX_USAGE_MOCK_FORBIDDEN"; exit 1 ;;
    esac
done
MOCK
chmod 755 "$TEST_ROOT/mock-codex"
sed 's/"result": {/"id": 2, "result": {/' "$ROOT/Tests/Fixtures/rate-limits.json" | tr -d '\n' > "$TEST_ROOT/mock-response.json"
printf '\n' >> "$TEST_ROOT/mock-response.json"
export CODEX_USAGE_MOCK_REQUESTS="$TEST_ROOT/mock-requests.jsonl"
export CODEX_USAGE_MOCK_RESPONSE="$TEST_ROOT/mock-response.json"
export CODEX_USAGE_MOCK_FORBIDDEN="$TEST_ROOT/forbidden-request"
for attempt in 1 2 3; do
    CODEX_PATH="$TEST_ROOT/mock-codex" "$APP/Contents/MacOS/CodexUsage" --print-usage > "$TEST_ROOT/mock-usage-$attempt.json"
    cmp "$OUTPUT" "$TEST_ROOT/mock-usage-$attempt.json"
done
[ ! -e "$CODEX_USAGE_MOCK_FORBIDDEN" ]
[ "$(wc -l < "$CODEX_USAGE_MOCK_REQUESTS" | tr -d ' ')" = "9" ]
echo "Repeated mock app-server requests are read-only"

xcrun swiftc -swift-version 5 -O \
    "$ROOT/Sources/CodexUsage/UsageModels.swift" \
    "$ROOT/Sources/CodexUsage/CodexClient.swift" \
    "$ROOT/Tests/ResetRPCContractTests.swift" -o "$TEST_ROOT/reset-rpc-test"
CODEX_PATH="$TEST_ROOT/mock-codex" CODEX_USAGE_EXPECT_CONSUME=1 "$TEST_ROOT/reset-rpc-test"

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

if command -v python3 >/dev/null 2>&1; then
    PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s "$ROOT/Tests" -p 'test_*.py' -v
else
    echo "Python 3 is required to verify installation and migration" >&2
    exit 1
fi

echo "All tests passed"
