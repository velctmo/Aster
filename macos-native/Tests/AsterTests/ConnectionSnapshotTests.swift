import XCTest
@testable import Aster

final class ConnectionSnapshotTests: XCTestCase {
    private func connection(id: String, start: String, upload: Int64 = 0, download: Int64 = 0) -> ConnectionItem {
        ConnectionItem(id: id, upload: upload, download: download, start: start)
    }

    func testSnapshotKeepsClosedHistoryAndTrimsToThreeHundredRequests() {
        let previous = ConnectionSnapshot(
            recentRequests: (0..<301).map {
                connection(id: "closed-\($0)", start: String(format: "%04d", $0))
            }
        )
        let response = ConnectionsResponse(
            snapshotVersion: 2,
            downloadTotal: 20,
            uploadTotal: 10,
            connections: [connection(id: "active", start: "9999")]
        )

        let snapshot = previous.replacingActiveConnections(with: response)

        XCTAssertEqual(snapshot.connections.map(\.id), ["active"])
        XCTAssertEqual(snapshot.recentRequests.count, 300)
        XCTAssertEqual(snapshot.recentRequests.first?.id, "active")
        XCTAssertEqual(snapshot.recentRequests.first?.isClosed, false)
        XCTAssertEqual(snapshot.recentRequests.last?.id, "closed-2")
    }

    func testDeltaRemovesClosedConnectionAndKeepsStableOrdering() {
        let original = ConnectionSnapshot(
            connections: [
                connection(id: "b", start: "2026-01-01T00:00:00Z"),
                connection(id: "a", start: "2026-01-01T00:00:00Z"),
            ],
            recentRequests: [],
            downloadTotal: 1,
            uploadTotal: 2
        )
        let delta = ConnectionsDelta(
            downloadTotal: 30,
            uploadTotal: 40,
            snapshot: false,
            upserts: [connection(id: "c", start: "2026-01-01T00:00:01Z")],
            closed: ["b"]
        )

        let snapshot = original.applying(delta)

        XCTAssertEqual(snapshot.connections.map(\.id), ["c", "a"])
        XCTAssertEqual(snapshot.recentRequests.map(\.id), ["c", "a", "b"])
        XCTAssertEqual(snapshot.recentRequests.last?.isClosed, true)
        XCTAssertEqual(snapshot.downloadTotal, 30)
        XCTAssertEqual(snapshot.uploadTotal, 40)
    }

    func testSnapshotDeltaReplacesActiveSetWithoutDuplicatingHistory() {
        let original = ConnectionSnapshot(
            connections: [connection(id: "old", start: "1")],
            recentRequests: [connection(id: "old", start: "1")]
        )
        let delta = ConnectionsDelta(
            downloadTotal: 5,
            uploadTotal: 6,
            snapshot: true,
            upserts: [connection(id: "new", start: "2")],
            closed: []
        )

        let snapshot = original.applying(delta)

        XCTAssertEqual(snapshot.connections.map(\.id), ["new"])
        XCTAssertEqual(snapshot.recentRequests.map(\.id), ["new", "old"])
        XCTAssertEqual(snapshot.recentRequests[0].isClosed, false)
        XCTAssertEqual(snapshot.recentRequests[1].isClosed, true)
    }

}
