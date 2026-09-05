# Codex Usage Menu Bar

[English](README.md) | **한국어**

[![Build](https://github.com/yulepapa/codex-usage-menubar/actions/workflows/build.yml/badge.svg)](https://github.com/yulepapa/codex-usage-menubar/actions/workflows/build.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

남은 Codex 사용량을 보여 주는 작은 네이티브 macOS 메뉴 막대 앱입니다.

macOS의 선호 언어에 따라 앱이 자동으로 영어 또는 한국어를 사용합니다.

## 주요 기능

- 남은 사용량을 메뉴 막대에 백분율로 바로 표시
- Codex에서 제공하는 경우 단기 및 주간 사용량 제한 구간을 모두 지원
- 초기화 시각과 사용 가능한 초기화권 수를 표시
- 5분마다, 그리고 Mac이 잠자기에서 깨어날 때 자동 새로고침
- 수동 새로고침 명령 제공
- Dock 아이콘 없이 메뉴 막대 앱으로 실행
- 포함된 설치 스크립트로 설치하면 로그인할 때 자동 시작
- Python이나 서드파티 런타임 없이 네이티브 Swift와 AppKit만 사용

## 개인정보 보호 및 보안

Codex Usage Menu Bar는 Codex 인증 파일을 읽거나 액세스 토큰을 복사하지 않습니다. 로컬에 설치된 Codex CLI를 `codex app-server --stdio`로 실행하고 읽기 전용인 `account/rateLimits/read` 메서드를 호출합니다.

이 앱은 다음과 같이 작동합니다.

- 자체 서버나 제3자에게 데이터를 전송하지 않습니다.
- 사용량 스냅샷을 디스크에 저장하지 않습니다.
- 감지된 Codex 실행 파일 경로만 `~/Library/Application Support/CodexUsage/codex-path`에 저장합니다.
- 인증 정보가 앱 로그에 실수로 나타나지 않도록 app-server의 표준 오류 출력을 표시하지 않습니다.

Codex CLI 자체는 사용자의 Codex 설정에 따라 OpenAI와 통신합니다.

## 요구 사항

- macOS 13 이상
- 설치 및 인증이 완료된 [Codex CLI](https://github.com/openai/codex)
- 소스에서 빌드하기 위한 Xcode Command Line Tools

필요하다면 다음 명령으로 Command Line Tools를 설치하세요.

```bash
xcode-select --install
```

## 소스에서 설치

```bash
git clone https://github.com/yulepapa/codex-usage-menubar.git
cd codex-usage-menubar
./Scripts/install.sh
```

설치 프로그램은 현재 Mac에 맞게 앱을 빌드하고 `~/Applications/CodexUsage.app`에 설치한 뒤, 로그인 시 자동 실행을 위한 사용자 LaunchAgent를 생성합니다.

Codex가 일반적이지 않은 경로에 설치되어 있다면 다음과 같이 실행하세요.

```bash
CODEX_PATH=/absolute/path/to/codex ./Scripts/install.sh
```

새로고침 간격을 변경하려면 60초 이상의 값을 사용하세요.

```bash
CODEX_USAGE_REFRESH_SECONDS=120 ./Scripts/install.sh
```

## 사용 방법

메뉴 막대 제목에 남은 사용량이 백분율로 표시됩니다. 항목을 클릭하면 다음 정보를 확인할 수 있습니다.

- 제공되는 각 사용량 제한 구간
- 다음 초기화 시각
- 사용 가능한 초기화권 수와 가장 빠른 만료 시각
- 마지막으로 새로고침에 성공한 시각
- 수동 새로고침 및 종료 명령

Hidden Bar, Bartender 또는 다른 메뉴 막대 관리 앱을 사용하면 새 항목이 처음부터 숨김 영역에 들어갈 수 있습니다. 관리 앱의 숨김 영역을 펼친 뒤 `Command` 키를 누른 채 `Codex`를 항상 표시되는 영역으로 드래그하세요.

## 빌드 및 테스트

```bash
make build       # 현재 Mac의 아키텍처
make universal   # arm64 + x86_64
make test        # 오프라인 fixture 및 패키징 검사
make test-live   # 로컬에서 인증된 Codex CLI 조회도 수행
```

빌드된 앱은 `.build/CodexUsage.app`에 생성됩니다.

명령줄 진단 기능도 사용할 수 있습니다.

```bash
.build/CodexUsage.app/Contents/MacOS/CodexUsage --print-usage
```

이 명령은 민감한 정보가 제거된 사용량 데이터만 출력하며 인증 정보는 절대 출력하지 않습니다.

## 제거

```bash
./Scripts/uninstall.sh
```

애플리케이션 지원 디렉터리도 함께 제거하려면 `--purge` 옵션을 사용하세요.

```bash
./Scripts/uninstall.sh --purge
```

## 호환성 참고 사항

`codex app-server`와 `account/rateLimits/read`는 현재 실험적인 Codex 인터페이스입니다. 향후 Codex 릴리스에서 변경될 수 있습니다. 이 프로젝트는 문제가 생기면 인증 파일을 직접 읽는 대신 안전하게 중단하고 오류를 표시합니다.

## 기여

이슈와 풀 리퀘스트를 환영합니다. [CONTRIBUTING.md](CONTRIBUTING.md)와 [SECURITY.md](SECURITY.md)를 참고하세요.

## 면책 조항

이 프로젝트는 비공식 커뮤니티 프로젝트이며 OpenAI와 제휴하거나 OpenAI의 보증 또는 지원을 받지 않습니다. Codex와 OpenAI는 각 소유자의 상표입니다.

## 라이선스

[MIT](LICENSE)
