import SwiftUI
import Charts
import AppKit

public struct ActivityDashboardView: View {
    @ObservedObject var state = AsterState.shared
    @State private var showExternalIPPopover = false
    @State private var isDiagnosing = false
    @State private var connectionFilter: String = "all" // "all" | "proxy" | "direct"
    @State private var selectedConnection: ConnectionItem? = nil
    @State private var showRuleEvaluator: Bool = false
    @State private var showCloseAllAlert: Bool = false

    public init() {}

    public var body: some View {
        VStack(spacing: 12) {
            // 顶栏：沉稳专业页面标题 (无冗余侵入性横幅)
            activityHeaderView

            // Zone 1: 精炼全景指标舱 (HUD, 高度收敛至 ~76pt，释放 75%+ 垂直主空间)
            activityOverviewHUD
                .padding(.horizontal, DesignTokens.pagePadding)

            // Zone 2: 实时连接流主舞台 (全尺寸纵向平滑滚动，杜绝 8 行硬截断)
            liveConnectionsStreamSection
                .padding(.horizontal, DesignTokens.pagePadding)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onExitCommand {
            if selectedConnection != nil {
                withAnimation(.easeInOut(duration: 0.22)) {
                    selectedConnection = nil
                }
            }
        }
        .background {
            if selectedConnection != nil {
                Button("") {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        selectedConnection = nil
                    }
                }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
            }
        }
        .onAppear {
            Task {
                await state.fetchDiagnostics()
                await state.fetchTopProcesses()
            }
            state.fetchIPInfo()
        }
        .alert("断开全部活跃连接", isPresented: $showCloseAllAlert) {
            Button("取消", role: .cancel) {}
            Button("断开全部", role: .destructive) {
                state.closeAllConnections()
            }
        } message: {
            Text("确定要强制关闭当前所有正在进行的 TCP/UDP 活跃连接吗？此操作将立即释放全部出站套接字。")
        }
    }

    // A. 顶部状态栏
    private var activityHeaderView: some View {
        PageHeader(title: "活动") {
            Button(action: {
                InspectorWindowController.shared.show()
            }) {
                HStack(spacing: 5) {
                    Image(systemName: "macwindow.on.rectangle")
                    Text("独立日志窗口")
                }
            }
            .buttonStyle(.exquisiteSecondary(height: 28, cornerRadius: AsterMetrics.radiusControl))
            .help("在独立的悬浮窗口中打开网络请求日志审查")
        }
    }

