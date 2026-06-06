import Foundation
import CoreData

#if canImport(UIKit)
import UIKit
#endif

/// 写真のバージョン（オリジナルまたは編集版）
@objc(PhotoVersion)
public class PhotoVersion: NSManagedObject {
    /// 画像を取得（imageDataから復元）
    var image: UIImage? {
        guard let data = imageData else { return nil }
        return UIImageDecode.fromJPEGData(data)
    }

    /// サムネイルを取得（thumbnailDataから復元）
    var thumbnail: UIImage? {
        guard let data = thumbnailData else { return nil }
        return UIImageDecode.fromJPEGData(data)
    }

    /// 編集設定を取得（settingsJSONから復元）
    var settings: PhotoEditorSettings? {
        guard let json = settingsJSON,
              let data = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(PhotoEditorSettings.self, from: data)
    }

    /// バージョン名（表示用）
    var displayName: String {
        if isOriginal {
            return "Original"
        } else {
            return "Version \(versionNumber)"
        }
    }

    /// バージョンバッジ（ギャラリー表示用）
    var versionBadge: String? {
        guard !isOriginal else { return nil }
        return "v\(versionNumber)"
    }
}

// MARK: - Generated accessors
extension PhotoVersion {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<PhotoVersion> {
        return NSFetchRequest<PhotoVersion>(entityName: "PhotoVersion")
    }

    @NSManaged public var id: UUID
    @NSManaged public var originalPhotoID: String
    @NSManaged public var versionNumber: Int32
    @NSManaged public var imageData: Data?
    @NSManaged public var thumbnailData: Data?
    @NSManaged public var settingsJSON: String?
    @NSManaged public var createdAt: Date
    @NSManaged public var updatedAt: Date
    @NSManaged public var userRating: Int16
    @NSManaged public var isOriginal: Bool
    @NSManaged public var group: PhotoGroup?
}

extension PhotoVersion: Identifiable {}
