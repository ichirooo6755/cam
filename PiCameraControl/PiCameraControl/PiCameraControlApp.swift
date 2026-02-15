import SwiftUI

@main
struct PiCameraControlApp: App {
    @AppStorage("appAppearanceMode") private var appAppearanceMode: String = "system"

    var body: some Scene {
        WindowGroup {
            TabView {
                PhotoGalleryView()
                    .tabItem {
                        Label("写真", systemImage: "photo.on.rectangle")
                    }
                
                ContentView()
                    .tabItem {
                        Label("設定", systemImage: "gearshape")
                    }
            }
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
