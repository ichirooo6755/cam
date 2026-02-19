import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import CoreData

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

// MARK: - HSL調整（色相・彩度・輝度）

struct HSLChannel: Codable, Hashable {
    var hue: Double        // 色相シフト（-180〜+180度）
    var saturation: Double // 彩度（-100〜+100%）
    var luminance: Double  // 輝度（-100〜+100%）

    static let `default` = HSLChannel(hue: 0, saturation: 0, luminance: 0)
}

struct HSLSettings: Codable, Hashable {
    var red: HSLChannel
    var orange: HSLChannel
    var yellow: HSLChannel
    var green: HSLChannel
    var aqua: HSLChannel
    var blue: HSLChannel
    var purple: HSLChannel
    var magenta: HSLChannel

    static let `default` = HSLSettings(
        red: .default,
        orange: .default,
        yellow: .default,
        green: .default,
        aqua: .default,
        blue: .default,
        purple: .default,
        magenta: .default
    )
}

// MARK: - トーンカーブ

struct ToneCurve: Codable, Hashable {
    var points: [Double]  // 5点制御 [0, 0.25, 0.5, 0.75, 1.0]

    static let `default` = ToneCurve(points: [0, 0.25, 0.5, 0.75, 1.0])
}

struct ToneCurveSettings: Codable, Hashable {
    var master: ToneCurve
    var red: ToneCurve
    var green: ToneCurve
    var blue: ToneCurve

    static let `default` = ToneCurveSettings(
        master: .default,
        red: .default,
        green: .default,
        blue: .default
    )
}

// MARK: - スプリットトーニング

struct SplitToningSettings: Codable, Hashable {
    var highlightHue: Double       // ハイライト色相（0〜360度）
    var highlightSaturation: Double // ハイライト彩度（0〜100%）
    var shadowHue: Double          // シャドウ色相（0〜360度）
    var shadowSaturation: Double   // シャドウ彩度（0〜100%）
    var balance: Double            // バランス（-100〜+100、0=中間）

    static let `default` = SplitToningSettings(
        highlightHue: 0,
        highlightSaturation: 0,
        shadowHue: 0,
        shadowSaturation: 0,
        balance: 0
    )
}

struct PhotoEditorSettings: Codable, Hashable {
    var exposureEV: Double
    var contrast: Double
    var saturation: Double
    var highlightRecovery: Double
    var shadowBoost: Double
    var temperature: Double
    var tint: Double  // グリーン/マゼンタ補正
    var vibrance: Double  // 彩度（Vibrance: 肌色保護）
    var clarity: Double  // 明瞭度
    var texture: Double  // テクスチャ（細かいディテール強調）
    var dehaze: Double  // ディヘイズ（霞除去）
    var sharpness: Double  // シャープネス
    var noiseReduction: Double  // ノイズ除去
    var vignette: Double  // ヴィネット（周辺光量）
    var grain: Double  // フィルムグレイン
    var autoWhiteBalance: Bool  // 自動ホワイトバランス補正
    var irAutoCorrect: Bool
    var irCorrectionStrength: Double
    var monochrome: Double
    var crop: NormalizedRect
    var radialMask: RadialMaskSettings
    var hsl: HSLSettings  // HSL調整（8色チャンネル）
    var splitToning: SplitToningSettings  // スプリットトーニング
    var toneCurve: ToneCurveSettings  // トーンカーブ（Master/RGB）

    static let `default` = PhotoEditorSettings(
        exposureEV: 0,
        contrast: 1,
        saturation: 1,
        highlightRecovery: 0,
        shadowBoost: 0,
        temperature: 0,
        tint: 0,
        vibrance: 0,
        clarity: 0,
        texture: 0,
        dehaze: 0,
        sharpness: 0,
        noiseReduction: 0,
        vignette: 0,
        grain: 0,
        autoWhiteBalance: false,
        irAutoCorrect: false,
        irCorrectionStrength: 0.75,
        monochrome: 0,
        crop: .full,
        radialMask: .default,
        hsl: .default,
        splitToning: .default,
        toneCurve: .default
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

// MARK: - ImageAnalyzer (精度向上版)

struct ImageAnalysisResult {
    var brightness: Double      // 0-1 (平均輝度)
    var contrast: Double        // 0-1 (ヒストグラム標準偏差)
    var saturation: Double      // 0-1 (平均彩度)
    var histogram: HistogramData  // ヒストグラム情報
    var colorBalance: (r: Double, g: Double, b: Double)  // RGB平均
    var exposureScore: Double   // 露出評価（0=暗い, 0.5=適正, 1=明るい）
}

struct HistogramData {
    var luminanceStdDev: Double  // 輝度の標準偏差
    var shadowClipping: Double   // シャドウクリッピング（0-1）
    var highlightClipping: Double // ハイライトクリッピング（0-1）
    var dynamicRange: Double     // ダイナミックレンジ（0-1）
}

private enum ImageAnalyzer {
    private static let context = CIContext(options: nil)

    static func analyze(image: UIImage) -> ImageAnalysisResult? {
        let ciImage: CIImage
        if let cgImage = image.cgImage {
            ciImage = CIImage(cgImage: cgImage)
        } else if let ci = image.ciImage {
            ciImage = ci
        } else if let ci = CIImage(image: image) {
            ciImage = ci
        } else {
            return nil
        }

        // 平均色を計算
        let avgColor = calculateAverageColor(ciImage)
        let r = avgColor.r
        let g = avgColor.g
        let b = avgColor.b

        // 明るさ（輝度）
        let brightness = 0.299 * r + 0.587 * g + 0.114 * b

        // ヒストグラム分析
        let histogram = analyzeHistogram(ciImage)

        // コントラスト（ヒストグラム標準偏差ベース）
        let contrast = histogram.luminanceStdDev

        // 彩度（色の鮮やかさ）
        let maxRGB = max(r, g, b)
        let minRGB = min(r, g, b)
        let saturation = maxRGB > 0 ? (maxRGB - minRGB) / maxRGB : 0

        // 露出スコア（明暗バランス評価）
        let exposureScore = calculateExposureScore(brightness: brightness, histogram: histogram)

        return ImageAnalysisResult(
            brightness: brightness,
            contrast: contrast,
            saturation: saturation,
            histogram: histogram,
            colorBalance: (r, g, b),
            exposureScore: exposureScore
        )
    }

    /// 平均色を計算
    private static func calculateAverageColor(_ ciImage: CIImage) -> (r: Double, g: Double, b: Double) {
        let extent = ciImage.extent
        let averageFilter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: ciImage,
            kCIInputExtentKey: CIVector(cgRect: extent)
        ])

        guard let outputImage = averageFilter?.outputImage else {
            return (0.5, 0.5, 0.5)
        }

        var bitmap = [UInt8](repeating: 0, count: 4)
        context.render(outputImage, toBitmap: &bitmap, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)

        return (
            Double(bitmap[0]) / 255.0,
            Double(bitmap[1]) / 255.0,
            Double(bitmap[2]) / 255.0
        )
    }

