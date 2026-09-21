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

            // 状态与异常提示 (规范胶囊式呈现)
            if let error = state.configMutationError {
                HStack {
                    InlineStatusPill(kind: .error(error), onDismiss: {
                        state.configMutationError = nil
                    })
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // 主内容区分支展示
            if activeTab == .profiles {
                if state.configs.isEmpty {
                    Spacer()
                    ContentUnavailableView("暂无配置", systemImage: "doc.badge.plus", description: Text("添加 sing-box 订阅、Clash 配置或组合节点"))
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
        HStack(spacing: 12) {
            // 左侧状态指示
            ZStack {
                Circle()
                    .fill(config.active ? Color.green.opacity(0.15) : Color.primary.opacity(0.05))
                    .frame(width: 34, height: 34)
                Image(systemName: config.active ? "checkmark.circle.fill" : (config.kind == "subscription" ? "globe" : "square.stack.3d.up"))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(config.active ? .green : .secondary)
            }

            // 中部核心元数据
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(config.name)
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundColor(config.active ? .primary : .primary.opacity(0.9))
                        .lineLimit(1)

                    Text(config.kind == "subscription" ? "完整订阅" : (config.name == "Default" ? "Default" : "节点聚合"))
                        .font(.system(size: 9.5, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background((config.kind == "subscription" ? Color.blue : Color.purple).opacity(0.12))
                        .foregroundColor(config.kind == "subscription" ? .blue : .purple)
                        .clipShape(Capsule())

                    Text(configSummaryText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)

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
                        Text("当前生效")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundColor(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }

                HStack(spacing: 8) {
                    if let scriptName = boundScriptName {
                        HStack(spacing: 3) {
                            Image(systemName: "curlybraces")
                                .font(.system(size: 9))
                                .foregroundColor(.orange)
                            Text("覆写: \(scriptName)")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.primary.opacity(0.85))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }

                    if !config.lastError.isEmpty {
                        InlineStatusPill(kind: .warning(config.lastError))
                    } else if let refresh = config.recentRefreshes?.first, refresh.at > 0 {
                        Text("更新于 \(Date(timeIntervalSince1970: TimeInterval(refresh.at)).formatted(date: .omitted, time: .shortened))")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundColor(.secondary.opacity(0.8))
                    }
                }
            }

            Spacer()

            // 右侧操作工具栏 (显式可点击，不再隐藏在右键)
            HStack(spacing: 8) {
                // 1. 刷新订阅按钮
                Button(action: {
                    state.refreshConfig(id: config.id)
                }) {
                    if isUpdating {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .buttonStyle(.exquisiteSecondary(height: 26))
                .disabled(isUpdating || state.isConfigMutationInFlight)
                .help("刷新并拉取最新订阅")

                // 2. 启用配置按钮 (未激活时直观可见)
                if !config.active {
                    Button(action: {
                        state.activateConfig(id: config.id)
                    }) {
                        Text("启用")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .buttonStyle(.exquisitePrimary(height: 26, cornerRadius: AsterMetrics.radiusControl))
                    .help("激活并切换为此配置")
                }

                // 3. 更多选项菜单
                Menu {
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
                        Label("绑定覆写脚本", systemImage: "curlybraces")
                    }

                    Button {
                        onSwitchToOverrides()
                    } label: {
                        Label("打开覆写管理", systemImage: "slider.horizontal.3")
                    }

                    Divider()

                    Button {
                        ClipboardHelper.copy(config.name)
                    } label: {
                        Label("复制配置名称", systemImage: "doc.on.doc")
                    }

                    Divider()

                    Button(role: .destructive) {
                        state.deleteConfig(id: config.id)
                    } label: {
                        Label("删除配置", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.exquisiteSecondary(height: 26))
                .help("更多配置操作")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background {
            if config.active {
                RoundedRectangle(cornerRadius: AsterMetrics.radiusCard, style: .continuous)
                    .fill(Color.accentColor.opacity(0.08))
            } else {
                RoundedRectangle(cornerRadius: AsterMetrics.radiusCard, style: .continuous)
                    .fill(.ultraThinMaterial)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: AsterMetrics.radiusCard, style: .continuous)
                .strokeBorder(
                    config.active ? Color.accentColor.opacity(0.4) : (isHovered ? Color.primary.opacity(0.18) : Color.primary.opacity(0.06)),
                    lineWidth: config.active ? 1.0 : 0.5
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: AsterMetrics.radiusCard, style: .continuous))
        .onTapGesture {
            if !config.active {
                state.activateConfig(id: config.id)
            }
        }
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
                ClipboardHelper.copy(config.name)
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
            } catch {
                let message = "更新「\(config.name)」的覆写脚本失败：\(error.localizedDescription)"
                state.configMutationError = message
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

// MARK: - 全新重构的添加订阅与配置模态 (AddSubscriptionSheet)
public struct AddSubscriptionSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject private var state = AsterState.shared

    public enum ImportMode: Int, CaseIterable {
        case singleUrl = 0
        case nodePool = 1
        case localFile = 2

        var title: String {
            switch self {
            case .singleUrl: return "单订阅托管"
            case .nodePool: return "节点聚合池"
            case .localFile: return "本地配置文件"
            }
        }

        var icon: String {
            switch self {
            case .singleUrl: return "link.badge.plus"
            case .nodePool: return "circle.hexagongrid.fill"
            case .localFile: return "doc.text.fill"
            }
        }
    }

    @State private var importMode: ImportMode = .singleUrl
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
        switch importMode {
        case .singleUrl:
            return !singleUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .nodePool:
            return sourceCount > 0
        case .localFile:
            return !localContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var namePlaceholder: String {
        switch importMode {
        case .singleUrl:
            return "选填，未填写时自动解析域名或备注"
        case .nodePool:
            return "选填，默认命名为「节点订阅聚合」"
        case .localFile:
            return "选填，未填写时自动提取文件名"
        }
    }

    private var detectedFormatMeta: (icon: String, text: String) {
        let trimmed = singleUrl.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty {
            return ("info.circle", "支持主流格式：Clash YAML、sing-box JSON、Base64 订阅链接等")
        }
        if trimmed.contains("clash") {
            return ("bolt.horizontal", "识别为 Clash 规则订阅，导入后将自动提取节点并建立分流策略")
        } else if trimmed.contains("sing-box") || (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) {
            return ("shippingbox", "识别为 sing-box 原生 JSON 配置，将以完整托管模式导入")
        } else if trimmed.contains("b64") || trimmed.contains("base64") || trimmed.contains("sip002") {
            return ("lock", "识别为 Base64 节点订阅，将自动解码并聚合代理节点")
        } else {
            return ("globe", "智能自适应模式：系统拉取时将自动探查格式并提取有效节点")
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // 顶栏：标题与图标
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 38, height: 38)
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.accentColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("添加配置与订阅")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.primary)
                    Text("导入机场订阅源或本地配置，支持多协议自动识别转换")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()
            }

            // 模式切换器：高质感三合一药丸选择器
            HStack(spacing: 4) {
                ForEach(ImportMode.allCases, id: \.self) { mode in
                    Button {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            importMode = mode
                            errorMessage = nil
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: mode.icon)
                                .font(.system(size: 11.5, weight: importMode == mode ? .semibold : .regular))
                            Text(mode.title)
                                .font(.system(size: 11.5, weight: importMode == mode ? .semibold : .medium))
                        }
                        .foregroundColor(importMode == mode ? .primary : .secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(importMode == mode ? Color.primary.opacity(0.08) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(importMode == mode ? Color.primary.opacity(0.12) : Color.clear, lineWidth: 0.8)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(submitting)
                }
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 0.8)
            )

            // 模式主体区域
            Group {
                switch importMode {
                case .singleUrl:
                    singleUrlView
                case .nodePool:
                    nodePoolView
                case .localFile:
                    localFileView
                }
            }

            // 通用配置与覆写设置卡片
            VStack(alignment: .leading, spacing: 10) {
                // 配置名称
                VStack(alignment: .leading, spacing: 5) {
                    Text("配置名称（可选）")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                    TextField(namePlaceholder, text: $name)
                        .textFieldStyle(.roundedBorder)
                        .disabled(submitting)
                }

                // 挂载覆写脚本
                HStack(spacing: 10) {
                    Text("挂载覆写脚本:")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
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
                    .frame(maxWidth: 240)
                    .disabled(submitting)
                    Spacer()
                }

                Divider().opacity(0.4)

                // 立即激活开关
                Toggle(isOn: $activateImmediately) {
                    HStack(spacing: 6) {
                        Text("添加成功后立即激活此配置")
                            .font(.system(size: 11.5))
                            .foregroundColor(.primary)
                        Text("(平滑重载当前核心)")
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(submitting)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: AsterMetrics.radiusCard, style: .continuous)
                    .fill(Color.primary.opacity(0.02))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AsterMetrics.radiusCard, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 0.8)
            )

            // 进度条
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
                        ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                        Text(progressStage).font(.system(size: 11)).foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }

            // 错误提示 (规范就地反馈)
            if let errorMessage {
                HStack {
                    InlineStatusPill(kind: .error(errorMessage), onDismiss: {
                        self.errorMessage = nil
                    })
                    Spacer()
                }
                .padding(.vertical, 2)
            }

            // 底部操作按钮
            HStack(spacing: 12) {
                Spacer()
                Button("取消") { isPresented = false }
                    .buttonStyle(.exquisiteSecondary(height: 30, cornerRadius: AsterMetrics.radiusControl))
                    .keyboardShortcut(.cancelAction)
                    .disabled(submitting)

                Button(action: { submit() }) {
                    HStack(spacing: 6) {
                        if submitting {
                            ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                            Text("正在处理…")
                        } else {
                            Image(systemName: "square.and.arrow.down.fill")
                                .font(.system(size: 11))
                            Text("立即导入配置")
                        }
                    }
                }
                .buttonStyle(.exquisitePrimary(height: 30, cornerRadius: AsterMetrics.radiusControl))
                .keyboardShortcut(.defaultAction)
                .disabled(submitting || !isValid)
            }
        }
        .padding(22)
        .frame(width: 540)
    }

    // MARK: - 子视图: 单订阅托管
    private var singleUrlView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("订阅链接 (HTTP / HTTPS):")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)

            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "link")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    TextField("https://example.com/sub?...", text: $singleUrl)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                    if !singleUrl.isEmpty {
                        Button {
                            singleUrl = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: AsterMetrics.radiusControl, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AsterMetrics.radiusControl, style: .continuous)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 0.8)
                )

                Button {
                    pasteFromClipboard()
                } label: {
                    Label("粘贴", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.exquisiteSecondary(height: 28, cornerRadius: AsterMetrics.radiusControl))
                .disabled(submitting)
            }

            // 智能识别提示徽章
            HStack(alignment: .center, spacing: 6) {
                let meta = detectedFormatMeta
                Image(systemName: meta.icon)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text(meta.text)
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: - 子视图: 节点聚合池
    private var nodePoolView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("订阅链接列表（每行一个，系统将提取全部节点）：")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                Text("已识别 \(sourceCount) 个有效订阅源")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundColor(sourceCount > 0 ? .accentColor : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(Capsule())
            }

            TextEditor(text: $multiUrls)
                .font(.system(size: 11.5, design: .monospaced))
                .frame(height: 100)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: AsterMetrics.radiusControl, style: .continuous)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 0.8)
                )
                .clipShape(RoundedRectangle(cornerRadius: AsterMetrics.radiusControl, style: .continuous))
                .disabled(submitting)

            HStack(spacing: 5) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary.opacity(0.8))
                Text("支持 Clash YAML、Base64 等各类订阅并发提取节点。")
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary.opacity(0.85))
                Spacer()
                Button {
                    appendFromClipboard()
                } label: {
                    Label("追加剪贴板", systemImage: "plus.square.on.square")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                .disabled(submitting)

                if !multiUrls.isEmpty {
                    Text("•").foregroundColor(.secondary.opacity(0.5))
                    Button("清空") {
                        multiUrls = ""
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .disabled(submitting)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: - 子视图: 本地配置文件
    private var localFileView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("选择或拖拽本地配置文件:")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)

            ZStack {
                RoundedRectangle(cornerRadius: AsterMetrics.radiusCard, style: .continuous)
                    .strokeBorder(
                        isDropTargeted ? Color.accentColor : Color.primary.opacity(0.15),
                        style: StrokeStyle(lineWidth: 1.5, dash: [5])
                    )
                    .background(
                        RoundedRectangle(cornerRadius: AsterMetrics.radiusCard, style: .continuous)
                            .fill(isDropTargeted ? Color.accentColor.opacity(0.06) : Color.primary.opacity(0.015))
                    )

                if !localFileName.isEmpty {
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "doc.badge.gearshape.fill")
                                .font(.system(size: 20))
                                .foregroundColor(.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(localFileName)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundColor(.primary)
                                HStack(spacing: 6) {
                                    Text(Formatters.bytesString(Int64(localContent.utf8.count)))
                                    Text("•")
                                    Text(localFileName.hasSuffix(".json") ? "sing-box JSON" : "Clash YAML")
                                }
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button("更换文件…") { chooseLocalFile() }
                                .buttonStyle(.exquisiteSecondary(height: 26, cornerRadius: AsterMetrics.radiusControl))
                                .disabled(submitting)
                        }
                        .padding(14)
                    }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 24))
                            .foregroundColor(.secondary)
                        Text("点击选择或将 .json / .yaml / .yml 文件拖拽至此")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Button("选择文件…") { chooseLocalFile() }
                            .buttonStyle(.exquisiteSecondary(height: 26, cornerRadius: AsterMetrics.radiusControl))
                            .disabled(submitting)
                    }
                    .padding(16)
                }
            }
            .frame(height: 108)
            .onDrop(of: [UTType.fileURL], isTargeted: &isDropTargeted) { providers in
                handleDrop(providers: providers)
            }
        }
    }

    private func pasteFromClipboard() {
        if let string = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty {
            singleUrl = string
        }
    }

    private func appendFromClipboard() {
        if let string = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty {
            if multiUrls.isEmpty {
                multiUrls = string
            } else {
                multiUrls += "\n" + string
            }
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

    @MainActor
    private func submit() {
        submitting = true
        errorMessage = nil
        progressValue = 0.2
        progressStage = "正在准备解析配置数据…"

        Task { @MainActor in
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
                    progressValue = 0.7
                    progressStage = "正在重试挂载覆写脚本…"
                } else {
                    var finalName = name.trimmingCharacters(in: .whitespacesAndNewlines)

                    switch importMode {
                    case .singleUrl:
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

                        progressValue = 0.5
                        progressStage = "正在向订阅端拉取数据并校验规则…"

                        createdConfig = try await state.createConfigAndReturn(
                            name: finalName,
                            kind: "subscription",
                            url: trimmedUrl,
                            content: "",
                            urls: [],
                            activate: activateImmediately
                        )

                    case .nodePool:
                        let lines = multiUrlLines
                        guard !lines.isEmpty else {
                            throw NSError(domain: "Aster", code: -1, userInfo: [NSLocalizedDescriptionKey: "请至少输入一行有效的订阅链接"])
                        }

                        if finalName.isEmpty {
                            finalName = "节点订阅聚合"
                        }

                        progressValue = 0.5
                        progressStage = "正在并发抓取多源订阅并提取有效节点…"

                        createdConfig = try await state.createConfigAndReturn(
                            name: finalName,
                            kind: "nodes",
                            url: "",
                            content: "",
                            urls: lines,
                            activate: activateImmediately
                        )

                    case .localFile:
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

                        progressValue = 0.5
                        progressStage = "正在解析并进行内核规则校验…"

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
                    progressValue = 0.8
                    progressStage = "正在挂载覆写脚本…"
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

                progressValue = 1.0
                progressStage = activateImmediately ? "配置已生效！" : "配置添加成功！"
                createdConfigID = nil
                try? await Task.sleep(for: .milliseconds(300))
                isPresented = false
            } catch {
                errorMessage = error.localizedDescription
                submitting = false
                progressValue = 0.0
                progressStage = ""
            }
        }
    }
}

public typealias AddConfigSheet = AddSubscriptionSheet
