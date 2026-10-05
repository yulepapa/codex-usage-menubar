# Security Policy

## Supported versions

Security fixes are applied to the latest release and the `main` branch.

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting feature for this repository. Do not include access tokens, Codex authentication files, or other credentials in an issue, pull request, screenshot, or log.

The app must not read or persist Codex credentials. It should obtain usage only through the locally authenticated Codex CLI and return a sanitized payload.

UI refreshes are read-only. Authorized automatic redemption runs only in the registered background worker, with an exclusive process lock, explicit ownership/settings, fresh core-limit eligibility, and a persisted idempotency key before the RPC. Never run the legacy watcher and native consumer together. An uncertain result must not be converted to success or silently retried with a new key. The worker uses the existing authenticated CLI; it must not read or migrate credentials. Never render raw errors, prompts, credit identifiers, or idempotency keys. Missing, stale, and malformed data must not imply success.
