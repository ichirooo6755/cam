import SwiftUI

@main
struct PiCameraControlApp: App {
    @AppStorage("appAppearanceMode") private var appAppearanceMode: String = "system"
    @StateObject private var connectionMonitor = ConnectionMonitor.shared
    @Environment(\.scenePhase) private var scenePhase

    // Core Data永続化コントローラー
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            TabView {
                UnifiedGalleryView()
                    .tabItem {
                        Label("ギャラリー", systemImage: "photo.on.rectangle.angled")
                    }

                ContentView()
                    .tabItem {
                        Label("設定", systemImage: "gearshape")
                    }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
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
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .active:
                    connectionMonitor.handleForegroundReturn()
                case .background:
                    connectionMonitor.handleBackgroundEntry()
                default:
                    break
                }
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

/// 全タブ共通のオフラインバナー（.safeAreaInset で挿入されるため、位置は自動調整）
struct OfflineBannerView: View {
    @EnvironmentObject var connectionMonitor: ConnectionMonitor

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 13, weight: .bold))
            Text("OFFLINE")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
            Text("Pi に接続できません")
                .font(.system(size: 11, weight: .medium))
            Spacer()
            if connectionMonitor.consecutiveFailures > 0 {
                Text("\(connectionMonitor.consecutiveFailures)回失敗")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .opacity(0.7)
            }
            Button {
                Task { await connectionMonitor.checkNow() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .bold))
            }
        }
        .foregroundColor(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            LinearGradient(
                colors: [Color.red.opacity(0.9), Color.orange.opacity(0.8)],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
    }
}