    // B. 精炼全景指标舱 (Zone 1: 四列指标均匀对称分布，高度收敛)
    private var activityOverviewHUD: some View {
        HStack(spacing: 14) {
            // Col 1: 接入网络与出口模式
            hudNetworkCol

            Divider().opacity(0.25).frame(height: 48)

            // Col 2: 真实网络延迟 (真实物理测量，绝无假数据)
            hudLatencyCol

            Divider().opacity(0.25).frame(height: 48)

            // Col 3: 实时速率与吞吐
            hudThroughputCol

            Divider().opacity(0.25).frame(height: 48)

            // Col 4: 活跃连接监控大盘
            hudConnectionsCol
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .activityCardStyle()
    }

    // Col 1: 网络与当前生效模式
    private var hudNetworkCol: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                let netType = state.diagnostics.networkType.isEmpty ? "网络就绪" : state.diagnostics.networkType
                let iconName: String = {
                    if netType.contains("Wi-Fi") { return "wifi" }
                    if netType == "未连接网络" { return "wifi.slash" }
                    if netType == "蜂窝网络" { return "antenna.radiowaves.left.and.right" }
                    return "cable.connector"
                }()
                Image(systemName: iconName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(netType)
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text(currentModeBadge)
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(Capsule())
            }

            HStack(spacing: 6) {
                let activeName = (state.status.activeConfigName?.isEmpty == false) ? state.status.activeConfigName! : (!state.diagnostics.configName.isEmpty ? state.diagnostics.configName : "未激活配置")
                Text(activeName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 4)

                Button(action: { showExternalIPPopover.toggle() }) {
                    HStack(spacing: 3) {
                        Image(systemName: "globe")
                            .font(.system(size: 9.5))
                        Text(displayExternalIP)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showExternalIPPopover, arrowEdge: .bottom) {
                    DualIPDetailPopoverView()
                        .frame(width: 360, height: 260)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var currentModeBadge: String {
        switch state.status.mode {
        case "global": return "GLOBAL"
        case "direct": return "DIRECT"
        default: return "RULE"
        }
    }

    private var displayExternalIP: String {
        if state.status.mode == "direct" {
            let ip = state.dualIP.localIP.ip
            return (ip.isEmpty || ip == "检测中..." || ip == "检测失败" || ip == "---") ? "---" : ip
        }
        let proxyIP = state.dualIP.proxyIP.ip
        if !proxyIP.isEmpty && proxyIP != "检测中..." && proxyIP != "检测失败" && proxyIP != "待连接" && proxyIP != "---" {
            return proxyIP
        }
        let local = state.dualIP.localIP.ip
        if !local.isEmpty && local != "检测中..." && local != "检测失败" && local != "---" {
            return local
        }
        return "---"
    }

    // Col 2: 真实网络延迟
    private var hudLatencyCol: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("网络延迟")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()

                Button(action: {
                    isDiagnosing = true
                    Task {
                        await state.fetchDiagnostics(force: true)
                        try? await Task.sleep(for: .milliseconds(500))
                        isDiagnosing = false
                    }
                }) {
                    HStack(spacing: 3) {
                        if isDiagnosing {
                            ProgressView()
                                .controlSize(.mini)
                                .frame(width: 9, height: 9)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 9, weight: .medium))
                        }
                        Text(isDiagnosing ? "诊断中" : "测速")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(.rect(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .disabled(isDiagnosing)
            }

            let delay = state.diagnostics.internetDelayMs
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                if isDiagnosing {
                    Text("…")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                    Text("检测中")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                } else if delay <= 0 {
                    Text("--")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.6))
                    Text("未测速")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(delay)")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(LatencyFormatter.color(delayMs: delay))
                    Text("ms")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 6) {
                    detailDelayItem(label: "网关", ms: state.diagnostics.routeDelayMs)
                    detailDelayItem(label: "DNS", ms: state.diagnostics.dnsDelayMs)
                    if state.status.mode == "direct" {
                        Text("直连").font(.system(size: 9.5, weight: .medium)).foregroundStyle(.secondary)
                    } else {
                        detailDelayItem(label: "代理", ms: state.diagnostics.proxyDelayMs > 0 ? state.diagnostics.proxyDelayMs : state.status.delayMs)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detailDelayItem(label: String, ms: Int) -> some View {
        HStack(spacing: 2) {
            Text("\(label):")
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
            Text(ms > 0 ? "\(ms)" : "--")
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(ms > 0 ? LatencyFormatter.color(delayMs: ms) : Color.secondary)
        }
    }

    // Col 3: 实时下行与上行速率
    private var hudThroughputCol: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("实时速率")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("累计: \(Formatters.bytesString(state.downloadTotal + state.uploadTotal))")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary.opacity(0.8))
            }

            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(TrafficColors.down)
                    Text(Formatters.speedString(state.currentDownSpeed))
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(.primary)
                }

                HStack(spacing: 4) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(TrafficColors.up)
                    Text(Formatters.speedString(state.currentUpSpeed))
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(.primary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Col 4: 活跃连接监控大盘
    private var hudConnectionsCol: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("活跃连接")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Circle()
                    .fill(state.status.running ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 6.5, height: 6.5)
            }

            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text("\(state.status.running ? state.connections.count : 0)")
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundStyle(.primary)
                Text("并发")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Spacer()

                let proxyCount = state.connections.filter { $0.isProxy }.count
                let directCount = state.connections.filter { $0.isDirect }.count
                HStack(spacing: 6) {
                    Text("代理 \(proxyCount)")
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.accentColor)
                    Text("·").foregroundStyle(.secondary)
                    Text("直连 \(directCount)")
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // C. 工具条与过滤器组件
    private var connectionFilterPicker: some View {
        Picker("", selection: $connectionFilter) {
            Text("全部 (\(state.connections.count))").tag("all")
            let proxyCount = state.connections.filter { $0.isProxy }.count
            Text("代理 (\(proxyCount))").tag("proxy")
            let directCount = state.connections.filter { $0.isDirect }.count
            Text("直连 (\(directCount))").tag("direct")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var connectionSearchField: some View {
        ExquisiteSearchField(placeholder: "搜索应用 / 域名 / IP…", text: $state.activityFilterText)
    }

    // D. 实时网络连接流主舞台 (Zone 2: 占全屏 75%+ 垂直主空间，全尺寸纵向平滑滚动)
    private var liveConnectionsStreamSection: some View {
        let filteredList = filteredLiveConnections

        return VStack(alignment: .leading, spacing: 8) {
            // 工具条
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Label("实时连接", systemImage: "network")
                        .font(.system(size: 13, weight: .bold))
                    Text("\(filteredList.count)")
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Color.primary.opacity(0.08))
                        .clipShape(Capsule())
                }

                connectionFilterPicker
                    .frame(maxWidth: 240)

                connectionSearchField
                    .frame(maxWidth: 220)

                // 规则测试 切换按钮
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        showRuleEvaluator.toggle()
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.shield")
                            .font(.system(size: 11))
                        Text("规则测试")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4.5)
                    .background(showRuleEvaluator ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.06))
                    .foregroundColor(showRuleEvaluator ? .accentColor : .primary)
                    .clipShape(.rect(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(showRuleEvaluator ? Color.accentColor.opacity(0.35) : Color.clear, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .help("展开或收起分流规则即时仿真测试条")

                Spacer(minLength: 0)

                if filteredList.count > 0 {
                    Button(action: { showCloseAllAlert = true }) {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle")
                                .font(.system(size: 10))
                            Text("断开全部")
                                .font(.system(size: 10.5, weight: .medium))
                        }
                    }
                    .buttonStyle(.exquisiteDestructive(height: 24))
                }
            }

            // 规则即时仿真测试条
            if showRuleEvaluator {
                RuleEvaluatorBar()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            // 连接数据大表与抽屉联动
            if filteredList.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: state.status.running ? "waveform.path.ecg" : "network.slash")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary.opacity(0.4))
                    Text(state.status.running ? (state.activityFilterText.isEmpty ? "暂无活跃网络长连接 · 内核正在持续监听流量" : "无匹配的网络连接记录") : "代理内核未运行")
                        .font(.system(size: 12.5))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: AsterMetrics.radiusCard, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    NativeHairlineBorder(cornerRadius: AsterMetrics.radiusCard)
                )
            } else {
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 0) {
                        // 表头 (固定顶置)
                        HStack(spacing: 12) {
                            Text("应用 / 进程")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundColor(.secondary)
                                .frame(width: 120, alignment: .leading)

                            Text("目标地址")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundColor(.secondary)
                                .frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)

                            Text("命中分流规则")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundColor(.secondary)
                                .frame(width: 105, alignment: .leading)

                            Text("出站链路")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundColor(.secondary)
                                .frame(width: 95, alignment: .leading)

                            Text("累计流量")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundColor(.secondary)
                                .frame(width: 80, alignment: .trailing)

                            Text("状态")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundColor(.secondary)
                                .frame(width: 80, alignment: .trailing)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.primary.opacity(0.025))

