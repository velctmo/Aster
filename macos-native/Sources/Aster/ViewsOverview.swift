import SwiftUI
import Charts
import AppKit

public struct OverviewDashboardView: View {
    @ObservedObject var state = AsterState.shared
    @State private var showPortsSheet = false

    public var body: some View {
        let importedProfile = state.status.activeConfigKind == "subscription"
        VStack(spacing: 0) {
            // 顶栏：标题 + 出站模式 Segmented 控制器 + 快速重载
            PageHeader(title: "控制台") {
                HStack(spacing: 10) {
                    ModeSegmentedControl(selectedMode: Binding(
                        get: { state.status.mode },
                        set: { state.setMode($0) }
                    ))
                    .disabled(!(state.status.capabilities?.ruleControl.available ?? true))
                    .help(state.status.capabilities?.ruleControl.reason ?? "切换全局出站分流模式")

                    Button(action: {
                        state.restartCore()
                    }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.exquisiteSecondary(height: 24))
                    .help("重新启动 sing-box 代理内核")
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 1. 核心运行状态与当前出站
                    overviewSection(title: "运行中枢与核心状态") {
                        HeroCommandDeckView()
                    }

                    // 2. 实时网络吞吐与波形监控
                    overviewSection(title: "实时网络吞吐与流量监控") {
                        ThroughputMonitorCard()
                    }

                    // 3. 网络出口与公网 IP 拓扑
                    overviewSection(title: "外部出口与网络拓扑") {
                        DualIPCard()
                    }

                    // 4. 网络接管与局域网共享
                    overviewSection(title: "系统网络接管与局域网代理") {
                        VStack(spacing: 12) {
                            HStack(spacing: 12) {
                                // 卡片 1: 系统代理
                                OverviewModuleCard(
                                    icon: "globe",
                                    iconColor: .blue,
                                    title: "系统代理",
                                    statusText: state.status.capture.systemProxy
                                        ? (state.status.running
                                            ? "已配置 127.0.0.1:\(state.status.mixedPort ?? 6780)"
                                            : "等待核心启动")
                                        : "未设置",
                                    statusActive: state.status.capture.systemProxy && state.status.running,
                                    description: "在 macOS 系统网络偏好设置中挂载 HTTP 和 HTTPS 代理。大多数应用与浏览器会自动遵循此设置。",
                                    isOn: Binding(
                                        get: { state.status.capture.systemProxy },
                                        set: { state.setCapture(systemProxy: $0, tun: state.status.capture.tun) }
                                    ),
                                    isEnabled: state.status.running && (state.status.capabilities?.systemProxy.available ?? true)
                                )

                                // 卡片 2: 虚拟网卡 (TUN)
                                OverviewModuleCard(
                                    icon: "cpu.fill",
                                    iconColor: .green,
                                    title: "虚拟网卡",
                                    statusText: {
                                        if !(state.status.capabilities?.tun.available ?? true) {
                                            return state.status.capabilities?.tun.reason ?? "请安装 Aster 网络组件"
                                        }
                                        if state.status.capture.tun {
                                            if state.status.running { return "运行中 (系统级接管)" }
                                            if state.status.needAdmin { return "需要安装网络组件" }
                                            return "等待核心启动"
                                        }
                                        return "已禁用"
                                    }(),
                                    statusActive: state.status.capture.tun && state.status.running,
                                    description: state.status.capabilities?.tun.reason ?? "创建独立虚拟网卡，全量接管 TCP/UDP 流量，游戏与终端免配全代理，无需应用主动适配。",
                                    isOn: Binding(
                                        get: { state.status.capture.tun },
                                        set: { state.setCapture(systemProxy: state.status.capture.systemProxy, tun: $0) }
                                    ),
                                    isEnabled: state.status.capabilities?.tun.available ?? true
                                )
                            }

                            // 卡片 3: 局域网代理共享
                            OverviewModuleCard(
                                icon: "network",
                                iconColor: .indigo,
                                title: "局域网代理共享",
                                statusText: importedProfile ? "由完整配置管理" : (state.allowLan ? (state.localLANIP == "127.0.0.1" ? "已开启 (未检测到局域网 IP)" : "已监听在 \(state.localLANIP):\(state.status.mixedPort ?? 6780)") : "局域网共享已关闭"),
                                statusActive: !importedProfile && state.allowLan,
                                description: importedProfile
                                    ? "完整订阅的入站监听由配置作者管理，Aster 不会改写局域网共享设置。"
                                    : "允许局域网内的其它设备（如手机、平板、电视或同网络电脑）通过本机的 IP 与端口代理上网。",
                                isOn: Binding(
                                    get: { state.allowLan },
                                    set: { state.patchSettings(body: ["allowLan": $0]) }
                                ),
                                isEnabled: !importedProfile,
                                actionMenu: {
                                    Button(action: { showPortsSheet.toggle() }) {
                                        Image(systemName: "ellipsis.circle")
                                            .font(.system(size: 14))
                                            .foregroundColor(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("局域网代理端口设置")
                                    .popover(isPresented: $showPortsSheet) {
                                        PortsDetailPopoverView(port: state.status.mixedPort ?? 6780)
                                    }
                                }
                            )
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .padding(.horizontal, DesignTokens.pagePadding)
                .padding(.bottom, DesignTokens.pagePadding)
            }
        }
        .onAppear {
            Task {
                await state.fetchSettings()
                state.fetchIPInfo()
            }
        }
    }

    @ViewBuilder
    private func overviewSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 4)
            content()
        }
    }
}

// MARK: - 英雄中枢命令甲板 (Hero Command Deck)
public struct HeroCommandDeckView: View {
    @ObservedObject var state = AsterState.shared
    @State private var isClearingProxy: Bool = false
    @State private var clearProxyDone: Bool = false

    public init() {}

    private var activeProfileName: String {
        state.status.activeConfigName ?? "Default"
    }

    private var statusTitle: String {
        if state.status.running {
            return "RUNNING"
        } else if state.status.pending {
            return "STARTING"
        } else if state.status.sessionPhase == "failed" {
            return "FAILED"
        } else if state.status.sessionPhase == "networkComponentRequired" {
            return "SETUP REQUIRED"
        } else {
            return "STANDBY"
        }
    }

    private var statusSubtitle: String {
        if state.status.running {
            return "核心引擎已接管系统流量 · 实时分流中"
        } else if state.status.pending {
            return "正在载入核心引擎与路由策略…"
        } else if state.status.sessionPhase == "failed" {
            return state.status.error.isEmpty ? "核心异常退出，请检查配置或脚本" : state.status.error
        } else if state.status.sessionPhase == "networkComponentRequired" {
            return "增强接管需要安装并授权系统网络组件"
        } else {
            return "核心引擎待命中 · 随时准备接管网络流量"
        }
    }

    private var statusColor: Color {
        if state.status.running {
            return Color(red: 0.20, green: 0.78, blue: 0.45) // 翡翠微光绿
        } else if state.status.pending {
            return .orange
        } else if state.status.sessionPhase == "failed" {
            return Color(red: 0.88, green: 0.35, blue: 0.35)
        } else {
            return .secondary
        }
    }

    public var body: some View {
        VStack(spacing: 16) {
            // 甲板上层：状态信标 + 核心大字 + 快捷操作
            HStack(alignment: .center, spacing: 14) {
                // 左侧信标与引擎标题
                StatusBeaconDot(active: state.status.running, color: statusColor, size: 8)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(statusTitle)
                            .font(.system(size: 18, weight: .black, design: .rounded))
                            .tracking(1.0)
                            .foregroundColor(state.status.running ? .primary : .secondary)

                        // 配置文件胶囊
                        HStack(spacing: 4) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 9, weight: .semibold))
                            Text(activeProfileName)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Color.accentColor.opacity(0.10))
                        .foregroundColor(Color.accentColor)
                        .clipShape(Capsule())
                        .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 0.6))
                    }

                    Text(statusSubtitle)
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                // 右侧快捷操作：重试 / 重启内核 / 节点入口
                HStack(spacing: 8) {
                    if state.status.sessionPhase == "failed" || state.status.sessionPhase == "networkComponentRequired" {
                        Button(action: { state.restartCore() }) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.counterclockwise")
                                Text("重试启动")
                            }
                        }
                        .buttonStyle(.exquisitePrimary)
                    } else {
                        Button(action: { state.restartCore() }) {
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 10, weight: .bold))
                                Text("重载内核")
                                    .font(.system(size: 11.5, weight: .medium))
                            }
                        }
                        .buttonStyle(.exquisiteSecondary(height: 28))
                        .help("重新启动 sing-box 内核并平滑重载配置")

                        Button(action: {
                            isClearingProxy = true
                            Task {
                                try? await state.clearSystemProxyResidue()
                                clearProxyDone = true
                                try? await Task.sleep(for: .seconds(2))
                                clearProxyDone = false
                                isClearingProxy = false
                            }
                        }) {
                            HStack(spacing: 4) {
                                if isClearingProxy {
                                    ProgressView().controlSize(.mini).frame(width: 10, height: 10)
                                } else {
                                    Image(systemName: clearProxyDone ? "checkmark" : "shield.slash")
                                        .font(.system(size: 10))
                                }
                                Text(clearProxyDone ? "已清理" : "清理代理")
                                    .font(.system(size: 11.5, weight: .medium))
                            }
                        }
                        .buttonStyle(.exquisiteSecondary(height: 28))
                        .help("一键清除 macOS 系统网络中遗留的 HTTP/HTTPS 代理设置")

                        Button(action: { state.selectedTab = .nodes }) {
                            HStack(spacing: 5) {
                                Image(systemName: "square.stack.3d.up")
                                    .font(.system(size: 11))
                                Text("选择出站")
                                    .font(.system(size: 11.5, weight: .medium))
                            }
                        }
                        .buttonStyle(.exquisiteSecondary(height: 28))
                        .help("进入出站策略组与节点视图")
                    }
                }
            }

            // 分割微光线
            Divider().opacity(0.2)

            // 甲板下层：当前活动出口节点与网络遥测信息
            HStack(spacing: 16) {
                // 出口网关信息
                HStack(spacing: 10) {
                    Image(systemName: "network")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(TrafficColors.down)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("当前活动出口")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)

                        HStack(spacing: 6) {
                            Text(NodeNameSanitizer.clean(state.status.selectedLabel))
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.primary)
                                .lineLimit(1)

                            if let node = state.findNode(for: state.status.selected) {
                                Text(node.protocolName.uppercased())
                                    .font(.system(size: 8.5, weight: .black, design: .monospaced))
                                    .padding(.horizontal, 4.5)
                                    .padding(.vertical, 1.5)
                                    .background(Color.secondary.opacity(0.12))
                                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }

                Spacer(minLength: 8)

                // 实时延迟与辅助状态
                HStack(spacing: 12) {
                    if state.status.delayMs > 0 {
                        HStack(spacing: 5) {
                            Text("RTT")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(.secondary)
                            LatencyBadge(delayMs: state.status.delayMs, isTesting: state.isTestingDelays)
                        }
                    }

                    if let lastSync = state.status.lastSuccessfulAt, lastSync > 0 {
                        let date = Date(timeIntervalSince1970: TimeInterval(lastSync))
                        Text("活跃于 \(date.formatted(date: .omitted, time: .shortened))")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                }
            }
        }
        .asterCard(cornerRadius: AsterMetrics.radiusCard, padding: 16)
    }
}

