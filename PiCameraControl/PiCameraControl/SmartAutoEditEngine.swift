import Foundation
import CoreData

#if canImport(UIKit)
import UIKit
#endif

// MARK: - SmartAutoEditEngine

/// 統合スマート自動編集エンジン
/// IR検出・WB検出・リファレンスマッチング・既存AutoEdit学習を1つに統合
enum SmartAutoEditEngine {

    // MARK: - SmartAnalysis

    struct SmartAnalysis {
        let base: ImageAnalysisResult
        let irScore: Double                // 0-1: IR赤かぶりの可能性
        let wbDeviation: Double            // 0-1: WBのズレ度合い
        let wbCorrection: (temperature: Double, tint: Double)
        let appliedCorrections: Set<CorrectionType>
    }

    enum CorrectionType: String, Codable, CaseIterable {
        case autoEdit      // ヒストグラムベースのAI編集
        case whiteBalance  // 自動ホワイトバランス
        case irCorrection  // IR赤かぶり補正
        case reference     // リファレンス写真マッチング
        case learning      // 学習データ微調整
    }

    // MARK: - Smart Analysis

    /// 画像を包括的に分析し、IR/WBの問題を検出
    static func analyze(image: UIImage) -> SmartAnalysis? {
        guard let baseAnalysis = ImageAnalyzer.analyze(image: image) else {
            return nil
        }

        let r = baseAnalysis.colorBalance.r
        let g = baseAnalysis.colorBalance.g
        let b = baseAnalysis.colorBalance.b

        // IR赤かぶり検出
        let irScore = detectIRContamination(r: r, g: g, b: b)

        // WBズレ検出
        let (wbDeviation, wbCorrection) = detectWhiteBalanceDeviation(r: r, g: g, b: b)

        var corrections: Set<CorrectionType> = [.autoEdit]
        if irScore > 0.4 {
            corrections.insert(.irCorrection)
        }
        if wbDeviation > 0.15 {
            corrections.insert(.whiteBalance)
        }

        return SmartAnalysis(
            base: baseAnalysis,
            irScore: irScore,
            wbDeviation: wbDeviation,
            wbCorrection: wbCorrection,
            appliedCorrections: corrections
        )
    }

    // MARK: - IR Detection

    /// IR赤かぶりスコアを計算 (0=正常, 1=強いIR汚染)
    private static func detectIRContamination(r: Double, g: Double, b: Double) -> Double {
        guard g > 0.01, b > 0.01 else { return 0 }

        let rgRatio = r / g
        let gbRatio = g / b

        // R/G比 > 1.5 かつ G/B比 > 1.1 → IR赤かぶり高確率
        if rgRatio > 1.5 && gbRatio > 1.1 {
            let rgScore = min((rgRatio - 1.0) / 1.5, 1.0)
            let gbScore = min((gbRatio - 1.0) / 0.5, 1.0)
            return (rgScore * 0.7 + gbScore * 0.3)
        }

        // 軽度のIR傾向
        if rgRatio > 1.2 {
            return min((rgRatio - 1.0) / 2.0, 0.4)
        }

        return 0
    }

    // MARK: - WB Detection

    /// ホワイトバランスのズレを検出
    private static func detectWhiteBalanceDeviation(r: Double, g: Double, b: Double) -> (deviation: Double, correction: (temperature: Double, tint: Double)) {
        let avg = (r + g + b) / 3.0
        guard avg > 0.01 else { return (0, (0, 0)) }

        // RGB平均からの偏差
        let rDev = (r - avg) / avg
        let gDev = (g - avg) / avg
        let bDev = (b - avg) / avg

        let deviation = max(abs(rDev), abs(gDev), abs(bDev))

        // 色温度補正: 青い → 暖色化(+)、赤い → 寒色化(-)
        var temperature = 0.0
        if r > b {
            temperature = -(r - b) * 2000.0  // 赤い → 寒色化
        } else {
            temperature = (b - r) * 2000.0    // 青い → 暖色化
        }
        temperature = max(-2000, min(2000, temperature))

        // ティント補正: グリーン偏り → マゼンタ(+)、マゼンタ偏り → グリーン(-)
        var tint = 0.0
        if g > (r + b) / 2.0 {
            tint = (g - (r + b) / 2.0) * 150.0  // グリーン → マゼンタ補正
        } else {
            tint = -(((r + b) / 2.0) - g) * 150.0  // マゼンタ → グリーン補正
        }
        tint = max(-150, min(150, tint))

        return (deviation, (temperature, tint))
    }

    // MARK: - Smart Suggest Settings

