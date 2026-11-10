# recoco 개인정보처리방침

시행일: 2026년 11월 10일

Recoco는 사용자가 허용한 사진에서 정리할 후보를 찾고, 사용자가 선택한 사진을 비우도록 돕는 iOS 앱입니다. 이 방침은 **현재 무료 사진 정리 버전과 선택형 Apple 로그인**에 적용됩니다. 로그인이나 구독 없이도 사진 정리 기능을 모두 사용할 수 있습니다.

Apple 로그인이 없던 이전 버전에는 아래 계정 인증 관련 처리가 적용되지 않습니다.

## 1. 사진과 정보의 처리

### 사진 보관함

Recoco는 iOS에서 사용자가 허용한 범위의 사진과 관련 정보(사진 식별자, 촬영 날짜, 이미지 유형·크기 등)를 읽습니다. 중복·유사 여부와 정리 근거를 확인하는 분석은 기기에서 처리합니다. 사진 원본이나 사진 보관함 식별자를 Recoco 서버 또는 AI 서비스로 업로드하지 않습니다.

현재 사진 정리 기능은 사용자의 현재 위치를 요청하지 않으며, 사진에 저장된 GPS 좌표로 외부 위치 조회를 하지 않습니다.

### 기기에 저장되는 정보

다음 정보는 추천을 이어 보고 결과를 확인하기 위해 앱의 기기 내 저장 공간에 보관됩니다.

- 추천 사진의 식별자·추천 날짜·선정 근거 및 확인 진행 상태
- 사용자가 선택한 사진과 처리 결과, 비운 날짜 및 사진 수
- 온보딩 완료 여부와 알림 설정

삭제하지 않은 추천 사진을 일정 기간 다시 추천하지 않기 위해 추천 이력을 사용합니다. 현재 재추천 간격은 30일이며, 이는 모든 앱 데이터의 자동 삭제 기한을 뜻하지 않습니다.

이전 개발·체험 버전에서 작성한 글이나 사진 미리보기가 기기에 남아 있다면 업데이트 중 이를 보존할 수 있습니다. 현재 버전은 새 기록 작성이나 기록의 서버 동기화 기능을 제공하지 않습니다.

## 2. 계정·결제·추적

### 선택형 Apple 로그인

