import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

// MARK: - SSRF対策: URL検証ヘルパー

/// サーバーURLの妥当性を検証（SSRF対策）
/// - プライベートIP範囲内または.localドメインのみ許可
func validateServerURL(_ baseURL: String) -> Bool {
    guard let url = URL(string: baseURL),
          let scheme = url.scheme,
          let host = url.host else {
        return false
    }
    
    // http/httpsのみ許可
    guard scheme == "http" || scheme == "https" else {
        return false
    }
    
    // プライベートIPまたは.localドメインのみ許可（SSRF対策）
    let allowedPatterns = [
        "^192\\.168\\.",           // 192.168.x.x
        "^10\\.",                   // 10.x.x.x
        "^172\\.(1[6-9]|2[0-9]|3[01])\\.", // 172.16-31.x.x
        "^127\\.",                  // 127.x.x.x (localhost)
        "^0\\.0\\.0\\.0$",          // 0.0.0.0
        "\\.local$"                 // *.local (mDNS)
    ]
    
    for pattern in allowedPatterns {
        if host.range(of: pattern, options: .regularExpression) != nil {
            return true
        }
    }
    
    // 完全一致チェック
    let allowedHosts = ["localhost", "raspberrypi", "raspberrypi.local"]
    if allowedHosts.contains(host) {
        return true
    }
    
    return false
}

