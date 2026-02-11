import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

#if canImport(UIKit)
import UIKit
#endif

struct NormalizedRect: Codable, Hashable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    static let full = NormalizedRect(x: 0, y: 0, width: 1, height: 1)

    var isFull: Bool {
        abs(x) < 0.0001 && abs(y) < 0.0001 && abs(width - 1) < 0.0001 && abs(height - 1) < 0.0001
    }
}

struct RadialMaskSettings: Codable, Hashable {
    var enabled: Bool
    var centerX: Double
    var centerY: Double
    var radius: Double
    var feather: Double
    var exposureEV: Double

    static let `default` = RadialMaskSettings(enabled: false, centerX: 0.5, centerY: 0.5, radius: 0.35, feather: 0.6, exposureEV: 0)
}

struct PhotoEditorSettings: Codable, Hashable {
    var exposureEV: Double
    var contrast: Double
    var saturation: Double
    var highlightRecovery: Double
    var shadowBoost: Double
    var temperature: Double
    var monochrome: Double
    var crop: NormalizedRect
    var radialMask: RadialMaskSettings

    static let `default` = PhotoEditorSettings(
        exposureEV: 0,
        contrast: 1,
        saturation: 1,
        highlightRecovery: 0,
        shadowBoost: 0,
        temperature: 0,
        monochrome: 0,
        crop: .full,
        radialMask: .default
    )
}

struct PhotoEditorPreset: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var createdAt: Date
    var settings: PhotoEditorSettings
}

final class ImageWriteCoordinator: NSObject {
    private let completion: (Error?) -> Void

    init(completion: @escaping (Error?) -> Void) {
        self.completion = completion
    }

    @objc func image(_ image: UIImage, didFinishSavingWithError error: Error?, contextInfo: UnsafeRawPointer?) {
        completion(error)
    }
}

private enum PhotoEditorRenderer {
    private static let context = CIContext(options: nil)

    static func render(image: UIImage, settings: PhotoEditorSettings) -> UIImage? {
        let base: CIImage
        if let cgImage = image.cgImage {
            base = CIImage(cgImage: cgImage)
        } else if let ciImage = image.ciImage {
            base = ciImage
        } else if let ciImage = CIImage(image: image) {
            base = ciImage
        } else {
            return nil
        }

        var output = base.oriented(forExifOrientation: image.imageOrientation.exifOrientation)

        output = applyCrop(to: output, crop: settings.crop)

        if abs(settings.exposureEV) > 0.0001 {
            let f = CIFilter.exposureAdjust()
            f.inputImage = output
            f.ev = Float(settings.exposureEV)
            output = f.outputImage ?? output
        }

        if abs(settings.highlightRecovery) > 0.0001 || abs(settings.shadowBoost) > 0.0001 {
            let f = CIFilter.highlightShadowAdjust()
            f.inputImage = output
            f.highlightAmount = Float(clamp(1 - settings.highlightRecovery, 0, 1))
            f.shadowAmount = Float(clamp(settings.shadowBoost, 0, 1))
            output = f.outputImage ?? output
        }

        let effectiveSaturation = settings.saturation * (1 - settings.monochrome)
        if abs(settings.contrast - 1) > 0.0001 || abs(effectiveSaturation - 1) > 0.0001 {
            let f = CIFilter.colorControls()
            f.inputImage = output
            f.contrast = Float(settings.contrast)
            f.saturation = Float(effectiveSaturation)
            output = f.outputImage ?? output
        }

        if abs(settings.temperature) > 0.0001 {
            let f = CIFilter.temperatureAndTint()
            f.inputImage = output
            f.neutral = CIVector(x: 6500, y: 0)
            f.targetNeutral = CIVector(x: 6500 + settings.temperature, y: 0)
            output = f.outputImage ?? output
        }

        output = applyRadialMask(to: output, radial: settings.radialMask)

        let rect = output.extent.integral
        guard let cg = context.createCGImage(output, from: rect) else { return nil }
        return UIImage(cgImage: cg, scale: image.scale, orientation: .up)
    }

    private static func applyCrop(to image: CIImage, crop: NormalizedRect) -> CIImage {
        guard !crop.isFull else { return image }
        let extent = image.extent
        let w = extent.width * crop.width
        let h = extent.height * crop.height
        let x = extent.origin.x + extent.width * crop.x
        let y = extent.origin.y + extent.height * (1 - crop.y - crop.height)
        let rect = CGRect(x: x, y: y, width: w, height: h).integral
        return image.cropped(to: rect)
    }

    private static func applyRadialMask(to image: CIImage, radial: RadialMaskSettings) -> CIImage {
        guard radial.enabled, abs(radial.exposureEV) > 0.0001 else { return image }

        let extent = image.extent
        let center = CGPoint(
            x: extent.origin.x + extent.width * radial.centerX,
            y: extent.origin.y + extent.height * (1 - radial.centerY)
        )

        let minDim = min(extent.width, extent.height)
        let outer = CGFloat(clamp(radial.radius, 0.02, 2)) * minDim
        let inner = max(0, outer * CGFloat(clamp(1 - radial.feather, 0, 1)))

        let gradient = CIFilter.radialGradient()
        gradient.center = center
        gradient.radius0 = Float(inner)
        gradient.radius1 = Float(outer)
        gradient.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
        gradient.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)

