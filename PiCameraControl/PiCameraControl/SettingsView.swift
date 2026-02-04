import SwiftUI

struct SettingsView: View {
    @AppStorage("serverIP") private var serverIP: String = "192.168.0.20"
    
    @State private var status: SystemStatus?
    @State private var threshold: Double = 30
    @State private var isLoading = false
    @State private var showIPAlert = false
    @State private var tempIP = ""
    
    private var api: SimpleCameraAPI {
        SimpleCameraAPI(baseURL: "http://\(serverIP):8001")
    }
    
    var body: some View {
        NavigationView {
            List {
                // システム状態
                Section("システム状態") {
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
                
                // 検知設定
                Section("光検知設定") {
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
                
                // サーバー設定
                Section("サーバー設定") {
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
                
                // 情報
                Section("情報") {
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
                let fetchedStatus = try await api.fetchStatus()
                await MainActor.run {
                    status = fetchedStatus
                    threshold = Double(fetchedStatus.brightnessThreshold)
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

#Preview {
    SettingsView()
}
