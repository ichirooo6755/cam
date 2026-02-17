import Foundation
import CoreData

/// 写真のグループ（同じオリジナルから派生したバージョンを管理）
@objc(PhotoGroup)
public class PhotoGroup: NSManagedObject {
    /// サーバーメタデータを取得
    var serverMetadata: PhotoMetadata? {
        guard let json = serverMetadataJSON,
              let data = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(PhotoMetadata.self, from: data)
    }

    /// バージョン数
    var versionCount: Int {
        return versions?.count ?? 0
    }

    /// ソート済みバージョン一覧（古い順）
    var sortedVersions: [PhotoVersion] {
        guard let versions = versions as? Set<PhotoVersion> else {
            return []
        }
        return versions.sorted { v1, v2 in
            if v1.isOriginal { return true }
            if v2.isOriginal { return false }
            return v1.versionNumber < v2.versionNumber
        }
    }

    /// オリジナルバージョンを取得
    var originalVersion: PhotoVersion? {
        return sortedVersions.first { $0.isOriginal }
    }

    /// 次のバージョン番号を取得
    func nextVersionNumber() -> Int {
        let maxVersion = sortedVersions
            .filter { !$0.isOriginal }
            .map { Int($0.versionNumber) }
            .max() ?? 0
        return maxVersion + 1
    }
}

// MARK: - Generated accessors
extension PhotoGroup {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<PhotoGroup> {
        return NSFetchRequest<PhotoGroup>(entityName: "PhotoGroup")
    }

    @NSManaged public var id: String
    @NSManaged public var serverMetadataJSON: String?
    @NSManaged public var latestVersion: PhotoVersion?
    @NSManaged public var versions: NSSet?
}

// MARK: - Generated accessors for versions
extension PhotoGroup {
    @objc(addVersionsObject:)
    @NSManaged public func addToVersions(_ value: PhotoVersion)

    @objc(removeVersionsObject:)
    @NSManaged public func removeFromVersions(_ value: PhotoVersion)

    @objc(addVersions:)
    @NSManaged public func addToVersions(_ values: NSSet)

    @objc(removeVersions:)
    @NSManaged public func removeFromVersions(_ values: NSSet)
}

extension PhotoGroup: Identifiable {}
