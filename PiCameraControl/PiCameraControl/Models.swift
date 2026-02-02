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
    let apSsid: String?
    let apPassword: String?

    enum CodingKeys: String, CodingKey {
        case mode, ssid, ip
        case apSsid = "ap_ssid"
        case apPassword = "ap_password"
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

// MARK: - シャッタースピード選択肢

enum ShutterSpeedOption: String, CaseIterable, Identifiable, Hashable, Labelable {
    case auto
    case ss1000, ss500, ss250, ss125, ss60, ss30, ss15, ss8, ss4, ss2, ss1sec, ss2sec

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .ss1000: return "1/1000"
        case .ss500: return "1/500"
        case .ss250: return "1/250"
        case .ss125: return "1/125"
        case .ss60: return "1/60"
        case .ss30: return "1/30"
        case .ss15: return "1/15"
        case .ss8: return "1/8"
        case .ss4: return "1/4"
        case .ss2: return "1/2"
        case .ss1sec: return "1.0s"
        case .ss2sec: return "2.0s"
        }
    }

    var microseconds: Int? {
        switch self {
        case .auto: return nil
        case .ss1000: return 1000
        case .ss500: return 2000
        case .ss250: return 4000
        case .ss125: return 8000
        case .ss60: return 16666
        case .ss30: return 33333
        case .ss15: return 66666
        case .ss8: return 125000
        case .ss4: return 250000
        case .ss2: return 500000
        case .ss1sec: return 1_000_000
        case .ss2sec: return 2_000_000
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
