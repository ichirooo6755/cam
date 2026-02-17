import CoreData

/// Core Data スタック管理
struct PersistenceController {
    /// 共有インスタンス（アプリ全体で使用）
    static let shared = PersistenceController()

    /// プレビュー用インスタンス（SwiftUI Preview用）
    static var preview: PersistenceController = {
        let controller = PersistenceController(inMemory: true)
        let viewContext = controller.container.viewContext

        // プレビュー用のサンプルデータを作成
        for i in 0..<5 {
            let photo = EditedPhoto(context: viewContext)
            photo.id = UUID()
            photo.createdAt = Date().addingTimeInterval(-Double(i) * 86400)
            photo.userRating = Int16(i % 5 + 1)
            photo.settingsJSON = "{}"
        }

        do {
            try viewContext.save()
        } catch {
            fatalError("Preview data creation failed: \(error)")
        }

        return controller
    }()

    let container: NSPersistentContainer

    /// 初期化
    /// - Parameter inMemory: trueの場合、メモリ内ストアを使用（テスト・プレビュー用）
    init(inMemory: Bool = false) {
        container = NSPersistentContainer(name: "PiCameraData")

        if inMemory {
            container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
        }

        container.loadPersistentStores { description, error in
            if let error = error {
                // 本番環境では適切なエラー処理が必要
                // ここでは開発中のため、fatalErrorで停止
                fatalError("Core Data store failed to load: \(error.localizedDescription)")
            }
        }

        // iCloud同期を無効化（ローカル保存のみ）
        container.viewContext.automaticallyMergesChangesFromParent = true
    }

    /// 変更を保存
    func save() {
        let context = container.viewContext

        if context.hasChanges {
            do {
                try context.save()
            } catch {
                let nsError = error as NSError
                print("Core Data save error: \(nsError), \(nsError.userInfo)")
            }
        }
    }
}
