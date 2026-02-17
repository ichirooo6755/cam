import SwiftUI

/// Nikon 35Tiスタイルのカメラステータス＆測光画面
struct CameraStatusView: View {
    @AppStorage("serverIP") private var serverIP: String = "192.168.4.1"
    @Environment(\.managedObjectContext) private var viewContext

    @State private var isLoading = false
    @State private var sensorStatus: SensorStatus?
    @State private var meteringRecommendation: MeteringRecommendation?
    @State private var currentSettings: CameraSettings?
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var lastMeteringRating: Int = 3

    private var api: CameraAPI {
        CameraAPI(baseURL: "http://\(serverIP):8001")
    }

    var body: some View {
        NavigationView {
            ZStack {
                // Nikon 35Tiスタイルの背景（黒地に赤アクセント）
                LinearGradient(
                    colors: [
                        Color(red: 0.1, green: 0.1, blue: 0.12),
                        Color(red: 0.05, green: 0.05, blue: 0.08),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        // ステータスメーター（Nikon 35Tiスタイル）
                        statusMetersSection

                        // 測光セクション
                        meteringSection

                        // センサー情報
                        if let sensor = sensorStatus {
                            sensorInfoSection(sensor)
                        }

                        // 現在の設定
                        if let settings = currentSettings {
                            currentSettingsSection(settings)
                        }
                    }
                    .padding()
                }

                if isLoading {
                    ProgressView()
                        .scaleEffect(1.5)
                        .padding(30)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                }
            }
            .navigationTitle("カメラステータス")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await refreshStatus() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundColor(.red.opacity(0.9))
                    }
                }
            }
            .onAppear {
                Task { await refreshStatus() }
            }
            .alert("エラー", isPresented: $showError) {
                Button("OK") {
                    errorMessage = nil
                }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    // MARK: - ステータスメーター（Nikon 35Tiスタイル）

    private var statusMetersSection: some View {
        VStack(spacing: 20) {
            Text("EXPOSURE METER")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.red.opacity(0.7))
                .tracking(2)

            HStack(spacing: 30) {
                // ISO メーター
                VStack(spacing: 8) {
                    Text("ISO")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.gray)

                    if let recommendation = meteringRecommendation {
                        analogMeter(
                            value: Double(recommendation.recommendedISO),
                            range: 100...3200,
                            label: "\(recommendation.recommendedISO)"
                        )
                    } else {
                        analogMeter(value: 400, range: 100...3200, label: "---")
                    }
                }

                // シャッタースピード メーター
                VStack(spacing: 8) {
                    Text("SHUTTER")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.gray)

                    if let recommendation = meteringRecommendation,
                       let label = recommendation.recommendedShutterLabel {
                        analogMeter(
                            value: log2(Double(recommendation.recommendedShutterUs)),
                            range: 10...20,
                            label: label
                        )
                    } else {
                        analogMeter(value: 14, range: 10...20, label: "---")
                    }
                }

                // フォーカス距離 メーター
                VStack(spacing: 8) {
                    Text("FOCUS")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.gray)

                    if let recommendation = meteringRecommendation,
                       let focusM = recommendation.recommendedFocusM {
                        analogMeter(
                            value: focusM,
                            range: 0.5...10.0,
                            label: String(format: "%.1fm", focusM)
                        )
                    } else {
                        analogMeter(value: 3.0, range: 0.5...10.0, label: "---")
                    }
                }
            }
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(red: 0.15, green: 0.15, blue: 0.17))
                .shadow(color: .black.opacity(0.3), radius: 10, y: 5)
        )
    }

    // MARK: - アナログメーター（Nikon 35Tiスタイル）

    private func analogMeter(value: Double, range: ClosedRange<Double>, label: String) -> some View {
        VStack(spacing: 6) {
            ZStack {
                // メーター背景
                Circle()
                    .stroke(Color.gray.opacity(0.2), lineWidth: 2)
                    .frame(width: 80, height: 80)

                // メーター目盛り
                ForEach(0..<5) { i in
                    Rectangle()
                        .fill(Color.gray.opacity(0.4))
                        .frame(width: 1, height: 6)
                        .offset(y: -37)
                        .rotationEffect(.degrees(Double(i) * 36 - 72))
                }

                // 針
                let normalizedValue = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
                let angle = normalizedValue * 144 - 72  // -72° to +72°

                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.red.opacity(0.9), .red.opacity(0.5)],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(width: 2, height: 32)
                    .offset(y: -16)
                    .rotationEffect(.degrees(angle))
                    .animation(.spring(response: 0.4, dampingFraction: 0.7), value: angle)

                // 中央ドット
                Circle()
                    .fill(Color.red.opacity(0.9))
                    .frame(width: 8, height: 8)
            }

            // 値表示
            Text(label)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(.red.opacity(0.9))
        }
    }

    // MARK: - 測光セクション

    private var meteringSection: some View {
        VStack(spacing: 16) {
            Text("METERING")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.red.opacity(0.7))
                .tracking(2)

            Button {
                Task { await performMetering() }
            } label: {
                HStack {
                    Image(systemName: "light.beacon.max.fill")
                        .font(.title3)
                    Text("測光開始")
                        .font(.system(size: 16, weight: .bold, design: .default))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    LinearGradient(
                        colors: [
                            Color.red.opacity(0.8),
                            Color.red.opacity(0.6),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .red.opacity(0.3), radius: 8, y: 4)
            }
            .disabled(isLoading)

            if let recommendation = meteringRecommendation {
                VStack(spacing: 12) {
                    Divider()
                        .background(Color.gray.opacity(0.3))

                    HStack {
                        Text("推奨設定")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(.gray)
                        Spacer()
                        Button("適用") {
                            Task { await applyRecommendation(recommendation) }
                        }
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.red.opacity(0.9))
                    }

                    // 評価セクション
                    VStack(spacing: 8) {
                        Text("この測光を評価")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.gray)

                        HStack(spacing: 8) {
                            ForEach(1...5, id: \.self) { rating in
                                Button {
                                    lastMeteringRating = rating
                                    saveMeteringEvaluation(recommendation, rating: rating)
                                } label: {
                                    Image(systemName: rating <= lastMeteringRating ? "star.fill" : "star")
                                        .font(.caption)
                                        .foregroundColor(rating <= lastMeteringRating ? .yellow : .gray)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(red: 0.15, green: 0.15, blue: 0.17))
                .shadow(color: .black.opacity(0.3), radius: 10, y: 5)
        )
    }

    // MARK: - センサー情報セクション

    private func sensorInfoSection(_ sensor: SensorStatus) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SENSOR DATA")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.red.opacity(0.7))
                .tracking(2)

            VStack(alignment: .leading, spacing: 8) {
                if let lux = sensor.lux {
                    sensorRow(label: "照度", value: String(format: "%.2f lux", lux))
                }
                if let brightness = sensor.brightness {
                    sensorRow(label: "明るさ", value: String(format: "%.1f", brightness))
                }
                if let aeGain = sensor.aeGain {
                    sensorRow(label: "ゲイン", value: String(format: "%.2f", aeGain))
                }
                if let aeExposureUs = sensor.aeExposureUs {
                    sensorRow(
                        label: "露光時間",
                        value: String(format: "%d μs", aeExposureUs)
                    )
                }
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(red: 0.15, green: 0.15, blue: 0.17))
                .shadow(color: .black.opacity(0.3), radius: 10, y: 5)
        )
    }

    private func sensorRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.gray)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.9))
        }
    }

    // MARK: - 現在の設定セクション

    private func currentSettingsSection(_ settings: CameraSettings) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CURRENT SETTINGS")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.red.opacity(0.7))
                .tracking(2)

            VStack(alignment: .leading, spacing: 8) {
                settingRow(label: "モード", value: settings.cameraMode.uppercased())
                settingRow(label: "ISO", value: settings.iso.displayString)
                settingRow(label: "SS", value: settings.shutterSpeed.displayString)
                settingRow(label: "WB", value: settings.whiteBalance.uppercased())
                settingRow(
                    label: "解像度",
                    value: "\(settings.width)x\(settings.height)"
                )
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(red: 0.15, green: 0.15, blue: 0.17))
                .shadow(color: .black.opacity(0.3), radius: 10, y: 5)
        )
    }

    private func settingRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.gray)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.9))
        }
    }

    // MARK: - API呼び出し

    private func refreshStatus() async {
        isLoading = true
        defer { isLoading = false }

        do {
            async let statusTask = api.fetchSensorStatus()
            async let settingsTask = api.fetchSettings()

            let (status, settings) = try await (statusTask, settingsTask)
            sensorStatus = status
            currentSettings = settings
        } catch {
            errorMessage = "ステータス取得失敗: \(error.localizedDescription)"
            showError = true
        }
    }

    private func performMetering() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let response = try await api.fetchMeteringRecommendation(
                targetISO: nil,
                targetShutterUs: nil
            )

            if response.success, let recommendation = response.recommendation {
                meteringRecommendation = recommendation
            } else {
                errorMessage = response.error ?? "測光に失敗しました"
                showError = true
            }
        } catch {
            errorMessage = "測光失敗: \(error.localizedDescription)"
            showError = true
        }
    }

    private func applyRecommendation(_ recommendation: MeteringRecommendation) async {
        isLoading = true
        defer { isLoading = false }

        do {
            try await api.applyMeteringRecommendation(
                iso: recommendation.recommendedISO,
                shutterUs: recommendation.recommendedShutterUs
            )

            // 設定を再取得
            currentSettings = try await api.fetchSettings()
        } catch {
            errorMessage = "設定適用失敗: \(error.localizedDescription)"
            showError = true
        }
    }

    private func saveMeteringEvaluation(_ recommendation: MeteringRecommendation, rating: Int) {
        let evaluation = MeteringEvaluation(context: viewContext)
        evaluation.id = UUID()
        evaluation.createdAt = Date()
        evaluation.sensorLux = recommendation.lux ?? 0
        evaluation.suggestedISO = Int32(recommendation.recommendedISO)
        evaluation.suggestedShutterUS = Int64(recommendation.recommendedShutterUs)
        evaluation.actualISO = Int32(recommendation.recommendedISO)
        evaluation.actualShutterUS = Int64(recommendation.recommendedShutterUs)
        evaluation.userRating = Int16(rating)
        evaluation.temperature = 0  // TODO: 温度センサーから取得
        evaluation.humidity = 0  // TODO: 湿度センサーから取得

        try? viewContext.save()
    }
}

// MARK: - Preview

struct CameraStatusView_Previews: PreviewProvider {
    static var previews: some View {
        CameraStatusView()
            .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
    }
}
