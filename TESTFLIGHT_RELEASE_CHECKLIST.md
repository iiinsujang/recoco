# Recoco TestFlight 배포 체크리스트

현재 프로젝트 설정:

- 앱 타깃: `Recoco`
- Bundle ID: `app.recoco.ios`
- iOS 최소 버전: `16.0`
- 앱 버전: `1.0`
- 빌드 번호: `1`

## 1. 로컬 Mac 준비

1. Mac App Store에서 전체 Xcode를 설치합니다.
2. Xcode를 활성 개발 도구로 선택합니다.

   ```sh
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   ```

3. Xcode를 한 번 열고 라이선스 동의와 추가 컴포넌트 설치를 완료합니다.
4. Xcode Settings > Accounts에서 Apple Developer Program 계정으로 로그인합니다.

## 2. Archive 전 프로젝트 준비

1. `Recoco.xcodeproj`를 엽니다.
2. `Recoco` 타깃을 선택합니다.
3. Signing & Capabilities에서 올바른 Apple Developer Team을 선택합니다.
4. Bundle Identifier가 `app.recoco.ios`인지 확인합니다.
5. `Config.xcconfig`의 placeholder 값을 실제 값으로 교체합니다.

   ```xcconfig
   GOOGLE_CLIENT_ID = ...
   REVERSED_CLIENT_ID = ...
   ```

6. TestFlight 빌드에서 Firebase를 사용할 경우 `GoogleService-Info.plist`를 추가합니다.
7. `Recoco/Resources/Assets.xcassets/AppIcon.appiconset`의 내부 테스트용 아이콘을 정식 브랜딩 아이콘으로 교체합니다.
8. TestFlight에 새 빌드를 올릴 때마다 `CURRENT_PROJECT_VERSION`을 올립니다.

## 3. App Store Connect 준비

1. App Store Connect에서 `Recoco` iOS 앱 레코드를 생성합니다.
2. Bundle ID는 `app.recoco.ios`를 사용합니다.
3. TestFlight 필수 정보를 입력합니다.

   - 베타 앱 설명
   - 피드백 이메일
   - 외부 테스터를 사용할 경우 베타 앱 심사 정보

4. 테스터 초대 전 개인정보 처리와 수출 규정 질문을 완료합니다.

## 4. Archive 및 업로드

위 준비가 끝난 뒤 프로젝트 루트에서 실행합니다.

```sh
xcodebuild -resolvePackageDependencies -project Recoco.xcodeproj -scheme Recoco
xcodebuild clean archive -project Recoco.xcodeproj -scheme Recoco -configuration Release -destination 'generic/platform=iOS' -archivePath build/Recoco.xcarchive
xcodebuild -exportArchive -archivePath build/Recoco.xcarchive -exportPath build/TestFlight -exportOptionsPlist ExportOptions.TestFlight.plist
```

명령어 업로드가 서명이나 계정 인증에서 막히면 Xcode에서 진행합니다.

1. Product > Archive
2. Organizer > Distribute App
3. App Store Connect
4. Upload

## 5. 1차 베타 테스트 범위

처음에는 내부 테스터 소수로 시작합니다.

- 회원가입 / 로그인
- 사진 접근 권한 및 선택한 사진만 허용했을 때의 흐름
- 홈 일일 큐레이션: 3장, 2장, 1장, 0장 Empty State
- 비우기 / 기록하기 액션과 복구 기대감
- 프리미엄 전용 비슷한 사진 묶음 정리 흐름
- 30분 단위 알림 설정
- 리포트 화면
- App Store Connect의 테스터 피드백과 크래시 리포트

## 현재 확인된 막힘

- 현재 이 Mac은 전체 Xcode가 아니라 Command Line Tools만 선택되어 있습니다.
- 프로젝트에 Apple Developer Team이 아직 설정되어 있지 않습니다.
- `Config.xcconfig`에 Google Sign-In placeholder 값이 남아 있습니다.
- 내부 테스트용 앱 아이콘은 추가했지만, 넓은 베타 전에는 정식 브랜딩 아이콘으로 교체하는 편이 좋습니다.
- `xcodebuild`가 전체 Xcode를 요구하므로 실제 archive 빌드는 아직 검증하지 못했습니다.