// MARK: - 实时吞吐量波形监控卡片
public struct ThroughputMonitorCard: View {
    @ObservedObject var state = AsterState.shared

    public init() {}

    public var body: some View {
        VStack(spacing: 12) {
            // 上半部分：上下行瞬时速率 + 累计流量
            HStack(spacing: 20) {
                // 下行速率
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(TrafficColors.down.opacity(0.14))
                            .frame(width: 32, height: 32)
                        Image(systemName: "arrow.down")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(TrafficColors.down)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("下行速率")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                        Text(Formatters.speedString(state.currentDownSpeed))
                            .font(.system(size: 18, weight: .bold, design: .monospaced))
                            .foregroundColor(.primary)
                            .monospacedDigit()
                    }
                }

                // 上行速率
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(TrafficColors.up.opacity(0.14))
                            .frame(width: 32, height: 32)
                        Image(systemName: "arrow.up")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(TrafficColors.up)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("上行速率")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                        Text(Formatters.speedString(state.currentUpSpeed))
                            .font(.system(size: 18, weight: .bold, design: .monospaced))
                            .foregroundColor(.primary)
                            .monospacedDigit()
                    }
                }

                Spacer()

                // 会话累计统计
                VStack(alignment: .trailing, spacing: 3) {
                    HStack(spacing: 4) {
                        Text("下行累计:")
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                        Text(Formatters.bytesString(state.downloadTotal))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.primary.opacity(0.85))
                            .monospacedDigit()
                    }
                    HStack(spacing: 4) {
                        Text("上行累计:")
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                        Text(Formatters.bytesString(state.uploadTotal))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.primary.opacity(0.85))
                            .monospacedDigit()
                    }
                }
            }

            // 下半部分：平滑实时波形折线图
            realtimeChart
                .frame(height: 72)
        }
        .asterCard(cornerRadius: AsterMetrics.radiusCard, padding: 14)
    }

    @ViewBuilder
    private var realtimeChart: some View {
        let history = state.trafficHistory.suffix(30)
        if #available(macOS 13.0, *), history.count >= 2 {
            Chart {
                ForEach(Array(history)) { pt in
                    AreaMark(
                        x: .value("时间", pt.timestamp),
                        y: .value("下行", pt.downloadSpeed)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [TrafficColors.down.opacity(0.25), Color.clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)

                    LineMark(
                        x: .value("时间", pt.timestamp),
                        y: .value("下行", pt.downloadSpeed)
                    )
                    .foregroundStyle(TrafficColors.down)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.catmullRom)

                    AreaMark(
                        x: .value("时间", pt.timestamp),
                        y: .value("上行", pt.uploadSpeed)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [TrafficColors.up.opacity(0.20), Color.clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)

                    LineMark(
                        x: .value("时间", pt.timestamp),
                        y: .value("上行", pt.uploadSpeed)
                    )
                    .foregroundStyle(TrafficColors.up)
                    .lineStyle(StrokeStyle(lineWidth: 1.2))
                    .interpolationMethod(.catmullRom)
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.02))
                HStack(spacing: 4) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text("实时网络吞吐监听已就绪")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

// 概览卡片统一组件
public struct OverviewModuleCard<ActionContent: View>: View {
    public var icon: String
    public var iconColor: Color
    public var title: String
    public var statusText: String
    public var statusActive: Bool
    public var description: String
    public var isOn: Binding<Bool>?
    public var isEnabled: Bool
    public var actionMenu: (() -> ActionContent)?
    public var customAction: (() -> ActionContent)?

    public init(
        icon: String,
        iconColor: Color,
        title: String,
        statusText: String,
        statusActive: Bool,
        description: String,
        isOn: Binding<Bool>? = nil,
        isEnabled: Bool = true,
        actionMenu: (() -> ActionContent)? = nil,
        customAction: (() -> ActionContent)? = nil
    ) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self.statusText = statusText
        self.statusActive = statusActive
        self.description = description
        self.isOn = isOn
        self.isEnabled = isEnabled
        self.actionMenu = actionMenu
        self.customAction = customAction
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // 左侧大圆标
            ZStack {
                Circle()
                    .fill(iconColor.opacity(0.14))
                    .frame(width: 44, height: 44)
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(iconColor)
            }

            // 中间信息
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 15, weight: .bold))
                    HStack(spacing: 4) {
                        Circle()
                            .fill(statusActive ? Color.green : Color.secondary.opacity(0.4))
                            .frame(width: 6.5, height: 6.5)
                        Text(statusText)
                            .font(.system(size: 11, weight: statusActive ? .semibold : .regular))
                            .foregroundColor(statusActive ? .primary : .secondary)
                    }
                }

                Text(description)
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            // 右侧操作
            HStack(spacing: 10) {
                if let toggleBinding = isOn {
                    Toggle("", isOn: toggleBinding)
                        .toggleStyle(SwitchToggleStyle())
                        .labelsHidden()
                        .disabled(!isEnabled)
                }

                if let menu = actionMenu {
                    menu()
                }

                if let custom = customAction {
                    custom()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .asterCard(cornerRadius: AsterMetrics.radiusCard, padding: 16)
    }
}

