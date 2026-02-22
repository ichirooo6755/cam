#if canImport(UIKit)
import UIKit
#endif

import CoreImage
import CoreImage.CIFilterBuiltins

/// iPhone側での画像合成処理（Pi Zero 2Wの省電力化）
///
/// Pi側から画像処理を完全に除去し、iPhoneのGPUで高速処理。
/// - 多重露光（ブレンド/加算合成）
/// - 2-in-1コンポジション
/// - タイムスタンプ追加
enum ImageCompositor {

    // MARK: - タイムスタンプ追加

    /// 画像にタイムスタンプを追加
    static func addTimestamp(_ image: UIImage, timestamp: String) -> UIImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)

        return renderer.image { context in
            // 元画像を描画
            image.draw(at: .zero)

            // タイムスタンプテキスト
            let fontSize = image.size.width / 30  // 画像幅の1/30
            let font = UIFont.systemFont(ofSize: fontSize, weight: .bold)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.white,
                .strokeColor: UIColor.black,
                .strokeWidth: -3.0  // アウトライン
            ]

            let text = NSAttributedString(string: timestamp, attributes: attributes)
            let textSize = text.size()

            // 左下に配置
            let x: CGFloat = 20
            let y = image.size.height - textSize.height - 20
            text.draw(at: CGPoint(x: x, y: y))
        }
    }

    // MARK: - 多重露光（ブレンド）

    /// 2枚の画像を50:50でブレンド
    static func blendImages(_ first: UIImage, _ second: UIImage) -> UIImage? {
        guard let firstCI = CIImage(image: first),
              let secondCI = CIImage(image: second) else {
            return nil
        }

        // サイズを合わせる
        let targetSize = first.size
        let resizedSecond = resizeImage(secondCI, to: targetSize)

        // ブレンド
        let blendFilter = CIFilter.sourceOverCompositing()
        blendFilter.inputImage = resizedSecond
        blendFilter.backgroundImage = firstCI

        guard let output = blendFilter.outputImage else { return nil }

        // 50:50ブレンドにするため、opacityを調整
        let colorMatrix = CIFilter.colorMatrix()
        colorMatrix.inputImage = resizedSecond
        colorMatrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 0.5)

        guard let semi = colorMatrix.outputImage else { return nil }

        let blend = CIFilter.sourceOverCompositing()
        blend.inputImage = semi
        blend.backgroundImage = firstCI

        guard let final = blend.outputImage else { return nil }

        return renderCIImage(final, size: targetSize, scale: first.scale)
    }

    // MARK: - 多重露光（加算合成）

    /// 複数画像を加算合成（星の軌跡・ライトトレイル用）
    static func additiveComposite(_ images: [UIImage]) -> UIImage? {
        guard !images.isEmpty else { return nil }
        let context = CIContext(options: nil)

        let targetSize = images[0].size
        let scale = images[0].scale

        // すべての画像をCIImageに変換してリサイズ
        var ciImages: [CIImage] = []
        for img in images {
            guard let ci = CIImage(image: img) else { continue }
            ciImages.append(resizeImage(ci, to: targetSize))
        }

        guard !ciImages.isEmpty else { return nil }

        // 加算合成（GPU加速）
        var result = ciImages[0]

        for i in 1..<ciImages.count {
            let addFilter = CIFilter.additionCompositing()
            addFilter.inputImage = ciImages[i]
            addFilter.backgroundImage = result

            guard let added = addFilter.outputImage else { continue }
            result = added
        }

        return renderCIImage(result, size: targetSize, scale: scale)
    }

    // MARK: - 2-in-1コンポジション

    /// 2枚の画像を横並びに配置
    static func sideBySideComposite(_ first: UIImage, _ second: UIImage) -> UIImage? {
        let w1 = first.size.width
        let h1 = first.size.height
        let w2 = second.size.width
        let h2 = second.size.height

        // 高さを揃える
        let targetHeight = min(h1, h2)
        let scale1 = targetHeight / h1
        let scale2 = targetHeight / h2

        let newW1 = w1 * scale1
        let newW2 = w2 * scale2

        let totalWidth = newW1 + newW2
        let canvasSize = CGSize(width: totalWidth, height: targetHeight)

        let format = UIGraphicsImageRendererFormat()
        format.scale = max(first.scale, second.scale)
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: format)

        return renderer.image { context in
            // 左側に1枚目
            first.draw(in: CGRect(x: 0, y: 0, width: newW1, height: targetHeight))

            // 右側に2枚目
            second.draw(in: CGRect(x: newW1, y: 0, width: newW2, height: targetHeight))
        }
    }

    // MARK: - Helper Functions

    /// CIImageをリサイズ
    private static func resizeImage(_ image: CIImage, to size: CGSize) -> CIImage {
        let scaleX = size.width / image.extent.width
        let scaleY = size.height / image.extent.height

        let transform = CGAffineTransform(scaleX: scaleX, y: scaleY)
        return image.transformed(by: transform)
    }

    /// CIImageをUIImageにレンダリング（GPU加速）
    private static func renderCIImage(_ ciImage: CIImage, size: CGSize, scale: CGFloat) -> UIImage? {
        let context = CIContext(options: [
            .useSoftwareRenderer: false,  // GPU使用
            .priorityRequestLow: false     // 高優先度
        ])

        let rect = CGRect(origin: .zero, size: size)

        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }

        return UIImage(cgImage: cgImage, scale: scale, orientation: .up)
    }
}

// MARK: - Convenience Extensions

extension Array where Element == UIImage {
    /// 配列の画像を加算合成
    var additiveComposite: UIImage? {
        ImageCompositor.additiveComposite(self)
    }
}