Apple 로그인은 선택사항입니다. 로그인하면 계정 인증과 로그인 상태 유지를 위해 Apple이 제공하는 이메일 주소, Apple 계정 식별자와 Firebase 사용자 식별자(UID), 인증 토큰을 처리합니다. Apple의 ‘나의 이메일 가리기’를 선택하면 실제 이메일 대신 전달용 이메일을 사용합니다. 이름·전화번호를 요청하지 않으며 Apple 계정 비밀번호를 받지 않습니다. [Firebase의 Apple 로그인 안내](https://firebase.google.com/docs/auth/ios/apple)

인증에는 Google의 **Firebase Authentication**을 사용합니다. 사진 원본·사진 보관함 식별자·기존 기록·선택 상태·비움 집계는 인증 서버로 보내지 않습니다. 로그인해도 이 정보의 계정 동기화나 서버 백업이 생기지 않습니다.

Firebase는 인증 보안과 부정 이용 방지를 위해 IP 주소와 사용자 에이전트 등 기술정보도 처리합니다. 공식 안내에 따르면 Firebase Authentication은 미국에서 데이터를 처리하며, IP 로그는 수주간 보관합니다. 그 외 인증정보는 계정 삭제 요청까지 보관하고, 요청 후 운영·백업 시스템에서 180일 이내 제거합니다. 이는 사진이나 기기 내 내역의 보관기간과는 다릅니다. [Firebase 개인정보·보안 안내](https://firebase.google.com/support/privacy)

Firebase Authentication SDK는 기기·OS·앱 번들 식별자·개발 플랫폼 등 사용자 에이전트 진단정보도 수집합니다. Firebase는 이를 사용자·기기 식별자와 연결하지 않고 플랫폼·버전 사용 현황 분석과 SDK 개선에 사용한다고 안내합니다. [Firebase Apple SDK 데이터 공개 안내](https://firebase.google.com/docs/ios/app-store-data-collection)

### 결제·추적

현재 버전은 구독·앱 내 결제 및 외부 AI 문장 생성 기능을 제공하지 않습니다. 광고 추적, Google Analytics를 통한 앱 이용 행동 분석, 원격 푸시 알림용 토큰 수집도 사용하지 않습니다. 이는 위에서 설명한 Firebase 인증·SDK 진단정보 처리와 구분됩니다.

## 3. Apple 사진·iCloud·알림

- **사진 접근:** 전체 또는 제한된 접근 범위는 iOS에서 사용자가 정합니다. Recoco는 그 범위 밖의 사진을 분석하지 않습니다.
- **iCloud 사진:** 원본이 기기에 없으면 Apple 사진 기능을 통해 불러올 수 있습니다. 이 과정은 사용자의 iCloud 설정과 네트워크 상태에 영향을 받으며 Apple의 정책이 적용됩니다. Recoco가 별도 사진 서버에 보관하는 과정은 아닙니다.
- **사진 삭제:** 사용자가 선택하고 비우기를 요청한 사진만 Apple 사진 기능으로 삭제를 요청합니다. iOS 확인에서 취소하면 삭제를 진행하지 않습니다. iCloud 사진을 사용한다면 삭제가 같은 Apple 계정의 다른 기기에도 반영될 수 있습니다.
- **알림:** 알림을 허용하고 시간을 설정한 경우 기기 내 로컬 알림을 예약합니다. 알림 발송을 위해 Recoco 서버에 사진이나 이용 내역을 보내지 않습니다.

## 4. 보관·삭제·백업

Recoco의 정리 내역과 설정은 앱을 사용하는 동안 기기에 보관됩니다. 앱을 삭제하거나 기기를 초기화하면 해당 내역이 사라질 수 있습니다. Recoco는 이를 복원하기 위한 별도 계정 동기화나 서버 백업을 제공하지 않습니다. 기기 또는 iCloud 백업에 앱 데이터가 포함되는지는 Apple의 백업 방식과 사용자 설정에 따릅니다.

**로그아웃·회원탈퇴와 기기 내역 삭제는 별개입니다.** 로그인한 사용자는 **내 정보 → 회원탈퇴**에서 인증 계정 삭제를 요청할 수 있습니다. 로그아웃하거나 계정을 삭제해도 이 기기의 사진·비움 내역·기존 기록·사진 선택은 유지됩니다. 앱을 삭제하는 것만으로 서버의 인증 계정이 삭제되지는 않습니다.

**앱 내역과 사진 앱의 원본은 서로 다릅니다.** Recoco 앱을 삭제하는 것만으로 사진 앱의 원본이 삭제되지는 않습니다. 반대로 이미 사진 앱에서 삭제한 원본을 Recoco의 내역이나 미리보기로 복구할 수는 없습니다.

비운 사진의 보관·영구 삭제·복구는 Apple 사진 앱에서 관리합니다. 일반적으로 ‘최근 삭제된 항목’에서 30일 동안 복구할 수 있지만, 영구 삭제 여부·사진 보관함 유형 등에 따라 달라질 수 있습니다. [Apple의 사진 삭제·복구 안내](https://support.apple.com/ko-kr/104967)를 확인해주세요. Recoco는 원본 복구나 즉시 확보되는 저장 공간을 보장하지 않습니다.

## 5. 사용자의 선택

- iOS 설정에서 Recoco의 사진 접근 범위를 변경하거나 철회할 수 있습니다.
- 앱 또는 iOS 설정에서 알림을 끌 수 있습니다.
- 추천은 참고 정보입니다. 사진을 선택하지 않거나 비우기를 취소할 수 있으며, 추천만으로 사진이 자동 삭제되지 않습니다.
- Apple 로그인 없이 사용할 수 있으며, 로그인 후에는 **내 정보**에서 로그아웃하거나 회원탈퇴를 요청할 수 있습니다.

## 6. 문의

개인정보 및 앱 이용에 관한 안내는 [Recoco 고객지원 페이지](https://github.com/iiinsujang/recoco/blob/main/SUPPORT.md)에서 확인하고, [contact.dooooo@gmail.com](mailto:contact.dooooo@gmail.com)으로 문의할 수 있습니다.

이메일로 문의하면 사용자가 직접 보낸 발신 이메일 주소와 문의 내용을 답변과 문제 해결을 위해 처리합니다. 이는 앱이 사진이나 이용 내역을 자동 수집하는 것과 구분됩니다. 문의 메일은 Gmail을 통해 수신·보관하며, 이메일 서비스 제공자의 정보 처리에는 [Google 개인정보처리방침](https://policies.google.com/privacy?hl=ko)이 적용됩니다.

[GitHub 문의 페이지](https://github.com/iiinsujang/recoco/issues)도 선택해 이용할 수 있습니다. 문의 작성에 GitHub 계정이 필요할 수 있으며, 공개 이슈의 내용은 다른 사람이 볼 수 있습니다. GitHub에서의 게시·보관 및 계정 정보 처리에는 [GitHub 개인정보처리방침](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement)이 적용됩니다.

문의에 개인 사진, 사진 위치, 비밀번호·인증코드나 전체 진단 파일을 보내지 않아도 됩니다. 화면을 첨부할 경우 개인정보를 가려주세요. Recoco 앱은 사진이나 진단 자료를 문의에 자동 첨부하지 않습니다.

## 7. 방침 변경

기능 또는 정보 처리 방식이 변경되면 이 방침을 갱신합니다. 서버 동기화, 외부 AI 처리 등 새로운 정보 처리가 추가되는 경우 적용 전에 관련 내용과 필요한 선택 절차를 안내합니다.

---

## Privacy Policy Summary in English

The current free iOS version of Recoco provides on-device photo curation and user-confirmed cleanup. An account or subscription is not required. It analyzes photos within the access granted by the user. Original photos and Photo Library identifiers are not uploaded to a Recoco server or an AI service. The current cleanup flow does not request the user's location or perform an external lookup of photo GPS coordinates.

The account-authentication processing described below does not apply to earlier versions without Apple sign-in.

Optional Sign in with Apple uses Firebase Authentication. Recoco processes the email address Apple supplies (including a private relay address if chosen), Apple/Firebase user identifiers and authentication tokens to manage sign-in. It does not request a name or phone number or receive the Apple account password. Photos, saved records, selections and cleanup totals are not uploaded for authentication. [Firebase's Apple sign-in guide](https://firebase.google.com/docs/auth/ios/apple)

Firebase also processes IP addresses and user agents for authentication security and abuse prevention. Its documentation states that Authentication processes data in the United States, retains IP logs for a few weeks, and keeps other authentication data until account deletion is requested; removal from live and backup systems takes place within 180 days of that request. [Firebase privacy and security information](https://firebase.google.com/support/privacy)

The Firebase Authentication SDK also collects diagnostic user-agent information about the device, OS, app bundle and developer platform. Firebase states that this information is not linked to user or device identifiers and is used to understand platform/version adoption and improve its SDK. [Firebase Apple SDK data disclosure guide](https://firebase.google.com/docs/ios/app-store-data-collection)

Recommendation history, selections, cleanup counts and preferences remain in the app's local storage. Older locally saved records may be preserved during updates; new record creation is not part of this release. Recoco provides no account-based sync or server backup. Deleting the app may erase its local history but does not itself delete original photos in Apple Photos. Apple handles iCloud downloads, synchronized deletion and Recently Deleted recovery. Notifications are local. Recoco does not use advertising tracking or Google Analytics behavioral tracking; the Firebase authentication and SDK diagnostics described above are separate.

Signing out or deleting an account preserves the device's photos, history, saved records and selections. Signed-in users can request account deletion from **내 정보 → 회원탈퇴** (Profile → Delete account). Deleting the app does not itself delete the server-side authentication account.

Visit the [Recoco support page](https://github.com/iiinsujang/recoco/blob/main/SUPPORT.md) or email [contact.dooooo@gmail.com](mailto:contact.dooooo@gmail.com). When you contact us, we process the sender email address and inquiry you voluntarily provide to reply and resolve the issue. This is separate from automatic collection by the app. Support emails are received and stored through Gmail, whose processing is covered by [Google's Privacy Policy](https://policies.google.com/privacy).

You may also use the [public GitHub issue tracker](https://github.com/iiinsujang/recoco/issues); posting may require a GitHub account and others can see public issues. [GitHub's Privacy Statement](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement) applies to that service. Private photos, photo locations, passwords, verification codes and full diagnostic files are not needed for an inquiry. Hide personal information in any screenshots. Recoco does not automatically attach photos or diagnostics to support requests.
