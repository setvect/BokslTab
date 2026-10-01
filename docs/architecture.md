# BokslTab 아키텍처

현재 SwiftPM 구현의 책임과 실행 흐름을 설명한다. 초기 구현 계획은 `plan.md`를 참고한다.

## 모듈과 책임

| 모듈 | 책임 |
| --- | --- |
| `BokslTabCore` | 앱·창·탭 모델, 목록 조합, 선택 유지, MRU 순서, 어댑터 인터페이스 |
| `BokslTabMacOSAdapters` | CoreGraphics·Accessibility·AppKit 연동, 단축키 등록, 권한 조회, 진단 로그 |
| `BokslTabUI` | 단일 AppKit 패널, SwiftUI 목록, 키 입력과 반복, 화면 배치 |
| `BokslTabApp` | 서비스 조립과 `SwitcherCoordinator`의 표시·갱신·활성화 흐름 |

Core는 AppKit 및 Accessibility에 의존하지 않는다. App이 하나의 `MacOSAccessibilityService`를 만들어 창 목록 제공자와 창 활성화기에 주입한다.

## 창 목록 표시와 갱신

1. 시작 시와 새로운 전환 목록을 열 때 `requestRefresh(including:)`로 상세 조회를 예약한다.
2. 목록 읽기는 현재 CoreGraphics 창 정보와 이미 수집한 캐시로 즉시 결과를 만든다. 읽기 자체는 AX 조회를 예약하거나 기다리지 않는다.
3. AX 작업은 공유 서비스의 직렬 작업 큐에서 실행한다. 앱별 갱신 요청은 하나만 실행·대기할 수 있다.
4. 캐시 완료 알림은 50ms 동안 모아서 메인 큐에 전달한다. coordinator는 표시 중인 목록을 다시 읽고 선택 대상을 보존해 병합한다.
5. 패널과 hosting controller를 재사용한다. 항목 수에 따라 프레임을 다시 계산하므로 탭 확장 시 크기도 갱신된다.

`BackgroundRefreshCache`는 값의 유효 기간(5초), 갱신 간격(0.5초), 진행 중 요청과 오래된 결과 폐기를 관리한다. 앱의 응답 실패와 재시도 시점은 관리하지 않는다.

창 목록 관련 파일은 다음 책임으로 나눈다.

| 파일 | 책임 |
| --- | --- |
| `MacOSWindowCatalogProvider` | CG 목록과 AX·제목·이벤트 캐시를 조합하고 상세 갱신을 요청 |
| `AccessibilityWindowDiscovery` | 한 앱의 AX 창과 보조 창을 조회해 스냅샷 생성 |
| `WindowSnapshots` | 창 스냅샷, CG 정보 파싱, 합성 ID와 기하 정보 |
| `WindowCatalogPolicies` | 창 매칭, 제목 보완, 중복 제거 규칙 |
| `WindowTabCatalog` | 탭 지원 앱 판별, AX 탭 해석, 탭별 행 확장 |
| `AccessibilityWindowEventCache` | AX 이벤트 구독, 백그라운드 수집, 최근 창 보관 |
| `AccessibilityEventHistory` | 이벤트 이력의 보존·매칭·목록 변환 규칙 |
| `WindowTitleCache` | 제목 보완용 캐시와 개수 제한 |

## 응답 제한과 활성화

`MacOSAccessibilityService`가 앱별 재시도 제한을 단독으로 소유한다. 조회·이벤트 감시·활성화 모두 같은 상태를 사용한다. 응답 실패 또는 요청 시간 소진 시 해당 앱에 15초 동안 추가 AX 요청을 보내지 않는다. 대기 중 재요청으로 제한 시간이 연장되지 않는다.

`AccessibilityQueryBudget`는 각 작업에 명시적으로 전달한다. 전역 변수나 스레드 사전에 의존하지 않는다. 모든 AX 속성 읽기·쓰기·동작 요청과 이벤트 구독에 제한을 적용한다.

- 창 정보 조회: 개별 호출 최대 80ms, 한 앱의 작업 최대 250ms.
- 창 올리기·탭 선택: 개별 호출 최대 250ms, 작업 최대 1초.
- 실제 제한은 남은 시간과 개별 호출 제한 중 작은 값이다. 이미 시작한 시스템 호출의 반환은 OS 타임아웃에 따른다.

창 활성화는 비동기 인터페이스다. AX 대상 식별과 동작은 작업 큐에서 실행하고, 앱을 앞으로 가져오는 AppKit 호출과 결과 반영은 메인 액터에서 실행한다. 새 전환 요청이나 종료는 이전 작업을 취소한다. 취소된 작업은 대기 이후 앱 포커스를 변경하거나 다음 AX 동작을 시작하지 않는다. 이미 전달된 시스템 동작을 되돌리지는 않는다.

창을 정확히 찾지 못하거나 AX 요청이 지연되면 앱 활성화로 대체한다. 현재 선택한 탭을 찾지 못한 경우 다른 탭으로 임의 전환하지 않는다.

## 단축키 등록

`GlobalHotkeyServicing.start`가 실패하면 등록을 모두 정리한다. Carbon과 우선순위 서비스 모두 이 계약을 따른다. 활성 앱 단축키 등록 실패 시 coordinator가 기본 Cmd+Tab만 다시 등록하고, 성공 후 제한 상태를 알린다.

macOS 기본 Cmd+Tab 설정의 변경·복원은 `NativeCommandTabHotkeyService`가 담당한다. 우선순위 서비스는 native override, EventTap, Carbon 사용 순서를 결정한다.

## 로그와 테스트

앱 시작 시 파일 로그를 활성화한다. 라이브러리와 테스트에서는 기본적으로 사용자의 로그 파일에 기록하지 않는다. 파일 쓰기와 날짜 포맷은 별도 직렬 큐에서 처리한다. 현재 로그와 이전 로그를 각각 최대 5MiB로 제한한다. `--debug-logging`을 지정하면 창 목록의 상세 진단도 기록한다.

테스트는 Core 상태, 창·탭 정책, 캐시, AX 시스템 경계, 단축키 수명 주기, 패널 배치, coordinator 통합으로 구분한다. AX API를 교체해 실제 제한·재시도·취소 코드가 실행되도록 검증한다. 실제 앱의 권한 및 창·탭 전환은 별도 수동 검증 대상이다.
