import SwiftUI
import Charts
import AppKit

public struct ActivityDashboardView: View {
    @ObservedObject var state = AsterState.shared
    @State private var showExternalIPPopover = false
    @State private var timelineFilter: String = "all" // "all" | "down" | "up"
    @State private var isDiagnosing = false
    @State private var connectionFilter: String = "all" // "all" | "proxy" | "direct"
    @State private var connectionSearchText: String = ""
    @State private var topContentHeight: CGFloat = 340

    public var body: some View {
        VStack(spacing: 0) {
            // PageHeader 钉住不滚 (移除顶栏冗余日志按钮)
            activityHeaderView

            GeometryReader { geo in
                VStack(spacing: 12) {
                    // PrimaryZone: 四列元数据横栏 + 核心便当网格
                    VStack(spacing: 12) {
                        fourColumnMetadataBar
                        bentoGridView
                    }
                    .background(
                        GeometryReader { topGeo in
                            Color.clear.preference(key: TopContentHeightKey.self, value: topGeo.size.height)
                        }
                    )

                    // SecondaryZone: 实时连接区域 (动态自适应填满剩余垂直高度，单屏尽览零滚动条)
                    let availableHeight = max(geo.size.height - topContentHeight - 16, 120)
                    liveConnectionsStreamSection(availableHeight: availableHeight)
                }
                .onPreferenceChange(TopContentHeightKey.self) { newH in
                    if newH > 50 && abs(topContentHeight - newH) > 1 {
                        topContentHeight = newH
                    }
                }
                .padding(.horizontal, DesignTokens.pagePadding)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .onAppear {
            Task {
                await state.fetchDiagnostics()
                await state.fetchTopProcesses()
            }
            state.fetchIPInfo()
        }
    }

    // A. 顶部状态栏。仅保留必要错误告警，去除顶栏多余日志按钮
    private var activityHeaderView: some View {
        PageHeader(title: "活动") {
            if state.status.tunFailed || !state.status.error.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                    Text(state.status.error.isEmpty ? "虚拟网卡启动异常" : state.status.error)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(.orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.orange.opacity(0.12))
                .clipShape(.rect(cornerRadius: 6))
            }
        }
    }

    // B. 四列关键网络元数据横栏（窄宽 2×2）
    private var fourColumnMetadataBar: some View {
        ViewThatFits(in: .horizontal) {
            metadataRow(columns: 4)
            metadataRow(columns: 2)
        }
    }

    private func metadataRow(columns: Int) -> some View {
        let items: [(String, AnyView)] = [
            ("网络", AnyView(
                HStack(spacing: 6) {
                    Image(systemName: state.diagnostics.networkType.contains("Wi-Fi") ? "wifi" : "cable.connector")
                        .font(.system(size: 13))
                    Text(state.diagnostics.networkType.isEmpty ? "以太网" : state.diagnostics.networkType)
                        .font(.system(size: 13, weight: .bold))
                        .lineLimit(1)
                }
            )),
            ("配置", AnyView(
                HStack(spacing: 6) {
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.blue)
                    Text(state.diagnostics.configName.isEmpty ? "默认配置" : state.diagnostics.configName)
                        .font(.system(size: 13, weight: .bold))
                        .lineLimit(1)
                }
            )),
            ("出站模式", AnyView(
                Text(currentModeDisplayName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.primary)
                    .accessibilityLabel("当前出站模式：\(currentModeDisplayName)")
            )),
            ("外部 IP", AnyView(
                Button(action: { showExternalIPPopover.toggle() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "globe.asia.australia.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.orange)
                        Text(displayExternalIP)
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showExternalIPPopover, arrowEdge: .bottom) {
                    DualIPDetailPopoverView()
                        .frame(width: 360, height: 260)
                }
            )),
        ]

        return Group {
            if columns == 4 {
                HStack(spacing: 0) {
                    ForEach(0..<4, id: \.self) { i in
                        if i > 0 { Divider().frame(height: 32).opacity(0.3) }
                        metaCell(title: items[i].0, content: items[i].1)
                    }
                }
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .activityCardStyle()
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        metaCell(title: items[0].0, content: items[0].1)
                        Divider().frame(height: 32).opacity(0.3)
                        metaCell(title: items[1].0, content: items[1].1)
                    }
                    Divider().opacity(0.2)
                    HStack(spacing: 0) {
                        metaCell(title: items[2].0, content: items[2].1)
                        Divider().frame(height: 32).opacity(0.3)
                        metaCell(title: items[3].0, content: items[3].1)
                    }
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .activityCardStyle()
            }
        }
    }