        guard let mask = gradient.outputImage?.cropped(to: extent) else { return image }

        let local = CIFilter.exposureAdjust()
        local.inputImage = image
        local.ev = Float(radial.exposureEV)
        let localImage = local.outputImage ?? image

        let blend = CIFilter.blendWithMask()
        blend.inputImage = localImage
        blend.backgroundImage = image
        blend.maskImage = mask
        return blend.outputImage ?? image
    }

    private static func clamp(_ value: Double, _ minValue: Double, _ maxValue: Double) -> Double {
        min(max(value, minValue), maxValue)
    }
}

struct PhotoEditorView: View {
    private enum Panel: String, CaseIterable, Identifiable {
        case light
        case color
        case crop
        case radial
        case presets

        var id: String { rawValue }

        var title: String {
            switch self {
            case .light: return "ライト"
            case .color: return "カラー"
            case .crop: return "トリミング"
            case .radial: return "ラジアル"
            case .presets: return "プリセット"
            }
        }
    }

    private enum StorageKeys {
        static let presets = "photo_editor_presets_v1"
    }

    let originalImage: UIImage

    @Environment(\.dismiss) private var dismiss

    @State private var panel: Panel = .light
    @State private var settings: PhotoEditorSettings = .default
    @State private var previewSourceImage: UIImage?
    @State private var previewImage: UIImage?

    @State private var isRendering: Bool = false
    @State private var isExporting: Bool = false
    @State private var renderTask: Task<Void, Never>?

    @State private var presets: [PhotoEditorPreset] = []
    @State private var showSavePresetAlert: Bool = false
    @State private var presetName: String = ""

    @State private var showResultAlert: Bool = false
    @State private var resultMessage: String = ""

