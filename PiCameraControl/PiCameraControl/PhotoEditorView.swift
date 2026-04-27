import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import CoreData

#if canImport(UIKit)
import UIKit
#endif

// MARK: - PhotoEditorSettings

struct PhotoEditorSettings: Codable, Hashable {
    // LUT設定
    var lutStyleName: String
    var lutIntensity: Double

    // 露出・トーン調整（SmartAutoEditEngine が使用）
    var exposureEV: Double
    var contrast: Double
    var saturation: Double
    var vibrance: Double
    var clarity: Double
    var shadowBoost: Double
    var highlightRecovery: Double

    // ホワイトバランス
    var autoWhiteBalance: Bool
    var temperature: Double
    var tint: Double

    // IR補正
    var irAutoCorrect: Bool
    var irCorrectionStrength: Double

    static let `default` = PhotoEditorSettings(
        lutStyleName: "",
        lutIntensity: 1.0,
        exposureEV: 0.0,
        contrast: 1.0,
        saturation: 1.0,
        vibrance: 0.0,
        clarity: 0.0,
        shadowBoost: 0.0,
        highlightRecovery: 0.0,
        autoWhiteBalance: false,
        temperature: 0.0,
        tint: 0.0,
        irAutoCorrect: false,
        irCorrectionStrength: 0.0
    )
}

// MARK: - PhotoEditorView

struct PhotoEditorView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss

    let originalImage: UIImage
    var photoGroup: PhotoGroup?

    @State private var lutStyleName: String = ""
    @State private var lutIntensity: Double = 1.0
    @State private var previewImage: UIImage?
    @State private var isSaving = false
    @State private var showSaveAlert = false
    @State private var saveMessage = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    // プレビュー
                    previewArea

                    // LUT選択パネル
                    StyleLibraryView(selectedStyleName: $lutStyleName, intensity: $lutIntensity)
                        .frame(maxHeight: 320)
                }
            }
            .navigationTitle("LUT編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                        .foregroundColor(.white)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        save()
                    } label: {
                        if isSaving {
                            ProgressView().tint(.white)
                        } else {
                            Text("保存")
                                .bold()
                        }
                    }
                    .foregroundColor(.white)
                    .disabled(isSaving)
                }
            }
            .onChange(of: lutStyleName) { _ in updatePreview() }
            .onChange(of: lutIntensity) { _ in updatePreview() }
            .onAppear { previewImage = originalImage }
            .alert("保存", isPresented: $showSaveAlert) {
                Button("OK") {
                    if saveMessage.hasPrefix("保存しました") { dismiss() }
                }
            } message: {
                Text(saveMessage)
            }
        }
    }

    // MARK: - Preview

    private var previewArea: some View {
        ZStack {
            Color.black
            if let img = previewImage {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - LUT apply

    private func applyLUT(to image: UIImage, styleName: String, intensity: Double) -> UIImage {
        guard !styleName.isEmpty,
              let lut = LUTEngine.shared.load(named: styleName),
              let ciImage = CIImage(image: image) else { return image }
        let output = LUTEngine.apply(ciImage, data: lut.data, size: lut.size, intensity: intensity)
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        guard let cg = ctx.createCGImage(output, from: output.extent) else { return image }
        return UIImage(cgImage: cg, scale: image.scale, orientation: image.imageOrientation)
    }

    private func updatePreview() {
        let base = originalImage
        let style = lutStyleName
        let intensity = lutIntensity
        Task.detached(priority: .userInitiated) {
            let result = await Task.detached(priority: .userInitiated) {
                self.applyLUT(to: base, styleName: style, intensity: intensity)
            }.value
            await MainActor.run { previewImage = result }
        }
    }

    // MARK: - Save

    private func save() {
        isSaving = true
        var settings = PhotoEditorSettings.default
        settings.lutStyleName = lutStyleName
        settings.lutIntensity = lutIntensity
        let rendered = applyLUT(to: originalImage, styleName: lutStyleName, intensity: lutIntensity)

        if let group = photoGroup {
            saveToGroup(group, image: rendered, settings: settings)
        } else {
            saveToCameraRoll(image: rendered)
        }
    }

    private func saveToGroup(_ group: PhotoGroup, image: UIImage, settings: PhotoEditorSettings) {
        Task.detached(priority: .userInitiated) {
            guard let jpeg = image.jpegData(compressionQuality: 0.92) else {
                await MainActor.run {
                    isSaving = false
                    saveMessage = "画像の変換に失敗しました"
                    showSaveAlert = true
                }
                return
            }

            let thumbSize = CGSize(width: 300, height: 300)
            let renderer = UIGraphicsImageRenderer(size: thumbSize)
            let thumb = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: thumbSize)) }
            let thumbData = thumb.jpegData(compressionQuality: 0.8)

            let settingsJSON = (try? JSONEncoder().encode(settings)).flatMap { String(data: $0, encoding: .utf8) } ?? ""

            await MainActor.run {
                let v = PhotoVersion(context: viewContext)
                v.id = UUID()
                v.originalPhotoID = group.id
                v.versionNumber = Int32(group.nextVersionNumber())
                v.imageData = jpeg
                v.thumbnailData = thumbData
                v.isOriginal = false
                v.settingsJSON = settingsJSON
                v.createdAt = Date()
                v.updatedAt = Date()
                v.userRating = 0
                group.addToVersions(v)
                group.latestVersion = v

                do {
                    try viewContext.save()
                    isSaving = false
                    saveMessage = "保存しました"
                    showSaveAlert = true
                } catch {
                    isSaving = false
                    saveMessage = "保存失敗: \(error.localizedDescription)"
                    showSaveAlert = true
                }
            }
        }
    }

    private func saveToCameraRoll(image: UIImage) {
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        isSaving = false
        saveMessage = "カメラロールに保存しました"
        showSaveAlert = true
    }
}

// MARK: - Preview

struct PhotoEditorView_Previews: PreviewProvider {
    static var previews: some View {
        let context = PersistenceController.preview.container.viewContext
        let group = PhotoGroup(context: context)
        group.id = "sample.jpg"
        return PhotoEditorView(originalImage: UIImage(systemName: "photo") ?? UIImage(), photoGroup: group)
            .environment(\.managedObjectContext, context)
    }
}
