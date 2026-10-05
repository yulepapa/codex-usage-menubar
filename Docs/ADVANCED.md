# 자세한 설정·개발 안내

일상적인 사용은 [README](../README.md)를 먼저 확인하세요. 이 문서는 기존 감시기 연결, 문제 점검, 복구와 개발 작업을 할 때 필요한 내용을 모았습니다.

## 설치 위치와 갱신 간격

일반 설치는 앱을 `~/Applications/CodexUsage.app`에 넣고 로그인할 때 메뉴 앱을 열도록 설정합니다. 기존에 별도 절차로 설치했다면 앱 위치와 백업 경로가 다를 수 있습니다.

Codex CLI가 자동으로 검색되지 않으면 실제 실행파일 위치를 지정합니다.

```sh
CODEX_PATH=/example/bin/codex ./Scripts/install.sh
```

`/example/bin/codex`는 가상 경로입니다. 메뉴 사용량의 기본 갱신 간격은 5분입니다. 다음 예시는 2분으로 바꾸며, 최소 60초까지 설정할 수 있습니다. 자동 사용 감시기의 1분 확인 주기와는 별개입니다.

```sh
CODEX_USAGE_REFRESH_SECONDS=120 ./Scripts/install.sh
```

이미 리셋 감시기가 설정된 Mac에서는 일반 설치·제거 명령이 중단됩니다. 실행 중인 앱이나 사용 기록을 덮어쓰지 않도록 하기 위한 검사입니다. 기존 설치 때의 업데이트·복구 절차를 사용하세요.

## 기존 감시기를 앱으로 옮기기

이 절차는 **이미 실행 중인 Python 감시기 `reset_credit_watcher.py`**를 앱의 감시 프로그램으로 바꾸는 경우에만 사용합니다. 새 감시기 등록이나 다른 형식의 자동화를 자동으로 처리하지 않습니다. 옮기는 도구에는 Python 3.9 이상이 필요하지만, 앱 실행 자체에는 Python이 필요하지 않습니다.

먼저 가상 자료 검사와 앱 만들기를 완료합니다.

```sh
make test
make build
```

기존 감시기의 설정 파일과 실제 설치 앱 경로를 확인한 뒤 변경 계획을 봅니다. 아래 `example.reset-watcher`는 예시 이름이며, 그대로 사용하면 안 됩니다.

```sh
python3 Scripts/reset-worker.py --plan \
  --legacy-plist "$HOME/Library/LaunchAgents/example.reset-watcher.plist" \
  --app "$HOME/Applications/CodexUsage.app" \
  --enable-auto-use
```

`--plan`은 선택한 설정과 이전 사용 기록을 읽어 점검합니다. 앱·실행 설정·사용 기록은 바꾸지 않습니다. 결과가 불확실한 이전 사용 요청이 있다면 먼저 확인해야 합니다.

계획과 경로가 맞는지 확인한 뒤 다음 명령으로 실제 변경을 적용합니다.

```sh
python3 Scripts/reset-worker.py --apply \
  --legacy-plist "$HOME/Library/LaunchAgents/example.reset-watcher.plist" \
  --app "$HOME/Applications/CodexUsage.app" \
  --enable-auto-use
```

**이 명령은 앱과 감시기 설정을 실제로 바꿉니다.** `--enable-auto-use`를 넣으면 자동 사용을 켜므로, 조건이 이미 맞으면 리셋권이 사용될 수 있습니다. 이 옵션을 빼면 자동 사용은 꺼진 상태로 옮기고 알림만 켭니다. macOS 알림 허용도 별도로 필요합니다.

도구는 기존 앱·설정·사용 기록을 백업하고, 이전 감시기를 멈춘 뒤 마지막 사용 기록을 다시 읽습니다. 이후 같은 실행 등록 이름을 새 감시기에 연결합니다. **기존 감시기와 새 감시기를 동시에 실행하지 마세요.** 완료 상태와 실제 백업 경로를 확인하고 보관하세요. 백업이 있다는 사실만으로 복구가 성공한다고 보장할 수는 없습니다.

기본 이전 감시기 폴더는 `$CODEX_HOME/automations/codex`이며, `CODEX_HOME`이 없으면 `~/.codex/automations/codex`입니다. 다른 위치를 쓸 때는 `--legacy-dir`, `--built-app`, `--codex-path`로 실제 위치를 지정합니다.

