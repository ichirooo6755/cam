import SwiftUI

struct PhotoGalleryView: View {
    @AppStorage("serverIP") private var serverIP: String = "192.168.0.20"
    
    @State private var photos: [String] = []
    @State private var isLoading = false
    @State private var selectedPhoto: String?
    
    private var api: SimpleCameraAPI {
        SimpleCameraAPI(baseURL: "http://\(serverIP):8001")
    }
    
    var body: some View {
        NavigationView {
            ZStack {
                if photos.isEmpty {
                    emptyState
                } else {
                    photoGrid
                }
                
                if isLoading {
                    ProgressView()
                        .scaleEffect(1.5)
                        .padding(30)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                }
            }
            .navigationTitle("ギャラリー")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        loadPhotos()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundColor(.primary)
                    }
                }
            }
            .onAppear {
                loadPhotos()
            }
            .sheet(item: $selectedPhoto) { filename in
                PhotoDetailView(filename: filename, serverIP: serverIP)
            }
        }
    }
    
    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 60))
                .foregroundColor(.gray.opacity(0.5))
            Text("写真がありません")
                .font(.title3.weight(.medium))
                .foregroundColor(.secondary)
            Text("光を検知すると自動的に撮影されます")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
    
    private var photoGrid: some View {
        ScrollView {
            LazyVGrid(columns: [
                GridItem(.adaptive(minimum: 150), spacing: 12)
            ], spacing: 12) {
                ForEach(photos, id: \.self) { filename in
                    PhotoThumbnail(filename: filename, serverIP: serverIP)
                        .aspectRatio(1, contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .onTapGesture {
                            selectedPhoto = filename
                        }
                }
            }
            .padding()
        }
    }
    
    private func loadPhotos() {
        isLoading = true
        Task {
            do {
                let fetchedPhotos = try await api.fetchPhotos()
                await MainActor.run {
                    photos = fetchedPhotos
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                }
            }
        }
    }
}

struct PhotoThumbnail: View {
    let filename: String
    let serverIP: String
    
    @State private var image: UIImage?
    
    var body: some View {
        ZStack {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.gray.opacity(0.2)
                ProgressView()
            }
        }
        .task {
            await loadImage()
        }
    }
    
    private func loadImage() async {
        let api = SimpleCameraAPI(baseURL: "http://\(serverIP):8001")
        do {
            let loadedImage = try await api.downloadPhoto(filename: filename)
            await MainActor.run {
                image = loadedImage
            }
        } catch {
            // エラー時は何もしない
        }
    }
}

struct PhotoDetailView: View {
    let filename: String
    let serverIP: String
    
    @Environment(\.dismiss) var dismiss
    @State private var image: UIImage?
    @State private var isLoading = true
    
    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                
                if let image = image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else if isLoading {
                    ProgressView()
                        .tint(.white)
                }
            }
            .navigationTitle(filename)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("閉じる") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if let image = image {
                        Button {
                            UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                        } label: {
                            Image(systemName: "square.and.arrow.down")
                        }
                    }
                }
            }
        }
        .task {
            await loadImage()
        }
    }
    
    private func loadImage() async {
        let api = SimpleCameraAPI(baseURL: "http://\(serverIP):8001")
        do {
            let loadedImage = try await api.downloadPhoto(filename: filename)
            await MainActor.run {
                image = loadedImage
                isLoading = false
            }
        } catch {
            await MainActor.run {
                isLoading = false
            }
        }
    }
}

extension String: Identifiable {
    public var id: String { self }
}
