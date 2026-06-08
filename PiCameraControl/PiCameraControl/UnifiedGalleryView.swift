import SwiftUI
import CoreData
import PhotosUI

#if canImport(UIKit)
import UIKit
#endif

/// 統合ギャラリービュー（サーバー写真 + 編集版を統合管理）
struct UnifiedGalleryView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject var connectionMonitor: ConnectionMonitor
    @AppStorage("serverIP") private var serverIP: String = "192.168.4.1"

    // PhotoGroup一覧
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \PhotoGroup.latestVersion?.updatedAt, ascending: false)],
        animation: .default
    )
    private var photoGroups: FetchedResults<PhotoGroup>

    @State private var isLoading = false
    @State private var selectedGroup: PhotoGroup?
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var importedImage: UIImage?
    @State private var actionMessage: String?
    @State private var showActionAlert = false
    @State private var hasLoadedOnce = false
    @State private var isSelectionMode = false
    @State private var selectedIDs: Set<String> = []
    @State private var showDeleteConfirm = false
    // @State private var showHDRComposer = false // TODO: HDRComposerView追加後に有効化

    private var api: SimpleCameraAPI {
        SimpleCameraAPI(baseURL: "http://\(serverIP):8001")
    }

    var body: some View {
        NavigationStack {
            ZStack {
                backgroundGradient
                    .ignoresSafeArea()

                if photoGroups.isEmpty {
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
                    if isSelectionMode {
                        Button(selectedIDs.count == photoGroups.count ? "全解除" : "全選択") {
                            if selectedIDs.count == photoGroups.count {
                                selectedIDs.removeAll()
                            } else {
                                selectedIDs = Set(photoGroups.map { $0.id })
                            }
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
                        if isSelectionMode {
                            Button {
                                if !selectedIDs.isEmpty {
                                    showDeleteConfirm = true
                                }
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundColor(selectedIDs.isEmpty ? .gray : .red)
                            }
                            .disabled(selectedIDs.isEmpty)

                            Button("完了") {
                                isSelectionMode = false
                                selectedIDs.removeAll()
                            }
                        } else {
                            Button {
                                isSelectionMode = true
                            } label: {
                                Image(systemName: "checkmark.circle")
                                    .foregroundColor(.primary)
                            }

                            PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                                Image(systemName: "photo.on.rectangle.angled")
                                    .foregroundColor(.primary)
                            }

                            Button {
                                loadPhotosFromServer()
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .foregroundColor(.primary)
                            }
                        }
                    }
                }
            }
            .alert("削除確認", isPresented: $showDeleteConfirm) {
                Button("削除 (\(selectedIDs.count)枚)", role: .destructive) {
                    deleteSelectedPhotos()
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("\(selectedIDs.count)枚の写真を削除しますか？この操作は取り消せません。")
            }
            .onAppear {
                if !hasLoadedOnce {
                    loadPhotosFromServer()
                    hasLoadedOnce = true
                }
            }
            .fullScreenCover(item: $selectedGroup) { group in
                PhotoDetailView(photoGroup: group)
                    .environment(\.managedObjectContext, viewContext)
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
                    .environment(\.managedObjectContext, viewContext)
            }
            // TODO: HDRComposerViewをプロジェクトに追加後に有効化
            // .sheet(isPresented: $showHDRComposer) {
            //     HDRComposerView()
            // }
            .alert("結果", isPresented: $showActionAlert) {
                Button("OK") {
                    actionMessage = nil
                }
            } message: {
                Text(actionMessage ?? "")
            }
        }
    }

    private struct ImportedImageWrapper: Identifiable {
        let id = UUID()
        let image: UIImage
    }

    // MARK: - Subviews

    private var backgroundGradient: some View {
        ZStack {
            MinimalTheme.Background.primary
            LinearGradient(
                colors: [
                    Color.blue.opacity(0.08),
                    Color.teal.opacity(0.06),
                    Color.clear,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            if !connectionMonitor.isConnected {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 60))
                    .foregroundColor(.orange.opacity(0.5))
                Text("Pi への接続を確認中")
                    .font(MinimalTypography.headlineMedium)
                    .foregroundColor(MinimalTheme.Text.secondary)
                Text("PiCamera の Wi-Fi に接続している場合は、上部の更新ボタンを押してください")
                    .font(MinimalTypography.caption)
                    .foregroundColor(MinimalTheme.Text.tertiary)
                    .multilineTextAlignment(.center)
            } else {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 60))
                    .foregroundColor(MinimalTheme.Text.tertiary)
                Text("写真がありません")
                    .font(MinimalTypography.headlineMedium)
                    .foregroundColor(MinimalTheme.Text.secondary)
                Text("光を検知すると自動的に撮影されます")
                    .font(MinimalTypography.caption)
                    .foregroundColor(MinimalTheme.Text.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
        .minimalCard()
        .padding(.horizontal, 24)
    }

    private var galleryColumnCount: Int {
        horizontalSizeClass == .regular ? 3 : 2
    }

    /// LazyVGrid は列幅を子へ提案する。`containerRelativeFrame` を併用すると全幅基準で幅が膨らみ中央で重なるため使わない。
    private var galleryColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: galleryColumnCount)
    }

    private var photoGrid: some View {
        ScrollView {
            LazyVGrid(columns: galleryColumns, spacing: 12) {
                ForEach(photoGroups) { group in
                    ZStack(alignment: .topLeading) {
                        PhotoCell(group: group, serverIP: serverIP)
                            .frame(minWidth: 0, maxWidth: .infinity)
                            .onTapGesture {
                                if isSelectionMode {
                                    if selectedIDs.contains(group.id) {
                                        selectedIDs.remove(group.id)
                                    } else {
                                        selectedIDs.insert(group.id)
                                    }
                                } else {
                                    selectedGroup = group
                                }
                            }
                            .opacity(isSelectionMode && !selectedIDs.contains(group.id) ? 0.5 : 1.0)

                        if isSelectionMode {
                            Image(systemName: selectedIDs.contains(group.id) ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 24))
                                .foregroundStyle(selectedIDs.contains(group.id) ? Color.blue : Color.white)
                                .shadow(radius: 2)
                                .padding(8)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private func deleteSelectedPhotos() {
        let filenames = Array(selectedIDs)
        isLoading = true
        Task {
            do {
                let result = try await api.deletePhotos(filenames: filenames)
                await MainActor.run {
                    selectedIDs.removeAll()
                    isSelectionMode = false
                    loadPhotosFromServer()
                    let count = result.deleted.count
                    actionMessage = "\(count)枚を削除しました"
                    showActionAlert = true
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    actionMessage = "削除失敗: \(error.localizedDescription)"
                    showActionAlert = true
                }
            }
        }
    }

    // MARK: - Data Loading

    private func loadPhotosFromServer() {
        isLoading = true
        Task {
            do {
                let fetchedPhotos = try await api.fetchPhotos()
                await MainActor.run {
                    syncPhotoGroups(serverPhotos: fetchedPhotos)
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    actionMessage = "サーバーからの読み込みに失敗: \(error.localizedDescription)"
                    showActionAlert = true
                }
            }
        }
    }

    /// サーバーの写真一覧とローカルのPhotoGroupを同期
    private func syncPhotoGroups(serverPhotos: [String]) {
        guard !serverPhotos.isEmpty else { return }

        for filename in serverPhotos {
            // 既存のPhotoGroupを探す
            let fetchRequest: NSFetchRequest<PhotoGroup> = PhotoGroup.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "id == %@", filename)

            if (try? viewContext.fetch(fetchRequest).first) != nil {
                // 既存のグループは何もしない
                continue
            }

            // 新しいPhotoGroupを作成
            let group = PhotoGroup(context: viewContext)
            group.id = filename

            // オリジナルバージョンを作成（画像データは後で読み込み）
            let originalVersion = PhotoVersion(context: viewContext)
            originalVersion.id = UUID()
            originalVersion.originalPhotoID = filename
            originalVersion.versionNumber = 0
            originalVersion.isOriginal = true
            originalVersion.createdAt = Date()
            originalVersion.updatedAt = Date()
            originalVersion.userRating = 0
            originalVersion.group = group

            group.latestVersion = originalVersion
            group.addToVersions(originalVersion)
        }

        // 削除されたサーバー写真に対応するPhotoGroupを削除
        let allGroups = try? viewContext.fetch(PhotoGroup.fetchRequest())
        for group in allGroups ?? [] {
            if serverPhotos.contains(group.id) { continue }
            // 編集版があるグループはサーバー未登録でも保持
            let versions = group.versions as? Set<PhotoVersion> ?? []
            let hasEdits = versions.contains { !$0.isOriginal }
            if hasEdits { continue }
            viewContext.delete(group)
        }

        try? viewContext.save()
    }
}

// MARK: - PhotoCell

struct PhotoCell: View {
    @ObservedObject var group: PhotoGroup
    var serverIP: String
    @State private var thumbnailImage: UIImage?
    @State private var isLoading = false
    @State private var thumbnailFailed = false

    var body: some View {
        // グリッドから渡される列幅をそのまま一辺にした正方形（LazyVGrid と整合）
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                ZStack(alignment: .bottomTrailing) {
                    thumbnailLayer
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()

                    if let badge = group.latestVersion?.versionBadge {
                        HStack(spacing: 4) {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 10))
                            Text(badge)
                                .font(MinimalTypography.labelSmall)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.6))
                        .clipShape(Capsule())
                        .padding(8)
                    }
                }
                .background(MinimalTheme.Background.surface)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .onAppear {
                loadThumbnail()
            }
    }

    @ViewBuilder
    private var thumbnailLayer: some View {
        if let image = thumbnailImage {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else if isLoading {
            Rectangle()
                .fill(MinimalTheme.Background.variant)
                .overlay { ProgressView() }
        } else if thumbnailFailed {
            Rectangle()
                .fill(MinimalTheme.Background.variant)
                .overlay {
                    VStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                        Text("再試行")
                            .font(.caption2)
                    }
                    .foregroundStyle(MinimalTheme.Text.secondary)
                }
                .onTapGesture { loadFromServer(force: true) }
        } else {
            Rectangle()
                .fill(MinimalTheme.Background.variant)
                .overlay {
                    Image(systemName: "photo")
                        .font(.largeTitle)
                        .foregroundStyle(MinimalTheme.Text.tertiary)
                }
        }
    }

    private func isRenderable(_ image: UIImage) -> Bool {
        image.size.width > 8 && image.size.height > 8
    }

    private func loadThumbnail() {
        if let thumbnail = group.latestVersion?.thumbnail, isRenderable(thumbnail) {
            thumbnailImage = thumbnail
            return
        }
        if let image = group.latestVersion?.image, isRenderable(image) {
            thumbnailImage = image.preparingThumbnail(of: CGSize(width: 300, height: 300))
            return
        }
        loadFromServer()
    }

    private func loadFromServer(force: Bool = false) {
        let filename = group.id
        if force { thumbnailFailed = false }
        isLoading = true
        Task {
            let api = SimpleCameraAPI(baseURL: "http://\(serverIP):8001")
            if let image = try? await api.downloadPhoto(filename: filename, thumbnail: true, maxDimension: 300),
               isRenderable(image) {
                await MainActor.run {
                    thumbnailImage = image
                    isLoading = false
                    thumbnailFailed = false
                    // Core Data にサムネイルをキャッシュ（次回オフラインでも表示可能）
                    if let version = group.latestVersion,
                       let data = image.jpegData(compressionQuality: 0.7) {
                        version.thumbnailData = data
                        try? group.managedObjectContext?.save()
                    }
                }
            } else {
                await MainActor.run {
                    isLoading = false
                    thumbnailFailed = true
                }
            }
        }
    }
}

// MARK: - Preview

struct UnifiedGalleryView_Previews: PreviewProvider {
    static var previews: some View {
        UnifiedGalleryView()
            .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
    }
}
