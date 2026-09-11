import SwiftUI
import Charts
import AppKit

public struct OutboundsView: View {
    @ObservedObject var state = AsterState.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("sortNodesByDelay") private var sortNodesByDelay: Bool = false
    @State private var sortOption: NodeSortOption = .defaultOrder
    @State private var searchText = ""
    @State private var selectedSourceID = "all"
    @State private var expandedGroupTags: Set<String> = []
    @State private var didAutoExpandGroups = false

    public enum NodeSortOption: String, CaseIterable {
        case defaultOrder = "默认顺序"
        case lowestDelay = "最低延迟优先"
    }

    private let columns = [
        GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 12)
    ]

    private var sourceOptions: [(id: String, name: String)] {
        var seen = Set<String>()
        return state.nodes.compactMap { node in
            guard let id = node.subId, !id.isEmpty, id != "local", seen.insert(id).inserted else { return nil }
            return (id, node.subName?.isEmpty == false ? node.subName! : "订阅来源")
        }
    }

    private var filteredNodes: [ProxyNode] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return state.nodes.filter { node in
            if node.tag == "auto" {
                return selectedSourceID == "all" && query.isEmpty
            }
            if selectedSourceID != "all" && node.subId != selectedSourceID {
                return false
            }
            guard !query.isEmpty else { return true }
            return node.name.localizedCaseInsensitiveContains(query) ||
                node.tag.localizedCaseInsensitiveContains(query) ||
                node.protocolName.localizedCaseInsensitiveContains(query) ||
                (node.subName?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var sortedNodes: [ProxyNode] {
        let nodes = filteredNodes
        switch sortOption {
        case .defaultOrder:
            return nodes
        case .lowestDelay:
            // 防抖锁：如果正在全量测速中，保持现有视图顺序不频繁重排防跳动
            if !state.testingTags.isEmpty {
                return nodes
            }
            return nodes.sorted { a, b in
                let da = a.delayMs
                let db = b.delayMs
                // 1. 两者均测通且大于 0：延迟越低越靠前
                if da > 0 && db > 0 {
                    return da < db
                }
                // 2. 一个测通，一个未测（0）或超时（<0）：测通的优先
                if da > 0 && db <= 0 {
                    return true
                }
                if da <= 0 && db > 0 {
                    return false
                }
                // 3. 两者均未测通：未测速 (0) 优于 超时/异常 (<0)
                if da == 0 && db < 0 {
                    return true
                }
                if da < 0 && db == 0 {
                    return false
                }
                return false
            }
        }
    }

    @ViewBuilder
    private var headerActions: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("搜索节点", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除节点搜索")
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .frame(maxWidth: 190)

            if !sourceOptions.isEmpty {
                Picker("来源", selection: $selectedSourceID) {
                    Text("全部来源").tag("all")
                    ForEach(sourceOptions, id: \.id) { source in
                        Text(source.name).tag(source.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 150)
            }

            Picker("排序", selection: $sortOption) {
                ForEach(NodeSortOption.allCases, id: \.self) { opt in
                    Text(opt.rawValue).tag(opt)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)

            Button(action: {
                // 点击全量测速时，自动展开所有包含叶子节点的策略组，让用户直接看到测速动态
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    for g in state.visibleStrategyGroups {
                        expandedGroupTags.insert(g.tag)
                    }
                }
                state.testAllNodes() 
            }) {
                HStack(spacing: 5) {
                    if state.isTestingDelays {
                        ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                        Text("正在全量测速…")
                    } else {
                        Image(systemName: "bolt.fill")
                        Text("测速全部策略组")
                    }
                }
            }
            .buttonStyle(.exquisitePrimary)
            .disabled(state.isTestingDelays || !(state.status.capabilities?.speedtest.available ?? true))
            .help(state.status.capabilities?.speedtest.reason ?? "测试全部节点延迟")
        }
    }

    // MARK: - 策略组卡片头部
    private var policyGroupHeader: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.blue.opacity(0.12))
                    .frame(width: 38, height: 38)
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.blue)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("全部节点")
                        .font(.system(size: 15, weight: .bold))

                    Text("PROXY")
                        .font(.system(size: 10, weight: .heavy, design: .monospaced))
                        .foregroundColor(.blue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                    Text("SELECTOR")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                    Text("默认主策略组")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 8) {
                    Text("当前出站:")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    let activeLabel = state.status.selectedLabel.isEmpty ? "自动选择" : state.status.selectedLabel
                    Text(activeLabel)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(.primary)

                    if state.status.delayMs > 0 {
                        Text("\(state.status.delayMs) ms")
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                            .foregroundColor(.green)
                    } else if state.status.delayMs < 0 {
                        Text("超时")
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                            .foregroundColor(.red)
                    }

                    Text("·  \(state.nodes.count) 个可用子节点")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
        )
        .padding(.horizontal, DesignTokens.pagePadding)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "network.slash")
                .font(.system(size: 36))
                .foregroundColor(.secondary.opacity(0.4))
            Text("暂无可用节点")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)
            Text("请先在「设置 - 配置」中添加订阅或导入节点")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func autoExpandGroupsIfNeeded() {
        let groups = state.visibleStrategyGroups
        guard !groups.isEmpty, !didAutoExpandGroups else { return }
        for group in groups {
            expandedGroupTags.insert(group.tag)
        }
        didAutoExpandGroups = true
    }

    @ViewBuilder
    private var nodesGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(state.visibleStrategyGroups) { group in
                    strategyGroupSection(group)
                }
            }
            .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
    }


    @ViewBuilder
    private func strategyGroupSection(_ group: StrategyGroup) -> some View {
        let isGroupTesting = state.isTestingGroup(group)
        let expanded = Binding(
            get: { expandedGroupTags.contains(group.tag) },
            set: { value in if value { expandedGroupTags.insert(group.tag) } else { expandedGroupTags.remove(group.tag) } }
        )

        let currentLabel = state.selectedLabel(in: group)

        VStack(alignment: .leading, spacing: 0) {
            DisclosureGroup(isExpanded: expanded) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 155, maximum: 230), spacing: 8)], spacing: 8) {
                    ForEach(group.members, id: \.self) { tag in
                        let node = state.findNode(for: tag)
                        GroupNodeCard(
                            tag: tag,
                            node: node,
                            isSelector: state.canSelectMember(group: group, tag: tag),
                            isSelected: state.isMemberSelected(group: group, tag: tag),
                            isTesting: state.isNodeTesting(tag),
                            onSelect: {
                                state.selectStrategyGroupNode(group: group, tag: tag)
                            },
                            onTest: StrategyPresentation.canTest(tag: tag) ? { state.testNodeDelay(tag) } : nil
                        )
                    }
                }
                .padding(.top, 10)
                .padding(.bottom, 8)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: group.type == "selector" ? "square.stack.3d.up.fill" : "arrow.triangle.branch")
                        .foregroundColor(isGroupTesting ? .blue : .primary)
                        .font(.system(size: 14, weight: .semibold))

                    Text(group.name)
                        .font(.system(size: 14, weight: .bold))

                    Text(group.type.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))

                    if group.type == "urltest" {
                        Text("内核调度")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.teal)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1.5)
                            .background(Color.teal.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                            .help("该组由内核自动测速调度，组内节点仅供状态查看，不支持手动点击")
                    }

                    if !currentLabel.isEmpty {
                        Text("➔")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.secondary.opacity(0.6))
                        Text(currentLabel.truncated(toVisualWidth: 18))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.blue)
                    }

                    Spacer()

                    if !isGroupTesting {
                        Text("\(group.leafTags.count) 节点").font(.caption).foregroundStyle(.secondary)
                    }

                    Button {
                        _ = withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            expandedGroupTags.insert(group.tag)
                        }
                        state.testStrategyGroup(group)
                    } label: {
                        HStack(spacing: 3) {
                            if isGroupTesting {
                                ProgressView().controlSize(.mini).frame(width: 10, height: 10)
                            }
                            Text(isGroupTesting ? "测速中" : "测速")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!state.status.running || group.leafTags.isEmpty || isGroupTesting)
                }
                .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.02))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.8)
        )
        .padding(.horizontal, DesignTokens.pagePadding)
        .onAppear {
            if group.tag == state.status.selected || group.tag == "proxy" { expandedGroupTags.insert(group.tag) }
        }
        .onChange(of: isGroupTesting) { _, testing in
            if testing {
                _ = withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    expandedGroupTags.insert(group.tag)
                }
            }
        }
    }

    @ViewBuilder
    private func latencyText(_ delay: Int, testing: Bool) -> some View {
        if testing {
            Text("测速中…").foregroundStyle(.blue)
        } else if delay < 0 {
            Text("超时").foregroundStyle(Color(red: 0.85, green: 0.38, blue: 0.38))
        } else if delay == 0 {
            Text("---").foregroundStyle(.secondary)
        } else {
            let col = delay <= 150 ? Color(red: 0.22, green: 0.72, blue: 0.48) : (delay <= 500 ? Color(red: 0.88, green: 0.62, blue: 0.22) : Color(red: 0.85, green: 0.38, blue: 0.38))
            Text("\(delay) ms").foregroundStyle(col)
        }
    }

    // MARK: - 顶置全局出站分流模式控制器 (规则判定 / 全局代理 / 直接连接)
    private var outboundModeBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 3) {
                modeSegmentButton(mode: "rule", label: "规则判定", code: "RULE", icon: "arrow.triangle.branch")
                modeSegmentButton(mode: "global", label: "全局代理", code: "GLOBAL", icon: "globe.asia.australia.fill")
                modeSegmentButton(mode: "direct", label: "直接连接", code: "DIRECT", icon: "bolt.horizontal.fill")
            }
            .padding(3)
            .background(Color.primary.opacity(0.04))
            .clipShape(.rect(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6)
            )

            Spacer()

            // 模式语义指示微标
            HStack(spacing: 6) {
                Circle()
                    .fill(modeColor)
                    .frame(width: 6, height: 6)
                Text(modeDescription)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, DesignTokens.pagePadding)
        .padding(.vertical, 8)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.4))
    }

    private var modeColor: Color {
        switch state.status.mode {
        case "global": return .blue
        case "direct": return Color(red: 0.88, green: 0.62, blue: 0.22)
        default: return Color(red: 0.22, green: 0.72, blue: 0.48)
        }
    }

    private var modeDescription: String {
        switch state.status.mode {
        case "global": return "全局代理：全部流量经由当前选中的代理节点转发"
        case "direct": return "直接连接：全部流量直接发起请求，不经过任何代理"
        default: return "规则判定：依据分流规则自动判定代理直连或阻断"
        }
    }

    private func modeSegmentButton(mode: String, label: String, code: String, icon: String) -> some View {
        let isSelected = state.status.mode == mode
        return Button(action: {
            state.setMode(mode)
        }) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                Text(label)
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                Text(code)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(isSelected ? Color.blue : Color.secondary.opacity(0.7))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4.5)
            .background(
                isSelected ?
                    RoundedRectangle(cornerRadius: 6.5)
                        .fill(Color(NSColor.controlBackgroundColor))
                        .shadow(color: Color.black.opacity(0.08), radius: 2, x: 0, y: 1)
                    : nil
            )
            .overlay(
                isSelected ?
                    RoundedRectangle(cornerRadius: 6.5)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6)
                    : nil
            )
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    public var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "策略") {
                headerActions
                if state.status.activeConfigKind == "subscription" {
                    Text("完整订阅只读").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            Divider().opacity(0.4)

            outboundModeBar

            Divider().opacity(0.3)

            if state.visibleStrategyGroups.isEmpty {
                emptyState
            } else {
                nodesGrid
            }
        }
        .disabled(!(state.status.capabilities?.nodeControl.available ?? true))
        .onAppear {
            if sortNodesByDelay {
                sortOption = .lowestDelay
            }
            autoExpandGroupsIfNeeded()
            Task {
                await state.fetchStrategyGroups()
                autoExpandGroupsIfNeeded()
            }
        }
        .onChange(of: state.strategyGroups.map(\.tag)) { _, _ in
            autoExpandGroupsIfNeeded()
        }
        .onChange(of: state.status.activeConfigId) { _, _ in
            didAutoExpandGroups = false
            autoExpandGroupsIfNeeded()
        }
        .onChange(of: sortOption) { _, newVal in
            sortNodesByDelay = (newVal == .lowestDelay)
        }
        .onChange(of: sourceOptions.map(\.id)) { _, ids in
            if selectedSourceID != "all" && !ids.contains(selectedSourceID) {
                selectedSourceID = "all"
            }
        }
    }
}