extension OverviewModuleCard where ActionContent == EmptyView {
    public init(
        icon: String,
        iconColor: Color,
        title: String,
        statusText: String,
        statusActive: Bool,
        description: String,
        isOn: Binding<Bool>? = nil,
        isEnabled: Bool = true
    ) {
        self.init(
            icon: icon,
            iconColor: iconColor,
            title: title,
            statusText: statusText,
            statusActive: statusActive,
            description: description,
            isOn: isOn,
            isEnabled: isEnabled,
            actionMenu: nil,
            customAction: nil
        )
    }
}

// MARK: - 嵌入式双 IP 详情 Popover
public struct DualIPDetailPopoverView: View {
    @ObservedObject var state = AsterState.shared
    @State private var copiedLocal = false
    @State private var copiedProxy = false

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("外部出口 IP 拓扑")
                    .font(.system(size: 13, weight: .bold))
                Spacer()
                Button(action: { state.fetchIPInfo(force: true) }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                        .rotationEffect(.degrees(state.isFetchingIP ? 360 : 0))
                }
                .buttonStyle(.plain)
				.accessibilityLabel("重新检测外部 IP")
                .help("强制重新检测公网与代理 IP")
            }

            Divider().opacity(0.3)

            // 本机真实 IP
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("本机公网 IP (直连)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(action: {
                        let ip = state.dualIP.localIP.ip
                        guard !ip.isEmpty && ip != "检测中..." && ip != "检测中…" && ip != "检测失败" && ip != "127.0.0.1" else { return }
                        ClipboardHelper.copy(ip)
                        copiedLocal = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedLocal = false }
                    }) {
                        Text(copiedLocal ? "已复制" : "复制")
                            .font(.system(size: 10.5))
                            .foregroundColor(copiedLocal ? .green : .blue)
                    }
                    .buttonStyle(.plain)
                }
                let localIP = (state.dualIP.localIP.ip.isEmpty || state.dualIP.localIP.ip == "127.0.0.1") ? "检测中…" : state.dualIP.localIP.ip
                Text(localIP)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                Text([state.dualIP.localIP.country, state.dualIP.localIP.city, state.dualIP.localIP.isp].filter { !$0.isEmpty && $0 != "未知" }.joined(separator: " · "))
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
            }
            .padding(10)
            .background(Color.primary.opacity(0.04))
            .cornerRadius(8)

            // 代理出口 IP
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("代理出口 IP")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.blue)
                    Spacer()
                    Button(action: {
                        let ip = state.dualIP.proxyIP.ip
                        guard !ip.isEmpty && ip != "检测中..." && ip != "检测中…" && ip != "检测失败" && ip != "待连接" else { return }
                        ClipboardHelper.copy(ip)
                        copiedProxy = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedProxy = false }
                    }) {
                        Text(copiedProxy ? "已复制" : "复制")
                            .font(.system(size: 10.5))
                            .foregroundColor(copiedProxy ? .green : .blue)
                    }
                    .buttonStyle(.plain)
                }
                let proxyIP = (state.dualIP.proxyIP.ip.isEmpty || state.dualIP.proxyIP.ip == "检测失败" || state.dualIP.proxyIP.ip == "待连接") ? "---" : state.dualIP.proxyIP.ip
                Text(proxyIP)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                Text([state.dualIP.proxyIP.country, state.dualIP.proxyIP.city, state.dualIP.proxyIP.isp].filter { !$0.isEmpty && $0 != "未知" && $0 != "检测失败" }.joined(separator: " · "))
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
            }
            .padding(10)
            .background(Color.blue.opacity(0.06))
            .cornerRadius(8)
        }
        .padding(14)
    }
}


