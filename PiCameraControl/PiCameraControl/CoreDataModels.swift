import CoreData
import Foundation
import CoreGraphics

#if canImport(UIKit)
import UIKit
#endif

// MARK: - EditedPhoto Entity

@objc(EditedPhoto)
public class EditedPhoto: NSManagedObject, Identifiable {
    @NSManaged public var id: UUID
    @NSManaged public var createdAt: Date
    @NSManaged public var imageData: Data?
    @NSManaged public var thumbnailData: Data?
    @NSManaged public var settingsJSON: String
    @NSManaged public var userRating: Int16  // 0-5 (0 = 未評価)
    @NSManaged public var originalFilename: String?
}

extension EditedPhoto {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<EditedPhoto> {
        return NSFetchRequest<EditedPhoto>(entityName: "EditedPhoto")
    }

    /// 最新の写真を取得
    static func fetchRecent(limit: Int = 100, context: NSManagedObjectContext) -> [EditedPhoto] {
        let request = fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \EditedPhoto.createdAt, ascending: false)]
        request.fetchLimit = limit
        return (try? context.fetch(request)) ?? []
    }

    /// 評価が高い写真を取得
    static func fetchHighRated(minRating: Int = 4, context: NSManagedObjectContext) -> [EditedPhoto] {
        let request = fetchRequest()
        request.predicate = NSPredicate(format: "userRating >= %d", minRating)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \EditedPhoto.createdAt, ascending: false)]
        return (try? context.fetch(request)) ?? []
    }

    /// 画像をUIImageとして取得
    var image: UIImage? {
        guard let data = imageData else { return nil }
        return UIImage(data: data)
    }

    /// サムネイルをUIImageとして取得
    var thumbnail: UIImage? {
        guard let data = thumbnailData else { return nil }
        return UIImage(data: data)
    }

    /// 設定をPhotoEditorSettingsとして取得
    var settings: PhotoEditorSettings? {
        guard let data = settingsJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PhotoEditorSettings.self, from: data)
    }
}

// MARK: - AutoEditEvaluation Entity

@objc(AutoEditEvaluation)
public class AutoEditEvaluation: NSManagedObject, Identifiable {
    @NSManaged public var id: UUID
    @NSManaged public var createdAt: Date
    @NSManaged public var updatedAt: Date?
    @NSManaged public var predictedSettingsJSON: String
    @NSManaged public var finalSettingsJSON: String
    @NSManaged public var settingsJSON: String?
    @NSManaged public var smartEditDecisionJSON: String?
    @NSManaged public var referenceAnalysisJSON: String?
    @NSManaged public var userRating: Int16
    @NSManaged public var imageBrightness: Double
    @NSManaged public var imageContrast: Double
    @NSManaged public var imageSaturation: Double
    @NSManaged public var imageData: Data?
    @NSManaged public var thumbnailData: Data?
    @NSManaged public var originalPhotoID: String?
    @NSManaged public var versionNumber: Int32
    @NSManaged public var isOriginal: Bool
    @NSManaged public var group: URL?
}

extension AutoEditEvaluation {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<AutoEditEvaluation> {
        return NSFetchRequest<AutoEditEvaluation>(entityName: "AutoEditEvaluation")
    }

    /// finalSettingsJSON から PhotoEditorSettings を取得
    var finalSettings: PhotoEditorSettings? {
        guard let data = finalSettingsJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PhotoEditorSettings.self, from: data)
    }

    /// 高評価データを取得（学習用）
    static func fetchHighRated(minRating: Int = 4, context: NSManagedObjectContext) -> [AutoEditEvaluation] {
        let request = fetchRequest()
        request.predicate = NSPredicate(format: "userRating >= %d", minRating)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \AutoEditEvaluation.createdAt, ascending: false)]
        return (try? context.fetch(request)) ?? []
    }
}

// MARK: - MeteringEvaluation Entity

@objc(MeteringEvaluation)
public class MeteringEvaluation: NSManagedObject, Identifiable {
    @NSManaged public var id: UUID
    @NSManaged public var createdAt: Date
    @NSManaged public var sensorLux: Double  // 測光センサーの照度
    @NSManaged public var suggestedISO: Int32  // 提案されたISO
    @NSManaged public var suggestedShutterUS: Int64  // 提案されたシャッター速度（マイクロ秒）
    @NSManaged public var actualISO: Int32  // 実際に使用したISO
    @NSManaged public var actualShutterUS: Int64  // 実際に使用したシャッター速度（マイクロ秒）
    @NSManaged public var userRating: Int16  // 1-5
    @NSManaged public var temperature: Double  // 温度（°C）
    @NSManaged public var humidity: Double  // 湿度（%）
}

