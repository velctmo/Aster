import Foundation

// MARK: - 1. 系统核心状态
public struct AppStatus: Codable, Equatable, Sendable {
    public var running: Bool
    public var pending: Bool
    public var sessionPhase: String?
    public var needAdmin: Bool
    public var tunFailed: Bool
    public var error: String
    public var mode: String
    public var capture: CaptureSettings
    public var selected: String
    public var selectedLabel: String
    public var delayMs: Int
    public var upload: Int64
    public var download: Int64
    public var coreVersion: String
    public var hasNodes: Bool
    public var recentNodes: [String]?
    public var mixedPort: Int?
    public var delayURL: String?
    public var apiVersion: String?
    public var activeConfigId: String?
    public var activeConfigName: String?
    public var activeConfigKind: String?
    public var featureRestriction: String?
    public var capabilities: AppCapabilities?
    public var lastSuccessfulConfigId: String?
    public var lastSuccessfulAt: Int64?

    public static let placeholder = AppStatus(
        running: false,
        pending: false,
        sessionPhase: "failed",
        needAdmin: false,
        tunFailed: false,
        error: "",
        mode: "rule",
        capture: CaptureSettings(systemProxy: false, tun: false),
        selected: "",
        selectedLabel: "节点选择",
        delayMs: 0,
        upload: 0,
        download: 0,
        coreVersion: "Sing-box 官方内核",
        hasNodes: false,
        recentNodes: [],
        mixedPort: 6780,
        delayURL: "https://www.gstatic.com/generate_204",
        apiVersion: "1",
        activeConfigId: nil,
        activeConfigName: nil,
        activeConfigKind: nil,
        featureRestriction: nil,
        capabilities: nil,
        lastSuccessfulConfigId: nil,
        lastSuccessfulAt: nil
    )
}

public struct Capability: Codable, Equatable, Hashable, Sendable {
    public var available: Bool
    public var reason: String?
}

public struct AppCapabilities: Codable, Equatable, Hashable, Sendable {
    public var systemProxy: Capability
    public var tun: Capability
    public var nodeControl: Capability
    public var ruleControl: Capability
    public var speedtest: Capability
}

public struct RealtimeEvent: Codable, Sendable {
    public var type: String
    public var data: JSONValue
    public var sequence: UInt64
    public var timestamp: Int64
}

public enum JSONValue: Codable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public func decoded<T: Decodable>(_ type: T.Type) -> T? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

public struct ConfigProfileItem: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var kind: String
    public var active: Bool
    public var sourceCount: Int
    public var nodeCount: Int
    public var updatedAt: Int64
    public var lastError: String
    public var capabilities: AppCapabilities?
    public var hasScript: Bool
    public var script: String?
    public var scriptId: String?
    public var recentRefreshes: [RefreshEventItem]?
    public var sources: [ConfigSourceSummary]?
    public var inboundSummary: ImportedInboundSummary?
}

public struct ScriptItem: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var kind: String
    public var content: String
    public var updatedAt: Int64

    public init(id: String, name: String, kind: String, content: String, updatedAt: Int64) {
        self.id = id
        self.name = name
        self.kind = kind
        self.content = content
        self.updatedAt = updatedAt
    }
}

public struct RefreshEventItem: Codable, Hashable, Sendable {
    public var at: Int64
    public var sourceId: String
    public var outcome: String
    public var nodeCount: Int
    public var reason: String?
}

public struct ImportedInboundSummary: Codable, Hashable, Sendable {
    public var mixedLoopback: String?
    public var hasTun: Bool
}

public struct ConfigSourceSummary: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var nodeCount: Int
    public var updatedAt: Int64
    public var lastError: String
}

public struct IPInfo: Codable, Equatable, Sendable {
    public var ip: String
    public var country: String
    public var city: String
    public var isp: String
    public var fetchedAt: Int64

    public static let placeholder = IPInfo(
        ip: "检测中...",
        country: "未知",
        city: "",
        isp: "",
        fetchedAt: 0
    )
}

public struct DualIPInfo: Codable, Equatable, Sendable {
    public var localIP: IPInfo
    public var proxyIP: IPInfo
    public var protected: Bool
    public var fetchedAt: Int64

    public static let placeholder = DualIPInfo(
        localIP: IPInfo(ip: "检测中...", country: "未知", city: "", isp: "", fetchedAt: 0),
        proxyIP: IPInfo(ip: "待连接", country: "直连模式", city: "", isp: "", fetchedAt: 0),
        protected: false,
        fetchedAt: 0
    )
}

