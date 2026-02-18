import SwiftUI
import PhotosUI
import CoreData

#if canImport(UIKit)
import UIKit
#endif

struct HDRComposerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext

    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var sourceImages: [UIImage] = []
    @State private var settings: HDRCompositionSettings = .default
    @State private var resultImage: UIImage?

    @State private var isProcessing: Bool = false
    @State private var isExporting: Bool = false
    @State private var isSavingToApp: Bool = false
    @State private var showResultAlert: Bool = false
    @State private var resultMessage: String = ""
    @State private var showRatingDialog: Bool = false

    @State private var imageWriteCoordinator: ImageWriteCoordinator?

    private let processor = HDRProcessor()

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    previewArea
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    controlsArea
                }

                if isProcessing || isExporting || isSavingToApp {
                    ProgressView()
                        .scaleEffect(1.2)
                        .padding(22)
                        .background(Color(.systemGray5).opacity(0.9))
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                }
            }
            .navigationTitle("HDR合成")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("閉じる") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 14) {
                        if resultImage != nil {
                            Button {
                                saveToAppStorage()
                            } label: {
                                Image(systemName: "internaldrive")
                            }
                            .disabled(isSavingToApp)

                            Button {
                                exportToPhotoLibrary()
                            } label: {
                                Image(systemName: "square.and.arrow.down")
                            }
                            .disabled(isExporting)
                        }
                    }
                }
            }
        }
        .alert("結果", isPresented: $showResultAlert) {
            Button("OK") {
                resultMessage = ""
            }
        } message: {
            Text(resultMessage)
        }
        .alert("この編集を評価", isPresented: $showRatingDialog) {
            ForEach(1...5, id: \.self) { rating in
                Button("\(rating)星") {
                    confirmSaveWithRating(rating)
                }
            }
            Button("キャンセル", role: .cancel) {
                isSavingToApp = false
            }
        } message: {
            Text("HDR合成の品質を評価してください（1-5星）")
        }
    }

    private var previewArea: some View {
        Group {
            if let result = resultImage {
                // 合成結果表示
                Image(uiImage: result)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(.horizontal, 10)
            } else if !sourceImages.isEmpty {
                // 選択した画像のプレビュー
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(sourceImages.indices, id: \.self) { index in
                            VStack(spacing: 4) {
                                Image(uiImage: sourceImages[index])
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(height: 200)
                                    .cornerRadius(8)

                                Text("画像 \(index + 1)")
                                    .font(.caption2)
                                    .foregroundColor(.gray)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            } else {
                // 画像未選択
                VStack(spacing: 16) {
                    Image(systemName: "photo.stack")
                        .font(.system(size: 64))
                        .foregroundColor(.gray)

                    Text("2〜5枚の露出違い画像を選択")
                        .font(.headline)
                        .foregroundColor(.white.opacity(0.9))

                    Text("暗い画像、標準、明るい画像を\n選択することでHDR合成できます")
                        .font(.caption)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)

                    PhotosPicker(
                        selection: $selectedPhotoItems,
                        maxSelectionCount: 5,
                        matching: .images
                    ) {
                        HStack {
                            Image(systemName: "photo.on.rectangle.angled")
                            Text("写真を選択")
                        }
                        .font(.headline)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(Color.red.opacity(0.9))
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }
                }
            }
        }
    }

    private var controlsArea: some View {
        VStack(spacing: 12) {
            if !sourceImages.isEmpty {
                // 画像選択済み: 設定コントロール表示
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // トーンマッピング方法
                        VStack(alignment: .leading, spacing: 8) {
                            Text("トーンマッピング")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.secondary)

                            Picker("トーンマッピング", selection: $settings.tonemapMethod) {
                                ForEach(HDRCompositionSettings.TonemapMethod.allCases, id: \.self) { method in
                                    Text(method.description).tag(method)
                                }
                            }
                            .pickerStyle(.segmented)
                        }

                        Divider()

                        // オプション
                        Toggle("ゴースト除去", isOn: $settings.ghostRemoval)
                            .toggleStyle(SwitchToggleStyle(tint: .blue))

                        Toggle("位置合わせ", isOn: $settings.alignImages)
                            .toggleStyle(SwitchToggleStyle(tint: .blue))

                        Divider()

                        // 後処理
                        sliderRow(title: "露出", value: $settings.exposure, range: -2...2, step: 0.05)
                        sliderRow(title: "コントラスト", value: $settings.contrast, range: 0.5...1.6, step: 0.02)

                        Divider()

                        // 合成ボタン
                        if resultImage == nil {
                            Button {
                                composeHDR()
                            } label: {
                                HStack {
                                    Image(systemName: "wand.and.stars")
                                    Text("HDR合成実行")
                                }
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color.red.opacity(0.9))
                                .foregroundColor(.white)
                                .cornerRadius(12)
                            }
                            .disabled(sourceImages.count < 2 || isProcessing)
                        } else {
                            HStack(spacing: 12) {
                                Button {
                                    resetComposition()
                                } label: {
                                    HStack {
                                        Image(systemName: "arrow.counterclockwise")
                                        Text("リセット")
                                    }
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                                    .background(Color.gray.opacity(0.3))
                                    .foregroundColor(.white)
                                    .cornerRadius(12)
                                }

                                Button {
                                    composeHDR()
                                } label: {
                                    HStack {
                                        Image(systemName: "arrow.clockwise")
                                        Text("再合成")
                                    }
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                                    .background(Color.red.opacity(0.9))
                                    .foregroundColor(.white)
                                    .cornerRadius(12)
                                }
                                .disabled(isProcessing)
                            }
                        }

                        // 画像情報
                        VStack(alignment: .leading, spacing: 4) {
                            Text("📊 選択画像: \(sourceImages.count)枚")
                                .font(.caption2)
                                .foregroundColor(.gray)

                            if sourceImages.count < 2 {
                                Text("⚠️ 2枚以上選択してください")
                                    .font(.caption2)
                                    .foregroundColor(.red.opacity(0.8))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                // 画像未選択: 選択ボタン表示
                PhotosPicker(
                    selection: $selectedPhotoItems,
                    maxSelectionCount: 5,
                    matching: .images
                ) {
                    HStack {
                        Image(systemName: "photo.on.rectangle.angled")
                        Text("写真を選択（2〜5枚）")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.red.opacity(0.9))
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
            }
        }
        .padding(16)
        .background(Color(.systemBackground).opacity(0.95))
        .onChange(of: selectedPhotoItems) { _, newItems in
            loadSelectedImages(newItems)
        }
    }

    private func sliderRow(title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.caption.weight(.medium))
                    .foregroundColor(.secondary)
            }
            Slider(value: value, in: range, step: step)
        }
    }

    private func loadSelectedImages(_ items: [PhotosPickerItem]) {
        sourceImages = []
        resultImage = nil

        Task {
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    await MainActor.run {
                        sourceImages.append(image)
                    }
                }
            }
        }
    }

    private func composeHDR() {
        guard sourceImages.count >= 2 else {
            resultMessage = "2枚以上の画像を選択してください"
            showResultAlert = true
            return
        }

        isProcessing = true

        Task {
            do {
                let result = try await processor.composeHDR(
                    images: sourceImages,
                    settings: settings
                )

                await MainActor.run {
                    resultImage = result
                    isProcessing = false
                    resultMessage = "HDR合成が完了しました"
                    showResultAlert = true
                }
            } catch {
                await MainActor.run {
                    isProcessing = false
                    resultMessage = "合成失敗: \(error.localizedDescription)"
                    showResultAlert = true
                }
            }
        }
    }

    private func resetComposition() {
        resultImage = nil
        settings = .default
    }

    private func saveToAppStorage() {
        guard resultImage != nil else { return }
        if isSavingToApp { return }
        isSavingToApp = true
        showRatingDialog = true
    }

    private func confirmSaveWithRating(_ rating: Int) {
        guard let result = resultImage else {
            isSavingToApp = false
            return
        }

        Task {
            await MainActor.run {
                // 画像をJPEGエンコード（85%品質）
                guard let imageData = result.jpegData(compressionQuality: 0.85) else {
                    isSavingToApp = false
                    resultMessage = "画像のエンコードに失敗しました"
                    showResultAlert = true
                    return
                }

                // サムネイル生成（300x300）
                let thumbnailSize = CGSize(width: 300, height: 300)
                let thumbnail = result.preparingThumbnail(of: thumbnailSize)
                let thumbnailData = thumbnail?.jpegData(compressionQuality: 0.7)

                // 設定をJSONエンコード（HDR設定として保存）
                guard let settingsData = try? JSONEncoder().encode(settings),
                      let settingsJSON = String(data: settingsData, encoding: .utf8) else {
                    isSavingToApp = false
                    resultMessage = "設定のエンコードに失敗しました"
                    showResultAlert = true
                    return
                }

                // Core Dataに保存（EditedPhotoとして）
                let photo = EditedPhoto(context: viewContext)
                photo.id = UUID()
                photo.createdAt = Date()
                photo.imageData = imageData
                photo.thumbnailData = thumbnailData
                photo.settingsJSON = settingsJSON
                photo.userRating = Int16(rating)
                photo.originalFilename = "HDR_\(Date().timeIntervalSince1970).jpg"

                do {
                    try viewContext.save()
                    isSavingToApp = false
                    resultMessage = "HDR画像をアプリ内に保存しました（\(rating)星）"
                    showResultAlert = true
                } catch {
                    isSavingToApp = false
                    resultMessage = "保存に失敗しました: \(error.localizedDescription)"
                    showResultAlert = true
                }
            }
        }
    }

    private func exportToPhotoLibrary() {
        guard let result = resultImage else { return }

        if isExporting { return }
        isExporting = true

        let coordinator = ImageWriteCoordinator { error in
            DispatchQueue.main.async {
                isExporting = false
                if let error {
                    resultMessage = error.localizedDescription
                } else {
                    resultMessage = "写真に保存しました"
                }
                showResultAlert = true
                imageWriteCoordinator = nil
            }
        }
        imageWriteCoordinator = coordinator
        UIImageWriteToSavedPhotosAlbum(
            result,
            coordinator,
            #selector(ImageWriteCoordinator.image(_:didFinishSavingWithError:contextInfo:)),
            nil
        )
    }
}