public struct NodeCardView: View {
    public var node: ProxyNode
    public var isSelected: Bool
    public var isTesting: Bool = false
    public var isSpeedTesting: Bool = false
    public var onSelect: () -> Void
    public var onTest: () -> Void
    public var onSpeedTest: () -> Void

    @AppStorage("showNodeBandwidthBadge") private var showNodeBandwidthBadge: Bool = true
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(node.protocolName.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(isSelected ? Color.blue.opacity(0.18) : Color.primary.opacity(0.06))
                    .foregroundStyle(isSelected ? Color.blue : Color.secondary)
                    .clipShape(.rect(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(isSelected ? Color.blue.opacity(0.3) : Color.primary.opacity(0.08), lineWidth: 0.5)
                    )

                Spacer()

                HStack(spacing: 5) {
                    if isHovered && !isTesting && !isSpeedTesting {
                        Button(action: onTest) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
						.accessibilityLabel("测试节点延迟")
                        .help("测试节点延迟 (Ping)")

                        Button(action: onSpeedTest) {
                            Image(systemName: "bolt")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.purple)
                        }
                        .buttonStyle(.plain)
						.accessibilityLabel("测试节点带宽")
                        .help("测试真实下行带宽吞吐 (Speedtest)")
                    }
                    LatencyBadge(delayMs: node.delayMs, isTesting: isTesting)
                }
            }

