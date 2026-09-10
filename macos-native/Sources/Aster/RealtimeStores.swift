import Combine
import Foundation

/// A value snapshot for the high-frequency connections stream. Keeping merge,
/// sorting, de-duplication and retention here makes the result deterministic
/// and lets it be tested without a network or a SwiftUI view tree.
public struct ConnectionSnapshot: Equatable, Sendable {
    public var connections: [ConnectionItem]
    public var recentRequests: [ConnectionItem]
    public var requestPool: [ConnectionItem]
    public var downloadTotal: Int64
    public var uploadTotal: Int64

    public init(
        connections: [ConnectionItem] = [],
        recentRequests: [ConnectionItem] = [],
        downloadTotal: Int64 = 0,
        uploadTotal: Int64 = 0
    ) {
        let sortedConnections = Self.sorted(connections)
        let sortedRecentRequests = Self.sorted(recentRequests)
        self.connections = sortedConnections
        self.recentRequests = sortedRecentRequests
        self.requestPool = Self.requestPool(active: sortedConnections, recent: sortedRecentRequests)
        self.downloadTotal = downloadTotal
        self.uploadTotal = uploadTotal
    }

    public func replacingActiveConnections(with response: ConnectionsResponse) -> Self {
        Self(
            connections: response.connections,
            recentRequests: Self.mergedRecentRequests(existing: recentRequests, active: response.connections),
            downloadTotal: response.downloadTotal,
            uploadTotal: response.uploadTotal
        )
    }

    public func applying(_ delta: ConnectionsDelta) -> Self {
        var activeByID = delta.snapshot == true
            ? [String: ConnectionItem]()
            : Dictionary(uniqueKeysWithValues: connections.map { ($0.id, $0) })
        for connection in delta.upserts {
            activeByID[connection.id] = connection
        }
        for id in delta.closed {
            activeByID.removeValue(forKey: id)
        }

        let active = Self.sorted(Array(activeByID.values))
        return Self(
            connections: active,
            recentRequests: Self.mergedRecentRequests(existing: recentRequests, active: active),
            downloadTotal: delta.downloadTotal,
            uploadTotal: delta.uploadTotal
        )
    }

    private static func mergedRecentRequests(existing: [ConnectionItem], active: [ConnectionItem]) -> [ConnectionItem] {
        var requestsByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        let activeIDs = Set(active.map(\.id))

        for var connection in active {
            connection.isClosed = false
            requestsByID[connection.id] = connection
        }
        for (id, var request) in requestsByID where !activeIDs.contains(id) {
            request.isClosed = true
            requestsByID[id] = request
        }
        return Array(sorted(Array(requestsByID.values)).prefix(300))
    }

    private static func requestPool(active: [ConnectionItem], recent: [ConnectionItem]) -> [ConnectionItem] {
        var pool = [ConnectionItem]()
        var activeIDs = Set<String>()
        pool.reserveCapacity(active.count + recent.count)

        for var connection in active {
            connection.isClosed = false
            pool.append(connection)
            activeIDs.insert(connection.id)
        }
        for var connection in recent where !activeIDs.contains(connection.id) {
            connection.isClosed = true
            pool.append(connection)
        }
        return pool
    }

    private static func sorted(_ connections: [ConnectionItem]) -> [ConnectionItem] {
        connections.sorted {
            let lhsStart = $0.start ?? ""
            let rhsStart = $1.start ?? ""
            return lhsStart == rhsStart ? $0.id < $1.id : lhsStart > rhsStart
        }
    }
}

/// Narrow ObservableObject consumed by the inspector. The legacy coordinator
/// remains available to existing AppKit and SwiftUI code while high-frequency
/// connection updates no longer invalidate pages that do not display them.
@MainActor
public final class ConnectionStore: ObservableObject {
    @Published public private(set) var snapshot = ConnectionSnapshot()
    @Published public private(set) var status = AppStatus.placeholder
    @Published public private(set) var currentUpSpeed: Int64 = 0
    @Published public private(set) var currentDownSpeed: Int64 = 0

    public var connections: [ConnectionItem] { snapshot.connections }
    public var recentRequests: [ConnectionItem] { snapshot.recentRequests }
    public var requestPool: [ConnectionItem] { snapshot.requestPool }
    public var downloadTotal: Int64 { snapshot.downloadTotal }
    public var uploadTotal: Int64 { snapshot.uploadTotal }

    func replace(snapshot: ConnectionSnapshot) {
        guard self.snapshot != snapshot else { return }
        self.snapshot = snapshot
    }

    func update(status: AppStatus) {
        guard self.status != status else { return }
        self.status = status
    }

    func updateTraffic(up: Int64, down: Int64) {
        guard currentUpSpeed != up || currentDownSpeed != down else { return }
        currentUpSpeed = up
        currentDownSpeed = down
    }
}

/// Low-frequency runtime state consumed by pages that need only the current
/// configuration mode. It deliberately excludes traffic samples.
@MainActor
public final class RuntimeStore: ObservableObject {
    @Published public private(set) var status = AppStatus.placeholder

    func update(status: AppStatus) {
        guard self.status != status else { return }
        self.status = status
    }
}

/// Rules have their own publication boundary so frequent traffic and
/// connection events cannot trigger rule mapping, filtering and sorting.
@MainActor
public final class RuleStore: ObservableObject {
    @Published public private(set) var rules: [RuleItem] = []

    func replace(rules: [RuleItem]) {
        guard self.rules != rules else { return }
        self.rules = rules
    }
}
