import Foundation

/// カメラ設定のデータモデル（全設定）
struct CameraSettings: Codable {
    var iso: ISOValue
    var shutterSpeed: ShutterSpeedValue
    var whiteBalance: String
    var contrast: Int
    var saturation: Int
    var quality: Int
    var width: Int
    var height: Int
    var monitoringEnabled: Bool
    var detectionThreshold: Int
    var detectionInterval: Double
    var enableMultipleExposure: Bool
    var enable2in1Composition: Bool
    var enableTimestamp: Bool

    enum CodingKeys: String, CodingKey {
        case iso
        case shutterSpeed = "shutter_speed"
        case whiteBalance = "white_balance"
        case contrast, saturation, quality, width, height
        case monitoringEnabled = "monitoring_enabled"
        case detectionThreshold = "detection_threshold"
        case detectionInterval = "detection_interval"
        case enableMultipleExposure = "enable_multiple_exposure"
        case enable2in1Composition = "enable_2in1_composition"
        case enableTimestamp = "enable_timestamp"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        iso = try container.decode(ISOValue.self, forKey: .iso)
        shutterSpeed = try container.decode(ShutterSpeedValue.self, forKey: .shutterSpeed)
        whiteBalance = try container.decodeIfPresent(String.self, forKey: .whiteBalance) ?? "auto"
        contrast = try container.decodeIfPresent(Int.self, forKey: .contrast) ?? 0
        saturation = try container.decodeIfPresent(Int.self, forKey: .saturation) ?? 0
        quality = try container.decodeIfPresent(Int.self, forKey: .quality) ?? 95
        width = try container.decodeIfPresent(Int.self, forKey: .width) ?? 4056
        height = try container.decodeIfPresent(Int.self, forKey: .height) ?? 3040
        monitoringEnabled =
            try container.decodeIfPresent(Bool.self, forKey: .monitoringEnabled) ?? true
        detectionThreshold =
            try container.decodeIfPresent(Int.self, forKey: .detectionThreshold) ?? 30
        detectionInterval =
            try container.decodeIfPresent(Double.self, forKey: .detectionInterval) ?? 1.0
        enableMultipleExposure =
            try container.decodeIfPresent(Bool.self, forKey: .enableMultipleExposure) ?? false
        enable2in1Composition =
            try container.decodeIfPresent(Bool.self, forKey: .enable2in1Composition) ?? false
        enableTimestamp =
            try container.decodeIfPresent(Bool.self, forKey: .enableTimestamp) ?? false
    }
}

/// ISO値（"auto" または数値）
enum ISOValue: Codable, Equatable {
    case auto
    case value(Int)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let stringValue = try? container.decode(String.self), stringValue == "auto" {
            self = .auto
        } else if let intValue = try? container.decode(Int.self) {
            self = .value(intValue)
        } else {
            self = .auto
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .auto:
            try container.encode("auto")
        case .value(let val):
            try container.encode(val)
        }
    }

    var displayString: String {
        switch self {
        case .auto: return "Auto"
        case .value(let val): return "\(val)"
        }
    }
}

/// シャッタースピード値（"auto" または マイクロ秒）
enum ShutterSpeedValue: Codable, Equatable {
    case auto
    case microseconds(Int)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let stringValue = try? container.decode(String.self), stringValue == "auto" {
            self = .auto
        } else if let intValue = try? container.decode(Int.self) {
            self = .microseconds(intValue)
        } else {
            self = .auto
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .auto:
            try container.encode("auto")
        case .microseconds(let val):
            try container.encode(val)
        }
    }

    var displayString: String {
        switch self {
        case .auto: return "Auto"
        case .microseconds(let us):
            return ShutterSpeedOption.allCases.first { $0.microseconds == us }?.label ?? "\(us)μs"
        }
    }
}

/// 撮影結果のレスポンス
struct CaptureResponse: Codable {
    let success: Bool
    let filename: String?
    let error: String?
}

/// サニタイズ済みファイル名
struct SafeFilename: Hashable {
    let value: String
}

/// 設定更新のレスポンス
struct SettingsResponse: Codable {
    let success: Bool
    let error: String?
}

/// Wi-Fiステータス
struct WiFiStatus: Codable {
    let mode: String?
    let ssid: String?
    let ip: String?
    let ipAddress: String?
    let apSsid: String?
    let apPassword: String?

    enum CodingKeys: String, CodingKey {
        case mode, ssid, ip
        case ipAddress = "ip_address"
        case apSsid = "ap_ssid"
        case apPassword = "ap_password"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decodeIfPresent(String.self, forKey: .mode)
        ssid = try container.decodeIfPresent(String.self, forKey: .ssid)
        ip = try container.decodeIfPresent(String.self, forKey: .ip)
        ipAddress = try container.decodeIfPresent(String.self, forKey: .ipAddress)
        apSsid = try container.decodeIfPresent(String.self, forKey: .apSsid)
        apPassword = try container.decodeIfPresent(String.self, forKey: .apPassword)
    }

    var resolvedIP: String? {
        if let ip, !ip.isEmpty { return ip }
        if let ipAddress, !ipAddress.isEmpty { return ipAddress }
        return nil
    }
}

/// Wi-Fiモード切り替えレスポンス
struct WiFiSwitchResponse: Codable {
    let success: Bool
    let message: String?
}