extension MeteringEvaluation {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<MeteringEvaluation> {
        return NSFetchRequest<MeteringEvaluation>(entityName: "MeteringEvaluation")
    }

    /// 評価が高いデータを取得（ML学習用）
    static func fetchForTraining(minRating: Int = 4, context: NSManagedObjectContext) -> [MeteringEvaluation] {
        let request = fetchRequest()
        request.predicate = NSPredicate(format: "userRating >= %d", minRating)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \MeteringEvaluation.createdAt, ascending: false)]
        return (try? context.fetch(request)) ?? []
    }
}

// MARK: - ImageAnalysisResult

/// 画像分析結果（SmartAutoEditEngine / ImageAnalyzer 用）
struct ImageAnalysisResult {

    struct Histogram {
        var shadowClipping: Double    // 0-1: シャドウクリッピング率
        var highlightClipping: Double // 0-1: ハイライトクリッピング率
        var luminanceStdDev: Double   // 輝度の標準偏差
        var dynamicRange: Double      // 0-1: ダイナミックレンジ
    }

    struct ColorBalance {
        var r: Double
        var g: Double
        var b: Double
    }

    var brightness: Double       // 0-1
    var contrast: Double         // 0-1
    var saturation: Double       // 0-1
    var exposureScore: Double    // 0-1 (1=適正露出)
    var histogram: Histogram
    var colorBalance: ColorBalance
}

// MARK: - ImageAnalyzer

/// 画像分析ユーティリティ（SmartAutoEditEngine が使用）
enum ImageAnalyzer {

    /// UIImage を分析して ImageAnalysisResult を返す
    static func analyze(image: UIImage) -> ImageAnalysisResult? {
        guard let cgImage = image.cgImage else { return nil }

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: &pixels,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: bytesPerRow,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let total = width * height
        guard total > 0 else { return nil }

        var rSum = 0.0, gSum = 0.0, bSum = 0.0
        var lumSum = 0.0, lumSqSum = 0.0
        var shadowCount = 0, highlightCount = 0

        let step = max(1, total / 10000) // サンプリング
        var sampleCount = 0

        for i in Swift.stride(from: 0, to: total, by: step) {
            let base = i * bytesPerPixel
            let r = Double(pixels[base]) / 255.0
            let g = Double(pixels[base + 1]) / 255.0
            let b = Double(pixels[base + 2]) / 255.0

            rSum += r
            gSum += g
            bSum += b

            let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
            lumSum += lum
            lumSqSum += lum * lum

            if lum < 0.05 { shadowCount += 1 }
            if lum > 0.95 { highlightCount += 1 }
            sampleCount += 1
        }

        guard sampleCount > 0 else { return nil }

        let sc = Double(sampleCount)
        let avgR = rSum / sc
        let avgG = gSum / sc
        let avgB = bSum / sc
        let avgLum = lumSum / sc
        let lumVariance = lumSqSum / sc - avgLum * avgLum
        let lumStdDev = sqrt(max(0, lumVariance))

        let shadowClipping = Double(shadowCount) / sc
        let highlightClipping = Double(highlightCount) / sc

        // 彩度推定（単純化）
        let maxRGB = max(avgR, avgG, avgB)
        let minRGB = min(avgR, avgG, avgB)
        let saturation = maxRGB > 0 ? (maxRGB - minRGB) / maxRGB : 0

        // コントラスト推定
        let contrast = min(lumStdDev * 3.0, 1.0)

        // 露出スコア（明るさが中間値に近いほど高い）
        let exposureScore = 1.0 - abs(avgLum - 0.5) * 2.0

        return ImageAnalysisResult(
            brightness: avgLum,
            contrast: contrast,
            saturation: saturation,
            exposureScore: exposureScore,
            histogram: ImageAnalysisResult.Histogram(
                shadowClipping: shadowClipping,
                highlightClipping: highlightClipping,
                luminanceStdDev: lumStdDev,
                dynamicRange: min(lumStdDev * 4.0, 1.0)
            ),
            colorBalance: ImageAnalysisResult.ColorBalance(r: avgR, g: avgG, b: avgB)
        )
    }
}

// MARK: - ImageWriteCoordinator

/// 写真保存コールバック用のNSObjectサブクラス（HDRComposerView が使用）
final class ImageWriteCoordinator: NSObject {
    private let completion: (Error?) -> Void

    init(completion: @escaping (Error?) -> Void) {
        self.completion = completion
    }

    @objc func image(
        _ image: UIImage,
        didFinishSavingWithError error: Error?,
        contextInfo: UnsafeRawPointer
    ) {
        completion(error)
    }
}