이미 다른 도구로 앱의 자동 사용을 설정했다면 그때 사용한 도구와 백업을 보존하세요. 서로 다른 형식의 백업을 섞어서 사용할 수 없습니다. 자세한 실행 순서는 [운영 문서](OPERATIONS.md)에 있습니다.

## 백업과 복구

저장소의 `reset-worker.py`가 만든 백업은 **같은 도구가 알려 준 백업 경로**로 복구합니다. 다음 경로의 `EXAMPLE_TIMESTAMP`는 예시입니다.

```sh
python3 Scripts/reset-worker.py --rollback "$HOME/Library/Application Support/CodexUsage/backups/EXAMPLE_TIMESTAMP"
```

이 절차는 새 감시기를 멈추고 최신 사용 기록을 이전 감시기의 기록에 반영한 뒤, 이전 앱과 실행 설정을 복원합니다. 다른 방식으로 설치한 개인 환경에는 당시의 복구 절차를 사용해야 합니다.

`state.json`을 지워 다시 시도하거나 오래된 사용 기록을 덮어쓰지 마세요. 사용 결과가 불확실한 요청을 구분하는 정보가 없어져 같은 권을 다시 사용하려 할 수 있습니다. 감시기가 설정돼 있으면 일반 제거기의 `--purge`도 거부됩니다. 실제 운영 환경의 복구는 별도 확인이 필요합니다.

## 상태 점검

다음 명령은 정보를 조회할 뿐 리셋권을 사용하지 않습니다. 예시는 직접 만든 앱의 경로입니다. 설치 앱을 점검하려면 실제 설치 위치로 바꾸세요.

```sh
.build/CodexUsage.app/Contents/MacOS/CodexUsage --print-usage
.build/CodexUsage.app/Contents/MacOS/CodexUsage --print-native-reset-status
.build/CodexUsage.app/Contents/MacOS/CodexUsage --notification-status
```

출력에는 개인 사용량과 만료 시각이 포함될 수 있습니다. 공개 이슈에 그대로 붙이지 말고 필요한 부분만 개인 정보를 가린 뒤 공유하세요. 로그인 파일·토큰·실제 설정·사용 기록·로그·백업은 공개 저장소에 넣지 않습니다.

| 기본 위치 | 내용 |
| --- | --- |
| `~/Library/Application Support/CodexUsage/codex-path` | Codex CLI의 실행파일 위치 |
| `~/Library/Application Support/CodexUsage/reset/settings.json` | 자동 사용과 알림 설정 |
| 같은 폴더의 `state.json` | 사용 결과, 재확인할 요청과 보낸 알림 기록 |
| 같은 폴더의 `worker.json`, `ownership.json`, `wake.json`, 잠금 파일 | 감시 프로그램의 실행 설정과 중복 실행 방지 |
| 같은 폴더의 `worker.stdout.log`, `worker.stderr.log` | 개인 실행 로그 |
| `~/Library/LaunchAgents/<선택한 이름>.plist` | Mac 로그인 뒤 감시기를 실행하는 설정 |
| `~/Library/Application Support/CodexUsage/backups/<시각>/` | 이 저장소의 연결 도구가 만든 백업 |

설정과 사용 기록은 사용자만 읽을 수 있는 권한으로 저장합니다. 별도 설치 절차를 쓴 경우 위치가 다를 수 있습니다.

앱은 기존 Python 감시기 설정을 읽기만 하는 기능도 가지고 있습니다. 위의 이전 감시기 폴더나 `CODEX_USAGE_RESET_WATCHER_DIR`에 있는 정책·상태·일부 로그를 읽으며, Python 코드를 실행하지 않습니다. 앱으로 옮기기 전의 상태 확인과 가상 미리보기에 사용합니다.

## 결과가 불확실할 때의 처리

감시 프로그램은 사용 요청을 구분하는 번호를 먼저 저장합니다. 개발 코드에서는 이를 `idempotency key`라고 부릅니다. 통신이 끊겨 결과를 확인하지 못하면 **새 번호로 다른 권을 사용하지 않고**, 저장한 번호로 기존 요청만 재확인합니다.