// MARK: - Helper Protocols

protocol Labelable {
    var label: String { get }
}

// MARK: - ISO選択肢

enum ISOOption: String, CaseIterable, Identifiable, Hashable, Labelable {
    case auto
    case iso100, iso200, iso400, iso800, iso1600, iso3200

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .iso100: return "100"
        case .iso200: return "200"
        case .iso400: return "400"
        case .iso800: return "800"
        case .iso1600: return "1600"
        case .iso3200: return "3200"
        }
    }

    var isoValue: ISOValue {
        switch self {
        case .auto: return .auto
        case .iso100: return .value(100)
        case .iso200: return .value(200)
        case .iso400: return .value(400)
        case .iso800: return .value(800)
        case .iso1600: return .value(1600)
        case .iso3200: return .value(3200)
        }
    }

    static func from(_ value: ISOValue) -> ISOOption {
        switch value {
        case .auto: return .auto
        case .value(let v):
            return allCases.first {
                if case .value(let optVal) = $0.isoValue { return optVal == v }
                return false
            } ?? .auto
        }
    }
}

// MARK: - 画質選択肢

enum QualityOption: Int, CaseIterable, Identifiable, Hashable, Labelable {
    case q60 = 60
    case q70 = 70
    case q80 = 80
    case q90 = 90
    case q95 = 95

    var id: String { "q\(rawValue)" }

    var label: String {
        "Q\(rawValue)"
    }

    var qualityValue: Int { rawValue }

    static func from(_ value: Int) -> QualityOption {
        return allCases.first { $0.rawValue == value } ?? .q90
    }
}

// MARK: - シャッタースピード選択肢

enum ShutterSpeedOption: String, CaseIterable, Identifiable, Hashable, Labelable {
    case auto
    case ss400, ss250, ss125, ss60, ss30, ss15
    case ss8, ss4, ss2
    case ss1s, ss2s, ss3s, ss4s, ss5s, ss6s, ss7s, ss8s, ss9s, ss10s
    case ss11s, ss12s, ss13s, ss14s, ss15s, ss16s, ss17s, ss18s, ss19s, ss20s

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .ss400: return "1/400"
        case .ss250: return "1/250"
        case .ss125: return "1/125"
        case .ss60: return "1/60"
        case .ss30: return "1/30"
        case .ss15: return "1/15"
        case .ss8: return "1/8"
        case .ss4: return "1/4"
        case .ss2: return "1/2"
        case .ss1s: return "1s"
        case .ss2s: return "2s"
        case .ss3s: return "3s"
        case .ss4s: return "4s"
        case .ss5s: return "5s"
        case .ss6s: return "6s"
        case .ss7s: return "7s"
        case .ss8s: return "8s"
        case .ss9s: return "9s"
        case .ss10s: return "10s"
        case .ss11s: return "11s"
        case .ss12s: return "12s"
        case .ss13s: return "13s"
        case .ss14s: return "14s"
        case .ss15s: return "15s"
        case .ss16s: return "16s"
        case .ss17s: return "17s"
        case .ss18s: return "18s"
        case .ss19s: return "19s"
        case .ss20s: return "20s"
        }
    }

    var microseconds: Int? {
        switch self {
        case .auto: return nil
        case .ss400: return 2500
        case .ss250: return 4000
        case .ss125: return 8000
        case .ss60: return 16666
        case .ss30: return 33333
        case .ss15: return 66666
        case .ss8: return 125000
        case .ss4: return 250000
        case .ss2: return 500000
        case .ss1s: return 1_000_000
        case .ss2s: return 2_000_000
        case .ss3s: return 3_000_000
        case .ss4s: return 4_000_000
        case .ss5s: return 5_000_000
        case .ss6s: return 6_000_000
        case .ss7s: return 7_000_000
        case .ss8s: return 8_000_000
        case .ss9s: return 9_000_000
        case .ss10s: return 10_000_000
        case .ss11s: return 11_000_000
        case .ss12s: return 12_000_000
        case .ss13s: return 13_000_000
        case .ss14s: return 14_000_000
        case .ss15s: return 15_000_000
        case .ss16s: return 16_000_000
        case .ss17s: return 17_000_000
        case .ss18s: return 18_000_000
        case .ss19s: return 19_000_000
        case .ss20s: return 20_000_000
        }
    }

    var shutterValue: ShutterSpeedValue {
        if let us = microseconds {
            return .microseconds(us)
        }
        return .auto
    }

    static func from(_ value: ShutterSpeedValue) -> ShutterSpeedOption {
        switch value {
        case .auto: return .auto
        case .microseconds(let us):
            return allCases.first { $0.microseconds == us } ?? .auto
        }
    }
}

// MARK: - ホワイトバランス選択肢

enum WhiteBalanceOption: String, CaseIterable, Identifiable, Hashable, Labelable {
    case auto, daylight, cloudy, tungsten, fluorescent, shade

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .daylight: return "Daylight"
        case .cloudy: return "Cloudy"
        case .tungsten: return "Tungsten"
        case .fluorescent: return "Fluorescent"
        case .shade: return "Shade"
        }
    }

    static func from(_ value: String) -> WhiteBalanceOption {
        return allCases.first { $0.rawValue == value } ?? .auto
    }
}
