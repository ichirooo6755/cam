import SwiftUI
import CoreData
import PhotosUI

#if canImport(UIKit)
import UIKit
#endif

/// 統合ギャラリービュー（サーバー写真 + 編集版を統合管理）
struct UnifiedGalleryView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @AppStorage("serverIP") private var serverIP: String = "192.168.4.1"

    // PhotoGroup一覧
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \PhotoGroup.latestVersion?.updatedAt, ascending: false)],
        animation: .default
    )
    private var photoGroups: FetchedResults<PhotoGroup>

    @State private var isLoading = false
    @State private var selectedGroup: PhotoGroup?
    @State private var showPhotoDetail = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var importedImage: UIImage?
    @State private var actionMessage: String?
    @State private var showActionAlert = false
    @State private var hasLoadedOnce = false
    // @State private var showHDRComposer = false // TODO: HDRComposerView追加後に有効化

    private var api: SimpleCameraAPI {
        SimpleCameraAPI(baseURL: "http://\(serverIP):8001")
    }

    var body: some View {
        NavigationView {
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
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
                        // TODO: HDRComposerViewをプロジェクトに追加後に有効化
                        // Button {
                        //     showHDRComposer = true
                        // } label: {
                        //     Image(systemName: "photo.stack")
                        //         .foregroundColor(.primary)
                        // }

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
            .onAppear {
                if !hasLoadedOnce {
                    loadPhotosFromServer()
                    hasLoadedOnce = true
                }
            }
            .fullScreenCover(isPresented: $showPhotoDetail) {
                if let group = selectedGroup {
                    PhotoDetailView(photoGroup: group)
                        .environment(\.managedObjectContext, viewContext)
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
        .padding()
        .minimalCard()
        .padding(.horizontal, 24)
    }

    private var photoGrid: some View {
        ScrollView {
            LazyVGrid(columns: [
                GridItem(.adaptive(minimum: 150), spacing: 12)
            ], spacing: 12) {
                ForEach(photoGroups) { group in
                    PhotoCell(group: group, serverIP: serverIP)
                        .onTapGesture {
                            selectedGroup = group
                            showPhotoDetail = true
                        }
                }
            }
            .padding()
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
            if !serverPhotos.contains(group.id) {
                // サーバーから削除されている場合、ローカルも削除
                viewContext.delete(group)
            }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // サムネイル
            ZStack(alignment: .bottomTrailing) {
                if let image = thumbnailImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(height: 150)
                        .clipped()
                } else if isLoading {
                    Rectangle()
                        .fill(MinimalTheme.Background.variant)
                        .frame(height: 150)
                        .overlay(
                            ProgressView()
                        )
                } else {
                    Rectangle()
                        .fill(MinimalTheme.Background.variant)
                        .frame(height: 150)
                        .overlay(
                            Image(systemName: "photo")
                                .font(.largeTitle)
                                .foregroundColor(MinimalTheme.Text.tertiary)
                        )
                }

                // バージョンバッジ
                if let badge = group.latestVersion?.versionBadge {
                    HStack(spacing: 4) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 10))
                        Text(badge)
                            .font(MinimalTypography.labelSmall)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.6))
                    .clipShape(Capsule())
                    .padding(8)
                }
            }
        }
        .background(MinimalTheme.Background.surface)
        .cornerRadius(12)
        .shadow(
            color: Color.black.opacity(0.08),
            radius: 4,
            y: 2
        )
        .onAppear {
            loadThumbnail()
        }
    }

    private func loadThumbnail() {
        // latestVersionのサムネイルを読み込み
        if let thumbnail = group.latestVersion?.thumbnail {
            thumbnailImage = thumbnail
        } else if let thumbnail = group.latestVersion?.image {
            // サムネイルがない場合は画像をリサイズ
            thumbnailImage = thumbnail.preparingThumbnail(of: CGSize(width: 300, height: 300))
        } else {
            // サーバーから読み込み
            loadFromServer()
        }
    }

    private func loadFromServer() {
        let filename = group.id
        isLoading = true
        Task {
            let api = SimpleCameraAPI(baseURL: "http://\(serverIP):8001")
            if let image = try? await api.downloadPhoto(filename: filename, thumbnail: true, maxDimension: 300) {
                await MainActor.run {
                    thumbnailImage = image
                    isLoading = false
                }
            } else {
                await MainActor.run {
                    isLoading = false
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
