#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v python3 >/dev/null 2>&1 || {
    echo "Python 3.9 or later from the Mac developer tools is required." >&2
    exit 1
}
exec python3 "$ROOT/Scripts/installation.py" install "$@"