    /// 統合スマート自動編集: 分析結果に基づいて最適設定を提案
    static func suggestSettings(
        analysis: SmartAnalysis,
        learningData: [AutoEditEvaluation],
        referenceAnalysis: SmartAnalysis? = nil
    ) -> (settings: PhotoEditorSettings, corrections: Set<CorrectionType>) {

        var settings = PhotoEditorSettings.default
        var corrections = analysis.appliedCorrections

        // 1. ベース補正（既存のヒストグラム分析）
        applyBaseCorrections(&settings, analysis: analysis.base)

        // 2. IR検出 → IR補正
        if analysis.irScore > 0.4 {
            settings.irAutoCorrect = true
            settings.irCorrectionStrength = min(analysis.irScore * 1.2, 1.0)
            corrections.insert(.irCorrection)
        } else if analysis.wbDeviation > 0.15 {
            // 3. WBズレ検出 → 自動WB適用 (IRでない場合のみ)
            settings.autoWhiteBalance = true
            settings.temperature = analysis.wbCorrection.temperature * 0.6  // 控えめに適用
            settings.tint = analysis.wbCorrection.tint * 0.6
            corrections.insert(.whiteBalance)
        }

        // 4. リファレンス写真マッチング
        if let ref = referenceAnalysis {
            applyReferenceMatching(&settings, current: analysis, reference: ref)
            corrections.insert(.reference)
        }

        // 5. 学習データからの微調整
        let highRatedData = learningData.filter { $0.userRating >= 4 }
        if !highRatedData.isEmpty {
            applyLearningAdjustments(&settings, learningData: highRatedData, analysis: analysis.base)
            corrections.insert(.learning)
        }

        return (settings, corrections)
    }

    // MARK: - Base Corrections

    private static func applyBaseCorrections(_ settings: inout PhotoEditorSettings, analysis: ImageAnalysisResult) {
        let hist = analysis.histogram

        // 露出補正
        if hist.shadowClipping > 0.1 {
            settings.exposureEV = 0.5 + hist.shadowClipping
            settings.shadowBoost = 0.4
        } else if hist.highlightClipping > 0.1 {
            settings.exposureEV = -0.5 - hist.highlightClipping
            settings.highlightRecovery = 0.5
        } else if analysis.exposureScore < 0.5 {
            settings.exposureEV = (0.5 - analysis.exposureScore) * 2.0
            settings.shadowBoost = 0.3
        }

        // コントラスト補正
        if hist.luminanceStdDev < 0.15 {
            settings.contrast = 1.3
            settings.clarity = 0.4
        } else if hist.luminanceStdDev > 0.35 {
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
            settings.contrast = 1.25
            settings.clarity = 0.3
        }
    }

    // MARK: - Reference Matching

    /// リファレンス写真との特徴差を計算し設定に反映
    static func applyReferenceMatching(
        _ settings: inout PhotoEditorSettings,
        current: SmartAnalysis,
        reference: SmartAnalysis
    ) {
        let cur = current.base
        let ref = reference.base

        // 明るさ差 → exposureEV調整
        let brightnessDiff = ref.brightness - cur.brightness
        settings.exposureEV += clamp(brightnessDiff * 3.0, -1.5, 1.5)

        // コントラスト差 → contrast調整
        let contrastDiff = ref.contrast - cur.contrast
        settings.contrast += clamp(contrastDiff * 1.5, -0.3, 0.3)

        // 彩度差 → saturation調整
        let satDiff = ref.saturation - cur.saturation
        settings.saturation += clamp(satDiff * 1.5, -0.5, 0.5)

        // 色バランス差 → temperature/tint調整
        let rDiff = ref.colorBalance.r - cur.colorBalance.r
        let bDiff = ref.colorBalance.b - cur.colorBalance.b
        let gDiff = ref.colorBalance.g - cur.colorBalance.g

        settings.temperature += clamp((bDiff - rDiff) * 1500.0, -1000, 1000)
        settings.tint += clamp((gDiff - (rDiff + bDiff) / 2.0) * 100.0, -75, 75)

        // ダイナミックレンジ差 → highlight/shadow調整
        let drDiff = ref.histogram.dynamicRange - cur.histogram.dynamicRange
        if drDiff > 0.1 {
            settings.highlightRecovery += clamp(drDiff * 0.5, 0, 0.3)
            settings.shadowBoost += clamp(drDiff * 0.3, 0, 0.3)
        }

        // 全値を安全範囲にクランプ
        settings.exposureEV = clamp(settings.exposureEV, -2, 2)
        settings.contrast = clamp(settings.contrast, 0.5, 1.6)
        settings.saturation = clamp(settings.saturation, 0, 2)
        settings.highlightRecovery = clamp(settings.highlightRecovery, 0, 1)
        settings.shadowBoost = clamp(settings.shadowBoost, 0, 1)
        settings.temperature = clamp(settings.temperature, -2000, 2000)
        settings.tint = clamp(settings.tint, -150, 150)
    }

    // MARK: - Learning Adjustments

    private static func applyLearningAdjustments(
        _ settings: inout PhotoEditorSettings,
        learningData: [AutoEditEvaluation],
        analysis: ImageAnalysisResult
    ) {
        // 類似画像の学習データを重視
        let similarData = learningData.filter {
            abs($0.imageBrightness - analysis.brightness) < 0.2
        }
        let targetData = similarData.isEmpty ? learningData : similarData
        guard !targetData.isEmpty else { return }

        var avgExposure = 0.0
        var avgContrast = 0.0
        var avgSaturation = 0.0
        var count = 0.0

        for data in targetData {
            if let finalSettings = data.finalSettings {
                avgExposure += finalSettings.exposureEV
                avgContrast += finalSettings.contrast
                avgSaturation += finalSettings.saturation
                count += 1
            }
        }

        guard count > 0 else { return }
        avgExposure /= count
        avgContrast /= count
        avgSaturation /= count

        // 学習データで微調整（20%の重み）
        settings.exposureEV = settings.exposureEV * 0.8 + avgExposure * 0.2
        settings.contrast = settings.contrast * 0.8 + avgContrast * 0.2
        settings.saturation = settings.saturation * 0.8 + avgSaturation * 0.2
    }

