import SwiftUI

@main
struct PiCameraControlApp: App {
    @AppStorage("appAppearanceMode") private var appAppearanceMode: String = "system"

    // Core Data永続化コントローラー
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            TabView {
                PhotoGalleryView()
                    .tabItem {
                        Label("写真", systemImage: "photo.on.rectangle")
                    }

                EditedPhotosListView()
                    .tabItem {
                        Label("編集済み", systemImage: "photo.badge.checkmark")
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
