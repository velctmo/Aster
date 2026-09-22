import SwiftUI
import AppKit

public struct OverridesManagementView: View {
    @ObservedObject private var state = AsterState.shared
    @State private var selectedScriptId: String? = nil
    @State private var showingNewSheet = false
    @State private var searchText = ""

    public init(selectedScriptId: String? = nil) {
        self._selectedScriptId = State(initialValue: selectedScriptId)
    }

    private var filteredScripts: [ScriptItem] {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return state.scripts
        }
        return state.scripts.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    public var body: some View {
        HSplitView {
            // 左栏：脚本资产列表
            VStack(spacing: 0) {
                // 搜索栏与新建
                HStack(spacing: 8) {
                    ExquisiteSearchField(placeholder: "搜索脚本…", text: $searchText)

                    Button {
                        showingNewSheet = true
                    } label: {
                        Label("新建覆写脚本", systemImage: "plus")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.exquisitePrimary)
                    .help("新建覆写脚本")
                }
                .padding(12)

                Divider().opacity(0.3)

                if state.scripts.isEmpty {
                    AsterEmptyState(
                        icon: "curlybraces",
                        title: "暂无覆写脚本",
                        subtitle: "点击右上角 + 或下方按钮创建您的第一个覆写规则",
                        actionTitle: "新建脚本"
                    ) {
                        showingNewSheet = true
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $selectedScriptId) {
                        ForEach(filteredScripts) { script in
                            let count = state.configs.filter { $0.scriptId == script.id }.count
                            ScriptListRow(script: script, selectedId: selectedScriptId, usedCount: count)
                                .tag(script.id)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        deleteScript(script)
                                    } label: {
                                        Label("删除脚本", systemImage: "trash")
                                    }
                                }
                        }
                    }
                    .listStyle(.sidebar)
                }
            }
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)

            // 右栏：脚本代码编辑器与配置
            if let activeId = selectedScriptId, let script = state.scripts.first(where: { $0.id == activeId }) {
                ScriptDetailEditorView(script: script)
                    .id(script.id)
            } else {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary.opacity(0.4))
                    Text("请选择或新建一个覆写脚本")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            await state.fetchScripts()
            if selectedScriptId == nil, let first = state.scripts.first {
                selectedScriptId = first.id
            }
        }
        .sheet(isPresented: $showingNewSheet) {
            NewScriptSheet(isPresented: $showingNewSheet, onCreated: { newId in
                selectedScriptId = newId
            })
        }
    }

    private func deleteScript(_ script: ScriptItem) {
        let alert = NSAlert()
        alert.messageText = "确认删除脚本「\(script.name)」？"
        alert.informativeText = "删除后，所有引用该脚本的订阅配置将自动解绑并恢复为无覆写状态。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            Task {
                do {
                    try await state.deleteScript(id: script.id)
                    if selectedScriptId == script.id {
                        selectedScriptId = state.scripts.first?.id
                    }
                } catch {
                    let errAlert = NSAlert()
                    errAlert.messageText = "删除覆写脚本失败"
                    errAlert.informativeText = error.localizedDescription
                    errAlert.alertStyle = .critical
                    errAlert.runModal()
                }
            }
        }
    }
}

private struct ScriptListRow: View {
    let script: ScriptItem
    let selectedId: String?
    let usedCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(script.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Spacer()
                if usedCount > 0 {
                    Text("\(usedCount) 配置使用")
                        .font(.system(size: 9.5, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.accentColor.opacity(0.12))
                        .foregroundColor(.accentColor)
                        .clipShape(Capsule())
                }
            }

            HStack {
                Text(script.kind == "nodes" ? "节点清洗与策略组" : "完整配置与策略组")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Spacer()
                if script.updatedAt > 0 {
                    Text(Date(timeIntervalSince1970: TimeInterval(script.updatedAt)).formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.7))
                }
            }
        }
        .padding(.vertical, 3)
    }
}

public enum ScriptEditMode: String, CaseIterable, Identifiable {
    case visual = "表单构建器"
    case code = "代码编辑器"

    public var id: String { rawValue }
}

// 表单模式自定义策略组与分流规则模型
public struct CustomGroupFormItem: Identifiable {
    public var id = UUID().uuidString
    public var name: String
    public var type: String // "urltest" 或 "selector"
    public var matchKeyword: String // 正则/关键词匹配，空则为所有节点

    public init(name: String, type: String = "urltest", matchKeyword: String = "") {
        self.name = name
        self.type = type
        self.matchKeyword = matchKeyword
    }
}

public struct CustomRuleFormItem: Identifiable {
    public var id = UUID().uuidString
    public var matchType: String // "domain_suffix", "domain_keyword", "ip_cidr"
    public var value: String
    public var targetOutbound: String // "direct", "reject", 或策略组名

    public init(matchType: String = "domain_suffix", value: String = "", targetOutbound: String = "direct") {
        self.matchType = matchType
        self.value = value
        self.targetOutbound = targetOutbound
    }
}

public struct ScriptDetailEditorView: View {
    let script: ScriptItem
    @ObservedObject private var state = AsterState.shared

    @State private var name: String
    @State private var content: String
    @State private var editMode: ScriptEditMode = .code
    @State private var isSaving = false
    @State private var errorMessage: String? = nil
    @State private var saveSuccessMessage: String? = nil

    // 常用地区快捷预设 (默认不勾选，由用户按需选择)
    @State private var enableAutoHK = false
    @State private var enableAutoJP = false
    @State private var enableAutoUS = false
    @State private var enableAutoSG = false
    @State private var enableAutoTW = false
    @State private var enableAutoUK = false
    @State private var enableAutoDE = false
    @State private var enableAutoKR = false

    // sing-box 原生架构增强 (进阶特性)
    @State private var enableUTLS = false
    @State private var enableMultiplex = false
    @State private var enableNodeClean = false
    @State private var enableSmartDNS = false

    // 常用业务场景分流预设
    @State private var enableAIGroup = false
    @State private var enableStreamingGroup = false
    @State private var enableTelegramGroup = false
    @State private var enableAdBlock = false

    // 动态策略组列表 (纯净初始状态，无写死假数据)
    @State private var customGroups: [CustomGroupFormItem] = []

