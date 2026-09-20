import SwiftUI
import AppKit

// MARK: - 1. 独立请求日志窗口控制器 (⌘D 全局呼出 / 独立视窗)
@MainActor
public class InspectorWindowController: NSObject, NSWindowDelegate {
    public static let shared = InspectorWindowController()

    private var window: NSWindow?

    private override init() {
        super.init()
    }

    public func show() {
        if window == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1240, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            win.minSize = NSSize(width: 980, height: 600)
            win.title = "请求日志"
            win.titlebarAppearsTransparent = true
            win.titleVisibility = .hidden
            win.titlebarSeparatorStyle = .none
            win.isOpaque = false
            win.backgroundColor = .clear
            win.hasShadow = true
            win.isReleasedWhenClosed = false
            win.isMovableByWindowBackground = true
            win.delegate = self
            win.setFrameAutosaveName("AsterSurgeUnifiedLogs_v13")
            if !win.setFrameUsingName("AsterSurgeUnifiedLogs_v13") {
                win.center()
            }
            win.contentView = NSHostingView(rootView: SurgeProLogsView())
            self.window = win
        }

        AppDelegate.shared?.prepareToShowWindow()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        AppDelegate.shared?.updateDockPolicy()
    }

    public var isVisible: Bool {
        return window?.isVisible == true
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        AppDelegate.shared?.updateDockPolicy()
        return false
    }

    public func toggle() {
        if let win = window, win.isVisible {
            win.orderOut(nil)
            AppDelegate.shared?.updateDockPolicy()
        } else {
            show()
        }
    }
}

// MARK: - 2. 侧栏过滤分类维度
enum SidebarDimensionType: String, CaseIterable, Identifiable {
    case client = "应用"
    case domain = "域名"
    case device = "设备"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .client: return "app.badge.checkmark"
        case .domain: return "globe"
        case .device: return "laptopcomputer"
        }
    }
}

// MARK: - 3. Surge Pro 工业级实时请求日志主面板
public struct SurgeProLogsView: View {
    private let state: AsterState
    @ObservedObject private var connectionStore: ConnectionStore
    private let loadsRealtimeData: Bool

    // 状态分类：0: 全部, 1: 实时活跃, 2: 已关闭
    @State private var statusFilter: Int = 0

    // 搜索文本
    @State private var searchText: String = ""

    // 三维筛选选中项
    @State private var selectedClient: String? = nil
    @State private var selectedDomain: String? = nil
    @State private var selectedDevice: String? = nil

    // 侧栏当前维度
    @State private var currentDimension: SidebarDimensionType = .client

    // 选中的日志项（右侧属性面板滑出）
    @State private var selectedConnectionId: String? = nil

    // 悬浮行高亮
    @State private var hoveredConnectionId: String? = nil

    // 弹窗确认
    @State private var showCloseAllAlert: Bool = false

    // 规则多态弹窗上下文
    @State private var addRuleContext: AddRuleContext? = nil

    // 规则仿真测试器展开
    @State private var showRuleEvaluator: Bool = false

    @MainActor
    public init(state: AsterState? = nil, loadsRealtimeData: Bool = true) {
        let actual = state ?? .shared
        self.state = actual
        _connectionStore = ObservedObject(wrappedValue: actual.connectionStore)
        self.loadsRealtimeData = loadsRealtimeData
    }

    // MARK: - 统一请求数据池 (实时活跃 + 历史关闭，限制 300 条防内存溢出与掉帧)
    private var allRequestsPool: [ConnectionItem] { connectionStore.requestPool }

    private var activeCount: Int { connectionStore.connections.count }
    private var closedCount: Int { allRequestsPool.filter { $0.isClosed == true }.count }