/// Raspberry Piカメラ制御API クライアント
actor CameraAPI {

    // MARK: - 設定

    /// サーバーのベースURL
    private let baseURL: String

    private let session: URLSession

    private func sanitizeFilename(_ filename: String) -> SafeFilename? {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard trimmed.rangeOfCharacter(from: allowed.inverted) == nil else {
            return nil
        }

        let lower = trimmed.lowercased()
        guard lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") || lower.hasSuffix(".png") else {
            return nil
        }

        return SafeFilename(value: trimmed)
    }

    init(baseURL: String = "http://192.168.4.1:8001") {
        // SSRF対策: URL検証
        if validateServerURL(baseURL) {
            self.baseURL = baseURL
        } else {
            // 検証失敗時はデフォルト値を使用
            self.baseURL = "http://192.168.4.1:8001"
            print("Warning: Invalid server URL provided, using default: \(self.baseURL)")
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    // MARK: - 設定取得

    /// 現在のカメラ設定を取得
    func fetchSettings() async throws -> CameraSettings {
        guard let url = URL(string: "\(baseURL)/api/settings") else {
            throw CameraAPIError.invalidURL
        }

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
            httpResponse.statusCode == 200
        else {
            throw CameraAPIError.serverError
        }

        let decoder = JSONDecoder()
        return try decoder.decode(CameraSettings.self, from: data)
    }

    // MARK: - 設定更新

    /// 設定を更新（汎用）
    func updateSettings(
        _ settings: [String: Any],
        temporary: Bool = false,
        resetTemporary: Bool = false
    ) async throws {
        guard let url = URL(string: "\(baseURL)/api/settings") else {
            throw CameraAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // JSON変換
        var jsonDict: [String: Any] = [:]
        for (key, value) in settings {
            if let iso = value as? ISOValue {
                switch iso {
                case .auto: jsonDict[key] = "auto"
                case .value(let v): jsonDict[key] = v
                }
            } else if let ss = value as? ShutterSpeedValue {
                switch ss {
                case .auto: jsonDict[key] = "auto"
                case .microseconds(let us): jsonDict[key] = us
                }
            } else {
                jsonDict[key] = value
            }
        }

        if temporary {
            jsonDict["temporary"] = true
        }

        if resetTemporary {
            jsonDict["reset_temporary"] = true
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: jsonDict)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
            httpResponse.statusCode == 200
        else {
            throw CameraAPIError.serverError
        }

        let result = try JSONDecoder().decode(SettingsResponse.self, from: data)
        if !result.success {
            throw CameraAPIError.updateFailed(result.error ?? "Unknown error")
        }
    }

    /// ISO感度を更新
    func updateISO(_ iso: ISOValue, temporary: Bool = true) async throws {
        try await updateSettings(["iso": iso], temporary: temporary)
    }

    /// シャッタースピードを更新
    func updateShutterSpeed(_ shutterSpeed: ShutterSpeedValue, temporary: Bool = true) async throws {
        try await updateSettings(["shutter_speed": shutterSpeed], temporary: temporary)
    }

    /// ホワイトバランスを更新
    func updateWhiteBalance(_ wb: String, temporary: Bool = true) async throws {
        try await updateSettings(["white_balance": wb], temporary: temporary)
    }

    /// 検知閾値を更新
    func updateDetectionThreshold(_ threshold: Int, temporary: Bool = true) async throws {
        try await updateSettings(["detection_threshold": threshold], temporary: temporary)
    }

    /// 画質を更新
    func updateQuality(_ quality: Int, temporary: Bool = true) async throws {
        try await updateSettings(["quality": quality], temporary: temporary)
    }

    func updateDetectionInterval(_ interval: Double, temporary: Bool = true) async throws {
        try await updateSettings(["detection_interval": interval], temporary: temporary)
    }

    func updateCheckInterval(_ interval: Double, temporary: Bool = true) async throws {
        try await updateSettings(["check_interval": interval], temporary: temporary)
    }

    func updateCaptureCooldown(_ cooldown: Double, temporary: Bool = true) async throws {
        try await updateSettings(["capture_cooldown": cooldown], temporary: temporary)
    }

    func updateCameraMode(_ mode: CameraModeOption) async throws {
        try await updateSettings(["camera_mode": mode.rawValue])
    }

    /// 光検知の有効/無効を更新
    func updateMonitoringEnabled(_ enabled: Bool, temporary: Bool = true) async throws {
        try await updateSettings(["monitoring_enabled": enabled], temporary: temporary)
    }

    /// トグル設定を更新
    func updateToggleSettings(
        multipleExposure: Bool? = nil,
        composition2in1: Bool? = nil,
        timestamp: Bool? = nil,
        temporary: Bool = true
    ) async throws {
        var settings: [String: Any] = [:]
        if let me = multipleExposure { settings["enable_multiple_exposure"] = me }
        if let c2 = composition2in1 { settings["enable_2in1_composition"] = c2 }
        if let ts = timestamp { settings["enable_timestamp"] = ts }
        try await updateSettings(settings, temporary: temporary)
    }

    func resetTemporarySettings() async throws {
        try await updateSettings([:], resetTemporary: true)
    }

    // MARK: - 撮影

    /// 撮影を実行し、ファイル名を返す
    func capture() async throws -> SafeFilename {
        guard let url = URL(string: "\(baseURL)/api/capture") else {
            throw CameraAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = "{}".data(using: .utf8)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CameraAPIError.serverError
        }

        let decoder = JSONDecoder()
        let decodedResult = try? decoder.decode(CaptureResponse.self, from: data)

        if httpResponse.statusCode != 200 {
            if let decodedResult, let error = decodedResult.error {
                throw CameraAPIError.captureFailed(error)
            }
            throw CameraAPIError.serverError
        }

        guard let result = decodedResult else {
            throw CameraAPIError.serverError
        }

        guard result.success, let filename = result.filename else {
            throw CameraAPIError.captureFailed(result.error ?? "Unknown error")
        }

        guard let safeFilename = sanitizeFilename(filename) else {
            throw CameraAPIError.invalidFilename
        }

        return safeFilename
    }

    // MARK: - 画像ダウンロード

    /// 撮影した画像をダウンロード
    func downloadImage(filename: SafeFilename) async throws -> UIImage {
        let safeFilename = filename.value
        guard !safeFilename.isEmpty else {
            throw CameraAPIError.invalidFilename
        }

        guard let url = URL(string: "\(baseURL)/api/photo") else {
            throw CameraAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["filename": safeFilename]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
            httpResponse.statusCode == 200
        else {
            throw CameraAPIError.downloadFailed
        }

        guard let image = UIImage(data: data) else {
            throw CameraAPIError.invalidImageData
        }

        return image
    }

    // MARK: - 監視制御

    /// 監視を再開
    func restartMonitoring() async throws {
        guard let url = URL(string: "\(baseURL)/api/restart_monitoring") else {
            throw CameraAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
            httpResponse.statusCode == 200
        else {
            throw CameraAPIError.serverError
        }
    }

    /// 監視を停止
    func stopMonitoring() async throws {
        guard let url = URL(string: "\(baseURL)/api/stop_monitoring") else {
            throw CameraAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
            httpResponse.statusCode == 200
        else {
            throw CameraAPIError.serverError
        }
    }

    // MARK: - Wi-Fi

    /// Wi-Fiステータスを取得
    func fetchWiFiStatus() async throws -> WiFiStatus {
        guard let url = URL(string: "\(baseURL)/api/wifi/status") else {
            throw CameraAPIError.invalidURL
        }

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
            httpResponse.statusCode == 200
        else {
            throw CameraAPIError.serverError
        }

        return try JSONDecoder().decode(WiFiStatus.self, from: data)
    }

    /// Wi-Fiモードを切り替え
    func switchWiFiMode(toAP: Bool, ssid: String? = nil, password: String? = nil) async throws {
        guard let url = URL(string: "\(baseURL)/api/wifi/switch") else {
            throw CameraAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = ["mode": toAP ? "ap" : "tethering"]
        if toAP {
            body["ssid"] = ssid ?? "PiCamera"
            body["password"] = password ?? "picamera123"
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
            httpResponse.statusCode == 200
        else {
            throw CameraAPIError.serverError
        }

        let result = try JSONDecoder().decode(WiFiSwitchResponse.self, from: data)
        if !result.success {
            throw CameraAPIError.updateFailed(result.message ?? "Wi-Fi switch failed")
        }
    }

    /// 家Wi-Fi設定を書き込み
    func writeWpaSettings(ssid: String, psk: String) async throws {
        guard let url = URL(string: "\(baseURL)/api/wifi/write_wpa") else {
            throw CameraAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["ssid": ssid, "psk": psk]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
            httpResponse.statusCode == 200
        else {
            throw CameraAPIError.serverError
        }

        let result = try JSONDecoder().decode(WiFiSwitchResponse.self, from: data)
        if !result.success {
            throw CameraAPIError.updateFailed(result.message ?? "Wi-Fi write failed")
        }
    }
}

// MARK: - エラー定義

enum CameraAPIError: LocalizedError {
    case invalidURL
    case invalidFilename
    case serverError
    case updateFailed(String)
    case captureFailed(String)
    case downloadFailed
    case invalidImageData

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "無効なURLです"
        case .invalidFilename:
            return "無効なファイル名です"
        case .serverError:
            return "サーバーエラーが発生しました"
        case .updateFailed(let msg):
            return "設定更新失敗: \(msg)"
        case .captureFailed(let msg):
            return "撮影失敗: \(msg)"
        case .downloadFailed:
            return "画像ダウンロード失敗"
        case .invalidImageData:
            return "無効な画像データ"
        }
    }
}