    // 动态分流规则列表 (纯净初始状态，无写死假数据)
    @State private var customRules: [CustomRuleFormItem] = []

    public init(script: ScriptItem) {
        self.script = script
        self._name = State(initialValue: script.name)
        self._content = State(initialValue: script.content)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 顶栏：元数据、双模切换与保存
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    TextField("脚本名称", text: $name)
                        .font(.system(size: 14, weight: .bold))
                        .textFieldStyle(.plain)

                    HStack(spacing: 8) {
                        Text(script.kind == "nodes" ? "模式: 节点清洗与策略组（transformNodes / main）" : "模式: 完整配置与策略组（main）")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                // 双模切换器
                Picker("", selection: $editMode) {
                    ForEach(ScriptEditMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)

                if let saveSuccessMessage {
                    Text(saveSuccessMessage)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.green)
                }

                if editMode == .code {
                    Menu {
                        Button {
                            applyTemplate(ScriptTemplates.fullFeaturedRuleSets, name: "全能规则集分流")
                        } label: {
                            Label("全能规则集分流 (Remote Rule-Sets)", systemImage: "arrow.triangle.branch")
                        }
                        Button {
                            applyTemplate(ScriptTemplates.subStoreGroups, name: "多区域测速优选")
                        } label: {
                            Label("多区域测速优选 (Sub-Store 风格)", systemImage: "globe.asia.australia.fill")
                        }
                        Button {
                            applyTemplate(ScriptTemplates.smartFakeIPDNS, name: "智能 FakeIP 与双轨 DoH")
                        } label: {
                            Label("智能 FakeIP 与双轨 DoH DNS", systemImage: "shield.lefthalf.filled")
                        }
                        Button {
                            applyTemplate(ScriptTemplates.nodeOptimizer, name: "协议优化与 uTLS 伪装")
                        } label: {
                            Label("协议优化与 uTLS 伪装 (Chrome 指纹)", systemImage: "bolt.badge.shield.half.filled")
                        }
                        Button {
                            applyTemplate(ScriptTemplates.adBlockAndPrivacy, name: "轻量广告与隐私拦截")
                        } label: {
                            Label("轻量广告与隐私拦截 (AdBlock)", systemImage: "xmark.shield.fill")
                        }
                        Divider()
                        Button {
                            applyTemplate(ScriptTemplates.blankStarter, name: "纯净空白骨架")
                        } label: {
                            Label("纯净空白骨架 (Minimal Starter)", systemImage: "doc.plaintext")
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                            Text("载入预设模版")
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .buttonStyle(.exquisiteSecondary(height: 24))
                    .help("载入基于 sing-box 原生优势的生产级配置覆写模版")
                }

                Button {
                    save()
                } label: {
                    HStack(spacing: 4) {
                        if isSaving {
                            ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                        } else {
                            Image(systemName: "checkmark")
                        }
                        Text("保存并生效")
                    }
                }
                .buttonStyle(.exquisitePrimary)
                .disabled(isSaving)
                .keyboardShortcut("s", modifiers: .command)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))

            Divider().opacity(0.3)

            // 内容区：表单生成模式 vs 代码编辑模式
            if editMode == .visual {
                visualFormView
            } else {
                codeEditorView
            }
        }
    }

