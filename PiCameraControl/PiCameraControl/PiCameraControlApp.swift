import SwiftUI

@main
struct PiCameraControlApp: App {
    @AppStorage("appAppearanceMode") private var appAppearanceMode: String = "system"

    // Core Data永続化コントローラー
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
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
            .environment(\.managedObjectContext, persistenceController.container.viewContext)
            .preferredColorScheme(preferredColorScheme)
        }
    }

    private var preferredColorScheme: ColorScheme? {
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