    // MARK: - Record Evaluation

    /// スマート編集の評価を記録（拡張版）
    static func recordEvaluation(
        predicted: PhotoEditorSettings,
        final settings: PhotoEditorSettings,
        rating: Int,
        analysis: SmartAnalysis,
        corrections: Set<CorrectionType>,
        referenceAnalysis: SmartAnalysis?,
        context: NSManagedObjectContext
    ) {
        guard let predictedJSON = try? JSONEncoder().encode(predicted),
              let predictedString = String(data: predictedJSON, encoding: .utf8),
              let finalJSON = try? JSONEncoder().encode(settings),
              let finalString = String(data: finalJSON, encoding: .utf8) else {
            return
        }

        let evaluation = AutoEditEvaluation(context: context)
        evaluation.id = UUID()
        evaluation.createdAt = Date()
        evaluation.predictedSettingsJSON = predictedString
        evaluation.finalSettingsJSON = finalString
        evaluation.userRating = Int16(rating)
        evaluation.imageBrightness = analysis.base.brightness
        evaluation.imageContrast = analysis.base.contrast
        evaluation.imageSaturation = analysis.base.saturation

        // スマート編集決定記録
        let decisionInfo: [String: Any] = [
            "corrections": corrections.map { $0.rawValue },
            "irScore": analysis.irScore,
            "wbDeviation": analysis.wbDeviation
        ]
        if let decisionData = try? JSONSerialization.data(withJSONObject: decisionInfo),
           let decisionString = String(data: decisionData, encoding: .utf8) {
            evaluation.smartEditDecisionJSON = decisionString
        }

        // リファレンス分析記録
        if let ref = referenceAnalysis {
            let refInfo: [String: Double] = [
                "brightness": ref.base.brightness,
                "contrast": ref.base.contrast,
                "saturation": ref.base.saturation,
                "irScore": ref.irScore,
                "wbDeviation": ref.wbDeviation
            ]
            if let refData = try? JSONSerialization.data(withJSONObject: refInfo),
               let refString = String(data: refData, encoding: .utf8) {
                evaluation.referenceAnalysisJSON = refString
            }
        }

        try? context.save()

        #if DEBUG
        let correctionNames = corrections.map { $0.rawValue }.joined(separator: ", ")
        print("Smart Edit: Rating \(rating) | Corrections: \(correctionNames) | IR: \(String(format: "%.2f", analysis.irScore)) | WB: \(String(format: "%.2f", analysis.wbDeviation))")
        #endif
    }

    // MARK: - Similarity Score

    /// 編集結果とリファレンス写真の類似度スコアを計算 (0〜100)
    /// 明るさ(30%), コントラスト(20%), 彩度(20%), 色バランス(30%) の加重平均
    static func calculateSimilarityScore(edited: SmartAnalysis, reference: SmartAnalysis) -> Int {
        let e = edited.base
        let r = reference.base

        // 明るさ類似度 (0-1, 差が小さいほど1に近い)
        let brightnessSim = 1.0 - clamp(abs(e.brightness - r.brightness) * 2.0, 0, 1)

        // コントラスト類似度
        let contrastSim = 1.0 - clamp(abs(e.contrast - r.contrast) * 2.0, 0, 1)

        // 彩度類似度
        let saturationSim = 1.0 - clamp(abs(e.saturation - r.saturation) * 2.0, 0, 1)

        // 色バランス類似度 (RGB各チャンネルの差の平均)
        let rDiff = abs(e.colorBalance.r - r.colorBalance.r)
        let gDiff = abs(e.colorBalance.g - r.colorBalance.g)
        let bDiff = abs(e.colorBalance.b - r.colorBalance.b)
        let colorSim = 1.0 - clamp((rDiff + gDiff + bDiff) / 3.0 * 3.0, 0, 1)

        // 加重平均
        let score = brightnessSim * 0.30 + contrastSim * 0.20 + saturationSim * 0.20 + colorSim * 0.30
        return Int(clamp(score * 100, 0, 100))
    }

    /// UIImageペアから類似度スコアを計算（便利メソッド）
    static func calculateSimilarityScore(editedImage: UIImage, referenceImage: UIImage) -> Int? {
        guard let editedAnalysis = analyze(image: editedImage),
              let referenceAnalysis = analyze(image: referenceImage) else {
            return nil
        }
        return calculateSimilarityScore(edited: editedAnalysis, reference: referenceAnalysis)
    }

    // MARK: - Helpers

    private static func clamp(_ value: Double, _ lo: Double, _ hi: Double) -> Double {
        min(hi, max(lo, value))
    }
}