    // 表单可视化生成模式
    private var visualFormView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // 1. 自动地区分组快捷勾选
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "globe.asia.australia.fill").foregroundColor(.blue)
                        Text("常用地区自动分组 (一键生成 URLTest)").font(.system(size: 13, weight: .bold))
                    }
                    Text("勾选后系统将根据节点名称中的地区特征，自动聚合生成对应地区的自动测速优选策略组。")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
                        Toggle("香港自动优选 (HK)", isOn: $enableAutoHK)
                        Toggle("日本自动优选 (JP)", isOn: $enableAutoJP)
                        Toggle("美国自动优选 (US)", isOn: $enableAutoUS)
                        Toggle("新加坡自动优选 (SG)", isOn: $enableAutoSG)
                        Toggle("台湾自动优选 (TW)", isOn: $enableAutoTW)
                        Toggle("英国自动优选 (UK)", isOn: $enableAutoUK)
                        Toggle("德国自动优选 (DE)", isOn: $enableAutoDE)
                        Toggle("韩国自动优选 (KR)", isOn: $enableAutoKR)
                    }
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                }
                .asterSubcard(padding: 14)

                // 2. sing-box 原生特性与协议增强
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "bolt.badge.shield.half.filled").foregroundColor(.purple)
                        Text("sing-box 原生特性与协议增强").font(.system(size: 13, weight: .bold))
                    }
                    Text("充分利用 sing-box 1.10+ 高性能架构特性，自动注入真实浏览器指纹与 FakeIP 加速。")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 10)], spacing: 10) {
                        Toggle("uTLS Chrome 真实指纹", isOn: $enableUTLS)
                            .help("自动为 TLS 出站节点注入 Chrome 浏览器原生 TLS 指纹，防止主动探测")
                        Toggle("H2Mux 多路复用 (4 并发流)", isOn: $enableMultiplex)
                            .help("启用 TCP/TLS 连接复用，大幅减少高频并发与网页浏览时的连接握手耗时")
                        Toggle("节点名称净化 (去广告与倍率)", isOn: $enableNodeClean)
                            .help("自动去除节点名称中的推广链接、群组信息及倍率标签，保持状态栏清爽")
                        Toggle("智能 FakeIP 与双轨 DoH", isOn: $enableSmartDNS)
                            .help("注入 198.18.0.0/15 地址池与 DNS 劫持规则，国内走阿里 DNS，海外代理走加密 DoH")
                    }
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                }
                .asterSubcard(padding: 14)

                // 3. 常用业务分流预设 (基于二进制 .srs 规则集)
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "arrow.triangle.branch").foregroundColor(.teal)
                        Text("常用业务场景分流 (原生二进制规则集)").font(.system(size: 13, weight: .bold))
                    }
                    Text("采用 sing-box 原生二进制 .srs 规则集分流，毫秒级规则匹配且不增加额外内存占用。")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 10)], spacing: 10) {
                        Toggle("🤖 AI 平台分流 (OpenAI/Claude)", isOn: $enableAIGroup)
                            .help("自动引入 OpenAI 与 Anthropic 规则集并指派独立策略组")
                        Toggle("🎬 国际媒体分流 (YouTube/Netflix)", isOn: $enableStreamingGroup)
                            .help("自动引入 YouTube 与 Netflix 规则集并指派国际媒体策略组")
                        Toggle("📲 Telegram 独立分流", isOn: $enableTelegramGroup)
                            .help("自动识别电报域名与全球数据中心 IP 并分流")
                        Toggle("🛑 广告与追踪域名拦截 (REJECT)", isOn: $enableAdBlock)
                            .help("自动加载全量广告规则集并直接阻断丢弃，净化网页浏览体验")
                    }
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                }
                .asterSubcard(padding: 14)

                // 4. 动态自定义策略组构建区
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "square.stack.3d.up.fill").foregroundColor(.purple)
                        Text("自定义策略组构建器").font(.system(size: 13, weight: .bold))
                        Spacer()
                        Button {
                            customGroups.append(CustomGroupFormItem(name: "策略组\(customGroups.count + 1)", type: "urltest", matchKeyword: ""))
                        } label: {
                            Label("添加策略组", systemImage: "plus")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.exquisiteSecondary(height: 24))
                    }

                    Text("自由创建需要的策略组，可设定为【自动测速优选】或【手动选择】，并配置节点过滤关键词。")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    if customGroups.isEmpty {
                        AsterEmptyState(
                            icon: "square.stack.3d.up",
                            title: "暂无自定义策略组",
                            subtitle: "点击右上角「添加策略组」自由构建出站策略"
                        )
                        .padding(.vertical, 8)
                    } else {
                        VStack(spacing: 8) {
                            ForEach($customGroups) { $group in
                                HStack(spacing: 10) {
                                    TextField("策略组名称 (如: AI 或 国际流媒体)", text: $group.name)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 170)

                                    Picker("", selection: $group.type) {
                                        Text("自动优选 (urltest)").tag("urltest")
                                        Text("手动选择 (selector)").tag("selector")
                                    }
                                    .labelsHidden()
                                    .frame(width: 150)

                                    TextField("节点匹配关键词/正则 (留空为全部)", text: $group.matchKeyword)
                                        .textFieldStyle(.roundedBorder)

                                    Button {
                                        if let idx = customGroups.firstIndex(where: { $0.id == group.id }) {
                                            customGroups.remove(at: idx)
                                        }
                                    } label: {
                                        Image(systemName: "trash").foregroundColor(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .help("删除此策略组")
                                }
                                .padding(8)
                                .background(Color.primary.opacity(0.02))
                                .cornerRadius(6)
                            }
                        }
                    }
                }
                .asterSubcard(padding: 14)

                // 5. 动态分流规则构建区
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "arrow.triangle.branch").foregroundColor(.green)
                        Text("自定义路由分流规则").font(.system(size: 13, weight: .bold))
                        Spacer()
                        Button {
                            customRules.append(CustomRuleFormItem(matchType: "domain_suffix", value: "", targetOutbound: "direct"))
                        } label: {
                            Label("添加分流规则", systemImage: "plus")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.exquisiteSecondary(height: 24, cornerRadius: AsterMetrics.radiusControl))
                    }

                    Text("自定义匹配条件并指派出口，可分流至直连、阻止或上述任意创建的策略组。")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    if customRules.isEmpty {
                        AsterEmptyState(
                            icon: "arrow.triangle.branch",
                            title: "暂无自定义分流规则",
                            subtitle: "点击右上角「添加分流规则」指派域名或 IP 出口"
                        )
                        .padding(.vertical, 8)
                    } else {
                        VStack(spacing: 8) {
                            ForEach($customRules) { $rule in
                                HStack(spacing: 8) {
                                    Picker("", selection: $rule.matchType) {
                                        Text("域名后缀").tag("domain_suffix")
                                        Text("域名关键字").tag("domain_keyword")
                                        Text("IP-CIDR").tag("ip_cidr")
                                    }
                                    .labelsHidden()
                                    .frame(width: 110)

                                    TextField("输入匹配目标 (如 github.com，多个用逗号隔开)", text: $rule.value)
                                        .textFieldStyle(.roundedBorder)

                                    Image(systemName: "arrow.right")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(.secondary.opacity(0.7))

                                    Picker("", selection: $rule.targetOutbound) {
                                        Text("直连 (direct)").tag("direct")
                                        Text("阻止 (reject)").tag("reject")
                                        Text("节点选择 (proxy)").tag("proxy")
                                        ForEach(customGroups) { g in
                                            if !g.name.isEmpty {
                                                Text(g.name).tag(g.name)
                                            }
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(width: 130)

                                    Button {
                                        if let idx = customRules.firstIndex(where: { $0.id == rule.id }) {
                                            customRules.remove(at: idx)
                                        }
                                    } label: {
                                        Image(systemName: "trash").foregroundColor(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .help("删除此规则")
                                }
                                .padding(8)
                                .background(Color.primary.opacity(0.02))
                                .cornerRadius(6)
                            }
                        }
                    }
                }
                .asterSubcard(padding: 14)

                // 底部操作：编译为代码
                HStack {
                    Button {
                        generateCodeFromForm()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "wand.and.stars")
                            Text("生成规范 JavaScript 脚本并查看代码")
                        }
                    }
                    .buttonStyle(.exquisitePrimary)

                    Spacer()
                }
                .padding(.top, 4)
            }
            .padding(18)
        }
    }

    // 代码编辑器模式
    private var codeEditorView: some View {
        ZStack(alignment: .bottomLeading) {
            TextEditor(text: $content)
                .font(.system(size: 12, design: .monospaced))
                .padding(12)
                .scrollContentBackground(.hidden)
                .background(Color(NSColor.textBackgroundColor))

            if let errorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .font(.system(size: 12))
                    Text(errorMessage)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.red)
                        .lineLimit(3)
                    Spacer()
                    Button {
                        self.errorMessage = nil
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(10)
                .background(Color.red.opacity(0.12))
                .cornerRadius(6)
                .padding(12)
            }
        }
    }

    private func generateCodeFromForm() {
        var code = """
/**
 * 由 Aster 表单构建器生成的覆写脚本
 * 生成时间: \(Date().formatted(date: .abbreviated, time: .shortened))
 *
 * 充分利用 sing-box 原生优势：策略组编排、规则集分流、uTLS 指纹与 FakeIP。
 */

function main(config) {
  config = config || {};
  config.outbounds = config.outbounds || [];
  config.route = config.route || {};
  config.route.rules = config.route.rules || [];

  const reserved = new Set(['direct', 'proxy', 'auto', 'reject', 'block', 'dns']);

"""

        if enableNodeClean {
            code += """
  // 1. 净化节点名称
  for (var i = 0; i < config.outbounds.length; i++) {
    var out = config.outbounds[i];
    if (out && out.tag && !reserved.has(out.tag) && !['selector', 'urltest', 'fallback'].includes(out.type)) {
      out.tag = out.tag
        .replace(/\\[\\d+(\\.\\d+)?x\\]/gi, '')
        .replace(/\\|\\s*倍率[:：]?\\s*\\d+(\\.\\d+)?/gi, '')
        .replace(/(官网|地址|群组|频道|发布页)[:：]?\\s*\\S+/gi, '')
        .replace(/\\s+/g, ' ')
        .trim();
    }
  }

"""
        }

        if enableUTLS || enableMultiplex {
            code += """
  // 2. 协议优化与指纹伪装
  const tlsProtocols = new Set(['vmess', 'vless', 'trojan', 'shadowtls']);
  const muxProtocols = new Set(['vmess', 'vless', 'trojan']);
  for (var i = 0; i < config.outbounds.length; i++) {
    var out = config.outbounds[i];
    if (!out || !out.type) continue;
"""
            if enableUTLS {
                code += """
    if (tlsProtocols.has(out.type)) {
      out.tls = out.tls || {};
      out.tls.enabled = true;
      out.tls.utls = { enabled: true, fingerprint: 'chrome' };
    }
"""
            }
            if enableMultiplex {
                code += """
    if (muxProtocols.has(out.type)) {
      out.multiplex = { enabled: true, protocol: 'h2mux', max_connections: 4, min_streams: 4, padding: true };
    }
"""
            }
            code += "  }\n\n"
        }

        if enableSmartDNS {
            code += """
  // 3. 智能 FakeIP 与双轨 DoH
  config.dns = {
    servers: [
      { tag: 'dns-remote', address: 'https://1.1.1.1/dns-query', detour: 'proxy' },
      { tag: 'dns-direct', address: 'https://223.5.5.5/dns-query', detour: 'direct' },
      { tag: 'dns-fakeip', address: 'fakeip' },
      { tag: 'dns-block', address: 'rcode://success' }
    ],
    rules: [
      { outbound: 'any', server: 'dns-direct' },
      { rule_set: 'geosite-ads', server: 'dns-block' },
      { rule_set: 'geosite-cn', server: 'dns-direct' },
      { query_type: ['A', 'AAAA'], server: 'dns-fakeip' }
    ],
    fakeip: { enabled: true, inet4_range: '198.18.0.0/15' },
    independent_cache: true
  };
  const dnsHijackRule = { protocol: 'dns', action: 'hijack-dns' };
  if (!config.route.rules.some(function(r) { return r.protocol === 'dns'; })) {
    config.route.rules.unshift(dnsHijackRule);
  }

"""
        }

        code += """
  // 4. 提取节点并构建自动测速组
  const allNodeTags = (config.outbounds || [])
    .filter(function(o) {
      return o && o.tag && !reserved.has(o.tag) && !['selector', 'urltest', 'fallback'].includes(o.type);
    })
    .map(function(o) { return o.tag; });

  if (!allNodeTags.length) return config;

  const extraGroups = [
    { type: 'urltest', tag: '自动选择', outbounds: allNodeTags, url: 'https://www.gstatic.com/generate_204', interval: '3m', tolerance: 50 }
  ];

"""

        if enableAutoHK {
            code += "  const hkNodes = allNodeTags.filter(function(t) { return /香港|HK|Hong\\s*Kong|🇭🇰/i.test(t); });\n"
            code += "  if (hkNodes.length) extraGroups.push({ type: 'urltest', tag: '香港', outbounds: hkNodes, url: 'https://www.gstatic.com/generate_204', interval: '3m', tolerance: 50 });\n"
        }
        if enableAutoJP {
            code += "  const jpNodes = allNodeTags.filter(function(t) { return /日本|JP|Japan|东京|大阪|🇯🇵/i.test(t); });\n"
            code += "  if (jpNodes.length) extraGroups.push({ type: 'urltest', tag: '日本', outbounds: jpNodes, url: 'https://www.gstatic.com/generate_204', interval: '3m', tolerance: 50 });\n"
        }
        if enableAutoUS {
            code += "  const usNodes = allNodeTags.filter(function(t) { return /美国|美國|US|United\\s*States|洛杉矶|硅谷|🇺🇸/i.test(t); });\n"
            code += "  if (usNodes.length) extraGroups.push({ type: 'urltest', tag: '美国', outbounds: usNodes, url: 'https://www.gstatic.com/generate_204', interval: '3m', tolerance: 50 });\n"
        }
        if enableAutoSG {
            code += "  const sgNodes = allNodeTags.filter(function(t) { return /新加坡|SG|Singapore|🇸🇬/i.test(t); });\n"
            code += "  if (sgNodes.length) extraGroups.push({ type: 'urltest', tag: '新加坡', outbounds: sgNodes, url: 'https://www.gstatic.com/generate_204', interval: '3m', tolerance: 50 });\n"
        }
        if enableAutoTW {
            code += "  const twNodes = allNodeTags.filter(function(t) { return /台湾|台灣|TW|Taiwan|台北|🇹🇼/i.test(t); });\n"
            code += "  if (twNodes.length) extraGroups.push({ type: 'urltest', tag: '台湾', outbounds: twNodes, url: 'https://www.gstatic.com/generate_204', interval: '3m', tolerance: 50 });\n"
        }
        if enableAutoUK {
            code += "  const ukNodes = allNodeTags.filter(function(t) { return /英国|英國|UK|London|伦敦|🇬🇧/i.test(t); });\n"
            code += "  if (ukNodes.length) extraGroups.push({ type: 'urltest', tag: '英国', outbounds: ukNodes, url: 'https://www.gstatic.com/generate_204', interval: '3m', tolerance: 50 });\n"
        }
        if enableAutoDE {
            code += "  const deNodes = allNodeTags.filter(function(t) { return /德国|德國|DE|Germany|法兰克福|🇩🇪/i.test(t); });\n"
            code += "  if (deNodes.length) extraGroups.push({ type: 'urltest', tag: '德国', outbounds: deNodes, url: 'https://www.gstatic.com/generate_204', interval: '3m', tolerance: 50 });\n"
        }
        if enableAutoKR {
            code += "  const krNodes = allNodeTags.filter(function(t) { return /韩国|韓國|KR|Korea|首尔|🇰🇷/i.test(t); });\n"
            code += "  if (krNodes.length) extraGroups.push({ type: 'urltest', tag: '韩国', outbounds: krNodes, url: 'https://www.gstatic.com/generate_204', interval: '3m', tolerance: 50 });\n"
        }

        if enableAIGroup {
            code += "  extraGroups.push({ type: 'selector', tag: 'AI 平台', outbounds: ['自动选择'].concat(allNodeTags), default: '自动选择' });\n"
        }
        if enableStreamingGroup {
            code += "  extraGroups.push({ type: 'selector', tag: '国际媒体', outbounds: ['自动选择'].concat(allNodeTags), default: '自动选择' });\n"
        }
        if enableTelegramGroup {
            code += "  extraGroups.push({ type: 'selector', tag: 'Telegram', outbounds: ['自动选择'].concat(allNodeTags), default: '自动选择' });\n"
        }

        for (i, g) in customGroups.enumerated() {
            guard !g.name.isEmpty else { continue }
            let varName = "customGroupNodes_\(i)"
            if g.matchKeyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                code += "  const \(varName) = allNodeTags;\n"
            } else {
                let kw = g.matchKeyword.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
                code += "  const \(varName) = allNodeTags.filter(function(t) { return new RegExp('\(kw)', 'i').test(t); });\n"
            }
            if g.type == "urltest" {
                code += "  extraGroups.push({ type: 'urltest', tag: '\(g.name)', outbounds: \(varName).length ? \(varName) : allNodeTags, url: 'https://www.gstatic.com/generate_204', interval: '3m', tolerance: 50 });\n"
            } else {
                code += "  extraGroups.push({ type: 'selector', tag: '\(g.name)', outbounds: \(varName).length ? \(varName) : allNodeTags });\n"
            }
        }

        code += """

  const extraTags = extraGroups.map(function(g) { return g.tag; });
  config.outbounds = (config.outbounds || []).filter(function(o) { return !extraTags.includes(o.tag); });
  const proxy = config.outbounds.find(function(o) { return o.tag === 'proxy'; });
  if (proxy) {
    proxy.outbounds = extraTags.concat(allNodeTags);
    proxy.default = extraTags[0];
  }
  const proxyIdx = Math.max(0, config.outbounds.findIndex(function(o) { return o.tag === 'proxy'; }));
  config.outbounds.splice.apply(config.outbounds, [proxyIdx + 1, 0].concat(extraGroups));

"""

        let needsRuleSets = enableAdBlock || enableAIGroup || enableStreamingGroup || enableTelegramGroup
        if needsRuleSets {
            code += """
  // 5. 规则集注入 (sing-box 原生二进制 .srs)
  const ruleSetBase = 'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/';
  config.route.rule_set = config.route.rule_set || [];
  const existingRSTags = new Set(config.route.rule_set.map(function(rs) { return rs.tag; }));
  const ruleSetsToAdd = [];
"""
            if enableAdBlock {
                code += "  ruleSetsToAdd.push({ tag: 'geosite-ads', type: 'remote', format: 'binary', url: ruleSetBase + 'geosite/category-ads-all.srs', download_detour: 'proxy' });\n"
            }
            if enableAIGroup {
                code += "  ruleSetsToAdd.push({ tag: 'geosite-openai', type: 'remote', format: 'binary', url: ruleSetBase + 'geosite/openai.srs', download_detour: 'proxy' });\n"
                code += "  ruleSetsToAdd.push({ tag: 'geosite-anthropic', type: 'remote', format: 'binary', url: ruleSetBase + 'geosite/anthropic.srs', download_detour: 'proxy' });\n"
            }
            if enableStreamingGroup {
                code += "  ruleSetsToAdd.push({ tag: 'geosite-youtube', type: 'remote', format: 'binary', url: ruleSetBase + 'geosite/youtube.srs', download_detour: 'proxy' });\n"
                code += "  ruleSetsToAdd.push({ tag: 'geosite-netflix', type: 'remote', format: 'binary', url: ruleSetBase + 'geosite/netflix.srs', download_detour: 'proxy' });\n"
            }
            if enableTelegramGroup {
                code += "  ruleSetsToAdd.push({ tag: 'geosite-telegram', type: 'remote', format: 'binary', url: ruleSetBase + 'geosite/telegram.srs', download_detour: 'proxy' });\n"
                code += "  ruleSetsToAdd.push({ tag: 'geoip-telegram', type: 'remote', format: 'binary', url: ruleSetBase + 'geoip/telegram.srs', download_detour: 'proxy' });\n"
            }
            code += """
  for (var j = 0; j < ruleSetsToAdd.length; j++) {
    if (!existingRSTags.has(ruleSetsToAdd[j].tag)) {
      config.route.rule_set.push(ruleSetsToAdd[j]);
    }
  }

"""
        }

        code += """
  // 6. 路由规则指派
  config.route = config.route || {};
  config.route.rules = config.route.rules || [];
  config.route.final = 'proxy';

  const generatedRules = [];
"""

        for r in customRules {
            let items = r.value.components(separatedBy: CharacterSet(charactersIn: ",;，；\n"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !items.isEmpty else { continue }
            let arrayStr = items.map { "'\($0)'" }.joined(separator: ", ")
            code += "  generatedRules.push({ \(r.matchType): [\(arrayStr)], action: 'route', outbound: '\(r.targetOutbound)' });\n"
        }

        if enableAdBlock {
            code += """
  config.route.rule_set = config.route.rule_set || [];
  if (!config.route.rule_set.some(function(rs) { return rs.tag === 'geosite-ads'; })) {
    config.route.rule_set.push({
      tag: 'geosite-ads',
      type: 'remote',
      format: 'binary',
      url: 'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/category-ads-all.srs',
      download_detour: 'direct'
    });
  }
  generatedRules.push({ rule_set: 'geosite-ads', action: 'reject' });
"""
        }
        if enableAIGroup {
            code += "  generatedRules.push({ domain_suffix: ['openai.com', 'chatgpt.com', 'anthropic.com', 'claude.ai'], action: 'route', outbound: 'proxy' });\n"
        }
        if enableStreamingGroup {
            code += "  generatedRules.push({ domain_suffix: ['youtube.com', 'googlevideo.com', 'netflix.com', 'nflxvideo.net'], action: 'route', outbound: 'proxy' });\n"
        }
        if enableTelegramGroup {
            code += "  generatedRules.push({ domain_suffix: ['telegram.org', 't.me', 'telegra.ph'], action: 'route', outbound: 'proxy' });\n"
        }

        code += """
  config.route.rules = generatedRules.concat(config.route.rules);
  return config;
}
"""
        self.content = code
        self.editMode = .code
    }

    private func applyTemplate(_ templateContent: String, name: String = "预设模版") {
        let alert = NSAlert()
        alert.messageText = "载入「\(name)」预设模版？"
        alert.informativeText = "载入后将替换当前代码编辑区的内容，你可以随时在其基础上修改与调试。"
        alert.addButton(withTitle: "确认载入")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            self.content = templateContent
            self.editMode = .code
        }
    }

    @MainActor
    private func save() {
        isSaving = true
        errorMessage = nil
        saveSuccessMessage = nil
        Task { @MainActor in
            do {
                try await state.updateScript(id: script.id, name: name, content: content)
                self.isSaving = false
                self.saveSuccessMessage = "保存成功并已热重载！"
                try? await Task.sleep(for: .seconds(2))
                self.saveSuccessMessage = nil
            } catch {
                self.isSaving = false
                self.errorMessage = error.localizedDescription
            }
        }
    }
}

