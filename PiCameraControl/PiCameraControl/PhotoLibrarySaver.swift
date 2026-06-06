#if canImport(UIKit)
import UIKit
import Photos

enum PhotoLibrarySaver {
    enum SaveError: LocalizedError {
        case denied
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .denied:
                return "写真アプリへの保存が許可されていません。設定アプリで許可してください。"
            case .failed(let msg):
                return "写真の保存に失敗しました: \(msg)"
            }
        }
    }

    static func save(_ image: UIImage) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw SaveError.denied
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }, completionHandler: { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: SaveError.failed(error?.localizedDescription ?? "unknown"))
                }
            })
        }
    }
}

enum UIImageDecode {
    static func fromJPEGData(_ data: Data) -> UIImage? {
        guard data.count > 128 else { return nil }
        guard let image = UIImage(data: data), image.size.width > 1, image.size.height > 1 else {
            return nil
        }
        return image
    }
}
#endif
