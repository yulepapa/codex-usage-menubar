#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="${BUILD_ROOT:-$ROOT/.build}"
APP_PATH="${1:-$BUILD_ROOT/CodexUsage.app}"
MIN_MACOS="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
ARCHS="${ARCHS:-$(uname -m)}"
SOURCES=("$ROOT"/Sources/CodexUsage/*.swift)
INFO_PLIST="$ROOT/Resources/Info.plist"

case "$(basename "$APP_PATH")" in
    *.app) ;;
    *) echo "Output path must end in .app" >&2; exit 1 ;;
esac

command -v xcrun >/dev/null 2>&1 || {
    echo "Xcode Command Line Tools are required. Run: xcode-select --install" >&2
    exit 1
}

mkdir -p "$(dirname "$APP_PATH")"
APP_PARENT="$(cd "$(dirname "$APP_PATH")" && pwd)"
APP_BASENAME="$(basename "$APP_PATH")"
APP_PATH="$APP_PARENT/$APP_BASENAME"
STAGE_DIR="$(mktemp -d "$APP_PARENT/.codexusage-build.XXXXXX")"
BACKUP_DIR="$(mktemp -d "$APP_PARENT/.codexusage-backup.XXXXXX")"
STAGE_APP="$STAGE_DIR/$APP_BASENAME"

cleanup() {
    rm -rf -- "$STAGE_DIR" "$BACKUP_DIR"
}
trap cleanup EXIT

mkdir -p "$STAGE_APP/Contents/MacOS" "$STAGE_APP/Contents/Resources" "$STAGE_DIR/objects"
cp "$INFO_PLIST" "$STAGE_APP/Contents/Info.plist"

binaries=()
for arch in $ARCHS; do
    case "$arch" in
        arm64|x86_64) ;;
        *) echo "Unsupported architecture: $arch" >&2; exit 1 ;;
    esac
    output="$STAGE_DIR/objects/CodexUsage-$arch"
    xcrun swiftc \
        -swift-version 5 \
        -target "$arch-apple-macos$MIN_MACOS" \
        -O \
        -framework AppKit \
        -framework Foundation \
        "${SOURCES[@]}" \
        -o "$output"
    binaries+=("$output")
done

if [ "${#binaries[@]}" -eq 1 ]; then
    cp "${binaries[0]}" "$STAGE_APP/Contents/MacOS/CodexUsage"
else
    xcrun lipo -create "${binaries[@]}" -output "$STAGE_APP/Contents/MacOS/CodexUsage"
fi

chmod 755 "$STAGE_APP/Contents/MacOS/CodexUsage"
plutil -lint "$STAGE_APP/Contents/Info.plist" >/dev/null
codesign --force --deep --sign - "$STAGE_APP"
xattr -dr com.apple.quarantine "$STAGE_APP" 2>/dev/null || true
codesign --verify --deep --strict "$STAGE_APP"

HAD_PREVIOUS=0
if [ -e "$APP_PATH" ]; then
    mv "$APP_PATH" "$BACKUP_DIR/$APP_BASENAME"
    HAD_PREVIOUS=1
fi

if ! mv "$STAGE_APP" "$APP_PATH"; then
    if [ "$HAD_PREVIOUS" -eq 1 ]; then
        mv "$BACKUP_DIR/$APP_BASENAME" "$APP_PATH"
    fi
    echo "Could not replace $APP_PATH" >&2
    exit 1
fi

if ! codesign --verify --deep --strict "$APP_PATH"; then
    rm -rf -- "$APP_PATH"
    if [ "$HAD_PREVIOUS" -eq 1 ]; then
        mv "$BACKUP_DIR/$APP_BASENAME" "$APP_PATH"
    fi
    echo "Final app verification failed; the previous build was restored." >&2
    exit 1
fi

rm -rf -- "$BACKUP_DIR"
echo "Built $APP_PATH"