public struct NewScriptSheet: View {
    @Binding var isPresented: Bool
    var onCreated: (String) -> Void

    @ObservedObject private var state = AsterState.shared
    @State private var name: String = ""
    @State private var kind: String = "config"
    @State private var isCreating = false
    @State private var errorMessage: String? = nil

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("新建覆写脚本").font(.system(size: 16, weight: .bold))

            VStack(alignment: .leading, spacing: 6) {
                Text("脚本名称:").font(.system(size: 12, weight: .medium))
                TextField("如：全球分流与地区分组", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            InfoNoticeBanner(
                text: "创建后将生成干净标准的 main 入口骨架。你可以直接在代码编辑器中编写 JavaScript 脚本，或随时在「表单构建器」中通过点击「+ 添加策略组」「+ 添加分流规则」自由可视化组装。",
                icon: "info.circle.fill",
                style: .info
            )

            if let errorMessage {
                InfoNoticeBanner(text: errorMessage, icon: "exclamationmark.triangle.fill", style: .error)
            }

            HStack(spacing: 12) {
                Spacer()
                Button("取消") { isPresented = false }
                    .buttonStyle(.exquisiteSecondary(height: 28))
                Button(isCreating ? "创建中…" : "创建") {
                    create()
                }
                .buttonStyle(.exquisitePrimary(height: 28))
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCreating)
            }
        }
        .padding(22)
        .frame(width: 420)
        .unifiedWindowBackdrop(material: .popover, hasHairlineBorder: true)
    }

    @MainActor
    private func create() {
        isCreating = true
        errorMessage = nil
        let content = ScriptTemplates.blankStarter

        Task { @MainActor in
            do {
                let created = try await state.createScript(name: name, kind: kind, content: content)
                isPresented = false
                onCreated(created.id)
            } catch {
                self.errorMessage = error.localizedDescription
                self.isCreating = false
            }
        }
    }
}