                        Divider().opacity(0.2)

                        // 原生顺畅纵向滚动列表 (全尺寸充满剩余空间，零截断)
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(filteredList) { conn in
                                    LiveConnectionRow(
                                        conn: conn,
                                        isSelected: selectedConnection?.id == conn.id,
                                        onSelect: {
                                            withAnimation(.easeInOut(duration: 0.22)) {
                                                if selectedConnection?.id == conn.id {
                                                    selectedConnection = nil
                                                } else {
                                                    selectedConnection = conn
                                                }
                                            }
                                        }
                                    )
                                    if conn.id != filteredList.last?.id {
                                        Divider().opacity(0.18).padding(.leading, 14)
                                    }
                                }
                            }
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: AsterMetrics.radiusCard, style: .continuous)
                            .fill(.ultraThinMaterial)
                    )
                    .overlay(
                        NativeHairlineBorder(cornerRadius: AsterMetrics.radiusCard)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

                    if let selected = selectedConnection {
                        let activeConn = filteredList.first(where: { $0.id == selected.id }) ?? state.connections.first(where: { $0.id == selected.id }) ?? selected
                        ConnectionDetailDrawer(conn: activeConn, onClose: {
                            withAnimation(.easeInOut(duration: 0.22)) {
                                selectedConnection = nil
                            }
                        })
                        .frame(width: 320)
                        .frame(maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: AsterMetrics.radiusCard, style: .continuous))
                        .overlay(
                            NativeHairlineBorder(cornerRadius: AsterMetrics.radiusCard)
                        )
                        .shadow(color: Color.black.opacity(0.08), radius: 10, x: -2, y: 2)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var filteredLiveConnections: [ConnectionItem] {
        var list = state.connections
        if connectionFilter == "proxy" {
            list = list.filter { $0.isProxy }
        } else if connectionFilter == "direct" {
            list = list.filter { $0.isDirect }
        }
        if !state.activityFilterText.isEmpty {
            let kw = state.activityFilterText.lowercased()
            list = list.filter {
                $0.effectiveProcess.lowercased().contains(kw) ||
                ($0.metadata?.host ?? "").lowercased().contains(kw) ||
                ($0.metadata?.destinationIP ?? "").contains(kw) ||
                ($0.rule ?? "").lowercased().contains(kw)
            }
        }
        return list
    }
}

