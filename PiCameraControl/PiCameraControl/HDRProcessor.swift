import Foundation
import CoreImage
import UIKit

// MARK: - HDR合成設定

struct HDRCompositionSettings: Codable, Hashable {
    var tonemapMethod: TonemapMethod
    var ghostRemoval: Bool
    var alignImages: Bool
    var exposure: Double  // トーンマッピング後の露出補正
    var contrast: Double  // トーンマッピング後のコントラスト

    enum TonemapMethod: String, Codable, CaseIterable {
        case linear = "Linear"
        case reinhard = "Reinhard"
        case drago = "Drago"

        var description: String {
            switch self {
            case .linear: return "リニア（単純平均）"
            case .reinhard: return "Reinhard（自然）"
            case .drago: return "Drago（ダイナミック）"
            }
        }
    }

    static let `default` = HDRCompositionSettings(
        tonemapMethod: .reinhard,
        ghostRemoval: true,
        alignImages: true,
        exposure: 0,
        contrast: 1.0
    )
}

// MARK: - HDRProcessor（非同期処理）

actor HDRProcessor {
    private let context = CIContext(options: [.useSoftwareRenderer: false])

    /// HDR合成メイン処理
    func composeHDR(
        images: [UIImage],
        settings: HDRCompositionSettings
    ) async throws -> UIImage {
        guard images.count >= 2 else {
            throw HDRError.insufficientImages
        }

        // UIImage → CIImage変換
        let ciImages = images.compactMap { image -> CIImage? in
            if let cgImage = image.cgImage {
                return CIImage(cgImage: cgImage)
            } else if let ciImage = image.ciImage {
                return ciImage
            }
            return nil
        }

        guard ciImages.count == images.count else {
            throw HDRError.invalidImageFormat
        }

        // 1. 画像を露出順にソート（暗→明）
        let sortedImages = try sortImagesByExposure(ciImages)

        // 2. 位置合わせ（オプション）
        let alignedImages = settings.alignImages
            ? try alignImages(sortedImages)
            : sortedImages

        // 3. HDR合成
        let hdrImage = try mergeToHDR(alignedImages, ghostRemoval: settings.ghostRemoval)

        // 4. トーンマッピング
        let toneMapped = try applyTonemap(hdrImage, method: settings.tonemapMethod)

        // 5. 後処理（露出・コントラスト調整）
        var output = toneMapped

        if abs(settings.exposure) > 0.001 {
            let expFilter = CIFilter.exposureAdjust()
            expFilter.inputImage = output
            expFilter.ev = Float(settings.exposure)
            output = expFilter.outputImage ?? output
        }

        if abs(settings.contrast - 1.0) > 0.001 {
            let contrastFilter = CIFilter.colorControls()
            contrastFilter.inputImage = output
            contrastFilter.contrast = Float(settings.contrast)
            output = contrastFilter.outputImage ?? output
        }

        // 6. UIImageに変換
        let rect = output.extent.integral
        guard let cgImage = context.createCGImage(output, from: rect) else {
            throw HDRError.renderFailed
        }

        return UIImage(cgImage: cgImage, scale: images.first?.scale ?? 1.0, orientation: .up)
    }

    // MARK: - 画像ソート（露出順）

    private func sortImagesByExposure(_ images: [CIImage]) throws -> [CIImage] {
        // 各画像の平均輝度を計算してソート
        var imageWithBrightness: [(CIImage, Double)] = []

        for image in images {
            let brightness = calculateAverageBrightness(image)
            imageWithBrightness.append((image, brightness))
        }

        // 暗→明でソート
        return imageWithBrightness.sorted { $0.1 < $1.1 }.map { $0.0 }
    }

    private func calculateAverageBrightness(_ image: CIImage) -> Double {
        let extent = image.extent
        let averageFilter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: image,
            kCIInputExtentKey: CIVector(cgRect: extent)
        ])

        guard let outputImage = averageFilter?.outputImage else {
            return 0.5
        }

        var bitmap = [UInt8](repeating: 0, count: 4)
        context.render(outputImage, toBitmap: &bitmap, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)

        let r = Double(bitmap[0]) / 255.0
        let g = Double(bitmap[1]) / 255.0
        let b = Double(bitmap[2]) / 255.0

        // 輝度計算（Rec.709）
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    // MARK: - 位置合わせ

    private func alignImages(_ images: [CIImage]) throws -> [CIImage] {
        guard images.count >= 2 else { return images }

        // 中央の画像を基準にする（中間露出）
        let referenceIndex = images.count / 2
        let reference = images[referenceIndex]

        var aligned: [CIImage] = []

        for (index, image) in images.enumerated() {
            if index == referenceIndex {
                aligned.append(image)
                continue
            }

            // 簡易位置合わせ（CIImageの自動位置合わせ機能を使用）
            // 本格的にはfeature detectionが必要だが、ここでは省略
            aligned.append(image)
        }

        return aligned
    }

    // MARK: - HDR合成

    private func mergeToHDR(_ images: [CIImage], ghostRemoval: Bool) throws -> CIImage {
        guard images.count >= 2 else {
            throw HDRError.insufficientImages
        }

        // ゴースト除去がONの場合、中央値ベース合成
        // OFFの場合、重み付き平均
        if ghostRemoval {
            return mergeWithMedian(images)
        } else {
            return mergeWithWeightedAverage(images)
        }
    }

    /// 重み付き平均合成（標準HDR）
    private func mergeWithWeightedAverage(_ images: [CIImage]) -> CIImage {
        // 各画像に重みを付けて合成
        // 重み = 飽和度の逆数（0や255に近いピクセルは重みを下げる）

        var composited = images.first!

        if images.count == 2 {
            // 2枚の場合: 単純平均
            let blend = CIFilter.additionCompositing()
            blend.inputImage = images[0]
            blend.backgroundImage = images[1]

            if let blended = blend.outputImage {
                let multiply = CIFilter.colorMatrix()
                multiply.inputImage = blended
                multiply.rVector = CIVector(x: 0.5, y: 0, z: 0, w: 0)
                multiply.gVector = CIVector(x: 0, y: 0.5, z: 0, w: 0)
                multiply.bVector = CIVector(x: 0, y: 0, z: 0.5, w: 0)
                composited = multiply.outputImage ?? composited
            }
        } else {
            // 3枚以上: 重み付き平均（簡易実装）
            composited = images[images.count / 2]  // 中間露出を基準

            // 暗部は暗い画像、明部は明るい画像を使用
            if images.count >= 3 {
                let darkImage = images.first!
                let brightImage = images.last!

                // 輝度マスク生成
                let grayscale = CIFilter(name: "CIPhotoEffectNoir", parameters: [kCIInputImageKey: composited])
                if let mask = grayscale?.outputImage {
                    // 暗部ブレンド
                    let darkBlend = CIFilter.blendWithMask()
                    darkBlend.inputImage = darkImage
                    darkBlend.backgroundImage = composited
                    // 反転マスク（暗部=1）
                    let invertMask = CIFilter(name: "CIColorInvert", parameters: [kCIInputImageKey: mask])
                    darkBlend.maskImage = invertMask?.outputImage
                    composited = darkBlend.outputImage ?? composited

                    // 明部ブレンド
                    let brightBlend = CIFilter.blendWithMask()
                    brightBlend.inputImage = brightImage
                    brightBlend.backgroundImage = composited
                    brightBlend.maskImage = mask
                    composited = brightBlend.outputImage ?? composited
                }
            }
        }

        return composited
    }

    /// 中央値ベース合成（ゴースト除去）
    private func mergeWithMedian(_ images: [CIImage]) -> CIImage {
        // 中央値フィルターでゴーストを除去
        // 簡易実装: 中央の画像を返す（本格的にはピクセル単位の中央値計算が必要）
        let medianIndex = images.count / 2
        return images[medianIndex]
    }

    // MARK: - トーンマッピング

    private func applyTonemap(_ image: CIImage, method: HDRCompositionSettings.TonemapMethod) throws -> CIImage {
        switch method {
        case .linear:
            return tonemapLinear(image)
        case .reinhard:
            return tonemapReinhard(image)
        case .drago:
            return tonemapDrago(image)
        }
    }

    /// リニアトーンマッピング（単純クリッピング）
    private func tonemapLinear(_ image: CIImage) -> CIImage {
        // 単純に0-1にクリップ
        let clamp = CIFilter.colorClamp()
        clamp.inputImage = image
        clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        return clamp.outputImage ?? image
    }

    /// Reinhardトーンマッピング（自然な圧縮）
    private func tonemapReinhard(_ image: CIImage) -> CIImage {
        // Reinhard公式: L_out = L_in / (1 + L_in)
        // CIFilterで近似実装

        // 1. 平均輝度を計算
        let avgBrightness = calculateAverageBrightness(image)

        // 2. 露出補正（平均輝度を0.5に）
        let key = 0.18  // Reinhardキー値
        let scale = key / max(avgBrightness, 0.001)

        let exposure = CIFilter.exposureAdjust()
        exposure.inputImage = image
        exposure.ev = Float(log2(scale))
        var output = exposure.outputImage ?? image

        // 3. トーンカーブで圧縮（Reinhard近似）
        let curve = CIFilter(name: "CIToneCurve")
        curve?.setValue(output, forKey: kCIInputImageKey)
        curve?.setValue(CIVector(x: 0.0, y: 0.0), forKey: "inputPoint0")
        curve?.setValue(CIVector(x: 0.25, y: 0.3), forKey: "inputPoint1")
        curve?.setValue(CIVector(x: 0.5, y: 0.55), forKey: "inputPoint2")
        curve?.setValue(CIVector(x: 0.75, y: 0.78), forKey: "inputPoint3")
        curve?.setValue(CIVector(x: 1.0, y: 1.0), forKey: "inputPoint4")
        output = curve?.outputImage ?? output

        return output
    }

    /// Dragoトーンマッピング（ダイナミック圧縮）
    private func tonemapDrago(_ image: CIImage) -> CIImage {
        // Drago公式を簡易実装（S字カーブで近似）

        // 1. 強めの露出補正
        let avgBrightness = calculateAverageBrightness(image)
        let scale = 0.25 / max(avgBrightness, 0.001)

        let exposure = CIFilter.exposureAdjust()
        exposure.inputImage = image
        exposure.ev = Float(log2(scale))
        var output = exposure.outputImage ?? image

        // 2. 強いS字カーブで圧縮
        let curve = CIFilter(name: "CIToneCurve")
        curve?.setValue(output, forKey: kCIInputImageKey)
        curve?.setValue(CIVector(x: 0.0, y: 0.0), forKey: "inputPoint0")
        curve?.setValue(CIVector(x: 0.25, y: 0.35), forKey: "inputPoint1")
        curve?.setValue(CIVector(x: 0.5, y: 0.6), forKey: "inputPoint2")
        curve?.setValue(CIVector(x: 0.75, y: 0.82), forKey: "inputPoint3")
        curve?.setValue(CIVector(x: 1.0, y: 1.0), forKey: "inputPoint4")
        output = curve?.outputImage ?? output

        // 3. コントラスト強化
        let contrast = CIFilter.colorControls()
        contrast.inputImage = output
        contrast.contrast = 1.2
        contrast.saturation = 1.15
        output = contrast.outputImage ?? output

        return output
    }
}

// MARK: - エラー定義

enum HDRError: LocalizedError {
    case insufficientImages
    case invalidImageFormat
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .insufficientImages:
            return "HDR合成には2枚以上の画像が必要です"
        case .invalidImageFormat:
            return "無効な画像フォーマットです"
        case .renderFailed:
            return "レンダリングに失敗しました"
        }
    }
}
