import AVFoundation
import Foundation

/// iPhone 内蔵カメラの AE から周囲の明るさ（推定 lux）を取得する。
/// Pi 側の測光キャリブレーション（複数枚撮影）の代わりに、撮影前の ISO/SS 決定に使う。
enum iPhoneAmbientMeter {

    struct Reading: Sendable {
        let estimatedLux: Double
        let iso: Float
        let shutterSeconds: Double
        let aperture: Float
    }

    /// 背面カメラの AE が安定するまで短時間待ち、推定 lux を返す（通常 0.3〜0.6 秒）。
    static func measureLux() async throws -> Reading {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard granted else { throw MeterError.cameraDenied }
        } else if status != .authorized {
            throw MeterError.cameraDenied
        }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(for: .video)
        else {
            throw MeterError.noCamera
        }

        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }

        // AE 安定待ち（Pi の calibrate 3+3 秒より大幅に軽い）
        try await Task.sleep(nanoseconds: 450_000_000)

        let iso = device.iso
        let shutter = device.exposureDuration.seconds
        let aperture = device.lensAperture

        guard iso > 0, shutter > 0, aperture > 0 else {
            throw MeterError.unstableAE
        }

        // EV100 = log2(N²/t) - log2(ISO/100), lux ≈ 2.5 × 2^EV
        let ev = log2(Double(aperture * aperture) / shutter) - log2(Double(iso) / 100.0)
        let lux = 2.5 * pow(2.0, ev)

        return Reading(
            estimatedLux: max(0.1, lux),
            iso: iso,
            shutterSeconds: shutter,
            aperture: aperture
        )
    }

    enum MeterError: LocalizedError {
        case cameraDenied
        case noCamera
        case unstableAE

        var errorDescription: String? {
            switch self {
            case .cameraDenied:
                return "カメラへのアクセスが拒否されています。設定アプリで許可してください。"
            case .noCamera:
                return "カメラが利用できません。"
            case .unstableAE:
                return "明るさの測定が安定しませんでした。もう一度お試しください。"
            }
        }
    }
}