            Text(NodeNameSanitizer.clean(node.name))
                .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                .foregroundStyle(isSelected ? Color.blue : Color.primary)
                .lineLimit(2)
                .frame(height: 36, alignment: .topLeading)

            HStack(spacing: 6) {
                if let sub = node.subName, !sub.isEmpty {
                    Text(NodeNameSanitizer.clean(sub))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()

                // 3.2 真实带宽峰值徽章与测速状态
                if isSpeedTesting {
                    HStack(spacing: 3) {
                        ProgressView().controlSize(.mini)
                        Text("测速中...")
                            .font(.system(size: 9.5, weight: .semibold))
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.purple.opacity(0.12))
                    .foregroundStyle(.purple)
                    .clipShape(Capsule())
                } else if showNodeBandwidthBadge, let mbps = node.bandwidthMbps, mbps > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 8.5))
                        Text(String(format: "%.1f M", mbps))
                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.purple.opacity(0.12))
                    .foregroundStyle(.purple)
                    .clipShape(Capsule())
                    .help("真实下行峰值带宽: \(mbps) Mbps")
                }

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.blue)
                        .font(.system(size: 14))
                }
            }
        }
    }

    @ViewBuilder
    private var cardBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.blue.opacity(0.12))
        } else {
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
        }
    }

    private var cardBorder: some View {
        Group {
            if isSelected {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.blue.opacity(0.85), lineWidth: 1.5)
            } else {
                LiquidGlassBevelBorder(cornerRadius: 12, lineWidth: isHovered ? 1.0 : 0.8)
            }
        }
    }

    public var body: some View {
        Button(action: onSelect) {
            cardContent
                .padding(12)
                .background(cardBackground)
                .overlay(cardBorder)
                .shadow(color: isSelected ? Color.blue.opacity(0.15) : Color.black.opacity(0.04), radius: isHovered ? 6 : 2, y: 2)
                .scaleEffect(isHovered ? 1.01 : 1.0)
                .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.7), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("选择为活动节点") { onSelect() }
            Divider()
            Button("测试延迟 (Ping)") { onTest() }
            Button("测试真实峰值带宽 (Speedtest)") { onSpeedTest() }
        }
    }
}

