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
    /// `camera_service` の `sensor.state`（接続中のみ更新）。CSI 未接続などは `camera_unavailable`
    @Published private(set) var cameraSensorState: String?

    private var timer: Timer?
    private let normalInterval: TimeInterval = 5.0
    private let disconnectedBaseInterval: TimeInterval = 3.0
    private let maxPollingInterval: TimeInterval = 60.0
    private let maxFallbackAttempts: Int = 3
    private let offlineFailureThreshold: Int = 3
    /// Pi が AP のみで NTP 同期できないとき、iPhone 時刻との差がこれ以上なら /api/system/time で合わせる
    private let clockSyncSkewSeconds: TimeInterval = 12.0
    /// 連続失敗がこの回数を超えたら URLSession を作り直して
    /// 死んだ TCP コネクションの握り直しを促す
    private let sessionRecycleFailureThreshold: Int = 3
    private var session: URLSession
    private var activePathMonitor: NWPathMonitor?
    private let pathMonitorQueue = DispatchQueue(label: "connectionMonitor.nw")
    private var isCheckInFlight = false
    private var lastCheckStarted: Date = .distantPast
    private var lastSuccessfulCheck: Date?
    private var lastSessionRebuild: Date = .distantPast

    /// フォールバック候補IP（プライマリが失敗した場合に試す）
    private let fallbackIPs = ["192.168.4.1", "10.42.0.1"]

    /// Pi に繋がっているのにカメラハードが使えないとき、全タブ共通バナーを出す
    var needsCameraConnectorBanner: Bool {
        guard isConnected, let s = cameraSensorState else { return false }
        return s == "camera_unavailable" || s == "camera_recovering"
    }

    private init() {
        self.session = Self.makeSession()
    }

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 8
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.httpMaximumConnectionsPerHost = 2
        config.httpShouldUsePipelining = false
        return URLSession(configuration: config)
    }

    /// 死に接続を保持し続けないよう URLSession を作り直す。
    /// AP の瞬断後に iOS が古い TCP を握ったまま固まる現象の回避策。
    private func rebuildSession() {
        let now = Date()
        // 短時間に何度も作り直さない
        if now.timeIntervalSince(lastSessionRebuild) < 5.0 { return }
        lastSessionRebuild = now
        let old = session
        session = Self.makeSession()
        old.invalidateAndCancel()
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
        rebuildSession()
        Task {
            await checkConnection()
            if isConnected {
                let ip = UserDefaults.standard.string(forKey: "serverIP") ?? "192.168.4.1"
                let p = await probeStatus(ip: ip)
                await synchronizePiClockIfNeeded(ip: ip, serverTimeUnix: p.serverTimeUnix)
            }
        }
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
        let interval: TimeInterval
        if isConnected {
            interval = normalInterval
        } else {
            // 失敗回数に応じて指数的に間隔を延ばす（3s→6s→12s→...→最大60s）
            let backoff = disconnectedBaseInterval * pow(2.0, Double(min(consecutiveFailures, 5)))
            interval = min(backoff, maxPollingInterval)
        }
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
                    self.rebuildSession()
                    await self.checkConnection()
                } else {
                    // NWPath の瞬断だけで即オフライン確定せず、実疎通チェックで確定させる
                    self.rebuildSession()
                    await self.checkConnection()
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
        let primaryProbe = await probeStatus(ip: serverIP)
        if primaryProbe.ok {
            isConnected = true
            consecutiveFailures = 0
            lastSuccessfulCheck = Date()
            if !wasConnected {
                await synchronizePiClockIfNeeded(ip: serverIP, serverTimeUnix: primaryProbe.serverTimeUnix)
            }
        } else {
            consecutiveFailures += 1
            if consecutiveFailures >= offlineFailureThreshold || lastSuccessfulCheck == nil {
                isConnected = false
            }

            // AP瞬断後の死んだTCP接続を再利用し続けないよう、一定回数失敗したらSessionを作り直して再試行
            if consecutiveFailures >= sessionRecycleFailureThreshold {
                rebuildSession()
                let recycled = await probeStatus(ip: serverIP)
                if recycled.ok {
                    isConnected = true
                    consecutiveFailures = 0
                    lastSuccessfulCheck = Date()
                    lastChecked = Date()
                    if !wasConnected {
                        await synchronizePiClockIfNeeded(ip: serverIP, serverTimeUnix: recycled.serverTimeUnix)
                    }
                    if !wasConnected { scheduleTimer() }
                    lastChecked = Date()
                    await refreshCameraSensorState(ip: serverIP)
                    return
                }
            }

            // 3回連続失敗でフォールバックIPを試す（上限あり）
            if consecutiveFailures >= 3 && consecutiveFailures <= maxFallbackAttempts + 3 {
                for fallback in fallbackIPs where fallback != serverIP {
                    let fb = await probeStatus(ip: fallback)
                    if fb.ok {
                        UserDefaults.standard.set(fallback, forKey: "serverIP")
                        isConnected = true
                        consecutiveFailures = 0
                        lastSuccessfulCheck = Date()
                        if !wasConnected {
                            await synchronizePiClockIfNeeded(ip: fallback, serverTimeUnix: fb.serverTimeUnix)
                        }
                        break
                    }
                }
            }
        }

        lastChecked = Date()

        if isConnected {
            let ip = UserDefaults.standard.string(forKey: "serverIP") ?? "192.168.4.1"
            await refreshCameraSensorState(ip: ip)
        } else {
            cameraSensorState = nil
        }

        if wasConnected != isConnected {
            scheduleTimer()
        }
    }

    /// 指定IPの /api/status へ GET して到達性と Pi 時刻（あれば）を取得
    private func probeStatus(ip: String) async -> (ok: Bool, serverTimeUnix: Double?) {
        guard let url = URL(string: "http://\(ip):8001/api/status") else { return (false, nil) }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...499).contains(http.statusCode) else {
                return (false, nil)
            }
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let u = obj?["server_time_unix"] as? Double
            return (true, u)
        } catch {
            return (false, nil)
        }
    }

    private func synchronizePiClockIfNeeded(ip: String, serverTimeUnix: Double?) async {
        let now = Date().timeIntervalSince1970
        if let s = serverTimeUnix, abs(now - s) <= clockSyncSkewSeconds {
            return
        }
        await postUnixTimeToPi(ip: ip, unix: now)
    }

    private func postUnixTimeToPi(ip: String, unix: TimeInterval) async {
        guard let url = URL(string: "http://\(ip):8001/api/system/time") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["unix_time": unix])
        do {
            _ = try await session.data(for: req)
        } catch {}
    }

    private func refreshCameraSensorState(ip: String) async {
        guard let url = URL(string: "http://\(ip):8001/api/sensor/status") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let success = obj?["success"] as? Bool, success,
                  let sensor = obj?["sensor"] as? [String: Any],
                  let state = sensor["state"] as? String else { return }
            cameraSensorState = state
        } catch {}
    }
}
