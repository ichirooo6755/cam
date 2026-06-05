import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

#if canImport(CoreImage)
    import CoreImage
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
        guard let safe = sanitizePhotoFilename(filename) else { return nil }
        return SafeFilename(value: safe)
    }

    /// 軽量API用セッション（設定取得・ステータス等）
    private let lightSession: URLSession
    /// 撮影専用セッション（長露光対応: タイムアウト長め）
    private let captureSession: URLSession
    /// ダウンロード専用セッション（大きなファイルに対応、リクエスト自体は短め）
    private let downloadSession: URLSession

    init(baseURL: String = "http://192.168.4.1:8001") {
        // SSRF対策: URL検証
        if validateServerURL(baseURL) {
            self.baseURL = baseURL
        } else {
            self.baseURL = "http://192.168.4.1:8001"
            print("Warning: Invalid server URL provided, using default: \(self.baseURL)")
        }

        // 軽量API: 8秒でタイムアウト
        let lightConfig = URLSessionConfiguration.default
        lightConfig.timeoutIntervalForRequest = 8
        lightConfig.timeoutIntervalForResource = 12
        lightConfig.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.lightSession = URLSession(configuration: lightConfig)

        // 撮影: 長露光・カメラ初期化待ちに十分な時間
        let captureConfig = URLSessionConfiguration.default
        captureConfig.timeoutIntervalForRequest = 60
        captureConfig.timeoutIntervalForResource = 120
        self.captureSession = URLSession(configuration: captureConfig)

        // ダウンロード: 接続自体は素早く確立されるはず、転送に余裕を持たせる
        let dlConfig = URLSessionConfiguration.default
        dlConfig.timeoutIntervalForRequest = 15
        dlConfig.timeoutIntervalForResource = 60
        self.downloadSession = URLSession(configuration: dlConfig)

        // 後方互換のためプロパティを残す
        self.session = self.captureSession
    }

    // MARK: - リトライヘルパー

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

    // MARK: - 設定取得

    /// 現在のカメラ設定を取得
    func fetchSettings() async throws -> CameraSettings {
        try await withRetry {
            guard let url = URL(string: "\(self.baseURL)/api/settings") else {
                throw CameraAPIError.invalidURL
            }

            let (data, response) = try await self.lightSession.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                httpResponse.statusCode == 200
            else {
                throw CameraAPIError.serverError
            }

            let decoder = JSONDecoder()
            return try decoder.decode(CameraSettings.self, from: data)
        }
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

        let (data, response) = try await lightSession.data(for: request)

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

    /// 手ぶれ補正の有効/無効を更新
    func updateStabilization(_ enabled: Bool, temporary: Bool = true) async throws {
        try await updateSettings(["stabilization": enabled], temporary: temporary)
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

    // MARK: - 測光キャリブレーション

    struct MeteringResult: Codable {
        let success: Bool
        let settleSeconds: Int?
        let captureSeconds: Int?
        let photos: [MeteringPhoto]?
        let recommendation: MeteringCalibrationRec?
        let error: String?

        enum CodingKeys: String, CodingKey {
            case success
            case settleSeconds = "settle_seconds"
            case captureSeconds = "capture_seconds"
            case photos, recommendation, error
        }
    }

    struct MeteringPhoto: Codable {
        let filename: String?
        let index: Int?
        let aeGain: Double?
        let aeExposureUs: Double?
        let lux: Double?
        let fileSize: Int?

        enum CodingKeys: String, CodingKey {
            case filename, index, lux
            case aeGain = "ae_gain"
            case aeExposureUs = "ae_exposure_us"
            case fileSize = "file_size"
        }
    }

    struct MeteringCalibrationRec: Codable {
        let avgGain: Double?
        let avgExposureUs: Int?
        let avgLux: Double?
        let recommendedIso: Int?
        let recommendedShutterUs: Int?

        enum CodingKeys: String, CodingKey {
            case avgLux = "avg_lux"
            case avgGain = "avg_gain"
            case avgExposureUs = "avg_exposure_us"
            case recommendedIso = "recommended_iso"
            case recommendedShutterUs = "recommended_shutter_us"
        }
    }

    func meteringCalibrate(settleSeconds: Int = 3, captureSeconds: Int = 3) async throws -> MeteringResult {
        guard let url = URL(string: "\(baseURL)/api/metering/calibrate") else {
            throw CameraAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = TimeInterval(settleSeconds + captureSeconds + 30)

        let body: [String: Any] = [
            "settle_seconds": settleSeconds,
            "capture_seconds": captureSeconds,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await captureSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw CameraAPIError.serverError
        }
        return try JSONDecoder().decode(MeteringResult.self, from: data)
    }

    // MARK: - 撮影

    func captureWithMetadata(
        manualMode: ManualCaptureMode = .current,
        meta: String? = nil,
        location: CaptureLocationPayload? = nil
    ) async throws
        -> (SafeFilename, PhotoMetadata?)
    {
        guard let url = URL(string: "\(baseURL)/api/capture") else {
            throw CameraAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [:]
        if manualMode != .current {
            body["manual_mode"] = manualMode.rawValue
        }
        if let metaValue = meta?.trimmingCharacters(in: .whitespacesAndNewlines), !metaValue.isEmpty {
            body["meta"] = metaValue
        }
        if let location {
            body["location"] = location.jsonObject
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await captureSession.data(for: request)

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

        return (safeFilename, result.metadata)
    }

    /// 撮影を実行し、ファイル名を返す
    func capture(
        manualMode: ManualCaptureMode = .current,
        meta: String? = nil,
        location: CaptureLocationPayload? = nil
    ) async throws -> SafeFilename {
        let (filename, _) = try await captureWithMetadata(
            manualMode: manualMode,
            meta: meta,
            location: location
        )
        return filename
    }

    // MARK: - 画像ダウンロード

    /// 撮影した画像をダウンロード（撮影直後の AP 瞬断に備えてリトライ）
    func downloadImage(filename: SafeFilename, preferThumbnail: Bool = false) async throws -> UIImage {
        let safeFilename = filename.value
        guard !safeFilename.isEmpty else {
            throw CameraAPIError.invalidFilename
        }

        let useThumbnail = preferThumbnail || safeFilename.lowercased().hasSuffix(".dng")

        return try await withRetry(maxRetries: 4, delay: 2.0) {
            guard let url = URL(string: "\(self.baseURL)/api/photo") else {
                throw CameraAPIError.invalidURL
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var body: [String: Any] = ["filename": safeFilename]
            if useThumbnail {
                body["thumbnail"] = true
                body["max_dim"] = 1200
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await self.downloadSession.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw CameraAPIError.downloadFailed
            }

            if httpResponse.statusCode == 404 {
                throw CameraAPIError.downloadFailed
            }

            guard httpResponse.statusCode == 200 else {
                throw CameraAPIError.downloadFailed
            }

            if let image = UIImage(data: data) {
                return image
            }

            #if canImport(CoreImage)
                if let ciImage = CIImage(data: data) {
                    let context = CIContext(options: nil)
                    if let cgImage = context.createCGImage(ciImage, from: ciImage.extent) {
                        return UIImage(cgImage: cgImage)
                    }
                }
            #endif

            throw CameraAPIError.invalidImageData
        }
    }

    // MARK: - 監視制御

    /// 監視を再開
    func restartMonitoring() async throws {
        guard let url = URL(string: "\(baseURL)/api/restart_monitoring") else {
            throw CameraAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let (_, response) = try await lightSession.data(for: request)

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

        let (_, response) = try await lightSession.data(for: request)

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

        let (data, response) = try await lightSession.data(from: url)

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

        let (data, response) = try await lightSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CameraAPIError.serverError
        }

        let decodedResult = try? JSONDecoder().decode(WiFiSwitchResponse.self, from: data)

        if httpResponse.statusCode != 200 {
            if let decodedResult, let message = decodedResult.message {
                throw CameraAPIError.updateFailed(message)
            }
            throw CameraAPIError.serverError
        }

        guard let result = decodedResult else {
            throw CameraAPIError.serverError
        }

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

        let (data, response) = try await lightSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CameraAPIError.serverError
        }

        let decodedResult = try? JSONDecoder().decode(WiFiSwitchResponse.self, from: data)

        if httpResponse.statusCode != 200 {
            if let decodedResult, let message = decodedResult.message {
                throw CameraAPIError.updateFailed(message)
            }
            throw CameraAPIError.serverError
        }

        guard let result = decodedResult else {
            throw CameraAPIError.serverError
        }

        if !result.success {
            throw CameraAPIError.updateFailed(result.message ?? "Wi-Fi write failed")
        }
    }

    /// Wi-Fiネットワークをスキャン
    func scanWiFiNetworks(maxResults: Int = 25, rescan: Bool = true) async throws -> WiFiScanResponse {
        guard let url = URL(string: "\(baseURL)/api/wifi/scan") else {
            throw CameraAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "max_results": maxResults,
            "rescan": rescan
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await lightSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200
        else {
            throw CameraAPIError.serverError
        }

        let decoded = try JSONDecoder().decode(WiFiScanResponse.self, from: data)
        return decoded
    }

    // MARK: - Sensor / Metering

    func fetchSensorStatus() async throws -> SensorStatusResponse {
        guard let url = URL(string: "\(baseURL)/api/sensor/status") else {
            throw CameraAPIError.invalidURL
        }

        let (data, response) = try await lightSession.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
            httpResponse.statusCode == 200
        else {
            throw CameraAPIError.serverError
        }

        let decoded = try JSONDecoder().decode(SensorStatusResponse.self, from: data)
        if !decoded.success {
            throw CameraAPIError.updateFailed(decoded.error ?? "Sensor status fetch failed")
        }
        return decoded
    }

    func fetchMeteringRecommendation(
        targetISO: Int? = nil,
        targetShutterUs: Int? = nil
    ) async throws -> MeteringRecommendation {
        guard let url = URL(string: "\(baseURL)/api/metering") else {
            throw CameraAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [:]
        if let targetISO {
            body["target_iso"] = targetISO
        }
        if let targetShutterUs {
            body["target_shutter_us"] = targetShutterUs
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await lightSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
            httpResponse.statusCode == 200
        else {
            throw CameraAPIError.serverError
        }

        let decoded = try JSONDecoder().decode(MeteringResponse.self, from: data)
        guard decoded.success, let recommendation = decoded.recommendation else {
            throw CameraAPIError.updateFailed(decoded.error ?? "Metering recommendation failed")
        }
        return recommendation
    }

    func applyMeteringRecommendation(
        _ recommendation: MeteringRecommendation,
        temporary: Bool = true
    ) async throws {
        try await updateSettings([
            "iso": recommendation.recommendedISO,
            "shutter_speed": recommendation.recommendedShutterUs,
        ], temporary: temporary)
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
            return "サーバーから写真の取得に失敗しました（PiのSDカードには保存されている可能性があります。ギャラリーから再読み込みしてください）"
        case .invalidImageData:
            return "無効な画像データ"
        }
    }
}
