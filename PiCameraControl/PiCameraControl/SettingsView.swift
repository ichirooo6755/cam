import SwiftUI

struct SettingsView: View {
    @AppStorage("serverIP") private var serverIP: String = "192.168.4.1"

    @State private var status: SystemStatus?
    @State private var threshold: Double = 30
    @State private var selectedISO: ISOOption = .auto
    @State private var selectedShutter: ShutterSpeedOption = .auto
    @State private var selectedWB: WhiteBalanceOption = .auto
    @State private var enableMultipleExposure = false
    @State private var enable2in1Composition = false
    @State private var enableTimestamp = false
    @State private var isLoading = false
    @State private var showIPAlert = false
    @State private var tempIP = ""

    private var api: SimpleCameraAPI {
        SimpleCameraAPI(baseURL: "http://\(serverIP):8001")
    }

    private var cameraAPI: CameraAPI {
        CameraAPI(baseURL: "http://\(serverIP):8001")
    }
    
    var body: some View {
        NavigationView {
            ZStack {
                backgroundGradient
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {
                        SectionCard(title: "システム状態") {
                            if let status = status {
                                HStack {
                                    Text("撮影枚数")
                                    Spacer()
                                    Text("\(status.photoCount)枚")
                                        .foregroundColor(.secondary)
                                        .monospacedDigit()
                                }

                                HStack {
                                    Text("サービス状態")
                                    Spacer()
                                    Text(status.serviceRunning ? "稼働中" : "停止")
                                        .foregroundColor(status.serviceRunning ? .green : .red)
                                }
                            } else {
                                HStack {
                                    ProgressView()
                                    Text("読み込み中...")
                                        .foregroundColor(.secondary)
                                }
                            }
                        }

                        SectionCard(title: "光検知設定") {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text("明るさ閾値")
                                    Spacer()
                                    Text("\(Int(threshold))")
                                        .foregroundColor(.blue)
                                        .monospacedDigit()
                                }

                                Slider(value: $threshold, in: 0...100, step: 1) { editing in
                                    if !editing {
                                        updateThreshold()
                                    }
                                }
                            }
                            .padding(.vertical, 8)

                            Text("この値より明るい光を検知すると自動撮影します")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        SectionCard(title: "カメラ設定") {
                            Picker("ISO", selection: $selectedISO) {
                                ForEach(ISOOption.allCases) { option in
                                    Text(option.label).tag(option)
                                }
                            }
                            .onChange(of: selectedISO) { _, newValue in
                                Task { try? await cameraAPI.updateISO(newValue.isoValue) }
                            }

                            Picker("シャッタースピード", selection: $selectedShutter) {
                                ForEach(ShutterSpeedOption.allCases) { option in
                                    Text(option.label).tag(option)
                                }
                            }
                            .onChange(of: selectedShutter) { _, newValue in
                                Task { try? await cameraAPI.updateShutterSpeed(newValue.shutterValue) }
                            }

                            Picker("ホワイトバランス", selection: $selectedWB) {
                                ForEach(WhiteBalanceOption.allCases) { option in
                                    Text(option.label).tag(option)
                                }
                            }
                            .onChange(of: selectedWB) { _, newValue in
                                Task { try? await cameraAPI.updateWhiteBalance(newValue.rawValue) }
                            }
                        }

                        SectionCard(title: "合成設定") {
                            Toggle("多重露光", isOn: $enableMultipleExposure)
                                .onChange(of: enableMultipleExposure) { _, newValue in
                                    Task { try? await cameraAPI.updateToggleSettings(multipleExposure: newValue) }
                                }
                            Toggle("2in1合成", isOn: $enable2in1Composition)
                                .onChange(of: enable2in1Composition) { _, newValue in
                                    Task { try? await cameraAPI.updateToggleSettings(composition2in1: newValue) }
                                }
                            Toggle("日時刻印", isOn: $enableTimestamp)
                                .onChange(of: enableTimestamp) { _, newValue in
                                    Task { try? await cameraAPI.updateToggleSettings(timestamp: newValue) }
                                }
                        }

                        SectionCard(title: "サーバー設定") {
                            HStack {
                                Text("Raspberry Pi IP")
                                Spacer()
                                Button {
                                    tempIP = serverIP
                                    showIPAlert = true
                                } label: {
                                    Text(serverIP)
                                        .foregroundColor(.blue)
                                        .monospacedDigit()
                                }
                            }
                        }

                        SectionCard(title: "情報") {
                            HStack {
                                Text("バージョン")
                                Spacer()
                                Text("2.0.0")
                                    .foregroundColor(.secondary)
                            }

                            HStack {
                                Text("モード")
                                Spacer()
                                Text("省電力")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        loadStatus()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .alert("IPアドレス設定", isPresented: $showIPAlert) {
                TextField("IP Address", text: $tempIP)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("保存") {
                    if validateServerURL("http://\(tempIP):8001") {
                        serverIP = tempIP
                        loadStatus()
                    }
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("Raspberry PiのIPアドレスを入力してください")
            }
            .onAppear {
                loadStatus()
            }
        }
    }
    
    private func loadStatus() {
        isLoading = true
        Task {
            do {
                async let statusTask = api.fetchStatus()
                async let settingsTask = cameraAPI.fetchSettings()
                let fetchedStatus = try await statusTask
                let fetchedSettings = try await settingsTask
                await MainActor.run {
                    status = fetchedStatus
                    threshold = Double(fetchedStatus.brightnessThreshold)
                    selectedISO = ISOOption.from(fetchedSettings.iso)
                    selectedShutter = ShutterSpeedOption.from(fetchedSettings.shutterSpeed)
                    selectedWB = WhiteBalanceOption.from(fetchedSettings.whiteBalance)
                    enableMultipleExposure = fetchedSettings.enableMultipleExposure
                    enable2in1Composition = fetchedSettings.enable2in1Composition
                    enableTimestamp = fetchedSettings.enableTimestamp
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                }
            }
        }
    }
    
    private func updateThreshold() {
        Task {
            try? await api.updateThreshold(Int(threshold))
        }
    }
}

private struct SectionCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
            content
        }
        .padding(16)
        .liquidGlassStyle(radius: 22)
    }
}

private extension SettingsView {
    var backgroundGradient: some View {
        ZStack {
            Color(.systemBackground)
            LinearGradient(
                colors: [
                    Color.blue.opacity(0.18),
                    Color.teal.opacity(0.12),
                    Color.clear,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [Color.cyan.opacity(0.12), .clear],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 400
            )
        }
    }
}

#Preview {
    SettingsView()
}
