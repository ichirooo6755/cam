import Foundation
import Combine
import Network

/// グローバル接続監視: Pi への定期的な疎通チェックを行い、全タブで共有
/// NWPathMonitor でネットワーク変化をリアルタイム検知し、Timer ポーリングと併用
@MainActor
final class ConnectionMonitor: ObservableObject {
    static let shared = ConnectionMonitor()

    @Published var isConnected: Bool = false
    @Published var lastChecked: Date?
    @Published var consecutiveFailures: Int = 0

    private var timer: Timer?
    private let normalInterval: TimeInterval = 5.0
    private let fastInterval: TimeInterval = 2.0
    private let session: URLSession
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "connectionMonitor.nw")
    private var isCheckInFlight = false
    private var lastCheckStarted: Date = .distantPast

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 5
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        self.session = URLSession(configuration: config)
    }

    /// 監視開始
    func startMonitoring() {
        stopMonitoring()
        Task { await checkConnection() }
        scheduleTimer()
        startPathMonitor()
    }

    /// 監視停止
    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        pathMonitor.cancel()
    }

    /// フォアグラウンド復帰時に呼ぶ（即時チェック + Timer再開）
    func handleForegroundReturn() {
        consecutiveFailures = 0
        Task { await checkConnection() }
        scheduleTimer()
        startPathMonitor()
    }

    /// バックグラウンド移行時
    func handleBackgroundEntry() {
        timer?.invalidate()
        timer = nil
    }

    /// 即時チェック
    func checkNow() async {
        await checkConnection()
    }

    // MARK: - Private

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = isConnected ? normalInterval : fastInterval
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.checkConnection()
            }
        }
    }

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if path.status == .satisfied {
                    // ネットワーク復帰 → 即チェック
                    await self.checkConnection()
                } else {
                    self.isConnected = false
                    self.consecutiveFailures += 1
                }
            }
        }
        monitor.start(queue: pathMonitorQueue)
    }

    /// serverIP を読み取り、Pi の /api/status へ GET して到達性を判定
    private func checkConnection() async {
        // デバウンス: 1秒以内の連続呼び出しを抑制
        let now = Date()
        if now.timeIntervalSince(lastCheckStarted) < 1.0 { return }
        guard !isCheckInFlight else { return }
        isCheckInFlight = true
        lastCheckStarted = now
        defer { isCheckInFlight = false }

        let serverIP = UserDefaults.standard.string(forKey: "serverIP") ?? "192.168.4.1"
        guard let url = URL(string: "http://\(serverIP):8001/api/status") else {
            isConnected = false
            lastChecked = Date()
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let wasConnected = isConnected

        do {
            let (_, response) = try await session.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
               (200...499).contains(httpResponse.statusCode) {
                isConnected = true
                consecutiveFailures = 0
            } else {
                isConnected = false
                consecutiveFailures += 1
            }
        } catch {
            isConnected = false
            consecutiveFailures += 1
        }

        lastChecked = Date()

        // 接続状態が変化したらポーリング間隔を調整
        if wasConnected != isConnected {
            scheduleTimer()
        }
    }
}
