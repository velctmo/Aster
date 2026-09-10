#if DEBUG
import SwiftUI

@MainActor
enum PreviewFixtures {
    static func state() -> AsterState {
        let state = AsterState.previewState()
        var status = AppStatus.placeholder
        status.running = true
        status.mode = "rule"
        status.selectedLabel = "自动选择"
        status.activeConfigKind = "nodes"
        state.status = status
        state.rules = [
            RuleItem(id: "preview-domain", match: "domain_suffix", value: "example.com", action: "proxy", source: "USER", hits: 12),
            RuleItem(id: "preview-direct", match: "geoip", value: "cn", action: "direct", source: "USER", hits: 6),
        ]
        let connection = ConnectionItem(
            id: "preview-request",
            upload: 2_048,
            download: 8_192,
            start: "2026-09-10T12:00:00Z",
            chains: ["自动选择"],
            rule: "PROXY",
            rulePayload: "example.com",
            metadata: ConnectionMetadata(
                network: "tcp",
                type: "http",
                sourceIP: "127.0.0.1",
                destinationIP: "93.184.216.34",
                host: "example.com",
                process: "Safari",
                processPath: "/System/Applications/Safari.app",
                destinationPort: "443"
            )
        )
        state.connectionStore.replace(
            snapshot: ConnectionSnapshot(
                connections: [connection],
                downloadTotal: 8_192,
                uploadTotal: 2_048
            )
        )
        state.connectionStore.updateTraffic(up: 2_048, down: 8_192)
        return state
    }
}

#Preview("规则") {
    RulesView(state: PreviewFixtures.state())
        .frame(width: 900, height: 600)
}

#Preview("请求日志") {
    SurgeProLogsView(state: PreviewFixtures.state(), loadsRealtimeData: false)
        .frame(width: 1_160, height: 720)
}
#endif
