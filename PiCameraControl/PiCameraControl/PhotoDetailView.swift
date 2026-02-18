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
                    Button("閉じる") {
                        dismiss()
                    }
                    .foregroundColor(.white)

                    Spacer()

                    Text("\(currentVersionIndex + 1) / \(versions.count)")
                        .font(MinimalTypography.labelMedium)
                        .foregroundColor(.white.opacity(0.7))

                    Spacer()

                    Menu {
                        Button {
                            if fullImage != nil || currentVersion?.image != nil {
                                showEditor = true
                            }
                        } label: {
                            Label("編集", systemImage: "slider.horizontal.3")
                        }

                        Button {
                            if let image = fullImage ?? currentVersion?.image {
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
                                Label("編集版のみ削除", systemImage: "trash")
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
        .task {
            loadOriginalImage()
        }
        .fullScreenCover(isPresented: $showEditor) {
            if let image = fullImage ?? currentVersion?.image {
                PhotoEditorView(originalImage: image)
                    .environment(\.managedObjectContext, viewContext)
            }
        }
        .sheet(isPresented: $showShareSheet) {
            if let image = imageToShare {
                ShareSheet(items: [image])
            }
        }
        .alert("写真を削除", isPresented: $showDeleteConfirmation) {
            Button("削除", role: .destructive) {
                performDelete()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            if deleteMode == .versionOnly {
                Text("この編集版を削除します。オリジナルは保持されます。")
            } else {
                Text("⚠️ サーバーから完全に削除されます。全ての編集版も失われます。復元できません。")
            }
        }
        .alert("結果", isPresented: $showActionAlert) {
            Button("OK") {
                actionMessage = nil
            }
        } message: {
            Text(actionMessage ?? "")
        }
    }

    // MARK: - Subviews

    private var imageCarousel: some View {
        ZStack {
            Color.black
            if let image = fullImage ?? currentVersion?.image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isLoadingFullImage {
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.4)
                        .tint(.white)
                    Text("読み込み中...")
                        .font(MinimalTypography.caption)
                        .foregroundColor(.white.opacity(0.7))
                }
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 48))
                    .foregroundColor(.white.opacity(0.3))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var versionIndicator: some View {
        HStack(spacing: 6) {
            ForEach(Array(versions.enumerated()), id: \.element.id) { index, version in
                Circle()
                    .fill(index == currentVersionIndex ? Color.white : Color.white.opacity(0.3))
                    .frame(width: 6, height: 6)
                    .animation(MinimalAnimation.standardEase, value: currentVersionIndex)
            }
        }
    }

    private var metadataSection: some View {
        VStack(spacing: MinimalSpacing.md) {
            // バージョン名
            Text(currentVersion?.displayName ?? "")
                .font(MinimalTypography.headlineMedium)
                .foregroundColor(MinimalTheme.Text.primary)

            // メタデータ
            if let version = currentVersion {
                if version.isOriginal {
                    // オリジナル: サーバーメタデータ
                    if let metadata = photoGroup.serverMetadata {
                        metadataRow(metadata: metadata)
                    }
                } else {
                    // 編集版: 編集設定のサマリー
                    if let settings = version.settings {
                        editSettingsSummary(settings: settings)
                    }
                }

                // 評価
                ratingView(version: version)

                // 日時
                Text(version.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(MinimalTypography.caption)
                    .foregroundColor(MinimalTheme.Text.tertiary)
            }
        }
        .padding(.horizontal, MinimalSpacing.md)
    }

    private func metadataRow(metadata: PhotoMetadata) -> some View {
        HStack(spacing: 4) {
            if let iso = metadata.iso {
                Text("ISO \(iso.displayString)")
            }
            Text("•")
            if let ss = metadata.shutterSpeed {
                Text(ss.displayString)
            }
            Text("•")
            if let wb = metadata.whiteBalance {
                Text(wb.uppercased())
            }
        }
        .font(MinimalTypography.captionMono)
        .foregroundColor(MinimalTheme.Text.secondary)
    }

    private func editSettingsSummary(settings: PhotoEditorSettings) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: MinimalSpacing.sm) {
                if abs(settings.exposureEV) > 0.01 {
                    settingBadge("露出", String(format: "%+.1f", settings.exposureEV))
                }
                if abs(settings.contrast - 1.0) > 0.01 {
                    settingBadge("コントラスト", String(format: "%.2f", settings.contrast))
                }
                if abs(settings.saturation - 1.0) > 0.01 {
                    settingBadge("彩度", String(format: "%.2f", settings.saturation))
                }
                if abs(settings.temperature) > 0.01 {
                    settingBadge("色温度", String(format: "%.0f", settings.temperature))
                }
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

    private func loadOriginalImage() {
        // 既にロード済み
        if fullImage != nil { return }
        // Core Dataにキャッシュ済み
        if let cached = currentVersion?.image {
            fullImage = cached
            return
        }
        // サーバーからダウンロード
        let filename = photoGroup.id
        isLoadingFullImage = true
        Task {
            do {
                let image = try await api.downloadPhoto(filename: filename)
                await MainActor.run {
                    fullImage = image
                    // Core Dataにキャッシュ
                    if let version = currentVersion,
                       let data = image.jpegData(compressionQuality: 0.9) {
                        version.imageData = data
                        try? viewContext.save()
                    }
                    isLoadingFullImage = false
                }
            } catch {
                await MainActor.run {
                    isLoadingFullImage = false
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
        case .versionOnly:
            deleteVersionOnly()
        case .completeFromServer:
            deleteCompleteFromServer()
        }
    }

    private func deleteVersionOnly() {
        guard let version = currentVersion, !version.isOriginal else {
            actionMessage = "オリジナルは削除できません"
            showActionAlert = true
            return
        }

        // 前のバージョンに移動
        if currentVersionIndex > 0 {
            currentVersionIndex -= 1
        }

        // PhotoGroupから削除
        photoGroup.removeFromVersions(version)

        // latestVersionを更新
        if photoGroup.latestVersion == version {
            photoGroup.latestVersion = photoGroup.sortedVersions.last
        }

        // Core Dataから削除
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
                // サーバーから削除
                let result = try await api.deletePhotos(filenames: [photoGroup.id])

                await MainActor.run {
                    if result.deleted.contains(photoGroup.id) {
                        // ローカルの全バージョンを削除
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

        // サンプルPhotoGroup
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