// MARK: - 实时长连接行组件 (克制配色、专业降噪排版)
public struct LiveConnectionRow: View {
    @ObservedObject private var state = AsterState.shared
    public var conn: ConnectionItem
    public var isSelected: Bool
    public var onSelect: () -> Void

    @State private var isHovered: Bool = false

    public init(
        conn: ConnectionItem,
        isSelected: Bool = false,
        onSelect: @escaping () -> Void = {}
    ) {
        self.conn = conn
        self.isSelected = isSelected
        self.onSelect = onSelect
    }

    public var body: some View {
        HStack(spacing: 12) {
            // 应用 / 进程
            HStack(spacing: 6) {
                AppIconView(processPath: conn.metadata?.processPath ?? "", processName: conn.effectiveProcess, size: 15)
                Text(conn.effectiveProcess)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }
            .frame(width: 115, alignment: .leading)

            // 目标地址 (Host:Port)
            HStack(spacing: 4) {
                let host = conn.metadata?.host ?? conn.metadata?.destinationIP ?? "未知目标"
                let port = conn.metadata?.destinationPort ?? ""
                Text(port.isEmpty ? host : "\(host):\(port)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.primary.opacity(0.9))
                    .lineLimit(1)
            }
            .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)

            // 命中分流规则 (克制单色微胶囊)
            HStack(spacing: 4) {
                let rawRule = conn.rule?.isEmpty == false ? conn.rule! : (conn.rulePayload?.isEmpty == false ? conn.rulePayload! : "FINAL")
                let cleanRule = rawRule.replacingOccurrences(of: "_", with: "-").uppercased()
                Text(cleanRule)
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(.rect(cornerRadius: 3.5))
                    .lineLimit(1)
            }
            .frame(width: 100, alignment: .leading)

            // 出站链路 / 节点
            HStack(spacing: 4) {
                let chain: String = {
                    if let last = conn.chains?.last, !last.isEmpty {
                        return last
                    }
                    let lowerRule = (conn.rule ?? "").lowercased()
                    if lowerRule == "direct" { return "DIRECT" }
                    if lowerRule == "reject" || lowerRule == "block" { return "REJECT" }
                    if !state.status.selectedLabel.isEmpty { return state.status.selectedLabel }
                    return "PROXY"
                }()
                ActionBadge(action: chain)
            }
            .frame(width: 95, alignment: .leading)

            // 累计流量 (等宽紧凑低调排版)
            HStack(spacing: 4) {
                Text(Formatters.bytesString(conn.download + conn.upload))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.primary.opacity(0.85))
            }
            .frame(width: 75, alignment: .trailing)

            // 状态诊断徽标
            HStack {
                ConnectionDiagnosticBadge(conn: conn)
            }
            .frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(
            isSelected
                ? Color.accentColor.opacity(0.12)
                : (isHovered ? Color.primary.opacity(0.04) : Color.clear)
        )
        .overlay(alignment: .leading) {
            if isSelected {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 3)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            let host = conn.metadata?.host ?? conn.metadata?.destinationIP ?? ""
            let target = conn.effectiveTarget
            Button("复制目标地址 (\(target))") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(target, forType: .string)
            }
            if !host.isEmpty {
                Divider()
                Button("为该目标添加规则… (弹窗)") {
                    AddRuleWindowController.shared.show(
                        context: AddRuleContext.forDomain(
                            host: host,
                            appName: conn.effectiveProcess,
                            appIcon: nil,
                            preferredAction: "DIRECT"
                        )
                    )
                }
                Divider()
                Button("添加直连规则 (DIRECT)") {
                    state.addRuleFromConnection(hostOrIP: host, action: "DIRECT", connectionId: conn.isClosed == true ? nil : conn.id)
                }
                Button("添加代理规则 (PROXY)") {
                    state.addRuleFromConnection(hostOrIP: host, action: "PROXY", connectionId: conn.isClosed == true ? nil : conn.id)
                }
                Button("添加拦截规则 (REJECT)") {
                    state.addRuleFromConnection(hostOrIP: host, action: "REJECT", connectionId: conn.isClosed == true ? nil : conn.id)
                }
            }
            if conn.isClosed != true {
                Divider()
                Button("断开此连接") {
                    state.closeConnection(conn.id)
                }
            }
        }
    }
}

