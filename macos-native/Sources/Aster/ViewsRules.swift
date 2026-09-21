import SwiftUI
import AppKit

// MARK: - 统一分流规则表格行模型
public struct UnifiedRuleTableRow: Identifiable, Hashable {
    public let id: String
    public let matchType: String   // 全大写匹配类型: DOMAIN-SUFFIX, IP-CIDR, RULE-SET, etc.
    public let payload: String     // 规则内容 / 目标域名 / CIDR (保留特定大小写)
    public let action: String      // 执行动作 / 策略组: PROXY, DIRECT, REJECT, GOOGLE, etc.
    public let source: String      // 来源: USER (手动添加), SCRIPT (覆写脚本), SYSTEM (内置默认)
    public let hits: Int           // 命中统计
    public var isSystem: Bool { source == "SYSTEM" }
    public var isScript: Bool { source == "SCRIPT" }
    public var isUser: Bool { source == "USER" }
    public var priority: Int {
        switch source {
        case "SYSTEM": return 100
        case "USER": return 50
        case "SCRIPT": return 10
        default: return 0
        }
    }
}

public struct RulesView: View {
    private let state: AsterState
    @ObservedObject private var ruleStore: RuleStore
    @ObservedObject private var runtimeStore: RuntimeStore
    @State private var addRuleContext: AddRuleContext?
    @State private var searchText: String = ""
    @State private var selectedFilter: RuleFilter = .all
    @State private var selectedRuleId: UnifiedRuleTableRow.ID?
    @State private var sortOrder: [KeyPathComparator<UnifiedRuleTableRow>] = [
        .init(\.priority, order: .reverse),
        .init(\.matchType, order: .forward)
    ]

    @MainActor
    public init(state: AsterState? = nil) {
        let actual = state ?? .shared
        self.state = actual
        _ruleStore = ObservedObject(wrappedValue: actual.ruleStore)
        _runtimeStore = ObservedObject(wrappedValue: actual.runtimeStore)
    }

    public enum RuleFilter: String, CaseIterable, Identifiable {
        case all = "全部"
        case user = "手动添加"
        case script = "脚本覆写"
        case system = "系统内置"

        public var id: String { rawValue }
    }

    // 内置系统高优先级默认规则
    private var builtInSystemRules: [UnifiedRuleTableRow] {
        [
            UnifiedRuleTableRow(
                id: "system-private-1",
                matchType: "IP-IS-PRIVATE",
                payload: "局域网私有 IP (LAN 直连)",
                action: "DIRECT",
                source: "SYSTEM",
                hits: 0
            ),
            UnifiedRuleTableRow(
                id: "system-cn-2",
                matchType: "RULE-SET",
                payload: "geosite-cn / geoip-cn (中国大陆直连)",
                action: "DIRECT",
                source: "SYSTEM",
                hits: 0
            )
        ]
    }

    // 动态规则转换 (包含用户手动自建与覆写脚本动态注入的规则)
    private var dynamicRules: [UnifiedRuleTableRow] {
        ruleStore.rules.map { r in
            let formattedType: String = {
                let lower = r.match.lowercased()
                switch lower {
                case "domain": return "DOMAIN"
                case "domain_suffix", "domainsuffix": return "DOMAIN-SUFFIX"
                case "domain_keyword", "domainkeyword": return "DOMAIN-KEYWORD"
                case "ip_cidr", "ipcidr": return "IP-CIDR"
                case "geosite": return "GEOSITE"
                case "geoip": return "GEOIP"
                case "process_name", "processname": return "PROCESS-NAME"
                case "process_path", "processpath": return "PROCESS-PATH"
                case "rule_set", "ruleset": return "RULE-SET"
                default: return r.match.uppercased().replacingOccurrences(of: "_", with: "-")
                }
            }()

            let ruleSource = (r.source ?? (r.id.hasPrefix("live-script-") ? "SCRIPT" : "USER")).uppercased()

            let trimmedAction = r.action.trimmingCharacters(in: .whitespaces)
            let displayAction: String = {
                switch trimmedAction.lowercased() {
                case "direct": return "DIRECT"
                case "reject": return "REJECT"
                case "proxy": return "PROXY"
                default: return trimmedAction
                }
            }()

            return UnifiedRuleTableRow(
                id: r.id,
                matchType: formattedType,
                payload: r.value,
                action: displayAction,
                source: ruleSource,
                hits: r.hits ?? 0
            )
        }
    }

    private var allRules: [UnifiedRuleTableRow] {
        // 如果后端已返回系统内置规则，则不再重复追加
        let hasSystemInBackend = dynamicRules.contains { $0.isSystem }
        return (hasSystemInBackend ? [] : builtInSystemRules) + dynamicRules
    }

