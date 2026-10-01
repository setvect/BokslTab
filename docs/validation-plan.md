# BokslTab 검증 계획

## 1. 목적

이 문서는 BokslTab MVP 구현 후 무엇을 자동/수동으로 검증할지 정의한다. 자동 검증은 `swift test`로 실행하며, 실제 앱 전환과 권한 동작은 아래 수동 시나리오로 확인한다.

## 2. 자동 테스트 항목

자동 테스트는 macOS UI/권한에 덜 의존하는 Core와 adapter contract를 우선한다.

| ID | 항목 | 검증 내용 |
| --- | --- | --- |
| T-AUTO-01 | Selection wraparound | next/previous가 리스트 끝에서 순환하는지 |
| T-AUTO-02 | 모든 앱/창 mode filtering | fake app/window 목록이 올바른 row로 변환되는지 |
| T-AUTO-03 | 활성 앱 창 mode filtering | foreground app의 window만 남는지 |
| T-AUTO-04 | title fallback | window title → app name → fallback 순서가 지켜지는지 |
| T-AUTO-05 | icon fallback | icon 누락 시 placeholder가 선택되는지 |
| T-AUTO-06 | exact raise success result | fake WindowActivator 성공 시 `exact-window-success`인지 |
| T-AUTO-07 | app fallback result | exact raise 실패 + app activation 성공 시 `limited-app-fallback-success`인지 |
| T-AUTO-08 | safe failure result | exact/app activation 모두 실패 시 safe failure인지 |
| T-AUTO-09 | permission state | denied/unknown/allowed 상태가 UI guidance state로 매핑되는지 |
| T-AUTO-10 | empty state | 빈 row 목록이 empty state로 매핑되는지 |

## 3. 수동 테스트 항목

| ID | 시나리오 | 준비 | 기대 결과 |
| --- | --- | --- | --- |
| T-MANUAL-01 | VS Code 다중 창 | VS Code 프로젝트 창 2개 이상 열기 | 모든 앱/창 모드에서 VS Code row가 창별로 표시됨 |
| T-MANUAL-02 | VS Code 활성 앱 창 모드 | VS Code를 foreground로 둠 | 활성 앱 창 모드에서 VS Code 창만 표시됨 |
| T-MANUAL-03 | Chrome/Brave 다중 창 | browser 창 2개 이상 열기 | discoverable window가 별도 row로 표시됨 |
| T-MANUAL-04 | Accessibility 허용 | Accessibility permission 허용 | 선택한 window raise가 `exact-window-success`로 동작 |
| T-MANUAL-05 | Accessibility 거부 | Accessibility permission 거부 | crash 없이 권한 안내 또는 app fallback 수행 |
| T-MANUAL-06 | 선택 직전 창 닫힘 | panel 표시 후 선택 대상 창 닫기 | crash 없이 refresh/close/safe failure |
| T-MANUAL-07 | 빈 목록 | 필터 결과가 없도록 구성 | empty state 또는 panel no-open, no crash |
| T-MANUAL-08 | 단일 활성 앱 창 | foreground app window 1개 | 1개 row 표시, confirm 시 raise/app activation 시도 |
| T-MANUAL-09 | 앱 단위 fallback | exact window raise 불가 대상 | app activation fallback은 제한 성공으로 기록 |
| T-MANUAL-10 | Escape 취소 | panel 표시 | panel 닫힘, 기존 focus 유지 |
| T-MANUAL-11 | 썸네일 제외 | panel 표시 | icon/title만 있고 screenshot/thumbnail 없음 |
| T-MANUAL-12 | hotkey 충돌/등록 실패 | 충돌 상황 또는 fake failure | diagnostic 기록, crash 없음 |

## 4. 빌드 검증 명령

현재 프로젝트는 SwiftPM을 사용한다.

### SwiftPM 선택 시

```bash
swift build
swift test
```

### Xcode project 선택 시

