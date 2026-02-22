import SwiftUI

@main
struct PiCameraControlApp: App {
    @AppStorage("appAppearanceMode") private var appAppearanceMode: String = "system"
    @StateObject private var connectionMonitor = ConnectionMonitor.shared

    // Core Data永続化コントローラー
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ZStack(alignment: .top) {
                TabView {
                    CameraStatusView()
                        .tabItem {
                            Label("ステータス", systemImage: "gauge.with.needle")
                        }

                    UnifiedGalleryView()
                        .tabItem {
                            Label("ギャラリー", systemImage: "photo.on.rectangle.angled")
                        }

                    ContentView()
                        .tabItem {
                            Label("設定", systemImage: "gearshape")
                        }
                }

                if !connectionMonitor.isConnected {
                    OfflineBannerView()
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.3), value: connectionMonitor.isConnected)
            .tint(MinimalTheme.Accent.primary)
            .environment(\.managedObjectContext, persistenceController.container.viewContext)
            .environmentObject(connectionMonitor)
            .preferredColorScheme(computedColorScheme)
            .onAppear {
                connectionMonitor.startMonitoring()
            }
        }
    }

    private var computedColorScheme: ColorScheme? {
        switch appAppearanceMode {
        case "light":
            return .light
        case "dark":
            return .dark
        default:
            return nil
        }
    }
}

/// 全タブ共通のオフラインバナー
struct OfflineBannerView: View {
    @EnvironmentObject var connectionMonitor: ConnectionMonitor

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 14, weight: .bold))
            Text("OFFLINE")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
            Text("- Pi に接続できません")
                .font(.system(size: 12, weight: .medium))
            Spacer()
            Button {
                Task { await connectionMonitor.checkNow() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .bold))
            }
        }
        .foregroundColor(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            LinearGradient(
                colors: [Color.red.opacity(0.85), Color.orange.opacity(0.75)],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .padding(.top, 0)
    }
}
