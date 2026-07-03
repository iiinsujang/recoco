import SwiftUI
import Photos
import PhotosUI

// MARK: - S-03A 사진 접근 안내 및 권한 요청
// 명세서 §8 S-03A
// - 사진 원본 미전송 안내
// - 전체 허용 / 제한적 허용 / 거부 분기
// - 나중에: S-04 권한 미허용 상태로 이동

struct PhotoPermissionView: View {
    @EnvironmentObject private var router: AppRouter
    @State private var isRequesting: Bool = false

    var body: some View {
        ZStack {
            Color.rBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // 일러스트 영역
                illustrationSection

                // 안내 텍스트
                descriptionSection

                Spacer()

                // 액션 버튼
                actionSection
                    .padding(.bottom, RSpacing.xxxl)
            }
            .padding(.horizontal, RSpacing.md)
        }
    }

    // MARK: - 일러스트

    private var illustrationSection: some View {
        // 에셋이 없으면 최소 아이콘으로 대체
        ZStack {
            Circle()
                .fill(Color.rSurface)
                .frame(width: 100, height: 100)

            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 40))
                .foregroundColor(.rTextSecondary)
        }
        .padding(.bottom, RSpacing.xxxl)
    }

    // MARK: - 안내 텍스트

    private var descriptionSection: some View {
        VStack(spacing: RSpacing.md) {
            Text("사진을 직접 올리지\n않아도 돼요.")
                .rTextStyle(.headlineLarge)
                .multilineTextAlignment(.center)
                .lineSpacing(RLineSpacing.body)

            VStack(spacing: RSpacing.sm) {
                permissionRow(
                    icon: "lock.shield",
                    text: "사진은 기기 안에서만 분석돼요."
                )
                permissionRow(
                    icon: "icloud.slash",
                    text: "원본은 서버로 전송되지 않아요."
                )
                permissionRow(
                    icon: "hand.tap",
                    text: "삭제는 항상 직접 확인 후 진행돼요."
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
        .padding(.horizontal, RSpacing.xl)
    }

    // MARK: - 액션 버튼

    private var actionSection: some View {
        VStack(spacing: RSpacing.sm) {
            RButton(
                title: "사진 접근 허용하기",
                variant: .primary,
                isLoading: isRequesting
            ) {
                requestPhotoAccess()
            }

            Button("나중에 할게요") {
                router.navigateTo(.main)
            }
            .rTextStyle(.subLabel, color: .rTextTertiary)
            .frame(minHeight: RSize.minTouchTarget)
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