    /// ヒストグラム分析（精度向上版）
    private static func analyzeHistogram(_ ciImage: CIImage) -> HistogramData {
        // サンプリング（高速化のためダウンスケール）
        let scale: CGFloat = 0.25
        let transform = CGAffineTransform(scaleX: scale, y: scale)
        let scaledImage = ciImage.transformed(by: transform)

        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else {
            return HistogramData(luminanceStdDev: 0.5, shadowClipping: 0, highlightClipping: 0, dynamicRange: 0.5)
        }

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        let bitsPerComponent = 8

        var pixelData = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            return HistogramData(luminanceStdDev: 0.5, shadowClipping: 0, highlightClipping: 0, dynamicRange: 0.5)
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // 輝度ヒストグラム作成
        var luminanceValues: [Double] = []
        var shadowCount = 0
        var highlightCount = 0

        for i in stride(from: 0, to: pixelData.count, by: bytesPerPixel) {
            let r = Double(pixelData[i]) / 255.0
            let g = Double(pixelData[i + 1]) / 255.0
            let b = Double(pixelData[i + 2]) / 255.0

            let luminance = 0.299 * r + 0.587 * g + 0.114 * b
            luminanceValues.append(luminance)

            // クリッピング検出
            if luminance < 0.05 { shadowCount += 1 }
            if luminance > 0.95 { highlightCount += 1 }
        }

        // 標準偏差計算
        let mean = luminanceValues.reduce(0, +) / Double(luminanceValues.count)
        let variance = luminanceValues.map { pow($0 - mean, 2) }.reduce(0, +) / Double(luminanceValues.count)
        let stdDev = sqrt(variance)

        // クリッピング率
        let totalPixels = Double(luminanceValues.count)
        let shadowClipping = Double(shadowCount) / totalPixels
        let highlightClipping = Double(highlightCount) / totalPixels

        // ダイナミックレンジ（最大値-最小値）
        let minLum = luminanceValues.min() ?? 0
        let maxLum = luminanceValues.max() ?? 1
        let dynamicRange = maxLum - minLum

        return HistogramData(
            luminanceStdDev: stdDev,
            shadowClipping: shadowClipping,
            highlightClipping: highlightClipping,
            dynamicRange: dynamicRange
        )
    }

    /// 露出スコア計算
    private static func calculateExposureScore(brightness: Double, histogram: HistogramData) -> Double {
        // 理想的な露出: brightness = 0.4-0.6, クリッピングなし
        let brightnessScore = 1.0 - abs(brightness - 0.5) * 2.0
        let clippingPenalty = (histogram.shadowClipping + histogram.highlightClipping) * 2.0
        return max(0, min(1, brightnessScore - clippingPenalty))
    }
}

// MARK: - AutoEditEngine (精度向上版)

private enum AutoEditEngine {
    /// 画像分析結果に基づいて設定を提案（精度向上版）
    static func suggestSettings(for analysis: ImageAnalysisResult, learningData: [AutoEditEvaluation]) -> PhotoEditorSettings {
        var settings = PhotoEditorSettings.default

        // 学習データの分析
        let highRatedData = learningData.filter { $0.userRating >= 4 }
        let lowRatedData = learningData.filter { $0.userRating <= 2 }

        // ベース補正（ヒストグラム分析ベース）
        applyBaseCorrections(&settings, analysis: analysis)

        // ポジティブ学習（高評価データから学習）
        if !highRatedData.isEmpty {
            applyPositiveLearning(&settings, highRatedData: highRatedData, analysis: analysis)
        }

        // ネガティブ学習（低評価データから回避）
        if !lowRatedData.isEmpty {
            applyNegativeLearning(&settings, lowRatedData: lowRatedData, analysis: analysis)
        }

        // 動的重み調整（学習データ量に応じて重みを調整）
        let learningWeight = calculateLearningWeight(dataCount: learningData.count)
        settings = blendSettings(base: settings, learned: settings, weight: learningWeight)

        return settings
    }

    /// ベース補正（ヒストグラム分析ベース）
    private static func applyBaseCorrections(_ settings: inout PhotoEditorSettings, analysis: ImageAnalysisResult) {
        let hist = analysis.histogram

        // 露出補正（クリッピングとダイナミックレンジを考慮）
        if hist.shadowClipping > 0.1 {
            // シャドウクリッピング → 明るくする
            settings.exposureEV = 0.5 + hist.shadowClipping
            settings.shadowBoost = 0.4
        } else if hist.highlightClipping > 0.1 {
            // ハイライトクリッピング → 暗くする
            settings.exposureEV = -0.5 - hist.highlightClipping
            settings.highlightRecovery = 0.5
        } else if analysis.exposureScore < 0.5 {
            // 露出不足
            settings.exposureEV = (0.5 - analysis.exposureScore) * 2.0
            settings.shadowBoost = 0.3
        }

        // コントラスト補正（標準偏差ベース）
        if hist.luminanceStdDev < 0.15 {
            // 低コントラスト
            settings.contrast = 1.3
            settings.clarity = 0.4
        } else if hist.luminanceStdDev > 0.35 {
            // 高コントラスト
            settings.contrast = 0.9
            settings.highlightRecovery = 0.3
            settings.shadowBoost = 0.2
        }

        // 彩度補正
        if analysis.saturation < 0.25 {
            settings.vibrance = 0.3
            settings.saturation = 1.15
        } else if analysis.saturation > 0.75 {
            settings.saturation = 0.85
        }

        // ダイナミックレンジ補正
        if hist.dynamicRange < 0.4 {
            // 狭いダイナミックレンジ → コントラスト強化
            settings.contrast = 1.25
            settings.clarity = 0.3
        }
    }

    /// ポジティブ学習（高評価データから学習）
    private static func applyPositiveLearning(_ settings: inout PhotoEditorSettings, highRatedData: [AutoEditEvaluation], analysis: ImageAnalysisResult) {
        // 類似画像の学習データを重視（明るさベース）
        let similarData = highRatedData.filter {
            abs($0.imageBrightness - analysis.brightness) < 0.2
        }

        let targetData = similarData.isEmpty ? highRatedData : similarData

        var avgExposure = 0.0
        var avgContrast = 0.0
        var avgSaturation = 0.0
        var avgClarity = 0.0
        var avgHighlightRecovery = 0.0
        var avgShadowBoost = 0.0

        for data in targetData {
            if let finalSettings = data.finalSettings {
                avgExposure += finalSettings.exposureEV
                avgContrast += finalSettings.contrast
                avgSaturation += finalSettings.saturation
                avgClarity += finalSettings.clarity
                avgHighlightRecovery += finalSettings.highlightRecovery
                avgShadowBoost += finalSettings.shadowBoost
            }
        }

        let count = Double(targetData.count)
        avgExposure /= count
        avgContrast /= count
        avgSaturation /= count
        avgClarity /= count
        avgHighlightRecovery /= count
        avgShadowBoost /= count

        // 学習データで微調整（30%の重み - 以前より重視）
        settings.exposureEV = settings.exposureEV * 0.7 + avgExposure * 0.3
        settings.contrast = settings.contrast * 0.7 + avgContrast * 0.3
        settings.saturation = settings.saturation * 0.7 + avgSaturation * 0.3
        settings.clarity = settings.clarity * 0.7 + avgClarity * 0.3
        settings.highlightRecovery = settings.highlightRecovery * 0.7 + avgHighlightRecovery * 0.3
        settings.shadowBoost = settings.shadowBoost * 0.7 + avgShadowBoost * 0.3
    }

