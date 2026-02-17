import CoreData
import Foundation

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

// MARK: - AutoEditEvaluation Entity

@objc(AutoEditEvaluation)
public class AutoEditEvaluation: NSManagedObject, Identifiable {
    @NSManaged public var id: UUID
    @NSManaged public var createdAt: Date
    @NSManaged public var predictedSettingsJSON: String  // ML予測の設定
    @NSManaged public var finalSettingsJSON: String  // ユーザーが最終的に使用した設定
    @NSManaged public var userRating: Int16  // 1-5
    @NSManaged public var imageBrightness: Double  // 画像の平均輝度（0-1）
    @NSManaged public var imageContrast: Double  // 画像のコントラスト
    @NSManaged public var imageSaturation: Double  // 画像の彩度
}

extension AutoEditEvaluation {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<AutoEditEvaluation> {
        return NSFetchRequest<AutoEditEvaluation>(entityName: "AutoEditEvaluation")
    }

    /// 評価が高いデータを取得（ML学習用）
    static func fetchForTraining(minRating: Int = 4, context: NSManagedObjectContext) -> [AutoEditEvaluation] {
        let request = fetchRequest()
        request.predicate = NSPredicate(format: "userRating >= %d", minRating)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \AutoEditEvaluation.createdAt, ascending: false)]
        return (try? context.fetch(request)) ?? []
    }

    /// 予測設定をPhotoEditorSettingsとして取得
    var predictedSettings: PhotoEditorSettings? {
        guard let data = predictedSettingsJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PhotoEditorSettings.self, from: data)
    }

    /// 最終設定をPhotoEditorSettingsとして取得
    var finalSettings: PhotoEditorSettings? {
        guard let data = finalSettingsJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PhotoEditorSettings.self, from: data)
    }
}