    // MARK: - 三维聚合列表
    // 1. 按客户端聚合
    private var clientAggregations: [(name: String, count: Int, activeCount: Int)] {
        var map = [String: (total: Int, active: Int)]()
        for c in allRequestsPool {
            let p = c.effectiveProcess.trimmingCharacters(in: .whitespaces)
            let name = p.isEmpty ? "系统网络" : p
            var current = map[name] ?? (total: 0, active: 0)
            current.total += 1
            if c.isClosed != true { current.active += 1 }
            map[name] = current
        }
        return map.map { (name: $0.key, count: $0.value.total, activeCount: $0.value.active) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }

    // 2. 按域名聚合
    private var domainAggregations: [(domain: String, count: Int, activeCount: Int)] {
        var map = [String: (total: Int, active: Int)]()
        for c in allRequestsPool {
            let host = c.metadata?.host ?? ""
            let ip = c.metadata?.destinationIP ?? ""
            let rawTarget = !host.isEmpty ? host : ip
            let d = extractPrimaryDomain(rawTarget)
            if !d.isEmpty {
                var current = map[d] ?? (total: 0, active: 0)
                current.total += 1
                if c.isClosed != true { current.active += 1 }
                map[d] = current
            }
        }
        return map.map { (domain: $0.key, count: $0.value.total, activeCount: $0.value.active) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.domain < $1.domain }
    }

    // 3. 按设备聚合
    private var deviceAggregations: [(device: String, rawIP: String, count: Int, activeCount: Int)] {
        var map = [String: (name: String, total: Int, active: Int)]()
        for c in allRequestsPool {
            let rawSrcIP = c.metadata?.sourceIP?.trimmingCharacters(in: .whitespaces) ?? ""
            let srcIP = rawSrcIP.isEmpty ? "本机" : rawSrcIP
            let label = deviceLabelForIP(srcIP)
            var current = map[srcIP] ?? (name: label, total: 0, active: 0)
            current.total += 1
            if c.isClosed != true { current.active += 1 }
            map[srcIP] = current
        }
        return map.map { (device: $0.value.name, rawIP: $0.key, count: $0.value.total, activeCount: $0.value.active) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.device < $1.device }
    }

    // MARK: - 综合筛选过滤
    private var filteredRequests: [ConnectionItem] {
        allRequestsPool.filter { conn in
            let isClosed = conn.isClosed ?? false

            // 1. 状态分类
            if statusFilter == 1 && isClosed { return false }
            if statusFilter == 2 && !isClosed { return false }

            // 2. 客户端筛选
            if let client = selectedClient, !client.isEmpty {
                if conn.effectiveProcess != client { return false }
            }

            // 3. 域名筛选
            if let domain = selectedDomain, !domain.isEmpty {
                let host = conn.metadata?.host ?? ""
                let ip = conn.metadata?.destinationIP ?? ""
                let primary = extractPrimaryDomain(!host.isEmpty ? host : ip)
                if !host.localizedCaseInsensitiveContains(domain) && primary != domain {
                    return false
                }
            }

            // 4. 设备筛选
            if let deviceIP = selectedDevice, !deviceIP.isEmpty {
                let rawSrcIP = conn.metadata?.sourceIP?.trimmingCharacters(in: .whitespaces) ?? ""
                let srcIP = rawSrcIP.isEmpty ? "本机" : rawSrcIP
                if srcIP != deviceIP && deviceLabelForIP(srcIP) != deviceIP {
                    return false
                }
            }

            // 5. 关键字搜索
            if !searchText.isEmpty {
                let host = conn.metadata?.host ?? ""
                let ip = conn.metadata?.destinationIP ?? ""
                let src = conn.metadata?.sourceIP ?? ""
                let proc = conn.effectiveProcess
                let rule = conn.rule ?? ""
                let payload = conn.rulePayload ?? ""
                let policy = conn.chains?.last ?? ""

                let match = host.localizedCaseInsensitiveContains(searchText) ||
                            ip.localizedCaseInsensitiveContains(searchText) ||
                            src.localizedCaseInsensitiveContains(searchText) ||
                            proc.localizedCaseInsensitiveContains(searchText) ||
                            rule.localizedCaseInsensitiveContains(searchText) ||
                            payload.localizedCaseInsensitiveContains(searchText) ||
                            policy.localizedCaseInsensitiveContains(searchText)
                if !match { return false }
            }

            return true
        }
    }

    private var selectedRequest: ConnectionItem? {
        guard let id = selectedConnectionId else { return nil }
        return allRequestsPool.first(where: { $0.id == id })
    }

    private var hasActiveFilters: Bool {
        selectedClient != nil || selectedDomain != nil || selectedDevice != nil || !searchText.isEmpty
    }

    public var body: some View {
        HStack(spacing: 0) {
            // 1. 左侧纯净全高侧栏
            sidebarView
                .frame(width: 230)
                .frame(maxHeight: .infinity)
                .background(VisualEffectView(material: .sidebar, blendingMode: .behindWindow))

            // 2. 贯穿垂直分割线
            Divider().opacity(0.2)

            // 3. 右侧主工作台
            VStack(spacing: 0) {
                mainTopToolbar
                    .frame(height: 52)

                Divider().opacity(0.15)

                if showRuleEvaluator {
                    RuleEvaluatorBar()
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))

                    Divider().opacity(0.15)
                }

                HStack(spacing: 0) {
                    mainTableArea

                    if let conn = selectedRequest {
                        Divider().opacity(0.18)

                        inspectorDetailPanel(conn)
                            .frame(width: 310)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider().opacity(0.15)

                bottomStatusBar
                    .frame(height: 36)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow))
        }
        .ignoresSafeArea()
        .frame(minWidth: 960, minHeight: 600)
        .onAppear {
            guard loadsRealtimeData else { return }
            Task {
                await state.fetchConnections()
                await state.fetchTopProcesses()
            }
        }
        .alert("确认断开全部活跃连接？", isPresented: $showCloseAllAlert) {
            Button("断开全部", role: .destructive) {
                state.closeAllConnections()
                selectedConnectionId = nil
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作将主动关闭当前内核维护的全部 \(connectionStore.connections.count) 个活跃长连接。")
        }
        .sheet(item: $addRuleContext) { ctx in
            AddRuleModalView(context: ctx) {
                addRuleContext = nil
            }
        }
    }

    // MARK: - 1. 左侧全高侧栏 (Sidebar - 230pt)
    private var sidebarView: some View {
        VStack(spacing: 0) {
            // 红绿灯留白安全区 (46pt)
            Color.clear
                .frame(height: 46)

            // 维度切换分段器 (规范 8pt 圆角)
            HStack(spacing: 2) {
                dimensionTabButton(type: .client)
                dimensionTabButton(type: .domain)
                dimensionTabButton(type: .device)
            }
            .padding(2.5)
            .background(Color.primary.opacity(0.06))
            .clipShape(.rect(cornerRadius: 8))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Divider().opacity(0.15)

            // 维度项列表
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 3) {
                    sidebarAllRow

                    Divider().opacity(0.12)
                        .padding(.vertical, 3)

                    switch currentDimension {
                    case .client:
                        clientListSection
                    case .domain:
                        domainListSection
                    case .device:
                        deviceListSection
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
        }
    }

    private func dimensionTabButton(type: SidebarDimensionType) -> some View {
        let isSelected = currentDimension == type
        return Button(action: {
            withAnimation(.easeInOut(duration: 0.14)) {
                currentDimension = type
            }
        }) {
            HStack(spacing: 4) {
                Image(systemName: type.icon)
                    .font(.system(size: 11))
                Text(type.rawValue)
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
            }
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(isSelected ? Color(NSColor.controlBackgroundColor) : Color.clear)
            .clipShape(.rect(cornerRadius: 6))
            .shadow(color: isSelected ? Color.black.opacity(0.05) : Color.clear, radius: 1, x: 0, y: 1)
        }
        .buttonStyle(.plain)
    }

    private var sidebarAllRow: some View {
        let isAllSelected: Bool = {
            switch currentDimension {
            case .client: return selectedClient == nil
            case .domain: return selectedDomain == nil
            case .device: return selectedDevice == nil
            }
        }()

        return Button(action: {
            switch currentDimension {
            case .client: selectedClient = nil
            case .domain: selectedDomain = nil
            case .device: selectedDevice = nil
            }
        }) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(isAllSelected ? Color.accentColor : Color.clear)
                    .frame(width: 3.5, height: 16)

                Image(systemName: "tray.2.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(isAllSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 16)

                Text("全部\(currentDimension.rawValue)")
                    .font(.system(size: 12.5, weight: isAllSelected ? .semibold : .regular))
                    .foregroundStyle(isAllSelected ? Color.primary : Color.primary.opacity(0.85))

                Spacer()

                Text("\(allRequestsPool.count)")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 5.5)
                    .padding(.vertical, 1)
                    .background(isAllSelected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.05))
                    .foregroundStyle(isAllSelected ? Color.accentColor : Color.secondary)
                    .clipShape(.rect(cornerRadius: 4))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5.5)
            .background(isAllSelected ? Color.accentColor.opacity(0.08) : Color.clear)
            .clipShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var clientListSection: some View {
        Group {
            if clientAggregations.isEmpty {
                emptySidebarPlaceholder("暂无客户端请求")
            } else {
                ForEach(clientAggregations, id: \.name) { item in
                    let isSelected = selectedClient == item.name

                    Button(action: {
                        selectedClient = isSelected ? nil : item.name
                    }) {
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(isSelected ? Color.accentColor : Color.clear)
                                .frame(width: 3.5, height: 16)

                            AppIconView(processPath: "", processName: item.name, size: 17)

                            Text(item.name)
                                .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                                .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.85))
                                .lineLimit(1)

                            Spacer()

                            if item.activeCount > 0 {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 5.5, height: 5.5)
                            }

                            Text("\(item.count)")
                                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                .padding(.horizontal, 5.5)
                                .padding(.vertical, 1)
                                .background(isSelected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.05))
                                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                                .clipShape(.rect(cornerRadius: 4))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5.5)
                        .background(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
                        .clipShape(.rect(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var domainListSection: some View {
        Group {
            if domainAggregations.isEmpty {
                emptySidebarPlaceholder("暂无目标域名记录")
            } else {
                ForEach(domainAggregations.prefix(35), id: \.domain) { item in
                    let isSelected = selectedDomain == item.domain

                    Button(action: {
                        selectedDomain = isSelected ? nil : item.domain
                    }) {
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(isSelected ? Color.accentColor : Color.clear)
                                .frame(width: 3.5, height: 16)

                            Image(systemName: "globe")
                                .font(.system(size: 11.5))
                                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.8))
                                .frame(width: 16)

                            Text(item.domain)
                                .font(.system(size: 12, weight: isSelected ? .semibold : .regular, design: .monospaced))
                                .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.85))
                                .lineLimit(1)

                            Spacer()

                            if item.activeCount > 0 {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 5.5, height: 5.5)
                            }

                            Text("\(item.count)")
                                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                .padding(.horizontal, 5.5)
                                .padding(.vertical, 1)
                                .background(isSelected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.05))
                                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                                .clipShape(.rect(cornerRadius: 4))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5.5)
                        .background(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
                        .clipShape(.rect(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var deviceListSection: some View {
        Group {
            if deviceAggregations.isEmpty {
                emptySidebarPlaceholder("暂无来源设备记录")
            } else {
                ForEach(deviceAggregations, id: \.rawIP) { item in
                    let isSelected = selectedDevice == item.rawIP
                    let isLocal = item.rawIP.contains("127.0.0.1") || item.rawIP == "::1"

                    Button(action: {
                        selectedDevice = isSelected ? nil : item.rawIP
                    }) {
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(isSelected ? Color.accentColor : Color.clear)
                                .frame(width: 3.5, height: 16)

                            Image(systemName: isLocal ? "laptopcomputer" : "iphone")
                                .font(.system(size: 11.5))
                                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.8))
                                .frame(width: 16)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.device)
                                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                                    .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.85))
                                    .lineLimit(1)
                                if !isLocal {
                                    Text(item.rawIP)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Spacer()

                            if item.activeCount > 0 {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 5.5, height: 5.5)
                            }

                            Text("\(item.count)")
                                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                .padding(.horizontal, 5.5)
                                .padding(.vertical, 1)
                                .background(isSelected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.05))
                                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                                .clipShape(.rect(cornerRadius: 4))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5.5)
                        .background(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
                        .clipShape(.rect(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func emptySidebarPlaceholder(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "hourglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }

    // MARK: - 2. 主顶栏 (Main Toolbar - 52pt)
    private var mainTopToolbar: some View {
        HStack(spacing: 14) {
            // 标题与呼吸指示器
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle.portrait.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accentColor)

                Text("请求日志")
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundStyle(.primary)

                HStack(spacing: 4.5) {
                    Circle()
                        .fill(connectionStore.status.running ? Color.green : Color.orange)
                        .frame(width: 5.5, height: 5.5)
                    Text(connectionStore.status.running ? "实时流同步" : "已休眠")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(Color.primary.opacity(0.05))
                .clipShape(.rect(cornerRadius: 10))
            }

            Spacer()

            // 核心状态胶囊控制器 (8pt 圆角)
            HStack(spacing: 2) {
                statusCapsuleButton(title: "全部", count: allRequestsPool.count, tag: 0)
                statusCapsuleButton(title: "活跃", count: activeCount, tag: 1, dotColor: .green)
                statusCapsuleButton(title: "已关闭", count: closedCount, tag: 2, dotColor: .secondary.opacity(0.6))
            }
            .padding(2.5)
            .background(Color.primary.opacity(0.06))
            .clipShape(.rect(cornerRadius: 8))

            Spacer()

            // 搜索框 (发丝边框标准化组件)
            ExquisiteSearchField(
                placeholder: "搜索域名、应用、设备或规则",
                text: $searchText,
                width: 220
            )

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

            // 清理按钮
            if !connectionStore.recentRequests.isEmpty {
                Button(action: {
                    state.clearRecentRequests()
                    selectedConnectionId = nil
                }) {
                    Image(systemName: "trash")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .padding(5.5)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("清空已关闭的请求日志记录")
            }

            // 属性审查抽屉切换按钮
            Button(action: {
                withAnimation(.easeInOut(duration: 0.16)) {
                    if selectedConnectionId != nil {
                        selectedConnectionId = nil
                    } else {
                        selectedConnectionId = filteredRequests.first?.id
                    }
                }
            }) {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 11.5))
                    .foregroundStyle(selectedConnectionId != nil ? Color.accentColor : Color.secondary)
                    .padding(5.5)
                    .background(selectedConnectionId != nil ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("显示/隐藏请求属性审查面板")
        }
        .padding(.horizontal, 16)
    }

    private func statusCapsuleButton(title: String, count: Int, tag: Int, dotColor: Color? = nil) -> some View {
        let isSelected = statusFilter == tag
        return Button(action: {
            withAnimation(.easeInOut(duration: 0.14)) {
                statusFilter = tag
            }
        }) {
            HStack(spacing: 5) {
                if let dot = dotColor {
                    Circle()
                        .fill(dot)
                        .frame(width: 5.5, height: 5.5)
                }

                Text(title)
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)

                Text("\(count)")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 5.5)
                    .padding(.vertical, 1)
                    .background(isSelected ? Color.primary.opacity(0.08) : Color.clear)
                    .clipShape(.rect(cornerRadius: 4))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary.opacity(0.8))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(isSelected ? Color(NSColor.controlBackgroundColor) : Color.clear)
            .clipShape(.rect(cornerRadius: 6))
            .shadow(color: isSelected ? Color.black.opacity(0.06) : Color.clear, radius: 1.5, x: 0, y: 1)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 3. 中央数据流水工作台 (黄金网格，杜绝横向空洞)
    private var mainTableArea: some View {
        let requests = filteredRequests
        return VStack(spacing: 0) {
            // 筛选条件 Chip
            if hasActiveFilters {
                activeFilterChipsBar
                Divider().opacity(0.15)
            }

            // 黄金网格表头 (严格对齐下方行结构)
            HStack(spacing: 0) {
                dataHeaderItem("状态", width: 85, alignment: .leading)
                dataHeaderItem("应用", width: 105)
                dataHeaderItem("目标主机与分流路由", minWidth: 140)
                dataHeaderItem("出站策略", width: 95)
                dataHeaderItem("流量", width: 80, alignment: .trailing)
                dataHeaderItem("时刻", width: 55, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.02))

            Divider().opacity(0.12)

            // 请求流
            if requests.isEmpty {
                emptyStateView
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(requests) { conn in
                            proLogRow(conn)
                        }
                    }
                    .padding(.vertical, 3)
                    .padding(.horizontal, 6)
                }
            }
        }
    }

    private var activeFilterChipsBar: some View {
        HStack(spacing: 6) {
            Text("当前筛选:")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(.secondary)

            if let client = selectedClient {
                filterChip("应用: \(client)") { selectedClient = nil }
            }
            if let domain = selectedDomain {
                filterChip("域名: \(domain)") { selectedDomain = nil }
            }
            if let device = selectedDevice {
                filterChip("设备: \(device)") { selectedDevice = nil }
            }
            if !searchText.isEmpty {
                filterChip("搜索: \"\(searchText)\"") { searchText = "" }
            }

            Spacer()

            Button("清除全部筛选") {
                selectedClient = nil
                selectedDomain = nil
                selectedDevice = nil
                searchText = ""
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(Color.accentColor)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.04))
    }

    private func filterChip(_ text: String, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.primary)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
			.accessibilityLabel("移除筛选 \(text)")
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(Color.primary.opacity(0.06))
        .clipShape(.rect(cornerRadius: 4))
    }

    private func dataHeaderItem(_ title: String, width: CGFloat? = nil, minWidth: CGFloat? = nil, alignment: Alignment = .leading) -> some View {
        Group {
            if let w = width {
                Text(title)
                    .frame(width: w, alignment: alignment)
            } else {
                Text(title)
                    .frame(minWidth: minWidth ?? 140, maxWidth: .infinity, alignment: alignment)
            }
        }
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(Color.secondary.opacity(0.75))
        .padding(.horizontal, 4)
    }

    // MARK: - 4. 黄金排布请求行 (紧凑高密排布，抽屉滑出不挤压，字重得体)
    private func proLogRow(_ conn: ConnectionItem) -> some View {
        let isSelected = selectedConnectionId == conn.id
        let isHovered = hoveredConnectionId == conn.id
        let isClosed = conn.isClosed ?? false
        let proto = detectProtocol(conn)
        let procName = conn.effectiveProcess
        let host = conn.metadata?.host ?? ""
        let ipPort = "\(conn.metadata?.destinationIP ?? ""):\(conn.metadata?.destinationPort ?? "")"
        let primaryTarget = !host.isEmpty ? host : (conn.metadata?.destinationIP ?? "未知目标")
        let rawSrcIP = conn.metadata?.sourceIP?.trimmingCharacters(in: .whitespaces) ?? ""
        let srcIP = rawSrcIP.isEmpty ? "本机" : rawSrcIP
        let deviceLabel = deviceLabelForIP(srcIP)
        let ruleStr = "\(conn.rule ?? "FINAL") \(conn.rulePayload ?? "")".trimmingCharacters(in: .whitespaces)
        let policyStr = conn.chains?.last ?? (connectionStore.status.selectedLabel.isEmpty ? "DIRECT" : connectionStore.status.selectedLabel)

        return Button(action: {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                if selectedConnectionId == conn.id {
                    selectedConnectionId = nil
                } else {
                    selectedConnectionId = conn.id
                }
            }
        }) {
            VStack(spacing: 4) {
                // 行 1: 核心聚焦 (85 / 105 / min 140 / 95 / 80 / 55)
                HStack(spacing: 0) {
                    // 1. 状态微光与异常诊断徽标 (85pt)
                    ConnectionDiagnosticBadge(conn: conn)
                        .frame(width: 85, alignment: .leading)
                        .padding(.horizontal, 4)

                    // 2. 客户端应用 (105pt)
                    HStack(spacing: 5) {
                        AppIconView(processPath: conn.metadata?.processPath ?? "", processName: procName, size: 14)
                        Text(procName.truncated(toVisualWidth: 12))
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.primary.opacity(0.9))
                            .lineLimit(1)
                    }
                    .frame(width: 105, alignment: .leading)
                    .padding(.horizontal, 4)

                    // 3. 目标域名 (主视觉第一焦点: 12.5pt SemiBold Rounded)
                    HStack(spacing: 6) {
                        Text(primaryTarget)
                            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        // 协议小微标 (柔和低调，3.5pt 圆角)
                        protocolSubtleBadge(proto: proto)
                    }
                    .frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)

                    // 4. 出站分流策略微胶囊 (95pt)
                    outboundBadge(policyStr)
                        .frame(width: 95, alignment: .leading)
                        .padding(.horizontal, 4)

                    // 5. 传输总流量 (80pt)
                    Text(Formatters.bytesString(conn.download + conn.upload))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary)
                        .frame(width: 80, alignment: .trailing)
                        .padding(.horizontal, 4)

                    // 6. 请求时间 (55pt)
                    Text(formatTimeOnly(conn.start))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary.opacity(0.8))
                        .frame(width: 55, alignment: .trailing)
                        .padding(.horizontal, 4)
                }

                // 行 2: 辅助诊断参数 (对齐上方列结构，次要信息降噪)
                HStack(spacing: 0) {
                    Color.clear
                        .frame(width: 85)
                        .padding(.horizontal, 4)

                    // 来源设备与 IP (105pt)
                    HStack(spacing: 4) {
                        Image(systemName: "laptopcomputer")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary.opacity(0.7))
                        Text(deviceLabel)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary.opacity(0.8))
                            .lineLimit(1)
                    }
                    .frame(width: 105, alignment: .leading)
                    .padding(.horizontal, 4)

                    // 端口与命中规则 (minWidth 140)
                    HStack(spacing: 6) {
                        Text(":\(conn.metadata?.destinationPort ?? "")")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary.opacity(0.7))

                        if !ruleStr.isEmpty {
                            Text("·")
                                .foregroundStyle(.secondary.opacity(0.3))
                            Text("Rule: \(ruleStr)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary.opacity(0.7))
                                .lineLimit(1)
                        }
                    }
                    .frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)

