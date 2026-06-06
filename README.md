# BokslTab

BokslTab은 macOS용 AltTab 스타일 앱/창 전환기 프로토타입입니다.
현재 MVP는 완성형 배포 앱이 아니라, SwiftPM 기반으로 요구사항 → 구현 → 검증 과정을 실험하기 위한 작은 macOS 프로토타입입니다.

## 현재 MVP 기능

- 모든 앱/창 리스트 표시 및 전환
- 활성 앱의 창 리스트 표시 및 전환
- 앱 아이콘 + 앱/창 타이틀 표시
- 키보드 이동, 선택, 취소
- 전역 단축키 등록
- Accessibility 권한이 없거나 창을 정확히 식별할 수 없을 때 앱 활성화 fallback

제외 범위:

- 실행 화면 캡처/창 썸네일
- 설정 화면
- 자동 업데이트
- DMG 배포 자동화

## 요구사항

- macOS 13 이상
- Xcode Command Line Tools 또는 Xcode
- SwiftPM 사용 가능 환경

확인:

```bash
swift --version
xcode-select -p
```

Xcode Command Line Tools가 없다면:

```bash
xcode-select --install
```

## 빌드

### Debug 빌드

```bash
swift build
```

생성 파일:

```text
.build/debug/BokslTab
```

### Release 빌드

```bash
swift build -c release
```

생성 파일:

```text
.build/release/BokslTab
```

### 테스트

```bash
swift test
```

### Smoke test

GUI 패널을 띄우지 않고 앱/창 조회와 권한 상태를 확인합니다.

```bash
.build/debug/BokslTab --smoke-test
```

예상 출력 예:

```text
BokslTab smoke-test
regularApps=8
windows=4
switcherItems=11
accessibility=denied(...)
screenMetadata=allowed
```

## 디버그 실행

### 개발용 `.app`으로 실행 권장

Accessibility 권한 테스트까지 하려면 SwiftPM raw binary보다 개발용 `.app` 번들 실행을 권장합니다.

```bash
./scripts/build-dev-app.sh
open .build/dev-app/BokslTab.app
```

이 방식은 `.build/dev-app/BokslTab.app` 번들을 만들고 ad-hoc 서명합니다. 정식 배포용 서명은 아니지만, `swift run`보다 macOS 권한 화면에서 `BokslTab.app`으로 인식될 가능성이 높습니다.

### SwiftPM raw binary로 실행

빠른 기능 확인만 할 때는 아래 명령도 가능합니다.

```bash
swift run BokslTab
```

또는 빌드된 바이너리를 직접 실행합니다.

```bash
.build/debug/BokslTab
```

단, 이 방식은 터미널/iTerm에서 실행한 개발용 프로세스라 Accessibility 권한 화면에서 `iTerm.app`, `Terminal.app`, `swift` 또는 raw executable로 표시될 수 있습니다.

실행하면 메뉴바에 `BokslTab` 아이콘이 표시됩니다.

### 앱 사용 방법

기본 단축키:

| 동작 | 단축키 |
| --- | --- |
| 모든 앱/창 전환 패널 열기 | `Option + Tab` |
| 활성 앱 창 전환 패널 열기 | `Command + Tab` |
| 다음 항목 | `Tab`, `↓`, `→` |
| 이전 항목 | `Shift + Tab`, `↑`, `←` |
| 선택 항목으로 전환 | `Enter`, `Space` |
| 클릭 선택 | row 클릭 |
| 클릭 전환 | row 더블클릭 |
| 취소 | `Esc` |

`Option + Tab` 패널은 `Option` 키를 떼면 현재 선택 항목으로 전환됩니다. `Command + Tab` 활성 앱 창 패널은 `Command` 키를 떼면 현재 선택 항목으로 전환됩니다.

macOS 기본 앱 전환기와 충돌해 `Command + Tab` 전역 단축키 등록이 실패할 수 있습니다. 이 경우 BokslTab은 종료하지 않고 `Option + Tab` 단축키만 유지하며, 패널 하단에 등록 실패 안내를 표시합니다.

메뉴바에서도 다음 항목을 실행할 수 있습니다.

- `모든 앱/창 보기`
- `활성 앱 창 보기`
- `종료`

## macOS 권한 설정

BokslTab은 다른 앱의 창을 찾고 전환을 시도하기 때문에 macOS 보안/개인정보 보호 정책의 영향을 받습니다.

### Accessibility / 손쉬운 사용

창 단위 전환을 시도하려면 Accessibility 권한이 필요합니다.

설정 경로:

```text
시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용
```

여기에서 BokslTab 실행 파일 또는 앱을 허용합니다.

BokslTab 패널의 권한 안내에는 `설정 열기` 버튼이 표시됩니다. 이 버튼은 먼저 macOS Accessibility 권한 프롬프트를 요청한 뒤 손쉬운 사용 설정으로 이동을 시도하고, 실패하면 System Settings 앱을 엽니다. macOS System Settings의 세부 pane URL은 공식 안정 API가 아니므로 macOS 버전에 따라 정확한 위치 이동이 달라질 수 있습니다.

