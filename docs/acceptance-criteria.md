# BokslTab Acceptance Criteria

## 1. 범위

이 문서는 BokslTab MVP 구현 완료 여부를 판단하기 위한 기준이다. MVP는 앱/창 전환의 핵심 흐름만 검증하며 창 썸네일, 설정 UI, 배포 품질은 제외한다.

## 2. P0 Acceptance Criteria

### AC-P0-1. 모든 앱/창 모드 열기

- Given 여러 앱과 여러 창이 실행 중일 때
- When 사용자가 모든 앱/창 모드 hotkey를 입력하면
- Then BokslTab은 전환 가능한 앱/창 row 목록을 표시한다.

### AC-P0-2. 같은 앱의 여러 창 표시

- Given VS Code 또는 Chrome/Brave가 여러 창을 가지고 있을 때
- When 모든 앱/창 모드가 열리면
- Then 같은 앱의 여러 창이 가능한 경우 각각 별도 row로 표시된다.

### AC-P0-3. 활성 앱 창 모드

- Given 현재 foreground 앱이 여러 창을 가지고 있을 때
- When 사용자가 활성 앱 창 모드 hotkey를 입력하면
- Then 현재 foreground 앱의 창 row만 표시된다.

### AC-P0-4. 단일 활성 앱 창 처리

- Given 현재 foreground 앱에 창이 하나뿐일 때
- When 활성 앱 창 모드가 열리면
- Then BokslTab은 해당 창 1개를 row로 표시한다.

### AC-P0-5. Row 표시 정보

- Given 앱/창 row가 표시될 때
- Then 각 row는 app icon과 window/app title을 표시한다.
- And window title이 없으면 app name 또는 fallback title을 표시한다.

### AC-P0-6. 키보드 이동

- Given switcher panel이 열려 있을 때
- When 사용자가 next/previous 키를 입력하면
- Then 선택 row가 이동한다.
- And 마지막 row 다음은 첫 row로, 첫 row 이전은 마지막 row로 순환한다.

### AC-P0-7. Exact window raise

- Given window row가 선택되어 있고 필요한 권한이 허용되어 있을 때
- When 사용자가 confirm을 입력하면
- Then BokslTab은 해당 window를 foreground로 가져오기를 시도한다.
- And 성공하면 결과를 `exact-window-success`로 취급한다.

### AC-P0-8. App-level fallback

- Given exact window raise가 실패했지만 owner app activation은 가능한 경우
- When 사용자가 window row를 confirm하면
- Then BokslTab은 owner app activation fallback을 수행한다.
- And 결과는 정확한 창 전환 성공이 아니라 `limited-app-fallback-success`로 구분한다.

### AC-P0-9. 앱 단위 row 전환

- Given 창 정보가 없는 앱 단위 row가 선택되어 있을 때
- When 사용자가 confirm을 입력하면
- Then BokslTab은 해당 app activation을 시도한다.

### AC-P0-10. 취소

- Given switcher panel이 열려 있을 때
- When 사용자가 Escape를 입력하면
- Then panel이 닫히고 기존 focus가 유지된다.

### AC-P0-11. 권한 부족 안전 처리

- Given Accessibility 또는 Privacy 제한 때문에 exact window raise나 title 조회가 제한될 때
- When 사용자가 switcher를 사용하면
- Then BokslTab은 crash하지 않는다.
- And 가능한 fallback 또는 간단한 권한 안내를 제공한다.

### AC-P0-12. 창 닫힘 안전 처리

- Given 사용자가 선택한 창이 confirm 직전에 닫혔을 때
- When BokslTab이 전환을 시도하면
- Then crash하지 않고 list refresh, panel close, 또는 safe failure로 처리한다.

### AC-P0-13. 빈 목록 안전 처리

- Given 표시할 전환 대상이 없을 때
- When 사용자가 switcher를 열면
- Then empty state를 표시하거나 panel을 열지 않는다.
- And crash하지 않는다.

### AC-P0-14. 썸네일 제외

- Given switcher panel이 표시될 때
- Then row에는 app icon과 title만 표시된다.
- And 창 썸네일, 화면 캡처, 실시간 preview는 표시되지 않는다.

## 3. P1 Acceptance Criteria

P0 이후 안정화 기준이다.

- 권한 안내 문구가 사용자에게 이해 가능하다.
- 창 목록 조회가 체감상 지연 없이 동작한다.
- icon/title fallback이 일관되다.
- hotkey 충돌 시 개발자가 상수 변경으로 대체할 수 있다.
- 주요 failure result가 로그 또는 debug output으로 구분된다.

## 4. Out-of-scope 확인 기준

아래 항목이 구현되어 있지 않아도 MVP 실패가 아니다.

- 설정 UI
- 창 썸네일
- 창 검색
- 앱별 grouping 옵션
- 배포 자동화
- code signing/notarization
- 다국어 지원
