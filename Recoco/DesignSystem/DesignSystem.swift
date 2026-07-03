// MARK: - recoco DesignSystem
//
// 이 파일은 DesignSystem 모듈의 구성 요소를 문서화합니다.
// Xcode에서는 각 파일을 직접 참조하세요.
//
// ┌─────────────────────────────────────────────┐
// │  DesignSystem/                              │
// │  ├── Colors.swift          컬러 토큰         │
// │  ├── Typography.swift      폰트·텍스트 스타일  │
// │  ├── Spacing.swift         간격·크기 상수     │
// │  └── Components/                           │
// │      ├── RButton.swift     버튼 컴포넌트      │
// │      ├── RCard.swift       카드·배지·토스트   │
// │      └── RNavigation.swift 탭바·네비게이션    │
// └─────────────────────────────────────────────┘
//
// 사용 예시:
//
//   RButton(title: "정리하기", variant: .primary) { }
//   RBadge(text: "HIGH DETOX", variant: .detox)
//   RProgressBar(progress: 3.0 / 7.0)
//   Text("RECOCO").rTextStyle(.wordmark)
//   Color.rTextPrimary
//   RSpacing.md        // 16pt
//   RRadius.lg         // 12pt
//
// Inter 폰트 설치:
//   1. https://rsms.me/inter/ 에서 Inter 다운로드
//   2. TTF 파일을 Xcode 프로젝트 Resources에 추가
//   3. Info.plist > UIAppFonts 에 파일명 등록
//   Inter 미설치 시 시스템 폰트로 자동 폴백됩니다.
