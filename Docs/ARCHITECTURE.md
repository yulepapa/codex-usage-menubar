# Architecture

```mermaid
flowchart LR
    UI[Menu: main.swift] --> Read[CodexClient: account/rateLimits/read]
    UI --> Settings[ResetStore: settings and wake signal]
    Launch[Existing user LaunchAgent] --> Worker[ResetWorker with process lease]
    Worker --> Engine[ResetEngine]
    Engine --> Read
    Engine --> Ledger[Private durable ledger]
    Engine --> Consume[CodexClient: consume with saved idempotency key]
    Engine --> Notify[UserNotifications]
```

`UsageModels.swift` parses sanitized usage and internal reset metadata. Internal credit IDs and recovery keys do not enter the printable payload. `StatusIcon.swift` preserves the existing icon. `CodexClient.swift` owns bounded stdio JSON-RPC and suppresses raw server stderr.

`ResetEngine.swift` contains the clock, freshness, eligibility, notification milestones and durable recovery policy. A core 300-minute or 10080-minute window with at least 90% used allows a conditional attempt in the final 1200 seconds. A second read verifies the same unexpired credit. Settings/ownership are rechecked immediately before consuming. Intent is durably saved first; an uncertain result retries the same key after 180 seconds. Known successful outcomes are terminal. Missing/expired uncertain credits hold further use for review. A five-minute success cooldown limits stale-data effects.

`ResetRuntime.swift` provides the actual CLI service, macOS notifier and serial launchd worker loop. The worker requires both the selected service's `XPC_SERVICE_NAME` and exact executable path. `ResetStore.active()` also validates the selected LaunchAgent points to that executable with `--reset-worker`. A nonblocking exclusive lease prevents a second consumer. The worker checks minute deadlines and wake/settings signals; there is no model process or independent cloud scheduler.

`ResetAutomation.swift` is a read-only compatibility adapter for the prior watcher. It reads only policy, state and a bounded log tail. It is retained for pre-handoff installations and the offline preview. It neither imports Python code nor executes the old watcher.

The menu alone never consumes. The CLI consumption result remains authoritative: `reset`, `alreadyRedeemed`, `nothingToReset` and `noCredit` are distinct. An empty credit list is not proof of redemption. Notification status and redemption status are independent.

The portable Python handoff helper selects an existing legacy service explicitly, checks read-only access, backs up, stages the bundle, stops the old consumer, captures its final ledger, and then repoints the same label. Its optional enable flag governs automatic use. This helper is packaging/operations code; it does not change the installed v1.1.0 Swift runtime.

`MenuPresentation.swift` provides compact, read-only count/expiry presentation and conditional warnings. Normal worker status/history/timing explanations stay in the Details submenu. It changes no consume, notifier or worker policy.
