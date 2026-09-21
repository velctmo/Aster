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

    private var sourceOptions: [(id: String, name: String)] {
        var seen = Set<String>()
        return state.nodes.compactMap { node in
            guard let id = node.subId, !id.isEmpty, id != "local", seen.insert(id).inserted else { return nil }
            return (id, node.subName?.isEmpty == false ? node.subName! : "订阅来源")
        }
    }

    private func membersForGroup(_ group: StrategyGroup) -> [String] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasFilter = !query.isEmpty || selectedSourceID != "all"

        // 1. 过滤：按搜索词与订阅来源
        let filtered = group.members.filter { tag in
            guard hasFilter else { return true }

            if tag == "auto" {
                return query.isEmpty && selectedSourceID == "all"
            }
            if tag == "direct" || tag == "reject" {
                if selectedSourceID != "all" { return false }
                guard !query.isEmpty else { return true }
                let label = tag == "direct" ? "直连" : "拦截"
                return label.localizedCaseInsensitiveContains(query) || tag.localizedCaseInsensitiveContains(query)
            }

            if let nestedGroup = state.strategyGroups.first(where: { $0.tag == tag }) {
                if selectedSourceID != "all" { return false }
                guard !query.isEmpty else { return true }
                return nestedGroup.name.localizedCaseInsensitiveContains(query) ||
                       nestedGroup.tag.localizedCaseInsensitiveContains(query)
            }

            guard let node = state.findNode(for: tag) else {
                guard !query.isEmpty else { return true }
                let memberTitle = state.memberTitle(for: tag)
                return memberTitle.localizedCaseInsensitiveContains(query) || tag.localizedCaseInsensitiveContains(query)
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

        // 2. 排序：按最低延迟优先或默认顺序
        switch sortOption {
        case .defaultOrder:
            return filtered
        case .lowestDelay:
            if !state.testingTags.isEmpty {
                return filtered
            }
            return filtered.sorted { a, b in
                let da = state.memberDelay(for: a)
                let db = state.memberDelay(for: b)
                if da > 0 && db > 0 { return da < db }
                if da > 0 && db <= 0 { return true }
                if da <= 0 && db > 0 { return false }
                if da == 0 && db < 0 { return true }
                if da < 0 && db == 0 { return false }
                return false
            }
        }
    }

    @ViewBuilder
    private var headerActions: some View {
        HStack(spacing: 10) {
            ExquisiteSearchField(placeholder: "搜索节点…", text: $searchText, maxWidth: 190)

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
            Text("请先在「配置」中添加订阅或导入节点")
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
        let members = membersForGroup(group)

        VStack(alignment: .leading, spacing: 0) {
            DisclosureGroup(isExpanded: expanded) {
                if members.isEmpty {
                    Text("无匹配节点")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 14)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 155, maximum: 230), spacing: 8)], spacing: 8) {
                        ForEach(members, id: \.self) { tag in
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
                }
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
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.right")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.secondary.opacity(0.6))
                            Text(currentLabel.truncated(toVisualWidth: 18))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.blue)

                            let activeTag = state.selectedTag(in: group)
                            let activeDelay = state.memberDelay(for: activeTag)
                            if activeDelay != 0 {
                                LatencyBadge(delayMs: activeDelay, isTesting: state.isNodeTesting(activeTag))
                            }
                        }
                    }

                    Spacer()

                    if !isGroupTesting {
                        if members.count != group.members.count {
                            Text("\(members.count) / \(group.members.count) 节点").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("\(group.leafTags.count) 节点").font(.caption).foregroundStyle(.secondary)
                        }
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
                    .buttonStyle(.exquisitePill(height: 22))
                    .disabled(!state.status.running || group.leafTags.isEmpty || isGroupTesting)
                }
                .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: AsterMetrics.radiusCard, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            NativeHairlineBorder(cornerRadius: AsterMetrics.radiusCard)
        )
        .shadow(color: Color.black.opacity(0.03), radius: 6, x: 0, y: 1.5)
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

    // MARK: - 顶置全局出站分流模式控制器 (规则判定 / 全局代理 / 直接连接)
    private var outboundModeBar: some View {
        HStack(spacing: 12) {
            ModeSegmentedControl(selectedMode: Binding(
                get: { state.status.mode },
                set: { state.setMode($0) }
            ))

            Spacer()

            let currentMode = AppMode.from(string: state.status.mode)
            HStack(spacing: 6) {
                Circle()
                    .fill(currentMode.color)
                    .frame(width: 6, height: 6)
                Text(currentMode.description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, DesignTokens.pagePadding)
        .padding(.vertical, 8)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.4))
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

// MARK: - 策略组成员精巧小卡片
public struct GroupNodeCard: View {
    @ObservedObject private var state = AsterState.shared
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
        state.autoWinnerName()
    }

    private var effectiveDelay: Int {
        state.memberDelay(for: tag)
    }

    private var accentColor: Color {
        isAutoNode ? Color.indigo : Color.blue
    }

    private var isBuiltinOutbound: Bool {
        !StrategyPresentation.canTest(tag: tag)
    }

    private var cardTitle: String {
        state.memberTitle(for: tag)
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
                ProtocolBadge(proto: proto, isSelected: isSelected)
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
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 8, weight: .bold))
                        Text(NodeNameSanitizer.clean(winner))
                            .lineLimit(1)
                    }
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundColor(isSelected ? Color.indigo.opacity(0.9) : .secondary)
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
        RoundedRectangle(cornerRadius: AsterMetrics.radiusControl, style: .continuous)
            .fill(isSelected ? accentColor.opacity(0.12) : Color.primary.opacity(isHovered ? 0.05 : 0.025))
    }

    @ViewBuilder
    private var cardBorder: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: AsterMetrics.radiusControl, style: .continuous)
                .strokeBorder(accentColor.opacity(0.75), lineWidth: 1.0)
        } else {
            NativeHairlineBorder(cornerRadius: AsterMetrics.radiusControl, lineWidth: isHovered ? 0.8 : 0.5)
        }
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
