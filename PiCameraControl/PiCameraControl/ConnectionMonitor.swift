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
    private var activePathMonitor: NWPathMonitor?
    private let pathMonitorQueue = DispatchQueue(label: "connectionMonitor.nw")
    private var isCheckInFlight = false
    private var lastCheckStarted: Date = .distantPast

    /// フォールバック候補IP（プライマリが失敗した場合に試す）
    private let fallbackIPs = ["192.168.4.1", "10.42.0.1"]

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
        activePathMonitor?.cancel()
        activePathMonitor = nil
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
        activePathMonitor?.cancel()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if path.status == .satisfied {
                    await self.checkConnection()
                } else {
                    self.isConnected = false
                    self.consecutiveFailures += 1
                }
            }
        }
        monitor.start(queue: pathMonitorQueue)
        activePathMonitor = monitor
    }

    /// serverIP を読み取り、Pi の /api/status へ GET して到達性を判定
    private func checkConnection() async {
        let now = Date()
        if now.timeIntervalSince(lastCheckStarted) < 1.0 { return }
        guard !isCheckInFlight else { return }
        isCheckInFlight = true
        lastCheckStarted = now
        defer { isCheckInFlight = false }

        let serverIP = UserDefaults.standard.string(forKey: "serverIP") ?? "192.168.4.1"
        let wasConnected = isConnected

        // プライマリIPで接続試行
        if await tryConnect(ip: serverIP) {
            isConnected = true
            consecutiveFailures = 0
        } else {
            consecutiveFailures += 1
            isConnected = false

            // 3回連続失敗でフォールバックIPを試す
            if consecutiveFailures >= 3 {
                for fallback in fallbackIPs where fallback != serverIP {
                    if await tryConnect(ip: fallback) {
                        UserDefaults.standard.set(fallback, forKey: "serverIP")
                        isConnected = true
                        consecutiveFailures = 0
                        break
                    }
                }
            }
        }

        lastChecked = Date()

        if wasConnected != isConnected {
            scheduleTimer()
        }
    }

    /// 指定IPの /api/status へ GET して到達性を判定
    private func tryConnect(ip: String) async -> Bool {
        guard let url = URL(string: "http://\(ip):8001/api/status") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse,
               (200...499).contains(http.statusCode) {
                return true
            }
        } catch {}
        return false
    }
}
