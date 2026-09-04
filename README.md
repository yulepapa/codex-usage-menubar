# Codex Usage Menu Bar

[![Build](https://github.com/yulepapa/codex-usage-menubar/actions/workflows/build.yml/badge.svg)](https://github.com/yulepapa/codex-usage-menubar/actions/workflows/build.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A small native macOS menu bar app that shows how much Codex usage remains.

The app automatically uses English or Korean based on the preferred macOS language.

## Features

- Shows the remaining percentage directly in the menu bar
- Supports both short and weekly rate-limit windows when Codex provides them
- Shows reset times and available reset credits
- Refreshes every five minutes and after wake
- Includes a manual refresh command
- Runs as a menu bar agent with no Dock icon
- Starts automatically at login when installed with the included script
- Uses native Swift and AppKit with no Python or third-party runtime dependency

## Privacy and security

Codex Usage Menu Bar does not read Codex authentication files or copy access tokens. It starts the locally installed Codex CLI with `codex app-server --stdio` and calls the read-only `account/rateLimits/read` method.

The app:

- does not send data to its own server or any third party
- does not persist usage snapshots to disk
- stores only the detected Codex executable path in `~/Library/Application Support/CodexUsage/codex-path`
- suppresses app-server stderr so credentials cannot accidentally appear in app logs

The Codex CLI still communicates with OpenAI according to the user's own Codex configuration.

## Requirements

- macOS 13 or later
- An installed and authenticated [Codex CLI](https://github.com/openai/codex)
- Xcode Command Line Tools for building from source

Install the command line tools if needed:

```bash
xcode-select --install
```

## Install from source

```bash
git clone https://github.com/yulepapa/codex-usage-menubar.git
cd codex-usage-menubar
./Scripts/install.sh
```

The installer builds the app for the current Mac, installs it at `~/Applications/CodexUsage.app`, and creates a user LaunchAgent for login startup.

If Codex is installed in an unusual location:

```bash
CODEX_PATH=/absolute/path/to/codex ./Scripts/install.sh
```

To change the refresh interval, use a value of at least 60 seconds:

```bash
CODEX_USAGE_REFRESH_SECONDS=120 ./Scripts/install.sh
```

## Usage

The menu bar title shows the remaining percentage. Click it to see:

- each available rate-limit window
- the next reset time
- available reset credits and the earliest expiry
- the last successful refresh time
- manual refresh and quit commands

If you use Hidden Bar, Bartender, or another menu bar manager, a newly created item may start in its hidden section. Expand the manager and Command-drag `Codex` into the always-visible section.

## Build and test

```bash
make build       # native architecture
make universal   # arm64 + x86_64
make test        # offline fixture and packaging checks
make test-live   # also query the locally authenticated Codex CLI
```

The built app is written to `.build/CodexUsage.app`.

A command-line diagnostic is also available:

```bash
.build/CodexUsage.app/Contents/MacOS/CodexUsage --print-usage
```

It prints a sanitized usage payload and never prints authentication material.

## Uninstall

```bash
./Scripts/uninstall.sh
```

Use `--purge` to also remove the application support directory:

```bash
./Scripts/uninstall.sh --purge
```

## Compatibility note

`codex app-server` and `account/rateLimits/read` are currently experimental Codex interfaces. A future Codex release may change them. This project fails closed and shows an error instead of reading authentication files directly.

## 한국어

macOS 기본 언어가 한국어이면 메뉴가 자동으로 한국어로 표시됩니다. 설치 후 메뉴 막대에서 남은 Codex 사용량, 초기화 시각, 초기화권 수를 확인할 수 있습니다. Hidden Bar를 사용한다면 숨김 영역을 펼친 뒤 `⌘` 키를 누른 채 Codex 항목을 세로 구분선 오른쪽으로 옮겨 주세요.

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md).

## Disclaimer

This is an unofficial community project. It is not affiliated with, endorsed by, or supported by OpenAI. Codex and OpenAI are trademarks of their respective owner.

## License

[MIT](LICENSE)