public struct CaptureSettings: Codable, Equatable, Sendable {
    public var systemProxy: Bool
    public var tun: Bool

    public init(systemProxy: Bool, tun: Bool) {
        self.systemProxy = systemProxy
        self.tun = tun
    }
}

// MARK: - 2. 节点与策略组
public struct ProxyNode: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var tag: String
    public var name: String
    public var protocolName: String
    public var subId: String?
    public var subName: String?
    public var disabled: Bool
    public var delayMs: Int
    public var bandwidthMbps: Double?

    enum CodingKeys: String, CodingKey {
        case id, tag, name
        case protocolName = "protocol"
        case subId, subName, disabled, delayMs, bandwidthMbps
    }
}

public struct ProxyGroup: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var type: String // selector, urltest, fallback
    public var selectedNodeTag: String
    public var nodeTags: [String]
}

public struct StrategyGroup: Codable, Identifiable, Hashable, Sendable {
    public var tag: String
    public var name: String
    public var type: String
    public var now: String?
    public var members: [String]
    public var leafTags: [String]
    public var delayMs: Int?
    public var id: String { tag }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tag = try container.decode(String.self, forKey: .tag)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? tag
        type = try container.decode(String.self, forKey: .type)
        now = try container.decodeIfPresent(String.self, forKey: .now)
        members = try container.decodeIfPresent([String].self, forKey: .members) ?? []
        leafTags = try container.decodeIfPresent([String].self, forKey: .leafTags) ?? []
        delayMs = try container.decodeIfPresent(Int.self, forKey: .delayMs)
    }

    public init(tag: String, name: String, type: String, now: String? = nil, members: [String], leafTags: [String], delayMs: Int? = nil) {
        self.tag = tag
        self.name = name
        self.type = type
        self.now = now
        self.members = members
        self.leafTags = leafTags
        self.delayMs = delayMs
    }
}

// MARK: - 3. 分流规则模型
public struct RuleItem: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var match: String  // domain_suffix, domain_keyword, ip_cidr, geosite, geoip, etc.
    public var value: String
    public var action: String // direct, proxy, reject, or custom group
    public var source: String? // "USER", "SCRIPT", "SYSTEM"
    public var hits: Int?
}

// MARK: - 5. 活跃连接模型
public struct ConnectionItem: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var upload: Int64
    public var download: Int64
    public var start: String?
    public var chains: [String]?
    public var rule: String?
    public var rulePayload: String?
    public var metadata: ConnectionMetadata?
    public var isClosed: Bool?

    public init(
        id: String,
        upload: Int64 = 0,
        download: Int64 = 0,
        start: String? = nil,
        chains: [String]? = nil,
        rule: String? = nil,
        rulePayload: String? = nil,
        metadata: ConnectionMetadata? = nil,
        isClosed: Bool? = false
    ) {
        self.id = id
        self.upload = upload
        self.download = download
        self.start = start
        self.chains = chains
        self.rule = rule
        self.rulePayload = rulePayload
        self.metadata = metadata
        self.isClosed = isClosed
    }

    public var effectiveProcess: String {
        if let p = metadata?.process, !p.trimmingCharacters(in: .whitespaces).isEmpty {
            return p
        }
        if let path = metadata?.processPath, !path.isEmpty {
            let parts = path.split(separator: "/")
            if let last = parts.last {
                var s = String(last)
                if let parenIdx = s.firstIndex(of: "(") {
                    s = String(s[..<parenIdx]).trimmingCharacters(in: .whitespaces)
                }
                return s.replacingOccurrences(of: ".app", with: "")
            }
        }
        return "系统网络"
    }

    public var effectiveTarget: String {
        let h = metadata?.host ?? ""
        let ip = metadata?.destinationIP ?? ""
        let port = metadata?.destinationPort ?? ""
        let hostOrIP = !h.isEmpty ? h : (!ip.isEmpty ? ip : "未知目标")
        return port.isEmpty ? hostOrIP : "\(hostOrIP):\(port)"
    }

    public var isDirect: Bool {
        if let r = rule?.lowercased(), r == "direct" { return true }
        if let lastChain = chains?.last?.lowercased(), lastChain == "direct" { return true }
        if let chains = chains, chains.contains(where: { $0.lowercased() == "direct" }) { return true }
        return false
    }

    public var isReject: Bool {
        if let r = rule?.lowercased(), r == "reject" || r == "block" { return true }
        if let lastChain = chains?.last?.lowercased(), lastChain == "reject" || lastChain == "block" { return true }
        return false
    }

    public var isProxy: Bool {
        return !isDirect && !isReject
    }
}

