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

                        Button { showingAddSheet = true } label: { Label("添加配置", systemImage: "plus") }
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
            AddConfigSheet(isPresented: $showingAddSheet)
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

// MARK: - 全新重构的添加订阅与配置弹窗 (以输入来源驱动)
public struct AddConfigSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject private var state = AsterState.shared

    @State private var sourceTab = 0 // 0: 从 URL 导入, 1: 从文件导入
    @State private var name = ""
    @State private var url = ""
    @State private var urls = ""
    @State private var localContent = ""
    @State private var localFileName = ""
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

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 顶栏：标题与来源选项卡
            HStack {
                Text("添加订阅与配置").font(.system(size: 16, weight: .bold))
                Spacer()
            }

            // 来源选择器
            Picker("", selection: $sourceTab) {
                Text("🌐 从网络 URL 导入").tag(0)
                Text("📁 从本地文件导入").tag(1)
            }
            .pickerStyle(.segmented)
            .disabled(submitting)

            // 配置名称（可选）
            VStack(alignment: .leading, spacing: 4) {
                Text("配置名称（可选）:").font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
                TextField("如：My Airport 01", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .disabled(submitting)
            }

            // 核心来源表单切换
            if sourceTab == 0 {
                // 1. 从 URL 导入
                VStack(alignment: .leading, spacing: 6) {
                    Text("订阅链接（单订阅链接，或每行一个节点聚合源）:").font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
                    TextEditor(text: $urls)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 100)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                        .disabled(submitting)

                    Text("💡 支持 sing-box JSON、Clash YAML 与 Base64 订阅链接，系统自动嗅探识别。")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary.opacity(0.8))
                }
            } else {
                // 2. 从文件导入
                VStack(alignment: .leading, spacing: 8) {
                    Text("选择或拖拽本地配置文件:").font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)

                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                            .foregroundColor(isDropTargeted ? .accentColor : .secondary.opacity(0.4))
                            .background(isDropTargeted ? Color.accentColor.opacity(0.05) : Color.clear)

                        VStack(spacing: 8) {
                            if !localFileName.isEmpty {
                                HStack(spacing: 6) {
                                    Image(systemName: "doc.badge.gearshape.fill")
                                        .foregroundColor(.accentColor)
                                    Text(localFileName)
                                        .font(.system(size: 12, weight: .semibold))
                                    Text("(\(localContent.count) 字节)")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                                Button("更换文件…") { chooseLocalFile() }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "square.and.arrow.down")
                                    .font(.system(size: 24))
                                    .foregroundColor(.secondary)
                                Text("点击选择或将 .json / .yaml 文件拖拽至此")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                Button("选择文件…") { chooseLocalFile() }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                        }
                        .padding(16)
                    }
                    .frame(height: 100)
                    .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
                        handleDrop(providers: providers)
                    }
                }
            }

            // 可选挂载已有覆写脚本
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
                .frame(maxWidth: 200)
                Spacer()
            }

            Toggle("添加后立即设为当前生效配置", isOn: $activateImmediately)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .disabled(submitting)

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
                Text(errorMessage).font(.system(size: 11)).foregroundColor(.red)
            }

            HStack {
                Spacer()
                Button("取消") { isPresented = false }.disabled(submitting)
                Button(submitting ? "正在导入…" : "添加") { submit() }
                    .buttonStyle(.borderedProminent)
                    .disabled(submitting || !isValid)
            }
        }
        .padding(22)
        .frame(width: 520)
    }

    private var isValid: Bool {
        if sourceTab == 0 {
            return !urls.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } else {
            return !localContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func chooseLocalFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, UTType(filenameExtension: "yaml") ?? .plainText, UTType(filenameExtension: "yml") ?? .plainText]
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
                } else if sourceTab == 0 {
                    // 从 URL 导入：根据行数与内容自动判断
                    let trimmed = urls.trimmingCharacters(in: .whitespacesAndNewlines)
                    let lines = trimmed.split(whereSeparator: \.isNewline).map(String.init)
                    let isSingle = lines.count == 1

                    await MainActor.run {
                        progressValue = 0.5
                        progressStage = "正在向订阅端拉取数据并校验规则…"
                    }

                    if isSingle {
                        // 尝试单订阅导入
                        createdConfig = try await state.createConfigAndReturn(
                            name: name,
                            kind: "subscription",
                            url: lines[0],
                            content: "",
                            urls: [],
                            activate: activateImmediately
                        )
                    } else {
                        // 节点池聚合导入
                        createdConfig = try await state.createConfigAndReturn(
                            name: name,
                            kind: "nodes",
                            url: "",
                            content: "",
                            urls: lines,
                            activate: activateImmediately
                        )
                    }
                } else {
                    // 从文件导入：完整配置
                    await MainActor.run {
                        progressValue = 0.5
                        progressStage = "正在解析并进行内核规则校验…"
                    }
                    createdConfig = try await state.createConfigAndReturn(
                        name: name,
                        kind: "subscription",
                        url: "",
                        content: localContent,
                        urls: [],
                        activate: activateImmediately
                    )
                }

                createdConfigID = createdConfig.id

                // 如果指定了覆写脚本，进行绑定
                if !selectedScriptId.isEmpty {
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
