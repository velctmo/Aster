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
                    for g in state.strategyGroups {
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

    /// 过滤后的用户可视策略组（隐藏底层仅作单跳别名的 proxy 兼容组以及内部 URLTest 测速池）
    private var displayStrategyGroups: [StrategyGroup] {
        state.strategyGroups.filter { group in
            // 如果 tag 为 "proxy"，且仅有 1 个成员，并且该成员本身就是另一个策略组，则作为底层别名隐藏
            if (group.tag == "proxy" || group.name == "proxy") && group.members.count == 1 {
                let target = group.members[0]
                if state.strategyGroups.contains(where: { $0.tag == target }) {
                    return false
                }
            }
            // 如果存在上层 selector 包含 auto，并且当前组 tag 为 "auto" (urltest)，则作为底层测速池隐藏，避免界面出现全置灰卡片
            if group.tag == "auto" && group.type == "urltest" {
                let hasSelectorParent = state.strategyGroups.contains(where: { $0.type == "selector" && $0.members.contains("auto") })
                if hasSelectorParent {
                    return false
                }
            }
            return true
        }
    }

    /// 智能解析当前系统的主出站策略组 (如「🚀 节点选择」)
    private var primaryOutboundGroup: StrategyGroup? {
        let rawProxyGroup = state.strategyGroups.first(where: { $0.tag == "proxy" || $0.name == "proxy" })
        if let p = rawProxyGroup, p.members.count == 1, let targetGroup = state.strategyGroups.first(where: { $0.tag == p.members[0] }) {
            return targetGroup
        }
        if let selectorGroup = displayStrategyGroups.first(where: { $0.type == "selector" && ($0.tag.contains("选择") || $0.tag.contains("Proxy")) }) {
            return selectorGroup
        }
        return displayStrategyGroups.first(where: { $0.type == "selector" }) ?? rawProxyGroup
    }

    @ViewBuilder
    private var nodesGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // 1. 顶部 Hero 主代理出口看板卡片
                primaryOutboundHeroCard

                // 2. 策略组列表 (过滤内部包装层，保留用户定义的策略组完整排列)
                ForEach(displayStrategyGroups) { group in
                    strategyGroupSection(group)
                }
            }
            .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
    }

    /// 顶部主代理通道的高规格 Hero 状态卡片
    @ViewBuilder
    private var primaryOutboundHeroCard: some View {
        let pGroup = primaryOutboundGroup
        let activeTag = pGroup?.now ?? state.status.selected
        let isAuto = (activeTag == "auto" || state.status.selected == "auto")
        let activeNode = state.nodes.first(where: { $0.tag == activeTag })
        let rawName: String = {
            if isAuto {
                if !state.status.selectedLabel.isEmpty { return state.status.selectedLabel }
                if let autoGroup = state.strategyGroups.first(where: { $0.tag == "auto" }), let now = autoGroup.now, !now.isEmpty {
                    let win = state.findNode(for: now)?.name ?? now
                    return "自动选择 ➔ \(win)"
                }
                return "自动选择"
            }
            if let node = activeNode { return node.name }
            if !state.status.selectedLabel.isEmpty { return state.status.selectedLabel }
            return activeTag.isEmpty ? "未选择节点" : activeTag
        }()
        let cleanName = NodeNameSanitizer.clean(rawName)

        HStack(alignment: .center, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.blue.opacity(0.12))
                    .frame(width: 44, height: 44)
                Image(systemName: "globe.asia.australia.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.blue)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("当前主代理出站")
                        .font(.system(size: 14, weight: .bold))

                    if let group = pGroup {
                        Text(group.name)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundColor(.blue)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                        Text(group.type.uppercased())
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                }

                HStack(spacing: 8) {
                    Text(cleanName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    if isAuto {
                        let autoDelay = state.strategyGroups.first(where: { $0.tag == "auto" })?.delayMs ?? state.status.delayMs
                        if autoDelay > 0 {
                            Text("\(autoDelay) ms")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(autoDelay <= 150 ? .green : (autoDelay <= 500 ? .orange : .red))
                        } else if state.isNodeTesting("auto") {
                            Text("测速中…")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.blue)
                        }
                    } else if let node = activeNode {
                        if node.delayMs > 0 {
                            Text("\(node.delayMs) ms")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(node.delayMs <= 150 ? .green : (node.delayMs <= 500 ? .orange : .red))
                        } else if node.delayMs < 0 {
                            Text("超时")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(.red)
                        }
                    } else if let gDelay = pGroup?.delayMs, gDelay > 0 {
                        Text("\(gDelay) ms")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(gDelay <= 150 ? .green : (gDelay <= 500 ? .orange : .red))
                    } else if state.status.delayMs > 0 {
                        Text("\(state.status.delayMs) ms")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(state.status.delayMs <= 150 ? .green : (state.status.delayMs <= 500 ? .orange : .red))
                    }
                }
            }

            Spacer()

            if let targetGroup = pGroup {
                let isGroupTesting = targetGroup.leafTags.contains { state.testingTags.contains($0) } || state.testingTags.contains(targetGroup.tag)
                Button {
                    expandedGroupTags.insert(targetGroup.tag)
                    state.testStrategyGroup(targetGroup)
                } label: {
                    HStack(spacing: 4) {
                        if isGroupTesting {
                            ProgressView().controlSize(.mini).frame(width: 10, height: 10)
                            Text("测速中…")
                        } else {
                            Image(systemName: "bolt.fill")
                            Text("测速主出口")
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(!state.status.running || targetGroup.leafTags.isEmpty || isGroupTesting)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
        )
        .padding(.horizontal, DesignTokens.pagePadding)
    }

    @ViewBuilder
    private func strategyGroupSection(_ group: StrategyGroup) -> some View {
        let isGroupTesting = group.leafTags.contains { state.testingTags.contains($0) }
        let expanded = Binding(
            get: { expandedGroupTags.contains(group.tag) },
            set: { value in if value { expandedGroupTags.insert(group.tag) } else { expandedGroupTags.remove(group.tag) } }
        )

        // 解析当前策略组选中的节点
        let selectedTagInGroup = group.now ?? ((group.tag == "proxy" || group.tag == state.status.selected) ? state.status.selected : "")
        let selectedNode = state.findNode(for: selectedTagInGroup)
        let currentLabel: String = {
            if selectedTagInGroup == "auto" {
                if let autoGroup = state.strategyGroups.first(where: { $0.tag == "auto" }), let now = autoGroup.now, !now.isEmpty {
                    let win = state.findNode(for: now)?.name ?? now
                    return "自动 ➔ \(NodeNameSanitizer.clean(win))"
                }
                return "自动优选"
            }
            return NodeNameSanitizer.clean(selectedNode?.name ?? selectedTagInGroup)
        }()

        VStack(alignment: .leading, spacing: 0) {
            DisclosureGroup(isExpanded: expanded) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 155, maximum: 230), spacing: 8)], spacing: 8) {
                    ForEach(group.members, id: \.self) { tag in
                        let node = state.findNode(for: tag)
                        let isCurrentSelected = (tag == selectedTagInGroup)
                        GroupNodeCard(
                            tag: tag,
                            node: node,
                            isSelector: group.type == "selector",
                            isSelected: isCurrentSelected,
                            isTesting: state.isNodeTesting(tag),
                            onSelect: {
                                if group.type == "selector" {
                                    state.selectStrategyGroupNode(group: group, tag: tag)
                                }
                            }
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

                    if isGroupTesting {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                            Text("正在测速…")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.blue)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(4)
                    } else {
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

            if state.strategyGroups.isEmpty {
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
			Task { await state.fetchStrategyGroups() }
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

    @State private var isHovered = false

    private var isAutoNode: Bool {
        tag == "auto"
    }

    private var autoWinnerName: String? {
        guard isAutoNode else { return nil }
        if let autoGroup = AsterState.shared.strategyGroups.first(where: { $0.tag == "auto" }), let now = autoGroup.now, !now.isEmpty {
            return AsterState.shared.findNode(for: now)?.name ?? now
        }
        return nil
    }

    private var effectiveDelay: Int {
        if isAutoNode {
            let gDelay = AsterState.shared.strategyGroups.first(where: { $0.tag == "auto" })?.delayMs ?? 0
            if gDelay > 0 { return gDelay }
            return AsterState.shared.status.delayMs
        }
        return node?.delayMs ?? 0
    }

    private var accentColor: Color {
        isAutoNode ? Color.indigo : Color.blue
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
        let title = isAutoNode ? "♻️ 自动优选" : NodeNameSanitizer.clean(node?.name ?? tag)
        Text(title)
            .font(.system(size: 11.5, weight: isSelected ? .bold : .medium))
            .foregroundColor(isSelected ? accentColor : .primary)
            .lineLimit(1)
            .truncationMode(.tail)
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
