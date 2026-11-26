# Recoco · 하루 3장 사진 정리

쌓인 사진을 어디서부터 정리할지 막막할 때, 정리할 만한 사진과 그 이유를 함께 보여주는 iPhone 앱입니다. 사진 분석은 기기 안에서 이루어지며, 사진을 직접 선택하고 iOS 삭제 확인을 완료해야 사진이 비워집니다.

이 저장소는 **2026년 11월 24일 공개한 1.0 (99)** 기준으로 정리했습니다. 무료 사진 정리, 선택적 Apple 로그인, 비움 캘린더와 집계, 다음 정리 항목 투표, 31개 앱 언어를 포함합니다. 출시 버전의 구독 기능은 꺼져 있습니다.

## 현재 동작

- 같은 사진, 가까운 시간에 찍은 비슷한 사진, 안내 문구 등 실제로 확인한 근거를 우선합니다. 서로 다른 근거를 우선하되 부족하면 같은 유형의 후보로 최대 세 장을 채웁니다. 허용된 사진과 분석 결과에 따라 세 장보다 적을 수 있습니다.
- 저장된 추천을 먼저 복원하고 새 후보를 분석합니다. 처음 보는 사진이나 iCloud에만 있는 사진에는 추가 시간이 필요할 수 있습니다.
- 사진을 표시하지 못하면 비우기를 막습니다. 선택·취소·재실행과 계정 전환에서도 기기의 기록과 선택을 유지하도록 구현했습니다.
- 사진을 서버에 업로드하지 않습니다. 선택적 로그인과 공유 투표 결과에는 네트워크가 필요합니다.

## 프로젝트 구성

| 경로 | 내용 |
| --- | --- |
| `Recoco/` | SwiftUI 앱, 사진 추천, 기록, 계정, 투표, 디자인과 다국어 리소스 |
| `Recoco.xcodeproj/` | 앱·테스트 대상, 공유 스킴, 고정된 Swift 패키지 버전 |
| `RecocoTests/`, `RecocoUITests/` | 동작 및 화면 검증 |
| `scripts/` | 출시 설정·번역 점검과 빌드 준비 도구 |
| `functions/` | 초기 기록 생성 기능의 서버 예제. 현재 사진 추천 엔진에는 사용하지 않습니다. |
| `outputs/recoco-prototype/` | 과거에 게시한 웹 프로토타입. 현재 iOS 출시 화면과 다를 수 있습니다. |

일부 기록 생성·구독 코드가 남아 있어도 출시 앱에서 모두 노출되는 것은 아닙니다. 앱 전용 투표의 호스팅 서비스 소스와 운영 데이터는 이 iOS 소스 정리 범위에 포함하지 않았습니다.

## 로컬 빌드

Xcode 26 이상이 필요하며 앱의 최소 배포 대상은 iOS 16입니다.

1. `Config.xcconfig.example`을 `Config.xcconfig`로 복사합니다.
2. 권한을 가진 개발자는 프로젝트 루트에 해당 앱의 `GoogleService-Info.plist`를 별도로 준비합니다. 현재 Xcode 프로젝트의 리소스 목록에서 이 파일을 참조합니다. 파일은 저장소에 포함하지 않습니다.
3. `Recoco.xcodeproj`를 열고 `Recoco` 스킴과 시뮬레이터를 선택합니다.
4. 실제 기기·배포 빌드에는 자신의 개발자 계정과 적절한 서명 설정이 필요합니다. 프로젝트의 Release 번들 ID와 팀 설정은 출시 당시 값을 유지했습니다.

Apple 로그인까지 검증하려면 Firebase의 Apple 제공자 설정, Apple 로그인 권한 및 인증 해제 구성이 필요합니다. 서버의 비공개 키는 앱이나 이 저장소에 넣지 마세요. 구성 파일 없이 출시 계정 동작까지 재현할 수 있다고 보장하지 않습니다.

```sh
cp Config.xcconfig.example Config.xcconfig
python3 scripts/check_localizations.py
python3 -m unittest discover -s scripts -p 'test_release_preflight.py'
./scripts/release_preflight.sh --with-apple-auth
xcodebuild build -project Recoco.xcodeproj -scheme Recoco \
  -configuration Release -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO
```

## 검증과 공개 문서

- [검증 안내](TESTING.md)
- [1.0 (99) 소스 정리 범위](docs/releases/1.0-99.md)
- [출시 점검 목록](TESTFLIGHT_RELEASE_CHECKLIST.md)
- [개인정보처리방침](PRIVACY_POLICY.md) · [이용약관](TERMS_OF_SERVICE.md) · [지원](SUPPORT.md)

소스 업데이트는 App Store 배포나 사용자 앱 데이터를 변경하지 않습니다. 비공개 구성, 서명 키, 기기 백업과 개인 사진·검사 로그는 포함하지 않습니다.
