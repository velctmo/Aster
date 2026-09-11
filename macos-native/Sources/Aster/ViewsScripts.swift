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
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                            .font(.system(size: 11))
                        TextField("搜索脚本…", text: $searchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(6)

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
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "curlybraces")
                            .font(.system(size: 32))
                            .foregroundColor(.secondary.opacity(0.5))
                        Text("暂无覆写脚本")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
                        Text("点击右上角 + 创建您的第一个覆写规则")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary.opacity(0.8))
                        Button("新建脚本") {
                            showingNewSheet = true
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        Spacer()
                    }
                    .padding(20)
                } else {
                    List(selection: $selectedScriptId) {
                        ForEach(filteredScripts) { script in
                            ScriptListRow(script: script, selectedId: selectedScriptId)
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
                    state.notify(message: "已删除覆写脚本「\(script.name)」", type: .success)
                } catch {
                    state.notify(message: "删除覆写脚本失败：\(error.localizedDescription)", type: .error)
                }
            }
        }
    }
}

private struct ScriptListRow: View {
    let script: ScriptItem
    let selectedId: String?
    @ObservedObject private var state = AsterState.shared

    private var usedCount: Int {
        state.configs.filter { $0.scriptId == script.id }.count
    }

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
                    Button {
                        applyTemplate(ScriptTemplates.subStoreGroups)
                    } label: {
                        Text("载入地区分组示例")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("在节点池主组上叠加自动选择与地区 urltest，类似 Sub-Store")
                }