권한 테스트는 개발용 `.app` 번들로 실행하는 것을 권장합니다.

```bash
./scripts/build-dev-app.sh
open .build/dev-app/BokslTab.app
```

`swift run BokslTab`은 정식 `.app` 번들이 아니라 SwiftPM이 만든 raw executable을 터미널/iTerm 하위 프로세스로 실행합니다. 이 경우 macOS 권한 프롬프트가 `BokslTab`이 아니라 `iTerm.app` 또는 `Terminal.app`이 컴퓨터를 제어하려 한다고 표시될 수 있습니다.

빌드 산출물을 지우거나 다시 만들면 macOS가 다른 실행 파일로 인식할 수 있으므로 권한을 다시 허용해야 할 수 있습니다.

### Screen Recording / 화면 기록

현재 MVP는 창 썸네일이나 화면 캡처를 사용하지 않습니다. 다만 macOS 버전/정책에 따라 다른 앱 창의 제목 같은 메타데이터 접근이 제한될 수 있습니다.

증상:

- 창 제목이 비어 있음
- 앱 이름 fallback만 표시됨
- smoke test에서 `screenMetadata=denied(...)` 표시

필요 시 확인 경로:

```text
시스템 설정 > 개인정보 보호 및 보안 > 화면 기록
```

## 설치

### 개발 PC에서 개발용 `.app` 설치/실행

권한 테스트까지 하려면 개발용 `.app` 번들을 만들어 실행합니다.

```bash
./scripts/build-dev-app.sh
open .build/dev-app/BokslTab.app
```

생성 위치:

```text
.build/dev-app/BokslTab.app
```

### 개발 PC에서 SwiftPM으로 임시 실행

가장 단순한 방식은 repo에서 직접 실행하는 것입니다. 단, 이 방식은 권한 화면에서 iTerm/Terminal로 인식될 수 있습니다.

```bash
swift run BokslTab
```

### 개발 PC에 release 바이너리 복사

SwiftPM release 바이너리를 원하는 위치에 복사해 실행할 수 있습니다.

```bash
swift build -c release
mkdir -p ~/Applications/BokslTab-dev
cp .build/release/BokslTab ~/Applications/BokslTab-dev/BokslTab
~/Applications/BokslTab-dev/BokslTab
```

주의:

- 이 방식은 정식 macOS `.app` 설치가 아닙니다.
- 메뉴바 앱처럼 동작하지만 Finder에서 일반 앱처럼 보이는 설치 경험은 아닙니다.
- Accessibility 권한은 복사한 실행 파일 경로 기준으로 다시 허용해야 할 수 있습니다.

### 로컬 ad-hoc 서명

내 Mac에서만 테스트할 목적이면 ad-hoc 서명을 붙일 수 있습니다.

```bash
codesign --force --sign - ~/Applications/BokslTab-dev/BokslTab
codesign --verify --verbose ~/Applications/BokslTab-dev/BokslTab
```

이 서명은 Gatekeeper 배포용 Developer ID 서명이 아닙니다. 다른 사람에게 안전하게 배포하는 용도로 쓰지 않습니다.

## 배포

현재 repo는 SwiftPM 실행 파일 프로토타입입니다. 다른 Mac에 일반 사용자용으로 배포하려면 다음 작업이 추가로 필요합니다.

### 1. `.app` 번들 만들기

개발용 번들은 다음 명령으로 만들 수 있습니다.

```bash
./scripts/build-dev-app.sh
```

생성 위치:

```text
.build/dev-app/BokslTab.app
```

이 스크립트는 다음을 수행합니다.

- SwiftPM debug 또는 release 빌드
- `BokslTab.app/Contents/MacOS/BokslTab`에 실행 파일 복사
- `Info.plist` 생성
- `LSUIElement=true` 설정으로 메뉴바 앱처럼 실행
- ad-hoc 서명

release 바이너리로 번들을 만들려면:

```bash
CONFIGURATION=release ./scripts/build-dev-app.sh
```

주의: 이 스크립트의 ad-hoc 서명은 로컬 개발용입니다. 외부 배포에는 Developer ID 서명과 공증이 필요합니다.

### 2. Developer ID 서명

Mac App Store 밖에서 배포하려면 Apple Developer Program 멤버십으로 발급한 Developer ID 인증서가 필요합니다.

- 앱 서명: `Developer ID Application` 인증서
- `.pkg` 설치 프로그램 서명: `Developer ID Installer` 인증서

Apple 설명에 따르면 Developer ID 인증서는 Mac App Store 밖에서 배포하는 앱/플러그인/설치 패키지에 사용하는 배포 인증서이며, Gatekeeper가 개발자와 변조 여부를 확인하는 데 사용합니다.

예시:

