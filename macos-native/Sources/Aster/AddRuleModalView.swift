import SwiftUI
import AppKit

// MARK: - 1. 规则类型定义
public enum AddRuleType: String, CaseIterable, Identifiable {
    case domainSuffix = "DOMAIN-SUFFIX"
    case domain = "DOMAIN"
    case domainKeyword = "DOMAIN-KEYWORD"
    case ipCIDR = "IP-CIDR"
    case processName = "PROCESS-NAME"
    case processPath = "PROCESS-PATH"

    public var id: String { rawValue }
    public var title: String { rawValue }

    public var apiMatchKind: String {
        switch self {
        case .domainSuffix: return "domain_suffix"
        case .domain: return "domain"
        case .domainKeyword: return "domain_keyword"
        case .ipCIDR: return "ip_cidr"
        case .processName: return "process_name"
        case .processPath: return "process_path"
        }
    }

    public var explanation: String {
        switch self {
        case .domainSuffix:
            return "匹配该域名及所有子域名（如 'google.com' 匹配 'www.google.com' 与 'mail.google.com'）"
        case .domain:
            return "完全精确匹配完整域名（'www.google.com' 不会匹配根域名或其他二级域）"
        case .domainKeyword:
            return "目标域名只要包含该关键词即可触发匹配"
        case .ipCIDR:
            return "匹配目标 IP 地址或子网 CIDR（如 192.168.1.0/24 或 1.1.1.1/32）"
        case .processName:
            return "根据发起连接的应用进程名称精确匹配（如 DingTalk、Safari、curl）"
        case .processPath:
            return "根据发起连接的可执行文件完整绝对路径匹配"
        }
    }
}

// MARK: - 2. 多态情景类型
public enum AddRuleSituation: Equatable {
    case webpage(url: String, domain: String)
    case domain(host: String)
    case process(name: String, path: String)
    case custom
}

// MARK: - 3. 弹窗上下文
public struct AddRuleContext: Identifiable {
    public let id = UUID()
    public var situation: AddRuleSituation
    public var title: String
    public var subtitle: String
    public var appIcon: NSImage?
    public var defaultType: AddRuleType
    public var defaultValue: String
    public var defaultAction: String

    public init(
        situation: AddRuleSituation,
        title: String,
        subtitle: String,
        appIcon: NSImage? = nil,
        defaultType: AddRuleType = .domainSuffix,
        defaultValue: String = "",
        defaultAction: String = "DIRECT"
    ) {
        self.situation = situation
        self.title = title
        self.subtitle = subtitle
        self.appIcon = appIcon
        self.defaultType = defaultType
        self.defaultValue = defaultValue
        self.defaultAction = defaultAction
    }

    public static func forWebpage(url: String, domain: String, icon: NSImage?) -> AddRuleContext {
        let cleanHost = domain.isEmpty ? (URL(string: url)?.host ?? url) : domain
        let rootDomain = extractRootDomain(cleanHost.isEmpty ? url : cleanHost)
        return AddRuleContext(
            situation: .webpage(url: url, domain: cleanHost),
            title: "为当前网页添加规则",
            subtitle: url.isEmpty ? (cleanHost.isEmpty ? "手动输入分流目标" : cleanHost) : url,
            appIcon: icon,
            defaultType: .domainSuffix,
            defaultValue: rootDomain,
            defaultAction: "DIRECT"
        )
    }

    public static func forDomain(host: String, appName: String?, appIcon: NSImage?, preferredAction: String? = nil) -> AddRuleContext {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let rootDomain = extractRootDomain(cleanHost)
        let isIP = cleanHost.range(of: #"^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}"#, options: .regularExpression) != nil
        return AddRuleContext(
            situation: .domain(host: cleanHost),
            title: "为目标域名添加规则",
            subtitle: cleanHost,
            appIcon: appIcon,
            defaultType: isIP ? .ipCIDR : .domainSuffix,
            defaultValue: isIP ? (cleanHost.contains("/") ? cleanHost : "\(cleanHost)/32") : rootDomain,
            defaultAction: preferredAction ?? "DIRECT"
        )
    }

    public static func forProcess(name: String, path: String, icon: NSImage?, preferredAction: String? = nil) -> AddRuleContext {
        let val = path.isEmpty ? name : path
        return AddRuleContext(
            situation: .process(name: name, path: path),
            title: "为进程添加规则",
            subtitle: name,
            appIcon: icon,
            defaultType: path.isEmpty ? .processName : .processPath,
            defaultValue: val,
            defaultAction: preferredAction ?? "DIRECT"
        )
    }

    public static func forCustom(type: AddRuleType = .domainSuffix, value: String = "", action: String = "DIRECT") -> AddRuleContext {
        return AddRuleContext(
            situation: .custom,
            title: "添加分流规则",
            subtitle: "创建自定义网络路由与分流策略",
            appIcon: nil,
            defaultType: type,
            defaultValue: value,
            defaultAction: action
        )
    }

    public static func extractRootDomain(_ hostOrURL: String) -> String {
        var raw = hostOrURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "" }

        if let url = URL(string: raw), let h = url.host, !h.isEmpty {
            raw = h
        } else if let url = URL(string: "https://" + raw), let h = url.host, !h.isEmpty {
            raw = h
        } else {
            if let colonIdx = raw.firstIndex(of: ":") {
                raw = String(raw[..<colonIdx])
            }
            if let slashIdx = raw.firstIndex(of: "/") {
                raw = String(raw[..<slashIdx])
            }
        }
        let parts = raw.components(separatedBy: ".")
        if parts.count >= 2 {
            let lastTwo = parts.suffix(2).joined(separator: ".").lowercased()
            let cctlds = ["com.cn", "net.cn", "org.cn", "gov.cn", "co.uk", "com.tw", "com.hk", "edu.cn"]
            if parts.count >= 3 && cctlds.contains(lastTwo) {
                return parts.suffix(3).joined(separator: ".")
            }
            return lastTwo
        }
        return raw
    }
}

