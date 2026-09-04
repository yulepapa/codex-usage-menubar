# Security Policy

## Supported versions

Security fixes are applied to the latest release and the `main` branch.

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting feature for this repository. Do not include access tokens, Codex authentication files, or other credentials in an issue, pull request, screenshot, or log.

The app must not read or persist Codex credentials. It should obtain usage only through the locally authenticated Codex CLI and return a sanitized payload.