// MARK: - 策略组成员精巧小卡片
public struct GroupNodeCard: View {
    public var tag: String
    public var node: ProxyNode?
    public var isSelector: Bool
    public var isSelected: Bool
    public var isTesting: Bool
    public var onSelect: () -> Void
    public var onTest: (() -> Void)? = nil

    @State private var isHovered = false

    private var isAutoNode: Bool {
        tag == "auto"
    }

    private var autoWinnerName: String? {
        AsterState.shared.autoWinnerName()
    }

    private var effectiveDelay: Int {
        AsterState.shared.memberDelay(for: tag)
    }

    private var accentColor: Color {
        isAutoNode ? Color.indigo : Color.blue
    }

    private var isBuiltinOutbound: Bool {
        !StrategyPresentation.canTest(tag: tag)
    }

    private var cardTitle: String {
        AsterState.shared.memberTitle(for: tag)
    }

    @ViewBuilder
    private var headerRow: some View {
        HStack(spacing: 4) {
            if isAutoNode {
                Text("AUTO")
                    .font(.system(size: 8.5, weight: .bold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1.5)
                    .background(isSelected ? Color.indigo : Color.indigo.opacity(0.15))
                    .foregroundColor(isSelected ? .white : .indigo)
                    .clipShape(Capsule())
            } else if isBuiltinOutbound {
                Text(tag == "direct" ? "直连" : "拦截")
                    .font(.system(size: 8.5, weight: .bold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1.5)
                    .background(isSelected ? Color.blue : Color.secondary.opacity(0.15))
                    .foregroundColor(isSelected ? .white : .secondary)
                    .clipShape(Capsule())
            } else if let proto = node?.protocolName, !proto.isEmpty {
                Text(proto.uppercased())
                    .font(.system(size: 8.5, weight: .bold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1.5)
                    .background(isSelected ? Color.blue : Color.secondary.opacity(0.15))
                    .foregroundColor(isSelected ? .white : .secondary)
                    .clipShape(Capsule())
            }
            Spacer()
            LatencyBadge(delayMs: effectiveDelay, isTesting: isTesting)
        }
    }

    @ViewBuilder
    private var nameRow: some View {
        HStack(spacing: 6) {
            Text(cardTitle)
                .font(.system(size: 11.5, weight: isSelected ? .bold : .medium))
                .foregroundColor(isSelected ? accentColor : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if let onTest, StrategyPresentation.canTest(tag: tag), !isTesting {
                Button("测试") { onTest() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.blue)
            }
        }
    }

    @ViewBuilder
    private var footerRow: some View {
        HStack {
            if isAutoNode {
                if let winner = autoWinnerName {
                    Text("➔ \(NodeNameSanitizer.clean(winner))")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundColor(isSelected ? Color.indigo.opacity(0.9) : .secondary)
                        .lineLimit(1)
                } else {
                    Text("内核智能测速")
                        .font(.system(size: 9.5))
                        .foregroundColor(.secondary.opacity(0.8))
                        .lineLimit(1)
                }
            } else if let sub = node?.subName, !sub.isEmpty {
                Text(NodeNameSanitizer.clean(sub))
                    .font(.system(size: 9.5))
                    .foregroundColor(.secondary.opacity(0.8))
                    .lineLimit(1)
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(accentColor)
            }
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(isSelected ? accentColor.opacity(0.12) : Color.primary.opacity(isHovered ? 0.05 : 0.025))
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 8)
            .strokeBorder(isSelected ? accentColor.opacity(0.75) : Color.primary.opacity(isHovered ? 0.15 : 0.08), lineWidth: isSelected ? 1.2 : 0.8)
    }

    public var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 6) {
                headerRow
                nameRow
                footerRow
            }
            .padding(8)
            .background(cardBackground)
            .overlay(cardBorder)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isSelector)
        .onHover { isHovered = $0 }
        .help(isAutoNode ? "自动测速并分流至最低延迟节点" : (isSelector ? "点击切换为当前使用节点" : "自动或策略分组（由内核自动决策）"))
    }
}
