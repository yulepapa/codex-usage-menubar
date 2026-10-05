# Codex Usage Menu Bar

Native macOS menu bar usage display with a single background reset-credit worker. Version **1.1.1**. [한국어](README.md)

## Behavior

- Shows the Codex outline icon and the remaining short/weekly usage windows supplied by the locally authenticated Codex CLI.
- Displays available reset credits, expiry, conditional next attempt, recent results and worker/notification status. Missing or stale data stays unknown.
- Primary **Auto-use: On/Off** switch and **Details → Expiry notifications** switch. Normal status narration, history and timing diagnostics stay in Details; actionable warnings remain on the first screen.
- Tries a reset in the final **20 minutes before expiry** only after a fresh core 5-hour or weekly window has **10% or less remaining**. The service makes the final eligibility decision.
- Native reminders **1 hour, 20 minutes and 5 minutes** before expiry. Confirmed use stops reminders. Wake-up coalesces missed thresholds rather than emitting a backlog.
- The registered worker uses `codex app-server --stdio` and the published account read/consume RPCs. It starts **no model turn** and reads no authentication files.

The Mac must be awake and logged in. No cloud execution, wake scheduler or power-setting change is included. Quitting the menu leaves the worker running; switch automatic use off in the menu to stop redemption. Notification permission and macOS Focus/banner settings determine visibility.

## Build and test

Requires macOS 13+, Xcode Command Line Tools and an authenticated Codex CLI for live reads. The application is Swift/AppKit/UserNotifications; the reviewed legacy handoff helper additionally needs Python 3.9+.

```sh
make test        # offline fixtures, mock RPCs and packaging checks
make build      # current architecture, .build/CodexUsage.app
make universal  # arm64 and x86_64
```

If Command Line Tools are separately installed but another developer directory is selected, use a scoped environment variable rather than changing system settings:

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools make test
```

`make test-live` performs an optional real **read-only** usage query. Offline consumption tests can only reach the guarded mock executable. They do not redeem real credits.

## Install and maintain

For a new usage-only installation with no configured reset worker:

```sh
./Scripts/install.sh
```

This builds to `~/Applications/CodexUsage.app` and registers login startup. `CODEX_PATH` selects a nonstandard CLI location; `CODEX_USAGE_REFRESH_SECONDS` sets menu refresh (minimum 60 seconds). Native worker polling is once per minute while awake.

For an existing legacy reset watcher, follow [the explicit handoff and recovery guide](Docs/OPERATIONS.md). The helper requires the exact existing LaunchAgent and installed app paths, retains the same service label and backs up the app/plist/recovery ledger. Automatic use defaults off unless `--enable-auto-use` is supplied. The usage-only installer/uninstaller refuse a configured worker so they cannot remove its executable or recovery ledger.

Merely opening the menu or invoking `--reset-worker` in a terminal cannot activate another consumer. Do not run the legacy and native consumers together or delete the ledger to fix an uncertain result.

## Diagnostics and development

```sh
.build/CodexUsage.app/Contents/MacOS/CodexUsage --print-usage
.build/CodexUsage.app/Contents/MacOS/CodexUsage --print-native-reset-status
.build/CodexUsage.app/Contents/MacOS/CodexUsage --notification-status
```

These diagnostics do not redeem credits. Keep their output local: sanitized usage and expiry still describe an account. For an offline UI sample:

```sh
CODEX_USAGE_DEVELOPMENT=1 ./Scripts/build.sh .build/CodexUsageDev.app
open -n .build/CodexUsageDev.app --args --preview "$PWD/Tests/Fixtures/ResetPreview" --at 1893452400
```

Fixtures are fictitious 2030 records. The preview has a separate bundle identity and does not start a worker or contact Codex. Dates follow the Mac time zone; tests cover `Asia/Seoul` date boundaries. A legacy read-only adapter is retained for migration preparation; see [architecture](Docs/ARCHITECTURE.md).

## Knowledge and verification

This README is the canonical behavior/build entry point. [Architecture](Docs/ARCHITECTURE.md), [operations and recovery](Docs/OPERATIONS.md), [validation scope](Docs/VALIDATION.md) and the small [provider-neutral manifest](project-manifest.json) support later maintenance and indexing. Update these alongside code changes rather than creating duplicate document copies.

Account state, private logs, CLI auth caches, backups and binaries are excluded from Git. See [SECURITY.md](SECURITY.md). The CLI still communicates with OpenAI using the user's existing login. App-server compatibility can change; failures are shown without reading credentials directly.

MIT for project code. Codex/OpenAI marks remain their owners' property. This is an unofficial project, without OpenAI endorsement.