// MARK: - 纯净空白骨架与标准模版库
public enum ScriptTemplates {
    public static let blankStarter = """
/**
 * Aster 覆写脚本
 * 
 * 约定入口: main(config)
 * 默认配置已生成 tag 为 proxy 的主选择组，可在此追加 urltest / 地区组并写回 proxy.outbounds。
 * @param {Object} config - 传入的 sing-box 完整配置对象
 * @returns {Object} 处理后的 sing-box 配置对象
 */
function main(config) {
  // 可以在此处自由调整 config.outbounds 与 config.route
  // 也可以通过上方切换到「表单构建器」可视化添加策略组和分流规则一键生成
  return config;
}
"""

    public static let fullFeaturedRuleSets = """
/**
 * 全能规则集分流模版 (基于 sing-box 官方/社区二进制 .srs 规则集)
 *
 * 特性：
 * 1. 采用 sing-box 原生二进制 .srs 规则集，极速匹配、零内存浪费
 * 2. 预设：OpenAI/AI 平台、YouTube、Netflix、Telegram、GitHub、广告拦截、中国大陆直连
 * 3. 自动生成对应业务策略组并汇入主选择组 proxy
 */
function main(config) {
  config = config || {};
  config.outbounds = config.outbounds || [];
  config.route = config.route || {};
  config.route.rule_set = config.route.rule_set || [];
  config.route.rules = config.route.rules || [];

  const reserved = new Set(['direct', 'proxy', 'auto', 'reject', 'block', 'dns']);
  const allNodeTags = config.outbounds
    .filter(function(o) {
      return o && o.tag && !reserved.has(o.tag) && !['selector', 'urltest', 'fallback'].includes(o.type);
    })
    .map(function(o) { return o.tag; });

  if (!allNodeTags.length) return config;

  // 1. 地区自动优选组
  const regions = [
    { tag: '香港', re: /香港|HK|Hong\\s*Kong|🇭🇰/i },
    { tag: '日本', re: /日本|JP|Japan|东京|🇯🇵/i },
    { tag: '台湾', re: /台湾|台灣|TW|Taiwan|🇹🇼/i },
    { tag: '新加坡', re: /新加坡|SG|Singapore|🇸🇬/i },
    { tag: '美国', re: /美国|美國|US|United\\s*States|🇺🇸/i }
  ];

  const regionalGroups = [];
  for (var i = 0; i < regions.length; i++) {
    var reg = regions[i];
    var matched = allNodeTags.filter(function(t) { return reg.re.test(t); });
    if (matched.length > 0) {
      regionalGroups.push({
        type: 'urltest',
        tag: reg.tag,
        outbounds: matched,
        url: 'https://www.gstatic.com/generate_204',
        interval: '3m',
        tolerance: 50
      });
    }
  }

  // 2. 基础选择备选项
  const autoGroup = {
    type: 'urltest',
    tag: '自动优选',
    outbounds: allNodeTags,
    url: 'https://www.gstatic.com/generate_204',
    interval: '3m',
    tolerance: 50
  };

  const groupOptions = ['自动优选']
    .concat(regionalGroups.map(function(g) { return g.tag; }))
    .concat(allNodeTags);

  // 3. 业务专线分流策略组
  const appGroups = [
    { type: 'selector', tag: 'AI 平台', outbounds: groupOptions, default: '自动优选' },
    { type: 'selector', tag: '国际媒体', outbounds: groupOptions, default: '自动优选' },
    { type: 'selector', tag: 'Telegram', outbounds: groupOptions, default: '自动优选' },
    { type: 'selector', tag: 'GitHub', outbounds: ['direct'].concat(groupOptions), default: '自动优选' }
  ];

  const newGroups = [autoGroup].concat(regionalGroups).concat(appGroups);
  const newGroupTags = newGroups.map(function(g) { return g.tag; });

  // 4. 重建主选择组 proxy
  config.outbounds = config.outbounds.filter(function(o) { return !newGroupTags.includes(o.tag); });
  var proxy = config.outbounds.find(function(o) { return o.tag === 'proxy'; });
  if (proxy) {
    proxy.outbounds = ['自动优选']
      .concat(regionalGroups.map(function(g) { return g.tag; }))
      .concat(allNodeTags);
    proxy.default = '自动优选';
  }
  var proxyIdx = Math.max(0, config.outbounds.findIndex(function(o) { return o.tag === 'proxy'; }));
  config.outbounds.splice.apply(config.outbounds, [proxyIdx + 1, 0].concat(newGroups));

  // 5. 注入远程二进制 .srs 规则集 (兼容 sing-box 1.8+)
  const ruleSetBase = 'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/';
  const ruleSetsToAdd = [
    { tag: 'geosite-openai', type: 'remote', format: 'binary', url: ruleSetBase + 'geosite/openai.srs', download_detour: 'proxy' },
    { tag: 'geosite-anthropic', type: 'remote', format: 'binary', url: ruleSetBase + 'geosite/anthropic.srs', download_detour: 'proxy' },
    { tag: 'geosite-youtube', type: 'remote', format: 'binary', url: ruleSetBase + 'geosite/youtube.srs', download_detour: 'proxy' },
    { tag: 'geosite-netflix', type: 'remote', format: 'binary', url: ruleSetBase + 'geosite/netflix.srs', download_detour: 'proxy' },
    { tag: 'geosite-telegram', type: 'remote', format: 'binary', url: ruleSetBase + 'geosite/telegram.srs', download_detour: 'proxy' },
    { tag: 'geoip-telegram', type: 'remote', format: 'binary', url: ruleSetBase + 'geoip/telegram.srs', download_detour: 'proxy' },
    { tag: 'geosite-github', type: 'remote', format: 'binary', url: ruleSetBase + 'geosite/github.srs', download_detour: 'proxy' },
    { tag: 'geosite-ads', type: 'remote', format: 'binary', url: ruleSetBase + 'geosite/category-ads-all.srs', download_detour: 'proxy' },
    { tag: 'geosite-cn', type: 'remote', format: 'binary', url: ruleSetBase + 'geosite/cn.srs', download_detour: 'direct' },
    { tag: 'geoip-cn', type: 'remote', format: 'binary', url: ruleSetBase + 'geoip/cn.srs', download_detour: 'direct' }
  ];

  const existingRSTags = new Set(config.route.rule_set.map(function(rs) { return rs.tag; }));
  for (var j = 0; j < ruleSetsToAdd.length; j++) {
    if (!existingRSTags.has(ruleSetsToAdd[j].tag)) {
      config.route.rule_set.push(ruleSetsToAdd[j]);
    }
  }

  // 6. 注入顶层分流路由规则
  const businessRules = [
    { rule_set: 'geosite-ads', action: 'reject' },
    { rule_set: ['geosite-openai', 'geosite-anthropic'], outbound: 'AI 平台' },
    { rule_set: ['geosite-youtube', 'geosite-netflix'], outbound: '国际媒体' },
    { rule_set: ['geosite-telegram', 'geoip-telegram'], outbound: 'Telegram' },
    { rule_set: 'geosite-github', outbound: 'GitHub' },
    { rule_set: ['geosite-cn', 'geoip-cn'], outbound: 'direct' }
  ];

  config.route.rules = businessRules.concat(config.route.rules);
  config.route.final = 'proxy';

  return config;
}
"""

