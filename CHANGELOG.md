# Changelog

## 1.2.6 — 2026-10-10

- 주간 잔여량 막대의 검은 끝점을 제거하고, 응답의 10080분 구간 길이와 초기화 시각으로 계산한 남은 시간 참고 눈금을 표시합니다.
- 균등 사용 기준 대비 차이와 산식을 툴팁·키보드 초점·상세에 제공합니다. 조회 실패·결측·만료와 조기 리셋 후 이전 응답에는 눈금을 숨기고 새 응답에서 다시 계산합니다.
- 5시간 구간, 리셋권 디자인과 자동 사용 조건은 유지합니다.

## 1.2.5 — 2026-10-07

- 앱 표시 이름을 코코(COCO, Codex Companion)로 바꾸고 팝오버·메뉴바·정보 화면과 한국어 안내를 맞췄습니다.
- 기존 앱 파일·실행 파일·번들 ID·설정·감시기 경로는 유지합니다. v1.2.4의 팝오버 외부 클릭 닫힘 수정도 이어집니다.

## 1.2.4 — 2026-10-07

- Close the popover when another app or menu bar item is clicked or the app loses focus; stop the outside-click monitor when the popover closes or the app exits.
- Keep clicks inside the popover and the status item's repeat-click toggle unchanged.

## 1.2.3 — 2026-10-06

- Show the selected credit's Seoul expiry directly on its collapsed ticket; keep unknown or expired data explicit rather than inventing an active credit.
- Shorten the small card position to `1 / 2`, label the auto-use switch on/off in text, and move the final-20-minute/usage-independent rule into Details.
- Replace the footer refresh word with an icon while retaining its full click target, tooltip, VoiceOver label and Command-R shortcut. Keep menu-bar usage and redemption policy unchanged.

## 1.2.2 — 2026-10-06

- Show a separate selectable tab for every observed reset credit. Four to six credits fit in the existing popover; additional tabs scroll horizontally with at least 44 pt of clickable width each.
- Keep expiry order, selection, keyboard browsing and display-only card actions. Add native fixture checks for each card's hover and click target across four, five and six credits.

## 1.2.1 — 2026-10-06

- Show distinct, fresh reset credits as overlapping cards ordered by expiry, with stable ID tie-breaking and a small hover lift.
- Select a card to reveal its expiry; click a selected non-default card again to return to the earliest credit. Default selection follows new earlier credits while explicit selections survive refresh by identity.
- Limit the visible stack to three cards and provide previous/next navigation with position labels for every observed card. Keep unknown, stale, expired and count-only data explicit; disclose count/list mismatches.
- Keep card actions display-only, with keyboard navigation and Reduce Motion support. Automatic use, saved settings, worker policy and durable result warnings remain independent of selection.
- Add synthetic model, coordinate hit-testing, hover ordering, selection refresh, many-card, keyboard and callback-isolation checks.

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
