import Foundation
import Combine

/// グローバル接続監視: Pi への定期的な疎通チェックを行い、全タブで共有
@MainActor
final class ConnectionMonitor: ObservableObject {
    static let shared = ConnectionMonitor()

    @Published var isConnected: Bool = false
    @Published var lastChecked: Date?

    private var timer: Timer?
    private let checkInterval: TimeInterval = 5.0
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 6
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    /// 監視開始
    func startMonitoring() {
        stopMonitoring()
        Task { await checkConnection() }
        timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.checkConnection()
            }
        }
    }

    /// 監視停止
    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    /// 即時チェック
    func checkNow() async {
        await checkConnection()
    }

    /// serverIP を読み取り、Pi の /api/status へ HEAD/GET して到達性を判定
    private func checkConnection() async {
        let serverIP = UserDefaults.standard.string(forKey: "serverIP") ?? "192.168.4.1"
        guard let url = URL(string: "http://\(serverIP):8001/api/status") else {
            isConnected = false
            lastChecked = Date()
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (_, response) = try await session.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
               (200...499).contains(httpResponse.statusCode) {
                isConnected = true
            } else {
                isConnected = false
            }
        } catch {
            isConnected = false
        }

        lastChecked = Date()
    }
}