    public static let subStoreGroups = """
/**
 * 多区域测速优选模版 (Sub-Store 风格多区域 URLTest 策略组)
 *
 * 特性：
 * 1. 深度识别全球主流区域 (港/日/台/新/美/英/德/韩)
 * 2. 针对存在的节点自动创建 urltest 测速分组，动态维护健康节点
 * 3. 将各区域优选组按序嵌套入主选择组 proxy
 */
function main(config) {
  config = config || {};
  config.outbounds = config.outbounds || [];

  const reserved = new Set(['direct', 'proxy', 'auto', 'reject', 'block', 'dns']);
  const allNodeTags = config.outbounds
    .filter(function(o) {
      return o && o.tag && !reserved.has(o.tag) && !['selector', 'urltest', 'fallback'].includes(o.type);
    })
    .map(function(o) { return o.tag; });

  if (!allNodeTags.length) return config;

  const regions = [
    { tag: '香港', re: /香港|HK|Hong\\s*Kong|🇭🇰/i },
    { tag: '日本', re: /日本|JP|Japan|东京|大阪|🇯🇵/i },
    { tag: '台湾', re: /台湾|台灣|TW|Taiwan|🇹🇼/i },
    { tag: '新加坡', re: /新加坡|SG|Singapore|🇸🇬/i },
    { tag: '美国', re: /美国|美國|US|United\\s*States|洛杉矶|硅谷|🇺🇸/i },
    { tag: '英国', re: /英国|英國|UK|London|伦敦|🇬🇧/i },
    { tag: '德国', re: /德国|德國|DE|Germany|法兰克福|🇩🇪/i },
    { tag: '韩国', re: /韩国|韓國|KR|Korea|首尔|🇰🇷/i }
  ];

  const extraGroups = [{
    type: 'urltest',
    tag: '自动优选',
    outbounds: allNodeTags,
    url: 'https://www.gstatic.com/generate_204',
    interval: '3m',
    tolerance: 50
  }];

  for (var i = 0; i < regions.length; i++) {
    var reg = regions[i];
    var tags = allNodeTags.filter(function(t) { return reg.re.test(t); });
    if (tags.length > 0) {
      extraGroups.push({
        type: 'urltest',
        tag: reg.tag,
        outbounds: tags,
        url: 'https://www.gstatic.com/generate_204',
        interval: '3m',
        tolerance: 50
      });
    }
  }

  const extraTags = extraGroups.map(function(g) { return g.tag; });
  config.outbounds = config.outbounds.filter(function(o) { return !extraTags.includes(o.tag); });

  const proxy = config.outbounds.find(function(o) { return o.tag === 'proxy'; });
  if (proxy) {
    proxy.outbounds = extraTags.concat(allNodeTags);
    proxy.default = extraTags[0];
  }

  const idx = Math.max(0, config.outbounds.findIndex(function(o) { return o.tag === 'proxy'; }));
  config.outbounds.splice.apply(config.outbounds, [idx + 1, 0].concat(extraGroups));
  return config;
}
"""

