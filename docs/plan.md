# BokslTab 구현 계획

## 1. 목적

이 문서는 BokslTab MVP를 작게 구현하기 위한 순서를 정의한다. 이번 단계에서는 **구현하지 않고 계획만 작성**한다.

기준 문서:

- `docs/requirements.md`
- `docs/prd.md`
- `docs/architecture.md`
- `docs/acceptance-criteria.md`
- `docs/validation-plan.md`

## 2. 구현 원칙

1. MVP는 작게 유지한다.
2. 창 단위 전환은 P0로 유지한다.
3. UI polish보다 window catalog / exact window raise spike를 먼저 검증한다.
4. Core는 순수 Swift로 테스트 가능하게 유지한다.
5. macOS API 실패는 fallback 가능한 결과로 모델링한다.
6. 썸네일, 설정 UI, 배포 품질은 구현하지 않는다.

## 3. 구현 순서

### Phase 0. 프로젝트 선택

목표:

- SwiftPM 또는 Xcode project 중 하나를 선택한다.
- MVP에서는 SwiftPM + macOS executable/app target을 우선 검토하되, SwiftUI App lifecycle이 필요하면 Xcode project를 선택한다.

완료 기준:

- 빌드 명령이 하나로 확정된다.
- 폴더 구조가 `architecture.md`의 레이어 경계를 따른다.

### Phase 1. Core 모델과 상태부터 작성

목표:

- `SwitcherItem`
- `SwitcherMode`
- `SwitcherState`
- selection reducer
- fallback title 규칙
- fake provider protocol

완료 기준:

- macOS API 없이 단위 테스트 가능하다.
- next/previous wraparound가 테스트된다.

### Phase 2. Window catalog spike

목표:

- VS Code, Chrome/Brave, Finder 등의 창 metadata를 조회할 수 있는지 확인한다.
- 각 row에 필요한 최소 데이터만 확인한다.
  - app identity
  - PID
  - window ID 또는 AX window reference
  - title
  - app icon 연결 가능성

완료 기준:

- 모든 앱/창 모드에 사용할 후보 row를 만들 수 있다.
- 활성 앱 창 모드에 사용할 foreground app filtering 기준을 확인한다.
- title 누락/권한 제한 케이스가 fallback으로 표현된다.

### Phase 3. Exact window raise spike

목표:

- 선택한 창을 정확히 앞으로 가져올 수 있는지 검증한다.
- Accessibility 허용/거부 상태에서 동작 차이를 확인한다.
- app activation fallback과 exact raise 성공을 구분한다.

결과 분류:

| 결과 | 의미 | 다음 행동 |
| --- | --- | --- |
| `exact-window-success` | 선택 창이 정확히 foreground가 됨 | P0 그대로 진행 |
| `limited-app-fallback-success` | 앱은 활성화됐지만 선택 창 보장은 약함 | MVP에 제한 성공으로 기록하고 fallback UX 포함 |
| `safe-failure` | 창/app 전환 모두 실패 | 구현 중단 후 요구사항 재검토 필요 |

### Phase 4. HotkeyService 구현

목표:

- 모든 앱/창 모드 hotkey 등록
- 활성 앱 창 모드 hotkey 등록

우선순위:

1. native API 직접 사용
2. 막히면 작은 HotKey 패키지 검토

완료 기준:

- 두 hotkey가 각각 올바른 mode open event를 발생시킨다.
- 등록 실패가 diagnostic으로 남는다.

### Phase 5. SwitcherPanel UI 구현

목표:

- 참고 이미지처럼 어두운 반투명 panel
- app icon + window/app title row
- 파란색 선택 하이라이트
- empty/error/permission 안내 상태

완료 기준:

- 썸네일 없이 리스트 UI가 표시된다.
- 단일 활성 앱 창은 1개 row로 표시된다.

### Phase 6. Keyboard navigation 연결

목표:

- 다음/이전 이동
- Enter 또는 release confirm
- Escape cancel
- wraparound

완료 기준:

- keyboard-only flow가 가능하다.

### Phase 7. Activation 연결

목표:

- window row는 exact raise 먼저 시도한다.
- 실패하면 app activation fallback을 시도한다.
- app row는 app activation을 시도한다.

완료 기준:

- result가 exact success / limited fallback / safe failure로 기록된다.
- crash 없이 panel이 닫히거나 error state가 표시된다.

### Phase 8. Permission/failure handling

목표:

- Accessibility denied 안내
- Privacy/Screen Recording 관련 가능성 안내
- 창 닫힘/빈 목록/hotkey 실패 처리

완료 기준:

- `validation-plan.md`의 failure case를 통과한다.

### Phase 9. Validation

목표:

- 자동 테스트 실행
- 수동 테스트 matrix 실행
- build command 확인

완료 기준:

- `docs/acceptance-criteria.md` P0가 충족된다.
- `docs/validation-plan.md`에 결과를 기록할 수 있다.

## 4. MVP에서 의도적으로 하지 않는 것

- 창 썸네일
- 화면 캡처
- 설정 UI
- 창 검색
- 앱별 그룹핑 옵션
- 배포/서명/공증 자동화
- 디자인 polish

## 5. 후속 실행 옵션

- 기본 추천: `$ultragoal`로 이 계획을 durable goal로 전환해 순차 구현한다.
- 병렬이 필요할 때: `$team`으로 Core/Adapters/UI/Validation lane을 분리한다.
- 명시적 fallback: 사용자가 원할 때만 `$ralph`로 단일 owner 지속 검증 루프를 사용한다.

## 6. 권장 작업 분할

| Lane | 역할 | 산출물 |
| --- | --- | --- |
| Core | 모델/상태/테스트 | pure Swift unit-tested core |
| macOS spike | window catalog/raise/hotkey 검증 | adapter feasibility notes |
| UI | panel/list/keyboard | minimal switcher UI |
| Validation | 수동/자동 검증 | validation evidence |

MVP가 작으므로 최초 실행은 single-owner 순차 구현이 적합하다. 창 전환 spike가 막힐 경우에만 병렬 조사 또는 사용자 결정이 필요하다.
