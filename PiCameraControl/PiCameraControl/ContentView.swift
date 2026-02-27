import SwiftUI
import CoreLocation
import PhotosUI

#if canImport(UIKit)
    import UIKit
#endif

// MARK: - Nikon 35Ti Styles

struct LiquidGlassModifier: ViewModifier {
    var radius: CGFloat = 20

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius)
                    .fill(Color(red: 0.15, green: 0.15, blue: 0.17))
                    .shadow(color: .black.opacity(0.3), radius: 10, y: 5)
            )
    }
}

@MainActor
final class CaptureLocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var authorization: CLAuthorizationStatus
    @Published private(set) var latestLocation: CLLocation?
    @Published private(set) var lastLocationError: String?

    private let manager = CLLocationManager()

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 20
    }

    func requestAuthorizationAndStart() {
        authorization = manager.authorizationStatus
        if authorization == .notDetermined {
            manager.requestWhenInUseAuthorization()
            return
        }
        if authorization == .authorizedAlways || authorization == .authorizedWhenInUse {
            manager.startUpdatingLocation()
        }
    }

    func capturePayload(label: String? = nil) -> CaptureLocationPayload? {
        guard let location = latestLocation else {
            return nil
        }
        let age = abs(location.timestamp.timeIntervalSinceNow)
        if age > 60 * 20 {
            return nil
        }
        if location.horizontalAccuracy <= 0 || location.horizontalAccuracy > 500 {
            return nil
        }
        return CaptureLocationPayload(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            label: label
        )
    }

    var statusLabel: String {
        if let latestLocation {
            let age = Int(abs(latestLocation.timestamp.timeIntervalSinceNow))
            return "位置情報: 取得済み (±\(Int(max(latestLocation.horizontalAccuracy, 0)))m / \(age)s前)"
        }

        switch authorization {
        case .authorizedAlways, .authorizedWhenInUse:
            return "位置情報: 取得中"
        case .denied, .restricted:
            return "位置情報: 許可なし"
        case .notDetermined:
            return "位置情報: 未許可"
        @unknown default:
            return "位置情報: 不明"
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            authorization = manager.authorizationStatus
            if authorization == .authorizedAlways || authorization == .authorizedWhenInUse {
                manager.startUpdatingLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            latestLocation = locations.last
            lastLocationError = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            lastLocationError = error.localizedDescription
        }
    }
}

extension View {
    func liquidGlassStyle(radius: CGFloat = 20) -> some View {
        self.modifier(LiquidGlassModifier(radius: radius))
    }
}

// MARK: - Components

struct GlassToggle: View {
    var icon: String
    var title: String
    @Binding var isOn: Bool
    var action: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(isOn ? MinimalTheme.Accent.primary : .secondary)

            Text(title)
                .font(.caption.weight(.medium))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(SwitchToggleStyle(tint: .blue))
                .scaleEffect(0.9)
                .onChange(of: isOn) { oldValue, newValue in
                    action()
                }
        }
        .frame(maxWidth: .infinity)
        .minimalCard()
    }
}

// MARK: - Main View

struct ContentView: View {

    private enum SyncState: Equatable {
        case idle
        case syncing(String)
        case success(String)
    }

    // MARK: - State
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("serverIP") private var serverIP: String = "192.168.4.1"
    @AppStorage("apSSID") private var savedAPSSID: String = "PiCamera"
    @AppStorage("apPassword") private var savedAPPassword: String = "picamera123"
    @AppStorage("appAppearanceMode") private var appAppearanceMode: String = "system"

    @State private var isEditingIP: Bool = false

    // Camera Settings
    @State private var selectedCameraMode: CameraModeOption = .standard
    @State private var selectedISO: ISOOption = .auto
    @State private var selectedShutterSpeed: ShutterSpeedOption = .auto
    @State private var selectedQuality: QualityOption = .q90
    @State private var selectedWhiteBalance: WhiteBalanceOption = .auto
    @State private var detectionThreshold: Double = 30

    // Toggles
    @State private var enableMultipleExposure: Bool = false
    @State private var multipleExposureMode: String = "blend"  // "blend" or "additive"
    @State private var enable2in1Composition: Bool = false
    @State private var enableTimestamp: Bool = false
    @State private var enableStabilization: Bool = true
    @State private var enableRawMode: Bool = false
    @State private var manualModeEnabled: Bool = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var importedImage: UIImage?

    // Network
    @State private var wifiMode: String = "取得中..."
    @State private var wifiSSID: String = "-"
    @State private var wifiIP: String = "-"
    @State private var apSSIDInput: String = ""
    @State private var apPasswordInput: String = ""
    @State private var homeSSIDInput: String = ""
    @State private var homePasswordInput: String = ""
    @State private var isAPMode: Bool = false
    @State private var targetAPMode: Bool = false

    // Capture
    @State private var capturedImage: UIImage? = nil
    @State private var isLoading: Bool = false
    @State private var isCapturing: Bool = false
    @State private var isMetering: Bool = false
    @State private var meteringResult: CameraAPI.MeteringCalibrationRec? = nil
    @State private var meteringToast: String? = nil
    @State private var isSwitchingWiFi: Bool = false
    @State private var isScanning: Bool = false
    @State private var scannedNetworks: [WiFiNetwork] = []
    @State private var scanError: String? = nil
    @State private var errorMessage: String? = nil
    @State private var syncState: SyncState = .idle
    @State private var isApplyingRemoteSettings: Bool = false
    @State private var hasLoadedSettings: Bool = false
    @State private var showResetTemporaryConfirm: Bool = false
    @State private var manualCaptureMode: ManualCaptureMode = .current
    @State private var manualCaptureMeta: String = ""
    @State private var lastCaptureMetadata: PhotoMetadata? = nil
    @State private var captureToast: String? = nil
    @State private var sensorStatus: SensorRuntimeStatus? = nil
    @State private var meteringRecommendation: MeteringRecommendation? = nil
    @StateObject private var captureLocationProvider = CaptureLocationProvider()

    // Section expansion state
    @State private var expandedCamera = true
    @State private var expandedFeatures = false
    @State private var expandedCapture = true
    @State private var expandedSensor = false
    @State private var expandedAppearance = false
    @State private var expandedNetwork = false
    @State private var expandedTroubleshoot = false

    @FocusState private var isManualMetaFocused: Bool

    private var api: CameraAPI {
        CameraAPI(baseURL: "http://\(serverIP):8001")
    }

    private var shutterOptions: [ShutterSpeedOption] {
        if manualModeEnabled {
            return ShutterSpeedOption.allCases
        }
        // 非手動モードでは長時間露光（30s以上）を非表示
        return ShutterSpeedOption.allCases.filter {
            guard let us = $0.microseconds else { return true }
            return us <= 20_000_000
        }
    }

    // MARK: - Section Header Helper