    public static let smartFakeIPDNS = """
/**
 * 智能 FakeIP 与双轨 DoH DNS 模版
 *
 * 特性：
 * 1. 采用 sing-box 原生 FakeIP (198.18.0.0/15) 消除远程解析延迟与 DNS 泄漏
 * 2. 双轨 DoH 架构：国内走阿里/腾讯加密 DNS，海外走 Cloudflare/Google 加密 DoH
 * 3. 自动注入 DNS 劫持规则与分流策略
 */
function main(config) {
  config = config || {};
  config.outbounds = config.outbounds || [];
  config.route = config.route || {};
  config.route.rules = config.route.rules || [];

  config.dns = {
    servers: [
      {
        tag: 'dns-remote',
        type: 'https',
        server: '1.1.1.1',
        path: '/dns-query',
        detour: 'proxy'
      },
      {
        tag: 'dns-direct',
        type: 'https',
        server: '223.5.5.5',
        path: '/dns-query',
        detour: 'direct'
      },
      {
        tag: 'dns-fakeip',
        type: 'fakeip',
        inet4_range: '198.18.0.0/15'
      }
    ],
    rules: [
      { query_type: ['AAAA', 'HTTPS', 'SVCB'], action: 'reject' },
      { inbound: ['mixed-in', 'tun-in'], query_type: ['A'], server: 'dns-fakeip' },
      { rule_set: 'geosite-cn', server: 'dns-direct' }
    ],
    final: 'dns-direct',
    strategy: 'ipv4_only'
  };

  const dnsHijackRule = {
    protocol: 'dns',
    action: 'hijack-dns'
  };

  if (!config.route.rules.some(function(r) { return r.protocol === 'dns'; })) {
    config.route.rules.unshift(dnsHijackRule);
  }

  return config;
}
"""