    /// ネガティブ学習（低評価データから回避）
    private static func applyNegativeLearning(_ settings: inout PhotoEditorSettings, lowRatedData: [AutoEditEvaluation], analysis: ImageAnalysisResult) {
        // 低評価データの共通パターンを避ける
        for data in lowRatedData {
            guard let predicted = data.predictedSettings,
                  abs(data.imageBrightness - analysis.brightness) < 0.2 else {
                continue
            }

            // 低評価につながった設定を避ける
            // 予測値と逆方向に調整（ペナルティ）
            if abs(settings.exposureEV - predicted.exposureEV) < 0.3 {
                settings.exposureEV -= (predicted.exposureEV - settings.exposureEV) * 0.1
            }

            if abs(settings.contrast - predicted.contrast) < 0.2 {
                settings.contrast -= (predicted.contrast - settings.contrast) * 0.1
            }

            if abs(settings.saturation - predicted.saturation) < 0.2 {
                settings.saturation -= (predicted.saturation - settings.saturation) * 0.1
            }
        }
    }

    /// 学習重み計算（データ量に応じた信頼度）
    private static func calculateLearningWeight(dataCount: Int) -> Double {
        // データが多いほど学習重みを高くする（最大50%）
        let normalized = Double(min(dataCount, 50)) / 50.0
        return 0.2 + (normalized * 0.3)  // 20% -> 50%
    }

    /// 設定のブレンド
    private static func blendSettings(base: PhotoEditorSettings, learned: PhotoEditorSettings, weight: Double) -> PhotoEditorSettings {
        var result = base
        result.exposureEV = base.exposureEV * (1 - weight) + learned.exposureEV * weight
        result.contrast = base.contrast * (1 - weight) + learned.contrast * weight
        result.saturation = base.saturation * (1 - weight) + learned.saturation * weight
        return result
    }

    /// 自動編集の評価を記録（精度向上版）
    static func recordEvaluation(
        predicted: PhotoEditorSettings,
        final: PhotoEditorSettings,
        rating: Int,
        analysis: ImageAnalysisResult,
        context: NSManagedObjectContext
    ) {
        guard let predictedJSON = try? JSONEncoder().encode(predicted),
              let predictedString = String(data: predictedJSON, encoding: .utf8),
              let finalJSON = try? JSONEncoder().encode(final),
              let finalString = String(data: finalJSON, encoding: .utf8) else {
            return
        }

        let evaluation = AutoEditEvaluation(context: context)
        evaluation.id = UUID()
        evaluation.createdAt = Date()
        evaluation.predictedSettingsJSON = predictedString
        evaluation.finalSettingsJSON = finalString
        evaluation.userRating = Int16(rating)

        // 基本画像特徴量
        evaluation.imageBrightness = analysis.brightness
        evaluation.imageContrast = analysis.contrast
        evaluation.imageSaturation = analysis.saturation

        // 拡張特徴量（メモ: Core Dataモデルに追加する場合）
        // evaluation.shadowClipping = analysis.histogram.shadowClipping
        // evaluation.highlightClipping = analysis.histogram.highlightClipping
        // evaluation.dynamicRange = analysis.histogram.dynamicRange
        // evaluation.exposureScore = analysis.exposureScore

        try? context.save()

        // デバッグログ（学習の進捗確認用）
        #if DEBUG
        print("🧠 Learning: Rating \(rating)⭐️ | Brightness \(String(format: "%.2f", analysis.brightness)) | Contrast \(String(format: "%.2f", analysis.contrast))")
        if rating >= 4 {
            print("  ✅ Positive: EV \(String(format: "%.2f", final.exposureEV)) | Contrast \(String(format: "%.2f", final.contrast))")
        } else if rating <= 2 {
            print("  ❌ Negative: Avoid predicted EV \(String(format: "%.2f", predicted.exposureEV))")
        }
        #endif
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

        if settings.irAutoCorrect {
            output = applyInfraredAutoCorrection(to: output, strength: settings.irCorrectionStrength)
        }

        let effectiveSaturation = settings.saturation * (1 - settings.monochrome)
        if abs(settings.contrast - 1) > 0.0001 || abs(effectiveSaturation - 1) > 0.0001 {
            let f = CIFilter.colorControls()
            f.inputImage = output
            f.contrast = Float(settings.contrast)
            f.saturation = Float(effectiveSaturation)
            output = f.outputImage ?? output
        }

        // 自動ホワイトバランス補正
        if settings.autoWhiteBalance {
            output = applyAutoWhiteBalance(to: output)
        }

        // 色温度とティント調整
        if abs(settings.temperature) > 0.0001 || abs(settings.tint) > 0.0001 {
            let f = CIFilter.temperatureAndTint()
            f.inputImage = output
            f.neutral = CIVector(x: 6500, y: 0)
            f.targetNeutral = CIVector(x: 6500 + settings.temperature, y: settings.tint)
            output = f.outputImage ?? output
        }

        // Vibrance（彩度・肌色保護）
        if abs(settings.vibrance) > 0.0001 {
            let f = CIFilter.vibrance()
            f.inputImage = output
            f.amount = Float(settings.vibrance)
            output = f.outputImage ?? output
        }

        // Clarity（明瞭度）
        if abs(settings.clarity) > 0.0001 {
            output = applyClarity(to: output, amount: settings.clarity)
        }

        // Texture（テクスチャ・細かいディテール強調）
        if abs(settings.texture) > 0.0001 {
            output = applyTexture(to: output, amount: settings.texture)
        }

        // Dehaze（ディヘイズ・霞除去）
        if abs(settings.dehaze) > 0.0001 {
            output = applyDehaze(to: output, amount: settings.dehaze)
        }

        // ノイズ除去
        if abs(settings.noiseReduction) > 0.0001 {
            let f = CIFilter.noiseReduction()
            f.inputImage = output
            f.noiseLevel = Float(settings.noiseReduction * 0.1)
            f.sharpness = Float(max(0, 1 - settings.noiseReduction * 0.3))
            output = f.outputImage ?? output
        }

        // シャープネス
        if abs(settings.sharpness) > 0.0001 {
            let f = CIFilter.sharpenLuminance()
            f.inputImage = output
            f.sharpness = Float(settings.sharpness)
            output = f.outputImage ?? output
        }

        // ヴィネット
        if abs(settings.vignette) > 0.0001 {
            let f = CIFilter.vignette()
            f.inputImage = output
            f.intensity = Float(settings.vignette)
            f.radius = 1.5
            output = f.outputImage ?? output
        }

        // フィルムグレイン
        if abs(settings.grain) > 0.0001 {
            output = applyGrain(to: output, intensity: settings.grain)
        }

        output = applyRadialMask(to: output, radial: settings.radialMask)

        // HSL調整
        output = applyHSL(to: output, settings: settings.hsl)

        // スプリットトーニング
        output = applySplitToning(to: output, settings: settings.splitToning)

        // トーンカーブ
        output = applyToneCurve(to: output, settings: settings.toneCurve)

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

    private static func applyInfraredAutoCorrection(to image: CIImage, strength: Double) -> CIImage {
        let normalizedStrength = clamp(strength, 0, 1)
        guard normalizedStrength > 0.0001 else { return image }

        var output = image

        let tempTint = CIFilter.temperatureAndTint()
        tempTint.inputImage = output
        tempTint.neutral = CIVector(x: 6500, y: 0)
        tempTint.targetNeutral = CIVector(
            x: 6500 - 1300 * normalizedStrength,
            y: -120 * normalizedStrength
        )
        output = tempTint.outputImage ?? output

        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = output
        matrix.rVector = CIVector(
            x: 1 - 0.18 * normalizedStrength,
            y: 0.04 * normalizedStrength,
            z: 0.02 * normalizedStrength,
            w: 0
        )
        matrix.gVector = CIVector(
            x: 0.08 * normalizedStrength,
            y: 1 + 0.12 * normalizedStrength,
            z: 0.08 * normalizedStrength,
            w: 0
        )
        matrix.bVector = CIVector(
            x: 0.03 * normalizedStrength,
            y: 0.06 * normalizedStrength,
            z: 1 - 0.16 * normalizedStrength,
            w: 0
        )
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        output = matrix.outputImage ?? output

        let controls = CIFilter.colorControls()
        controls.inputImage = output
        controls.saturation = Float(max(0.7, 1 - 0.1 * normalizedStrength))
        output = controls.outputImage ?? output

        return output
    }

    /// 自動ホワイトバランス補正（色かぶり除去）
    private static func applyAutoWhiteBalance(to image: CIImage) -> CIImage {
        // 画像全体の平均色を計算
        let extent = image.extent
        let averageFilter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: image,
            kCIInputExtentKey: CIVector(cgRect: extent)
        ])