// MARK: - 4. 因果流水线全新规则弹窗
public struct AddRuleModalView: View {
    public let context: AddRuleContext
    public var onDismiss: () -> Void

    @ObservedObject private var state = AsterState.shared

    @State private var selectedType: AddRuleType
    @State private var ruleValue: String
    @State private var selectedAction: String
    @State private var insertAtTop: Bool = true
    @State private var sanitizedTip: String? = nil
    @State private var isSubmitting: Bool = false
    @State private var submissionError: String? = nil

    public init(context: AddRuleContext, onDismiss: @escaping () -> Void) {
        self.context = context
        self.onDismiss = onDismiss
        _selectedType = State(initialValue: context.defaultType)
        _ruleValue = State(initialValue: context.defaultValue)
        _selectedAction = State(initialValue: context.defaultAction)
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 顶栏：标题与图标
            HStack(alignment: .center, spacing: 14) {
                if let icon = context.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 38, height: 38)
                        .cornerRadius(8)
                        .shadow(color: Color.black.opacity(0.1), radius: 2, y: 1)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.accentColor.opacity(0.12))
                            .frame(width: 38, height: 38)
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.accentColor)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(context.title)
                        .font(.system(size: 14, weight: .bold))
                    Text(context.subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 14)

            Divider().opacity(0.3)

            // 表单内容区：因果流水线三部曲
            VStack(alignment: .leading, spacing: 18) {
                // 阶段 1：匹配条件 (Condition)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("1. 匹配条件")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.secondary)
                        Spacer()
                    }

                    HStack(spacing: 8) {
                        Picker("", selection: $selectedType) {
                            ForEach(AddRuleType.allCases) { type in
                                Text(type.title).tag(type)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 150)

                        HStack(spacing: 4) {
                            TextField("目标域名、IP 或进程名", text: $ruleValue)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                                .onChange(of: ruleValue) { _, newValue in
                                    autoSanitizeInput(newValue)
                                }

                            if selectedType == .processName || selectedType == .processPath {
                                Button("选取 App…") {
                                    pickApplication()
                                }
                                .buttonStyle(.exquisiteSecondary(height: 24))
                            }
                        }
                    }

                    // 辅助提示与自动提纯反显
                    if let tip = sanitizedTip {
                        InfoNoticeBanner(text: tip, icon: "checkmark.circle.fill", style: .success)
                    } else {
                        Text(selectedType.explanation)
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary.opacity(0.8))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .asterSubcard(cornerRadius: 8, padding: 12)

                // 流向指示箭头
                HStack {
                    Spacer()
                    Image(systemName: "arrow.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.secondary.opacity(0.4))
                    Spacer()
                }
                .padding(.vertical, -10)

                // 阶段 2：执行策略 (Route Policy)
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("2. 路由策略")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.secondary)
                        Spacer()
                    }

                    // 常用动作三大胶囊
                    HStack(spacing: 8) {
                        SelectionCapsule(
                            title: "DIRECT 直连",
                            icon: "arrow.up.right",
                            isSelected: selectedAction.uppercased() == "DIRECT",
                            tintColor: .green
                        ) {
                            selectedAction = "DIRECT"
                        }
                        SelectionCapsule(
                            title: "PROXY 代理",
                            icon: "paperplane.fill",
                            isSelected: selectedAction.uppercased() == "PROXY",
                            tintColor: .accentColor
                        ) {
                            selectedAction = "PROXY"
                        }
                        SelectionCapsule(
                            title: "REJECT 拦截",
                            icon: "xmark.shield.fill",
                            isSelected: selectedAction.uppercased() == "REJECT",
                            tintColor: .red
                        ) {
                            selectedAction = "REJECT"
                        }
                    }

                    // 自定义策略组与节点下拉选择器
                    HStack(spacing: 8) {
                        Text("或指定策略组 / 节点:")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)

                        Picker("", selection: $selectedAction) {
                            Text("（遵循上方快捷动作）").tag(selectedActionIsQuick ? selectedAction : "")

                            // 优先置顶展示由覆写脚本创建的自定义策略组
                            if !state.strategyGroups.isEmpty {
                                Divider()
                                ForEach(state.strategyGroups) { g in
                                    Text("策略组: \(g.name)").tag(g.tag)
                                }
                            }

                            // 展示可用节点
                            if !state.nodes.isEmpty {
                                Divider()
                                ForEach(state.nodes) { n in
                                    Text("节点: \(n.name)").tag(n.tag)
                                }
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                    }
                }
                .asterSubcard(cornerRadius: 8, padding: 12)

                // 阶段 3：插入优先级
                HStack(spacing: 16) {
                    Text("执行优先级:")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)

                    Picker("", selection: $insertAtTop) {
                        Text("置顶优先匹配（推荐）").tag(true)
                        Text("追加到底部").tag(false)
                    }
                    .pickerStyle(.radioGroup)
                    .horizontalRadioGroupLayout()
                    .font(.system(size: 11))

                    Spacer()
                }
                .padding(.horizontal, 4)
            }
            .padding(20)

            Divider().opacity(0.3)

            // 底部预览与确认栏
            HStack(spacing: 12) {
                // 实时预览徽章
                HStack(spacing: 4) {
                    Text("预览:").font(.system(size: 10.5)).foregroundColor(.secondary)
                    Text("\(selectedType.rawValue), \(cleanValue)")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundColor(.primary.opacity(0.85))
                        .lineLimit(1)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundColor(.secondary.opacity(0.7))
                    Text(selectedAction)
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundColor(.primary)
                }

                Spacer()

                if let err = submissionError {
                    Text(err).font(.system(size: 11)).foregroundColor(.red).lineLimit(1)
                }

                Button("取消") {
                    onDismiss()
                }
                .buttonStyle(.exquisiteSecondary(height: 28, cornerRadius: AsterMetrics.radiusControl))
                .keyboardShortcut(.cancelAction)
                .disabled(isSubmitting)

                Button {
                    submitRule()
                } label: {
                    HStack(spacing: 4) {
                        if isSubmitting {
                            ProgressView().controlSize(.mini).frame(width: 10, height: 10)
                        }
                        Text("添加规则")
                    }
                }
                .buttonStyle(.exquisitePrimary(height: 28, cornerRadius: AsterMetrics.radiusControl))
                .disabled(cleanValue.isEmpty || isSubmitting)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
        }
        .frame(width: 480)
        .unifiedWindowBackdrop(material: .popover, hasHairlineBorder: true)
    }

    private var cleanValue: String {
        ruleValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var selectedActionIsQuick: Bool {
        ["DIRECT", "PROXY", "REJECT"].contains(selectedAction.uppercased())
    }

    private func autoSanitizeInput(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard selectedType == .domain || selectedType == .domainSuffix else {
            sanitizedTip = nil
            return
        }

        if trimmed.contains("://") || trimmed.contains("/") || trimmed.contains(":") {
            let extracted = AddRuleContext.extractRootDomain(trimmed)
            if !extracted.isEmpty && extracted != trimmed {
                self.ruleValue = extracted
                self.sanitizedTip = "已自动剔除协议/路径，提取纯净域名: \(extracted)"
                return
            }
        }
        self.sanitizedTip = nil
    }

    private func pickApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let appURL = panel.url {
            let appName = appURL.deletingPathExtension().lastPathComponent
            if selectedType == .processName {
                self.ruleValue = appName
            } else {
                self.ruleValue = appURL.path
            }
        }
    }

    private func submitRule() {
        guard !cleanValue.isEmpty, !isSubmitting else { return }
        isSubmitting = true
        submissionError = nil

        let matchKind = selectedType.apiMatchKind
        let act = selectedAction.lowercased()

        Task { @MainActor in
            do {
                try await state.addRule(match: matchKind, value: cleanValue, action: act)
                self.isSubmitting = false
                self.onDismiss()
            } catch {
                self.isSubmitting = false
                self.submissionError = error.localizedDescription
            }
        }
    }
}

// MARK: - 5. 独立模态窗口控制器
@MainActor
public class AddRuleWindowController: NSObject, NSWindowDelegate {
    public static let shared = AddRuleWindowController()
    private var window: NSWindow?

    public func show(context: AddRuleContext) {
        let targetWidth: CGFloat = 480
        let targetHeight: CGFloat = 420

        if window == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: targetWidth, height: targetHeight),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            win.title = context.title
            win.titlebarAppearsTransparent = true
            win.titleVisibility = .hidden
            win.titlebarSeparatorStyle = .none
            win.isMovableByWindowBackground = true
            win.backgroundColor = .clear
            win.isOpaque = false
            win.hasShadow = true
            win.isReleasedWhenClosed = false
            win.delegate = self
            self.window = win
        }

        guard let win = self.window else { return }
        let rootView = AddRuleModalView(context: context) { [weak self] in
            self?.window?.orderOut(nil)
        }

        let hosting = NSHostingView(rootView: rootView)
        win.contentView = hosting
        win.title = context.title
        win.setContentSize(NSSize(width: targetWidth, height: targetHeight))
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}