    public static let nodeOptimizer = """
/**
 * 协议特征与 uTLS 伪装优化模版
 *
 * 特性：
 * 1. 自动注入 Chrome 浏览器原生 TLS 指纹 (uTLS: chrome)，规避主动探测
 * 2. 为 VMess/VLESS/Trojan 启用 H2Mux 多路复用，降低并发连接握手开销
 * 3. 净化节点名称：去除广告、倍率后缀与营销字符，保持状态栏清爽
 */
function main(config) {
  config = config || {};
  config.outbounds = config.outbounds || [];

  const tlsProtocols = new Set(['vmess', 'vless', 'trojan', 'shadowtls']);
  const muxProtocols = new Set(['vmess', 'vless', 'trojan']);

  for (var i = 0; i < config.outbounds.length; i++) {
    var out = config.outbounds[i];
    if (!out || !out.type) continue;

    // 1. 净化节点名称
    if (out.tag && !['direct', 'proxy', 'auto', 'reject', 'block', 'dns'].includes(out.tag)) {
      out.tag = out.tag
        .replace(/\\[\\d+(\\.\\d+)?x\\]/gi, '')
        .replace(/\\|\\s*倍率[:：]?\\s*\\d+(\\.\\d+)?/gi, '')
        .replace(/(官网|地址|群组|频道|发布页)[:：]?\\s*\\S+/gi, '')
        .replace(/\\s+/g, ' ')
        .trim();
    }

    // 2. 注入 uTLS Chrome 真实指纹
    if (tlsProtocols.has(out.type)) {
      out.tls = out.tls || {};
      out.tls.enabled = true;
      out.tls.utls = {
        enabled: true,
        fingerprint: 'chrome'
      };
    }

    // 3. 启用 H2Mux 多路复用
    if (muxProtocols.has(out.type)) {
      out.multiplex = {
        enabled: true,
        protocol: 'h2mux',
        max_connections: 4,
        min_streams: 4,
        padding: true
      };
    }
  }

  return config;
}
"""

    public static let adBlockAndPrivacy = """
/**
 * 轻量广告拦截与隐私加固模版
 *
 * 特性：
 * 1. 接入 MetaCubeX 全量广告域名规则集
 * 2. 阻断常见的追踪与分析上报，提升网页加载速度
 * 3. 匹配即阻断 (action: reject)
 */
function main(config) {
  config = config || {};
  config.route = config.route || {};
  config.route.rule_set = config.route.rule_set || [];
  config.route.rules = config.route.rules || [];

  const adRuleSet = {
    tag: 'geosite-ads',
    type: 'remote',
    format: 'binary',
    url: 'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/category-ads-all.srs',
    download_detour: 'direct'
  };

  if (!config.route.rule_set.some(function(rs) { return rs.tag === 'geosite-ads'; })) {
    config.route.rule_set.push(adRuleSet);
  }

  config.route.rules.unshift({
    rule_set: 'geosite-ads',
    action: 'reject'
  });

  return config;
}
"""
}

