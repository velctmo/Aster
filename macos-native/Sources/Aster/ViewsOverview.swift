import SwiftUI
import Charts
import AppKit

public struct OverviewDashboardView: View {
    @ObservedObject var state = AsterState.shared
    @AppStorage("allowLanSharing") private var allowLanSharing = false
    @State private var showPortsSheet = false

    public var body: some View {
        let importedProfile = state.status.activeConfigKind == "subscription"
        VStack(spacing: 0) {
            PageHeader(title: "控制台") {
                HStack(spacing: 8) {
                    Menu("出站模式", systemImage: "arrow.triangle.branch") {
                        Button("智能规则") { state.setMode("rule") }
                        Button("全局代理") { state.setMode("global") }
                        Button("直接连接") { state.setMode("direct") }
                    }
                    .disabled(!(state.status.capabilities?.ruleControl.available ?? true))
                    .help(state.status.capabilities?.ruleControl.reason ?? "切换出站模式")

                }
            }

            ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.sectionGap) {

                overviewSection(title: "运行状态") {
                    OverviewModuleCard(
                        icon: state.status.running ? "bolt.horizontal.circle.fill" : "bolt.slash.circle",
                        iconColor: state.status.running ? .green : .orange,
                        title: state.status.activeConfigName ?? "未选择配置",
                        statusText: state.status.running ? "核心运行中" : (state.status.pending ? "正在启动" : "核心未运行"),
                        statusActive: state.status.running,
                        description: runtimeSummary,
                        isOn: nil,
                        customAction: {
                            Group {
                                if state.status.sessionPhase == "failed" || state.status.sessionPhase == "networkComponentRequired" {
                                    Button("重新尝试") { state.restartCore() }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        .accessibilityHint("重新启动当前活动配置的核心")
                                }
                            }
                        }
                    )
                }

                // B. 第一组：网络接管卡片池 (Network Takeover)
                overviewSection(title: "网络接管") {
                    VStack(spacing: 12) {
                        // 卡片 1: 系统代理
                        OverviewModuleCard(
                            icon: "globe",
                            iconColor: .blue,
                            title: "系统代理",
                            statusText: state.status.capture.systemProxy
                                ? (state.status.running
                                    ? "已配置为 127.0.0.1:\(state.status.mixedPort ?? 2080)"
                                    : "等待核心启动")
                                : "未设置",
                            statusActive: state.status.capture.systemProxy && state.status.running,
                            description: "在 macOS 系统网络偏好设置中挂载 HTTP 和 HTTPS 代理。大多数应用与浏览器会自动遵循此设置。",
                            isOn: Binding(
                                get: { state.status.capture.systemProxy },
                                set: { state.setCapture(systemProxy: $0, tun: state.status.capture.tun) }
                            ),
                            isEnabled: state.status.capabilities?.systemProxy.available ?? true
                        )

                        // 卡片 2: 虚拟网卡 (彻底去除 TUN)
                        OverviewModuleCard(
                            icon: "cpu.fill",
                            iconColor: .green,
                            title: "虚拟网卡",
                            statusText: state.status.capture.tun
                                ? (state.status.running ? "运行中 (系统级接管)" : (state.status.needAdmin ? "需要安装网络组件" : "等待核心启动"))
                                : "已禁用",
                            statusActive: state.status.capture.tun && state.status.running,
                            description: "创建独立虚拟网卡，全量接管 TCP/UDP 流量，游戏与终端免配全代理，无需应用主动适配。",
                            isOn: Binding(
                                get: { state.status.capture.tun },
                                set: { state.setCapture(systemProxy: state.status.capture.systemProxy, tun: $0) }
                            ),
                            isEnabled: state.status.capabilities?.tun.available ?? true
                        )
                    }
                }

                // C. 第二组：局域网设备接管 (LAN Devices & Sharing)
                overviewSection(title: "局域网设备接管") {
                    VStack(spacing: 12) {
                        // 卡片 3: 局域网代理共享
                        OverviewModuleCard(
                            icon: "network",
                            iconColor: .indigo,
                            title: "局域网代理共享",
                            statusText: importedProfile ? "由完整配置管理" : (allowLanSharing ? "已监听在 \(state.localLANIP):\(state.status.mixedPort ?? 2080)" : "局域网共享已关闭"),
                            statusActive: !importedProfile && allowLanSharing,
                            description: importedProfile
                                ? "完整订阅的入站监听由配置作者管理，Aster 不会改写局域网共享设置。"
                                : "允许局域网内的其它设备（如手机、平板、电视或同网络电脑）通过本机的 IP 与端口代理上网。",
                            isOn: Binding(
                                get: { allowLanSharing },
                                set: { v in
                                    allowLanSharing = v
                                    state.patchSettings(body: ["allowLan": v])
                                }
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
                                    PortsDetailPopoverView(port: state.status.mixedPort ?? 2080, clashPort: state.status.clashPort ?? 2090)
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
            Task { await state.fetchSettings() }
            allowLanSharing = UserDefaults.standard.object(forKey: "allowLanSharing") as? Bool ?? allowLanSharing
        }
    }

    private var runtimeSummary: String {
        var parts = ["出口：\(state.status.selectedLabel)"]
        if let phase = state.status.sessionPhase {
            switch phase {
            case "starting": parts.append("状态：正在启动")
            case "networkComponentRequired": parts.append("状态：需要安装网络组件")
            case "failed": parts.append("状态：启动失败")
            default: break
            }
        }
        if state.status.delayMs > 0 { parts.append("延迟：\(state.status.delayMs) ms") }
        if let restoredAt = state.status.lastSuccessfulAt, restoredAt > 0 {
            let date = Date(timeIntervalSince1970: TimeInterval(restoredAt))
            parts.append("最近成功：\(date.formatted(date: .abbreviated, time: .shortened))")
        }
        if !state.status.error.isEmpty { parts.append("错误：\(state.status.error)") }
        return parts.joined(separator: " · ")
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
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
        )
        .liquidGlassBorder(cornerRadius: 12)
        .shadow(color: Color.black.opacity(0.04), radius: 6, x: 0, y: 2)
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
                        guard !ip.isEmpty && ip != "检测中..." && ip != "检测失败" else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(ip, forType: .string)
                        copiedLocal = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedLocal = false }
                    }) {
                        Text(copiedLocal ? "已复制" : "复制")
                            .font(.system(size: 10.5))
                            .foregroundColor(copiedLocal ? .green : .blue)
                    }
                    .buttonStyle(.plain)
                }
                Text(state.dualIP.localIP.ip.isEmpty ? "---" : state.dualIP.localIP.ip)
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
                        guard !ip.isEmpty && ip != "检测中..." && ip != "检测失败" && ip != "待连接" else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(ip, forType: .string)
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
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(ip, forType: .string)
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
                    Text(state.dualIP.localIP.ip.isEmpty ? "127.0.0.1" : state.dualIP.localIP.ip)
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
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
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.ultraThinMaterial)
            )
            .liquidGlassBorder(cornerRadius: 12)
            .shadow(color: Color.black.opacity(0.04), radius: 6, x: 0, y: 2)

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
                            ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
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
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(ip, forType: .string)
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
                    HStack(spacing: 4) {
                        Text(location.isEmpty ? "直连模式" : location)
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
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.ultraThinMaterial)
            )
            .liquidGlassBorder(cornerRadius: 12)
            .shadow(color: Color.black.opacity(0.04), radius: 6, x: 0, y: 2)
        }
    }
}

// MARK: - 3. 代理端口详情原生 Popover 弹层
public struct PortsDetailPopoverView: View {
    let port: Int
    let clashPort: Int
    @State private var copiedHttp = false
    @State private var copiedSocks = false
    @State private var copiedControl = false
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

                // Clash API 端口
                portRow(title: "内核控制端口", value: "127.0.0.1:\(clashPort)", isCopied: copiedControl) {
                    copyText("127.0.0.1:\(clashPort)")
                    copiedControl = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedControl = false }
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
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// 4. 网络流量接管方式卡片 (系统代理 + 虚拟网卡 + 聚合端口胶囊)
