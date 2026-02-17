import SwiftUI

struct CameraStatusView: View {
    var body: some View {
        NavigationView {
            ZStack {
                Color(.systemBackground).ignoresSafeArea()

                VStack(spacing: 16) {
                    Image(systemName: "gauge.with.needle")
                        .font(.system(size: 56, weight: .regular))
                        .foregroundColor(.secondary)

                    Text("ステータス")
                        .font(.headline)

                    Text("カメラの状態を表示するビューは準備中です。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle("ステータス")
            .navigationBarTitleDisplayMode(.large)
        }
    }
}

#Preview {
    CameraStatusView()
}
