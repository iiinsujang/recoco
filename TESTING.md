# 검증 안내

## 이 소스의 기준

1.0 (99) 출시 소스를 정리한 저장소입니다. [핵심 파일 목록](docs/releases/1.0-99-core-manifest.json)은 출시 아카이브 준비 당시 기록한 11개 파일의 SHA-256 값입니다. 전체 소스나 배포 바이너리를 인증하는 목록은 아닙니다.

## 로컬 점검

README의 비공개 로컬 구성을 준비한 뒤 실행합니다.

```sh
python3 scripts/check_localizations.py
python3 -m unittest discover -s scripts -p 'test_release_preflight.py'
./scripts/release_preflight.sh --with-apple-auth
xcodebuild -showdestinations -project Recoco.xcodeproj -scheme Recoco
```

사용 가능한 시뮬레이터 ID를 선택해 앱 테스트를 실행합니다. 다음 명령의 `SIMULATOR_ID`는 실제 ID로 바꿉니다.

```sh
xcodebuild test -project Recoco.xcodeproj -scheme Recoco \
  -destination 'platform=iOS Simulator,id=SIMULATOR_ID' \
  -only-testing:RecocoTests CODE_SIGNING_ALLOWED=NO
```

`RecocoUITests`는 별도의 테스트용 시뮬레이터와 사진으로 실행하세요. 실제 사용자 사진·기록을 쓰는 기기에서 자동 삭제 검사를 실행하지 마세요. 구독 검증은 출시 기능과 분리된 `RecocoSubscriptions` 스킴 및 StoreKit 테스트 구성을 사용합니다.

## 주요 확인 범위

- 추천 근거, 후보 다양성, 일별 교체와 30일 재추천 간격
- 추천·선택 복원, 사진 로딩 실패 시 비우기 차단, 재시도
- 제한된 접근의 추가 선택창과 권한 변경 후 복귀
- 비우기 취소, 날짜·월별 집계, 계정 전환 시 로컬 기록 유지
- 온보딩·다국어, 앱 전용 투표, 공개 문서 연결

## 출시 당시 검증 기록의 한계

출시 준비 당시 앱 검사는 587개 중 586개 통과, 기기 조건 관련 1개 건너뜀, 실패 0개로 기록했습니다. StoreKit 검사 7개는 별도로 확인했습니다. 이 수치는 소스 동기화 때 모든 검사를 다시 실행했다는 뜻이 아닙니다.

iPhone 13 Pro의 새 분석 측정에서는 첫 미리보기 1.98–2.76초, 세 장 표시 5.62–7.32초를 기록했습니다. 분석 시작 기준이며 앱 프로세스 시작부터의 시간은 아닙니다. PhotoKit 캐시가 남아 있었고 모든 사진이 iCloud에만 있는 조건을 보장하지 않습니다. 세 종류의 근거가 모든 사진함에서 항상 존재하는 것도 아닙니다.

기기 백업·개인 사진·상세 로그는 공개 저장소에 포함하지 않습니다. 향후 변경 시에는 해당 변경 범위의 검사를 다시 실행하고, 실제 기기 성능은 별도로 측정해야 합니다.