                    Color.clear
                        .frame(width: 95)
                        .padding(.horizontal, 4)

                    // 上传流量 (80pt)
                    Text("↑ \(Formatters.bytesString(conn.upload))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary.opacity(0.7))
                        .frame(width: 80, alignment: .trailing)
                        .padding(.horizontal, 4)

                    Color.clear
                        .frame(width: 55)
                        .padding(.horizontal, 4)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(
                        isSelected
                            ? Color.accentColor.opacity(0.12)
                            : (isHovered ? Color.primary.opacity(0.04) : Color.clear)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(isSelected ? Color.accentColor.opacity(0.35) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hoveredConnectionId = inside ? conn.id : nil
        }
        .contextMenu {
            Button("复制目标主机 (\(primaryTarget))") {
                copyToClipboard(primaryTarget)
            }
            if !ipPort.isEmpty && ipPort != ":" {
                Button("复制远程地址 (\(ipPort))") {
                    copyToClipboard(ipPort)
                }
            }
            Divider()
            Button("按此应用筛选 (\(procName))") {
                selectedClient = procName
                currentDimension = .client
            }
            Button("按此域名筛选 (\(extractPrimaryDomain(primaryTarget)))") {
                selectedDomain = extractPrimaryDomain(primaryTarget)
                currentDimension = .domain
            }
            Button("按此设备筛选 (\(deviceLabel))") {
                selectedDevice = srcIP
                currentDimension = .device
            }
            Divider()
            Button("为域名 (\(primaryTarget)) 添加规则…") {
                let icon = state.iconForProcess(path: conn.metadata?.processPath ?? "", name: procName, size: 40)
                addRuleContext = .forDomain(host: primaryTarget, appName: procName, appIcon: icon)
            }
            Button("为进程 (\(procName)) 添加规则…") {
                let icon = state.iconForProcess(path: conn.metadata?.processPath ?? "", name: procName, size: 40)
                addRuleContext = .forProcess(name: procName, path: conn.metadata?.processPath ?? "", icon: icon)
            }
            Divider()
            Button("设为直连 (DIRECT)…") {
                let icon = state.iconForProcess(path: conn.metadata?.processPath ?? "", name: procName, size: 40)
                addRuleContext = .forDomain(host: primaryTarget, appName: procName, appIcon: icon, preferredAction: "DIRECT")
            }
            Button("设为代理 (PROXY)…") {
                let icon = state.iconForProcess(path: conn.metadata?.processPath ?? "", name: procName, size: 40)
                addRuleContext = .forDomain(host: primaryTarget, appName: procName, appIcon: icon, preferredAction: "PROXY")
            }
            Button("设为拦截 (REJECT)…") {
                let icon = state.iconForProcess(path: conn.metadata?.processPath ?? "", name: procName, size: 40)
                addRuleContext = .forDomain(host: primaryTarget, appName: procName, appIcon: icon, preferredAction: "REJECT")
            }
            if !isClosed {
                Divider()
                Button("断开此连接") {
                    state.closeConnection(conn.id)
                }
            }
        }
    }

    // 状态指示点 (5.5pt 优雅微点)
    private func statusPulseDot(isClosed: Bool) -> some View {
        Circle()
            .fill(isClosed ? Color.secondary.opacity(0.35) : Color.green)
            .frame(width: 5.5, height: 5.5)
    }

    // 协议小微标 (柔和专属语义色彩，3.5pt 圆角)
    private func protocolSubtleBadge(proto: String) -> some View {
        let color = ProtocolBadge.protocolColor(proto)
        return Text(proto)
            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(color == .secondary ? Color.secondary : color)
            .padding(.horizontal, 4.5)
            .padding(.vertical, 1.5)
            .background(color == .secondary ? Color.primary.opacity(0.06) : color.opacity(0.12))
            .clipShape(.rect(cornerRadius: 3.5))
    }

    // 出站策略胶囊 (与主界面规则/活动统一使用 ActionBadge)
    private func outboundBadge(_ policy: String) -> some View {
        ActionBadge(action: policy)
    }

    private func detectProtocol(_ conn: ConnectionItem) -> String {
        if conn.metadata?.destinationPort == "53" { return "DNS" }
        if conn.metadata?.network?.lowercased() == "udp" { return "UDP" }
        if conn.metadata?.destinationPort == "443" { return "HTTPS" }
        if conn.metadata?.destinationPort == "80" { return "HTTP" }
        return conn.metadata?.network?.uppercased() ?? "TCP"
    }

    private func formatTimeOnly(_ raw: String?) -> String {
        guard let raw = raw, !raw.isEmpty else { return "刚刚" }
        if raw.count >= 19 {
            let startIdx = raw.index(raw.startIndex, offsetBy: 11)
            let endIdx = raw.index(raw.startIndex, offsetBy: 19)
            return String(raw[startIdx..<endIdx])
        }
        return raw
    }

    private func formatDuration(_ ms: Int64?) -> String {
        guard let ms = ms else { return "--" }
        if ms < 0 { return "0ms" }
        if ms < 1000 {
            return "\(ms)ms"
        } else {
            return String(format: "%.2fs", Double(ms) / 1000.0)
        }
    }

    private func formatCloseReason(_ conn: ConnectionItem) -> String {
        if let reason = conn.diagnostics?.closeReason {
            switch reason {
            case "rejected": return "规则阻断"
            case "timeout": return "连接超时"
            case "dns_failed": return "DNS 异常"
            case "completed": return "正常完成"
            case "active": return "活跃传输中"
            default: return reason
            }
        }
        if conn.isReject { return "规则阻断" }
        if conn.isClosed == true { return "已关闭" }
        return "活跃传输中"
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func extractPrimaryDomain(_ hostOrIP: String) -> String {
        let raw = hostOrIP.split(separator: ":").first.map(String.init) ?? hostOrIP
        let parts = raw.split(separator: ".")
        if parts.count >= 2 {
            return parts.suffix(2).joined(separator: ".")
        }
        return raw
    }

    private func deviceLabelForIP(_ ip: String) -> String {
        if ip == "127.0.0.1" || ip == "::1" || ip.isEmpty || ip.contains("localhost") {
            return "本机"
        }
        if ip.starts(with: "198.18.") {
            return "本机(FakeIP)"
        }
        return ip
    }

    // MARK: - 5. 空状态提示
    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.06))
                    .frame(width: 72, height: 72)
                Circle()
                    .stroke(Color.accentColor.opacity(0.12), lineWidth: 1.5)
                    .frame(width: 54, height: 54)
                Image(systemName: "list.bullet.rectangle.portrait")
                    .font(.system(size: 26))
                    .foregroundStyle(Color.accentColor.opacity(0.7))
            }

            VStack(spacing: 4) {
                Text(hasActiveFilters ? "无匹配当前条件的请求日志" : "等待网络请求流入...")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.85))

                Text(hasActiveFilters ? "请尝试调整搜索关键字，或点击上方清除筛选" : "保持内核运行，本地应用发起通信时将毫秒级流式展现")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 6. 右侧滑出属性审查面板 (340pt)
    private func inspectorDetailPanel(_ conn: ConnectionItem) -> some View {
        let isClosed = conn.isClosed ?? false
        let proto = detectProtocol(conn)
        let targetHost = conn.metadata?.host ?? "--"
        let destIP = conn.metadata?.destinationIP ?? "--"
        let rawSrcIP = conn.metadata?.sourceIP?.trimmingCharacters(in: .whitespaces) ?? ""
        let srcIP = rawSrcIP.isEmpty ? "本机" : rawSrcIP
        let policyStr = conn.chains?.last ?? "DIRECT"

        return VStack(spacing: 0) {
            // 6.1 审查器顶栏
            HStack {
                HStack(spacing: 7) {
                    Image(systemName: "sidebar.right")
                        .foregroundStyle(Color.accentColor)
                        .font(.system(size: 12))
                    Text("请求属性审查")
                        .font(.system(size: 12.5, weight: .bold))
                }

                Spacer()

                Button(action: {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        selectedConnectionId = nil
                    }
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.secondary.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.primary.opacity(0.02))

            Divider().opacity(0.15)

            // 6.2 属性详情流
            ScrollView {
                VStack(spacing: 12) {
                    inspectorSection("客户端与来源设备") {
                        inspectorProperty("应用程序", conn.effectiveProcess)
                        inspectorProperty("来源设备", deviceLabelForIP(srcIP))
                        inspectorProperty("来源 IP", srcIP, canCopy: true)
                        inspectorProperty("进程路径", conn.metadata?.processPath ?? "--", canCopy: true)
                    }

                    inspectorSection("目标网络与传输") {
                        inspectorProperty("目标主机", targetHost, canCopy: true)
                        inspectorProperty("目标 IP", destIP, canCopy: true)
                        inspectorProperty("目标端口", destPort)
                        inspectorProperty("网络协议", "\(conn.metadata?.network?.uppercased() ?? "TCP") · \(proto)")
                    }

                    inspectorSection("分流规则与出站") {
                        RuleTracePipelineView(conn: conn)
                            .padding(.vertical, 2)

                        inspectorProperty("命中规则", "\(conn.rule ?? "FINAL") \(conn.rulePayload ?? "")")
                        inspectorProperty("出站节点", policyStr)
                        inspectorProperty("完整链路", conn.chains?.joined(separator: " → ") ?? policyStr)
                    }

                    inspectorSection("流量与时序生命周期") {
                        inspectorProperty("连接状态", isClosed ? "已关闭终止" : "实时传输中")
                        inspectorProperty("关闭原因", formatCloseReason(conn))
                        inspectorProperty("持续时间", formatDuration(conn.diagnostics?.durationMs))
                        inspectorProperty("瞬时下行", "\(Formatters.bytesString(conn.diagnostics?.speedIn ?? 0))/s")
                        inspectorProperty("瞬时上行", "\(Formatters.bytesString(conn.diagnostics?.speedOut ?? 0))/s")
                        inspectorProperty("下载传输", Formatters.bytesString(conn.download))
                        inspectorProperty("上传传输", Formatters.bytesString(conn.upload))
                        inspectorProperty("请求时刻", conn.start ?? "--")
                    }

                    // 快捷动作 (对标 Surge，呼出多态规则弹窗)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("分流与策略动作")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(.secondary)

                        VStack(spacing: 6) {
                            // 1. 为目标域名添加规则... (对应图 3)
                            actionButton(title: "为目标域名添加规则…", icon: "globe", color: .blue) {
                                let icon = state.iconForProcess(path: conn.metadata?.processPath ?? "", name: conn.effectiveProcess, size: 40)
                                let target = targetHost != "--" ? targetHost : destIP
                                addRuleContext = .forDomain(host: target, appName: conn.effectiveProcess, appIcon: icon)
                            }

                            // 2. 为进程应用添加规则... (对应图 4)
                            actionButton(title: "为进程应用添加规则…", icon: "app.badge", color: .indigo) {
                                let icon = state.iconForProcess(path: conn.metadata?.processPath ?? "", name: conn.effectiveProcess, size: 40)
                                addRuleContext = .forProcess(
                                    name: conn.effectiveProcess,
                                    path: conn.metadata?.processPath ?? "",
                                    icon: icon
                                )
                            }

                            // 3. 快速预设策略弹窗
                            HStack(spacing: 6) {
                                quickActionPreset(title: "直连", color: .green) {
                                    let icon = state.iconForProcess(path: conn.metadata?.processPath ?? "", name: conn.effectiveProcess, size: 40)
                                    let target = targetHost != "--" ? targetHost : destIP
                                    addRuleContext = .forDomain(host: target, appName: conn.effectiveProcess, appIcon: icon, preferredAction: "DIRECT")
                                }
                                quickActionPreset(title: "代理", color: .blue) {
                                    let icon = state.iconForProcess(path: conn.metadata?.processPath ?? "", name: conn.effectiveProcess, size: 40)
                                    let target = targetHost != "--" ? targetHost : destIP
                                    addRuleContext = .forDomain(host: target, appName: conn.effectiveProcess, appIcon: icon, preferredAction: "PROXY")
                                }
                                quickActionPreset(title: "阻断", color: .red) {
                                    let icon = state.iconForProcess(path: conn.metadata?.processPath ?? "", name: conn.effectiveProcess, size: 40)
                                    let target = targetHost != "--" ? targetHost : destIP
                                    addRuleContext = .forDomain(host: target, appName: conn.effectiveProcess, appIcon: icon, preferredAction: "REJECT")
                                }
                            }

                            if !isClosed {
                                actionButton(title: "断开此连接", icon: "xmark.octagon.fill", color: .secondary) {
                                    state.closeConnection(conn.id)
                                }
                            }
                        }
                    }
                    .padding(10)
                    .background(Color.primary.opacity(0.03))
                    .clipShape(.rect(cornerRadius: 8))
                }
                .padding(12)
            }
        }
        .background(.ultraThinMaterial)
    }

    private func inspectorSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(.secondary)

            VStack(spacing: 4) {
                content()
            }
            .padding(10)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            .clipShape(.rect(cornerRadius: 7))
        }
    }

    private func inspectorProperty(_ key: String, _ value: String, canCopy: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(key)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)

            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            if canCopy && value != "--" {
                Button(action: { copyToClipboard(value) }) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
				.accessibilityLabel("复制 \(key) 内容")
                .help("复制此项内容")
            }
        }
    }

    private func quickActionPreset(title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(color.opacity(0.08))
                .clipShape(.rect(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(color.opacity(0.2), lineWidth: 0.8)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func actionButton(title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10.5))
                    .foregroundStyle(color)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5.5)
            .background(Color(NSColor.windowBackgroundColor))
            .clipShape(.rect(cornerRadius: 5.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 7. 仪表盘底栏 (高度 38pt，厚重专业)
    private var bottomStatusBar: some View {
        HStack(spacing: 12) {
            // 运行状态与引擎
            HStack(spacing: 5) {
                Circle()
                    .fill(connectionStore.status.running ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
                Text(connectionStore.status.running ? "内核引擎运转正常" : "内核未运行")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            Text("·")
                .foregroundStyle(Color.secondary.opacity(0.3))

            // 模式指示
            Text("模式: \(connectionStore.status.mode.isEmpty ? "Rule" : connectionStore.status.mode)")
                .font(.system(size: 10.5, weight: .medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Color.primary.opacity(0.05))
                .clipShape(.rect(cornerRadius: 4))
                .foregroundStyle(.secondary)

            Text("·")
                .foregroundStyle(Color.secondary.opacity(0.3))

            Text("活跃连接: \(activeCount)")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)

            Text("展示: \(filteredRequests.count) 条")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)

            Spacer()

            // 实时吞吐微胶囊
            HStack(spacing: 8) {
                HStack(spacing: 3.5) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.teal)
                    Text(Formatters.speedString(connectionStore.currentUpSpeed))
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 3.5) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.blue)
                    Text(Formatters.speedString(connectionStore.currentDownSpeed))
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(Color.primary.opacity(0.04))
            .clipShape(.rect(cornerRadius: 5))

            if activeCount > 0 {
                Button(action: { showCloseAllAlert = true }) {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 10))
                        Text("断开全部活跃")
                            .font(.system(size: 10.5))
                    }
                }
                .buttonStyle(.exquisiteDestructive(height: 22))
            }
        }
        .padding(.horizontal, 16)
    }
}
