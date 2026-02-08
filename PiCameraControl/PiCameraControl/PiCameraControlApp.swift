import SwiftUI

@main
struct PiCameraControlApp: App {
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
        }
    }
}
