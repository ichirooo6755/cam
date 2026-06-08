import SwiftUI
import CoreData

#if canImport(UIKit)
import UIKit
#endif

/// 写真詳細ビュー（バージョンカルーセル付き）
struct PhotoDetailView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss
    @AppStorage("serverIP") private var serverIP: String = "192.168.4.1"

    @ObservedObject var photoGroup: PhotoGroup

    @State private var currentVersionIndex: Int = 0
    @State private var showDeleteConfirmation = false
    @State private var deleteMode: DeleteMode?
    @State private var actionMessage: String?
    @State private var showActionAlert = false
    @State private var showEditor = false
    @State private var showShareSheet = false
    @State private var imageToShare: UIImage?
    @State private var isLoadingFullImage = false
    @State private var fullImage: UIImage?
    @State private var loadError: String?
    @State private var useThumbnailFallback = false

    private var api: SimpleCameraAPI {
        SimpleCameraAPI(baseURL: "http://\(serverIP):8001")
    }

    private var versions: [PhotoVersion] {
        photoGroup.sortedVersions
    }

    private var currentVersion: PhotoVersion? {
        guard currentVersionIndex < versions.count else { return nil }
        return versions[currentVersionIndex]
    }

    // RAWファイル（.dng）か判定
    private var isRawPhoto: Bool {
        photoGroup.id.lowercased().hasSuffix(".dng")
    }

    private var displayImage: UIImage? {
        if let version = currentVersion, !version.isOriginal {
            if let data = version.imageData, let img = UIImage(data: data) { return img }
            if let img = version.image { return img }
        }
        return fullImage ?? currentVersion?.image
    }

    enum DeleteMode {
        case versionOnly
        case completeFromServer
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // カスタムツールバー
                HStack {
                    Button("閉じる") { dismiss() }
                        .foregroundColor(.white)

                    Spacer()

                    Text("\(currentVersionIndex + 1) / \(versions.count)")
                        .font(MinimalTypography.labelMedium)
                        .foregroundColor(.white.opacity(0.7))

                    Spacer()

                    Menu {
                        Button {
                            if displayImage != nil {
                                showEditor = true
                            }
                        } label: {
                            Label("編集（LUT）", systemImage: "camera.filters")
                        }

                        Button {
                            if let image = displayImage {
                                imageToShare = image
                                showShareSheet = true
                            }
                        } label: {
                            Label("共有", systemImage: "square.and.arrow.up")
                        }

                        Divider()

                        if let version = currentVersion, !version.isOriginal {
                            Button(role: .destructive) {
                                deleteMode = .versionOnly
                                showDeleteConfirmation = true
                            } label: {
                                Label("この編集版を削除", systemImage: "trash")
                            }
                        }

                        Button(role: .destructive) {
                            deleteMode = .completeFromServer
                            showDeleteConfirmation = true
                        } label: {
                            Label("サーバーから完全削除", systemImage: "trash.fill")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.title3)
                            .foregroundColor(.white)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 4)

                // メイン画像
                imageCarousel

                // バージョンインジケーター
                versionIndicator
                    .padding(.vertical, MinimalSpacing.sm)

                // メタデータ＆評価
                metadataSection
                    .padding(.vertical, MinimalSpacing.md)
                    .background(MinimalTheme.Background.surface)
            }
        }
        .task(id: currentVersionIndex) { loadImageForCurrentVersion() }
        .fullScreenCover(isPresented: $showEditor) {
            if let image = displayImage {
                PhotoEditorView(originalImage: image, photoGroup: photoGroup)
                    .environment(\.managedObjectContext, viewContext)
            }
        }
        .sheet(isPresented: $showShareSheet) {
            if let image = imageToShare {
                ShareSheet(items: [image])
            }
        }
        .alert("写真を削除", isPresented: $showDeleteConfirmation) {
            Button("削除", role: .destructive) { performDelete() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            if deleteMode == .versionOnly {
                Text("この編集版を削除します。オリジナルは保持されます。")
            } else {
                Text("⚠️ サーバーから完全に削除されます。全ての編集版も失われます。復元できません。")
            }
        }
        .alert("結果", isPresented: $showActionAlert) {
            Button("OK") { actionMessage = nil }
        } message: {
            Text(actionMessage ?? "")
        }
    }

    // MARK: - Subviews

    private var imageCarousel: some View {
        TabView(selection: $currentVersionIndex) {
            ForEach(Array(versions.enumerated()), id: \.element.id) { index, version in
                versionImagePage(version: version)
                    .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: currentVersionIndex) { _, _ in
            loadError = nil
            useThumbnailFallback = false
        }
    }

    @ViewBuilder
    private func versionImagePage(version: PhotoVersion) -> some View {
        ZStack {
            Color.black
            if indexMatchesDisplay(version: version), let image = displayImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let img = versionImage(version) {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isLoadingFullImage {
                VStack(spacing: 12) {
                    ProgressView().scaleEffect(1.4).tint(.white)
                    Text(useThumbnailFallback ? "サムネイル読込中..." : "読み込み中...")
                        .font(MinimalTypography.caption)
                        .foregroundColor(.white.opacity(0.7))
                }
            } else if let loadError {
                VStack(spacing: 16) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 40))
                        .foregroundColor(.orange)
                    Text(loadError)
                        .font(MinimalTypography.caption)
                        .foregroundColor(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    HStack(spacing: 12) {
                        Button("再試行") { loadImageForCurrentVersion(force: true) }
                            .buttonStyle(.borderedProminent)
                        if !useThumbnailFallback {
                            Button("サムネイル") {
                                useThumbnailFallback = true
                                loadImageForCurrentVersion(force: true)
                            }
                            .buttonStyle(.bordered)
                            .tint(.white)
                        }
                    }
                }
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 48))
                    .foregroundColor(.white.opacity(0.3))
            }
        }
    }

    private func indexMatchesDisplay(version: PhotoVersion) -> Bool {
        guard let current = currentVersion else { return false }
        return version.id == current.id
    }

    private func versionImage(_ version: PhotoVersion) -> UIImage? {
        if let data = version.imageData, let img = UIImage(data: data) { return img }
        return version.image
    }

    private var versionIndicator: some View {
        HStack(spacing: 6) {
            ForEach(Array(versions.enumerated()), id: \.element.id) { index, version in
                Button {
                    withAnimation { currentVersionIndex = index }
                } label: {
                    VStack(spacing: 2) {
                        Circle()
                            .fill(index == currentVersionIndex ? Color.white : Color.white.opacity(0.3))
                            .frame(width: 6, height: 6)
                        if index == currentVersionIndex {
                            Text(version.displayName)
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.8))
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var metadataSection: some View {
        VStack(spacing: MinimalSpacing.md) {
            // バージョン名
            HStack(spacing: 8) {
                Text(currentVersion?.displayName ?? "")
                    .font(MinimalTypography.headlineMedium)
                    .foregroundColor(MinimalTheme.Text.primary)

                // RAWバッジ
                if isRawPhoto, currentVersion?.isOriginal == true {
                    Text("RAW")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15))
                        .cornerRadius(4)
                }
            }

            if let version = currentVersion {
                if version.isOriginal {
                    if let metadata = photoGroup.serverMetadata {
                        metadataRow(metadata: metadata)
                    }
                    // RAWオリジナルの注記
                    if isRawPhoto {
                        Text("RAWファイルはサーバーに保持されます。編集すると新しいバージョンとして保存されます。")
                            .font(MinimalTypography.caption)
                            .foregroundColor(MinimalTheme.Text.tertiary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, MinimalSpacing.md)
                    }
                } else {
                    if let settings = version.settings {
                        editSettingsSummary(settings: settings)
                    }
                }

                ratingView(version: version)

                Text(version.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(MinimalTypography.caption)
                    .foregroundColor(MinimalTheme.Text.tertiary)
            }
        }
        .padding(.horizontal, MinimalSpacing.md)
    }

    private func metadataRow(metadata: PhotoMetadata) -> some View {
        HStack(spacing: 4) {
            if let iso = metadata.iso { Text("ISO \(iso.displayString)") }
            Text("•")
            if let ss = metadata.shutterSpeed { Text(ss.displayString) }
            Text("•")
            if let wb = metadata.whiteBalance { Text(wb.uppercased()) }
        }
        .font(MinimalTypography.captionMono)
        .foregroundColor(MinimalTheme.Text.secondary)
    }

    private func editSettingsSummary(settings: PhotoEditorSettings) -> some View {
        HStack(spacing: MinimalSpacing.sm) {
            if !settings.lutStyleName.isEmpty {
                settingBadge("LUT", settings.lutStyleName)
                settingBadge("強度", "\(Int(settings.lutIntensity * 100))%")
            } else {
                Text("スタイルなし")
                    .font(MinimalTypography.caption)
                    .foregroundColor(MinimalTheme.Text.tertiary)
            }
        }
    }

    private func settingBadge(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(MinimalTypography.labelSmall)
                .foregroundColor(MinimalTheme.Text.tertiary)
            Text(value)
                .font(MinimalTypography.captionMono)
                .foregroundColor(MinimalTheme.Text.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(MinimalTheme.Background.variant)
        .cornerRadius(8)
    }

    private func ratingView(version: PhotoVersion) -> some View {
        HStack(spacing: 4) {
            ForEach(1...5, id: \.self) { index in
                Button {
                    updateRating(version: version, rating: index)
                } label: {
                    Image(systemName: index <= version.userRating ? "star.fill" : "star")
                        .font(.system(size: 18))
                        .foregroundColor(index <= version.userRating ? .yellow : MinimalTheme.Text.tertiary)
                }
            }
        }
    }

    // MARK: - Image Loading

    private func loadImageForCurrentVersion(force: Bool = false) {
        guard let version = currentVersion else { return }

        if !version.isOriginal {
            if versionImage(version) != nil { return }
        } else {
            if !force, fullImage != nil { return }
            if !force, let cached = versionImage(version) {
                fullImage = cached
                return
            }
        }

        let filename = photoGroup.id
        isLoadingFullImage = true
        loadError = nil
        Task {
            do {
                let image: UIImage
                if useThumbnailFallback || isRawPhoto {
                    image = try await api.downloadPhoto(
                        filename: filename, thumbnail: true, maxDimension: 1600)
                } else {
                    image = try await api.downloadPhoto(filename: filename)
                }
                await MainActor.run {
                    if version.isOriginal {
                        fullImage = image
                        if let data = image.jpegData(compressionQuality: 0.9) {
                            version.imageData = data
                            try? viewContext.save()
                        }
                    } else {
                        if let data = image.jpegData(compressionQuality: 0.9) {
                            version.imageData = data
                            try? viewContext.save()
                        }
                    }
                    isLoadingFullImage = false
                    loadError = nil
                }
            } catch {
                await MainActor.run {
                    isLoadingFullImage = false
                    loadError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Actions

    private func updateRating(version: PhotoVersion, rating: Int) {
        version.userRating = Int16(rating)
        version.updatedAt = Date()
        try? viewContext.save()
    }

    private func performDelete() {
        guard let mode = deleteMode else { return }
        switch mode {
        case .versionOnly: deleteVersionOnly()
        case .completeFromServer: deleteCompleteFromServer()
        }
    }

    private func deleteVersionOnly() {
        guard let version = currentVersion, !version.isOriginal else {
            actionMessage = "オリジナルは削除できません"
            showActionAlert = true
            return
        }

        if currentVersionIndex > 0 { currentVersionIndex -= 1 }

        photoGroup.removeFromVersions(version)
        if photoGroup.latestVersion == version {
            photoGroup.latestVersion = photoGroup.sortedVersions.last
        }
        viewContext.delete(version)

        do {
            try viewContext.save()
            actionMessage = "編集版を削除しました"
            showActionAlert = true
        } catch {
            actionMessage = "削除に失敗: \(error.localizedDescription)"
            showActionAlert = true
        }
    }

    private func deleteCompleteFromServer() {
        Task {
            do {
                let result = try await api.deletePhotos(filenames: [photoGroup.id])
                await MainActor.run {
                    if result.deleted.contains(photoGroup.id) {
                        viewContext.delete(photoGroup)
                        do {
                            try viewContext.save()
                            dismiss()
                        } catch {
                            actionMessage = "ローカル削除失敗: \(error.localizedDescription)"
                            showActionAlert = true
                        }
                    } else {
                        actionMessage = "サーバーからの削除に失敗しました"
                        showActionAlert = true
                    }
                }
            } catch {
                await MainActor.run {
                    actionMessage = "削除失敗: \(error.localizedDescription)"
                    showActionAlert = true
                }
            }
        }
    }
}

// MARK: - ShareSheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Preview

struct PhotoDetailView_Previews: PreviewProvider {
    static var previews: some View {
        let context = PersistenceController.preview.container.viewContext
        let group = PhotoGroup(context: context)
        group.id = "sample.jpg"
        let original = PhotoVersion(context: context)
        original.id = UUID()
        original.originalPhotoID = "sample.jpg"
        original.versionNumber = 0
        original.isOriginal = true
        original.createdAt = Date()
        original.updatedAt = Date()
        original.userRating = 4
        group.addToVersions(original)
        group.latestVersion = original
        return PhotoDetailView(photoGroup: group)
            .environment(\.managedObjectContext, context)
    }
}
