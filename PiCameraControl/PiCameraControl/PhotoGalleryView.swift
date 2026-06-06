import SwiftUI
import PhotosUI

#if canImport(UIKit)
    import UIKit
#endif

struct PhotoGalleryView: View {
    @AppStorage("serverIP") private var serverIP: String = "192.168.4.1"
    
    @State private var photos: [String] = []
    @State private var isLoading = false
    @State private var selectedPhoto: SelectedPhoto?
    @State private var isSelectionMode: Bool = false
    @State private var selectedFilenames: Set<String> = []
    @State private var actionMessage: String?
    @State private var showActionAlert: Bool = false
    @State private var showDeleteConfirmation: Bool = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var importedImage: UIImage?

    private var api: SimpleCameraAPI {
        SimpleCameraAPI(baseURL: "http://\(serverIP):8001")
    }
    
    var body: some View {
        NavigationView {
            ZStack {
                backgroundGradient
                    .ignoresSafeArea()

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
                ToolbarItem(placement: .navigationBarLeading) {
                    if !photos.isEmpty {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                isSelectionMode.toggle()
                                if !isSelectionMode {
                                    selectedFilenames.removeAll()
                                }
                            }
                        } label: {
                            Text(isSelectionMode ? "完了" : "選択")
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
                        PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .foregroundColor(.primary)
                        }

                        Button {
                            loadPhotos()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .foregroundColor(.primary)
                        }
                    }
                }
            }
            .onAppear {
                loadPhotos()
            }
            .sheet(item: $selectedPhoto) { selection in
                GalleryPhotoDetailView(
                    filename: selection.id,
                    serverIP: serverIP,
                    onDeleted: { deletedFilename in
                        photos.removeAll { $0 == deletedFilename }
                        selectedFilenames.remove(deletedFilename)
                    }
                )
            }
            .alert("確認", isPresented: $showDeleteConfirmation) {
                Button("削除", role: .destructive) {
                    deleteSelectedPhotos()
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("選択した\(selectedFilenames.count)枚を削除しますか？")
            }
            .alert("結果", isPresented: $showActionAlert) {
                Button("OK") {
                    actionMessage = nil
                }
            } message: {
                Text(actionMessage ?? "")
            }
            .safeAreaInset(edge: .bottom) {
                if isSelectionMode {
                    selectionActionBar
                }
            }
            .onChange(of: selectedPhotoItem) { oldItem, newItem in
                Task {
                    if let newItem = newItem,
                       let data = try? await newItem.loadTransferable(type: Data.self),
                       let uiImage = UIImage(data: data) {
                        await MainActor.run {
                            importedImage = uiImage
                        }
                    }
                }
            }
            .sheet(item: Binding(
                get: { importedImage.map { ImportedImageWrapper(image: $0) } },
                set: { importedImage = $0?.image }
            )) { wrapper in
                PhotoEditorView(originalImage: wrapper.image)
            }
        }
    }

    private struct ImportedImageWrapper: Identifiable {
        let id = UUID()
        let image: UIImage
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
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.secondarySystemBackground))
        )
        .padding(.horizontal, 24)
    }
    
    private var photoGrid: some View {
        ScrollView {
            LazyVGrid(columns: [
                GridItem(.adaptive(minimum: 150), spacing: 12)
            ], spacing: 12) {
                ForEach(photos, id: \.self) { filename in
                    ZStack(alignment: .topTrailing) {
                        PhotoThumbnail(filename: filename, serverIP: serverIP)
                            .frame(minHeight: 150, maxHeight: 150)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .shadow(color: .black.opacity(0.08), radius: 4, y: 2)

                        if isSelectionMode {
                            let isSelected = selectedFilenames.contains(filename)
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(isSelected ? .blue : .white.opacity(0.85))
                                .padding(6)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                                .padding(10)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                    .onTapGesture {
                        if isSelectionMode {
                            toggleSelection(filename)
                        } else {
                            selectedPhoto = SelectedPhoto(id: filename)
                        }
                    }
                }
            }
            .padding()
        }
    }

    private var selectionActionBar: some View {
        VStack(spacing: 10) {
            Divider().opacity(0.2)
            HStack(spacing: 12) {
                Text("選択: \(selectedFilenames.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)

                Spacer()

                Button {
                    saveSelectedPhotosToLibrary()
                } label: {
                    Label("保存", systemImage: "square.and.arrow.down")
                        .font(.caption.weight(.bold))
                }
                .disabled(selectedFilenames.isEmpty || isLoading)

                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("削除", systemImage: "trash")
                        .font(.caption.weight(.bold))
                }
                .disabled(selectedFilenames.isEmpty || isLoading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(.ultraThinMaterial)
    }

    private var backgroundGradient: some View {
        ZStack {
            Color(.systemBackground)
            LinearGradient(
                colors: [
                    Color.blue.opacity(0.18),
                    Color.teal.opacity(0.12),
                    Color.clear,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [Color.cyan.opacity(0.12), .clear],
                center: .bottomTrailing,
                startRadius: 0,
                endRadius: 420
            )
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

    private func toggleSelection(_ filename: String) {
        if selectedFilenames.contains(filename) {
            selectedFilenames.remove(filename)
        } else {
            selectedFilenames.insert(filename)
        }
    }

    private func saveSelectedPhotosToLibrary() {
        #if canImport(UIKit)
            let targets = Array(selectedFilenames)
            guard !targets.isEmpty else { return }
            isLoading = true

            Task {
                var saved = 0
                var failed = 0

                for filename in targets {
                    do {
                        let image = try await api.downloadPhoto(filename: filename)
                        try await PhotoLibrarySaver.save(image)
                        await MainActor.run {
                            saved += 1
                        }
                    } catch {
                        failed += 1
                    }
                }

                await MainActor.run {
                    isLoading = false
                    actionMessage = failed == 0
                        ? "\(saved)枚を保存しました"
                        : "保存: \(saved)枚 / 失敗: \(failed)枚"
                    showActionAlert = true
                }
            }
        #endif
    }

    private func deleteSelectedPhotos() {
        let targets = Array(selectedFilenames)
        guard !targets.isEmpty else { return }
        isLoading = true

        Task {
            do {
                let result = try await api.deletePhotos(filenames: targets)
                await MainActor.run {
                    isLoading = false

                    photos.removeAll { result.deleted.contains($0) }
                    selectedFilenames.subtract(result.deleted)

                    if result.success {
                        actionMessage = "削除しました: \(result.deleted.count)枚"
                    } else {
                        actionMessage = "削除できない項目があります\n削除: \(result.deleted.count) / 不正: \(result.invalid.count) / エラー: \(result.errors.count)"
                    }
                    showActionAlert = true
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    actionMessage = error.localizedDescription
                    showActionAlert = true
                }
            }
        }
    }
}

private final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, UIImage>()

    init() {
        cache.countLimit = 100
        cache.totalCostLimit = 50 * 1024 * 1024
    }

    func image(forKey key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func setImage(_ image: UIImage, forKey key: String) {
        let cost = Int(image.size.width * image.size.height * 4)
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}

private actor DownloadLimiter {
    static let shared = DownloadLimiter(limit: 4)
    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func acquire() async {
        if running < limit {
            running += 1
        } else {
            await withCheckedContinuation { cont in
                waiters.append(cont)
            }
        }
    }

    func release() {
        running -= 1
        if !waiters.isEmpty {
            running += 1
            let next = waiters.removeFirst()
            next.resume()
        }
    }
}

struct PhotoThumbnail: View {
    let filename: String
    let serverIP: String

    @State private var image: UIImage?
    @State private var didFail = false

    var body: some View {
        ZStack {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .clipped()
            } else if didFail {
                Color.gray.opacity(0.15)
                Image(systemName: "photo")
                    .foregroundColor(.gray.opacity(0.4))
            } else {
                Color.gray.opacity(0.15)
                ProgressView()
            }
        }
        .task {
            await loadImage()
        }
    }

    private func loadImage() async {
        if let cached = ThumbnailCache.shared.image(forKey: filename) {
            image = cached
            return
        }

        await DownloadLimiter.shared.acquire()
        defer { Task { await DownloadLimiter.shared.release() } }

        do {
            let api = SimpleCameraAPI(baseURL: "http://\(serverIP):8001")
            let loaded = try await api.downloadPhoto(filename: filename, thumbnail: true, maxDimension: 300)
            let thumb = downsample(loaded, maxDimension: 300)
            ThumbnailCache.shared.setImage(thumb, forKey: filename)
            await MainActor.run {
                image = thumb
            }
        } catch {
            await MainActor.run {
                didFail = true
            }
        }
    }

    private func downsample(_ source: UIImage, maxDimension: CGFloat) -> UIImage {
        let maxDim = max(source.size.width, source.size.height)
        guard maxDim > maxDimension, maxDim > 0 else { return source }
        let scale = maxDimension / maxDim
        let newSize = CGSize(width: source.size.width * scale, height: source.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            source.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}

struct GalleryPhotoDetailView: View {
    let filename: String
    let serverIP: String
    let onDeleted: (String) -> Void
    
    @Environment(\.dismiss) var dismiss
    @State private var image: UIImage?
    @State private var isLoading = true
    @State private var metadata: PhotoMetadata?
    @State private var showDeleteConfirmation: Bool = false
    @State private var actionMessage: String?
    @State private var showActionAlert: Bool = false
    @State private var isDeleting: Bool = false
    @State private var showEditor: Bool = false
    
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

                if let metadata {
                    VStack {
                        Spacer()
                        VStack(alignment: .leading, spacing: 8) {
                            Text("METADATA")
                                .font(.caption2.weight(.black))
                                .foregroundColor(.white.opacity(0.85))

                            HStack(alignment: .top, spacing: 16) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("MODE: \((metadata.appliedMode ?? metadata.manualMode ?? "-").uppercased())")
                                    Text("ISO: \(metadata.iso?.displayString ?? "-")")
                                    Text("SS: \(metadata.shutterSpeed?.displayString ?? "-")")
                                }
                                .monospacedDigit()

                                Spacer()

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("WB: \((metadata.whiteBalance ?? "-").uppercased())")
                                    Text("Q: \(metadata.quality.map(String.init) ?? "-")")
                                    Text("DATE: \(metadata.capturedDateDisplay)")
                                }
                                .monospacedDigit()
                            }
                            .font(.caption.weight(.medium))
                            .foregroundColor(.white.opacity(0.8))

                            Text("LOC: \(metadata.locationDisplay)")
                                .font(.caption.weight(.medium))
                                .foregroundColor(.white.opacity(0.8))
                                .monospacedDigit()

                            Text("META: \(metadata.meta?.isEmpty == false ? metadata.meta! : "-")")
                                .font(.caption.weight(.medium))
                                .foregroundColor(.white.opacity(0.8))
                                .monospacedDigit()
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.55))
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
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
                        HStack(spacing: 14) {
                            Button {
                                Task {
                                    try? await PhotoLibrarySaver.save(image)
                                }
                            } label: {
                                Image(systemName: "square.and.arrow.down")
                            }

                            Button {
                                showEditor = true
                            } label: {
                                Image(systemName: "slider.horizontal.3")
                            }
                            .disabled(isDeleting)

                            Button(role: .destructive) {
                                showDeleteConfirmation = true
                            } label: {
                                Image(systemName: "trash")
                            }
                            .disabled(isDeleting)
                        }
                    }
                }
            }
        }
        .task {
            await loadImage()
        }
        .fullScreenCover(isPresented: $showEditor) {
            if let image = image {
                PhotoEditorView(originalImage: image)
            } else {
                ProgressView()
            }
        }
        .alert("確認", isPresented: $showDeleteConfirmation) {
            Button("削除", role: .destructive) {
                deletePhoto()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("この写真を削除しますか？")
        }
        .alert("結果", isPresented: $showActionAlert) {
            Button("OK") {
                actionMessage = nil
            }
        } message: {
            Text(actionMessage ?? "")
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

            do {
                let loadedMetadata = try await api.fetchPhotoMetadata(filename: filename)
                await MainActor.run {
                    metadata = loadedMetadata
                }
            } catch {
                return
            }
        } catch {
            await MainActor.run {
                isLoading = false
            }
        }
    }

    private func deletePhoto() {
        isDeleting = true
        let api = SimpleCameraAPI(baseURL: "http://\(serverIP):8001")
        Task {
            do {
                let result = try await api.deletePhotos(filenames: [filename])
                await MainActor.run {
                    isDeleting = false
                    if result.deleted.contains(filename) {
                        onDeleted(filename)
                        dismiss()
                    } else {
                        actionMessage = result.success
                            ? "削除対象が見つかりませんでした"
                            : "削除に失敗しました"
                        showActionAlert = true
                    }
                }
            } catch {
                await MainActor.run {
                    isDeleting = false
                    actionMessage = error.localizedDescription
                    showActionAlert = true
                }
            }
        }
    }
}

struct SelectedPhoto: Identifiable {
    let id: String
}

