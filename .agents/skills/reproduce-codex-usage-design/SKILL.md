---
name: reproduce-codex-usage-design
description: Reproduce or review the Codex Usage Menu Bar v1.2.3 popover design in local mockups, video frames, or Swift/AppKit implementation. Use when matching its colors, fonts, layout, reset-credit cards, interactions, states, or accessibility against the installed design.
---

# Reproduce Codex Usage Design

1. Read [the project's single design specification](../../../Docs/DESIGN_V1.2.3.md) in full. Take all colors, coordinates, copy, behavior, and version distinctions from that document; do not copy those tokens into this skill.
2. Check the current `project-manifest.json` version and the relevant Swift files named in the specification. If they no longer match v1.2.3, identify the drift before claiming pixel or behavior parity.
3. Work from synthetic fixtures for shareable mockups or video. The `Sources/CodexUsage/PopoverDiagnostics.swift` scenarios and `Tests/Fixtures` are starting points. Keep account snapshots, credit IDs, credentials, and personal paths out of deliverables. Distinguish an offscreen native render from a real installed-app screenshot.
4. For a mockup or video, preserve the specification's fixed view ratio, hierarchy, exact words, font roles, and state-specific data. Show any cinematic zoom or camera motion as presentation, not as app behavior. Treat v4 and the v1.2.2 recommendation image as historical references only.
5. For implementation review, compare code and rendered output in matching states. Include single/two/missing usage windows; 0/1/2/6/7+ credits; count-only, stale, expired, pending, used and failed states; hover, selection return, scroll, keyboard focus, and Reduce Motion. Check that selecting a card is display-only and that the refresh and switch remain accessible.
6. Report the tested version, artifact type, fixture source, pass/fail differences, and limits of verification. Do not claim real notification delivery, VoiceOver speech, physical clicks, or credit consumption from synthetic tests.

Use this skill only within this project. It does not install itself globally or authorize changing the running app, worker, public repository, or a user's reset credits.
