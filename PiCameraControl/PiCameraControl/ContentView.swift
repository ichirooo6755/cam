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
    var title: String
    @Binding var isOn: Bool
    var action: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundColor(.secondary)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(SwitchToggleStyle(tint: .blue))
                .scaleEffect(0.9)
                .onChange(of: isOn) { oldValue, newValue in
                    action()
                }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .liquidGlassStyle(radius: 16)
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
    @State private var enableFocusPeaking: Bool = false
    @State private var focusPeakingColor: String = "red"
    @State private var focusPeakingImage: UIImage?
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
    @State private var isSwitchingWiFi: Bool = false
    @State private var isScanning: Bool = false
    @State private var scannedNetworks: [WiFiNetwork] = []
    @State private var scanError: String? = nil
    @State private var errorMessage: String? = nil
    @State private var syncState: SyncState = .idle
    @State private var isApplyingRemoteSettings: Bool = false
    @State private var showResetTemporaryConfirm: Bool = false
    @State private var manualCaptureMode: ManualCaptureMode = .current
    @State private var manualCaptureMeta: String = ""
    @State private var lastCaptureMetadata: PhotoMetadata? = nil
    @State private var sensorStatus: SensorRuntimeStatus? = nil
    @State private var meteringRecommendation: MeteringRecommendation? = nil
    @State private var isMetering: Bool = false
    @StateObject private var captureLocationProvider = CaptureLocationProvider()

    @FocusState private var isManualMetaFocused: Bool

    private var api: CameraAPI {
        CameraAPI(baseURL: "http://\(serverIP):8001")
    }

    private var shutterOptions: [ShutterSpeedOption] {
        if manualModeEnabled {
            return ShutterSpeedOption.allCases
        }
        return ShutterSpeedOption.allCases.filter { $0 != .ss400 }
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

                        // Image Display
                        previewArea

                        syncBanner

                        monitoringQuickSection

                        // Camera Controls (Nikon 35Ti Style)
                        VStack(spacing: 24) {
                            // MODE Picker
                            VStack(alignment: .leading, spacing: 14) {
                                Text("MODE")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(Color.gray.opacity(0.9))
                                    .tracking(1.5)
                                    .padding(.horizontal, 4)

                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 10) {
                                        ForEach(CameraModeOption.allCases) { mode in
                                            Button {
                                                withAnimation(.easeInOut(duration: 0.15)) {
                                                    selectedCameraMode = mode
                                                    updateCameraMode(mode)
                                                }
                                            } label: {
                                                Text(mode.label)
                                                    .font(.system(size: 14, weight: selectedCameraMode == mode ? .bold : .medium, design: .monospaced))
                                                    .foregroundColor(selectedCameraMode == mode ? .white : Color.gray.opacity(0.9))
                                                    .padding(.horizontal, 18)
                                                    .padding(.vertical, 12)
                                                    .background(
                                                        RoundedRectangle(cornerRadius: 10)
                                                            .fill(selectedCameraMode == mode ? Color.red.opacity(0.85) : Color.gray.opacity(0.15))
                                                    )
                                            }
                                        }
                                    }
                                }
                            }
                            .padding(20)
                            .liquidGlassStyle(radius: 16)

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
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Image(systemName: "photo")
                                        .foregroundColor(.gray.opacity(0.7))
                                        .font(.caption)
                                    Text(qualityDescriptionForMode(selectedCameraMode))
                                        .font(.caption2)
                                        .foregroundColor(.gray.opacity(0.9))
                                }
                            }
                            .padding(.horizontal, 16)

                            isoQuickModule
                            shutterPickerModule

                            pickerModule(
                                title: "QUALITY", selection: $selectedQuality,
                                options: QualityOption.allCases
                            ) { opt in
                                updateQuality(opt)
                            }

                            whiteBalanceModule

                            if !manualModeEnabled {
                                thresholdModule
                            }
                        }

                        // Toggles
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                            GlassToggle(title: "手動モード", isOn: $manualModeEnabled) {
                                updateMonitoringEnabled(!manualModeEnabled)
                            }
                            GlassToggle(title: "多重露光", isOn: $enableMultipleExposure) {
                                updateToggle(multipleExposure: enableMultipleExposure)
                            }
                            GlassToggle(title: "2-in-1", isOn: $enable2in1Composition) {
                                updateToggle(composition2in1: enable2in1Composition)
                            }
                            GlassToggle(title: "日時刻印", isOn: $enableTimestamp) {
                                updateToggle(timestamp: enableTimestamp)
                            }
                            GlassToggle(title: "手ぶれ補正", isOn: $enableStabilization) {
                                Task {
                                    do {
                                        try await api.updateStabilization(enableStabilization, temporary: false)
                                    } catch {
                                        print("手ぶれ補正の更新に失敗: \(error)")
                                    }
                                }
                            }
                            GlassToggle(title: "RAWモード", isOn: $enableRawMode) {
                                Task {
                                    do {
                                        try await api.updateSettings(["raw_mode": enableRawMode], temporary: false)
                                    } catch {
                                        print("RAWモードの更新に失敗: \(error)")
                                    }
                                }
                            }
                            GlassToggle(title: "フォーカスピーキング", isOn: $enableFocusPeaking) {
                                if enableFocusPeaking {
                                    fetchFocusPeaking()
                                } else {
                                    focusPeakingImage = nil
                                }
                            }
                        }

                        // 手ぶれ補正の説明
                        if enableStabilization {
                            Text("⚠️ 手ぶれ補正ONで画質がわずかに劣化します")
                                .font(.caption)
                                .foregroundColor(.orange.opacity(0.8))
                                .padding(.horizontal, 16)
                        }

                        // RAWモードの説明
                        if enableRawMode {
                            Text("📷 RAWモード: DNG形式で保存（12.3MP）")
                                .font(.caption)
                                .foregroundColor(.blue.opacity(0.8))
                                .padding(.horizontal, 16)
                        }

                        // 多重露光モード選択
                        if enableMultipleExposure {
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
                            .padding(20)
                            .liquidGlassStyle(radius: 16)
                        }

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
                            .padding(14)
                            .foregroundColor(.blue)
                        }
                        .liquidGlassStyle(radius: 20)
                        .disabled(isLoading || isCapturing)
                        .alert("一時変更をリセットしますか？", isPresented: $showResetTemporaryConfirm) {
                            Button("リセット", role: .destructive) {
                                resetTemporarySettings()
                            }
                            Button("キャンセル", role: .cancel) {}
                        } message: {
                            Text("ISO/シャッター/WB/画質/閾値などの一時変更を元に戻します")
                        }

                        // Capture Button
                        captureSection
                            .sensoryFeedback(.impact(flexibility: .rigid), trigger: isCapturing)

                        sensorStatusSection

                        appearanceSection

                        // Network
                        networkSection

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
                        .padding(14)
                        .liquidGlassStyle(radius: 20)
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
                loadAllSettings()
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

    private func fetchFocusPeaking() {
        isLoading = true
        let color = focusPeakingColor

        Task {
            do {
                guard let url = URL(string: "http://\(serverIP):8001/api/focus_peaking?color=\(color)&threshold=30") else {
                    await MainActor.run {
                        errorMessage = "無効なURL"
                        isLoading = false
                    }
                    return
                }

                let (data, response) = try await URLSession.shared.data(from: url)

                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    await MainActor.run {
                        errorMessage = "フォーカスピーキングの取得に失敗"
                        isLoading = false
                    }
                    return
                }

                if let image = UIImage(data: data) {
                    await MainActor.run {
                        focusPeakingImage = image
                        isLoading = false
                    }
                } else {
                    await MainActor.run {
                        errorMessage = "画像の読み込みに失敗"
                        isLoading = false
                    }
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
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

    private var backgroundGradient: some View {
        ZStack {
            Color(colorScheme == .dark ? Color(red: 0.06, green: 0.07, blue: 0.08) : Color(red: 0.97, green: 0.98, blue: 0.99))

            LinearGradient(
                colors: [
                    Color.cyan.opacity(colorScheme == .dark ? 0.22 : 0.14),
                    Color.white.opacity(colorScheme == .dark ? 0.04 : 0.2),
                    Color.clear,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [Color.teal.opacity(colorScheme == .dark ? 0.2 : 0.1), .clear],
                center: .bottomTrailing,
                startRadius: 0,
                endRadius: 400
            )
        }
    }

    private var previewArea: some View {
        ZStack {
            if enableFocusPeaking, let image = focusPeakingImage {
                // フォーカスピーキングプレビュー
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .frame(height: 300)
                    .background(Color.black.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 30))
                    .overlay(
                        RoundedRectangle(cornerRadius: 30)
                            .stroke(.white.opacity(0.2), lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 30))
            } else if let image = capturedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .frame(height: 300)
                    .background(Color.black.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 30))
                    .overlay(
                        RoundedRectangle(cornerRadius: 30)
                            .stroke(.white.opacity(0.2), lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 30))
                    .contextMenu {
                        #if canImport(UIKit)
                            Button {
                                UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                            } label: {
                                Label("Save to Photos", systemImage: "square.and.arrow.down")
                            }
                        #endif
                        Button {
                            // Copy to clipboard or other action
                        } label: {
                            Label("Copy Image", systemImage: "doc.on.doc")
                        }
                    }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "camera.shutter.button")
                        .font(.system(size: 40, weight: .light))
                        .foregroundColor(.primary.opacity(0.3))
                    Text("NO PREVIEW")
                        .font(.system(size: 10, weight: .black))
                        .foregroundColor(.primary.opacity(0.2))

                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        HStack(spacing: 8) {
                            Image(systemName: "photo.on.rectangle.angled")
                            Text("写真を編集")
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.blue.opacity(0.8))
                        .cornerRadius(20)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 300)
                .liquidGlassStyle(radius: 30)
            }

            if isLoading || isCapturing {
                ProgressView()
                    .scaleEffect(1.2)
                    .padding(20)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
                    .transition(.opacity.combined(with: .scale))
            }
        }
        .padding(.top, 10)
    }

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
        .padding(12)
        .liquidGlassStyle(radius: 20)
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
        .padding(16)
        .liquidGlassStyle(radius: 20)
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
        .padding(16)
        .liquidGlassStyle(radius: 20)
    }

    private var isoQuickModule: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("ISO")
                    .font(.caption2.weight(.black))
                    .foregroundColor(.secondary)
                Spacer()
                Text(selectedISO.label)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                    .monospacedDigit()

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
        .padding(16)
        .liquidGlassStyle(radius: 20)
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
        .padding(16)
        .liquidGlassStyle(radius: 20)
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
        .padding(16)
        .liquidGlassStyle(radius: 20)
    }

    private var shutterPickerModule: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("SHUTTER")
                    .font(.caption2.weight(.black))
                    .foregroundColor(.secondary)
                Spacer()
                Text(selectedShutterSpeed.label)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                    .monospacedDigit()

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

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(shutterOptions, id: \.self) { opt in
                        quickChip(
                            title: opt.label,
                            active: selectedShutterSpeed == opt,
                            activeColor: .indigo
                        ) {
                            selectedShutterSpeed = opt
                            updateShutterSpeed(opt)
                        }
                    }
                }
            }
        }
        .padding(16)
        .liquidGlassStyle(radius: 20)
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
        .padding(16)
        .liquidGlassStyle(radius: 20)
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
            .disabled(isCapturing)
            .padding(.vertical, 6)

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
        .padding(16)
        .liquidGlassStyle(radius: 20)
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
        .padding(20)
        .liquidGlassStyle(radius: 24)
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

        DispatchQueue.main.async {
            isApplyingRemoteSettings = false
        }
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

    private func capturePhoto() {
        isManualMetaFocused = false
        errorMessage = nil
        syncState = .idle
        isCapturing = true
        lastCaptureMetadata = nil
        let apiClient = api
        let mode = manualCaptureMode
        let meta = manualCaptureMeta
        let locationPayload = captureLocationProvider.capturePayload()
        Task {
            do {
                let (filename, metadata) = try await apiClient.captureWithMetadata(
                    manualMode: mode,
                    meta: meta,
                    location: locationPayload
                )
                let image = try await apiClient.downloadImage(filename: filename)
                await MainActor.run {
                    capturedImage = image
                    lastCaptureMetadata = metadata
                    isCapturing = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isCapturing = false
                }
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
            .padding(14)
            .liquidGlassStyle(radius: 20)
        case .success(let message):
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text(message)
                    .font(.caption.weight(.medium))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(14)
            .liquidGlassStyle(radius: 20)
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
