import SwiftUI
import Photos
import PhotosUI

// MARK: - S-03A 사진 접근 안내 및 권한 요청
// 명세서 §8 S-03A
// - 사진 원본 미전송 안내
// - 전체 허용 / 제한적 허용 / 거부 분기
// - 중립적인 ‘다음’ 한 가지 액션으로 시스템 권한 선택창 연결

struct PhotoPermissionView: View {
    @EnvironmentObject private var router: AppRouter
    @State private var isRequesting: Bool = false

    var body: some View {
        ZStack {
            Color.rBackground.ignoresSafeArea()

            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: RSpacing.xl) {
                        Spacer(minLength: 0)
                        illustrationSection
                        descriptionSection
                        Spacer(minLength: RSpacing.md)
                        actionSection
                    }
                    .padding(RLayout.screenInset)
                    .frame(minHeight: geometry.size.height)
                }
            }
        }
    }

    // MARK: - 일러스트

    private var illustrationSection: some View {
        RSealIllustration(pose: .curious, width: RCharacterSize.state)
    }

    // MARK: - 안내 텍스트

    private var descriptionSection: some View {
        VStack(spacing: RSpacing.md) {
            Text("내 사진에서\n살펴볼 이유를 찾아요.")
                .rTextStyle(.headlineLarge)
                .multilineTextAlignment(.center)
                .lineSpacing(RLineSpacing.body)

            Text("허용한 사진 안에서\n매일 새 후보를 최대 세 장 찾아요.")
                .rTextStyle(.body, color: .rTextSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: RSpacing.sm) {
                permissionRow(
                    icon: "photo.on.rectangle",
                    text: String(localized: "선택한 사진만 허용해도 괜찮아요.")
                )
                permissionRow(
                    icon: "icloud.slash",
                    text: String(localized: "기기에서 분석해요. 원본은 서버로 보내지 않아요.")
                )
                permissionRow(
                    icon: "hand.tap",
                    text: String(localized: "삭제는 항상 직접 확인 후 진행돼요.")
                )
            }
            .padding(.top, RSpacing.sm)
        }
    }

    private func permissionRow(icon: String, text: String) -> some View {
        HStack(spacing: RSpacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(.rTextSecondary)
                .frame(width: 24)

            Text(text)
                .rTextStyle(.body, color: .rTextSecondary)

            Spacer()
        }
    }

    // MARK: - 액션 버튼

    private var actionSection: some View {
        VStack(spacing: RLayout.actionGap) {
            RButton(
                title: String(localized: "다음"),
                variant: .primary,
                isLoading: isRequesting
            ) {
                requestPhotoAccess()
            }
            .accessibilityIdentifier("photoPermission.request")

        }
    }

    // MARK: - 권한 요청

    private func requestPhotoAccess() {
        isRequesting = true

        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            DispatchQueue.main.async {
                isRequesting = false

                switch status {
                case .authorized, .limited:
                    // 전체 또는 제한적 접근 — S-04 이동
                    router.navigateTo(.main)

                case .denied, .restricted:
                    // 거부 — S-04 권한 없음 상태로 이동
                    // 홈에서 별도 안내 표시
                    router.navigateTo(.main)

                case .notDetermined:
                    break

                @unknown default:
                    router.navigateTo(.main)
                }
            }
        }
    }
}

#if DEBUG
#Preview {
    PhotoPermissionView()
        .environmentObject(AppRouter())
}
#endif