public struct ConnectionMetadata: Codable, Equatable, Sendable {
    public var network: String?
    public var type: String?
    public var sourceIP: String?
    public var destinationIP: String?
    public var host: String?
    public var process: String?
    public var processPath: String?
    public var destinationPort: String?

    public init(
        network: String? = nil,
        type: String? = nil,
        sourceIP: String? = nil,
        destinationIP: String? = nil,
        host: String? = nil,
        process: String? = nil,
        processPath: String? = nil,
        destinationPort: String? = nil
    ) {
        self.network = network
        self.type = type
        self.sourceIP = sourceIP
        self.destinationIP = destinationIP
        self.host = host
        self.process = process
        self.processPath = processPath
        self.destinationPort = destinationPort
    }
}

public struct ConnectionsResponse: Codable, Sendable {
    public var snapshotVersion: UInt64?
    public var downloadTotal: Int64
    public var uploadTotal: Int64
    public var connections: [ConnectionItem]
}

public struct ConnectionsDelta: Codable, Sendable {
    public var downloadTotal: Int64
    public var uploadTotal: Int64
    public var snapshot: Bool?
    public var upserts: [ConnectionItem]
    public var closed: [String]
}

// MARK: - 6. 实时流量与日志
public struct TrafficSample: Codable, Sendable {
    public var up: Int64
    public var down: Int64
}

public struct TrafficHistoryPoint: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let timestamp: Date
    public let uploadSpeed: Double   // bytes/s
    public let downloadSpeed: Double // bytes/s
}

public struct LogEntry: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let time: String
    public let level: String
    public let message: String
}

// MARK: - 7. iCloud 云端备份状态
public struct ICloudStatusInfo: Codable, Equatable, Sendable {
    public var available: Bool
    public var hasBackup: Bool
    public var updatedAt: Int64

    public static let placeholder = ICloudStatusInfo(available: false, hasBackup: false, updatedAt: 0)
}

// MARK: - 8. 专业三级网络链路延时诊断模型
public struct NetworkDiagnostics: Codable, Equatable, Sendable {
    public var internetDelayMs: Int
    public var routeDelayMs: Int
    public var dnsDelayMs: Int
    public var proxyDelayMs: Int
    public var proxyApplicable: Bool
    public var networkType: String
    public var configName: String
    public var outboundMode: String
    public var fetchedAt: Int64

    public static let placeholder = NetworkDiagnostics(
        internetDelayMs: 0,
        routeDelayMs: 0,
        dnsDelayMs: 0,
        proxyDelayMs: 0,
        proxyApplicable: false,
        networkType: "网络就绪",
        configName: "默认配置",
        outboundMode: "直接连接",
        fetchedAt: 0
    )
}

// MARK: - 9. 进程与客户端实时吞吐速率模型
public struct ProcessTrafficStat: Codable, Identifiable, Equatable, Sendable {
    public var id: String { name }
    public var name: String
    public var processPath: String?
    public var upSpeed: Int64
    public var downSpeed: Int64
    public var connCount: Int
    public var totalBytes: Int64?

    public init(name: String, processPath: String? = nil, upSpeed: Int64 = 0, downSpeed: Int64 = 0, connCount: Int = 0, totalBytes: Int64? = nil) {
        self.name = name
        self.processPath = processPath
        self.upSpeed = upSpeed
        self.downSpeed = downSpeed
        self.connCount = connCount
        self.totalBytes = totalBytes
    }
}

// MARK: - 10. 系统通知分类
public enum NotificationType: String, Codable, Equatable, Sendable {
    case success
    case error
    case warning
    case info
}

// MARK: - 11. WebDAV 同步与云端配置
public struct WebDAVConfig: Codable, Equatable, Sendable {
    public var serverURL: String
    public var username: String
    public var password: String
    public var remotePath: String
    public var lastBackupAt: Int64

    public init(
        serverURL: String = "",
        username: String = "",
        password: String = "",
        remotePath: String = "/Aster",
        lastBackupAt: Int64 = 0
    ) {
        self.serverURL = serverURL
        self.username = username
        self.password = password
        self.remotePath = remotePath
        self.lastBackupAt = lastBackupAt
    }
}
