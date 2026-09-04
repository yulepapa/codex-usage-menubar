#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="CodexUsage.app"
APP_PARENT="$HOME/Applications"
APP_DEST="$APP_PARENT/$APP_NAME"
SUPPORT_DIR="$HOME/Library/Application Support/CodexUsage"
LAUNCH_AGENT_DIR="$HOME/Library/LaunchAgents"
LABEL="io.github.yulepapa.codex-usage-menubar"
PLIST="$LAUNCH_AGENT_DIR/$LABEL.plist"

case "$APP_DEST" in
    "$HOME/Applications/"*.app) ;;
    *) echo "Refusing unsafe application destination: $APP_DEST" >&2; exit 1 ;;
esac

find_codex() {
    if [ -n "${CODEX_PATH:-}" ] && [ -x "$CODEX_PATH" ]; then
        printf '%s\n' "$CODEX_PATH"
        return 0
    fi

    if command -v codex >/dev/null 2>&1; then
        command -v codex
        return 0
    fi

    for candidate in \
        "$HOME/.local/bin/codex" \
        "$HOME/.volta/bin/codex" \
        "$HOME/.bun/bin/codex" \
        "$HOME/.asdf/shims/codex" \
        "$HOME/.local/share/mise/shims/codex" \
        /opt/homebrew/bin/codex \
        /usr/local/bin/codex; do
        if [ -x "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

if ! CODEX_EXECUTABLE="$(find_codex)"; then
    cat >&2 <<'EOF'
Codex CLI was not found.
Install and sign in to Codex first, or run:
  CODEX_PATH=/absolute/path/to/codex ./Scripts/install.sh
EOF
    exit 1
fi

case "$CODEX_EXECUTABLE" in
    /*) ;;
    *)
        CODEX_EXECUTABLE="$(cd "$(dirname "$CODEX_EXECUTABLE")" && pwd)/$(basename "$CODEX_EXECUTABLE")"
        ;;
esac
"$CODEX_EXECUTABLE" --version >/dev/null

if [ -n "${CODEX_USAGE_REFRESH_SECONDS:-}" ]; then
    case "$CODEX_USAGE_REFRESH_SECONDS" in
        *[!0-9]*|'')
            echo "CODEX_USAGE_REFRESH_SECONDS must be an integer of at least 60." >&2
            exit 1
            ;;
    esac
    if [ "$CODEX_USAGE_REFRESH_SECONDS" -lt 60 ]; then
        echo "CODEX_USAGE_REFRESH_SECONDS must be at least 60." >&2
        exit 1
    fi
fi

BUILD_APP="$ROOT/.build/$APP_NAME"
"$ROOT/Scripts/build.sh" "$BUILD_APP"

mkdir -p "$APP_PARENT" "$SUPPORT_DIR" "$LAUNCH_AGENT_DIR"
INSTALL_STAGE="$(mktemp -d "$APP_PARENT/.codexusage-install.XXXXXX")"
STAGE_APP="$INSTALL_STAGE/$APP_NAME"
STAGE_PLIST="$INSTALL_STAGE/$LABEL.plist"
PREVIOUS_DIR="$INSTALL_STAGE/previous"
CONFIG_STAGE="$INSTALL_STAGE/codex-path"

cleanup() {
    rm -rf -- "$INSTALL_STAGE"
}
trap cleanup EXIT

/usr/bin/ditto "$BUILD_APP" "$STAGE_APP"
xattr -dr com.apple.quarantine "$STAGE_APP" 2>/dev/null || true
codesign --verify --deep --strict "$STAGE_APP"

plutil -create xml1 "$STAGE_PLIST"
plutil -insert Label -string "$LABEL" "$STAGE_PLIST"
plutil -insert ProgramArguments -json '[]' "$STAGE_PLIST"
plutil -insert ProgramArguments.0 -string "$APP_DEST/Contents/MacOS/CodexUsage" "$STAGE_PLIST"
plutil -insert EnvironmentVariables -json '{}' "$STAGE_PLIST"
plutil -insert EnvironmentVariables.CODEX_PATH -string "$CODEX_EXECUTABLE" "$STAGE_PLIST"
if [ -n "${CODEX_USAGE_REFRESH_SECONDS:-}" ]; then
    plutil -insert EnvironmentVariables.CODEX_USAGE_REFRESH_SECONDS -string "$CODEX_USAGE_REFRESH_SECONDS" "$STAGE_PLIST"
fi
plutil -insert LimitLoadToSessionType -string Aqua "$STAGE_PLIST"
plutil -insert ProcessType -string Interactive "$STAGE_PLIST"
plutil -insert RunAtLoad -bool YES "$STAGE_PLIST"
plutil -insert ThrottleInterval -integer 10 "$STAGE_PLIST"
chmod 644 "$STAGE_PLIST"
xattr -d com.apple.quarantine "$STAGE_PLIST" 2>/dev/null || true
plutil -lint "$STAGE_PLIST" >/dev/null

printf '%s\n' "$CODEX_EXECUTABLE" > "$CONFIG_STAGE"
chmod 600 "$CONFIG_STAGE"

DOMAIN="gui/$(id -u)"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
mkdir -p "$PREVIOUS_DIR"
HAD_APP=0
HAD_PLIST=0
if [ -e "$APP_DEST" ]; then
    mv "$APP_DEST" "$PREVIOUS_DIR/$APP_NAME"
    HAD_APP=1
fi
if [ -e "$PLIST" ]; then
    mv "$PLIST" "$PREVIOUS_DIR/$LABEL.plist"
    HAD_PLIST=1
fi

if ! mv "$STAGE_APP" "$APP_DEST"; then
    if [ "$HAD_APP" -eq 1 ]; then mv "$PREVIOUS_DIR/$APP_NAME" "$APP_DEST"; fi
    if [ "$HAD_PLIST" -eq 1 ]; then mv "$PREVIOUS_DIR/$LABEL.plist" "$PLIST"; fi
    echo "Installation failed; the previous installation was restored." >&2
    exit 1
fi
if ! mv "$STAGE_PLIST" "$PLIST"; then
    rm -rf -- "$APP_DEST"
    if [ "$HAD_APP" -eq 1 ]; then mv "$PREVIOUS_DIR/$APP_NAME" "$APP_DEST"; fi
    if [ "$HAD_PLIST" -eq 1 ]; then mv "$PREVIOUS_DIR/$LABEL.plist" "$PLIST"; fi
    echo "Installation failed; the previous installation was restored." >&2
    exit 1
fi
mv "$CONFIG_STAGE" "$SUPPORT_DIR/codex-path"
rm -rf -- "$PREVIOUS_DIR"

if launchctl bootstrap "$DOMAIN" "$PLIST"; then
    echo "Installed and started $APP_DEST"
else
    /usr/bin/open -g "$APP_DEST" 2>/dev/null || true
    echo "Installed $APP_DEST, but login startup could not be activated in this session." >&2
    echo "The LaunchAgent is installed and will be retried at the next login." >&2
fi
