#!/bin/bash
set -euo pipefail

APP_NAME="CodexUsage.app"
APP_DEST="$HOME/Applications/$APP_NAME"
SUPPORT_DIR="$HOME/Library/Application Support/CodexUsage"
LABEL="io.github.yulepapa.codex-usage-menubar"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

case "$APP_DEST" in
    "$HOME/Applications/"*.app) ;;
    *) echo "Refusing unsafe application destination: $APP_DEST" >&2; exit 1 ;;
esac

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
rm -f -- "$PLIST"
rm -rf -- "$APP_DEST"

if [ "${1:-}" = "--purge" ]; then
    rm -rf -- "$SUPPORT_DIR"
else
    rm -f -- "$SUPPORT_DIR/codex-path"
    rmdir "$SUPPORT_DIR" 2>/dev/null || true
fi

echo "Uninstalled Codex Usage"