// MARK: - 2. 本机真实 IP vs 代理出口 IP 双列对比卡片
public struct DualIPCard: View {
    @ObservedObject var state = AsterState.shared
    @State private var copiedLocal = false
    @State private var copiedProxy = false

    public var body: some View {
        HStack(spacing: 14) {
            // A. 本机真实公网 IP 卡片 (左列)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    HStack(spacing: 6) {
                        Image(systemName: "house.fill")
                            .foregroundColor(.orange)
                            .font(.system(size: 12))
                        Text("本机公网 IP (直连)")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    Spacer()

                    Button(action: {
                        let ip = state.dualIP.localIP.ip
                        guard !ip.isEmpty && ip != "检测中..." && ip != "检测失败" else { return }
                        ClipboardHelper.copy(ip)
                        copiedLocal = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedLocal = false }
                    }) {
                        Image(systemName: copiedLocal ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundColor(copiedLocal ? .green : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("复制本机 IP 地址")
                }

                VStack(alignment: .leading, spacing: 3) {
                    let localIPText = (state.dualIP.localIP.ip.isEmpty || state.dualIP.localIP.ip == "127.0.0.1") ? "检测中…" : state.dualIP.localIP.ip
                    Text(localIPText)
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                        .foregroundColor(localIPText == "检测中…" ? .secondary : .primary)
                        .lineLimit(1)

                    let location = [state.dualIP.localIP.country, state.dualIP.localIP.city].filter { !$0.isEmpty && $0 != "未知" }.joined(separator: " ")
                    let isp = state.dualIP.localIP.isp
                    HStack(spacing: 4) {
                        Text(location.isEmpty ? "局域网 / 检测中" : location)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        if !isp.isEmpty {
                            Text("(\(isp))")
                                .font(.system(size: 10.5))
                                .foregroundColor(.secondary.opacity(0.8))
                                .lineLimit(1)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .asterCard(cornerRadius: AsterMetrics.radiusCard, padding: 14)

            // B. 代理出口落地 IP 卡片 (右列)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    HStack(spacing: 6) {
                        Image(systemName: "globe.desk.fill")
                            .foregroundColor(.blue)
                            .font(.system(size: 12))
                        Text("代理出口 IP (落地)")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    Spacer()

                    // 安全保护状态指示
                    if state.dualIP.protected {
                        HStack(spacing: 3) {
                            Image(systemName: "shield.lefthalf.filled.badge.checkmark")
                            Text("已受保护")
                        }
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.12))
                        .clipShape(Capsule())
                    }

                    // 刷新按钮
                    Button(action: {
                        state.fetchIPInfo(force: true)
                    }) {
                        if state.isFetchingIP {
                            ProgressView().controlSize(.mini).frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("即时刷新双 IP 与归属地")

                    // 复制按钮
                    Button(action: {
                        let ip = state.dualIP.proxyIP.ip
                        guard !ip.isEmpty && ip != "---" && ip != "待连接" && ip != "检测失败" else { return }
                        ClipboardHelper.copy(ip)
                        copiedProxy = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedProxy = false }
                    }) {
                        Image(systemName: copiedProxy ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundColor(copiedProxy ? .green : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("复制代理出口 IP 地址")
                }

                VStack(alignment: .leading, spacing: 3) {
                    let displayIP = (state.dualIP.proxyIP.ip.isEmpty || state.dualIP.proxyIP.ip == "检测失败" || state.dualIP.proxyIP.ip == "待连接") ? "---" : state.dualIP.proxyIP.ip
                    Text(displayIP)
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                        .foregroundColor(displayIP == "---" ? .secondary : .primary)
                        .lineLimit(1)

                    let location = [state.dualIP.proxyIP.country, state.dualIP.proxyIP.city].filter { !$0.isEmpty && $0 != "未知" && $0 != "检测失败" }.joined(separator: " ")
                    let defaultProxyLocation = !state.status.running ? "核心未启动" : (state.status.mode == "direct" ? "直连模式 (不经代理)" : "检测中…")
                    HStack(spacing: 4) {
                        Text(location.isEmpty ? defaultProxyLocation : location)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        if !state.dualIP.proxyIP.isp.isEmpty {
                            Text("(\(state.dualIP.proxyIP.isp))")
                                .font(.system(size: 10.5))
                                .foregroundColor(.secondary.opacity(0.8))
                                .lineLimit(1)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .asterCard(cornerRadius: AsterMetrics.radiusCard, padding: 14)
        }
    }
}

// MARK: - 3. 代理端口详情原生 Popover 弹层
public struct PortsDetailPopoverView: View {
    let port: Int
    @State private var copiedHttp = false
    @State private var copiedSocks = false
    @State private var copiedEnv = false

    private var envCommand: String {
        "export http_proxy=http://127.0.0.1:\(port) https_proxy=http://127.0.0.1:\(port) all_proxy=socks5://127.0.0.1:\(port)"
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "network.badge.shield.half.filled")
                    .foregroundColor(.teal)
                Text("本地代理端口与接口详情")
                    .font(.system(size: 12.5, weight: .bold))
            }

            Divider().opacity(0.3)

            VStack(spacing: 8) {
                // HTTP 代理
                portRow(title: "HTTP / HTTPS 代理", value: "127.0.0.1:\(port)", isCopied: copiedHttp) {
                    copyText("127.0.0.1:\(port)")
                    copiedHttp = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedHttp = false }
                }

                // SOCKS5 代理
                portRow(title: "SOCKS5 代理", value: "127.0.0.1:\(port)", isCopied: copiedSocks) {
                    copyText("127.0.0.1:\(port)")
                    copiedSocks = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedSocks = false }
                }
            }

            Divider().opacity(0.3)

            // 终端环境变量
            VStack(alignment: .leading, spacing: 4) {
                Text("终端代理环境变量:")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(.secondary)

                HStack {
                    Text(envCommand)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(2)

                    Spacer()

                    Button(action: {
                        copyText(envCommand)
                        copiedEnv = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedEnv = false }
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: copiedEnv ? "checkmark" : "doc.on.doc")
                            Text(copiedEnv ? "已复制" : "复制")
                        }
                        .font(.system(size: 10.5))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.06))
                        .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private func portRow(title: String, value: String, isCopied: Bool, onCopy: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
            Button(action: onCopy) {
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10))
                    .foregroundColor(isCopied ? .green : .secondary)
            }
            .buttonStyle(.plain)
			.accessibilityLabel("复制 \(title)")
        }
    }

    private func copyText(_ text: String) {
        ClipboardHelper.copy(text)
    }
}

// 4. 网络流量接管方式卡片 (系统代理 + 虚拟网卡 + 聚合端口胶囊)
