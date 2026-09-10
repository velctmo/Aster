import Foundation
import Combine
import AppKit
import SwiftUI

@MainActor
public class AsterState: ObservableObject {
    public static let shared = AsterState()

    /// A non-started state object for previews and isolated UI tests. The
    /// production singleton remains the only instance that owns daemon and
    /// WebSocket lifecycle work.
    static func previewState() -> AsterState { AsterState() }
    public let connectionStore = ConnectionStore()
    public let runtimeStore = RuntimeStore()
    public let ruleStore = RuleStore()

    // 核心状态
    @Published public var status: AppStatus = .placeholder {
        didSet {
            connectionStore.update(status: status)
            runtimeStore.update(status: status)
        }
    }
    @Published public var nodes: [ProxyNode] = []
    @Published public var strategyGroups: [StrategyGroup] = []

    // 默认主策略组 (包含全部可用节点，对应 sing-box 默认 PROXY 出站)
    public var defaultGroup: ProxyGroup {
        ProxyGroup(
            id: "proxy",
            name: "全部节点",
            type: "SELECTOR",
            selectedNodeTag: status.selected,
            nodeTags: nodes.map(\.tag)
        )
    }
    @Published public var configs: [ConfigProfileItem] = []
    @Published public var scripts: [ScriptItem] = []
    @Published public var configMutationError: String?
    @Published public var isConfigMutationInFlight = false
    @Published public var updatingConfigIds: Set<String> = [] // 正在更新的特定配置ID
    @Published public var isRefreshingAllConfigs: Bool = false // 正在全量更新配置
    @Published public var rules: [RuleItem] = [] {
        didSet { ruleStore.replace(rules: rules) }
    }
    @Published public var connections: [ConnectionItem] = []
    @Published public var recentRequests: [ConnectionItem] = []
    @Published public var logs: [LogEntry] = []

    // 流量与图表
    @Published public var downloadTotal: Int64 = 0
    @Published public var uploadTotal: Int64 = 0
    @Published public var currentUpSpeed: Int64 = 0
    @Published public var currentDownSpeed: Int64 = 0
    @Published public var trafficHistory: [TrafficHistoryPoint] = []

    // 连接与测速状态
    @Published public var isConnected: Bool = false
    @Published public var isTestingDelays: Bool = false
    @Published public var testingTags: Set<String> = [] // 节点独立测速中集合
    @Published public var testingSpeedTags: Set<String> = [] // 独立真实带宽吞吐测速中集合

    public func isNodeTesting(_ tag: String) -> Bool {
        return testingTags.contains(tag)
    }

    public func isNodeSpeedTesting(_ tag: String) -> Bool {
        return testingSpeedTags.contains(tag)
    }

    public func findNode(for tag: String) -> ProxyNode? {
        return nodes.first(where: { $0.tag == tag })
            ?? nodes.first(where: { $0.id == tag })
            ?? nodes.first(where: { $0.name == tag })
            ?? nodes.first(where: { tag.hasSuffix($0.name) || $0.tag.hasSuffix(tag) || tag.contains($0.name) })
    }

    // 出口与本机双 IP 信息
    @Published public var dualIP: DualIPInfo = .placeholder
    @Published public var isFetchingIP: Bool = false

    /// 获取本机活跃的局域网内网 IPv4 地址 (通常为 192.168.x.x 或 10.x.x.x)
    public var localLANIP: String {
        let address = "127.0.0.1"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return address }
        defer { freeifaddrs(ifaddr) }

