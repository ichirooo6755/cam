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
                VStack(spacing: 0) {
                    if !connectionMonitor.isConnected {
                        OfflineBannerView()
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if connectionMonitor.needsCameraConnectorBanner {
                        CameraConnectorBannerView(sensorState: connectionMonitor.cameraSensorState ?? "")
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
            }
            .animation(.easeInOut(duration: 0.3), value: connectionMonitor.isConnected)
            .animation(.easeInOut(duration: 0.3), value: connectionMonitor.needsCameraConnectorBanner)
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
            Text("Pi への接続を確認中")
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

/// Pi には繋がっているが CSI / カメラモジュールが使えないとき（全タブ共通）
struct CameraConnectorBannerView: View {
    let sensorState: String

    private var title: String {
        switch sensorState {
        case "camera_recovering":
            return "カメラを再初期化中"
        default:
            return "カメラコネクター未検出"
        }
    }

    private var message: String {
        switch sensorState {
        case "camera_recovering":
            return "しばらく待つか、電源を入れ直してください"
        default:
            return "CSI リボンケーブル・コネクタの固定を確認してください"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .bold))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .bold))
                Text(message)
                    .font(.system(size: 10, weight: .medium))
                    .opacity(0.95)
            }
            Spacer()
        }
        .foregroundColor(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            LinearGradient(
                colors: [Color.orange.opacity(0.92), Color.yellow.opacity(0.75)],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
    }
}
