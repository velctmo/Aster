import SwiftUI
import AppKit
import UniformTypeIdentifiers

public enum ProfileManagementTab: String, CaseIterable, Identifiable {
    case profiles = "订阅配置"
    case overrides = "覆写管理"

    public var id: String { rawValue }
}

public struct ProfilesView: View {
    @ObservedObject var state = AsterState.shared
    @State private var activeTab: ProfileManagementTab = .profiles
    @State private var showingAddSheet = false

    public var body: some View {
        VStack(spacing: 0) {
            // 顶栏：标题 + 原生胶囊分段导航 + 快捷操作
            PageHeader(title: "配置") {
                HStack(spacing: 12) {
                    // 原生胶囊分段导航器
                    Picker("", selection: $activeTab) {
                        ForEach(ProfileManagementTab.allCases) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)

                    Divider().frame(height: 16).opacity(0.4)

                    if activeTab == .profiles {
                        Text("\(state.configs.count) 个配置")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)

                        Button { 
                            state.refreshAllConfigs() 
                        } label: { 
                            HStack(spacing: 4) {
                                if state.isRefreshingAllConfigs {
                                    ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                                    Text("正在更新…")
                                } else {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                    Text("全部更新")
                                }
                            }
                        }
                        .buttonStyle(.exquisiteSecondary)
                        .disabled(state.isConfigMutationInFlight || state.isRefreshingAllConfigs)

                        Button { showingAddSheet = true } label: { Label("添加订阅", systemImage: "plus") }
                        .buttonStyle(.exquisitePrimary)
                        .disabled(state.isConfigMutationInFlight)
                    } else {
                        Text("\(state.scripts.count) 个覆写脚本")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
            }

            Divider().opacity(0.4)

            // 错误横幅
            if let error = state.configMutationError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text(error).font(.system(size: 12)).lineLimit(2)
                    Spacer()
                    Button("关闭") { state.configMutationError = nil }
                        .buttonStyle(.borderless).controlSize(.small)
                }
                .padding(.horizontal, 24).padding(.vertical, 9)
                .background(Color.orange.opacity(0.1))
            }

            // 主内容区分支展示
            if activeTab == .profiles {
                if state.configs.isEmpty {
                    Spacer()
                    ContentUnavailableView("暂无配置", systemImage: "doc.badge.plus", description: Text("添加 sing-box 订阅、Clash 配置或组合节点池"))
                    Spacer()
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(state.configs) { config in
                                ConfigProfileCard(config: config, onSwitchToOverrides: {
                                    activeTab = .overrides
                                })
                            }
                        }
                        .padding(24)
                    }
                    .scrollIndicators(.hidden)
                }
            } else {
                OverridesManagementView()
            }
        }
        .task {
            await state.fetchConfigs()
            await state.fetchScripts()
        }
        .sheet(isPresented: $showingAddSheet) {
            AddSubscriptionSheet(isPresented: $showingAddSheet)
        }
    }
}

public struct ConfigProfileCard: View {
    let config: ConfigProfileItem
    var onSwitchToOverrides: () -> Void
    @ObservedObject private var state = AsterState.shared
    @State private var isHovered = false

    private var isUpdating: Bool {
        state.updatingConfigIds.contains(config.id) || state.isRefreshingAllConfigs
    }

    private var configSummaryText: String {
        if config.kind == "subscription" {
            return "完整订阅"
        } else {
            return "\(config.sourceCount) 源 · \(config.nodeCount) 节点"
        }
    }