    private var filteredRules: [UnifiedRuleTableRow] {
        allRules.filter { r in
            let matchesFilter: Bool = {
                switch selectedFilter {
                case .all: return true
                case .user: return r.isUser
                case .script: return r.isScript
                case .system: return r.isSystem
                }
            }()
            guard matchesFilter else { return false }

            if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                return true
            }
            let q = searchText.lowercased()
            return r.matchType.lowercased().contains(q)
                || r.payload.lowercased().contains(q)
                || r.action.lowercased().contains(q)
        }
        .sorted(using: sortOrder)
    }

    public var body: some View {
        let visibleRules = filteredRules
        VStack(spacing: 0) {
            // 顶栏 Header
            PageHeader(title: "规则") {
                HStack(spacing: 12) {
                    if runtimeStore.status.activeConfigKind == "subscription" {
                        Text("当前为完整订阅配置 (只读模式)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    Button(action: {
                        addRuleContext = AddRuleContext.forCustom()
                    }) {
                        Label("添加规则", systemImage: "plus")
                    }
                    .buttonStyle(.exquisitePrimary)
                    .disabled(runtimeStore.status.activeConfigKind == "subscription")
                }
            }

            Divider().opacity(0.4)

            // 搜索与过滤工具栏
            HStack(spacing: 12) {
                // 搜索框
                ExquisiteSearchField(placeholder: "搜索类型、域名、IP 或策略…", text: $searchText)

                Picker("过滤", selection: $selectedFilter) {
                    ForEach(RuleFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)

                Spacer()

                Text("\(visibleRules.count) 条规则")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .background(Color.primary.opacity(0.015))

            Divider().opacity(0.3)

            // 原生 Table 数据表格 (IDE 代码编辑器质感)
            if visibleRules.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 38))
                        .foregroundStyle(.secondary.opacity(0.4))
                    Text(searchText.isEmpty ? "暂无匹配规则" : "未找到包含「\(searchText)」的规则")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(visibleRules, selection: $selectedRuleId, sortOrder: $sortOrder) {
                    TableColumn("类型", value: \.matchType) { rule in
                        Text(rule.matchType)
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2.5)
                            .background(Color.primary.opacity(0.045))
                            .foregroundStyle(.primary.opacity(0.85))
                            .clipShape(.rect(cornerRadius: 4))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                            )
                    }
                    .width(min: 110, ideal: 135, max: 170)

                    TableColumn("匹配规则 / 内容", value: \.payload) { rule in
                        Text(rule.payload)
                            .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .textSelection(.enabled)
                    }
                    .width(min: 240, ideal: 380)

                    TableColumn("执行策略", value: \.action) { rule in
                        ActionBadge(action: rule.action)
                    }
                    .width(min: 90, ideal: 125, max: 180)

                    TableColumn("来源") { rule in
                        let (labelText, bgCol, textCol): (String, Color, Color) = {
                            switch rule.source {
                            case "SCRIPT":
                                return ("脚本", Color.purple.opacity(0.12), Color.purple)
                            case "USER":
                                return ("用户", Color.blue.opacity(0.12), Color.blue)
                            default:
                                return ("内置", Color.primary.opacity(0.05), Color.secondary)
                            }
                        }()
                        Text(labelText)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(textCol)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(bgCol)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .strokeBorder(textCol.opacity(0.25), lineWidth: 0.5)
                            )
                    }
                    .width(min: 55, ideal: 65, max: 80)

                    TableColumn("操作") { rule in
                        if rule.isUser && runtimeStore.status.activeConfigKind != "subscription" {
                            HStack(spacing: 8) {
                                Button {
                                    openEditRule(rule)
                                } label: {
                                    Label("编辑规则", systemImage: "pencil")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.plain)
                                .help("编辑规则")

                                Button(role: .destructive) {
                                    state.deleteRule(id: rule.id)
                                } label: {
                                    Label("删除规则", systemImage: "trash")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color(red: 0.85, green: 0.38, blue: 0.38))
                                }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.plain)
                                .help("删除规则")
                            }
                        } else {
                            Text("只读")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary.opacity(0.6))
                        }
                    }
                    .width(min: 60, ideal: 70, max: 80)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .contextMenu(forSelectionType: UnifiedRuleTableRow.ID.self) { items in
                    if let id = items.first, let rule = allRules.first(where: { $0.id == id }) {
                        if !rule.isSystem && runtimeStore.status.activeConfigKind != "subscription" {
                            Button {
                                openEditRule(rule)
                            } label: {
                                Label("编辑规则", systemImage: "pencil")
                            }
                        }

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(rule.payload, forType: .string)
                        } label: {
                            Label("复制匹配内容", systemImage: "doc.on.doc")
                        }

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("\(rule.matchType),\(rule.payload),\(rule.action)", forType: .string)
                        } label: {
                            Label("复制整行规则", systemImage: "doc.on.clipboard")
                        }

                        if !rule.isSystem && runtimeStore.status.activeConfigKind != "subscription" {
                            Divider()
                            Button(role: .destructive) {
                                state.deleteRule(id: rule.id)
                            } label: {
                                Label("删除规则", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .sheet(item: $addRuleContext) { ctx in
            AddRuleModalView(context: ctx) {
                addRuleContext = nil
            }
        }
    }

    private func openEditRule(_ rule: UnifiedRuleTableRow) {
        let ruleType: AddRuleType = {
            switch rule.matchType {
            case "DOMAIN": return .domain
            case "DOMAIN-KEYWORD": return .domainKeyword
            case "IP-CIDR": return .ipCIDR
            case "PROCESS-NAME": return .processName
            case "PROCESS-PATH": return .processPath
            default: return .domainSuffix
            }
        }()
        addRuleContext = AddRuleContext.forCustom(type: ruleType, value: rule.payload, action: rule.action.uppercased())
    }
}