        guard let outputImage = averageFilter?.outputImage else { return image }

        var bitmap = [UInt8](repeating: 0, count: 4)
        context.render(outputImage, toBitmap: &bitmap, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)

        let r = Double(bitmap[0]) / 255.0
        let g = Double(bitmap[1]) / 255.0
        let b = Double(bitmap[2]) / 255.0

        // グレーポイント（理想的には0.5）からのズレを計算
        let grayPoint = 0.5
        let rGain = grayPoint / max(r, 0.01)
        let gGain = grayPoint / max(g, 0.01)
        let bGain = grayPoint / max(b, 0.01)

        // ゲインを正規化
        let maxGain = max(rGain, gGain, bGain)
        let normalizedR = rGain / maxGain
        let normalizedG = gGain / maxGain
        let normalizedB = bGain / maxGain

        // カラーマトリクスで補正
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = image
        matrix.rVector = CIVector(x: normalizedR, y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: 0, y: normalizedG, z: 0, w: 0)
        matrix.bVector = CIVector(x: 0, y: 0, z: normalizedB, w: 0)
        matrix.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)

        return matrix.outputImage ?? image
    }

    /// Clarity（明瞭度）適用
    private static func applyClarity(to image: CIImage, amount: Double) -> CIImage {
        guard abs(amount) > 0.0001 else { return image }

        // ガウシアンブラーでソフトな画像を生成
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = image
        blur.radius = 5.0
        guard let blurred = blur.outputImage else { return image }

        // ハイパス: 元画像 - ブラー
        let subtract = CIFilter(name: "CISubtractBlendMode", parameters: [
            kCIInputImageKey: image,
            kCIInputBackgroundImageKey: blurred
        ])
        guard let highpass = subtract?.outputImage else { return image }

        // ハイパスをオーバーレイ合成
        let overlay = CIFilter(name: "CIOverlayBlendMode", parameters: [
            kCIInputImageKey: highpass,
            kCIInputBackgroundImageKey: image
        ])
        guard let clarified = overlay?.outputImage else { return image }

        // amount に応じてブレンド
        if amount < 1.0 {
            let blend = CIFilter(name: "CIBlendWithMask", parameters: [
                kCIInputImageKey: clarified,
                kCIInputBackgroundImageKey: image,
                kCIInputMaskImageKey: CIImage(color: CIColor(red: CGFloat(amount), green: CGFloat(amount), blue: CGFloat(amount)))
            ])
            return blend?.outputImage ?? image
        }

        return clarified
    }

    /// テクスチャ適用（細かいディテール強調）
    private static func applyTexture(to image: CIImage, amount: Double) -> CIImage {
        guard abs(amount) > 0.0001 else { return image }

        // Clarityより小さい半径でハイパスフィルター（細部強調）
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = image
        blur.radius = 2.0  // Clarityの5.0より小さい
        guard let blurred = blur.outputImage else { return image }

        // ハイパス: 元画像 - ブラー
        let subtract = CIFilter(name: "CISubtractBlendMode", parameters: [
            kCIInputImageKey: image,
            kCIInputBackgroundImageKey: blurred
        ])
        guard let highpass = subtract?.outputImage else { return image }

        // ハイパスをソフトライト合成（Overlayより柔らかい）
        let softLight = CIFilter(name: "CISoftLightBlendMode", parameters: [
            kCIInputImageKey: highpass,
            kCIInputBackgroundImageKey: image
        ])
        guard let textured = softLight?.outputImage else { return image }

        // amount に応じてブレンド
        let normalizedAmount = clamp(amount, -1, 1)
        let blendAmount = abs(normalizedAmount)

        if blendAmount < 1.0 {
            // Linear interpolation
            let blend = CIFilter.blendWithAlphaMask()
            blend.inputImage = textured
            blend.backgroundImage = image
            // alpha maskとして単色画像を使用
            let maskColor = CIColor(red: CGFloat(blendAmount), green: CGFloat(blendAmount), blue: CGFloat(blendAmount))
            blend.maskImage = CIImage(color: maskColor).cropped(to: image.extent)
            return blend.outputImage ?? image
        }

        return normalizedAmount > 0 ? textured : image
    }

    /// ディヘイズ適用（霞除去）
    private static func applyDehaze(to image: CIImage, amount: Double) -> CIImage {
        guard abs(amount) > 0.0001 else { return image }

        // ディヘイズ = コントラスト強化 + 彩度強化 + わずかな暗化
        let normalizedAmount = clamp(amount, -1, 1)

        var output = image

        // コントラスト強化
        let contrastFilter = CIFilter.colorControls()
        contrastFilter.inputImage = output
        contrastFilter.contrast = Float(1 + normalizedAmount * 0.3)  // +30%まで
        contrastFilter.saturation = Float(1 + normalizedAmount * 0.2)  // +20%まで
        contrastFilter.brightness = Float(-normalizedAmount * 0.05)  // わずかに暗化
        output = contrastFilter.outputImage ?? output

        // 露出補正（霞除去で暗くなりすぎないように）
        if normalizedAmount > 0.5 {
            let exposureFilter = CIFilter.exposureAdjust()
            exposureFilter.inputImage = output
            exposureFilter.ev = Float(normalizedAmount * 0.1)
            output = exposureFilter.outputImage ?? output
        }

        return output
    }

    /// フィルムグレイン適用
    private static func applyGrain(to image: CIImage, intensity: Double) -> CIImage {
        guard abs(intensity) > 0.0001 else { return image }

        let noise = CIFilter.randomGenerator()
        guard var noiseImage = noise.outputImage else { return image }

        // ノイズをグレインらしく調整
        let whiten = CIFilter.colorMatrix()
        whiten.inputImage = noiseImage
        whiten.rVector = CIVector(x: 0.3, y: 0.3, z: 0.3, w: 0)
        whiten.gVector = CIVector(x: 0.3, y: 0.3, z: 0.3, w: 0)
        whiten.bVector = CIVector(x: 0.3, y: 0.3, z: 0.3, w: 0)
        whiten.aVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(intensity * 0.3))
        noiseImage = whiten.outputImage ?? noiseImage

        // 画像範囲に合わせてクロップ
        noiseImage = noiseImage.cropped(to: image.extent)

        // スクリーンブレンド
        let blend = CIFilter(name: "CIScreenBlendMode", parameters: [
            kCIInputImageKey: noiseImage,
            kCIInputBackgroundImageKey: image
        ])

        return blend?.outputImage ?? image
    }

    /// HSL調整適用（8色チャンネル別）
    private static func applyHSL(to image: CIImage, settings: HSLSettings) -> CIImage {
        // 各色チャンネルが全てデフォルト値かチェック
        let channels: [(HSLChannel, Double)] = [
            (settings.red, 0),
            (settings.orange, 30),
            (settings.yellow, 60),
            (settings.green, 120),
            (settings.aqua, 180),
            (settings.blue, 240),
            (settings.purple, 270),
            (settings.magenta, 300)
        ]

        var output = image

        for (channel, _) in channels {
            // このチャンネルに変更があるかチェック
            guard abs(channel.hue) > 0.01 || abs(channel.saturation) > 0.01 || abs(channel.luminance) > 0.01 else {
                continue
            }

            // 簡易実装: 全体に適用（本格的な実装では色マスクが必要）
            // 色相シフト
            if abs(channel.hue) > 0.01 {
                let hueAdjust = CIFilter.hueAdjust()
                hueAdjust.inputImage = output
                hueAdjust.angle = Float(channel.hue * .pi / 180.0) * 0.2  // 弱めに適用
                output = hueAdjust.outputImage ?? output
            }

            // 彩度調整
            if abs(channel.saturation) > 0.01 {
                let satAdjust = CIFilter.colorControls()
                satAdjust.inputImage = output
                satAdjust.saturation = Float(1 + channel.saturation / 100.0 * 0.3)  // 弱めに適用
                output = satAdjust.outputImage ?? output
            }

            // 輝度調整
            if abs(channel.luminance) > 0.01 {
                let lumAdjust = CIFilter.exposureAdjust()
                lumAdjust.inputImage = output
                lumAdjust.ev = Float(channel.luminance / 100.0 * 0.3)  // 弱めに適用
                output = lumAdjust.outputImage ?? output
            }
        }

        return output
    }

    /// スプリットトーニング適用
    private static func applySplitToning(to image: CIImage, settings: SplitToningSettings) -> CIImage {
        guard settings.highlightSaturation > 0.01 || settings.shadowSaturation > 0.01 else {
            return image
        }

        // 輝度マスク生成（ハイライト/シャドウ分離）
        let grayscale = CIFilter(name: "CIPhotoEffectNoir", parameters: [kCIInputImageKey: image])
        guard var mask = grayscale?.outputImage else { return image }

        // バランス調整（中間点シフト）
        if abs(settings.balance) > 0.01 {
            let gamma = CIFilter(name: "CIGammaAdjust", parameters: [
                kCIInputImageKey: mask,
                "inputPower": 1.0 - settings.balance / 200.0
            ])
            mask = gamma?.outputImage ?? mask
        }

        var output = image

        // ハイライトに色調適用
        if settings.highlightSaturation > 0.01 {
            let highlightColor = hsvToRGB(
                h: settings.highlightHue / 360.0,
                s: 1.0,
                v: 0.7
            )
            let tint = CIFilter(name: "CIColorMonochrome", parameters: [
                kCIInputImageKey: output,
                "inputColor": CIColor(red: CGFloat(highlightColor.r), green: CGFloat(highlightColor.g), blue: CGFloat(highlightColor.b)),
                "inputIntensity": settings.highlightSaturation / 200.0
            ])
            if let tinted = tint?.outputImage {
                let blend = CIFilter.blendWithMask()
                blend.inputImage = tinted
                blend.backgroundImage = output
                blend.maskImage = mask
                output = blend.outputImage ?? output
            }
        }

        // シャドウに色調適用
        if settings.shadowSaturation > 0.01 {
            let shadowColor = hsvToRGB(
                h: settings.shadowHue / 360.0,
                s: 1.0,
                v: 0.3
            )
            let tint = CIFilter(name: "CIColorMonochrome", parameters: [
                kCIInputImageKey: output,
                "inputColor": CIColor(red: CGFloat(shadowColor.r), green: CGFloat(shadowColor.g), blue: CGFloat(shadowColor.b)),
                "inputIntensity": settings.shadowSaturation / 200.0
            ])
            if let tinted = tint?.outputImage {
                // 反転マスク（シャドウ用）
                let invert = CIFilter(name: "CIColorInvert", parameters: [kCIInputImageKey: mask])
                if let invertedMask = invert?.outputImage {
                    let blend = CIFilter.blendWithMask()
                    blend.inputImage = tinted
                    blend.backgroundImage = output
                    blend.maskImage = invertedMask
                    output = blend.outputImage ?? output
                }
            }
        }

        return output
    }

    /// トーンカーブ適用（Master/R/G/B）
    private static func applyToneCurve(to image: CIImage, settings: ToneCurveSettings) -> CIImage {
        // デフォルト値（[0, 0.25, 0.5, 0.75, 1.0]）かチェック
        let isDefault = settings.master == .default &&
                        settings.red == .default &&
                        settings.green == .default &&
                        settings.blue == .default

        guard !isDefault else { return image }

        // CIColorCurvesフィルターを使用
        // 各チャンネルのポイントをCIVectorに変換
        _ = createCurveVector(from: settings.master.points)
        _ = createCurveVector(from: settings.red.points)
        _ = createCurveVector(from: settings.green.points)
        _ = createCurveVector(from: settings.blue.points)

        guard let filter = CIFilter(name: "CIToneCurve") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)

        // 5点制御: points[0]=0.0, points[1]=0.25, points[2]=0.5, points[3]=0.75, points[4]=1.0
        // CIToneCurveは各ポイントをCGPoint(x: input, y: output)で指定
        // Master curve適用
        if settings.master != .default {
            let pts = settings.master.points
            filter.setValue(CIVector(x: 0.0, y: pts[0]), forKey: "inputPoint0")
            filter.setValue(CIVector(x: 0.25, y: pts[1]), forKey: "inputPoint1")
            filter.setValue(CIVector(x: 0.5, y: pts[2]), forKey: "inputPoint2")
            filter.setValue(CIVector(x: 0.75, y: pts[3]), forKey: "inputPoint3")
            filter.setValue(CIVector(x: 1.0, y: pts[4]), forKey: "inputPoint4")
        }

        var output = filter.outputImage ?? image

        // RGB各チャンネルはCIColorMatrixで適用
        // （CIToneCurveはMasterのみなので、RGB別はカスタム実装が必要）
        // 簡易実装: RGBチャンネルもCIToneCurveで全体に適用（本格的にはカスタムKernel必要）
        if settings.red != .default {
            let redFilter = CIFilter(name: "CIToneCurve")
            redFilter?.setValue(output, forKey: kCIInputImageKey)
            let pts = settings.red.points
            redFilter?.setValue(CIVector(x: 0.0, y: pts[0]), forKey: "inputPoint0")
            redFilter?.setValue(CIVector(x: 0.25, y: pts[1]), forKey: "inputPoint1")
            redFilter?.setValue(CIVector(x: 0.5, y: pts[2]), forKey: "inputPoint2")
            redFilter?.setValue(CIVector(x: 0.75, y: pts[3]), forKey: "inputPoint3")
            redFilter?.setValue(CIVector(x: 1.0, y: pts[4]), forKey: "inputPoint4")
            output = redFilter?.outputImage ?? output
        }

        if settings.green != .default {
            let greenFilter = CIFilter(name: "CIToneCurve")
            greenFilter?.setValue(output, forKey: kCIInputImageKey)
            let pts = settings.green.points
            greenFilter?.setValue(CIVector(x: 0.0, y: pts[0]), forKey: "inputPoint0")
            greenFilter?.setValue(CIVector(x: 0.25, y: pts[1]), forKey: "inputPoint1")
            greenFilter?.setValue(CIVector(x: 0.5, y: pts[2]), forKey: "inputPoint2")
            greenFilter?.setValue(CIVector(x: 0.75, y: pts[3]), forKey: "inputPoint3")
            greenFilter?.setValue(CIVector(x: 1.0, y: pts[4]), forKey: "inputPoint4")
            output = greenFilter?.outputImage ?? output
        }

        if settings.blue != .default {
            let blueFilter = CIFilter(name: "CIToneCurve")
            blueFilter?.setValue(output, forKey: kCIInputImageKey)
            let pts = settings.blue.points
            blueFilter?.setValue(CIVector(x: 0.0, y: pts[0]), forKey: "inputPoint0")
            blueFilter?.setValue(CIVector(x: 0.25, y: pts[1]), forKey: "inputPoint1")
            blueFilter?.setValue(CIVector(x: 0.5, y: pts[2]), forKey: "inputPoint2")
            blueFilter?.setValue(CIVector(x: 0.75, y: pts[3]), forKey: "inputPoint3")
            blueFilter?.setValue(CIVector(x: 1.0, y: pts[4]), forKey: "inputPoint4")
            output = blueFilter?.outputImage ?? output
        }

        return output
    }

    /// トーンカーブポイントをCIVectorに変換（5点）
    private static func createCurveVector(from points: [Double]) -> CIVector {
        // 5点制御: [0, 0.25, 0.5, 0.75, 1.0]
        guard points.count == 5 else {
            return CIVector(values: [0, 0.25, 0.5, 0.75, 1.0], count: 5)
        }
        let values = points.map { CGFloat(clamp($0, 0, 1)) }
        return CIVector(values: values, count: 5)
    }

    /// HSV → RGB変換
    private static func hsvToRGB(h: Double, s: Double, v: Double) -> (r: Double, g: Double, b: Double) {
        let c = v * s
        let x = c * (1 - abs((h * 6).truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c

        var r: Double = 0, g: Double = 0, b: Double = 0

        let hSextant = Int(h * 6)
        switch hSextant {
        case 0: (r, g, b) = (c, x, 0)
        case 1: (r, g, b) = (x, c, 0)
        case 2: (r, g, b) = (0, c, x)
        case 3: (r, g, b) = (0, x, c)
        case 4: (r, g, b) = (x, 0, c)
        case 5: (r, g, b) = (c, 0, x)
        default: (r, g, b) = (0, 0, 0)
        }

        return (r + m, g + m, b + m)
    }

    private static func clamp(_ value: Double, _ minValue: Double, _ maxValue: Double) -> Double {
        min(max(value, minValue), maxValue)
    }
}

struct PhotoEditorView: View {
    private enum StorageKeys {
        static let presets = "photo_editor_presets_v1"
    }

    let originalImage: UIImage
    var sourcePhotoGroup: PhotoGroup? = nil  // 編集元のPhotoGroup（保存時に使用）

    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext

    @State private var selectedCategory: EditorCategory = .light
    @State private var settings: PhotoEditorSettings = .default
    @State private var previewSourceImage: UIImage?
    @State private var previewImage: UIImage?

    @State private var isRendering: Bool = false
    @State private var isExporting: Bool = false
    @State private var isSavingToApp: Bool = false
    @State private var renderTask: Task<Void, Never>?

    @State private var presets: [PhotoEditorPreset] = []
    @State private var showSavePresetAlert: Bool = false
    @State private var presetName: String = ""

    @State private var showResultAlert: Bool = false
    @State private var resultMessage: String = ""
    @State private var showRatingDialog: Bool = false
    @State private var pendingRating: Int = 3
    @State private var imageAnalysis: ImageAnalysisResult?
    @State private var predictedSettings: PhotoEditorSettings?
    @State private var isAutoEditMode: Bool = false

    @State private var imageWriteCoordinator: ImageWriteCoordinator?
    @GestureState private var showingOriginalWhilePress: Bool = false

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()

                GeometryReader { geometry in
                    VStack(spacing: 0) {
                        previewArea
                            .frame(height: geometry.size.height * 0.42)

                        controlsArea
                            .frame(maxHeight: geometry.size.height * 0.58)
                    }
                }

                if isRendering || isExporting || isSavingToApp {
                    ProgressView()
                        .scaleEffect(1.2)
                        .padding(22)
                        .background(Color(.systemGray5).opacity(0.9))
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
                            applyAutoEdit()
                        } label: {
                            Image(systemName: isAutoEditMode ? "sparkles" : "sparkle")
                                .foregroundColor(isAutoEditMode ? .purple : .primary)
                        }

                        Button {
                            settings.autoWhiteBalance.toggle()
                            if settings.autoWhiteBalance {
                                settings.temperature = 0
                                settings.tint = 0
                            }
                        } label: {
                            Image(systemName: settings.autoWhiteBalance ? "wand.and.stars.inverse" : "wand.and.stars")
                                .foregroundColor(settings.autoWhiteBalance ? .blue : .primary)
                        }

                        Button {
                            resetAll()
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                        }

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
            Text("編集の品質を評価してください（1-5星）")
        }
    }

    private var previewArea: some View {
        ZStack {
            let imageToShow = showingOriginalWhilePress ? originalImage : (previewImage ?? originalImage)
            Image(uiImage: imageToShow)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(.horizontal, 10)

            if showingOriginalWhilePress {
                VStack {
                    HStack {
                        Text("ORIGINAL")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.black.opacity(0.7))
                            .foregroundColor(.white)
                            .cornerRadius(8)
                        Spacer()
                    }
                    Spacer()
                }
                .padding(16)
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($showingOriginalWhilePress) { _, state, _ in
                    state = true
                }
        )
    }

    private var controlsArea: some View {
        VStack(spacing: MinimalSpacing.md) {
            // アイコングリッド
            IconGridSelector(selectedCategory: $selectedCategory)

            // 選択されたカテゴリのコントロール
            ScrollView {
                VStack(alignment: .leading, spacing: MinimalSpacing.md) {
                    categoryControls
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(MinimalSpacing.md)
        .background(MinimalTheme.Background.surface.opacity(0.95))
    }

    @ViewBuilder
    private var categoryControls: some View {
        switch selectedCategory {
        case .light:
            sliderRow(title: "露出", value: $settings.exposureEV, range: -2...2, step: 0.05)
            sliderRow(title: "コントラスト", value: $settings.contrast, range: 0.5...1.6, step: 0.02)
            sliderRow(title: "ハイライト", value: $settings.highlightRecovery, range: 0...1, step: 0.02)
            sliderRow(title: "シャドウ", value: $settings.shadowBoost, range: 0...1, step: 0.02)

        case .color:
            HStack {
                Button(action: {
                    settings.autoWhiteBalance.toggle()
                    if settings.autoWhiteBalance {
                        // Auto WB適用時に温度/ティントをリセット
                        settings.temperature = 0
                        settings.tint = 0
                    }
                }) {
                    HStack {
                        Image(systemName: settings.autoWhiteBalance ? "wand.and.stars" : "wand.and.stars.inverse")
                            .font(.caption.weight(.bold))
                        Text("自動ホワイトバランス")
                            .font(.caption.weight(.semibold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(settings.autoWhiteBalance ? Color.blue : Color.gray.opacity(0.2))
                    .foregroundColor(settings.autoWhiteBalance ? .white : .primary)
                    .cornerRadius(8)
                }
                Spacer()
            }

            sliderRow(title: "色温度", value: $settings.temperature, range: -2000...2000, step: 25)
            sliderRow(title: "ティント", value: $settings.tint, range: -150...150, step: 5)
            sliderRow(title: "彩度", value: $settings.saturation, range: 0...2, step: 0.02)
            sliderRow(title: "自然な彩度", value: $settings.vibrance, range: -1...1, step: 0.02)
            sliderRow(title: "モノクロ", value: $settings.monochrome, range: 0...1, step: 0.02)

            Toggle("IR赤み自動補正", isOn: $settings.irAutoCorrect)
                .toggleStyle(SwitchToggleStyle(tint: .blue))
            if settings.irAutoCorrect {
                sliderRow(title: "IR補正強度", value: $settings.irCorrectionStrength, range: 0...1, step: 0.02)
            }
            Button("IR補正プリセット") {
                applyInfraredPreset()
            }
            .font(.caption.weight(.bold))

        case .effects:
            sliderRow(title: "明瞭度", value: $settings.clarity, range: 0...2, step: 0.05)
            sliderRow(title: "テクスチャ", value: $settings.texture, range: -1...1, step: 0.05)
            sliderRow(title: "ディヘイズ", value: $settings.dehaze, range: -1...1, step: 0.05)
            sliderRow(title: "シャープネス", value: $settings.sharpness, range: 0...2, step: 0.05)
            sliderRow(title: "ノイズ除去", value: $settings.noiseReduction, range: 0...1, step: 0.02)
            sliderRow(title: "ヴィネット", value: $settings.vignette, range: -1...1, step: 0.02)
            sliderRow(title: "フィルムグレイン", value: $settings.grain, range: 0...1, step: 0.02)

        case .hsl:
            hslControls

        case .splitToning:
            splitToningControls

        case .toneCurve:
            toneCurveControls

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
        let xMax = max(0.01, 1 - crop.wrappedValue.width)
        let yMax = max(0.01, 1 - crop.wrappedValue.height)
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
            sliderRow(title: "X", value: crop.x, range: 0...xMax, step: min(0.01, xMax))
            sliderRow(title: "Y", value: crop.y, range: 0...yMax, step: min(0.01, yMax))
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

    private var hslControls: some View {
        let hslBinding = Binding(get: { settings.hsl }, set: { settings.hsl = $0 })
        return VStack(alignment: .leading, spacing: 16) {
            Text("8色チャンネル別調整")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)

            hslChannelSection(title: "Red", channel: hslBinding.red)
            hslChannelSection(title: "Orange", channel: hslBinding.orange)
            hslChannelSection(title: "Yellow", channel: hslBinding.yellow)
            hslChannelSection(title: "Green", channel: hslBinding.green)
            hslChannelSection(title: "Aqua", channel: hslBinding.aqua)
            hslChannelSection(title: "Blue", channel: hslBinding.blue)
            hslChannelSection(title: "Purple", channel: hslBinding.purple)
            hslChannelSection(title: "Magenta", channel: hslBinding.magenta)
        }
    }

    private func hslChannelSection(title: String, channel: Binding<HSLChannel>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundColor(.gray)

            sliderRow(title: "色相", value: channel.hue, range: -180...180, step: 1)
            sliderRow(title: "彩度", value: channel.saturation, range: -100...100, step: 1)
            sliderRow(title: "輝度", value: channel.luminance, range: -100...100, step: 1)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private var splitToningControls: some View {
        let stBinding = Binding(get: { settings.splitToning }, set: { settings.splitToning = $0 })
        return VStack(alignment: .leading, spacing: 16) {
            Text("ハイライト")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)

            sliderRow(title: "色相", value: stBinding.highlightHue, range: 0...360, step: 1)
            sliderRow(title: "彩度", value: stBinding.highlightSaturation, range: 0...100, step: 1)

            Divider()
                .padding(.vertical, 8)

            Text("シャドウ")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)

            sliderRow(title: "色相", value: stBinding.shadowHue, range: 0...360, step: 1)
            sliderRow(title: "彩度", value: stBinding.shadowSaturation, range: 0...100, step: 1)

            Divider()
                .padding(.vertical, 8)

            sliderRow(title: "バランス", value: stBinding.balance, range: -100...100, step: 1)
        }
    }

    private var toneCurveControls: some View {
        let tcBinding = Binding(get: { settings.toneCurve }, set: { settings.toneCurve = $0 })
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("トーンカーブ（5点制御）")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Button("リセット") {
                    settings.toneCurve = .default
                }
                .font(.caption.weight(.bold))
            }

            // Masterチャンネル
            toneCurveChannelSection(title: "Master", curve: tcBinding.master, color: .white)

            Divider().padding(.vertical, 8)

            // Redチャンネル
            toneCurveChannelSection(title: "Red", curve: tcBinding.red, color: .red)

            Divider().padding(.vertical, 8)

            // Greenチャンネル
            toneCurveChannelSection(title: "Green", curve: tcBinding.green, color: .green)

            Divider().padding(.vertical, 8)

            // Blueチャンネル
            toneCurveChannelSection(title: "Blue", curve: tcBinding.blue, color: .blue)

            Text("📝 0.0=黒, 0.25=ダークトーン, 0.5=中間, 0.75=ハイライト, 1.0=白")
                .font(.caption2)
                .foregroundColor(.gray)
                .padding(.top, 8)
        }
    }

    private func toneCurveChannelSection(title: String, curve: Binding<ToneCurve>, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundColor(color.opacity(0.8))

            // 5点制御: points[0]=0.0, points[1]=0.25, points[2]=0.5, points[3]=0.75, points[4]=1.0
            sliderRow(title: "0.0 (黒)", value: curve.points[0], range: 0...1, step: 0.01)
            sliderRow(title: "0.25 (ダーク)", value: curve.points[1], range: 0...1, step: 0.01)
            sliderRow(title: "0.5 (中間)", value: curve.points[2], range: 0...1, step: 0.01)
            sliderRow(title: "0.75 (ハイライト)", value: curve.points[3], range: 0...1, step: 0.01)
            sliderRow(title: "1.0 (白)", value: curve.points[4], range: 0...1, step: 0.01)
        }
        .padding(12)
        .background(Color(red: 0.15, green: 0.15, blue: 0.17))
        .cornerRadius(12)
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
                    .background(Color(.secondarySystemBackground))
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
        isAutoEditMode = false
        predictedSettings = nil
    }

    private func applyAutoEdit() {
        // 画像を分析
        guard let analysis = ImageAnalyzer.analyze(image: originalImage) else {
            return
        }

        imageAnalysis = analysis

        // 学習データを取得
        let learningData = AutoEditEvaluation.fetchForTraining(minRating: 4, context: viewContext)

        // 設定を提案
        let suggested = AutoEditEngine.suggestSettings(for: analysis, learningData: learningData)

        // 予測設定を保存（後で評価記録に使用）
        predictedSettings = suggested

        // 設定を適用
        settings = suggested
        isAutoEditMode = true
    }

    private func applyInfraredPreset() {
        settings.irAutoCorrect = true
        settings.irCorrectionStrength = 0.78
        settings.temperature = -850
        settings.highlightRecovery = max(settings.highlightRecovery, 0.18)
    }

    private func saveToAppStorage() {
        if isSavingToApp { return }
        isSavingToApp = true

        // PhotoGroupがある場合は新バージョンとして保存、ない場合は従来通りEditedPhotoとして保存
        if sourcePhotoGroup != nil {
            showRatingDialog = true
        } else {
            showRatingDialog = true
        }
    }

    private func confirmSaveWithRating(_ rating: Int) {
        let current = settings
        Task {
            let rendered = PhotoEditorRenderer.render(image: originalImage, settings: current)

            await MainActor.run {
                guard let rendered else {
                    isSavingToApp = false
                    resultMessage = "保存に失敗しました"
                    showResultAlert = true
                    return
                }

                // 画像をJPEGエンコード（80%品質）
                guard let imageData = rendered.jpegData(compressionQuality: 0.8) else {
                    isSavingToApp = false
                    resultMessage = "画像のエンコードに失敗しました"
                    showResultAlert = true
                    return
                }

                // サムネイル生成（300x300）
                let thumbnailSize = CGSize(width: 300, height: 300)
                let thumbnail = rendered.preparingThumbnail(of: thumbnailSize)
                let thumbnailData = thumbnail?.jpegData(compressionQuality: 0.7)

                // 設定をJSONエンコード
                guard let settingsData = try? JSONEncoder().encode(current),
                      let settingsJSON = String(data: settingsData, encoding: .utf8) else {
                    isSavingToApp = false
                    resultMessage = "設定のエンコードに失敗しました"
                    showResultAlert = true
                    return
                }

                // PhotoGroupがある場合は新バージョンとして保存
                if let group = sourcePhotoGroup {
                    let version = PhotoVersion(context: viewContext)
                    version.id = UUID()
                    version.originalPhotoID = group.id
                    version.versionNumber = Int32(group.nextVersionNumber())
                    version.imageData = imageData
                    version.thumbnailData = thumbnailData
                    version.settingsJSON = settingsJSON
                    version.createdAt = Date()
                    version.updatedAt = Date()
                    version.userRating = Int16(rating)
                    version.isOriginal = false
                    version.group = group

                    // latestVersionを更新
                    group.latestVersion = version
                } else {
                    // PhotoGroupがない場合は従来通りEditedPhotoとして保存
                    let photo = EditedPhoto(context: viewContext)
                    photo.id = UUID()
                    photo.createdAt = Date()
                    photo.imageData = imageData
                    photo.thumbnailData = thumbnailData
                    photo.settingsJSON = settingsJSON
                    photo.userRating = Int16(rating)
                }

                // 自動編集モードの場合、評価を記録
                if isAutoEditMode,
                   let predicted = predictedSettings,
                   let analysis = imageAnalysis {
                    AutoEditEngine.recordEvaluation(
                        predicted: predicted,
                        final: current,
                        rating: rating,
                        analysis: analysis,
                        context: viewContext
                    )
                }

                do {
                    try viewContext.save()
                    isSavingToApp = false
                    let modeInfo = isAutoEditMode ? "（自動編集）" : ""
                    let saveTypeInfo = sourcePhotoGroup != nil ? "新バージョンとして" : "アプリ内に"
                    resultMessage = "\(saveTypeInfo)保存しました\(modeInfo)（\(rating)星）"
                    showResultAlert = true

                    // 保存後にリセット
                    isAutoEditMode = false
                    predictedSettings = nil
                } catch {
                    isSavingToApp = false
                    resultMessage = "保存に失敗しました: \(error.localizedDescription)"
                    showResultAlert = true
                }
            }
        }
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