        var ptr = firstAddr
        while true {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name.hasPrefix("en") || name.hasPrefix("eth") {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                &hostname, socklen_t(hostname.count),
                                nil, socklen_t(0), NI_NUMERICHOST)
                    let ip = String(decoding: hostname.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    if !ip.isEmpty && ip != "127.0.0.1" {
                        return ip
                    }
                }
            }
            guard let next = ptr.pointee.ifa_next else { break }
            ptr = next
        }
        return address
    }

    // 后台特性与采样开关
    @Published public var passiveSampling: Bool = true

    // 原生三级网络延时诊断与实时 Top 进程速率
    @Published public var diagnostics: NetworkDiagnostics = .placeholder
    @Published public var topProcesses: [ProcessTrafficStat] = []
    @Published public var isDiagnosing: Bool = false

    // iCloud 云端备份状态
    @Published public var iCloudStatus: ICloudStatusInfo = .placeholder

    // 高性能本地进程图标缓存 (避免每帧重复调用 NSWorkspace 耗尽主线程 CPU)
    private var iconCache: [String: NSImage] = [:]

    private var statusWsTask: URLSessionWebSocketTask?
    private var trafficWsTask: URLSessionWebSocketTask?
    private var connWsTask: URLSessionWebSocketTask?
    private var logsWsTask: URLSessionWebSocketTask?
    private var processesWsTask: URLSessionWebSocketTask?
    private var reconnectTasks: [String: Task<Void, Never>] = [:]
    private var connectionSnapshot = ConnectionSnapshot()
    private var pendingConnectionMutations: [ConnectionMutation] = []
    private var isProjectingConnectionMutations = false
    private var realtimeStreamingEnabled = false
    private var realtimeStreamGenerations: [String: UUID] = [:]
    // Each endpoint is independently buffered by URLSession. A global cursor
    // can drop a valid delayed process/log event merely because traffic arrived
    // first, so stale-event protection is scoped to the event type.
    private var latestRealtimeSequences: [String: UInt64] = [:]

    /// Control-plane base (scheme://host:port). Overridable via ASTER_API_BASE.
    private var apiBase: String {
        if let env = ProcessInfo.processInfo.environment["ASTER_API_BASE"], !env.isEmpty {
            return env.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        let port = UserDefaults.standard.object(forKey: "asterControlPort") as? Int ?? 1780
        return "http://127.0.0.1:\(port)"
    }

    private var wsBase: String {
        apiBase.replacingOccurrences(of: "http://", with: "ws://").replacingOccurrences(of: "https://", with: "wss://")
    }

    @Published public var daemonError: String = ""
    @Published public var actionError: String?
    @Published public var lastActiveAppName: String = ""
    @Published public var lastActiveAppBundleId: String? = nil
    private var apiToken: String = ""

    public func recordActiveApp(name: String, bundleId: String?) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "aster" else { return }
        self.lastActiveAppName = trimmed
        self.lastActiveAppBundleId = bundleId
    }

    /// All transient feedback is delivered by macOS Notification Center.
    public func notify(message: String, type: NotificationType = .info, duration: TimeInterval = 3.5) {
        let title: String
        switch type { case .error: title = "Aster 操作失败"; case .warning: title = "Aster 提醒"; case .success: title = "Aster 完成"; case .info: title = "Aster" }
        AppDelegate.shared?.postSystemNotification(title: title, body: message, category: type.rawValue)
    }

    /// 兼容现有 showToast 调用，全量统一分发
    public func showToast(message: String, isError: Bool = false) {
        notify(message: message, type: isError ? .error : .success)
    }

    private func dataDirURL() -> URL {
        if let env = ProcessInfo.processInfo.environment["ASTER_DATA_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Application Support/Aster", isDirectory: true)
    }

    private func loadAPIToken() {
        let url = dataDirURL().appendingPathComponent("machine.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["apiToken"] as? String else { return }
        apiToken = token
        if let port = obj["controlPort"] as? Int, port > 0 {
            UserDefaults.standard.set(port, forKey: "asterControlPort")
        }
    }

    private func apiURL(_ path: String, query: [URLQueryItem] = []) -> URL? {
        let items = query
        // WebSocket-friendly: also allow token query for WS upgrades
        guard var comp = URLComponents(string: apiBase + path) else { return nil }
        if !items.isEmpty {
            comp.queryItems = (comp.queryItems ?? []) + items
        }
        return comp.url
    }

    private func authorizedRequest(url: URL, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if !apiToken.isEmpty {
            request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func apiData(for request: URLRequest) async throws -> (Data, URLResponse) {
        var req = request
        if !apiToken.isEmpty && req.value(forHTTPHeaderField: "Authorization") == nil {
            req.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        }
        return try await URLSession.shared.data(for: req)
    }

    private func apiGet(_ path: String, query: [URLQueryItem] = []) async throws -> (Data, URLResponse) {
        guard let url = apiURL(path, query: query) else { throw URLError(.badURL) }
        return try await apiData(for: authorizedRequest(url: url))
    }


    private init() {
        // 初始化固定长度（60 点）滑动窗口缓冲，杜绝内存无限增长
        let now = Date()
        for i in 0..<60 {
            trafficHistory.append(
                TrafficHistoryPoint(
                    timestamp: now.addingTimeInterval(Double(i - 60)),
                    uploadSpeed: 0,
                    downloadSpeed: 0
                )
            )
        }
    }

    public func start() {
        realtimeStreamingEnabled = true
        loadAPIToken()
        ensureDaemonRunning()
        refreshAll()
        fetchIPInfo(force: false)
        startStatusWebSocket()
        startTrafficWebSocket()
        startConnectionsWebSocket()
        startLogsWebSocket()
        startProcessesWebSocket()
        Task { await self.fetchICloudStatus() }

    }

    // MARK: - 本地 App 图标缓存获取 (4级穿透解析 + SF Symbol 高质感降级引擎)
    public func iconForProcess(path: String, name: String, size: CGFloat = 28) -> NSImage {
        let key = path.isEmpty ? name : path
        if let cached = iconCache[key] {
            return cached
        }

        var icon: NSImage?
        let fileManager = FileManager.default

        // 1. 深度分析路径：若包含 .app/ 目录（哪怕深度嵌入在 Frameworks 或 Helpers 中），向上截取到主 .app 包路径
        var mainAppBundlePath: String?
        if !path.isEmpty && path.contains(".app") {
            let components = path.components(separatedBy: "/")
            var acc: [String] = []
            for comp in components {
                acc.append(comp)
                if comp.hasSuffix(".app") {
                    mainAppBundlePath = acc.joined(separator: "/")
                    break
                }
            }
        }

        if let appPath = mainAppBundlePath, fileManager.fileExists(atPath: appPath) {
            icon = NSWorkspace.shared.icon(forFile: appPath)
        } else if !path.isEmpty && fileManager.fileExists(atPath: path) && !path.hasPrefix("/dev") {
            // 普通独立二进制或外部可执行程序
            icon = NSWorkspace.shared.icon(forFile: path)
        }

        // 2. 若仍未匹配成功，通过进程名称匹配运行中进程 (NSRunningApplication) 与剥离 Helper
        if icon == nil && !name.isEmpty {
            let runningApps = NSWorkspace.shared.runningApplications
            // 剥离辅助后缀，如 "Google Chrome Helper (Renderer)" -> "Google Chrome"
            var baseName = name
            for suffix in [" Helper", " (Renderer)", " (GPU)", " (Plugin)", " Service", " Agent", " Daemon"] {
                if let range = baseName.range(of: suffix) {
                    baseName = String(baseName[..<range.lowerBound])
                }
            }
            baseName = baseName.trimmingCharacters(in: .whitespacesAndNewlines)

            // 先完全匹配
            if let matchedApp = runningApps.first(where: {
                $0.localizedName?.localizedCaseInsensitiveCompare(name) == .orderedSame ||
                $0.executableURL?.lastPathComponent.localizedCaseInsensitiveCompare(name) == .orderedSame ||
                $0.localizedName?.localizedCaseInsensitiveCompare(baseName) == .orderedSame ||
                $0.executableURL?.lastPathComponent.localizedCaseInsensitiveCompare(baseName) == .orderedSame
            }) {
                icon = matchedApp.icon
            }

            // 3. 搜索系统与用户应用程序目录
            if icon == nil {
                let cleanName = baseName.replacingOccurrences(of: ".app", with: "")
                let candidates = [
                    "/Applications/\(cleanName).app",
                    "/System/Applications/\(cleanName).app",
                    "/System/Applications/Utilities/\(cleanName).app",
                    NSHomeDirectory() + "/Applications/\(cleanName).app"
                ]
                for c in candidates {
                    if fileManager.fileExists(atPath: c) {
                        icon = NSWorkspace.shared.icon(forFile: c)
                        break
                    }
                }
            }
        }

        // 4. 特殊命令行工具与系统核心守护进程的精致 SF Symbol 矢量图标降级
        if icon == nil {
            let lower = name.lowercased()
            let symConfig = NSImage.SymbolConfiguration(pointSize: size * 1.5, weight: .medium)

            if lower.contains("chrome") {
                icon = NSImage(systemSymbolName: "globe", accessibilityDescription: name)?.withSymbolConfiguration(symConfig)
            } else if lower.contains("cursor") || lower.contains("code") || lower.contains("xcode") || lower.contains("sublime") {
                icon = NSImage(systemSymbolName: "chevron.left.forwardslash.chevron.right", accessibilityDescription: name)?.withSymbolConfiguration(symConfig)
            } else if lower.contains("node") || lower.contains("python") || lower.contains("go") || lower.contains("ruby") || lower.contains("java") {
                icon = NSImage(systemSymbolName: "curlybraces", accessibilityDescription: name)?.withSymbolConfiguration(symConfig)
            } else if lower.contains("git") || lower.contains("docker") || lower.contains("cargo") {
                icon = NSImage(systemSymbolName: "shippingbox.fill", accessibilityDescription: name)?.withSymbolConfiguration(symConfig)
            } else if lower.contains("codex") || lower.contains("bash") || lower.contains("zsh") || lower.contains("sh") || lower.contains("fish") || lower.contains("iterm") || lower.contains("terminal") {
                icon = NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: name)?.withSymbolConfiguration(symConfig)
            } else if lower.contains("curl") || lower.contains("wget") || lower.contains("http") || lower.contains("dns") || lower.contains("mdns") {
                icon = NSImage(systemSymbolName: "network", accessibilityDescription: name)?.withSymbolConfiguration(symConfig)
            } else if lower.contains("syspolicy") || lower.contains("trustd") || lower.contains("security") || lower.contains("auth") {
                icon = NSImage(systemSymbolName: "shield.lefthalf.filled", accessibilityDescription: name)?.withSymbolConfiguration(symConfig)
            } else if lower.contains("apple") || lower.contains("system") || lower.contains("kernel") || lower.contains("launchd") {
                icon = NSImage(systemSymbolName: "apple.logo", accessibilityDescription: name)?.withSymbolConfiguration(symConfig)
            } else {
                icon = NSImage(systemSymbolName: "app.fill", accessibilityDescription: name)?.withSymbolConfiguration(symConfig)
            }
        }

        let finalIcon = icon ?? NSWorkspace.shared.icon(for: .application)
        finalIcon.size = NSSize(width: size * 2, height: size * 2)
        iconCache[key] = finalIcon
        return finalIcon
    }

    // MARK: - 后台 Go 引擎健康监控
    public func ensureDaemonRunning() {
        Task {
            let running = await pingDaemon()
            if !running {
                launchDaemonProcess()
            }
        }
    }

    private func pingDaemon() async -> Bool {
        guard let url = apiURL("/api/v1/status") else { return false }
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                self.isConnected = true
                return true
            }
        } catch {
            self.isConnected = false
        }
        return false
    }

    private func launchDaemonProcess() {
        let fileManager = FileManager.default
        var daemonPath = ""

        if let env = ProcessInfo.processInfo.environment["ASTER_DAEMON"], fileManager.isExecutableFile(atPath: env) {
            daemonPath = env
        } else if let resourcePath = Bundle.main.resourceURL?.appendingPathComponent("aster-daemon").path,
           fileManager.isExecutableFile(atPath: resourcePath) {
            daemonPath = resourcePath
        }

        guard !daemonPath.isEmpty else {
            self.daemonError = "未找到 aster-daemon（请使用 make app 打包，或设置 ASTER_DAEMON）"
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: daemonPath)
        process.arguments = []
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            self.daemonError = ""
            Task {
                for _ in 0..<8 {
                    try? await Task.sleep(for: .milliseconds(250))
                    self.loadAPIToken()
                    if await self.pingDaemon() { break }
                }
                self.refreshAll()
            }
        } catch {
            self.daemonError = "启动守护进程失败: \(error.localizedDescription)"
            print(self.daemonError)
        }
    }

    // MARK: - 轮询与全量拉取
    public func refreshAll() {
        Task {
            await fetchStatus()
            await fetchNodes()
			await fetchStrategyGroups()
			await fetchConfigs()
            await fetchRules()
            await fetchSettings()
            await fetchDiagnostics()
            await fetchTopProcesses()
            await fetchConnections()
            self.fetchIPInfo()
        }
    }

    public func fetchConnections() async {
        guard let url = apiURL("/api/v1/connections") else { return }
        do {
            let (data, response) = try await apiData(for: authorizedRequest(url: url))
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            let decoded = try await Self.decode(ConnectionsResponse.self, from: data)
            enqueueConnectionMutation(.snapshot(decoded))
            if let version = decoded.snapshotVersion {
                self.latestRealtimeSequences["connections"] = max(self.latestRealtimeSequences["connections"] ?? 0, version)
            }
        } catch {}
    }

    public func mergeRecentConnections(_ newConns: [ConnectionItem]) {
        let response = ConnectionsResponse(
            snapshotVersion: nil,
            downloadTotal: downloadTotal,
            uploadTotal: uploadTotal,
            connections: newConns
        )
        applyConnectionSnapshot(connectionSnapshot.replacingActiveConnections(with: response))
    }

    public func clearRecentRequests() {
        applyConnectionSnapshot(
            ConnectionSnapshot(
                connections: connectionSnapshot.connections,
                recentRequests: [],
                downloadTotal: connectionSnapshot.downloadTotal,
                uploadTotal: connectionSnapshot.uploadTotal
            )
        )
    }

    private func applyConnectionDelta(_ delta: ConnectionsDelta) {
        enqueueConnectionMutation(.delta(delta))
    }

    private func enqueueConnectionMutation(_ mutation: ConnectionMutation) {
        pendingConnectionMutations.append(mutation)
        guard !isProjectingConnectionMutations else { return }
        isProjectingConnectionMutations = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            while !self.pendingConnectionMutations.isEmpty {
                let mutation = self.pendingConnectionMutations.removeFirst()
                let previous = self.connectionSnapshot
                let snapshot: ConnectionSnapshot
                switch mutation {
                case .snapshot(let response):
                    snapshot = await Self.projectConnections(previous, replacingWith: response)
                case .delta(let delta):
                    snapshot = await Self.projectConnections(previous, applying: delta)
                }
                self.applyConnectionSnapshot(snapshot)
            }
            self.isProjectingConnectionMutations = false
        }
    }

    private func applyConnectionSnapshot(_ snapshot: ConnectionSnapshot) {
        guard connectionSnapshot != snapshot else { return }
        connectionSnapshot = snapshot
        connectionStore.replace(snapshot: snapshot)
        if connections != snapshot.connections { connections = snapshot.connections }
        if recentRequests != snapshot.recentRequests { recentRequests = snapshot.recentRequests }
        if downloadTotal != snapshot.downloadTotal { downloadTotal = snapshot.downloadTotal }
        if uploadTotal != snapshot.uploadTotal { uploadTotal = snapshot.uploadTotal }
    }

    private nonisolated static func decode<T: Decodable & Sendable>(_ type: T.Type, from data: Data) async throws -> T {
        try await Task.detached(priority: .utility) {
            try JSONDecoder().decode(T.self, from: data)
        }.value
    }

    private nonisolated static func projectConnections(_ previous: ConnectionSnapshot, replacingWith response: ConnectionsResponse) async -> ConnectionSnapshot {
        await Task.detached(priority: .utility) {
            previous.replacingActiveConnections(with: response)
        }.value
    }

    private nonisolated static func projectConnections(_ previous: ConnectionSnapshot, applying delta: ConnectionsDelta) async -> ConnectionSnapshot {
        await Task.detached(priority: .utility) {
            previous.applying(delta)
        }.value
    }

    public func fetchStatus() async {
        guard let url = apiURL("/api/v1/status") else { return }
        do {
            let (data, response) = try await apiData(for: authorizedRequest(url: url))
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            let decoded = try JSONDecoder().decode(AppStatus.self, from: data)
            self.status = decoded
            self.isConnected = true
        } catch {
            self.isConnected = false
        }
    }

    public func fetchNodes() async {
        guard let url = apiURL("/api/v1/nodes") else { return }
        do {
            let (data, response) = try await apiData(for: authorizedRequest(url: url))
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            let decoded = try JSONDecoder().decode([ProxyNode].self, from: data)
            self.nodes = decoded
        } catch {}
    }

    public func fetchStrategyGroups() async {
        guard let url = apiURL("/api/v1/strategy-groups") else { return }
        do {
            let (data, response) = try await apiData(for: authorizedRequest(url: url))
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            strategyGroups = try JSONDecoder().decode([StrategyGroup].self, from: data)
        } catch {
            strategyGroups = []
        }
    }

    public func testStrategyGroup(_ group: StrategyGroup) {
        guard status.running else {
            actionError = "核心未运行，无法测速"
            return
        }
        let tags = group.leafTags
        testingTags.formUnion(tags)
        AppDelegate.shared?.refreshStatusMenu()
        Task { @MainActor in
            defer {
                self.testingTags.subtract(tags)
                AppDelegate.shared?.refreshStatusMenu()
            }
            guard let url = self.apiURL("/api/v1/strategy-groups/\(group.tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? group.tag)/delay") else { return }
            let request = self.authorizedRequest(url: url, method: "POST")
            do {
                let (data, response) = try await self.apiData(for: request)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw NSError(domain: "Aster", code: -1, userInfo: [NSLocalizedDescriptionKey: "策略组测速失败"]) }
                if let results = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    for result in results {
                        guard let tag = result["tag"] as? String, let delay = result["delay"] as? Int else { continue }
                        if let index = self.nodes.firstIndex(where: { $0.tag == tag || $0.id == tag || $0.name == tag || tag.hasSuffix($0.name) || $0.tag.hasSuffix(tag) }) {
                            self.nodes[index].delayMs = delay
                        }
                        if let gIdx = self.strategyGroups.firstIndex(where: { $0.tag == tag || $0.name == tag }) {
                            self.strategyGroups[gIdx].delayMs = delay
                        }
                    }
                }
                await self.fetchNodes()
                AppDelegate.shared?.refreshStatusMenu()
            } catch {
                self.actionError = error.localizedDescription
                AppDelegate.shared?.refreshStatusMenu()
            }
        }
    }

    public func selectStrategyGroupNode(group: StrategyGroup, tag: String) {
        guard group.type == "selector", let encoded = group.tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), let url = apiURL("/api/v1/strategy-groups/\(encoded)/select") else { return }
        // 乐观更新本地 strategyGroups 与 status，防止界面闪烁
        if let idx = self.strategyGroups.firstIndex(where: { $0.tag == group.tag }) {
            self.strategyGroups[idx].now = tag
        }
        if group.tag == "proxy" || group.tag == self.status.selected {
            self.status.selected = tag
            if tag == "auto" {
                if let autoGroup = self.strategyGroups.first(where: { $0.tag == "auto" }), let now = autoGroup.now, !now.isEmpty {
                    let winName = self.findNode(for: now)?.name ?? now
                    self.status.selectedLabel = "自动选择 ➔ \(winName)"
                } else {
                    self.status.selectedLabel = "自动选择"
                }
            } else if let n = self.findNode(for: tag) {
                self.status.selectedLabel = n.name
            }
            AppDelegate.shared?.refreshStatusMenu()
        }
        Task { @MainActor in
            var request = self.authorizedRequest(url: url, method: "POST")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["tag": tag])
            do {
                let (_, response) = try await self.apiData(for: request)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw NSError(domain: "Aster", code: -1, userInfo: [NSLocalizedDescriptionKey: "选择策略组节点失败"]) }
                await self.fetchStatus()
                await self.fetchStrategyGroups()
            } catch { self.actionError = error.localizedDescription }
        }
    }

    public func fetchConfigs() async {
        guard let url = apiURL("/api/v1/configs") else { return }
        do {
            let (data, response) = try await apiData(for: authorizedRequest(url: url))
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            configs = try JSONDecoder().decode([ConfigProfileItem].self, from: data)
            await fetchScripts()
        } catch {}
    }

    public func fetchRules() async {
        guard let url = apiURL("/api/v1/rules") else { return }
        do {
            let (data, response) = try await apiData(for: authorizedRequest(url: url))
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            let decoded = try JSONDecoder().decode([RuleItem].self, from: data)
            self.rules = decoded
        } catch {}
    }

    public func setMode(_ mode: String) {
        triggerHaptic()
        // 乐观更新：立刻在界面上呈现所选分流模式，杜绝回跳
        self.status.mode = mode
        patchAction("/api/v1/mode", body: ["mode": mode])
        triggerAutoFetchIP()
    }

    public func setCapture(systemProxy: Bool, tun: Bool) {
        triggerHaptic()
        patchAction("/api/v1/capture", body: ["systemProxy": systemProxy, "tun": tun])
        triggerAutoFetchIP()
    }

    public func selectNode(_ tag: String) {
        triggerHaptic()
        // 乐观更新：立刻在界面上呈现选中状态
        self.status.selected = tag
        if let node = nodes.first(where: { $0.tag == tag }) {
            self.status.selectedLabel = node.name
        }
        postAction("/api/v1/nodes/select", body: ["tag": tag])
        triggerAutoFetchIP()
    }

    private func triggerAutoFetchIP() {
        Task {
            try? await Task.sleep(for: .milliseconds(1_200))
            self.fetchIPInfo(force: true)
        }
    }

    public func fetchIPInfo(force: Bool = false) {
        guard !isFetchingIP else { return }
        isFetchingIP = true
        Task { @MainActor in
            defer { self.isFetchingIP = false }
            guard let url = apiURL("/api/v1/ip", query: [URLQueryItem(name: "force", value: force ? "1" : "0")]) else { return }
            do {
                let (data, response) = try await apiData(for: authorizedRequest(url: url))
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
                // 1. 优先尝试解码最新的双 IP 结构
                if let decoded = try? JSONDecoder().decode(DualIPInfo.self, from: data) {
                    self.dualIP = decoded
                    return
                }
                // 2. 容灾兼容：若守护进程为旧版单 IP 格式
                if let single = try? JSONDecoder().decode(IPInfo.self, from: data) {
                    self.dualIP = DualIPInfo(
                        localIP: single,
                        proxyIP: single,
                        protected: false,
                        fetchedAt: single.fetchedAt
                    )
                }
            } catch {
                print("获取双 IP 信息失败: \(error)")
            }
        }
    }

    public func testNodeDelay(_ tag: String) {
		guard status.running else {
			actionError = "核心未运行，无法测速"
			return
		}
        triggerHaptic()
        testingTags.insert(tag)
        Task { @MainActor in
            defer { self.testingTags.remove(tag) }
            guard let url = apiURL("/api/v1/nodes/delay") else { return }
            var request = authorizedRequest(url: url, method: "POST")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 10.0
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["tag": tag])
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                    throw NSError(domain: "Aster", code: (response as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: message ?? "节点延迟测试失败"])
                }
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
					if let message = obj["error"] as? String, !message.isEmpty {
						throw NSError(domain: "Aster", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
					}
					if let d = obj["delay"] as? Int, d > 0 {
                    if let idx = self.nodes.firstIndex(where: { $0.tag == tag }) {
                        self.nodes[idx].delayMs = d
                    }
                }
				}
                self.actionError = nil
            } catch {
                self.actionError = error.localizedDescription
            }
            await self.fetchNodes()
            await self.fetchStatus()
        }
    }

    public func testAllNodes() {
		guard !isTestingDelays else { return }
		guard status.running else {
			actionError = "核心未运行，无法测速"
			return
		}
        isTestingDelays = true
        triggerHaptic()
        let tags = nodes.filter { !$0.disabled && $0.tag != "auto" }.map { $0.tag }
        for t in tags {
            testingTags.insert(t)
        }
        Task { @MainActor in
            defer {
                self.isTestingDelays = false
                self.testingTags.removeAll()
            }
            guard !tags.isEmpty, let url = apiURL("/api/v1/nodes/delay") else {
                return
            }
            var request = authorizedRequest(url: url, method: "POST")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 45.0 // 并发测完全量节点可能需要较长时间
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["tags": tags])
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode == 200,
                   let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    var delayMap: [String: Int] = [:]
                    for item in list {
                        if let t = item["tag"] as? String, let d = item["delay"] as? Int {
                            delayMap[t] = d
                        }
                    }
                    for i in 0..<self.nodes.count {
                        if let d = delayMap[self.nodes[i].tag] {
                            self.nodes[i].delayMs = d
                        }
                    }
                    
                    // 测速汇总统计：不针对任何单个节点报错，仅计算整体可用率与最优节点
                    let testedNodes = self.nodes.filter { tags.contains($0.tag) }
                    let totalCount = testedNodes.count
                    let availableNodes = testedNodes.filter { $0.delayMs > 0 }
                    let timeoutNodes = testedNodes.filter { $0.delayMs <= 0 }
                    let availableCount = availableNodes.count
                    let timeoutCount = timeoutNodes.count

                    let summary: String
                    let isSuccess: Bool
                    if let best = availableNodes.min(by: { $0.delayMs < $1.delayMs }) {
                        summary = "共测速 \(totalCount) 个节点：\(availableCount) 可用，\(timeoutCount) 超时。最优: \(best.name) (\(best.delayMs)ms)"
                        isSuccess = true
                    } else if totalCount > 0 {
                        summary = "共测速 \(totalCount) 个节点：全部超时"
                        isSuccess = false
                    } else {
                        summary = "暂无可测速节点"
                        isSuccess = false
                    }

                    // 统一弹出最终汇总通知，持续 4.5 秒展示倒计时进度条
                    self.notify(message: summary, type: isSuccess ? .success : .warning, duration: 4.5)
                }
            } catch {
                let errMsg = "批量测速请求异常：\(error.localizedDescription)"
                self.notify(message: errMsg, type: .error)
            }
            await self.fetchNodes()
            await self.fetchStatus()
            AppDelegate.shared?.updateStatusItemTitle()
        }
    }

    // MARK: - 3.2 独立真实带宽吞吐测速 (Cloudflare 10MB 切片)
    public func testNodeBandwidth(_ tag: String) {
        guard !testingSpeedTags.contains(tag) else { return }
        triggerHaptic()
        testingSpeedTags.insert(tag)
        Task { @MainActor in
            defer { self.testingSpeedTags.remove(tag) }
            guard let url = apiURL("/api/v1/nodes/speedtest") else { return }
            var request = authorizedRequest(url: url, method: "POST")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 15.0
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["tag": tag])
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                    throw NSError(domain: "Aster", code: (response as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: message ?? "节点带宽测速失败"])
                }
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let mbps = obj["bandwidthMbps"] as? Double {
                    if let idx = self.nodes.firstIndex(where: { $0.tag == tag }) {
                        self.nodes[idx].bandwidthMbps = mbps
                    }
                }
                self.actionError = nil
            } catch {
                self.actionError = error.localizedDescription
            }
        }
    }

    // MARK: - 快捷规则注入（连接审计）
    public func addRuleFromConnection(hostOrIP: String, action: String, connectionId: String? = nil) {
        triggerHaptic()
        let cleanTarget = hostOrIP.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTarget.isEmpty else { return }

        Task { @MainActor in
            guard let url = apiURL("/api/v1/rules/from-log") else {
                self.showToast(message: "控制平面服务未连接", isError: true)
                return
            }
            var request = authorizedRequest(url: url, method: "POST")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "host": cleanTarget,
                "match": "domain_suffix",
                "action": action
            ])
            do {
                let (data, response) = try await apiData(for: request)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    let errMsg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                    self.showToast(message: "规则注入失败: \(errMsg ?? "服务端拒绝")", isError: true)
                    return
                }
                if let updatedRules = try? JSONDecoder().decode([RuleItem].self, from: data) {
                    self.rules = updatedRules
                } else {
                    await self.fetchRules()
                }
                await self.fetchStatus()
                if let connId = connectionId, !connId.isEmpty {
                    self.closeConnection(connId)
                }
                self.showToast(message: "已注入分流规则: \(cleanTarget) → \(action.uppercased())")
            } catch {
                self.showToast(message: "注入规则失败: \(error.localizedDescription)", isError: true)
            }
        }
    }

    public func restartCore() {
        triggerHaptic()
        postAction("/api/v1/restart", body: [:])
    }

    // MARK: - 测速探针配置与设置持久化
    public func updateDelayURL(_ url: String) async throws {
        triggerHaptic()
        guard let endpoint = apiURL("/api/v1/settings") else {
            throw NSError(domain: "Aster", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的服务地址"])
        }
        var request = authorizedRequest(url: endpoint, method: "PATCH")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["delayURL": url])
        let (data, response) = try await apiData(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String ?? "更新测速探针失败"
            throw NSError(domain: "Aster", code: (response as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        if let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let persisted = settings["delayURL"] as? String {
            status.delayURL = persisted
        }
        actionError = nil
        await fetchSettings()
        await fetchStatus()
    }

    public func patchSettings(body: [String: Any]) {
        triggerHaptic()
        guard let url = apiURL("/api/v1/settings") else { return }
        var request = authorizedRequest(url: url, method: "PATCH")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        Task { @MainActor in
            await self.performStatusAction(request)
            // Settings are reflected by AppStorage-backed controls. Always
            // re-read the canonical server state so a rejected mutation cannot
            // leave an optimistic toggle or probe URL displayed as enabled.
            await self.fetchSettings()
            await self.fetchStatus()
        }
    }

    public func togglePassiveSampling(_ enabled: Bool) {
        self.passiveSampling = enabled
        patchSettings(body: ["passiveSampling": enabled])
    }

    public func fetchSettings() async {
        guard let url = apiURL("/api/v1/settings") else { return }
        do {
            let (data, response) = try await apiData(for: authorizedRequest(url: url))
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
				if let v = obj["delayURL"] as? String {
					self.status.delayURL = v
				}
                if let ps = obj["passiveSampling"] as? Bool {
                    self.passiveSampling = ps
                }
                if let v = obj["strictRoute"] as? Bool {
                    UserDefaults.standard.set(v, forKey: "enableStrictRoute")
                }
                if let v = obj["allowLan"] as? Bool {
                    UserDefaults.standard.set(v, forKey: "allowLanSharing")
                }
                if let v = obj["autostart"] as? Bool {
                    UserDefaults.standard.set(v, forKey: "autoLaunchOnLogin")
                }
                if let v = obj["delayTimeoutMs"] as? Int {
                    UserDefaults.standard.set(v, forKey: "speedtestTimeoutMs")
                } else if let v = obj["delayTimeoutMs"] as? Double {
                    UserDefaults.standard.set(Int(v), forKey: "speedtestTimeoutMs")
                }
                if let v = obj["delayConcurrency"] as? Int {
                    UserDefaults.standard.set(v, forKey: "speedtestConcurrency")
                } else if let v = obj["delayConcurrency"] as? Double {
                    UserDefaults.standard.set(Int(v), forKey: "speedtestConcurrency")
                }
                if let v = obj["controlPort"] as? Int, v > 0 {
                    UserDefaults.standard.set(v, forKey: "asterControlPort")
                } else if let v = obj["controlPort"] as? Double, v > 0 {
                    UserDefaults.standard.set(Int(v), forKey: "asterControlPort")
                }
            }
        } catch {}
    }

    // MARK: - 三级网络延时诊断与 Top 进程速率
    public func fetchDiagnostics(force: Bool = false) async {
        isDiagnosing = true
        defer { isDiagnosing = false }
        guard let url = apiURL("/api/v1/network/diagnostics", query: [URLQueryItem(name: "force", value: force ? "true" : "false")]) else { return }
        do {
            let (data, response) = try await apiData(for: authorizedRequest(url: url))
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            if let decoded = try? JSONDecoder().decode(NetworkDiagnostics.self, from: data) {
                self.diagnostics = decoded
            }
        } catch {}
    }

    public func fetchTopProcesses() async {
        guard let url = apiURL("/api/v1/traffic/processes") else { return }
        do {
            let (data, response) = try await apiData(for: authorizedRequest(url: url))
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            if let decoded = try? JSONDecoder().decode([ProcessTrafficStat].self, from: data) {
                self.topProcesses = decoded
            }
        } catch {}
    }

    // MARK: - 复制终端代理命令 (⌘C)
    public func copyTerminalProxyCommand() {
        triggerHaptic()
        let port = status.mixedPort ?? 2080
        let cmd = "export http_proxy=http://127.0.0.1:\(port) https_proxy=http://127.0.0.1:\(port) all_proxy=socks5://127.0.0.1:\(port)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
    }

    public func exportDiagnosticsReport() async throws {
        guard let url = apiURL("/api/v1/diagnostics/report") else {
            throw NSError(domain: "Aster", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的服务地址"])
        }
        let (data, response) = try await apiData(for: authorizedRequest(url: url))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "Aster", code: (response as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: "导出诊断报告失败"])
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "aster-diagnostics.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        try data.write(to: destination, options: .atomic)
    }

    // MARK: - iCloud 多端云备份与恢复
    public func fetchICloudStatus() async {
        guard let url = apiURL("/api/v1/backup/icloud") else { return }
        do {
            let (data, response) = try await apiData(for: authorizedRequest(url: url))
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            if let decoded = try? JSONDecoder().decode(ICloudStatusInfo.self, from: data) {
                self.iCloudStatus = decoded
            }
        } catch {}
    }

    public func exportToICloud() async throws {
        triggerHaptic()
        guard let url = apiURL("/api/v1/backup/icloud/export") else {
            throw NSError(domain: "Aster", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的服务地址"])
        }
        let (data, response) = try await apiData(for: authorizedRequest(url: url, method: "POST"))
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String ?? "备份至 iCloud 失败"
            throw NSError(domain: "Aster", code: (response as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        if let decoded = try? JSONDecoder().decode(ICloudStatusInfo.self, from: data) {
            iCloudStatus = decoded
        } else {
            await fetchICloudStatus()
        }
    }

    public func importFromICloud() async throws {
        triggerHaptic()
        guard let url = apiURL("/api/v1/backup/icloud/import") else {
            throw NSError(domain: "Aster", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的服务地址"])
        }
        let (data, response) = try await apiData(for: authorizedRequest(url: url, method: "POST"))
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String ?? "从 iCloud 恢复失败"
            throw NSError(domain: "Aster", code: (response as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        relaunchAfterConfigurationRestore()
    }

    // MARK: - WebDAV 私有网盘备份与恢复
    public func testWebDAVConnection(config: WebDAVConfig) async throws {
        let cleanURL = config.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: cleanURL) else {
            throw NSError(domain: "Aster", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的 WebDAV 服务器地址"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "PROPFIND"
        req.setValue("0", forHTTPHeaderField: "Depth")
        if !config.username.isEmpty {
            let auth = "\(config.username):\(config.password)"
            if let data = auth.data(using: .utf8) {
                req.setValue("Basic \(data.base64EncodedString())", forHTTPHeaderField: "Authorization")
            }
        }
        let (_, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) || http.statusCode == 207 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "Aster", code: code, userInfo: [NSLocalizedDescriptionKey: "连接失败 (HTTP \(code))，请检查地址或账密"])
        }
    }

    public func exportToWebDAV(config: WebDAVConfig) async throws {
        triggerHaptic()
        guard let exportURL = apiURL("/api/v1/backup/export") else {
            throw NSError(domain: "Aster", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法获取本地配置导出数据"])
        }
        let (backupData, exportResp) = try await apiData(for: authorizedRequest(url: exportURL))
        guard let httpExport = exportResp as? HTTPURLResponse, httpExport.statusCode == 200 else {
            throw NSError(domain: "Aster", code: -1, userInfo: [NSLocalizedDescriptionKey: "生成本地备份数据包失败"])
        }

        let baseURL = config.serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let remoteDir = config.remotePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let targetDirURLStr = remoteDir.isEmpty ? baseURL : "\(baseURL)/\(remoteDir)"
        guard let dirURL = URL(string: targetDirURLStr), let fileURL = URL(string: "\(targetDirURLStr)/aster-backup.zip") else {
            throw NSError(domain: "Aster", code: -1, userInfo: [NSLocalizedDescriptionKey: "远程 WebDAV 路径解析错误"])
        }

        // 尝试创建远程目录 (MKCOL)
        if !remoteDir.isEmpty {
            var mkcolReq = URLRequest(url: dirURL)
            mkcolReq.httpMethod = "MKCOL"
            if !config.username.isEmpty {
                let auth = "\(config.username):\(config.password)"
                if let data = auth.data(using: .utf8) {
                    mkcolReq.setValue("Basic \(data.base64EncodedString())", forHTTPHeaderField: "Authorization")
                }
            }
            _ = try? await URLSession.shared.data(for: mkcolReq)
        }

        // 上传备份文件 (PUT)
        var putReq = URLRequest(url: fileURL)
        putReq.httpMethod = "PUT"
        putReq.setValue("application/zip", forHTTPHeaderField: "Content-Type")
        if !config.username.isEmpty {
            let auth = "\(config.username):\(config.password)"
            if let data = auth.data(using: .utf8) {
                putReq.setValue("Basic \(data.base64EncodedString())", forHTTPHeaderField: "Authorization")
            }
        }
        putReq.httpBody = backupData

        let (_, putResp) = try await URLSession.shared.data(for: putReq)
        guard let httpPut = putResp as? HTTPURLResponse, (200...299).contains(httpPut.statusCode) else {
            let code = (putResp as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "Aster", code: code, userInfo: [NSLocalizedDescriptionKey: "上传至 WebDAV 失败 (HTTP \(code))"])
        }
    }

    public func importFromWebDAV(config: WebDAVConfig) async throws {
        triggerHaptic()
        let baseURL = config.serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let remoteDir = config.remotePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let targetDirURLStr = remoteDir.isEmpty ? baseURL : "\(baseURL)/\(remoteDir)"
        guard let fileURL = URL(string: "\(targetDirURLStr)/aster-backup.zip") else {
            throw NSError(domain: "Aster", code: -1, userInfo: [NSLocalizedDescriptionKey: "远程 WebDAV 路径解析错误"])
        }

        var getReq = URLRequest(url: fileURL)
        getReq.httpMethod = "GET"
        if !config.username.isEmpty {
            let auth = "\(config.username):\(config.password)"
            if let data = auth.data(using: .utf8) {
                getReq.setValue("Basic \(data.base64EncodedString())", forHTTPHeaderField: "Authorization")
            }
        }

        let (data, getResp) = try await URLSession.shared.data(for: getReq)
        guard let httpGet = getResp as? HTTPURLResponse, (200...299).contains(httpGet.statusCode) else {
            let code = (getResp as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "Aster", code: code, userInfo: [NSLocalizedDescriptionKey: "未能从 WebDAV 下载备份 (HTTP \(code)，请确认已备份)"])
        }

        guard let importURL = apiURL("/api/v1/backup/import") else {
            throw NSError(domain: "Aster", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法访问本地导入服务接口"])
        }
        var importReq = authorizedRequest(url: importURL, method: "POST")
        importReq.setValue("application/zip", forHTTPHeaderField: "Content-Type")
        importReq.httpBody = data

        let (respData, importResp) = try await apiData(for: importReq)
        guard let httpImport = importResp as? HTTPURLResponse, (200...299).contains(httpImport.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: respData) as? [String: Any])?["error"] as? String ?? "导入备份数据失败"
            throw NSError(domain: "Aster", code: (importResp as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: message])
        }

        relaunchAfterConfigurationRestore()
    }

    // MARK: - 本地备份文件导出与恢复
    public func exportLocalBackup() async throws {
        triggerHaptic()
        guard let exportURL = apiURL("/api/v1/backup/export") else {
            throw NSError(domain: "Aster", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法访问本地配置导出接口"])
        }
        let (data, response) = try await apiData(for: authorizedRequest(url: exportURL))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "Aster", code: (response as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: "导出本地备份失败"])
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "aster-backup-\(Int64(Date().timeIntervalSince1970)).zip"
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        try data.write(to: destination, options: .atomic)
    }

    public func importLocalBackup() async throws {
        triggerHaptic()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }
        let data = try Data(contentsOf: sourceURL)
        guard let importURL = apiURL("/api/v1/backup/import") else {
            throw NSError(domain: "Aster", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法访问本地导入接口"])
        }
        var request = authorizedRequest(url: importURL, method: "POST")
        request.setValue("application/zip", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let (respData, response) = try await apiData(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: respData) as? [String: Any])?["error"] as? String ?? "恢复备份失败"
            throw NSError(domain: "Aster", code: (response as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        relaunchAfterConfigurationRestore()
    }

    private func relaunchAfterConfigurationRestore() {
        notify(message: "配置已恢复，Aster 正在重新启动…", type: .success)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.relaunchApplication()
        }
    }

    public func clearSystemProxyResidue() async throws {
        triggerHaptic()
        guard let url = apiURL("/api/v1/clear-proxy") else {
            throw NSError(domain: "Aster", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法访问清理代理服务"])
        }
        let (data, response) = try await apiData(for: authorizedRequest(url: url, method: "POST"))
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String ?? "清理代理残留失败"
            throw NSError(domain: "Aster", code: (response as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        refreshAll()
    }

    // MARK: - 重启整个 Aster 应用程序
    public func relaunchApplication() {
        triggerHaptic()
        let appBundleURL = Bundle.main.bundleURL

        // 1. 优先安全停止当前后台 daemon，确保释放 1780 / 2080 / 2090 端口
        let dataDirectory: URL
        if let override = ProcessInfo.processInfo.environment["ASTER_DATA_DIR"], !override.isEmpty {
            dataDirectory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            dataDirectory = FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Application Support/Aster", directoryHint: .isDirectory)
        }
        let pidURL = dataDirectory.appending(path: "daemon.pid")
        if let rawPID = try? String(contentsOf: pidURL, encoding: .utf8),
           let pid = Int32(rawPID.trimmingCharacters(in: .whitespacesAndNewlines)),
           pid > 0 {
            _ = Darwin.kill(pid, SIGTERM)
        }

        // 2. 通过后台独立进程延迟 300ms 唤起新 App，保证端口完全解绑
        let script = "sleep 0.35; open -n \"\(appBundleURL.path)\""
        let restartProc = Process()
        restartProc.executableURL = URL(fileURLWithPath: "/bin/sh")
        restartProc.arguments = ["-c", script]
        try? restartProc.run()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.terminate(nil)
        }
    }

    // MARK: - 订阅管理
    public func createConfig(name: String, kind: String, url: String = "", content: String = "", urls: [String] = [], activate: Bool = true) async throws {
        _ = try await createConfigAndReturn(
            name: name,
            kind: kind,
            url: url,
            content: content,
            urls: urls,
            activate: activate
        )
    }

    func createConfigAndReturn(name: String, kind: String, url: String = "", content: String = "", urls: [String] = [], activate: Bool = true) async throws -> ConfigProfileItem {
        triggerHaptic()
        guard let endpoint = apiURL("/api/v1/configs") else {
            throw NSError(domain: "Aster", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的服务地址"])
        }
        var request = authorizedRequest(url: endpoint, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 45
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": name, "kind": kind, "url": url, "content": content, "urls": urls, "activate": activate
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String ?? "添加配置失败"
            throw NSError(domain: "Aster", code: (response as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        let createdProfiles = try JSONDecoder().decode([ConfigProfileItem].self, from: data)
        guard let created = createdProfiles.last else {
            throw NSError(domain: "Aster", code: -1, userInfo: [NSLocalizedDescriptionKey: "服务端未返回新建配置"])
        }
        self.configs = createdProfiles
        await fetchNodes()
        await fetchStrategyGroups()
        await fetchStatus()
        return created
    }

    public func activateConfig(id: String) {
        triggerHaptic()
        performConfigMutation("/api/v1/configs/\(id)/activate")
    }

    public func refreshConfig(id: String) {
        triggerHaptic()
        updatingConfigIds.insert(id)
        performConfigMutation("/api/v1/configs/\(id)/refresh", specificId: id) { [weak self] success, err in
            guard let self = self else { return }
            self.updatingConfigIds.remove(id)
            if success {
                let name = self.configs.first(where: { $0.id == id })?.name ?? "配置"
                self.showToast(message: "已成功更新订阅: \(name)")
            } else if let err = err {
                self.showToast(message: "更新失败: \(err)", isError: true)
            }
        }
    }

    public func refreshAllConfigs() {
        triggerHaptic()
        isRefreshingAllConfigs = true
        for c in configs { updatingConfigIds.insert(c.id) }
        performConfigMutation("/api/v1/configs/refresh-all") { [weak self] success, err in
            guard let self = self else { return }
            self.isRefreshingAllConfigs = false
            self.updatingConfigIds.removeAll()
            if success {
                self.showToast(message: "全部配置与订阅已更新完毕")
            } else if let err = err {
                self.showToast(message: "更新出现异常: \(err)", isError: true)
            }
        }
    }

    public func deleteConfig(id: String) {
        triggerHaptic()
        performConfigMutation("/api/v1/configs/\(id)", method: "DELETE")
    }

    // Config operations can render, validate, restart, or fetch subscriptions.
    // Their duration is intentionally not guessed with a fixed delay; refresh
    // presentation state only after the daemon has answered.
    private func performConfigMutation(
        _ path: String,
        method: String = "POST",
        specificId: String? = nil,
        completion: ((Bool, String?) -> Void)? = nil
    ) {
        guard !isConfigMutationInFlight, let endpoint = apiURL(path) else {
            completion?(false, "已有配置操作正在执行中")
            return
        }
        var request = authorizedRequest(url: endpoint, method: method)
        if method != "DELETE" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: [:])
        }
        request.timeoutInterval = 45
        isConfigMutationInFlight = true
        configMutationError = nil
        Task { @MainActor in
            var isSuccess = false
            var errorMsg: String? = nil
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                    let err = message ?? "配置操作失败"
                    errorMsg = err
                    throw NSError(
                        domain: "Aster",
                        code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                        userInfo: [NSLocalizedDescriptionKey: err]
                    )
                }
                isSuccess = true
            } catch {
                let msg = error.localizedDescription
                self.configMutationError = msg
                errorMsg = msg
            }
            await self.fetchConfigs()
            await self.fetchNodes()
            await self.fetchStatus()
            self.isConfigMutationInFlight = false
            completion?(isSuccess, errorMsg)
        }
    }

    public func setConfigScript(id: String, script: String) async throws {
        guard let endpoint = apiURL("/api/v1/configs/\(id)/script") else {
            throw NSError(domain: "Aster", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的服务地址"])
        }
        var request = authorizedRequest(url: endpoint, method: "PUT")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["script": script])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String ?? "保存覆写失败"
            throw NSError(domain: "Aster", code: (response as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        await fetchConfigs()
        await fetchNodes()
    }

    public func fetchScripts() async {
        guard let url = apiURL("/api/v1/scripts") else { return }
        do {
            let (data, response) = try await apiData(for: authorizedRequest(url: url))
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            self.scripts = try JSONDecoder().decode([ScriptItem].self, from: data)
        } catch {}
    }

    public func createScript(name: String, kind: String, content: String) async throws -> ScriptItem {
        guard let endpoint = apiURL("/api/v1/scripts") else {
            throw NSError(domain: "Aster", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的服务地址"])
        }
        var request = authorizedRequest(url: endpoint, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": name,
            "kind": kind,
            "content": content
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String ?? "创建脚本失败"
            throw NSError(domain: "Aster", code: (response as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        let created = try JSONDecoder().decode(ScriptItem.self, from: data)
        await fetchScripts()
        return created
    }

    public func updateScript(id: String, name: String, content: String) async throws {
        guard let endpoint = apiURL("/api/v1/scripts/\(id)") else {
            throw NSError(domain: "Aster", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的服务地址"])
        }
        var request = authorizedRequest(url: endpoint, method: "PUT")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": name,
            "content": content
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String ?? "更新脚本失败"
            throw NSError(domain: "Aster", code: (response as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        await fetchScripts()
        await fetchConfigs()
        await fetchNodes()
    }

    public func deleteScript(id: String) async throws {
        guard let endpoint = apiURL("/api/v1/scripts/\(id)") else {
            throw NSError(domain: "Aster", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的服务地址"])
        }
        let request = authorizedRequest(url: endpoint, method: "DELETE")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String ?? "删除脚本失败"
            throw NSError(domain: "Aster", code: (response as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        await fetchScripts()
        await fetchConfigs()
        await fetchNodes()
    }

    public func bindScript(profileId: String, scriptId: String?) async throws {
        guard let endpoint = apiURL("/api/v1/configs/\(profileId)/bind-script") else {
            throw NSError(domain: "Aster", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的服务地址"])
        }
        var request = authorizedRequest(url: endpoint, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["scriptId": scriptId ?? ""])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String ?? "挂载脚本失败"
            throw NSError(domain: "Aster", code: (response as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        await fetchConfigs()
        await fetchNodes()
    }

    // MARK: - 分流规则管理
    public func addRule(match: String, value: String, action: String) async throws {
        triggerHaptic()
        let cleanVal = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanVal.isEmpty else {
            throw NSError(domain: "Aster", code: -1, userInfo: [NSLocalizedDescriptionKey: "规则目标值不能为空"])
        }
        guard let url = apiURL("/api/v1/rules") else {
            throw NSError(domain: "Aster", code: -1, userInfo: [NSLocalizedDescriptionKey: "控制平面服务未连接"])
        }
        var request = authorizedRequest(url: url, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "match": match,
            "value": cleanVal,
            "action": action
        ])
        let (data, response) = try await apiData(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let errMsg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            let err = NSError(
                domain: "Aster",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: errMsg ?? "添加规则失败"]
            )
            self.showToast(message: "添加规则失败: \(err.localizedDescription)", isError: true)
            throw err
        }
        if let updatedRules = try? JSONDecoder().decode([RuleItem].self, from: data) {
            self.rules = updatedRules
        } else {
            await self.fetchRules()
        }
        await self.fetchStatus()
        self.showToast(message: "已添加分流规则: \(cleanVal) → \(action.uppercased())")
    }

    public func addRule(match: String, value: String, action: String) {
        Task { @MainActor in
            do {
                try await self.addRule(match: match, value: value, action: action)
            } catch {
                // Toast 提示已在内部触发
            }
        }
    }

    public func deleteRule(id: String) {
        triggerHaptic()
        let previousRules = self.rules
        withAnimation(.easeInOut(duration: 0.2)) {
            self.rules.removeAll { $0.id == id }
        }
        Task { @MainActor in
            guard let url = apiURL("/api/v1/rules/\(id)") else { return }
            let request = authorizedRequest(url: url, method: "DELETE")
            do {
                let (data, response) = try await apiData(for: request)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    let errMsg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                    withAnimation {
                        self.rules = previousRules
                    }
                    self.showToast(message: "删除规则失败: \(errMsg ?? "服务端拒绝")", isError: true)
                    return
                }
                if let updatedRules = try? JSONDecoder().decode([RuleItem].self, from: data) {
                    self.rules = updatedRules
                } else {
                    await self.fetchRules()
                }
                await self.fetchStatus()
                self.showToast(message: "已删除分流规则")
            } catch {
                withAnimation {
                    self.rules = previousRules
                }
                self.showToast(message: "删除规则失败: \(error.localizedDescription)", isError: true)
            }
        }
    }

    // MARK: - 连接与抓包断开
    public func closeConnection(_ id: String) {
        triggerHaptic()
        deleteAction("/api/v1/connections/\(id)")
    }

    public func closeAllConnections() {
        triggerHaptic()
        deleteAction("/api/v1/connections")
    }

    // MARK: - 快捷菜单专享：为当前浏览器活跃网页呼出 Surge 风格多态弹窗
    public func promptAddRuleForCurrentWebpage() {
        triggerHaptic()
        if let info = getActiveBrowserInfo(), !info.host.isEmpty {
            let context = AddRuleContext.forWebpage(url: info.url, domain: info.host, icon: info.icon)
            DispatchQueue.main.async {
                AddRuleWindowController.shared.show(context: context)
            }
        } else {
            // Fail-Safe: 未探测到活跃网页时降级打开自定义规则弹窗，绝不展示空占位
            self.showToast(message: "未检测到活跃网页，已打开自定义规则编辑", isError: false)
            let fallbackContext = AddRuleContext.forCustom(type: .domainSuffix, value: "", action: "DIRECT")
            DispatchQueue.main.async {
                AddRuleWindowController.shared.show(context: fallbackContext)
            }
        }
    }

    private struct BrowserInfo {
        let name: String
        let url: String
        let host: String
        let icon: NSImage?
    }

    private struct SupportedBrowserSpec {
        let bundleId: String
        let displayName: String
        let scriptApp: String
        let isSafari: Bool
    }

    private func getActiveBrowserInfo() -> BrowserInfo? {
        let specs: [SupportedBrowserSpec] = [
            SupportedBrowserSpec(bundleId: "com.google.Chrome", displayName: "Google Chrome", scriptApp: "Google Chrome", isSafari: false),
            SupportedBrowserSpec(bundleId: "com.apple.Safari", displayName: "Safari", scriptApp: "Safari", isSafari: true),
            SupportedBrowserSpec(bundleId: "company.thebrowser.Browser", displayName: "Arc", scriptApp: "Arc", isSafari: false),
            SupportedBrowserSpec(bundleId: "com.microsoft.edgemac", displayName: "Microsoft Edge", scriptApp: "Microsoft Edge", isSafari: false),
            SupportedBrowserSpec(bundleId: "com.brave.Browser", displayName: "Brave Browser", scriptApp: "Brave Browser", isSafari: false),
            SupportedBrowserSpec(bundleId: "com.google.Chrome.canary", displayName: "Google Chrome Canary", scriptApp: "Google Chrome Canary", isSafari: false),
            SupportedBrowserSpec(bundleId: "org.chromium.Chromium", displayName: "Chromium", scriptApp: "Chromium", isSafari: false),
            SupportedBrowserSpec(bundleId: "com.vivaldi.Vivaldi", displayName: "Vivaldi", scriptApp: "Vivaldi", isSafari: false),
            SupportedBrowserSpec(bundleId: "com.operasoftware.Opera", displayName: "Opera", scriptApp: "Opera", isSafari: false)
        ]

        // 1. 原生零权限获取当前运行中应用，排除未运行浏览器，杜绝 AppleScript 假死或权限弹窗
        let runningApps = NSWorkspace.shared.runningApplications
        var matchedRunning: [(spec: SupportedBrowserSpec, app: NSRunningApplication)] = []

        for spec in specs {
            if let app = runningApps.first(where: { $0.bundleIdentifier == spec.bundleId }) {
                matchedRunning.append((spec, app))
            }
        }

        guard !matchedRunning.isEmpty else {
            return fallbackClipboardBrowserInfo()
        }

        // 2. 排序优先度：激活中的浏览器 > 上次焦点浏览器 > 默认顺序
        matchedRunning.sort { a, b in
            if a.app.isActive && !b.app.isActive { return true }
            if !a.app.isActive && b.app.isActive { return false }
            if let lastBundle = self.lastActiveAppBundleId {
                if a.spec.bundleId == lastBundle { return true }
                if b.spec.bundleId == lastBundle { return false }
            }
            if !self.lastActiveAppName.isEmpty {
                let aMatch = a.spec.displayName.localizedCaseInsensitiveContains(self.lastActiveAppName) ||
                             (a.app.localizedName?.localizedCaseInsensitiveContains(self.lastActiveAppName) ?? false)
                let bMatch = b.spec.displayName.localizedCaseInsensitiveContains(self.lastActiveAppName) ||
                             (b.app.localizedName?.localizedCaseInsensitiveContains(self.lastActiveAppName) ?? false)
                if aMatch && !bMatch { return true }
                if !aMatch && bMatch { return false }
            }
            return false
        }

        // 3. 依次尝试向目标浏览器读取活跃标签页的 URL
        for pair in matchedRunning {
            let spec = pair.spec
            let script: String
            if spec.isSafari {
                script = """
                tell application "Safari"
                    if (count of windows) > 0 then
                        return URL of current tab of front window
                    end if
                end tell
                return ""
                """
            } else {
                script = """
                tell application "\(spec.scriptApp)"
                    if (count of windows) > 0 then
                        return URL of active tab of front window
                    end if
                end tell
                return ""
                """
            }

            if let rawURL = runAppleScriptSource(script),
               let (cleanURL, cleanHost) = sanitizeHostAndURL(rawURL) {
                let icon = pair.app.icon ?? iconForBrowser(name: spec.displayName)
                return BrowserInfo(name: spec.displayName, url: cleanURL, host: cleanHost, icon: icon)
            }
        }

        // 4. 兜底策略：检测系统剪贴板中是否包含合法的 http/https 链接
        return fallbackClipboardBrowserInfo()
    }

    private func runAppleScriptSource(_ source: String) -> String? {
        if let script = NSAppleScript(source: source) {
            var err: NSDictionary?
            let res = script.executeAndReturnError(&err)
            if err == nil, let str = res.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !str.isEmpty {
                return str
            }
        }

        // 双保险回退：通过 /usr/bin/osascript 子进程执行，规避宿主权限环境差异
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let out = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if !out.isEmpty { return out }
            }
        } catch {}
        return nil
    }

    private func fallbackClipboardBrowserInfo() -> BrowserInfo? {
        if let pasteboardString = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           pasteboardString.hasPrefix("http://") || pasteboardString.hasPrefix("https://") {
            if let (cleanURL, cleanHost) = sanitizeHostAndURL(pasteboardString) {
                let icon = iconForProcess(path: "", name: "Safari", size: 40)
                return BrowserInfo(name: "剪贴板网页", url: cleanURL, host: cleanHost, icon: icon)
            }
        }
        return nil
    }

    private func sanitizeHostAndURL(_ raw: String) -> (url: String, host: String)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 排除浏览器内部协议页面与本地空白起始页
        let ignorePrefixes = ["chrome://", "chrome-extension://", "edge://", "about:", "safari-resource://", "brave://", "file://", "favorites://"]
        for prefix in ignorePrefixes {
            if trimmed.lowercased().hasPrefix(prefix) {
                return nil
            }
        }

        var candidate = trimmed
        if !candidate.contains("://") {
            candidate = "https://" + candidate
        }

        guard let parsed = URL(string: candidate), let host = parsed.host, !host.isEmpty else {
            return nil
        }

        return (trimmed, host)
    }

    private func iconForBrowser(name: String) -> NSImage? {
        let bundleIds: [String: String] = [
            "Google Chrome": "com.google.Chrome",
            "Safari": "com.apple.Safari",
            "Microsoft Edge": "com.microsoft.edgemac",
            "Arc": "company.thebrowser.Browser",
            "Brave Browser": "com.brave.Browser",
            "Google Chrome Canary": "com.google.Chrome.canary",
            "Chromium": "org.chromium.Chromium"
        ]
        if let bid = bundleIds[name], let path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid)?.path {
            return NSWorkspace.shared.icon(forFile: path)
        }
        return iconForProcess(path: "", name: name, size: 40)
    }

    public func triggerHaptic() {
        NSHapticFeedbackManager.defaultPerformer.perform(
            .alignment,
            performanceTime: .default
        )
    }

    // MARK: - 网络基础请求
    private func postAction(_ path: String, body: [String: Any]) {
        guard let url = apiURL(path) else { return }
        var request = authorizedRequest(url: url, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        Task { @MainActor in await self.performStatusAction(request) }
    }

    private func patchAction(_ path: String, body: [String: Any]) {
        guard let url = apiURL(path) else { return }
        var request = authorizedRequest(url: url, method: "PATCH")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        Task { @MainActor in await self.performStatusAction(request) }
    }

    // Every mutating control operation reconciles with daemon state.  A server
    // rejection is surfaced to the window instead of leaving an optimistic UI
    // value with no explanation.
    private func performStatusAction(_ request: URLRequest) async {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                throw NSError(
                    domain: "Aster",
                    code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                    userInfo: [NSLocalizedDescriptionKey: message ?? "操作失败"]
                )
            }
            if let decoded = try? JSONDecoder().decode(AppStatus.self, from: data) {
                self.status = decoded
            }
            self.actionError = nil
        } catch {
            self.actionError = error.localizedDescription
        }
        await self.fetchStatus()
    }

    private func deleteAction(_ path: String) {
        guard let url = apiURL(path) else { return }
        let request = authorizedRequest(url: url, method: "DELETE")
        Task { @MainActor in
            do {
                let (data, response) = try await apiData(for: request)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                    throw NSError(
                        domain: "Aster",
                        code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                        userInfo: [NSLocalizedDescriptionKey: message ?? "删除操作失败"]
                    )
                }
                self.actionError = nil
            } catch {
                self.actionError = error.localizedDescription
            }
            await self.fetchRules()
            await self.fetchConnections()
            await self.fetchStatus()
        }
    }

    private func wsURL(_ path: String) -> URL? {
        var items: [URLQueryItem] = []
        if !apiToken.isEmpty {
            items.append(URLQueryItem(name: "token", value: apiToken))
        }
        guard let httpURL = apiURL(path, query: items) else { return nil }
        var s = httpURL.absoluteString
        if s.hasPrefix("https://") {
            s = "wss://" + s.dropFirst("https://".count)
        } else if s.hasPrefix("http://") {
            s = "ws://" + s.dropFirst("http://".count)
        }
        return URL(string: s)
    }

    public func stopRealtimeStreams() {
        realtimeStreamingEnabled = false
        reconnectTasks.values.forEach { $0.cancel() }
        reconnectTasks.removeAll()
        realtimeStreamGenerations.removeAll()
        statusWsTask?.cancel(with: .goingAway, reason: nil)
        trafficWsTask?.cancel(with: .goingAway, reason: nil)
        connWsTask?.cancel(with: .goingAway, reason: nil)
        logsWsTask?.cancel(with: .goingAway, reason: nil)
        processesWsTask?.cancel(with: .goingAway, reason: nil)
        statusWsTask = nil
        trafficWsTask = nil
        connWsTask = nil
        logsWsTask = nil
        processesWsTask = nil
    }

    private func cancelPendingReconnect(for stream: String) {
        reconnectTasks.removeValue(forKey: stream)?.cancel()
    }

    private func beginRealtimeStream(_ stream: String) -> UUID {
        let generation = UUID()
        realtimeStreamGenerations[stream] = generation
        return generation
    }

    private func isCurrentRealtimeStream(_ stream: String, generation: UUID) -> Bool {
        realtimeStreamingEnabled && realtimeStreamGenerations[stream] == generation
    }

    private func scheduleReconnect(
        for stream: String,
        operation: @escaping @MainActor () async -> Void
    ) {
        guard realtimeStreamingEnabled else { return }
        cancelPendingReconnect(for: stream)
        reconnectTasks[stream] = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
            guard !Task.isCancelled, self?.realtimeStreamingEnabled == true else { return }
            await operation()
        }
    }

    // MARK: - WebSocket 实时流（状态、流量、连接、审计日志）
    private func startStatusWebSocket() {
        guard let url = wsURL("/api/v1/ws/status") else { return }
        cancelPendingReconnect(for: "status")
        let generation = beginRealtimeStream("status")
        statusWsTask?.cancel()
        statusWsTask = URLSession.shared.webSocketTask(with: url)
        statusWsTask?.resume()
        receiveStatusMessage(generation: generation)
    }

    private func receiveStatusMessage(generation: UUID) {
        statusWsTask?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                if case .string(let text) = message,
                   let data = text.data(using: .utf8),
                   let event = try? JSONDecoder().decode(RealtimeEvent.self, from: data) {
                    if event.type == "status",
                       let status = event.data.decoded(AppStatus.self) {
                        Task { @MainActor in
                            guard self.isCurrentRealtimeStream("status", generation: generation), self.accept(event) else { return }
                            self.status = status
                            self.isConnected = true
                        }
                    } else if event.type == "notify" {
                        struct NotifyPayload: Codable {
                            let title: String?
                            let message: String
                            let type: String?
                        }
                        if let payload = event.data.decoded(NotifyPayload.self) {
                            Task { @MainActor in
                                guard self.isCurrentRealtimeStream("status", generation: generation) else { return }
                                let nType: NotificationType = (payload.type == "error") ? .error : .info
                                if let title = payload.title, !title.isEmpty {
                                    AppDelegate.shared?.postSystemNotification(title: title, body: payload.message, category: "core")
                                } else {
                                    self.notify(message: payload.message, type: nType)
                                }
                            }
                        }
                    }
                }
                Task { @MainActor in
                    guard self.isCurrentRealtimeStream("status", generation: generation) else { return }
                    self.receiveStatusMessage(generation: generation)
                }
            case .failure:
                Task { @MainActor [weak self] in
                    guard let self, self.isCurrentRealtimeStream("status", generation: generation) else { return }
                    self.scheduleReconnect(for: "status") { [weak self] in
                        guard let self else { return }
                        await self.fetchStatus()
                        self.startStatusWebSocket()
                    }
                }
            }
        }
    }

    private func startTrafficWebSocket() {
        guard let url = wsURL("/api/v1/ws/traffic") else { return }
        cancelPendingReconnect(for: "traffic")
        let generation = beginRealtimeStream("traffic")
        trafficWsTask?.cancel()
        trafficWsTask = URLSession.shared.webSocketTask(with: url)
        trafficWsTask?.resume()
        receiveTrafficMessage(generation: generation)
    }

    private func receiveTrafficMessage(generation: UUID) {
        trafficWsTask?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                if case .string(let text) = message,
                   let data = text.data(using: .utf8) {
                    if let event = try? JSONDecoder().decode(RealtimeEvent.self, from: data) {
                        if event.type == "node_delay",
                           let payload = event.data.decoded(NodeDelayEvent.self) {
                            Task { @MainActor in
                                guard self.isCurrentRealtimeStream("traffic", generation: generation), self.accept(event) else { return }
                                if let idx = self.nodes.firstIndex(where: { $0.tag == payload.tag || $0.id == payload.tag || $0.name == payload.tag || payload.tag.hasSuffix($0.name) || $0.tag.hasSuffix(payload.tag) }) {
                                    self.nodes[idx].delayMs = payload.delay
                                }
                                if let gIdx = self.strategyGroups.firstIndex(where: { $0.tag == payload.tag || $0.name == payload.tag }) {
                                    self.strategyGroups[gIdx].delayMs = payload.delay
                                }
                                self.testingTags.remove(payload.tag)
                                AppDelegate.shared?.notifyNodeDelayUpdated(tag: payload.tag, delay: payload.delay)
                            }
                        } else if event.type == "node_speed",
                                  let payload = event.data.decoded(NodeSpeedEvent.self) {
                            Task { @MainActor in
                                guard self.isCurrentRealtimeStream("traffic", generation: generation), self.accept(event) else { return }
                                if let idx = self.nodes.firstIndex(where: { $0.tag == payload.tag }) {
                                    self.nodes[idx].bandwidthMbps = payload.bandwidthMbps
                                }
                                self.testingSpeedTags.remove(payload.tag)
                            }
                        } else if event.type == "nodes",
                                  let nodes = event.data.decoded([ProxyNode].self) {
                            Task { @MainActor in
                                guard self.isCurrentRealtimeStream("traffic", generation: generation), self.accept(event) else { return }
                                self.nodes = nodes
                            }
                        } else if event.type == "traffic",
                                  let sample = event.data.decoded(TrafficSample.self) {
                        Task { @MainActor in
                            guard self.isCurrentRealtimeStream("traffic", generation: generation), self.accept(event) else { return }
                            self.currentUpSpeed = sample.up
                            self.currentDownSpeed = sample.down
                            self.connectionStore.updateTraffic(up: sample.up, down: sample.down)

                            var history = self.trafficHistory
                            if history.count >= 60 {
                                history.removeFirst()
                            }
                            history.append(
                                TrafficHistoryPoint(
                                    timestamp: Date(),
                                    uploadSpeed: Double(sample.up),
                                    downloadSpeed: Double(sample.down)
                                )
                            )
                            self.trafficHistory = history
	                        }
	                    }
	                }
	                }
                Task { @MainActor in
                    guard self.isCurrentRealtimeStream("traffic", generation: generation) else { return }
                    self.receiveTrafficMessage(generation: generation)
                }
            case .failure:
                Task { @MainActor [weak self] in
                    guard let self, self.isCurrentRealtimeStream("traffic", generation: generation) else { return }
                    self.scheduleReconnect(for: "traffic") { [weak self] in
                        self?.startTrafficWebSocket()
                    }
                }
            }
        }
    }

    private func startConnectionsWebSocket() {
        guard let url = wsURL("/api/v1/ws/connections") else { return }
        cancelPendingReconnect(for: "connections")
        let generation = beginRealtimeStream("connections")
        connWsTask?.cancel()
        connWsTask = URLSession.shared.webSocketTask(with: url)
        connWsTask?.resume()
        receiveConnectionsMessage(generation: generation)
    }

    private func receiveConnectionsMessage(generation: UUID) {
        connWsTask?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                if case .string(let text) = message,
                   let data = text.data(using: .utf8),
                   let event = try? JSONDecoder().decode(RealtimeEvent.self, from: data),
                   event.type == "connections",
                   let delta = event.data.decoded(ConnectionsDelta.self) {
                    Task { @MainActor in
                        guard self.isCurrentRealtimeStream("connections", generation: generation), self.accept(event) else { return }
                        self.applyConnectionDelta(delta)
                    }
                }
                Task { @MainActor in
                    guard self.isCurrentRealtimeStream("connections", generation: generation) else { return }
                    self.receiveConnectionsMessage(generation: generation)
                }
            case .failure:
                Task { @MainActor [weak self] in
                    guard let self, self.isCurrentRealtimeStream("connections", generation: generation) else { return }
                    self.scheduleReconnect(for: "connections") { [weak self] in
                        guard let self else { return }
                        await self.fetchConnections()
                        self.startConnectionsWebSocket()
                    }
                }
            }
        }
    }

    private func startLogsWebSocket() {
        guard let url = wsURL("/api/v1/ws/logs") else { return }
        cancelPendingReconnect(for: "logs")
        let generation = beginRealtimeStream("logs")
        logsWsTask?.cancel()
        logsWsTask = URLSession.shared.webSocketTask(with: url)
        logsWsTask?.resume()
        receiveLogsMessage(generation: generation)
    }

    private func startProcessesWebSocket() {
        guard let url = wsURL("/api/v1/ws/processes") else { return }
        cancelPendingReconnect(for: "processes")
        let generation = beginRealtimeStream("processes")
        processesWsTask?.cancel()
        processesWsTask = URLSession.shared.webSocketTask(with: url)
        processesWsTask?.resume()
        receiveProcessesMessage(generation: generation)
    }

    private func receiveProcessesMessage(generation: UUID) {
        processesWsTask?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                if case .string(let text) = message,
                   let data = text.data(using: .utf8),
                   let event = try? JSONDecoder().decode(RealtimeEvent.self, from: data),
                   event.type == "process_traffic",
                   let processes = event.data.decoded([ProcessTrafficStat].self) {
                    Task { @MainActor in
                        guard self.isCurrentRealtimeStream("processes", generation: generation), self.accept(event) else { return }
                        self.topProcesses = processes
                    }
                }
                Task { @MainActor in
                    guard self.isCurrentRealtimeStream("processes", generation: generation) else { return }
                    self.receiveProcessesMessage(generation: generation)
                }
            case .failure:
                Task { @MainActor [weak self] in
                    guard let self, self.isCurrentRealtimeStream("processes", generation: generation) else { return }
                    self.scheduleReconnect(for: "processes") { [weak self] in
                        guard let self else { return }
                        await self.fetchTopProcesses()
                        self.startProcessesWebSocket()
                    }
                }
            }
        }
    }

    private func receiveLogsMessage(generation: UUID) {
        logsWsTask?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                if case .string(let text) = message,
                   let data = text.data(using: .utf8),
                   let event = try? JSONDecoder().decode(RealtimeEvent.self, from: data),
                   event.type == "log" {
                    Task { @MainActor in
                        guard self.isCurrentRealtimeStream("logs", generation: generation), self.accept(event) else { return }
                        var currentLogs = self.logs
                        if currentLogs.count >= 200 {
                            currentLogs.removeFirst()
                        }
                        let entry = LogEntry(
                            time: DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium),
                            level: "INFO",
                            message: event.data.decoded(LogEventPayload.self)?.displayMessage ?? "收到一条连接审计记录"
                        )
                        currentLogs.append(entry)
                        self.logs = currentLogs
                    }
                }
                Task { @MainActor in
                    guard self.isCurrentRealtimeStream("logs", generation: generation) else { return }
                    self.receiveLogsMessage(generation: generation)
                }
            case .failure:
                Task { @MainActor [weak self] in
                    guard let self, self.isCurrentRealtimeStream("logs", generation: generation) else { return }
                    self.scheduleReconnect(for: "logs") { [weak self] in
                        self?.startLogsWebSocket()
                    }
                }
            }
        }
    }

    private func accept(_ event: RealtimeEvent) -> Bool {
        let latest = latestRealtimeSequences[event.type] ?? 0
        guard event.sequence > latest else { return false }
        latestRealtimeSequences[event.type] = event.sequence
        return true
    }
}

private enum ConnectionMutation: Sendable {
    case snapshot(ConnectionsResponse)
    case delta(ConnectionsDelta)
}

private struct NodeDelayEvent: Codable { let tag: String; let delay: Int }
private struct NodeSpeedEvent: Codable { let tag: String; let bandwidthMbps: Double }
private struct LogEventPayload: Codable {
    let host: String
    let process: String
    let rule: String
    let outbound: String

    var displayMessage: String {
        let origin = process.isEmpty ? "未知进程" : process
        let destination = host.isEmpty ? "未知目标" : host
        let route = outbound.isEmpty ? rule : outbound
        return route.isEmpty ? "\(origin) → \(destination)" : "\(origin) → \(destination) · \(route)"
    }
}