    private func metaCell(title: String, content: AnyView) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }

    private var currentModeDisplayName: String {
        switch state.status.mode {
        case "global": return "全局代理"
        case "direct": return "直接连接"
        default: return "智能规则"
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

    // C. Bento Grid — 按内容宽 3 / 2 / 1 列
    private var bentoGridView: some View {
        let cards: [AnyView] = [
            AnyView(bentoLatencyCard),
            AnyView(bentoUploadCard),
            AnyView(bentoDownloadCard),
            AnyView(bentoConnectionsCard),
            AnyView(bentoTimelineCard),
            AnyView(bentoPeriodUsageCard),
        ]
        return ViewThatFits(in: .horizontal) {
            bentoGrid(columns: 3, cards: cards)
            bentoGrid(columns: 2, cards: cards)
            bentoGrid(columns: 1, cards: cards)
        }
    }

    private func bentoGrid(columns: Int, cards: [AnyView]) -> some View {
        let grid = Array(repeating: GridItem(.flexible(), spacing: DesignTokens.cardGap), count: columns)
        return LazyVGrid(columns: grid, spacing: DesignTokens.cardGap) {
            ForEach(0..<cards.count, id: \.self) { i in
                cards[i]
                    .frame(maxWidth: .infinity)
                    .frame(height: DesignTokens.bentoCardHeight)
            }
        }
    }

    // 卡片 1: INTERNET 延时
    private var bentoLatencyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("网络延迟")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()

                Button(action: {
                    isDiagnosing = true
                    Task {
                        await state.fetchDiagnostics(force: true)
                        try? await Task.sleep(for: .milliseconds(800))
                        isDiagnosing = false
                    }
                }) {
                    HStack(spacing: 3) {
                        if isDiagnosing {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 9))
                        }
                        Text("网络诊断")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(.rect(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .disabled(isDiagnosing)
            }

            // 大字延时 (采用质感原白色阶，诊断时带有微光渐变扫描动效)
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                let delay = state.diagnostics.internetDelayMs
                if isDiagnosing {
                    Text(delay > 0 ? "\(delay)" : "…")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.primary.opacity(0.4), Color.primary, Color.primary.opacity(0.4)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .opacity(0.75)
                    Text("诊断中")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                } else if state.diagnostics.fetchedAt == 0 {
                    Text("--")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.5))
                    Text("检测中")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                } else {
                    Text(delay > 0 ? "\(delay)" : "≤ 1")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                    Text("ms")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .frame(height: 34)

            Divider().opacity(0.2)

            // 三级延时细分 (路由 | DNS | 代理，采用内敛钛灰与克制微语义点)
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("路由")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                    if state.diagnostics.fetchedAt == 0 {
                        Text("--")
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary.opacity(0.6))
                    } else {
                        Text("≤ \(max(state.diagnostics.routeDelayMs, 1)) ms")
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(.primary.opacity(0.85))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text("DNS")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                    if state.diagnostics.fetchedAt == 0 {
                        Text("--")
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary.opacity(0.6))
                    } else {
                        let dnsDelay = state.diagnostics.dnsDelayMs
                        Text(dnsDelay > 0 ? "\(dnsDelay) ms" : "正常")
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(.primary.opacity(0.85))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text("代理")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                    if state.status.mode == "direct" {
                        Text("不适用")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    } else if state.diagnostics.fetchedAt == 0 {
                        Text("--")
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary.opacity(0.6))
                    } else {
                        let proxyDelay = state.diagnostics.proxyDelayMs > 0 ? state.diagnostics.proxyDelayMs : state.status.delayMs
                        Text(proxyDelay > 0 ? "\(proxyDelay) ms" : "---")
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(proxyDelay > 0 ? Color.primary.opacity(0.85) : Color.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(13)
        .activityCardStyle()
    }

    // 卡片 2: 上传速率
    private var bentoUploadCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("上传速率")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                Image(systemName: "arrow.up")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
            }

            // 大数字 (使用主文本色，沉稳高级)
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(Formatters.speedString(state.currentUpSpeed))
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
                Spacer()
            }
            .frame(height: 34)

            Spacer()

            // 极简微示波线 (超薄精致 3pt)
            GeometryReader { geo in
                let ratio = min(max(CGFloat(state.currentUpSpeed) / 1048576.0, 0.04), 1.0)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.primary.opacity(0.06))
                        .frame(height: 3)

                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.primary.opacity(0.45))
                        .frame(width: max(geo.size.width * ratio, 6), height: 3)
                        .animation(.linear(duration: 0.3), value: ratio)
                }
            }
            .frame(height: 3)
        }
        .padding(13)
        .activityCardStyle()
    }

    // 卡片 3: 下载速率
    private var bentoDownloadCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("下载速率")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                Image(systemName: "arrow.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
            }

            // 大数字 (主文本色)
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(Formatters.speedString(state.currentDownSpeed))
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
                Spacer()
            }
            .frame(height: 34)

            Spacer()

            // 极简微示波线 (超薄精致 3pt)
            GeometryReader { geo in
                let ratio = min(max(CGFloat(state.currentDownSpeed) / 2097152.0, 0.04), 1.0)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.primary.opacity(0.06))
                        .frame(height: 3)

                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.primary.opacity(0.65))
                        .frame(width: max(geo.size.width * ratio, 6), height: 3)
                        .animation(.linear(duration: 0.3), value: ratio)
                }
            }
            .frame(height: 3)
        }
        .padding(13)
        .activityCardStyle()
    }

    // 卡片 4: 活动连接
    private var bentoConnectionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("活动连接")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                // 呼吸绿灯
                Circle()
                    .fill(state.status.running ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
            }

            // 大数字
            HStack(alignment: .lastTextBaseline, spacing: 5) {
                Text("\(state.status.running ? state.connections.count : 0)")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
                Text("并发")
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .frame(height: 34)

            Divider().opacity(0.2)

            // 真实协议与分流明细分布
            VStack(alignment: .leading, spacing: 3) {
                let tcpCount = state.connections.filter { ($0.metadata?.network ?? "tcp").lowercased() == "tcp" }.count
                let udpCount = state.connections.filter { ($0.metadata?.network ?? "").lowercased() == "udp" }.count
                let procCount = max(Set(state.connections.map { $0.effectiveProcess }).count, state.topProcesses.count)

                HStack(spacing: 4) {
                    Text("\(procCount)")
                        .font(.system(size: 10.5, weight: .bold))
                    Text("个应用")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text("·").foregroundColor(.secondary)
                    Text("\(tcpCount)")
                        .font(.system(size: 10.5, weight: .bold))
                    Text("TCP")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text("·").foregroundColor(.secondary)
                    Text("\(udpCount)")
                        .font(.system(size: 10.5, weight: .bold))
                    Text("UDP")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                let proxyCount = state.connections.filter { $0.isProxy }.count
                let directCount = state.connections.filter { $0.isDirect }.count
                Text("\(proxyCount) 代理分流 · \(directCount) 规则直连")
                    .font(.system(size: 9.5))
                    .foregroundColor(.secondary.opacity(0.8))
            }
        }
        .padding(13)
        .activityCardStyle()
    }

    // 卡片 5: 实时流量时序示波器 (克制单色微透明阶梯，专业沉稳)
    private var bentoTimelineCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("实时吞吐 (60s)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)

                Spacer()

                // 示波通道切换 (小巧精致)
                Picker("", selection: $timelineFilter) {
                    Text("双向").tag("all")
                    Text("下行").tag("down")
                    Text("上行").tag("up")
                }
                .pickerStyle(.segmented)
                .frame(width: 125)
            }

            // 60 秒真实流量波动柱状示波图 (专业级低噪透明柱)
            VStack(spacing: 5) {
                GeometryReader { geo in
                    let points = state.trafficHistory
                    let maxSpeed = max(points.map { max($0.downloadSpeed, $0.uploadSpeed) }.max() ?? 1024, 10240)
                    let barWidth = max((geo.size.width - CGFloat(max(points.count - 1, 0)) * 2) / CGFloat(max(points.count, 1)), 1.5)

                    HStack(alignment: .bottom, spacing: 2) {
                        ForEach(points) { pt in
                            let downRatio = min(max(CGFloat(pt.downloadSpeed) / CGFloat(maxSpeed), 0.03), 1.0)
                            let upRatio = min(max(CGFloat(pt.uploadSpeed) / CGFloat(maxSpeed), 0.03), 1.0)

                            VStack(spacing: 1) {
                                Spacer()
                                if timelineFilter == "all" || timelineFilter == "up" {
                                    RoundedRectangle(cornerRadius: 1)
                                        .fill(Color.primary.opacity(0.32))
                                        .frame(width: barWidth, height: geo.size.height * upRatio * (timelineFilter == "all" ? 0.45 : 0.95))
                                }
                                if timelineFilter == "all" || timelineFilter == "down" {
                                    RoundedRectangle(cornerRadius: 1)
                                        .fill(Color.primary.opacity(0.68))
                                        .frame(width: barWidth, height: geo.size.height * downRatio * (timelineFilter == "all" ? 0.55 : 0.95))
                                }
                            }
                        }
                    }
                }
                .frame(height: 48)

                // 底部时间标尺
                HStack {
                    Text("-60s").frame(maxWidth: .infinity, alignment: .leading)
                    Text("-30s").frame(maxWidth: .infinity, alignment: .center)
                    Text("实时").frame(maxWidth: .infinity, alignment: .trailing)
                }
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.8))
            }
        }
        .padding(13)
        .activityCardStyle()
    }

    // 卡片 6: 累计流量与上下行占比 (极简高质感)
    private var bentoPeriodUsageCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("当前会话累计流量")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: {
                    state.refreshAll()
                }) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 9.5))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("刷新会话统计")
            }

            // 大数字：真实总流量 (主文本色)
            let totalUsage = state.downloadTotal + state.uploadTotal
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(Formatters.bytesString(totalUsage))
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
                Spacer()
            }
            .frame(height: 34)

            Spacer()

            // 极细双色比例条 (3.5pt 高度，轻盈精致)
            VStack(alignment: .leading, spacing: 4) {
                GeometryReader { geo in
                    let total = max(state.downloadTotal + state.uploadTotal, 1)
                    let downW = totalUsage > 0 ? (CGFloat(state.downloadTotal) / CGFloat(total)) * (geo.size.width - 2) : geo.size.width * 0.5
                    let upW = totalUsage > 0 ? max(geo.size.width - downW - 2, 0) : geo.size.width * 0.5

                    HStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.primary.opacity(0.65))
                            .frame(width: max(downW, 2))
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.primary.opacity(0.25))
                            .frame(width: max(upW, 2))
                    }
                }
                .frame(height: 3.5)

                // 图例说明 (等宽小字体)
                HStack {
                    HStack(spacing: 3) {
                        Circle().fill(Color.primary.opacity(0.65)).frame(width: 4.5, height: 4.5)
                        Text("下行: \(Formatters.bytesString(state.downloadTotal))")
                            .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    HStack(spacing: 3) {
                        Circle().fill(Color.primary.opacity(0.25)).frame(width: 4.5, height: 4.5)
                        Text("上行: \(Formatters.bytesString(state.uploadTotal))")
                            .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(13)
        .activityCardStyle()
    }

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
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            TextField("搜索应用 / 域名 / IP...", text: $connectionSearchText)
                .font(.system(size: 11))
                .textFieldStyle(.plain)
            if !connectionSearchText.isEmpty {
                Button(action: { connectionSearchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除活动连接搜索")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4.5)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.8))
        .clipShape(.rect(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8))
    }

    // D. 实时网络连接流与活跃应用 (根据剩余可用高度自适应展示，杜绝全页纵向滚动条)
    private func liveConnectionsStreamSection(availableHeight: CGFloat) -> some View {
        let filteredList = filteredLiveConnections
        // 根据可用高度动态计算最多容纳的行数 (每行约 34pt，表头与底栏约 70pt，自适应 2~8 行)
        let maxDisplayRows = max(min(Int((availableHeight - 70) / 34), 8), 2)
        let displayList = Array(filteredList.prefix(maxDisplayRows))

        return VStack(alignment: .leading, spacing: 8) {
            // SecondaryZone 工具条
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Label("实时连接", systemImage: "network")
                        .font(.system(size: 13, weight: .bold))
                    let activeCount = state.connections.count
                    Text("\(activeCount)")
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Color.primary.opacity(0.08))
                        .clipShape(Capsule())
                }

                connectionFilterPicker
                    .frame(maxWidth: 220)

                connectionSearchField
                    .frame(maxWidth: 200)

                Spacer(minLength: 0)

                // 显式引导：完整日志入口 (与快捷键 ⌘D 呼应)
                Button(action: { InspectorWindowController.shared.show() }) {
                    HStack(spacing: 4) {
                        Text("完整网络日志")
                            .font(.system(size: 11, weight: .medium))
                        Text("⌘D")
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(.rect(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("打开独立网络请求日志与诊断窗口 (⌘D)")
            }

            // 连接数据卡片
            if filteredList.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: state.status.running ? "waveform.path.ecg" : "network.slash")
                        .font(.system(size: 24))
                        .foregroundColor(.secondary.opacity(0.4))
                    Text(state.status.running ? (connectionSearchText.isEmpty ? "暂无活跃网络长连接 · 内核正在持续监听流量" : "无匹配的网络连接记录") : "代理内核未运行")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 120)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.ultraThinMaterial)
                )
                .liquidGlassBorder(cornerRadius: 10)
            } else {
                VStack(spacing: 0) {
                    // 表头 (极简规范对齐)
                    HStack(spacing: 12) {
                        Text("应用 / 进程")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundColor(.secondary)
                            .frame(width: 130, alignment: .leading)

                        Text("目标地址")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundColor(.secondary)
                            .frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)

                        Text("命中分流规则")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundColor(.secondary)
                            .frame(width: 120, alignment: .leading)

                        Text("出站链路")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundColor(.secondary)
                            .frame(width: 110, alignment: .leading)

                        Text("累计流量")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundColor(.secondary)
                            .frame(width: 90, alignment: .trailing)

                        Text("状态")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundColor(.secondary)
                            .frame(width: 35, alignment: .center)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.primary.opacity(0.025))

                    Divider().opacity(0.2)

                    // 动态自适应行数
                    ForEach(displayList) { conn in
                        LiveConnectionRow(conn: conn)
                        if conn.id != displayList.last?.id {
                            Divider().opacity(0.18).padding(.leading, 14)
                        }
                    }

                    // 底部优雅说明条 (仅作状态流向指引，保留右上角唯一 ⌘D 入口)
                    Divider().opacity(0.2)
                    HStack {
                        Image(systemName: "info.circle")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.8))
                        Text("实时看板仅展示活跃连接 (前 \(displayList.count)/\(filteredList.count) 条) · 完整流向与历史审计请通过右上角 ⌘D 网络日志审查")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)

                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.015))
                }
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.ultraThinMaterial)
                )
                .liquidGlassBorder(cornerRadius: 10)
                .frame(maxWidth: .infinity, alignment: .leading)
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
        if !connectionSearchText.isEmpty {
            let kw = connectionSearchText.lowercased()
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
    @ObservedObject var state = AsterState.shared
    public var conn: ConnectionItem

    public var body: some View {
        HStack(spacing: 12) {
            // 应用 / 进程
            HStack(spacing: 6) {
                let icon = state.iconForProcess(path: conn.metadata?.processPath ?? "", name: conn.effectiveProcess, size: 15)
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 15, height: 15)
                Text(conn.effectiveProcess)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }
            .frame(width: 130, alignment: .leading)

            // 目标地址 (Host:Port)
            HStack(spacing: 4) {
                let host = conn.metadata?.host ?? conn.metadata?.destinationIP ?? "未知目标"
                let port = conn.metadata?.destinationPort ?? ""
                Text(port.isEmpty ? host : "\(host):\(port)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.primary.opacity(0.9))
                    .lineLimit(1)
            }
            .frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)

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
            .frame(width: 120, alignment: .leading)

            // 出站链路 / 节点
            HStack(spacing: 4) {
                let chain = conn.chains?.last ?? (conn.rule == "direct" ? "DIRECT" : "Proxy")
                ActionBadge(action: chain)
            }
            .frame(width: 110, alignment: .leading)

            // 累计流量 (等宽紧凑低调排版)
            HStack(spacing: 4) {
                Text(Formatters.bytesString(conn.download + conn.upload))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.primary.opacity(0.85))
            }
            .frame(width: 90, alignment: .trailing)

            // 活跃状态指示点 (5pt 微点)
            HStack {
                Circle()
                    .fill(conn.isClosed == true ? Color.secondary.opacity(0.35) : Color.green)
                    .frame(width: 5.5, height: 5.5)
            }
            .frame(width: 35, alignment: .center)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
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

private extension View {
    func activityCardStyle() -> some View {
        self.background(
            RoundedRectangle(cornerRadius: DesignTokens.cardRadius)
                .fill(.ultraThinMaterial)
        )
        .liquidGlassBorder(cornerRadius: DesignTokens.cardRadius)
        .shadow(color: Color.black.opacity(0.04), radius: 6, x: 0, y: 2)
    }
}

// MARK: - 顶部内容高度自适应偏好键
private struct TopContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 340
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

