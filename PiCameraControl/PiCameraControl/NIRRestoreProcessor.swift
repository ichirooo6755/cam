import CoreImage
import CoreImage.CIFilterBuiltins
#if canImport(UIKit)
import UIKit
#endif

/// IRフィルター越し撮影画像を自然なRGBに復元するアダプティブプロセッサ。
///
/// 処理フロー（写真ごとに毎回分析して最適値を計算）:
///   1. ChannelStats — R/G/B それぞれの平均・黒点・白点を取得
///   2. adaptive levels — 黒点〜白点を 0〜1 にリニアマップ
///   3. adaptive white balance — R が過剰な分だけ G/B を持ち上げ
///   4. LUT colorization — nir_to_rgb.cube で統計ベースの色付け
///   5. saturation recover — 脱色された NIR 画像に彩度を復元
final class NIRRestoreProcessor {

    // MARK: - Public entry point

    /// intensity: 0.0=補正なし  1.0=フル補正
    static func restore(_ input: CIImage, intensity: Double = 1.0) -> CIImage {
        let stats = channelStats(input)
        var img   = input

        img = applyLevels(img, stats: stats)
        img = applyWhiteBalance(img, stats: stats)
        img = applyLUTColorization(img)
        img = recoverSaturation(img, amount: 0.35)

        guard intensity < 0.999 else { return img }
        return blend(original: input, processed: img, alpha: Float(intensity))
    }

    // MARK: - 1. Channel Statistics

    struct ChannelStats {
        let rMean, gMean, bMean: Float
        let rBlack, rWhite: Float   // 黒点・白点（2%ile / 98%ile 相当）
        let gBlack, gWhite: Float
        let bBlack, bWhite: Float
    }

    private static func channelStats(_ image: CIImage) -> ChannelStats {
        // CIAreaAverage で平均色を取得（高速）
        let ctx = CIContext()
        let avg = image.applyingFilter("CIAreaAverage",
                                        parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
        var bitmap = [Float](repeating: 0, count: 4)
        ctx.render(avg,
                   toBitmap: &bitmap,
                   rowBytes: 16,
                   bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                   format: .RGBAf,
                   colorSpace: nil)
        let rMean = bitmap[0]; let gMean = bitmap[1]; let bMean = bitmap[2]

        // 黒点・白点：平均を基点に経験的な幅で推定
        // （histogram が取れない場合のフォールバック）
        func estimateRange(_ mean: Float) -> (black: Float, white: Float) {
            let halfRange = min(mean, 1 - mean) * 0.85 + 0.05
            return (black: max(0, mean - halfRange),
                    white: min(1, mean + halfRange))
        }

        let rRange = estimateRange(rMean)
        let gRange = estimateRange(gMean)
        let bRange = estimateRange(bMean)

        return ChannelStats(
            rMean: rMean, gMean: gMean, bMean: bMean,
            rBlack: rRange.black, rWhite: rRange.white,
            gBlack: gRange.black, gWhite: gRange.white,
            bBlack: bRange.black, bWhite: bRange.white
        )
    }

    // MARK: - 2. Adaptive Levels（黒点〜白点を 0〜1 にリマップ）

    private static func applyLevels(_ image: CIImage, stats: ChannelStats) -> CIImage {
        // チャンネルごとに独立してレベル補正
        // y = (x - black) / (white - black)
        let eps: Float = 1e-4
        func slope(_ black: Float, _ white: Float) -> Float {
            1.0 / max(white - black, eps)
        }
        func intercept(_ black: Float, _ white: Float) -> Float {
            -black / max(white - black, eps)
        }

        let rSlope = slope(stats.rBlack, stats.rWhite)
        let gSlope = slope(stats.gBlack, stats.gWhite)
        let bSlope = slope(stats.bBlack, stats.bWhite)

        // CIColorPolynomial: output = a0 + a1*in + a2*in² + a3*in³
        // 線形なので a1=slope, a0=intercept のみ使う
        guard let filter = CIFilter(name: "CIColorPolynomial") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: CGFloat(intercept(stats.rBlack, stats.rWhite)),
                                 y: CGFloat(rSlope), z: 0, w: 0),
                        forKey: "inputRedCoefficients")
        filter.setValue(CIVector(x: CGFloat(intercept(stats.gBlack, stats.gWhite)),
                                 y: CGFloat(gSlope), z: 0, w: 0),
                        forKey: "inputGreenCoefficients")
        filter.setValue(CIVector(x: CGFloat(intercept(stats.bBlack, stats.bWhite)),
                                 y: CGFloat(bSlope), z: 0, w: 0),
                        forKey: "inputBlueCoefficients")
        filter.setValue(CIVector(x: 0, y: 1, z: 0, w: 0),
                        forKey: "inputAlphaCoefficients")
        return filter.outputImage ?? image
    }

    // MARK: - 3. Adaptive White Balance（NIRで強くなったR過剰を補正）

    private static func applyWhiteBalance(_ image: CIImage, stats: ChannelStats) -> CIImage {
        // IRカメラ: R > G > B（NIR透過率の差）
        // 目標: R/G/B を均等に近づける
        let neutralMean = (stats.rMean + stats.gMean + stats.bMean) / 3.0
        let eps: Float = 1e-4

        let rGain = neutralMean / max(stats.rMean, eps)
        let gGain = neutralMean / max(stats.gMean, eps)
        let bGain = neutralMean / max(stats.bMean, eps)

        // ゲインを制限（過補正を防ぐ）
        let rG = min(max(rGain, 0.5), 2.0)
        let gG = min(max(gGain, 0.5), 2.0)
        let bG = min(max(bGain, 0.5), 2.0)

        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = image
        // 対角要素: チャンネルゲイン / 非対角: 0
        matrix.rVector   = CIVector(x: CGFloat(rG), y: 0, z: 0, w: 0)
        matrix.gVector   = CIVector(x: 0, y: CGFloat(gG), z: 0, w: 0)
        matrix.bVector   = CIVector(x: 0, y: 0, z: CGFloat(bG), w: 0)
        matrix.aVector   = CIVector(x: 0, y: 0, z: 0, w: 1)
        matrix.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        return matrix.outputImage ?? image
    }

    // MARK: - 4. LUT Colorization

    private static func applyLUTColorization(_ image: CIImage) -> CIImage {
        guard let entry = LUTEngine.shared.load(named: "nir_to_rgb") else { return image }
        return LUTEngine.apply(image, data: entry.data, size: entry.size, intensity: 0.85)
    }

    // MARK: - 5. Saturation Recovery

    private static func recoverSaturation(_ image: CIImage, amount: Double) -> CIImage {
        let ctrl = CIFilter.colorControls()
        ctrl.inputImage  = image
        ctrl.saturation  = Float(1.0 + amount)
        ctrl.brightness  = 0
        ctrl.contrast    = 1
        return ctrl.outputImage ?? image
    }

    // MARK: - Blend

    private static func blend(original: CIImage, processed: CIImage, alpha: Float) -> CIImage {
        guard let blendFilter = CIFilter(name: "CIBlendWithMask") else { return processed }
        let maskColor = CIColor(red: CGFloat(alpha), green: CGFloat(alpha), blue: CGFloat(alpha))
        let mask = CIImage(color: maskColor).cropped(to: original.extent)
        blendFilter.setValue(processed,  forKey: kCIInputImageKey)
        blendFilter.setValue(original,   forKey: kCIInputBackgroundImageKey)
        blendFilter.setValue(mask,       forKey: kCIInputMaskImageKey)
        return blendFilter.outputImage ?? processed
    }
}