재확인은 3분이 지난 뒤 최신 사용 조건이 맞을 때 시도합니다. 재시작해도 요청 번호와 보류 상태는 유지합니다. 권이 사라지거나 만료됐다고 성공을 추정하지 않습니다. 해당 요청에 대한 Codex 서비스 응답으로 결과가 확정돼야 합니다. 사용 성공 뒤에는 연속 사용을 줄이기 위해 5분간 기다립니다.

이 소비 보류와 알림은 별개입니다. 조회에서 확인된 다른 사용 가능한 권의 만료 알림은 계속 처리합니다. 한 번 보낸 단계의 알림 기록도 저장해 재시작 후 중복을 줄입니다.

메뉴의 사용량 갱신은 조회만 합니다. 실제 사용은 등록된 감시 프로그램 하나가 담당하며, 실행 설정 확인과 프로세스 잠금으로 중복 실행을 막습니다. 앱은 로그인된 `codex app-server --stdio`를 통해 OpenAI와 통신하며, 새로운 AI 대화를 시작하지 않습니다. 통신 방식이 바뀌어 오류가 나더라도 로그인 파일 직접 접근이나 비공개 통신 주소 추측으로 우회하지 않습니다.

## 코드를 검사하고 앱 만들기

소스를 처음 받는 경우에는 다음을 사용합니다.

```sh
git clone https://github.com/yulepapa/codex-usage-menubar.git
cd codex-usage-menubar
make test
make build
```

`make build` 결과는 `.build/CodexUsage.app`입니다. 두 종류의 Mac 칩에서 실행할 수 있는 앱을 만들려면 `make universal`을 사용합니다. 앱은 Swift로 만들며 별도 실행 환경을 설치할 필요는 없습니다.

개발 도구가 준비됐는지 확인합니다.

```sh
xcrun swiftc --version
```

별도로 설치된 Command Line Tools를 이번 명령에만 선택해야 한다면 다음을 사용합니다. Mac의 전역 설정은 바꾸지 않습니다.

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools make test
```

기본 `make test`는 가상 자료와 가짜 Codex 프로그램으로 검사하며 실제 권을 사용하지 않습니다. 선택적인 `make test-live`는 실제 계정의 **읽기 전용 사용량 조회**를 추가합니다.

### 가상 자료로 메뉴 미리보기

```sh
CODEX_USAGE_DEVELOPMENT=1 ./Scripts/build.sh .build/CodexUsageDev.app
open -n .build/CodexUsageDev.app --args --preview "$PWD/Tests/Fixtures/ResetPreview" --at 1893452400
```

2030년 가상 자료만 사용하고 실제 Codex CLI나 감시기에 연결하지 않습니다. 개발 앱은 별도 앱 식별자와 메뉴바 위치를 사용하며 설치된 앱을 대체하지 않습니다. 화면에는 샘플 데이터라고 표시됩니다.

## 검증 범위와 참고 문서

가상 검사에는 사용량·시간대, 소비 직전 조건 변화, 같은 요청의 재확인, 여러 권의 미확인 결과, 중복 실행 방지, 알림과 메뉴 표시, 감시기 연결·복구가 포함됩니다. 실제 권을 시험 삼아 사용하지 않았습니다.

실제 만료 배너, 실제 자동 사용, 재부팅·잠자기 복귀와 운영 복구는 가상 검사만으로 확인할 수 없습니다. 실제 점검을 완료했다고 가정하지 말고 [검증 문서](VALIDATION.md)에서 범위를 확인하세요.

- [아키텍처](ARCHITECTURE.md): 코드와 역할을 설명합니다.
- [운영·복구](OPERATIONS.md): 기존 감시기 연결과 복구 절차를 설명합니다.
- [보안 정책](../SECURITY.md): 개인 정보와 인증 정보 취급 원칙을 설명합니다.
- [변경 이력](../CHANGELOG.md): 버전별 변경을 확인합니다.
- [지식관리 연결 정보](../project-manifest.json): 프로젝트 설명을 다른 관리 도구에 연결하기 위한 정보입니다. 로그인이나 자동 동기화를 만들지 않습니다.

지식관리 자료를 갱신할 때는 실제 원격 파일과 변경 버전을 확인하고 기존 자료에 연결하세요. 프로젝트 설명을 사용자의 저작물이나 개인 견해로 추정하지 않습니다.
