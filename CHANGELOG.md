# Changelog

## 1.1.2 — 2026-10-06

- Block new redemptions of other credits while any prior result remains unconfirmed, including the retry delay and process restart.
- Reconcile only saved pending intents with their original keys; keep review warnings until every uncertain result is resolved.
- Preserve expiry reminders while new consumption is held; add multi-credit, response-loss, fresh-read and separate-process lease regressions.

## 1.1.1 — 2026-10-05

- Reduce the main menu to usage, credit count/expiry and auto-use; move normal state/history/notification settings into Details.
- Show concise actionable expiry/login/worker/notification warnings only when needed.
- Add 20 presentation checks without changing redemption or notification policy.

## 1.1.0 — 2026-10-05

- Native single-worker reset use with fresh eligibility checks, durable recovery and process lease.
- Independent menu switches; native expiry reminders at 1 hour, 20 minutes and 5 minutes.
- Explicit legacy handoff and recovery helper, protected usage-only installer/uninstaller.
- Sanitized status adapter, fictitious offline preview and reset/time-zone/mock RPC tests.
- Canonical behavior, architecture, operations and validation documentation; provider-neutral project manifest.
- Existing Codex outline icon, usage display and login startup preserved.

## 1.0.0 — 2026-09-03

- Initial native usage display, short/weekly windows, reset details, English/Korean interface, five-minute refresh and login installer.
