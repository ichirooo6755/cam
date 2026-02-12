import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

// MARK: - Liquid Glass Styles

struct LiquidGlassModifier: ViewModifier {
    var radius: CGFloat = 20

    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial)
            .cornerRadius(radius)
            .shadow(color: Color.black.opacity(0.1), radius: 10, x: 0, y: 5)
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .stroke(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.5),
                                .white.opacity(0.05),
                                .black.opacity(0.05),
                                .black.opacity(0.2),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
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
    @AppStorage("serverIP") private var serverIP: String = "192.168.4.1"
    @AppStorage("apSSID") private var savedAPSSID: String = "PiCamera"
    @AppStorage("apPassword") private var savedAPPassword: String = "picamera123"

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
    @State private var enable2in1Composition: Bool = false
    @State private var enableTimestamp: Bool = false
    @State private var manualModeEnabled: Bool = false

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
    @State private var errorMessage: String? = nil
    @State private var syncState: SyncState = .idle
    @State private var isApplyingRemoteSettings: Bool = false
    @State private var showResetTemporaryConfirm: Bool = false
    @State private var manualCaptureMode: ManualCaptureMode = .current
    @State private var manualCaptureMeta: String = ""

    @Environment(\.colorScheme) var colorScheme

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
                // Liquid Background
                backgroundGradient
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 24) {

                        // Image Display
                        previewArea

                        syncBanner

                        // Camera Controls
                        VStack(spacing: 24) {
                            pickerModule(
                                title: "MODE", selection: $selectedCameraMode,
                                options: CameraModeOption.allCases
                            ) { opt in
                                updateCameraMode(opt)
                            }
                            HStack(spacing: 16) {
                                pickerModule(
                                    title: "ISO", selection: $selectedISO,
                                    options: ISOOption.allCases
                                ) { opt in
                                    updateISO(opt)
                                }
                                shutterPickerModule
                            }

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
                loadAllSettings()
            }
        }
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
            Color(colorScheme == .dark ? .black : .white)

            LinearGradient(
                colors: [
                    Color.blue.opacity(0.15),
                    Color.purple.opacity(0.15),
                    Color.clear,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [Color.blue.opacity(0.1), .clear],
                center: .bottomTrailing,
                startRadius: 0,
                endRadius: 400
            )
        }
    }

    private var previewArea: some View {
        ZStack {
            if let image = capturedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 300)
                    .clipped()
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
                VStack(spacing: 12) {
                    Image(systemName: "camera.shutter.button")
                        .font(.system(size: 40, weight: .light))
                        .foregroundColor(.primary.opacity(0.3))
                    Text("NO PREVIEW")
                        .font(.system(size: 10, weight: .black))
                        .foregroundColor(.primary.opacity(0.2))
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

    private var shutterPickerModule: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SHUTTER")
                .font(.caption2.weight(.black))
                .foregroundColor(.secondary)
                .padding(.leading, 4)

            Picker("SHUTTER", selection: $selectedShutterSpeed) {
                ForEach(shutterOptions, id: \.self) { opt in
                    Text(opt.label).tag(opt)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .onChange(of: selectedShutterSpeed) { _, newValue in
                updateShutterSpeed(newValue)
            }
        }
        .padding(12)
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

                    if isCapturing {
                        ProgressView()
                            .tint(.white)
                    }
                }
            }
            .disabled(isCapturing)
            .padding(.vertical, 6)

            Text("CURRENTは今の設定を使用。MODE指定時は手動撮影だけ一時的にプリセットを適用します。")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
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
                    TextField("家Wi-Fi SSID", text: $homeSSIDInput)
                        .textFieldStyle(GlassTextFieldStyle())
                        .disabled(isSwitchingWiFi)
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
        enable2in1Composition = settings.enable2in1Composition
        enableTimestamp = settings.enableTimestamp
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

    private func updateShutterSpeed(_ option: ShutterSpeedOption) {
        performSettingUpdate(
            label: "シャッター",
            validate: { $0.shutterSpeed == option.shutterValue }
        ) { api in
            try await api.updateShutterSpeed(option.shutterValue)
        }
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

    private func resetTemporarySettings() {
        performSettingUpdate(label: "一時変更リセット") { api in
            try await api.resetTemporarySettings()
        }
    }

    private func capturePhoto() {
        errorMessage = nil
        syncState = .idle
        isCapturing = true
        let apiClient = api
        let mode = manualCaptureMode
        let meta = manualCaptureMeta
        Task {
            do {
                let filename = try await apiClient.capture(manualMode: mode, meta: meta)
                let image = try await apiClient.downloadImage(filename: filename)
                await MainActor.run {
                    capturedImage = image
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
                    errorMessage = "AP切替の開始に失敗しました。接続先とパスワードを確認してください。"
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
}

#Preview {
    ContentView()
}