                Button {
                    save()
                } label: {
                    HStack(spacing: 4) {
                        if isSaving {
                            ProgressView().controlSize(.small)
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
                    }
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                }
                .padding(14)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
                .cornerRadius(10)
                .liquidGlassBorder(cornerRadius: 10)

                // 2. 动态自定义策略组构建区
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
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Text("自由创建需要的策略组，可设定为【自动测速优选】或【手动选择】，并配置节点过滤关键词。")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    if customGroups.isEmpty {
                        HStack {
                            Spacer()
                            VStack(spacing: 6) {
                                Image(systemName: "square.stack.3d.up")
                                    .font(.system(size: 24))
                                    .foregroundColor(.secondary.opacity(0.4))
                                Text("点击右上角「添加策略组」自由构建出站策略")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 16)
                            Spacer()
                        }
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
                .padding(14)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
                .cornerRadius(10)
                .liquidGlassBorder(cornerRadius: 10)

                // 3. 动态分流规则构建区
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
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Text("自定义匹配条件并指派出口，可分流至直连、阻止或上述任意创建的策略组。")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    if customRules.isEmpty {
                        HStack {
                            Spacer()
                            VStack(spacing: 6) {
                                Image(systemName: "arrow.triangle.branch")
                                    .font(.system(size: 24))
                                    .foregroundColor(.secondary.opacity(0.4))
                                Text("点击右上角「添加分流规则」指派域名或 IP 出口")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 16)
                            Spacer()
                        }
                    } else {
                        VStack(spacing: 8) {
                            ForEach($customRules) { $rule in
                                HStack(spacing: 8) {
                                    Picker("", selection: $rule.matchType) {
                                        Text("域名后缀").tag("domain_suffix")
                                        Text("域名关键字").tag("domain_keyword")
                                        Text("IP CIDR").tag("ip_cidr")
                                    }
                                    .labelsHidden()
                                    .frame(width: 110)

                                    TextField("输入匹配目标 (如 github.com，多个用逗号隔开)", text: $rule.value)
                                        .textFieldStyle(.roundedBorder)

                                    Text("➔").font(.system(size: 11)).foregroundColor(.secondary)

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
                .padding(14)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
                .cornerRadius(10)
                .liquidGlassBorder(cornerRadius: 10)

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
 * 节点池已提供 tag 为 proxy 的主选择组。脚本只追加策略组并写回 proxy.outbounds。
 */

function main(config) {
  const reserved = new Set(['direct', 'proxy', 'auto', 'reject', 'block', 'dns']);
  const allNodeTags = (config.outbounds || [])
    .filter(o => o && o.tag && !reserved.has(o.tag) && !['selector', 'urltest', 'fallback'].includes(o.type))
    .map(o => o.tag);

  if (!allNodeTags.length) return config;

  const extraGroups = [
    { type: 'urltest', tag: '自动选择', outbounds: allNodeTags, url: 'https://www.gstatic.com/generate_204', interval: '3m', tolerance: 50 }
  ];

"""

        if enableAutoHK {
            code += "  const hkNodes = allNodeTags.filter(t => /香港|HK|Hong\\s*Kong|🇭🇰/i.test(t));\n"
            code += "  if (hkNodes.length) extraGroups.push({ type: 'urltest', tag: '香港', outbounds: hkNodes, url: 'https://www.gstatic.com/generate_204', interval: '3m', tolerance: 50 });\n"
        }
        if enableAutoJP {
            code += "  const jpNodes = allNodeTags.filter(t => /日本|JP|Japan|东京|🇯🇵/i.test(t));\n"
            code += "  if (jpNodes.length) extraGroups.push({ type: 'urltest', tag: '日本', outbounds: jpNodes, url: 'https://www.gstatic.com/generate_204', interval: '3m', tolerance: 50 });\n"
        }
        if enableAutoUS {
            code += "  const usNodes = allNodeTags.filter(t => /美国|美國|US|United\\s*States|🇺🇸/i.test(t));\n"
            code += "  if (usNodes.length) extraGroups.push({ type: 'urltest', tag: '美国', outbounds: usNodes, url: 'https://www.gstatic.com/generate_204', interval: '3m', tolerance: 50 });\n"
        }
        if enableAutoSG {
            code += "  const sgNodes = allNodeTags.filter(t => /新加坡|SG|Singapore|🇸🇬/i.test(t));\n"
            code += "  if (sgNodes.length) extraGroups.push({ type: 'urltest', tag: '新加坡', outbounds: sgNodes, url: 'https://www.gstatic.com/generate_204', interval: '3m', tolerance: 50 });\n"
        }

        for (i, g) in customGroups.enumerated() {
            guard !g.name.isEmpty else { continue }
            let varName = "customGroupNodes_\(i)"
            if g.matchKeyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                code += "  const \(varName) = allNodeTags;\n"
            } else {
                let kw = g.matchKeyword.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
                code += "  const \(varName) = allNodeTags.filter(t => new RegExp('\(kw)', 'i').test(t));\n"
            }
            if g.type == "urltest" {
                code += "  extraGroups.push({ type: 'urltest', tag: '\(g.name)', outbounds: \(varName).length ? \(varName) : allNodeTags, url: 'https://www.gstatic.com/generate_204', interval: '3m', tolerance: 50 });\n"
            } else {
                code += "  extraGroups.push({ type: 'selector', tag: '\(g.name)', outbounds: \(varName).length ? \(varName) : allNodeTags });\n"
            }
        }

        code += """

  const extraTags = extraGroups.map(g => g.tag);
  config.outbounds = (config.outbounds || []).filter(o => !extraTags.includes(o.tag));
  const proxy = config.outbounds.find(o => o.tag === 'proxy');
  if (proxy) {
    proxy.outbounds = extraTags;
    proxy.default = extraTags[0];
  }
  const proxyIdx = Math.max(0, config.outbounds.findIndex(o => o.tag === 'proxy'));
  config.outbounds.splice(proxyIdx + 1, 0, ...extraGroups);

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

        code += """
  config.route.rules = [...generatedRules, ...config.route.rules];
  return config;
}
"""
        self.content = code
        self.editMode = .code
    }

    private func applyTemplate(_ templateContent: String) {
        let alert = NSAlert()
        alert.messageText = "载入预设示例代码？"
        alert.informativeText = "载入后将替换当前代码编辑区的内容，你可以随时在其基础上修改。"
        alert.addButton(withTitle: "载入")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            self.content = templateContent
            self.editMode = .code
        }
    }

    private func save() {
        isSaving = true
        errorMessage = nil
        saveSuccessMessage = nil
        Task {
            do {
                try await state.updateScript(id: script.id, name: name, content: content)
                await MainActor.run {
                    self.isSaving = false
                    self.saveSuccessMessage = "保存成功并已热重载！"
                }
                try? await Task.sleep(for: .seconds(2))
                await MainActor.run {
                    self.saveSuccessMessage = nil
                }
            } catch {
                await MainActor.run {
                    self.isSaving = false
                    self.errorMessage = error.localizedDescription
                }
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

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle.fill")
                        .foregroundColor(.accentColor)
                        .font(.system(size: 11))
                    Text("说明:").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                }
                Text("创建后将生成干净标准的 main 入口骨架。你可以直接在代码编辑器中编写 JavaScript 脚本，或随时在「表单构建器」中通过点击「+ 添加策略组」「+ 添加分流规则」自由可视化组装。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .background(Color.accentColor.opacity(0.06))
            .cornerRadius(6)

            if let errorMessage {
                Text(errorMessage).font(.system(size: 11)).foregroundColor(.red)
            }

            HStack {
                Spacer()
                Button("取消") { isPresented = false }
                Button(isCreating ? "创建中…" : "创建") {
                    create()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCreating)
            }
        }
        .padding(22)
        .frame(width: 420)
    }

    private func create() {
        isCreating = true
        errorMessage = nil
        let content = ScriptTemplates.blankStarter

        Task {
            do {
                let created = try await state.createScript(name: name, kind: kind, content: content)
                await MainActor.run {
                    isPresented = false
                    onCreated(created.id)
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isCreating = false
                }
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
 * 节点池已生成 tag 为 proxy 的主选择组，可在此追加 urltest / 地区组并写回 proxy.outbounds。
 * @param {Object} config - 传入的 sing-box 完整配置对象
 * @returns {Object} 处理后的 sing-box 配置对象
 */
function main(config) {
  // 可以在此处自由调整 config.outbounds 与 config.route
  // 也可以通过上方切换到「表单构建器」可视化添加策略组和分流规则一键生成
  return config;
}
"""

    public static let subStoreGroups = """
/**
 * Sub-Store 风格：在节点池主组上叠加自动选择与地区 urltest。
 * 入口: main(config)
 */
function main(config) {
  const reserved = new Set(['direct', 'proxy', 'auto', 'reject', 'block', 'dns']);
  const allNodeTags = (config.outbounds || [])
    .filter(o => o && o.tag && !reserved.has(o.tag) && !['selector', 'urltest', 'fallback'].includes(o.type))
    .map(o => o.tag);
  if (!allNodeTags.length) return config;

  const regions = [
    { tag: '香港', re: /香港|HK|Hong\\s*Kong|🇭🇰/i },
    { tag: '日本', re: /日本|JP|Japan|东京|🇯🇵/i },
    { tag: '台湾', re: /台湾|台灣|TW|Taiwan|🇹🇼/i },
    { tag: '新加坡', re: /新加坡|SG|Singapore|🇸🇬/i },
    { tag: '美国', re: /美国|美國|US|United\\s*States|🇺🇸/i }
  ];

  const extra = [{
    type: 'urltest', tag: '自动选择', outbounds: allNodeTags,
    url: 'https://www.gstatic.com/generate_204', interval: '3m', tolerance: 50
  }];
  for (const region of regions) {
    const tags = allNodeTags.filter(t => region.re.test(t));
    if (tags.length) extra.push({
      type: 'urltest', tag: region.tag, outbounds: tags,
      url: 'https://www.gstatic.com/generate_204', interval: '3m', tolerance: 50
    });
  }

  const extraTags = extra.map(g => g.tag);
  config.outbounds = config.outbounds.filter(o => !extraTags.includes(o.tag));
  const proxy = config.outbounds.find(o => o.tag === 'proxy');
  if (proxy) {
    proxy.outbounds = extraTags;
    proxy.default = extraTags[0];
  }
  const idx = config.outbounds.findIndex(o => o.tag === 'proxy');
  config.outbounds.splice(idx + 1, 0, ...extra);
  return config;
}
"""
}