// MARK: - 嵌入式规则即时仿真测试条
public struct RuleEvaluatorBar: View {
    @ObservedObject private var state = AsterState.shared
    @State private var targetInput: String = ""
    @State private var isEvaluating: Bool = false
    @State private var evalResult: RuleEvaluateResult? = nil
    @State private var errorMessage: String? = nil

    public init() {}

    public var body: some View {
        VStack(spacing: 8) {
            // 输入与操作栏
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.badge.magnifyingglass")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)

                    TextField("输入域名、IP 或 URL 进行分流规则仿真（如 v.qq.com 或 1.1.1.1）…", text: $targetInput)
                        .font(.system(size: 11))
                        .textFieldStyle(.plain)
                        .onSubmit {
                            performEvaluation()
                        }

                    if !targetInput.isEmpty {
                        Button(action: {
                            targetInput = ""
                            evalResult = nil
                            errorMessage = nil
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("清空输入")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4.5)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.85))
                .clipShape(.rect(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
                )

                Button(action: {
                    performEvaluation()
                }) {
                    HStack(spacing: 3.5) {
                        if isEvaluating {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "play.fill")
                                .font(.system(size: 8.5))
                        }
                        Text("测试")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .frame(minWidth: 50, minHeight: 22)
                }
                .buttonStyle(.exquisitePrimary)
                .disabled(targetInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isEvaluating)
            }

            // 结果微卡片或提示
            if let result = evalResult {
                resultMicroCard(result)
            } else if let error = errorMessage {
                errorNotice(error)
            }
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.45))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.8)
        )
    }

    @MainActor
    private func performEvaluation() {
        let trimmed = targetInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isEvaluating = true
        errorMessage = nil

        Task { @MainActor in
            do {
                let res = try await state.evaluateRule(target: trimmed)
                self.evalResult = res
                self.isEvaluating = false
            } catch {
                self.errorMessage = error.localizedDescription
                self.evalResult = nil
                self.isEvaluating = false
            }
        }
    }

    private func resultMicroCard(_ result: RuleEvaluateResult) -> some View {
        Group {
            if result.matched {
                HStack(spacing: 12) {
                    // 左侧：命中规则类型与 Payload
                    HStack(spacing: 6) {
                        Text(result.ruleType.isEmpty ? "RULE" : result.ruleType)
                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12))
                            .foregroundColor(.accentColor)
                            .clipShape(.rect(cornerRadius: 4))

                        Text(result.payload.isEmpty ? targetInput : result.payload)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    // 中间：出站策略
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary.opacity(0.7))
                        ActionBadge(action: result.outbound)
                    }

                    Spacer(minLength: 8)

                    // 右侧：落地节点与评估耗时
                    HStack(spacing: 8) {
                        if !result.selectedNode.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "server.rack")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                Text(result.selectedNode)
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(.primary.opacity(0.9))
                                    .lineLimit(1)
                            }
                        }

                        Text(String(format: "%.1fms", result.evaluationTimeMs))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.04))
                            .clipShape(.rect(cornerRadius: 3.5))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.03))
                .clipShape(.rect(cornerRadius: 6))
            } else {
                unhitNotice(result)
            }
        }
    }

    private func unhitNotice(_ result: RuleEvaluateResult) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 11.5))
                .foregroundColor(.secondary)
            Text("未命中任何显式规则 · 降级走默认出站策略：")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            ActionBadge(action: result.outbound.isEmpty ? "DIRECT" : result.outbound)
            if !result.selectedNode.isEmpty {
                Text("(\(result.selectedNode))")
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text(String(format: "%.1fms", result.evaluationTimeMs))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.03))
        .clipShape(.rect(cornerRadius: 6))
    }

    private func errorNotice(_ error: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundColor(.orange)
            Text("规则仿真异常: \(error)")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.08))
        .clipShape(.rect(cornerRadius: 6))
    }
}

private extension View {
    func activityCardStyle() -> some View {
        self.background(
            RoundedRectangle(cornerRadius: AsterMetrics.radiusCard, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            NativeHairlineBorder(cornerRadius: AsterMetrics.radiusCard)
        )
    }
}

// MARK: - 顶部内容高度自适应偏好键
private struct TopContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 340
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