```bash
xcodebuild build -scheme BokslTab -destination 'platform=macOS'
xcodebuild test -scheme BokslTab -destination 'platform=macOS'
```

### 현재 planning-only repo 검증

```bash
git status --short
python3 - <<'PY'
from pathlib import Path
required = {
  'docs/architecture.md': ['기술 스택', '폴더 구조', '주요 모듈', 'fallback'],
  'docs/plan.md': ['구현 순서', 'MVP', 'window catalog', 'exact window raise'],
  'docs/acceptance-criteria.md': ['AC-P0', 'exact-window-success', 'limited-app-fallback-success'],
  'docs/validation-plan.md': ['자동 테스트', '수동 테스트', '빌드 검증 명령']
}
for path, terms in required.items():
    text = Path(path).read_text()
    missing = [term for term in terms if term not in text]
    print(path, 'OK' if not missing else f'MISSING {missing}')
PY
```

## 5. 위험 요소와 fallback 전략

| 위험 | 검증 방법 | fallback | 성공 판정 |
| --- | --- | --- | --- |
| Accessibility 거부 | 권한 거부 상태에서 창 전환 시도 | 권한 안내 + app fallback | crash 없음, 제한 성공/실패 구분 |
| Screen Recording/Privacy 제약 | title/metadata 누락 관찰 | fallback title | row 표시 유지 |
| exact window raise 실패 | fake/manual 실패 유도 | app activation fallback | `limited-app-fallback-success` 기록 |
| app activation 실패 | fake/manual 실패 유도 | safe failure | crash 없음 |
| 창이 닫힘 | 선택 직전 창 닫기 | refresh/close/safe failure | crash 없음 |
| hotkey 등록 실패 | fake failure 또는 충돌 구성 | diagnostic | 앱 crash 없음 |
| 창 목록 조회 지연 | 다중 창 환경에서 체감 확인 | 최소 조회/cache | panel이 현저히 멈추지 않음 |
| scope creep | PRD와 비교 | 썸네일/settings 제외 | MVP 범위 유지 |

## 6. 검증 완료 조건

- P0 Acceptance Criteria 전체가 통과한다.
- 자동 테스트가 선택된 빌드 시스템에서 통과한다.
- 수동 테스트 matrix의 핵심 항목이 통과하거나 제한 사항이 문서화된다.
- exact window raise 성공과 app fallback 제한 성공이 결과상 구분된다.
- 썸네일/settings/distribution polish가 구현 범위에 들어오지 않는다.

## 응답 지연 및 리팩토링 회귀 검증

- 단축키 일부 등록 실패 후 Cmd+Tab 재등록 여부를 coordinator와 우선순위 서비스의 조합으로 검증한다.
- AX 속성 조회·활성화가 메인 스레드 밖에서 실행되고, 첫 타임아웃 후 추가 요청을 중단하는지 검증한다.
- 다른 앱의 조회는 계속 허용하고, 실패 앱의 재시도는 15초 후 가능하며 중간 요청으로 지연되지 않는지 확인한다.
- 취소한 조회가 늦게 끝나도 앱 포커스를 바꾸지 않는지 확인한다.
- 임시 앱 항목의 창 목록 전환, 탭 선택 보존, 패널의 확대·축소와 화면 컨트롤러 재사용을 검증한다.
- 목록 읽기와 갱신 알림에서 추가 AX 갱신이 자동 예약되지 않는지 확인한다.
- 파일 로그의 순차 기록과 크기 제한을 임시 디렉터리에서 검증한다.
- 동시성 변경 시 `swift test --sanitize=thread`로 AX·캐시·활성화 테스트를 확인한다.

수동으로는 손쉬운 사용 권한이 부여된 개발용 앱에서 Cmd+Tab / Option+Tab, 빠른 재입력, 여러 네이티브 탭, 응답이 느린 앱의 선택을 확인한다. 테스트를 위해 실제 사용자 앱을 강제로 멈추지 않는다.
