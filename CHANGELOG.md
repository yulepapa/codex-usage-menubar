# Changelog

## 1.2.0 — 2026-10-06

- Replace the open menu with the approved 660 × 414 native AppKit popover, retaining the closed status-bar icon, default font and numeric format.
- Bundle Paperlogy and Pretendard under OFL; draw live usage gauges, expanding credit ticket and animated auto-use switch.
- Show response-driven single/two-window usage, Seoul reset/expiry times, unknown or failed data and durable reset outcomes without implying consumption success.
- Connect refresh, auto-use and reminder controls to existing settings and wake hooks, with keyboard navigation, Escape, accessible buttons and Reduce Motion support.
- Retain the diagnostic menu export and add a strictly synthetic popover render/lifecycle export. Consumption, worker, ledger and pending protection are unchanged.

## 1.1.5 — 2026-10-06

- Keep the service's nothingToReset warning visible across worker ticks and restarts during the same valid credit's three-minute retry delay.
- Derive that warning from the durable result while fresh reads are pending or fail; preserve higher-priority uncertain results and clear superseded outcomes.
- Persist fresh credit data that invalidates eligibility, so later read failures and restarts cannot revive an obsolete warning.
- Save each successful snapshot before notification cleanup or another credit's read, including a fresh response that omits the current credit.
- Replace the obsolete 10% eligibility threshold in the project manifest with an explicit usage-independent policy.
- Test the menu after 60/120/179 seconds, retry at 180 seconds, stale credit outcomes and manifest/version consistency.

## 1.1.4 — 2026-10-06

- Attempt automatic use in the final 20 minutes regardless of remaining usage; remove the app's 10% threshold.
- Keep fresh credit verification, ownership, durable idempotency, pending-result holds and cooldowns.
- Show the service's nothingToReset result without claiming a successful reset; preserve the existing menu layout.
- Cover time boundaries, 0/8/30/100% remaining, missing usage windows, query failures and uncertain-result recovery with mock tests.

- Install the menu and its bundled background worker in one command, with automatic use initially off and expiry reminders on.
- Preserve existing choices and pending keys during updates; automatically hand off one recognized legacy user service without overlapping consumers.
- Use a durable installation journal and private backups for failure recovery. Uninstall both services together while retaining settings and recovery records.
- Verify installation, updates, removal, interrupted transactions and failures with isolated paths and a mock operating-system adapter.

## 1.1.3 — 2026-10-06

- Preserve consumption holds for missing, expired or changed pending credits while processing expiry reminders for other available credits.
- Apply the same reminder-only path to disappearance during the pre-consume fresh read; never infer consumption success from inventory changes.
- Test auto-use on/off, due alerts, reminder deduplication across restart and disabled reminders during pending holds.

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