```bash
codesign \
  --force \
  --options runtime \
  --timestamp \
  --sign "Developer ID Application: <TEAM_OR_NAME>" \
  BokslTab.app

codesign --verify --deep --strict --verbose=2 BokslTab.app
spctl --assess --type execute --verbose BokslTab.app
```

### 3. Notarization / 공증

Apple은 Developer ID로 배포하는 macOS 소프트웨어를 공증해 Gatekeeper가 확인할 수 있도록 하는 절차를 제공합니다. 최신 절차는 `notarytool`을 사용합니다.

예시:

```bash
# app을 zip으로 묶기
ditto -c -k --keepParent BokslTab.app BokslTab.zip

# notarization 제출
xcrun notarytool submit BokslTab.zip \
  --apple-id "<APPLE_ID>" \
  --team-id "<TEAM_ID>" \
  --password "<APP_SPECIFIC_PASSWORD>" \
  --wait

# 공증 ticket stapling
xcrun stapler staple BokslTab.app
xcrun stapler validate BokslTab.app

# Gatekeeper 평가
spctl --assess --type execute --verbose BokslTab.app
```

### 4. DMG 또는 PKG 만들기

사용자에게 전달할 산출물은 보통 DMG 또는 PKG를 사용합니다.

- DMG: 앱을 `/Applications`로 드래그하는 단순 설치 경험
- PKG: 설치 경로/권한/추가 파일 제어가 필요한 경우

PKG를 배포하려면 `Developer ID Installer` 인증서로 installer package도 서명해야 합니다.

## 다른 Mac에 설치할 수 있나?

가능하지만 배포 방식에 따라 사용자 경험이 다릅니다.

| 방식 | 다른 Mac 실행 | Gatekeeper 경험 | 용도 |
| --- | --- | --- | --- |
| unsigned 바이너리 복사 | 막히거나 경고 가능 | 나쁨 | 개인 실험 |
| ad-hoc 서명 바이너리 | 막히거나 경고 가능 | 나쁨 | 내 Mac 로컬 테스트 |
| Developer ID 서명 + 공증된 `.app`/DMG | 가능 | 좋음 | 외부 배포 |
| Mac App Store 배포 | 가능 | 가장 표준적 | 제품 배포 |

현재 단계에서는 개발 PC에서 `./scripts/build-dev-app.sh && open .build/dev-app/BokslTab.app` 실행을 권장합니다. 외부 배포는 Developer ID 서명, 공증, DMG/PKG 생성을 별도 작업으로 추가해야 합니다.

## 문제 해결

### 단축키가 동작하지 않음

- 다른 앱이 같은 단축키를 선점했을 수 있습니다.
- 터미널/실행 파일을 종료 후 다시 실행합니다.
- 콘솔 stderr에 `전역 단축키 등록 실패` 메시지가 있는지 확인합니다.

### 손쉬운 사용 목록에 BokslTab이 없음

- `swift run BokslTab`은 정식 `.app` 번들이 아니라 SwiftPM raw executable을 iTerm/Terminal 하위 프로세스로 실행합니다.
- 권한 프롬프트가 `BokslTab`이 아니라 `iTerm.app` 또는 `Terminal.app`으로 표시될 수 있습니다.
- 권한 테스트는 아래처럼 개발용 `.app` 번들로 실행합니다.

```bash
./scripts/build-dev-app.sh
open .build/dev-app/BokslTab.app
```

- 앱 패널의 `설정 열기` 버튼을 눌러 Accessibility 프롬프트를 먼저 발생시킵니다.
- 그래도 목록에 없다면 손쉬운 사용 화면의 `+` 버튼으로 `.build/dev-app/BokslTab.app`을 수동 추가합니다. `.build`는 숨김 디렉터리라 Finder 파일 선택 창에서 `Command + Shift + .`로 숨김 파일 표시를 켜야 할 수 있습니다.

### 창 전환이 앱 전환처럼만 동작함

- Accessibility 권한이 없으면 정확한 창 전환 대신 앱 활성화 fallback이 발생합니다.
- `시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용`에서 허용 후 앱을 재실행합니다.
- 같은 제목의 창이 여러 개 있거나 제목이 비어 있으면 MVP는 안전을 위해 exact window success를 주장하지 않고 앱 활성화 fallback을 사용합니다.

### 창 제목이 안 보임

- macOS 개인정보 보호 정책에 따라 창 제목 메타데이터가 제한될 수 있습니다.
- 화면 기록 권한이 필요한 환경인지 확인합니다.
- MVP는 제목이 없으면 앱 이름으로 fallback합니다.

## 참고 문서

- Apple Developer — Developer ID certificate: https://developer.apple.com/help/glossary/developer-id-certificate/
- Apple Developer — Developer ID certificates: https://developer.apple.com/help/account/certificates/create-developer-id-certificates/
- Apple Developer — Signing your apps for Gatekeeper: https://developer.apple.com/developer-id/
- Apple Developer — Notarizing macOS software before distribution: https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution
