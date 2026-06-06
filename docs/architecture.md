# BokslTab 아키텍처 계획

## 1. 목적

이 문서는 `docs/requirements.md`와 `docs/prd.md`를 기준으로 BokslTab MVP 구현 전 아키텍처를 정의한다. 이번 단계는 **계획 문서 작성만** 수행하며 코드를 작성하지 않는다.

BokslTab MVP의 핵심은 macOS 기본 `Cmd+Tab`의 앱 중심 전환 한계를 보완해, 앱과 창을 리스트로 보여주고 키보드로 선택해 전환하는 것이다.

## 2. RALPLAN 합의 요약

### Antithesis

작은 MVP라면 창 단위 전환을 제외하고 앱 단위 전환과 UI 검증만 먼저 구현하는 것이 더 안전할 수 있다. macOS 창 활성화는 Accessibility, CoreGraphics, AppKit 조합과 권한 문제 때문에 MVP를 불안정하게 만들 수 있다.

### Tradeoff

- 창 단위 전환 제외: 구현은 쉬워지지만 BokslTab의 핵심 문제인 “같은 앱의 여러 창을 구분하지 못하는 Cmd+Tab 불편”을 검증하지 못한다.
- 창 단위 전환 포함: 구현 리스크는 커지지만 제품 가설을 직접 검증할 수 있다.

### Synthesis

창 단위 전환은 MVP 필수 범위로 유지한다. 대신 UI polish보다 **window catalog / exact window raise spike**를 먼저 수행하고, 실패 시 앱 단위 fallback과 안전 실패를 명확히 둔다.

## 3. 기술 스택

| 영역 | 선택 | 이유 |
| --- | --- | --- |
| 언어 | Swift | macOS 네이티브 API 접근과 XCTest 연동이 좋다 |
| UI | SwiftUI + AppKit | 리스트 UI는 SwiftUI, floating panel/activation 제어는 AppKit 사용 |
| 앱 목록 | AppKit `NSWorkspace`, `NSRunningApplication` | 실행 앱과 앱 아이콘/이름 조회에 적합 |
| 창 목록 | CoreGraphics Quartz Window Services | window ID, owner PID/name, bounds/title 등 창 metadata 조회 후보 |
| 창 제어 | Accessibility `AXUIElement` | 특정 창 focus/raise, 창 속성 접근 후보 |
| 전역 단축키 | native-first, 필요 시 작은 HotKey 패키지 fallback | MVP는 의존성 최소화. 단축키가 병목이면 제한적으로 패키지 검토 |
| 테스트 | XCTest | Swift 기본 테스트 도구 |
| 배포 | 로컬 개발 실행만 | 서명/공증/배포 자동화는 MVP 제외 |

## 4. 외부 API 근거와 제약

- Apple `NSRunningApplication.activate(options:)`는 앱 활성화를 “시도”하고 system이 허용했는지 Boolean을 반환하지만, 활성화 자체가 항상 보장되지는 않는다.
- Apple `CGWindowListCopyWindowInfo`는 현재 GUI session의 window dictionary 목록을 반환하며, system window dictionary 생성은 상대적으로 비싼 작업일 수 있으므로 남용하지 않는다.
- Apple `AXUIElement` 계열 API는 accessibility object의 속성 조회/변경/동작 요청을 제공하지만, unsupported/no value/cannot complete/not implemented 같은 실패가 가능하다.

따라서 BokslTab은 exact window raise를 성공/실패가 있는 operation으로 취급하고, app-level activation fallback을 별도로 기록한다.

## 5. 레이어 구조

```text
UI
 ↓ uses
Core ports / state
 ↑ implemented by
MacOSAdapters
```

### 5.1 Core

순수 Swift 레이어다. AppKit, CoreGraphics, Accessibility를 import하지 않는다.

책임:

- 전환 항목 모델
- 전환 모드 모델
- 선택 상태와 키보드 이동 reducer
- 리스트 filtering/sorting 규칙
- title/icon fallback 규칙
- adapter protocol 정의
- 실패 상태 모델링

예상 타입:

- `SwitcherItem`
- `SwitcherMode`
- `SwitcherState`
- `SwitcherSelectionReducer`
- `WindowIdentity`
- `AppIdentity`
- `SwitchResult`
- `PermissionState`

### 5.2 MacOSAdapters

macOS API 의존 레이어다. Core의 protocol을 구현한다.

주요 어댑터:

| Adapter | 책임 |
| --- | --- |
| `RunningAppProvider` | 실행 앱 목록, app name, icon, PID, bundle identifier 조회 |
| `WindowCatalogProvider` | 전환 가능한 창 목록, window title, owner PID, window ID 조회 |
| `AppActivator` | 앱 단위 foreground activation 시도 |
| `WindowActivator` | exact window raise 시도 |
| `HotkeyService` | 전역 단축키 등록/해제 |
| `PermissionAdvisor` | Accessibility 및 Privacy/Screen Recording 관련 가능성 안내 상태 제공 |

### 5.3 UI

사용자에게 전환 UI를 표시하는 레이어다. macOS API를 직접 호출하지 않고 Core state와 ports를 통해 동작한다.

책임:

- floating switcher panel 표시/닫기
- row rendering: app icon + window/app title
- 선택 하이라이트 표시
- keyboard navigation event 전달
- empty/error/permission guidance 표시

## 6. 권장 폴더 구조

SwiftPM 기준의 작은 구조를 기본안으로 둔다. Xcode project를 선택해도 같은 모듈 경계를 유지한다.

```text
BokslTab/
  Package.swift 또는 BokslTab.xcodeproj
  Sources/
    BokslTabApp/
      BokslTabApp.swift
      AppDelegate.swift
    BokslTabCore/
      Models/
      State/
      Ports/
      Reducers/
    BokslTabMacOSAdapters/
      RunningAppProvider/
      WindowCatalogProvider/
      Activation/
      Hotkeys/
      Permissions/
    BokslTabUI/
      SwitcherPanel/
      Rows/
      States/
  Tests/
    BokslTabCoreTests/
    BokslTabAdapterContractTests/
  docs/
```

## 7. 주요 모듈

### 7.1 AppCatalog / RunningAppProvider

- 실행 앱 목록 조회
- BokslTab 자체 제외
- background/system-like process 필터링
- 앱 이름/icon fallback 제공

### 7.2 WindowCatalogProvider

- 모든 앱/창 모드용 window list 생성
- 활성 앱 창 모드용 foreground app window list 생성
- 창 제목 누락 시 fallback title 적용
- 단일 활성 앱 창은 **1개 row로 표시**한다. 사용자가 확정하면 같은 창을 다시 raise 시도한다.

### 7.3 SwitcherState

- 현재 모드
- 항목 리스트
- 선택 index
- loading/empty/error/permission 상태
- next/previous/confirm/cancel 처리

### 7.4 WindowActivator / AppActivator

- window row: exact window raise 먼저 시도
- exact raise 성공: `exact-window-success`
- exact raise 실패 후 app activation 성공: `limited-app-fallback-success`
- 둘 다 실패: `safe-failure`

### 7.5 HotkeyService

- 모든 앱/창 모드 hotkey
- 활성 앱 창 모드 hotkey
- 등록 실패 시 개발용 diagnostic 기록
- 설정 UI는 MVP 제외

### 7.6 PermissionAdvisor

- Accessibility permission 필요 가능성 안내
- CGWindow title/metadata 접근이 macOS Privacy 또는 Screen Recording 정책과 충돌할 가능성 안내
- 정확한 권한 요구는 spike 단계에서 확인한다.

## 8. 위험 요소와 fallback 전략

| 위험 | 영향 | fallback |
| --- | --- | --- |
| Accessibility 권한 거부 | exact window raise 불가 | 권한 안내 표시, 앱 단위 activation만 허용 |
| 창 title 누락 | row 식별성 저하 | app name 또는 fallback title 표시 |
| 선택 직전 창 닫힘 | 전환 실패 | 리스트 refresh 또는 panel close, no crash |
| exact window raise 실패 | 선택 창으로 정확히 이동 실패 | app activation fallback, 결과는 제한 성공으로 기록 |
| app activation 실패 | 전환 실패 | safe failure, panel close/log |
| hotkey 등록 실패 | UI 열기 불가 | diagnostic 기록, 대체 hotkey는 구현 단계에서 상수로 조정 |
| 창 목록 조회 비용 | UI 지연 | 단축키 시점 조회 최소화, 필요 시 가벼운 cache |
| 화면 기록/Privacy 제약 | title/metadata 제한 가능 | 권한 안내 또는 fallback title |

## 9. 제외 범위 확인

MVP에서 하지 않는다.

- 창 썸네일
- 화면 캡처 preview
- 설정 UI
- 창 검색
- 창 이동/리사이즈/정렬
- 코드 서명/공증/배포 자동화
- 완성형 디자인 시스템

## 10. 참고 자료

- Apple Developer Documentation — `NSRunningApplication.activate(options:)`
- Apple Developer Documentation — `CGWindowListCopyWindowInfo`
- Apple Developer Documentation — `AXUIElementCopyAttributeValue`, `AXUIElementSetAttributeValue`