    @State private var imageWriteCoordinator: ImageWriteCoordinator?

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    previewArea
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    controlsArea
                }

                if isRendering || isExporting {
                    ProgressView()
                        .scaleEffect(1.2)
                        .padding(22)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                }
            }
            .navigationTitle("編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("閉じる") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 14) {
                        Button {
                            resetAll()
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                        }

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
        .onAppear {
            presets = loadPresets()
            previewSourceImage = originalImage.scaledToMaxDimension(1600)
            schedulePreviewRender()
        }
        .onDisappear {
            renderTask?.cancel()
        }
        .onChange(of: settings) { _, _ in
            clampCrop()
            clampRadial()
            schedulePreviewRender()
        }
        .alert("プリセット保存", isPresented: $showSavePresetAlert) {
            TextField("名前", text: $presetName)
            Button("保存") {
                savePreset()
            }
            Button("キャンセル", role: .cancel) {
                presetName = ""
            }
        } message: {
            Text("現在の編集をプリセットとして保存します")
        }
        .alert("結果", isPresented: $showResultAlert) {
            Button("OK") {
                resultMessage = ""
            }
        } message: {
            Text(resultMessage)
        }
    }

    private var previewArea: some View {
        ZStack {
            if let previewImage {
                Image(uiImage: previewImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(.horizontal, 10)
            } else {
                Image(uiImage: originalImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(.horizontal, 10)
            }
        }
    }

    private var controlsArea: some View {
        VStack(spacing: 12) {
            Picker("Panel", selection: $panel) {
                ForEach(Panel.allCases) { p in
                    Text(p.title).tag(p)
                }
            }
            .pickerStyle(.segmented)

            Divider().opacity(0.2)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    panelControls
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var panelControls: some View {
        switch panel {
        case .light:
            sliderRow(title: "露出", value: $settings.exposureEV, range: -2...2, step: 0.05)
            sliderRow(title: "コントラスト", value: $settings.contrast, range: 0.5...1.6, step: 0.02)
            sliderRow(title: "ハイライト", value: $settings.highlightRecovery, range: 0...1, step: 0.02)
            sliderRow(title: "シャドウ", value: $settings.shadowBoost, range: 0...1, step: 0.02)

        case .color:
            sliderRow(title: "彩度", value: $settings.saturation, range: 0...2, step: 0.02)
            sliderRow(title: "色温度", value: $settings.temperature, range: -2000...2000, step: 25)
            sliderRow(title: "モノクロ", value: $settings.monochrome, range: 0...1, step: 0.02)

        case .crop:
            cropControls

        case .radial:
            radialControls

        case .presets:
            presetsControls
        }
    }

    private var cropControls: some View {
        let crop = Binding(get: { settings.crop }, set: { settings.crop = $0 })
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("範囲")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Button("リセット") {
                    settings.crop = .full
                }
                .font(.caption.weight(.bold))
            }

            sliderRow(title: "幅", value: crop.width, range: 0.2...1, step: 0.01)
            sliderRow(title: "高さ", value: crop.height, range: 0.2...1, step: 0.01)
            sliderRow(title: "X", value: crop.x, range: 0...max(0, 1 - crop.wrappedValue.width), step: 0.01)
            sliderRow(title: "Y", value: crop.y, range: 0...max(0, 1 - crop.wrappedValue.height), step: 0.01)
        }
    }

    private var radialControls: some View {
        let radial = Binding(get: { settings.radialMask }, set: { settings.radialMask = $0 })
        return VStack(alignment: .leading, spacing: 12) {
            Toggle("ラジアルマスク", isOn: radial.enabled)
                .toggleStyle(SwitchToggleStyle(tint: .blue))

            sliderRow(title: "明るさ(局所)", value: radial.exposureEV, range: -2...2, step: 0.05)
            sliderRow(title: "中心X", value: radial.centerX, range: 0...1, step: 0.01)
            sliderRow(title: "中心Y", value: radial.centerY, range: 0...1, step: 0.01)
            sliderRow(title: "半径", value: radial.radius, range: 0.05...0.9, step: 0.01)
            sliderRow(title: "ぼかし", value: radial.feather, range: 0...1, step: 0.02)

            Button("リセット") {
                settings.radialMask = .default
            }
            .font(.caption.weight(.bold))
        }
    }

    private var presetsControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("保存 / 適用")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Button("保存") {
                    presetName = ""
                    showSavePresetAlert = true
                }
                .font(.caption.weight(.bold))
            }

            if presets.isEmpty {
                Text("プリセットがありません")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(presets) { preset in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.name)
                                .font(.subheadline.weight(.semibold))
                            Text(preset.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Button("適用") {
                            settings = preset.settings
                        }
                        .font(.caption.weight(.bold))

                        Button(role: .destructive) {
                            deletePreset(preset)
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                    .padding(12)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
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

    private func schedulePreviewRender() {
        renderTask?.cancel()
        let source = previewSourceImage ?? originalImage
        let current = settings

        renderTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if Task.isCancelled { return }

            await MainActor.run { isRendering = true }
            let rendered = PhotoEditorRenderer.render(image: source, settings: current)
            await MainActor.run {
                previewImage = rendered
                isRendering = false
            }
        }
    }

    private func resetAll() {
        settings = .default
    }

    private func exportToPhotoLibrary() {
        if isExporting { return }
        isExporting = true

        let current = settings
        Task {
            let rendered = PhotoEditorRenderer.render(image: originalImage, settings: current)

            await MainActor.run {
                guard let rendered else {
                    isExporting = false
                    resultMessage = "書き出しに失敗しました"
                    showResultAlert = true
                    return
                }

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
                    rendered,
                    coordinator,
                    #selector(ImageWriteCoordinator.image(_:didFinishSavingWithError:contextInfo:)),
                    nil
                )
            }
        }
    }

    private func loadPresets() -> [PhotoEditorPreset] {
        guard let data = UserDefaults.standard.data(forKey: StorageKeys.presets) else { return [] }
        return (try? JSONDecoder().decode([PhotoEditorPreset].self, from: data)) ?? []
    }

    private func persistPresets() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        UserDefaults.standard.set(data, forKey: StorageKeys.presets)
    }

    private func savePreset() {
        let name = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = name.isEmpty ? "Preset" : name

        let preset = PhotoEditorPreset(id: UUID(), name: resolved, createdAt: Date(), settings: settings)
        presets.insert(preset, at: 0)
        persistPresets()
        presetName = ""

        resultMessage = "保存しました"
        showResultAlert = true
    }

    private func deletePreset(_ preset: PhotoEditorPreset) {
        presets.removeAll { $0.id == preset.id }
        persistPresets()
    }

    private func clampCrop() {
        var crop = settings.crop
        crop.width = min(max(crop.width, 0.2), 1)
        crop.height = min(max(crop.height, 0.2), 1)
        crop.x = min(max(crop.x, 0), 1 - crop.width)
        crop.y = min(max(crop.y, 0), 1 - crop.height)
        settings.crop = crop
    }

    private func clampRadial() {
        var radial = settings.radialMask
        radial.centerX = min(max(radial.centerX, 0), 1)
        radial.centerY = min(max(radial.centerY, 0), 1)
        radial.radius = min(max(radial.radius, 0.05), 0.9)
        radial.feather = min(max(radial.feather, 0), 1)
        radial.exposureEV = min(max(radial.exposureEV, -2), 2)
        settings.radialMask = radial
    }
}

private extension UIImage {
    func scaledToMaxDimension(_ maxDimension: CGFloat) -> UIImage {
        let maxDim = max(size.width, size.height)
        guard maxDim > maxDimension, maxDim > 0 else { return self }
        let scale = maxDimension / maxDim
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}

private extension UIImage.Orientation {
    var exifOrientation: Int32 {
        switch self {
        case .up: return 1
        case .down: return 3
        case .left: return 8
        case .right: return 6
        case .upMirrored: return 2
        case .downMirrored: return 4
        case .leftMirrored: return 5
        case .rightMirrored: return 7
        @unknown default: return 1
        }
    }
}