    private var boundScriptName: String? {
        guard let scriptId = config.scriptId, !scriptId.isEmpty else { return nil }
        return state.scripts.first(where: { $0.id == scriptId })?.name ?? "已配置脚本"
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            // 第一行：状态圆标 + 配置名称 + 模式标签 + 节点摘要 + 右侧状态指示（更新中/当前生效）
            HStack(spacing: 8) {
                // 生效或空闲状态小圆标
                Circle()
                    .fill(config.active ? Color.green : Color.secondary.opacity(0.35))
                    .frame(width: 7, height: 7)

                Text(config.name)
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundColor(config.active ? .primary : .primary.opacity(0.88))
                    .lineLimit(1)

                Text(config.kind == "subscription" ? "订阅" : "节点")
                    .font(.system(size: 9.5, weight: .semibold))
                    .padding(.horizontal, 5.5)
                    .padding(.vertical, 1.5)
                    .background((config.kind == "subscription" ? Color.blue : Color.purple).opacity(0.12))
                    .foregroundColor(config.kind == "subscription" ? .blue : .purple)
                    .clipShape(Capsule())

                Text(configSummaryText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)

                Spacer()

                if isUpdating {
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 10, height: 10)
                        Text("更新中…")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.accentColor)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.08))
                    .clipShape(Capsule())
                } else if config.active {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 9))
                        Text("当前生效")
                            .font(.system(size: 9.5, weight: .bold))
                    }
                    .foregroundColor(.green)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.12))
                    .clipShape(Capsule())
                }
            }

            // 第二行：覆写脚本状态胶囊 + 错误或更新时间展示
            HStack(spacing: 8) {
                // 覆写脚本状态展示胶囊
                if let scriptName = boundScriptName {
                    HStack(spacing: 4) {
                        Image(systemName: "curlybraces")
                            .font(.system(size: 9.5))
                            .foregroundColor(.orange)
                        Text("覆写: \(scriptName)")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(.primary.opacity(0.85))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(Color.orange.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "curlybraces")
                            .font(.system(size: 9.5))
                            .foregroundColor(.secondary.opacity(0.7))
                        Text("无覆写脚本")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(Color.secondary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }

                Spacer()

                if !config.lastError.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.system(size: 10))
                        Text(config.lastError)
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                            .lineLimit(1)
                    }
                } else if let refresh = config.recentRefreshes?.first, refresh.at > 0 {
                    Text("更新于 \(Date(timeIntervalSince1970: TimeInterval(refresh.at)).formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.8))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            if config.active {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.08))
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.6))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    config.active ? Color.accentColor.opacity(0.4) : (isHovered ? Color.primary.opacity(0.18) : Color.primary.opacity(0.06)),
                    lineWidth: config.active ? 1.2 : 0.8
                )
        )
        .shadow(color: config.active ? Color.accentColor.opacity(0.08) : Color.black.opacity(0.02), radius: 4, y: 1.5)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { isHovered = $0 }
        .contextMenu {
            if !config.active {
                Button {
                    state.activateConfig(id: config.id)
                } label: {
                    Label("启用此配置", systemImage: "checkmark.circle")
                }
            }

            Button {
                state.refreshConfig(id: config.id)
            } label: {
                Label("刷新 / 更新订阅", systemImage: "arrow.clockwise")
            }
            .disabled(isUpdating || state.isConfigMutationInFlight)

            Divider()

            // 切换覆写脚本二级子菜单
            Menu {
                Button {
                    bindScript(nil)
                } label: {
                    if config.scriptId == nil || config.scriptId?.isEmpty == true {
                        Label("无覆写", systemImage: "checkmark")
                    } else {
                        Text("无覆写")
                    }
                }

                if !state.scripts.isEmpty {
                    Divider()
                    ForEach(state.scripts) { s in
                        Button {
                            bindScript(s.id)
                        } label: {
                            if config.scriptId == s.id {
                                Label(s.name, systemImage: "checkmark")
                            } else {
                                Text(s.name)
                            }
                        }
                    }
                }
            } label: {
                Label("设置覆写脚本", systemImage: "curlybraces")
            }

            Button {
                onSwitchToOverrides()
            } label: {
                Label("打开覆写管理", systemImage: "slider.horizontal.3")
            }

            Divider()

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(config.name, forType: .string)
                state.showToast(message: "已复制配置名称")
            } label: {
                Label("复制配置名称", systemImage: "doc.on.doc")
            }

            Divider()

            Button(role: .destructive) {
                state.deleteConfig(id: config.id)
            } label: {
                Label("删除配置", systemImage: "trash")
            }
        }
    }

    private func bindScript(_ scriptId: String?) {
        Task {
            do {
                try await state.bindScript(profileId: config.id, scriptId: scriptId)
                let name = scriptId.flatMap { id in state.scripts.first(where: { $0.id == id })?.name } ?? "无覆写"
                state.notify(message: "已将「\(config.name)」的覆写脚本设为「\(name)」", type: .success)
            } catch {
                let message = "更新「\(config.name)」的覆写脚本失败：\(error.localizedDescription)"
                state.configMutationError = message
                state.notify(message: message, type: .error)
            }
        }
    }

    private func capabilityLabel(_ title: String, _ capability: Capability) -> some View {
        Label(title, systemImage: capability.available ? "checkmark.circle.fill" : "xmark.circle")
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(capability.available ? .green : .secondary)
            .help(capability.reason ?? title + "可用")
    }

    private func inboundDescription(_ inbound: ImportedInboundSummary) -> String {
        var parts = [inbound.mixedLoopback.map { "mixed \($0)" } ?? "未发现可用 loopback mixed 入站"]
        parts.append(inbound.hasTun ? "检测到 TUN（由配置管理）" : "未检测到 TUN")
        return parts.joined(separator: " · ")
    }

    private func refreshSourceName(_ id: String) -> String {
        if id == "subscription" { return "完整订阅" }
        return config.sources?.first(where: { $0.id == id })?.name ?? "订阅来源"
    }
}

