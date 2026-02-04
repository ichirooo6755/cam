import SwiftUI

/// 軽量版カメラAPI（写真一覧中心）
actor SimpleCameraAPI {
    private let baseURL: String
    private let session: URLSession
    
    init(baseURL: String = "http://192.168.0.20:8001") {
        if validateServerURL(baseURL) {
            self.baseURL = baseURL
        } else {
            self.baseURL = "http://192.168.0.20:8001"
        }
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
    }
    
    /// 写真一覧を取得
    func fetchPhotos() async throws -> [String] {
        guard let url = URL(string: "\(baseURL)/api/photos") else {
            throw APIError.invalidURL
        }
        
        let (data, response) = try await session.data(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw APIError.serverError
        }
        
        return try JSONDecoder().decode([String].self, from: data)
    }
    
    /// 写真をダウンロード
    func downloadPhoto(filename: String) async throws -> UIImage {
        guard let url = URL(string: "\(baseURL)/photos/\(filename)") else {
            throw APIError.invalidURL
        }
        
        let (data, response) = try await session.data(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw APIError.downloadFailed
        }
        
        guard let image = UIImage(data: data) else {
            throw APIError.invalidImageData
        }
        
        return image
    }
    
    /// システム状態を取得
    func fetchStatus() async throws -> SystemStatus {
        guard let url = URL(string: "\(baseURL)/api/status") else {
            throw APIError.invalidURL
        }
        
        let (data, response) = try await session.data(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw APIError.serverError
        }
        
        return try JSONDecoder().decode(SystemStatus.self, from: data)
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

enum APIError: LocalizedError {
    case invalidURL
    case serverError
    case downloadFailed
    case invalidImageData
    case updateFailed
    
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "無効なURL"
        case .serverError: return "サーバーエラー"
        case .downloadFailed: return "ダウンロード失敗"
        case .invalidImageData: return "無効な画像データ"
        case .updateFailed: return "更新失敗"
        }
    }
}
