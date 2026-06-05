import SwiftUI
import CoreImage

/// 軽量版カメラAPI（写真一覧中心）
actor SimpleCameraAPI {
    private let baseURL: String
    private let session: URLSession

    private func sanitizeFilename(_ filename: String) -> String? {
        return sanitizePhotoFilename(filename)
    }

    init(baseURL: String = "http://192.168.4.1:8001") {
        if validateServerURL(baseURL) {
            self.baseURL = baseURL
        } else {
            self.baseURL = "http://192.168.4.1:8001"
        }
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config)
    }

    /// ネットワーク操作を最大 maxRetries 回リトライする
    private func withRetry<T>(maxRetries: Int = 1, delay: TimeInterval = 1.0, operation: () async throws -> T) async throws -> T {
        var lastError: Error?
        for attempt in 0...maxRetries {
            do {
                return try await operation()
            } catch {
                lastError = error
                if attempt < maxRetries {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }
        throw lastError!
    }
    
    /// 写真一覧を取得
    func fetchPhotos() async throws -> [String] {
        try await withRetry {
            guard let url = URL(string: "\(self.baseURL)/api/photos") else {
                throw APIError.invalidURL
            }
            
            let (data, response) = try await self.session.data(from: url)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                throw APIError.serverError
            }
            
            let files = try JSONDecoder().decode([String].self, from: data)
            return files.compactMap { self.sanitizeFilename($0) }
        }
    }
    
    /// 写真をダウンロード
    func downloadPhoto(filename: String, thumbnail: Bool = false, maxDimension: Int = 300) async throws -> UIImage {
        guard let safeFilename = sanitizeFilename(filename) else {
            throw APIError.invalidFilename
        }

        let useThumbnail = thumbnail || safeFilename.lowercased().hasSuffix(".dng")

        return try await withRetry(maxRetries: 3, delay: 1.5) {
            guard let url = URL(string: "\(self.baseURL)/api/photo") else {
                throw APIError.invalidURL
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var body: [String: Any] = ["filename": safeFilename]
            if useThumbnail {
                body["thumbnail"] = true
                body["max_dim"] = maxDimension
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await self.session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                throw APIError.downloadFailed
            }

            // RAW（DNG）ファイル対応: まずUIImageで読み込みを試行
            if let image = UIImage(data: data) {
                return image
            }

            // UIImageで読めない場合はCoreImageでRAW読み込み（DNG対応）
            if let ciImage = CIImage(data: data) {
                let context = CIContext(options: nil)
                if let cgImage = context.createCGImage(ciImage, from: ciImage.extent) {
                    return UIImage(cgImage: cgImage)
                }
            }

            throw APIError.invalidImageData
        }
    }

    func fetchPhotoMetadata(filename: String) async throws -> PhotoMetadata? {
        guard let safeFilename = sanitizeFilename(filename) else {
            throw APIError.invalidFilename
        }

        guard let url = URL(string: "\(baseURL)/api/photo/meta") else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["filename": safeFilename])

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
            httpResponse.statusCode == 200
        else {
            throw APIError.serverError
        }

        let decoded = try JSONDecoder().decode(PhotoMetadataResponse.self, from: data)
        if !decoded.success {
            return nil
        }
        return decoded.metadata
    }

    func deletePhotos(filenames: [String]) async throws -> DeletePhotosResponse {
        let safeFilenames = filenames.compactMap { sanitizeFilename($0) }
        guard !safeFilenames.isEmpty else {
            throw APIError.invalidFilename
        }

        guard let url = URL(string: "\(baseURL)/api/photos/delete") else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["filenames": safeFilenames])

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.serverError
        }

        let decoder = JSONDecoder()
        guard let decoded = try? decoder.decode(DeletePhotosResponse.self, from: data) else {
            throw APIError.serverError
        }

        if httpResponse.statusCode == 200 || httpResponse.statusCode == 400 {
            return decoded
        }

        throw APIError.serverError
    }
    
    /// システム状態を取得
    func fetchStatus() async throws -> SystemStatus {
        try await withRetry {
            guard let url = URL(string: "\(self.baseURL)/api/status") else {
                throw APIError.invalidURL
            }
            
            let (data, response) = try await self.session.data(from: url)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                throw APIError.serverError
            }
            
            return try JSONDecoder().decode(SystemStatus.self, from: data)
        }
    }
    
    /// 明るさ閾値を更新
    func updateThreshold(_ threshold: Int) async throws {
        guard let url = URL(string: "\(baseURL)/api/settings") else {
            throw APIError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body = ["brightness_threshold": threshold]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw APIError.serverError
        }
        
        let result = try JSONDecoder().decode(SimpleResponse.self, from: data)
        if !result.success {
            throw APIError.updateFailed
        }
    }
}

struct SystemStatus: Codable {
    let photoCount: Int
    let brightnessThreshold: Int
    let serviceRunning: Bool
    
    enum CodingKeys: String, CodingKey {
        case photoCount = "photo_count"
        case brightnessThreshold = "brightness_threshold"
        case serviceRunning = "service_running"
    }
}

struct SimpleResponse: Codable {
    let success: Bool
}

struct DeletePhotosResponse: Codable {
    let success: Bool
    let deleted: [String]
    let notFound: [String]
    let invalid: [String]
    let errors: [DeletePhotoError]

    enum CodingKeys: String, CodingKey {
        case success
        case deleted
        case notFound = "not_found"
        case invalid
        case errors
    }
}

struct DeletePhotoError: Codable {
    let filename: String
    let error: String
}

enum APIError: LocalizedError {
    case invalidURL
    case invalidFilename
    case serverError
    case downloadFailed
    case invalidImageData
    case updateFailed
    
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "無効なURL"
        case .invalidFilename: return "無効なファイル名"
        case .serverError: return "サーバーエラー"
        case .downloadFailed: return "ダウンロード失敗"
        case .invalidImageData: return "無効な画像データ"
        case .updateFailed: return "更新失敗"
        }
    }
}