// MARK: - 全新重构的添加订阅双层分流模态 (AddSubscriptionSheet)
public struct AddSubscriptionSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject private var state = AsterState.shared

    @State private var sourceTab = 0 // 0: 网络 URL, 1: 本地文件
    @State private var networkMode = 0 // 0: 单订阅模式 (完整托管), 1: 节点订阅模式 (多源聚合)
    @State private var singleUrl = ""
    @State private var multiUrls = ""
    @State private var localContent = ""
    @State private var localFileName = ""
    @State private var name = ""
    @State private var selectedScriptId = ""
    @State private var activateImmediately = true
    @State private var errorMessage: String?
    @State private var submitting = false
    @State private var progressValue: Double = 0.0
    @State private var progressStage: String = ""
    @State private var isDropTargeted = false
    @State private var createdConfigID: ConfigProfileItem.ID?

    public init(isPresented: Binding<Bool>) {
        self._isPresented = isPresented
    }

    private var multiUrlLines: [String] {
        multiUrls
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var sourceCount: Int {
        multiUrlLines.count
    }

    private var isValid: Bool {
        if sourceTab == 0 {
            if networkMode == 0 {
                return !singleUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            } else {
                return sourceCount > 0
            }
        } else {
            return !localContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var namePlaceholder: String {
        if sourceTab == 0 {
            return networkMode == 0 ? "选填，未填写时自动解析域名" : "选填，默认命名为「节点订阅聚合」"
        } else {
            return "选填，未填写时自动使用文件名"
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 顶栏：标题
            HStack {
                Text("添加订阅")
                    .font(.system(size: 16, weight: .bold))
                Spacer()
            }

            // 第一级来源分段：网络 URL vs 本地文件
            Picker("", selection: $sourceTab) {
                Text("🌐 从网络 URL 导入").tag(0)
                Text("📁 从本地文件导入").tag(1)
            }
            .pickerStyle(.segmented)
            .disabled(submitting)

            // 第二级分流 / 导入内容输入区域
            if sourceTab == 0 {
                // 网络 URL 二级模式分段
                VStack(alignment: .leading, spacing: 10) {
                    Picker("", selection: $networkMode) {
                        Text("⚡️ 单订阅模式 (完整托管)").tag(0)
                        Text("🔗 节点订阅模式 (多源聚合)").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .disabled(submitting)

                    // 模式说明文案
                    HStack(spacing: 4) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Text(networkMode == 0
                            ? "使用源订阅分组与分流规则，仅需输入 1 个链接。"
                            : "支持多个订阅源（每行一个），仅提取节点并汇入聚合池。")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .padding(.leading, 2)

                    if networkMode == 0 {
                        // 单订阅输入区域
                        VStack(alignment: .leading, spacing: 6) {
                            Text("订阅链接:")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)

                            HStack(spacing: 8) {
                                TextField("https://example.com/sub/...", text: $singleUrl)
                                    .textFieldStyle(.roundedBorder)
                                    .disabled(submitting)

                                Button {
                                    pasteFromClipboard()
                                } label: {
                                    Label("粘贴", systemImage: "doc.on.clipboard")
                                }
                                .buttonStyle(.exquisiteSecondary)
                                .disabled(submitting)
                            }

                            Text("💡 支持 sing-box JSON、Clash YAML 与 Base64 订阅链接，完整保留源订阅内的策略组与分流规则。")
                                .font(.system(size: 10.5))
                                .foregroundColor(.secondary.opacity(0.85))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        // 节点订阅输入区域
                        VStack(alignment: .leading, spacing: 6) {
                            Text("订阅链接列表（每行一个）:")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)

                            TextEditor(text: $multiUrls)
                                .font(.system(size: 12, design: .monospaced))
                                .frame(height: 105)
                                .overlay(
                                    RoundedRectangle(cornerRadius: AsterMetrics.radiusControl, style: .continuous)
                                        .stroke(Color.secondary.opacity(0.3), lineWidth: 0.8)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: AsterMetrics.radiusControl, style: .continuous))
                                .disabled(submitting)

                            HStack(alignment: .top) {
                                Text("💡 支持 sing-box 支持的所有解析类型（Clash YAML、sing-box JSON、Base64 等），系统将并发抓取并仅提取有效节点。")
                                    .font(.system(size: 10.5))
                                    .foregroundColor(.secondary.opacity(0.85))
                                    .fixedSize(horizontal: false, vertical: true)

                                Spacer(minLength: 12)

                                Text("已识别 \(sourceCount) 个订阅源")
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundColor(sourceCount > 0 ? .accentColor : .secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.primary.opacity(0.05))
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }
            } else {
                // 本地文件导入区域
                VStack(alignment: .leading, spacing: 8) {
                    Text("选择或拖拽本地配置文件:").font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)

                    ZStack {
                        RoundedRectangle(cornerRadius: AsterMetrics.radiusCard, style: .continuous)
                            .strokeBorder(
                                isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                                style: StrokeStyle(lineWidth: 1.5, dash: [5])
                            )
                            .background(
                                RoundedRectangle(cornerRadius: AsterMetrics.radiusCard, style: .continuous)
                                    .fill(isDropTargeted ? Color.accentColor.opacity(0.06) : Color.primary.opacity(0.02))
                            )

                        VStack(spacing: 8) {
                            if !localFileName.isEmpty {
                                HStack(spacing: 6) {
                                    Image(systemName: "doc.badge.gearshape.fill")
                                        .font(.system(size: 16))
                                        .foregroundColor(.accentColor)
                                    Text(localFileName)
                                        .font(.system(size: 12, weight: .semibold))
                                    Text("(\(Formatters.bytesString(Int64(localContent.utf8.count))))")
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                                Button("更换文件…") { chooseLocalFile() }
                                    .buttonStyle(.exquisiteSecondary)
                                    .disabled(submitting)
                            } else {
                                Image(systemName: "square.and.arrow.down")
                                    .font(.system(size: 24))
                                    .foregroundColor(.secondary)
                                Text("点击选择或将 .json / .yaml / .yml 文件拖拽至此")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                Button("选择文件…") { chooseLocalFile() }
                                    .buttonStyle(.exquisiteSecondary)
                                    .disabled(submitting)
                            }
                        }
                        .padding(16)
                    }
                    .frame(height: 105)
                    .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
                        handleDrop(providers: providers)
                    }
                }
            }

            Divider().opacity(0.4)

            // 公共通用字段：配置名称（可选）
            VStack(alignment: .leading, spacing: 4) {
                Text("配置名称（可选）:").font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
                TextField(namePlaceholder, text: $name)
                    .textFieldStyle(.roundedBorder)
                    .disabled(submitting)
            }

            // 公共通用字段：挂载覆写脚本
            HStack(spacing: 10) {
                Text("挂载覆写脚本:").font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
                Picker("", selection: $selectedScriptId) {
                    Text("不启用覆写").tag("")
                    if !state.scripts.isEmpty {
                        Divider()
                        ForEach(state.scripts) { s in
                            Text(s.name).tag(s.id)
                        }
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
                Spacer()
            }
            .disabled(submitting)

            // 公共通用字段：添加后立即生效开关
            Toggle("添加后立即设为当前生效配置", isOn: $activateImmediately)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .disabled(submitting)

            // 提交进度与状态
            if submitting {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        ProgressView(value: progressValue, total: 1.0)
                            .progressViewStyle(.linear)
                        Text("\(Int(progressValue * 100))%")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
                        Text(progressStage).font(.system(size: 11)).foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            if let errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .font(.system(size: 11))
                    Text(errorMessage)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                }
            }

            // 底部操作按钮
            HStack {
                Spacer()
                Button("取消") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                    .disabled(submitting)
                Button(submitting ? "正在导入…" : "添加订阅") { submit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(submitting || !isValid)
            }
        }
        .padding(22)
        .frame(width: 540)
    }

    private func pasteFromClipboard() {
        if let string = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty {
            singleUrl = string
        }
    }

    private func chooseLocalFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            .json,
            UTType(filenameExtension: "yaml") ?? .plainText,
            UTType(filenameExtension: "yml") ?? .plainText
        ]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let fileURL = panel.url else { return }
        loadFile(at: fileURL)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let data = item as? Data, let fileURL = URL(dataRepresentation: data, relativeTo: nil) else { return }
            DispatchQueue.main.async {
                self.loadFile(at: fileURL)
            }
        }
        return true
    }

    private func loadFile(at fileURL: URL) {
        do {
            localContent = try String(contentsOf: fileURL, encoding: .utf8)
            localFileName = fileURL.lastPathComponent
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                name = fileURL.deletingPathExtension().lastPathComponent
            }
            errorMessage = nil
        } catch {
            errorMessage = "读取文件失败: \(error.localizedDescription)"
        }
    }

    private func submit() {
        submitting = true
        errorMessage = nil
        progressValue = 0.2
        progressStage = "正在准备解析配置数据…"

        Task {
            do {
                let createdConfig: ConfigProfileItem
                if let existingID = createdConfigID {
                    guard let existingConfig = state.configs.first(where: { $0.id == existingID }) else {
                        throw NSError(
                            domain: "Aster",
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "配置已创建，但本地列表尚未同步；请刷新配置页后再重试绑定覆写脚本。"]
                        )
                    }
                    createdConfig = existingConfig
                    await MainActor.run {
                        progressValue = 0.7
                        progressStage = "正在重试挂载覆写脚本…"
                    }
                } else {
                    // 解析名称
                    var finalName = name.trimmingCharacters(in: .whitespacesAndNewlines)

                    if sourceTab == 0 {
                        if networkMode == 0 {
                            // 单订阅模式 (完整托管)
                            let trimmedUrl = singleUrl.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmedUrl.isEmpty else {
                                throw NSError(domain: "Aster", code: -1, userInfo: [NSLocalizedDescriptionKey: "请输入有效的订阅链接"])
                            }

                            if finalName.isEmpty {
                                if let parsedURL = URL(string: trimmedUrl), let fragment = parsedURL.fragment, !fragment.isEmpty,
                                   let decoded = fragment.removingPercentEncoding, !decoded.isEmpty {
                                    finalName = decoded
                                } else if let host = URL(string: trimmedUrl)?.host, !host.isEmpty {
                                    finalName = host
                                } else {
                                    finalName = "单订阅配置"
                                }
                            }

                            await MainActor.run {
                                progressValue = 0.5
                                progressStage = "正在向订阅端拉取数据并校验规则…"
                            }

                            createdConfig = try await state.createConfigAndReturn(
                                name: finalName,
                                kind: "subscription",
                                url: trimmedUrl,
                                content: "",
                                urls: [],
                                activate: activateImmediately
                            )
                        } else {
                            // 节点订阅模式 (多源聚合)
                            let lines = multiUrlLines
                            guard !lines.isEmpty else {
                                throw NSError(domain: "Aster", code: -1, userInfo: [NSLocalizedDescriptionKey: "请至少输入一行有效的订阅链接"])
                            }

                            if finalName.isEmpty {
                                finalName = "节点订阅聚合"
                            }

                            await MainActor.run {
                                progressValue = 0.5
                                progressStage = "正在并发抓取多源订阅并提取有效节点…"
                            }

                            createdConfig = try await state.createConfigAndReturn(
                                name: finalName,
                                kind: "nodes",
                                url: "",
                                content: "",
                                urls: lines,
                                activate: activateImmediately
                            )
                        }
                    } else {
                        // 从本地文件导入
                        let trimmedContent = localContent.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmedContent.isEmpty else {
                            throw NSError(domain: "Aster", code: -1, userInfo: [NSLocalizedDescriptionKey: "请选择包含有效配置内容的本地文件"])
                        }

                        if finalName.isEmpty {
                            if !localFileName.isEmpty {
                                finalName = URL(fileURLWithPath: localFileName).deletingPathExtension().lastPathComponent
                            }
                            if finalName.isEmpty {
                                finalName = "本地配置"
                            }
                        }

                        await MainActor.run {
                            progressValue = 0.5
                            progressStage = "正在解析并进行内核规则校验…"
                        }

                        createdConfig = try await state.createConfigAndReturn(
                            name: finalName,
                            kind: "subscription",
                            url: "",
                            content: localContent,
                            urls: [],
                            activate: activateImmediately
                        )
                    }
                }

                createdConfigID = createdConfig.id

                // 如果指定了覆写脚本，进行绑定
                if !selectedScriptId.isEmpty {
                    await MainActor.run {
                        progressValue = 0.8
                        progressStage = "正在挂载覆写脚本…"
                    }
                    do {
                        try await state.bindScript(profileId: createdConfig.id, scriptId: selectedScriptId)
                    } catch {
                        throw NSError(
                            domain: "Aster",
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "配置「\(createdConfig.name)」已创建，但覆写脚本未能绑定：\(error.localizedDescription)"]
                        )
                    }
                }

                await MainActor.run {
                    progressValue = 1.0
                    progressStage = activateImmediately ? "配置已生效！" : "配置添加成功！"
                    createdConfigID = nil
                }
                try? await Task.sleep(for: .milliseconds(300))
                await MainActor.run {
                    isPresented = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    submitting = false
                    progressValue = 0.0
                    progressStage = ""
                }
            }
        }
    }
}

public typealias AddConfigSheet = AddSubscriptionSheet