    private func sectionHeader(icon: String, title: String, badge: String? = nil) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(MinimalTheme.Accent.primary)
                .frame(width: 24)
            Text(title)
                .font(MinimalTypography.headlineSmall)
                .foregroundColor(.primary)
            if let badge {
                Text(badge)
                    .font(MinimalTypography.labelSmall)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(MinimalTheme.Accent.primary.opacity(0.1))
                    .foregroundColor(MinimalTheme.Accent.primary)
                    .cornerRadius(4)
            }
            Spacer()
        }
    }

    // MARK: - Body

    var body: some View {
        NavigationView {
            ZStack {
                // Minimal White Background
                MinimalTheme.Background.primary
                    .ignoresSafeArea()

                LinearGradient(
                    colors: [
                        Color.blue.opacity(0.06),
                        Color.teal.opacity(0.04),
                        Color.clear,
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 24) {

                        syncBanner

                        // 光検知（常時表示）
                        monitoringQuickSection

                        // 📷 カメラ設定
                        DisclosureGroup(isExpanded: $expandedCamera) {
                            VStack(spacing: 20) {
                                // MODE Picker
                                VStack(alignment: .leading, spacing: 14) {
                                    Text("MODE")
                                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .tracking(1.5)
                                        .padding(.horizontal, 4)

                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 8) {
                                            ForEach(CameraModeOption.allCases) { mode in
                                                let isActive = selectedCameraMode == mode
                                                Button {
                                                    withAnimation(.easeInOut(duration: 0.15)) {
                                                        selectedCameraMode = mode
                                                        updateCameraMode(mode)
                                                    }
                                                } label: {
                                                    VStack(spacing: 4) {
                                                        Image(systemName: mode.icon)
                                                            .font(.system(size: 16, weight: .semibold))
                                                        Text(mode.subtitle)
                                                            .font(.system(size: 11, weight: .bold))
                                                    }
                                                    .frame(width: 56, height: 52)
                                                    .foregroundColor(isActive ? .white : .secondary)
                                                    .background(
                                                        RoundedRectangle(cornerRadius: 12)
                                                            .fill(isActive ? Color.red.opacity(0.85) : Color.primary.opacity(0.06))
                                                    )
                                                }
                                            }
                                        }
                                    }
                                }

                                if selectedCameraMode == .raw {
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack {
                                            Image(systemName: "camera.aperture")
                                                .foregroundColor(.blue)
                                            Text("RAWモード（PiCamera HQ）")
                                                .font(.caption.weight(.bold))
                                                .foregroundColor(.primary)
                                        }
                                        Text("• DNG形式（12.3MP: 4056x3040）\n• Sony IMX477センサー生データ\n• 全自動処理OFF（ピュアRAW）\n• ISO 100-16000対応\n• 手動撮影専用（光検知無効）")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                            .lineSpacing(4)
                                    }
                                    .padding(12)
                                    .background(Color.blue.opacity(0.1))
                                    .cornerRadius(12)
                                }

                                // カメラモード別JPEG品質説明
                                HStack {
                                    Image(systemName: "photo")
                                        .foregroundColor(.gray.opacity(0.7))
                                        .font(.caption)
                                    Text(qualityDescriptionForMode(selectedCameraMode))
                                        .font(.caption2)
                                        .foregroundColor(.gray.opacity(0.9))
                                }
                                .padding(.horizontal, 4)

                                Divider()

                                isoQuickModule

                                Divider()

                                shutterPickerModule

                                Divider()

                                pickerModule(
                                    title: "QUALITY", selection: $selectedQuality,
                                    options: QualityOption.allCases
                                ) { opt in
                                    updateQuality(opt)
                                }

                                Divider()

                                whiteBalanceModule

                                if !manualModeEnabled {
                                    Divider()
                                    thresholdModule
                                }
                            }
                            .padding(.top, 8)
                        } label: {
                            sectionHeader(icon: "camera.fill", title: "カメラ設定")
                        }
                        .tint(.primary)
                        .minimalCard()

                        // ⚙️ 機能設定
                        DisclosureGroup(isExpanded: $expandedFeatures) {
                            VStack(spacing: 16) {
                                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                                    GlassToggle(icon: "hand.raised.fill", title: "手動モード", isOn: $manualModeEnabled) {
                                        updateMonitoringEnabled(!manualModeEnabled)
                                    }
                                    GlassToggle(icon: "square.stack.3d.up.fill", title: "多重露光", isOn: $enableMultipleExposure) {
                                        updateToggle(multipleExposure: enableMultipleExposure)
                                    }
                                    GlassToggle(icon: "rectangle.split.2x1.fill", title: "2-in-1", isOn: $enable2in1Composition) {
                                        updateToggle(composition2in1: enable2in1Composition)
                                    }
                                    GlassToggle(icon: "clock.fill", title: "日時刻印", isOn: $enableTimestamp) {
                                        updateToggle(timestamp: enableTimestamp)
                                    }
                                    GlassToggle(icon: "waveform.path", title: "手ぶれ補正", isOn: $enableStabilization) {
                                        Task {
                                            do {
                                                try await api.updateStabilization(enableStabilization, temporary: false)
                                            } catch {
                                                print("手ぶれ補正の更新に失敗: \(error)")
                                            }
                                        }
                                    }
                                    GlassToggle(icon: "doc.fill", title: "RAWモード", isOn: $enableRawMode) {
                                        Task {
                                            do {
                                                try await api.updateSettings(["raw_mode": enableRawMode], temporary: false)
                                            } catch {
                                                print("RAWモードの更新に失敗: \(error)")
                                            }
                                        }
                                    }
                                }

                                if enableStabilization {
                                    Text("⚠️ 手ぶれ補正ONで画質がわずかに劣化します")
                                        .font(.caption)
                                        .foregroundColor(.orange.opacity(0.8))
                                        .padding(.horizontal, 4)
                                }

                                if enableRawMode {
                                    Text("📷 RAWモード: DNG形式で保存（12.3MP）")
                                        .font(.caption)
                                        .foregroundColor(.blue.opacity(0.8))
                                        .padding(.horizontal, 4)
                                }

                                if enableMultipleExposure {
                                    Divider()
                                    VStack(alignment: .leading, spacing: 12) {
                                        Text("MULTIPLE EXPOSURE MODE")
                                            .font(.caption2.weight(.black))
                                            .foregroundColor(.secondary)
                                            .padding(.horizontal, 4)

                                        ScrollView(.horizontal, showsIndicators: false) {
                                            HStack(spacing: 10) {
                                                Button {
                                                    multipleExposureMode = "blend"
                                                    updateMultipleExposureMode("blend")
                                                } label: {
                                                    VStack(alignment: .leading, spacing: 4) {
                                                        Text("BLEND")
                                                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                                                        Text("50:50ブレンド")
                                                            .font(.system(size: 9, weight: .medium))
                                                            .foregroundColor(.secondary)
                                                    }
                                                    .padding(.horizontal, 14)
                                                    .padding(.vertical, 10)
                                                    .background(
                                                        RoundedRectangle(cornerRadius: 10)
                                                            .fill(multipleExposureMode == "blend" ? Color.purple.opacity(0.85) : Color.gray.opacity(0.15))
                                                    )
                                                    .foregroundColor(multipleExposureMode == "blend" ? .white : .primary)
                                                }

                                                Button {
                                                    multipleExposureMode = "additive"
                                                    updateMultipleExposureMode("additive")
                                                } label: {
                                                    VStack(alignment: .leading, spacing: 4) {
                                                        Text("ADDITIVE")
                                                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                                                        Text("加算合成（星の軌跡）")
                                                            .font(.system(size: 9, weight: .medium))
                                                            .foregroundColor(.secondary)
                                                    }
                                                    .padding(.horizontal, 14)
                                                    .padding(.vertical, 10)
                                                    .background(
                                                        RoundedRectangle(cornerRadius: 10)
                                                            .fill(multipleExposureMode == "additive" ? Color.orange.opacity(0.85) : Color.gray.opacity(0.15))
                                                    )
                                                    .foregroundColor(multipleExposureMode == "additive" ? .white : .primary)
                                                }
                                            }
                                        }
                                    }
                                }

                                Divider()

                                Button {
                                    showResetTemporaryConfirm = true
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "arrow.uturn.backward")
                                            .font(.caption.weight(.bold))
                                        Text("一時変更をリセット")
                                            .font(.caption.weight(.bold))
                                        Spacer()
                                    }
                                    .padding(.vertical, 4)
                                    .foregroundColor(.blue)
                                }
                                .disabled(isLoading || isCapturing)
                                .alert("一時変更をリセットしますか？", isPresented: $showResetTemporaryConfirm) {
                                    Button("リセット", role: .destructive) {
                                        resetTemporarySettings()
                                    }
                                    Button("キャンセル", role: .cancel) {}
                                } message: {
                                    Text("ISO/シャッター/WB/画質/閾値などの一時変更を元に戻します")
                                }
                            }
                            .padding(.top, 8)
                        } label: {
                            sectionHeader(icon: "slider.horizontal.3", title: "機能設定")
                        }
                        .tint(.primary)
                        .minimalCard()

                        // 📸 撮影
                        DisclosureGroup(isExpanded: $expandedCapture) {
                            captureSection
                                .sensoryFeedback(.impact(flexibility: .rigid), trigger: isCapturing)
                                .padding(.top, 8)
                        } label: {
                            sectionHeader(icon: "camera.shutter.button", title: "撮影")
                        }
                        .tint(.primary)
                        .minimalCard()

                        // 📊 センサー
                        DisclosureGroup(isExpanded: $expandedSensor) {
                            sensorStatusSection
                                .padding(.top, 8)
                        } label: {
                            sectionHeader(icon: "gauge.with.dots.needle.33percent", title: "センサー")
                        }
                        .tint(.primary)
                        .minimalCard()

                        // 🎨 表示設定
                        DisclosureGroup(isExpanded: $expandedAppearance) {
                            appearanceSection
                                .padding(.top, 8)
                        } label: {
                            sectionHeader(icon: "paintbrush.fill", title: "表示設定")
                        }
                        .tint(.primary)
                        .minimalCard()

                        // 🌐 ネットワーク
                        DisclosureGroup(isExpanded: $expandedNetwork) {
                            networkSection
                                .padding(.top, 8)
                        } label: {
                            sectionHeader(icon: "wifi", title: "ネットワーク")
                        }
                        .tint(.primary)
                        .minimalCard()

                        // 🛠 トラブルシューティング
                        DisclosureGroup(isExpanded: $expandedTroubleshoot) {
                            troubleshootSection
                                .padding(.top, 8)
                        } label: {
                            sectionHeader(icon: "wrench.and.screwdriver.fill", title: "トラブルシューティング")
                        }
                        .tint(.primary)
                        .minimalCard()

                        Spacer(minLength: 80)
                    }
                    .padding(20)
                }

                if let message = errorMessage {
                    VStack(spacing: 0) {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)

                            ScrollView {
                                Text(message)
                                    .font(.caption.weight(.medium))
                                    .foregroundColor(.primary)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 120)

                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    errorMessage = nil
                                }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                        }
                        .minimalCard()
                        .padding(.horizontal, 20)
                        .padding(.top, 12)

                        Spacer(minLength: 0)
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(1)
                }
            }
            .navigationTitle("PiCamera Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        isEditingIP = true
                    } label: {
                        Label("Settings", systemImage: "slider.horizontal.3")
                            .labelStyle(.iconOnly)
                            .foregroundColor(.primary)
                            .padding(8)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: loadAllSettings) {
                        Label("Refresh", systemImage: "arrow.triangle.2.circlepath")
                            .labelStyle(.iconOnly)
                            .foregroundColor(.primary)
                            .padding(8)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                }
            }
            .alert("SERVER SETTINGS", isPresented: $isEditingIP) {
                TextField("IP Address", text: $serverIP)
                    .autocorrectionDisabled()
                Button("Update") {
                    // SSRF対策: URL検証
                    let fullURL = "http://\(serverIP):8001"
                    if validateServerURL(fullURL) {
                        loadAllSettings()
                    } else {
                        // 無効な場合はエラー表示してデフォルトに戻す
                        serverIP = "192.168.4.1"
                        errorMessage = "無効なIPアドレスです。プライベートIP範囲を使用してください。"
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .onAppear {
                apSSIDInput = savedAPSSID
                apPasswordInput = savedAPPassword
                captureLocationProvider.requestAuthorizationAndStart()
                if !hasLoadedSettings {
                    hasLoadedSettings = true
                    loadAllSettings()
                }
            }
            .onChange(of: selectedPhotoItem) { oldItem, newItem in
                Task {
                    if let newItem = newItem,
                       let data = try? await newItem.loadTransferable(type: Data.self),
                       let uiImage = UIImage(data: data) {
                        await MainActor.run {
                            importedImage = uiImage
                        }
                    }
                }
            }
            .sheet(item: Binding(
                get: { importedImage.map { ImportedImageWrapper(image: $0) } },
                set: { importedImage = $0?.image }
            )) { wrapper in
                PhotoEditorView(originalImage: wrapper.image)
            }
        }
    }

    private struct ImportedImageWrapper: Identifiable {
        let id = UUID()
        let image: UIImage
    }


    private func runMetering() {
        isMetering = true
        errorMessage = nil
        let apiClient = api
        let (targetISO, targetShutter) = meteringTargetsFromSelection()
        Task {
            do {
                let recommendation = try await apiClient.fetchMeteringRecommendation(
                    targetISO: targetISO,
                    targetShutterUs: targetShutter
                )
                let sensor = try? await apiClient.fetchSensorStatus()
                await MainActor.run {
                    meteringRecommendation = recommendation
                    sensorStatus = sensor?.sensor
                    isMetering = false
                }
            } catch {
                await MainActor.run {
                    isMetering = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func applyMeteringRecommendation(_ recommendation: MeteringRecommendation) {
        isMetering = true
        errorMessage = nil
        let apiClient = api
        Task {
            do {
                try await apiClient.applyMeteringRecommendation(recommendation)
                let settings = try await apiClient.fetchSettings()
                let sensor = try? await apiClient.fetchSensorStatus()
                await MainActor.run {
                    applyRemoteSettings(settings)
                    sensorStatus = sensor?.sensor
                    syncState = .success("測光提案を適用しました")
                    isMetering = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        if syncState == .success("測光提案を適用しました") {
                            syncState = .idle
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    isMetering = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func meteringTargetsFromSelection() -> (Int?, Int?) {
        var targetISO: Int?
        switch selectedISO.isoValue {
        case .auto:
            targetISO = nil
        case .value(let value):
            targetISO = value
        }

        var targetShutter: Int?
        switch selectedShutterSpeed.shutterValue {
        case .auto:
            targetShutter = nil
        case .microseconds(let us):
            targetShutter = us
        }

        return (targetISO, targetShutter)
    }

    private func formatSensorValue(_ value: Double?, digits: Int) -> String {
        guard let value else { return "-" }
        return String(format: "%.*f", digits, value)
    }

    private func connectHomeWiFi() {
        if homePasswordInput.count < 8 {
            errorMessage = "HOME WIFI PASSWORD は8文字以上必要です"
            return
        }
        isSwitchingWiFi = true
        errorMessage = nil
        let apiClient = api
        Task {
            do {
                try await apiClient.writeWpaSettings(ssid: homeSSIDInput, psk: homePasswordInput)
            } catch {
                await MainActor.run {
                    errorMessage = "家Wi-Fi設定の書き込みに失敗しました"
                    isSwitchingWiFi = false
                }
                return
            }

            do {
                try await apiClient.switchWiFiMode(toAP: false)
            } catch {
                await MainActor.run {
                    errorMessage = "家Wi-Fiへの切替開始に失敗しました。SSID/パスワードを確認してください。"
                    isSwitchingWiFi = false
                }
                return
            }

            await MainActor.run {
                serverIP = "raspberrypi.local"
                errorMessage = "テザリング切替を開始しました。家Wi-Fiへ接続し直してRefreshしてください。"
                isSwitchingWiFi = false
            }
        }
    }

    // MARK: - Subviews

    private func pickerModule<T: Identifiable & CaseIterable & Hashable>(
        title: String, selection: Binding<T>, options: T.AllCases, onChange: @escaping (T) -> Void
    ) -> some View where T.AllCases: RandomAccessCollection, T.ID == String {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption2.weight(.black))
                .foregroundColor(.secondary)
                .padding(.leading, 4)

            Picker(title, selection: selection) {
                ForEach(options) { opt in
                    if let labelable = opt as? Labelable {
                        Text(labelable.label).tag(opt)
                    } else {
                        Text(verbatim: String(describing: opt)).tag(opt)
                    }
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .onChange(of: selection.wrappedValue) { oldValue, newValue in
                onChange(newValue)
            }
        }
    }

    private var monitoringQuickSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("LIGHT DETECTION")
                    .font(.caption2.weight(.black))
                    .foregroundColor(.secondary)
                Spacer()
                Text(manualModeEnabled ? "PAUSED" : "ACTIVE")
                    .font(.caption2.weight(.heavy))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background((manualModeEnabled ? Color.orange : Color.green).opacity(0.2))
                    .foregroundColor(manualModeEnabled ? .orange : .green)
                    .cornerRadius(8)
            }

            Button {
                quickToggleMonitoring()
            } label: {
                Text(manualModeEnabled ? "光検知を再開" : "光検知を一時停止")
                    .font(.caption.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(manualModeEnabled ? Color.green : Color.orange)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }

            Text("屋外運用時は、移動・調整中だけ停止し、設置後に再開すると誤撮影と消費電力を抑えられます。")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .minimalCard()
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("APPEARANCE")
                    .font(.caption2.weight(.black))
                    .foregroundColor(.secondary)
                Spacer()
                Text(colorScheme == .dark ? "現在: DARK" : "現在: LIGHT")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.secondary)
            }

            Picker("外観", selection: $appAppearanceMode) {
                Text("自動").tag("system")
                Text("ライト").tag("light")
                Text("ダーク").tag("dark")
            }
            .pickerStyle(.segmented)

            Text("Systemにすると端末設定に追従します。屋外撮影はダーク固定が見やすいことが多いです。")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var isoQuickModule: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("ISO")
                    .font(.caption2.weight(.black))
                    .foregroundColor(.secondary)
                Spacer()
                Text(selectedISO.label)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(.blue)

                HStack(spacing: 8) {
                    Button {
                        shiftISO(step: -1)
                    } label: {
                        Image(systemName: "minus")
                            .font(.caption.weight(.bold))
                    }
                    .buttonStyle(.bordered)

                    Button {
                        shiftISO(step: 1)
                    } label: {
                        Image(systemName: "plus")
                            .font(.caption.weight(.bold))
                    }
                    .buttonStyle(.bordered)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ISOOption.allCases) { option in
                        quickChip(
                            title: option.label,
                            active: selectedISO == option,
                            activeColor: .blue
                        ) {
                            selectedISO = option
                            updateISO(option)
                        }
                    }
                }
            }
        }
    }

    private var whiteBalanceModule: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("WHITE BALANCE")
                .font(.caption2.weight(.black))
                .foregroundColor(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(WhiteBalanceOption.allCases) { option in
                        Button {
                            selectedWhiteBalance = option
                            updateWhiteBalance(option)
                        } label: {
                            Text(option.label)
                                .font(.caption.weight(.medium))
                                .padding(.vertical, 8)
                                .padding(.horizontal, 16)
                                .background(
                                    selectedWhiteBalance == option
                                        ? Color.blue : Color.primary.opacity(0.05)
                                )
                                .foregroundColor(selectedWhiteBalance == option ? .white : .primary)
                                .cornerRadius(12)
                        }
                    }
                }
            }
        }
    }

    private var sensorStatusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("SENSOR STATUS")
                    .font(.caption2.weight(.black))
                    .foregroundColor(.secondary)

                Spacer()

                if isMetering {
                    ProgressView()
                        .scaleEffect(0.8)
                }

                Button {
                    runMetering()
                } label: {
                    Text("測光")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.orange)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                .disabled(isMetering)
            }

            if let sensorStatus {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("STATE: \((sensorStatus.state ?? "-").uppercased())")
                        Text("MODE: \((sensorStatus.cameraMode ?? "-").uppercased())")
                        Text("BRIGHT: \(formatSensorValue(sensorStatus.brightness, digits: 2))")
                    }
                    .monospacedDigit()

                    Spacer()

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Δ%: \(formatSensorValue(sensorStatus.lastChangePercent, digits: 2))")
                        Text("LUX: \(formatSensorValue(sensorStatus.lux, digits: 2))")
                        Text("D→C: \(formatSensorValue(sensorStatus.lastDetectToCaptureMs, digits: 1))ms")
                    }
                    .monospacedDigit()
                }
                .font(.caption2.weight(.medium))
                .foregroundColor(.secondary)
            } else {
                Text("センサーステータス未取得")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let recommendation = meteringRecommendation {
                VStack(alignment: .leading, spacing: 8) {
                    Text("METERING RESULT")
                        .font(.caption2.weight(.black))
                        .foregroundColor(.secondary)

                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("ISO: \(recommendation.recommendedISO)")
                            Text("SS: \(recommendation.recommendedShutterLabel ?? "-")")
                        }
                        .monospacedDigit()

                        Spacer()

                        VStack(alignment: .leading, spacing: 4) {
                            Text("BASE ISO: \(recommendation.baseISO.map(String.init) ?? "-")")
                            Text("BASE SS: \(recommendation.baseShutterLabel ?? "-")")
                        }
                        .monospacedDigit()
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundColor(.secondary)

                    Button {
                        applyMeteringRecommendation(recommendation)
                    } label: {
                        Text("提案をISO/SSに適用")
                            .font(.caption.weight(.black))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.orange.opacity(0.9))
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                    .disabled(isMetering)
                }
                .padding(12)
                .background(Color.primary.opacity(0.05))
                .cornerRadius(14)
            }
        }
    }

    private var shutterPickerModule: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("SHUTTER")
                    .font(.caption2.weight(.black))
                    .foregroundColor(.secondary)
                Spacer()
                Text(selectedShutterSpeed.label)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(.indigo)

                HStack(spacing: 8) {
                    Button {
                        shiftShutter(step: -1)
                    } label: {
                        Image(systemName: "minus")
                            .font(.caption.weight(.bold))
                    }
                    .buttonStyle(.bordered)

                    Button {
                        shiftShutter(step: 1)
                    } label: {
                        Image(systemName: "plus")
                            .font(.caption.weight(.bold))
                    }
                    .buttonStyle(.bordered)
                }
            }

            // Auto
            quickChip(title: "Auto", active: selectedShutterSpeed == .auto, activeColor: .indigo) {
                selectedShutterSpeed = .auto
                updateShutterSpeed(.auto)
            }

            // 高速 (1/8000〜1/125)
            let fastOptions = shutterOptions.filter { ($0.microseconds ?? 0) > 0 && ($0.microseconds ?? 0) <= 8000 }
            if !fastOptions.isEmpty {
                Text("HIGH SPEED")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.6))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(fastOptions, id: \.self) { opt in
                            quickChip(title: opt.label, active: selectedShutterSpeed == opt, activeColor: .indigo) {
                                selectedShutterSpeed = opt
                                updateShutterSpeed(opt)
                            }
                        }
                    }
                }
            }

            // 標準 (1/60〜1/2)
            let midOptions = shutterOptions.filter { ($0.microseconds ?? 0) > 8000 && ($0.microseconds ?? 0) <= 500000 }
            if !midOptions.isEmpty {
                Text("STANDARD")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.6))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(midOptions, id: \.self) { opt in
                            quickChip(title: opt.label, active: selectedShutterSpeed == opt, activeColor: .indigo) {
                                selectedShutterSpeed = opt
                                updateShutterSpeed(opt)
                            }
                        }
                    }
                }
            }

            // 長時間 (1s〜)
            let slowOptions = shutterOptions.filter { ($0.microseconds ?? 0) > 500000 }
            if !slowOptions.isEmpty {
                Text("LONG EXPOSURE")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.6))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(slowOptions, id: \.self) { opt in
                            quickChip(title: opt.label, active: selectedShutterSpeed == opt, activeColor: .orange) {
                                selectedShutterSpeed = opt
                                updateShutterSpeed(opt)
                            }
                        }
                    }
                }
            }
        }
    }

    private var thresholdModule: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("DETECTION THRESHOLD")
                    .font(.caption2.weight(.black))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(Int(detectionThreshold))%")
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .foregroundColor(.blue)
            }

            Slider(value: $detectionThreshold, in: 0...100, step: 1) { editing in
                if !editing {
                    updateThreshold(Int(detectionThreshold))
                }
            }
            .accentColor(.blue)
        }
    }

    private var captureSection: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                pickerModule(
                    title: "MANUAL MODE", selection: $manualCaptureMode,
                    options: ManualCaptureMode.allCases
                ) { mode in
                    manualCaptureMode = mode
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("META")
                        .font(.caption2.weight(.black))
                        .foregroundColor(.secondary)
                        .padding(.leading, 4)
                    TextField("例: test01 / lensA", text: $manualCaptureMeta)
                        .textFieldStyle(GlassTextFieldStyle())
                        .focused($isManualMetaFocused)
                        .submitLabel(.done)
                        .onSubmit {
                            isManualMetaFocused = false
                        }
                }
            }

            Button(action: capturePhoto) {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 90, height: 90)
                        .overlay(
                            Circle()
                                .stroke(
                                    LinearGradient(
                                        colors: [.white.opacity(0.5), .clear], startPoint: .topLeading,
                                        endPoint: .bottomTrailing),
                                    lineWidth: 2
                                )
                        )

                    Circle()
                        .fill(isCapturing ? Color.gray : Color.red)
                        .frame(width: 70, height: 70)
                        .shadow(color: .red.opacity(0.3), radius: 15, x: 0, y: 0)

                    Image(systemName: "camera.fill")
                        .font(.system(size: 22, weight: .heavy))
                        .foregroundColor(.white)
                        .opacity(isCapturing ? 0 : 1)

                    if isCapturing {
                        ProgressView()
                            .tint(.white)
                    }
                }
            }
            .disabled(isCapturing || isMetering)
            .padding(.vertical, 6)

            // 測光ボタン
            Button {
                performMeteringCalibrate()
            } label: {
                HStack(spacing: 8) {
                    if isMetering {
                        ProgressView()
                            .tint(.yellow)
                    } else {
                        Image(systemName: "sun.max.trianglebadge.exclamationmark")
                            .font(.system(size: 16, weight: .bold))
                    }
                    Text(isMetering ? "測光中..." : "測光")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                }
                .foregroundColor(.black)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(
                    Capsule()
                        .fill(Color.yellow.opacity(isMetering ? 0.5 : 0.9))
                )
            }
            .disabled(isCapturing || isMetering)

            if let rec = meteringResult {
                VStack(alignment: .leading, spacing: 4) {
                    Text("測光結果")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(.secondary)
                    HStack(spacing: 12) {
                        if let iso = rec.recommendedIso {
                            Text("ISO \(iso)")
                                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        }
                        if let ss = rec.recommendedShutterUs {
                            let label = ss >= 1_000_000 ? String(format: "%.1fs", Double(ss) / 1_000_000) : "1/\(1_000_000 / ss)"
                            Text(label)
                                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        }
                        if let lux = rec.avgLux {
                            Text(String(format: "%.1f lux", lux))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.yellow.opacity(0.15)))
            }

            if let mToast = meteringToast {
                Text(mToast)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(mToast.contains("完了") ? Color.green : Color.orange))
                    .transition(.scale.combined(with: .opacity))
            }

            if let toast = captureToast {
                Text(toast)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(
                        Capsule()
                            .fill(toast.contains("成功") ? Color.green : Color.red)
                    )
                    .transition(.scale.combined(with: .opacity))
                    .animation(.spring(response: 0.3), value: captureToast)
            }

            Text("赤いボタンで手動撮影します。CURRENTは今の設定を使用。MODE指定時は手動撮影だけ一時的にプリセットを適用します。")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(captureLocationProvider.statusLabel)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let metadata = lastCaptureMetadata {
                VStack(alignment: .leading, spacing: 10) {
                    Text("LAST CAPTURE")
                        .font(.caption2.weight(.black))
                        .foregroundColor(.secondary)

                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("MODE: \((metadata.appliedMode ?? metadata.manualMode ?? "-").uppercased())")
                            Text("ISO: \(metadata.iso?.displayString ?? "-")")
                            Text("SS: \(metadata.shutterSpeed?.displayString ?? "-")")
                        }
                        .monospacedDigit()

                        Spacer()

                        VStack(alignment: .leading, spacing: 4) {
                            Text("WB: \((metadata.whiteBalance ?? "-").uppercased())")
                            Text("Q: \(metadata.quality.map(String.init) ?? "-")")
                            Text("DATE: \(metadata.capturedDateDisplay)")
                        }
                        .monospacedDigit()
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundColor(.secondary)

                    Text("LOC: \(metadata.locationDisplay)")
                        .font(.caption2.weight(.medium))
                        .foregroundColor(.secondary)
                        .monospacedDigit()

                    Text("META: \(metadata.meta?.isEmpty == false ? metadata.meta! : "-")")
                        .font(.caption2.weight(.medium))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                .padding(12)
                .background(Color.primary.opacity(0.05))
                .cornerRadius(14)
            }
        }
    }

    private var troubleshootSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("問題が起きたら以下のボタンで修正できます")
                .font(.system(size: 13))
                .foregroundColor(.secondary)

            // フィルムカメラ用デフォルトに戻す
            Button {
                Task {
                    do {
                        try await api.updateSettings([
                            "iso": 200,
                            "shutter_speed": 1000000,
                            "camera_mode": "standard",
                        ])
                        syncState = .success("ISO 200 / SS 1s に復元しました")
                        loadAllSettings()
                    } catch {
                        errorMessage = "復元失敗: \(error.localizedDescription)"
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 16, weight: .bold))
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("フィルムカメラ用に復元")
                            .font(.system(size: 14, weight: .bold))
                        Text("ISO 200 / SS 1秒 / STANDARD")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Image(systemName: "arrow.counterclockwise")
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.1)))
            }
            .buttonStyle(.plain)

            // ISO/SSをautoに変更
            Button {
                Task {
                    do {
                        try await api.updateSettings([
                            "iso": "auto",
                            "shutter_speed": "auto",
                        ], resetTemporary: true)
                        syncState = .success("ISO/SS を AUTO に変更しました")
                        loadAllSettings()
                    } catch {
                        errorMessage = "変更失敗: \(error.localizedDescription)"
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 16, weight: .bold))
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ISO/SS を AUTO に変更")
                            .font(.system(size: 14, weight: .bold))
                        Text("一時設定もクリア")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Image(systemName: "sparkles")
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.green.opacity(0.1)))
            }
            .buttonStyle(.plain)

            // camera-service再起動
            Button {
                Task {
                    do {
                        // /api/capture with empty body triggers service restart cycle
                        let url = URL(string: "http://\(serverIP):8001/api/settings")!
                        var request = URLRequest(url: url)
                        request.httpMethod = "POST"
                        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        request.httpBody = try JSONSerialization.data(withJSONObject: ["camera_mode": selectedCameraMode.rawValue])
                        let _ = try await URLSession.shared.data(for: request)
                        syncState = .success("カメラモードを再適用しました")
                        loadAllSettings()
                    } catch {
                        errorMessage = "再適用失敗: \(error.localizedDescription)"
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 16, weight: .bold))
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("カメラモード再適用")
                            .font(.system(size: 14, weight: .bold))
                        Text("設定をサーバーに再送信")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Image(systemName: "arrow.clockwise")
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.1)))
            }
            .buttonStyle(.plain)

            // 現在の設定表示
            VStack(alignment: .leading, spacing: 6) {
                Text("現在の設定")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.secondary)
                HStack(spacing: 16) {
                    Label("ISO: \(selectedISO.label)", systemImage: "sun.max")
                    Label("SS: \(selectedShutterSpeed.label)", systemImage: "timer")
                }
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                HStack(spacing: 16) {
                    Label("Mode: \(selectedCameraMode.rawValue.uppercased())", systemImage: "camera")
                    Label("Q: \(selectedQuality.label)", systemImage: "photo")
                }
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                if let sensor = sensorStatus {
                    HStack(spacing: 16) {
                        if let lux = sensor.lux {
                            Text(String(format: "Lux: %.1f", lux))
                        }
                        if let gain = sensor.aeGain {
                            Text(String(format: "Gain: %.1f", gain))
                        }
                        if let exp = sensor.aeExposureUs {
                            Text(String(format: "Exp: %.0fµs", exp))
                        }
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
        }
    }

    private var networkSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("NETWORK")
                        .font(.caption2.weight(.black))
                        .foregroundColor(.secondary)
                    Text(wifiSSID)
                        .font(.body.weight(.bold))
                }
                Spacer()
                Text(wifiMode.uppercased())
                    .font(.caption2.weight(.heavy))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.2))
                    .foregroundColor(.blue)
                    .cornerRadius(6)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(wifiIP, systemImage: "network")
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                    Spacer()
                }

                Picker("切替先", selection: $targetAPMode) {
                    Text("AP").tag(true)
                    Text("家Wi-Fi").tag(false)
                }
                .pickerStyle(.segmented)
                .disabled(isSwitchingWiFi)

                if targetAPMode {
                    TextField("AP SSID", text: $apSSIDInput)
                        .textFieldStyle(GlassTextFieldStyle())
                        .disabled(isSwitchingWiFi)
                    SecureField("AP PASSWORD", text: $apPasswordInput)
                        .textFieldStyle(GlassTextFieldStyle())
                        .disabled(isSwitchingWiFi)

                    if apPasswordInput == "picamera123" {
                        Text("⚠ デフォルトAPパスワードは外部利用時に危険です。8文字以上の固有パスワードへ変更してください。")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }

                    Button(action: switchWiFiMode) {
                        Text(isAPMode ? "AP設定を適用" : "APへ切り替え開始")
                            .font(.system(size: 12, weight: .black))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }
                    .disabled(isSwitchingWiFi)

                    Text("実行後、iPhoneのWi-Fi設定で \"\(apSSIDInput)\" に接続し直してから、アプリでRefreshしてください。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    HStack {
                        TextField("家Wi-Fi SSID", text: $homeSSIDInput)
                            .textFieldStyle(GlassTextFieldStyle())
                            .disabled(isSwitchingWiFi)

                        Button {
                            scanWiFiNetworks()
                        } label: {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.caption.weight(.bold))
                                .padding(12)
                                .background(Color.blue.opacity(0.2))
                                .foregroundColor(.blue)
                                .cornerRadius(10)
                        }
                        .disabled(isSwitchingWiFi || isScanning)
                    }

                    if isScanning {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.8)
                            Text("Wi-Fiネットワークをスキャン中...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if !scannedNetworks.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("検出されたネットワーク")
                                .font(.caption2.weight(.black))
                                .foregroundColor(.secondary)

                            ScrollView(.vertical, showsIndicators: true) {
                                VStack(spacing: 6) {
                                    ForEach(scannedNetworks) { network in
                                        wifiNetworkRow(network)
                                    }
                                }
                            }
                            .frame(maxHeight: 200)
                        }
                        .padding(12)
                        .background(Color.primary.opacity(0.05))
                        .cornerRadius(14)
                    }

                    SecureField("家Wi-Fi PASSWORD", text: $homePasswordInput)
                        .textFieldStyle(GlassTextFieldStyle())
                        .disabled(isSwitchingWiFi)

                    Button(action: connectHomeWiFi) {
                        Text(isAPMode ? "家Wi-Fiへ切り替え開始" : "家Wi-Fi設定を適用")
                            .font(.system(size: 12, weight: .black))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.green)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }
                    .disabled(isSwitchingWiFi || homeSSIDInput.isEmpty || homePasswordInput.isEmpty)

                    Text("実行後、iPhoneを家Wi-Fiへ接続し直してから、アプリでRefreshしてください。（\"raspberrypi.local\" で再接続します）")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if isSwitchingWiFi {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("切替処理中... Wi-Fi接続が切れたら案内に従って再接続してください")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    struct GlassTextFieldStyle: TextFieldStyle {
        func _body(configuration: TextField<Self._Label>) -> some View {
            configuration
                .padding(12)
                .background(Color.primary.opacity(0.05))
                .cornerRadius(12)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
        }
    }

    // MARK: - Logic (Same as before but with UI sync)

    private func loadAllSettings() {
        isLoading = true
        errorMessage = nil
        syncState = .idle
        Task {
            do {
                let settings = try await api.fetchSettings()
                let wifi = try await api.fetchWiFiStatus()
                let sensor = try? await api.fetchSensorStatus()
                await MainActor.run {
                    applyRemoteSettings(settings)

                    wifiMode = wifi.mode ?? "N/A"
                    wifiSSID = wifi.ssid ?? "Disconnected"
                    if let resolvedIP = wifi.resolvedIP {
                        if wifi.mode == "ap" {
                            wifiIP = "192.168.4.1"
                            if serverIP != "192.168.4.1" { serverIP = "192.168.4.1" }
                        } else {
                            wifiIP = resolvedIP
                            if serverIP != resolvedIP { serverIP = resolvedIP }
                        }
                    } else {
                        wifiIP = wifi.mode == "ap" ? "192.168.4.1" : "0.0.0.0"
                    }
                    isAPMode = wifi.mode == "ap"
                    targetAPMode = isAPMode
                    sensorStatus = sensor?.sensor

                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Offline"
                    isLoading = false
                }
            }
        }
    }

    private func applyRemoteSettings(_ settings: CameraSettings) {
        isApplyingRemoteSettings = true

        selectedCameraMode = CameraModeOption.from(settings.cameraMode)
        selectedISO = ISOOption.from(settings.iso)
        selectedShutterSpeed = ShutterSpeedOption.from(settings.shutterSpeed)
        selectedQuality = QualityOption.from(settings.quality)
        selectedWhiteBalance = WhiteBalanceOption.from(settings.whiteBalance)
        detectionThreshold = Double(settings.detectionThreshold)
        enableMultipleExposure = settings.enableMultipleExposure
        multipleExposureMode = settings.multipleExposureMode
        enable2in1Composition = settings.enable2in1Composition
        enableTimestamp = settings.enableTimestamp
        enableStabilization = settings.stabilization
        enableRawMode = settings.rawMode
        manualModeEnabled = !settings.monitoringEnabled

        isApplyingRemoteSettings = false
    }

    private func performSettingUpdate(
        label: String,
        validate: ((CameraSettings) -> Bool)? = nil,
        update: @escaping (CameraAPI) async throws -> Void
    ) {
        guard !isApplyingRemoteSettings else { return }

        syncState = .syncing(label)
        errorMessage = nil
        let apiClient = api

        Task {
            do {
                try await update(apiClient)
                let settings = try await apiClient.fetchSettings()
                await MainActor.run {
                    applyRemoteSettings(settings)
                    if validate?(settings) ?? true {
                        let message = "\(label)を反映しました"
                        syncState = .success(message)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            if syncState == .success(message) {
                                syncState = .idle
                            }
                        }
                    } else {
                        syncState = .idle
                        errorMessage = "\(label)が反映されませんでした"
                    }
                }
            } catch {
                await MainActor.run {
                    syncState = .idle
                    errorMessage = error.localizedDescription
                }

                do {
                    let settings = try await apiClient.fetchSettings()
                    await MainActor.run {
                        applyRemoteSettings(settings)
                    }
                } catch {
                }
            }
        }
    }

    private func updateISO(_ option: ISOOption) {
        performSettingUpdate(
            label: "ISO",
            validate: { $0.iso == option.isoValue }
        ) { api in
            try await api.updateISO(option.isoValue)
        }
    }

    private func shiftISO(step: Int) {
        let all = ISOOption.allCases
        guard let currentIndex = all.firstIndex(of: selectedISO) else { return }
        let next = min(max(currentIndex + step, 0), all.count - 1)
        guard next != currentIndex else { return }
        let target = all[next]
        selectedISO = target
        updateISO(target)
    }

    private func updateShutterSpeed(_ option: ShutterSpeedOption) {
        performSettingUpdate(
            label: "シャッター",
            validate: { $0.shutterSpeed == option.shutterValue }
        ) { api in
            try await api.updateShutterSpeed(option.shutterValue)
        }
    }

    private func shiftShutter(step: Int) {
        let all = shutterOptions
        guard let currentIndex = all.firstIndex(of: selectedShutterSpeed) else { return }
        let next = min(max(currentIndex + step, 0), all.count - 1)
        guard next != currentIndex else { return }
        let target = all[next]
        selectedShutterSpeed = target
        updateShutterSpeed(target)
    }

    private func updateQuality(_ option: QualityOption) {
        performSettingUpdate(
            label: "画質",
            validate: { $0.quality == option.qualityValue }
        ) { api in
            try await api.updateQuality(option.qualityValue)
        }
    }

    private func updateCameraMode(_ option: CameraModeOption) {
        performSettingUpdate(
            label: "モード",
            validate: { $0.cameraMode == option.rawValue }
        ) { api in
            try await api.updateCameraMode(option)
        }
    }

    private func updateWhiteBalance(_ option: WhiteBalanceOption) {
        performSettingUpdate(
            label: "WB",
            validate: { $0.whiteBalance == option.rawValue }
        ) { api in
            try await api.updateWhiteBalance(option.rawValue)
        }
    }

    private func updateThreshold(_ value: Int) {
        performSettingUpdate(
            label: "閾値",
            validate: { $0.detectionThreshold == value }
        ) { api in
            try await api.updateDetectionThreshold(value)
        }
    }

    private func updateMonitoringEnabled(_ enabled: Bool) {
        guard !isApplyingRemoteSettings else { return }

        if !enabled {
            enableMultipleExposure = false
            enable2in1Composition = false
            performSettingUpdate(
                label: "手動モード",
                validate: {
                    !$0.monitoringEnabled && !$0.enableMultipleExposure && !$0.enable2in1Composition
                }
            ) { api in
                try await api.updateSettings([
                    "monitoring_enabled": enabled,
                    "enable_multiple_exposure": false,
                    "enable_2in1_composition": false,
                ], temporary: true)
            }
            return
        }

        performSettingUpdate(
            label: "手動モード",
            validate: { $0.monitoringEnabled == enabled }
        ) { api in
            try await api.updateMonitoringEnabled(enabled)
        }
    }

    private func quickToggleMonitoring() {
        let targetMonitoringEnabled = manualModeEnabled
        manualModeEnabled.toggle()
        updateMonitoringEnabled(targetMonitoringEnabled)
    }

    private func quickChip(
        title: String,
        active: Bool,
        activeColor: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(active ? activeColor : Color.primary.opacity(0.08))
                .foregroundColor(active ? .white : .primary)
                .cornerRadius(10)
        }
    }

    private func updateToggle(
        multipleExposure: Bool? = nil, composition2in1: Bool? = nil, timestamp: Bool? = nil
    ) {
        let label: String = {
            if multipleExposure != nil { return "多重露光" }
            if composition2in1 != nil { return "2-in-1" }
            if timestamp != nil { return "日時刻印" }
            return "設定"
        }()

        performSettingUpdate(
            label: label,
            validate: { settings in
                if let multipleExposure, settings.enableMultipleExposure != multipleExposure {
                    return false
                }
                if let composition2in1, settings.enable2in1Composition != composition2in1 {
                    return false
                }
                if let timestamp, settings.enableTimestamp != timestamp {
                    return false
                }
                return true
            }
        ) { api in
            try await api.updateToggleSettings(
                multipleExposure: multipleExposure,
                composition2in1: composition2in1,
                timestamp: timestamp
            )
        }
    }

    private func updateMultipleExposureMode(_ mode: String) {
        performSettingUpdate(
            label: "多重露光モード",
            validate: { $0.multipleExposureMode == mode }
        ) { api in
            try await api.updateSettings(["multiple_exposure_mode": mode], temporary: false)
        }
    }

    private func resetTemporarySettings() {
        performSettingUpdate(label: "一時変更リセット") { api in
            try await api.resetTemporarySettings()
        }
    }

    private func performMeteringCalibrate() {
        isMetering = true
        meteringResult = nil
        meteringToast = "測光開始: 5秒待機 → 10秒間撮影..."
        errorMessage = nil

        let apiClient = api
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()

        Task {
            do {
                let result = try await apiClient.meteringCalibrate(settleSeconds: 5, captureSeconds: 10)
                await MainActor.run {
                    isMetering = false
                    if result.success, let rec = result.recommendation {
                        meteringResult = rec
                        let photoCount = result.photos?.count ?? 0
                        meteringToast = "測光完了 (\(photoCount)枚撮影)"
                        generator.notificationOccurred(.success)
                    } else {
                        meteringToast = "測光失敗: \(result.error ?? "unknown")"
                        generator.notificationOccurred(.error)
                    }
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await MainActor.run { meteringToast = nil }
            } catch {
                await MainActor.run {
                    isMetering = false
                    meteringToast = "測光エラー: \(error.localizedDescription)"
                    generator.notificationOccurred(.error)
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await MainActor.run { meteringToast = nil }
            }
        }
    }

    private func capturePhoto() {
        isManualMetaFocused = false
        errorMessage = nil
        syncState = .idle
        isCapturing = true
        lastCaptureMetadata = nil
        
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        
        let apiClient = api
        let mode = manualCaptureMode
        let meta = manualCaptureMeta
        let locationPayload = captureLocationProvider.capturePayload()
        let doMultiExposure = enableMultipleExposure
        let multiMode = multipleExposureMode
        let do2in1 = enable2in1Composition
        let doTimestamp = enableTimestamp

        Task {
            do {
                // 1枚目を撮影
                let (filename1, metadata) = try await apiClient.captureWithMetadata(
                    manualMode: mode, meta: meta, location: locationPayload
                )
                var image = try await apiClient.downloadImage(filename: filename1)

                // 多重露光: 2枚目を撮影してiPhone側で合成
                if doMultiExposure || do2in1 {
                    let (filename2, _) = try await apiClient.captureWithMetadata(
                        manualMode: mode, meta: meta, location: locationPayload
                    )
                    let image2 = try await apiClient.downloadImage(filename: filename2)

                    if do2in1 {
                        image = ImageCompositor.sideBySideComposite(image, image2) ?? image
                    } else if multiMode == "additive" {
                        image = ImageCompositor.additiveComposite([image, image2]) ?? image
                    } else {
                        image = ImageCompositor.blendImages(image, image2) ?? image
                    }
                }

                // タイムスタンプ追加（iPhone側で処理）
                if doTimestamp {
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                    let ts = formatter.string(from: Date())
                    image = ImageCompositor.addTimestamp(image, timestamp: ts) ?? image
                }

                await MainActor.run {
                    capturedImage = image
                    lastCaptureMetadata = metadata
                    isCapturing = false
                    captureToast = "✅ 撮影成功"
                    generator.notificationOccurred(.success)
                }
                // トースト自動消去
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await MainActor.run { captureToast = nil }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isCapturing = false
                    captureToast = "❌ 撮影失敗"
                    generator.notificationOccurred(.error)
                }
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                await MainActor.run { captureToast = nil }
            }
        }
    }

    private func switchWiFiMode() {
        if targetAPMode {
            savedAPSSID = apSSIDInput
            savedAPPassword = apPasswordInput
        }

        if targetAPMode && apPasswordInput.count < 8 {
            errorMessage = "PASSWORD は8文字以上必要です"
            return
        }
        isSwitchingWiFi = true
        errorMessage = nil
        let apiClient = api
        Task {
            do {
                try await apiClient.switchWiFiMode(
                    toAP: targetAPMode, ssid: apSSIDInput, password: apPasswordInput)
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isSwitchingWiFi = false
                }
                return
            }

            await MainActor.run {
                serverIP = "192.168.4.1"
                errorMessage = "AP切替を開始しました。Wi-Fi設定で\"\(apSSIDInput)\"へ接続し直してRefreshしてください。"
                isSwitchingWiFi = false
            }
        }
    }

    @ViewBuilder
    private var syncBanner: some View {
        switch syncState {
        case .idle:
            EmptyView()
        case .syncing(let label):
            HStack(spacing: 10) {
                ProgressView()
                Text("\(label)を適用中...")
                    .font(.caption.weight(.medium))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .minimalCard()
        case .success(let message):
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text(message)
                    .font(.caption.weight(.medium))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .minimalCard()
        }
    }

    // MARK: - Wi-Fi Scan Helpers

    private func wifiNetworkRow(_ network: WiFiNetwork) -> some View {
        Button {
            homeSSIDInput = network.ssid
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(network.ssid)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.primary)

                    HStack(spacing: 4) {
                        Image(systemName: network.isSecure ? "lock.fill" : "lock.open.fill")
                            .font(.caption2)
                        Text(network.security ?? "Open")
                            .font(.caption2)
                    }
                    .foregroundColor(.secondary)
                }

                Spacer()

                HStack(spacing: 4) {
                    Image(systemName: signalIcon(network.signal))
                        .foregroundColor(signalColor(network.signal))
                    Text(network.signalStrength)
                        .font(.caption2.weight(.medium))
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(
                homeSSIDInput == network.ssid
                    ? Color.blue.opacity(0.2)
                    : Color.clear
            )
            .cornerRadius(8)
        }
    }

    private func signalIcon(_ signal: Int?) -> String {
        guard let signal = signal else { return "wifi.slash" }
        if signal >= 75 { return "wifi" }
        if signal >= 50 { return "wifi" }
        if signal >= 25 { return "wifi" }
        return "wifi"
    }

    private func signalColor(_ signal: Int?) -> Color {
        guard let signal = signal else { return .red }
        if signal >= 75 { return .green }
        if signal >= 50 { return .orange }
        return .red
    }

    private func qualityDescriptionForMode(_ mode: CameraModeOption) -> String {
        switch mode {
        case .reaction:
            return "JPEG品質: Q70（高速撮影優先）"
        case .quality:
            return "JPEG品質: Q100（最高画質）"
        case .standard:
            return "JPEG品質: Q90（標準）"
        case .night:
            return "JPEG品質: Q95（暗所・夜間高画質）"
        case .battery:
            return "JPEG品質: Q80（省電力）"
        case .manual:
            return "JPEG品質: Q90（標準）"
        case .raw:
            return "JPEG品質: Q100（RAW+JPEG）"
        }
    }

    private func scanWiFiNetworks() {
        isScanning = true
        scanError = nil
        let apiClient = api
        Task {
            do {
                let response = try await apiClient.scanWiFiNetworks()
                await MainActor.run {
                    if response.success {
                        scannedNetworks = response.networks
                    } else {
                        scanError = response.message ?? "スキャンに失敗しました"
                        errorMessage = scanError
                    }
                    isScanning = false
                }
            } catch {
                await MainActor.run {
                    scanError = error.localizedDescription
                    errorMessage = "Wi-Fiスキャンエラー: \(scanError ?? "")"
                    isScanning = false
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
