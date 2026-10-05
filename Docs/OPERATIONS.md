# Operations and recovery

## Local files

| Location | Purpose |
| --- | --- |
| `~/Library/Application Support/CodexUsage/codex-path` | Detected CLI path |
| `~/Library/Application Support/CodexUsage/reset/settings.json` | `autoUse`, `reminders` |
| `…/reset/state.json` | Expiry metadata, notification milestones, persisted consume recovery |
| `…/reset/worker.json` | Selected label, executable and LaunchAgent path |
| `…/reset/ownership.json`, `wake.json`, lock files | Ownership, wake/settings signal and exclusivity |
| `…/reset/worker.stdout.log`, `worker.stderr.log` | Local operational output; do not upload |
| `~/Library/LaunchAgents/<selected-label>.plist` | The single registered worker |
| `~/Library/Application Support/CodexUsage/backups/<timestamp>/` | Portable helper's private recovery backup |

The deployed instance may use a separately chosen app/plist or backup location. Preserve its actual paths. Do not move an active executable, configured support directory or recovery backup during source cleanup. Files are private local data; settings/ledger use owner-only permissions. The fictitious [settings example](../Examples/reset-settings.json) is not a copy of an account.

## Explicit legacy handoff

Build and test first. Select the **existing** legacy LaunchAgent and app rather than creating another consumer. Review the plan and obtain the operating-system/tool approval appropriate to the environment before applying.

```sh
python3 Scripts/reset-worker.py --plan \
  --legacy-plist "$HOME/Library/LaunchAgents/example.reset-watcher.plist" \
  --app "$HOME/Applications/CodexUsage.app" \
  --enable-auto-use

python3 Scripts/reset-worker.py --apply \
  --legacy-plist "$HOME/Library/LaunchAgents/example.reset-watcher.plist" \
  --app "$HOME/Applications/CodexUsage.app" \
  --enable-auto-use
```

`example.reset-watcher` is a fictitious label. Use the actual selected plist. The default legacy directory is `$CODEX_HOME/automations/codex` (or `~/.codex/automations/codex`); `--legacy-dir`, `--built-app` and `--codex-path` override explicit locations. The helper requires the selected legacy script to be exactly `reset_credit_watcher.py` and verifies the existing process. It does not support arbitrary automation formats or an implicit fresh consumer setup.

`--plan` reads selected metadata and validates recovery outcomes only. `--apply` writes backups, support files, bundle and the selected LaunchAgent. Without `--enable-auto-use`, consumption stays off; reminders are enabled. macOS requests notification permission when the menu opens. Merely creating the ownership file cannot activate a worker while the selected plist still points to the old script.

After the old service is stopped, the helper rereads the final ledger so a consumption during staging is not lost. Unresolved legacy recovery blocks migration. The new worker must complete a read, be the only consumer, and the installed menu must launch; otherwise the helper restores the previous app/service. Keep all backups outside Git.

## Rollback

Use the backup path reported by the **same** portable helper:

```sh
python3 Scripts/reset-worker.py --rollback "$HOME/Library/Application Support/CodexUsage/backups/EXAMPLE_TIMESTAMP"
```

This stops the native service, merges any native recovery keys/results into the legacy ledger, restores the old app/plist and starts the legacy service. The original bespoke deployment helper has its own backup path and should be retained for that existing deployment; its backups are not interchangeable with this portable helper. Neither procedure copies credentials.

A backup being present is not evidence that a live rollback has been exercised. Never erase `state.json` to retry an unknown consumption: it can discard the idempotency key.

## Common states

- Unknown/stale or read failure: the worker cannot authorize consumption.
- No credit: no pending successful use is inferred.
- Unconfirmed result with absent/expired credit: hold for review, preserve the key.
- Notification denied: allow CodexUsage in macOS System Settings → Notifications. Focus or banner settings may still suppress display.
- Mac asleep/off: no execution; an expired credit cannot be recovered by a later local wake.

Usage-only uninstall is for installations without a configured reset worker. After reviewing and rolling back/stopping a worker, retain its ledger and backups until all recovery outcomes are known. Do not purge an active worker's support directory.
