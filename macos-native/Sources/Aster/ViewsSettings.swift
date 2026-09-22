import SwiftUI
import Charts
import AppKit

public struct SettingsView: View {
    @ObservedObject var state = AsterState.shared
    @AppStorage("sortNodesByDelay") private var sortNodesByDelay: Bool = false
    @AppStorage("minimizeOnLaunch") private var minimizeOnLaunch: Bool = false
    @AppStorage("showStatusBarSpeed") private var showStatusBarSpeed: Bool = true
    @AppStorage("keepDockWhenWindowClosed") private var keepDockWhenWindowClosed: Bool = false
    // WebDAV 持久化配置
    @AppStorage("webdavServerURL") private var webdavServerURL: String = ""
    @AppStorage("webdavUsername") private var webdavUsername: String = ""
    @AppStorage("webdavRemotePath") private var webdavRemotePath: String = "/Aster"
    @AppStorage("webdavLastBackupAt") private var webdavLastBackupAt: Double = 0
    @State private var webdavPassword: String = ""
    @State private var webdavCredentialError: String?
    @FocusState private var isEditingWebDAVPassword: Bool

    // 端口自定义状态
    @State private var mixedPortInput: String = "6780"
    @State private var isSavingPorts: Bool = false

    // 测速探针
    @State private var probePreset: String = "google"
    @State private var customProbeURL: String = ""
    @State private var isCustomProbe: Bool = false

    // 备份状态动效
    @State private var isBackingUpICloud: Bool = false
    @State private var isRestoringICloud: Bool = false
    @State private var isTestingWebDAV: Bool = false
    @State private var isBackingUpWebDAV: Bool = false
    @State private var isRestoringWebDAV: Bool = false
    @State private var isClearingProxy: Bool = false
    @State private var isFlushingDNS: Bool = false

    // 精致就地状态反馈指示 (InlineStatusPill)
    @State private var portStatus: InlineStatusKind? = nil
    @State private var probeStatus: InlineStatusKind? = nil
    @State private var webdavStatus: InlineStatusKind? = nil
    @State private var icloudStatus: InlineStatusKind? = nil
    @State private var clearProxyStatus: InlineStatusKind? = nil

    // 确认弹窗
    @State private var showConfirmICloudRestore: Bool = false
    @State private var showConfirmWebDAVRestore: Bool = false

    @State private var selectedTab: SettingsTab = .general

    public enum SettingsTab: String, CaseIterable, Identifiable {
        case general = "通用设置"
        case network = "网络与端口"
        case routing = "分流与测速"
        case backup = "备份与恢复"
        case about = "关于与系统"

        public var id: String { rawValue }
    }

    private func formatTimestamp(_ ts: Int64) -> String {
        guard ts > 0 else { return "暂无备份记录" }
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return df.string(from: date)
    }

    private func syncProbeFromState() {
        let current = state.status.delayURL ?? "https://www.gstatic.com/generate_204"
        if current.contains("gstatic") {
            probePreset = "google"
            isCustomProbe = false
        } else if current.contains("cloudflare") {
            probePreset = "cloudflare"
            isCustomProbe = false
        } else if current.contains("apple") {
            probePreset = "apple"
            isCustomProbe = false
        } else {
            probePreset = "custom"
            isCustomProbe = true
            customProbeURL = current
        }
    }

    @MainActor
    private func syncFromBackendSettings() {
        mixedPortInput = "\(state.status.mixedPort ?? 6780)"
        Task { @MainActor in
            await state.fetchSettings()
            if let p = state.status.mixedPort, p > 0 {
                mixedPortInput = "\(p)"
            }
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 顶部统一规范：左侧 26pt 大标题 + 右侧分类 Segmented Picker
            PageHeader(title: "设置") {
                Picker("", selection: $selectedTab) {
                    ForEach(SettingsTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 440)
            }

            Divider().opacity(0.4)

            // 分类内容区域
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch selectedTab {
                    case .general:
                        generalTabContent
                    case .network:
                        networkTabContent
                    case .routing:
                        routingTabContent
                    case .backup:
                        backupTabContent
                    case .about:
                        aboutTabContent
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
            }
            .scrollIndicators(.hidden)
        }
        .onAppear {
            syncProbeFromState()
            syncFromBackendSettings()
            loadWebDAVCredential()
            Task { await state.fetchICloudStatus() }
        }
        .onDisappear {
            saveWebDAVCredentialIfPossible()
        }
        .confirmationDialog(
            "确认从 iCloud 恢复配置？",
            isPresented: $showConfirmICloudRestore,
            titleVisibility: .visible
        ) {
            Button("立即恢复 (覆盖本地配置)", role: .destructive) {
                isRestoringICloud = true
                icloudStatus = .loading("正在从 iCloud Drive 恢复…")
                Task {
                    defer { isRestoringICloud = false }
                    do {
                        try await state.importFromICloud()
                        icloudStatus = .success("已成功从 iCloud Drive 恢复配置")
                    } catch {
                        icloudStatus = .error("恢复失败：\(error.localizedDescription)")
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("恢复会覆盖可迁移的订阅、节点选择、分流规则和应用偏好；本机端口、权限、内核路径与 API 身份保持不变。成功后 Aster 会自动重新启动。")
        }
        .confirmationDialog(
            "确认从 WebDAV 恢复配置？",
            isPresented: $showConfirmWebDAVRestore,
            titleVisibility: .visible
        ) {
            Button("立即恢复 (覆盖本地配置)", role: .destructive) {
                restoreFromWebDAV()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("恢复会覆盖可迁移的订阅、节点选择、分流规则和应用偏好；本机端口、权限、内核路径与 API 身份保持不变。成功后 Aster 会自动重新启动。")
        }
    }

    // MARK: - 通用 Tab
    private var generalTabContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            // 卡片 1: 桌面与系统交互
            VStack(alignment: .leading, spacing: 10) {
                Label("桌面与系统交互", systemImage: "macwindow.on.rectangle")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.primary)

                VStack(spacing: 12) {
                    settingSwitchRow(
                        title: "开机自动启动",
                        subtitle: "登录 macOS 后在后台自动启动并守护代理服务",
                        isOn: Binding(
                            get: { state.autostart },
                            set: { state.patchSettings(body: ["autostart": $0]) }
                        )
                    )

                    Divider()

                    settingSwitchRow(
                        title: "启动时隐藏主窗口",
                        subtitle: "启动时不弹出大窗口，仅在菜单栏保持就绪",
                        isOn: $minimizeOnLaunch
                    )

                    Divider()

                    settingSwitchRow(
                        title: "菜单栏显示实时网速",
                        subtitle: "在图标右侧显示上下行速率；关闭后菜单栏只保留图标",
                        isOn: $showStatusBarSpeed
                    )

                    Divider()

                    settingSwitchRow(
                        title: "关闭窗口后保留 Dock 图标",
                        subtitle: "开启后关闭主窗口仍留在 Dock；关闭则仅通过菜单栏访问",
                        isOn: $keepDockWhenWindowClosed
                    )

                }
                .settingsCardStyle()
            }

            // 卡片 2: 节点展示偏好
            VStack(alignment: .leading, spacing: 10) {
                Label("节点展示偏好", systemImage: "list.bullet.rectangle.portrait")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.primary)

                VStack(spacing: 12) {
                    settingSwitchRow(
                        title: "节点列表按延迟升序排序",
                        subtitle: "进入策略与节点界面时，默认将延迟最低的节点排在首位",
                        isOn: $sortNodesByDelay
                    )
                }
                .settingsCardStyle()
            }
        }
    }

    // MARK: - 2. 网络与端口 Tab
    private var networkTabContent: some View {
        let importedProfile = state.status.activeConfigKind == "subscription"
        return VStack(alignment: .leading, spacing: 18) {
            // 卡片 1: 全局网络接管与代理捕获 (实时生效)
            VStack(alignment: .leading, spacing: 10) {
                Label("网络接管与代理捕获", systemImage: "network.badge.shield.half.filled")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.primary)

                VStack(spacing: 12) {
                    settingSwitchRow(
                        title: "系统代理 (System Proxy)",
                        subtitle: "自动配置 macOS 系统网络偏好设置中的 HTTP、HTTPS 与 SOCKS 代理接入",
                        isOn: Binding(
                            get: { state.status.capture.systemProxy },
                            set: { state.setCapture(systemProxy: $0, tun: state.status.capture.tun) }
                        ),
                        isEnabled: state.status.capabilities?.systemProxy.available ?? true,
                        disabledReason: state.status.capabilities?.systemProxy.reason
                    )

                    Divider()

                    settingSwitchRow(
                        title: "虚拟网卡 (TUN 模式)",
                        subtitle: "创建独立虚拟网卡设备，全量接管 TCP/UDP 流量（包括无代理设置的终端与应用）",
                        isOn: Binding(
                            get: { state.status.capture.tun },
                            set: { state.setCapture(systemProxy: state.status.capture.systemProxy, tun: $0) }
                        ),
                        isEnabled: (state.status.capabilities?.tun.available ?? true) && !state.status.needAdmin,
                        disabledReason: state.status.needAdmin ? "需要 Helper 特权辅助组件授权" : state.status.capabilities?.tun.reason
                    )
                }
                .settingsCardStyle()
            }

            // 卡片 2: 端口自定义与监听
            VStack(alignment: .leading, spacing: 10) {
                Label("核心监听端口自定义", systemImage: "slider.horizontal.3")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.primary)

                VStack(spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("混合代理监听端口 (Mixed Port)")
                                .font(.system(size: 12.5, weight: .semibold))
                            Text("合并支持 HTTP / HTTPS 与 SOCKS5 双协议接入 (默认: 6780)")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        TextField("6780", text: $mixedPortInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                    }

                    Divider()

                    HStack(spacing: 8) {
                        Text("修改端口将自动热重载 sing-box 内核")
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                        Spacer()
                        if let portStatus {
                            InlineStatusPill(kind: portStatus, onDismiss: { self.portStatus = nil })
                        }
                        Button(action: saveCustomPorts) {
                            HStack(spacing: 4) {
                                if isSavingPorts {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: "checkmark")
                                }
                                Text("保存并重载端口")
                            }
                        }
                        .buttonStyle(.exquisitePrimary(height: 28, cornerRadius: AsterMetrics.radiusControl))
                        .disabled(isSavingPorts)
                    }
                }
                .settingsCardStyle()
            }

            // 卡片 2: 局域网共享与严格路由
            VStack(alignment: .leading, spacing: 10) {
                Label("局域网共享与路由边界", systemImage: "wifi.router")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.primary)

                VStack(spacing: 12) {
                    settingSwitchRow(
                        title: "允许局域网设备连接",
                        subtitle: "在 0.0.0.0 监听混合代理端口，允许同局域网手机、电视设备接入",
                        isOn: Binding(
                            get: { state.allowLan },
                            set: { state.patchSettings(body: ["allowLan": $0]) }
                        ),
                        isEnabled: !importedProfile,
                        disabledReason: "完整订阅由外部配置管理"
                    )

                    Divider()

                    settingSwitchRow(
                        title: "严格路由模式 (Strict Route)",
                        subtitle: "强制非本地私有网段流量全量进入虚拟网卡，严防 IPv6 与直连旁路泄露真实 IP",
                        isOn: Binding(
                            get: { state.strictRoute },
                            set: { state.patchSettings(body: ["strictRoute": $0]) }
                        ),
                        isEnabled: !importedProfile,
                        disabledReason: "完整订阅由外部配置管理"
                    )
                }
                .settingsCardStyle()
            }

            // 卡片 3: TUN 系统网卡与授权机制
            VStack(alignment: .leading, spacing: 10) {
                Label("虚拟网卡 (TUN) 安全授权机制", systemImage: "shield.lefthalf.filled")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.primary)

                HStack(spacing: 12) {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundColor(.blue)
                        .font(.system(size: 22))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("PKG 网络组件 + 常驻 Helper")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(.primary)
                        Text("便携版只能使用系统代理。虚拟网卡需要一次安装 Aster.pkg，之后由 root launchd helper 以 20 秒租约托管核心，无需每次输入密码。未安装组件时开关会保持禁用。")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                .settingsCardStyle()
            }
        }
    }

    private func saveCustomPorts() {
        guard let mixed = Int(mixedPortInput.trimmingCharacters(in: .whitespaces)) else {
            portStatus = .error("端口必须为纯数字")
            return
        }
        guard (1024...65535).contains(mixed) else {
            portStatus = .error("端口范围必须在 1024 ~ 65535 之间")
            return
        }
        isSavingPorts = true
        portStatus = .loading("正在更新端口…")
        state.patchSettings(body: [
            "mixedPort": mixed
        ])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            self.isSavingPorts = false
            self.portStatus = .success("端口已更新并生效 (\(mixed))")
        }
    }

    // MARK: - 3. 分流与测速 Tab
    private var routingTabContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Label("延迟测速与探针靶点", systemImage: "gauge.with.needle.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.primary)

                VStack(alignment: .leading, spacing: 12) {
                    Text("探针靶点预设")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)

                    Picker("测速探针", selection: $probePreset) {
                        Text("Google 204 (默认推荐)").tag("google")
                        Text("Cloudflare 204 (国内直连)").tag("cloudflare")
                        Text("Apple Captive (苹果官方)").tag("apple")
                        Text("自定义 URL").tag("custom")
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: probePreset) { _, newPreset in
                        switch newPreset {
                        case "google":
                            isCustomProbe = false
                            updateProbe("https://www.gstatic.com/generate_204", success: "已切换测速探针为 Google 204")
                        case "cloudflare":
                            isCustomProbe = false
                            updateProbe("http://cp.cloudflare.com/generate_204", success: "已切换测速探针为 Cloudflare 204")
                        case "apple":
                            isCustomProbe = false
                            updateProbe("http://captive.apple.com", success: "已切换测速探针为 Apple Captive")
                        case "custom":
                            isCustomProbe = true
                            if customProbeURL.isEmpty {
                                customProbeURL = state.status.delayURL ?? "https://www.gstatic.com/generate_204"
                            }
                        default:
                            break
                        }
                    }

                    if isCustomProbe {
                        HStack(spacing: 8) {
                            TextField("输入 HTTP/HTTPS 探针 URL...", text: $customProbeURL)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))

                            Button("保存靶点") {
                                let trimmed = customProbeURL.trimmingCharacters(in: .whitespaces)
                                guard !trimmed.isEmpty else { return }
                                updateProbe(trimmed, success: "已成功更新自定义测速靶点")
                            }
                            .buttonStyle(.exquisitePrimary(height: 28))
                        }
                    }

                    if let probeStatus {
                        InlineStatusPill(kind: probeStatus, onDismiss: { self.probeStatus = nil })
                            .padding(.vertical, 2)
                    }

                    Divider()

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("测速超时熔断阈值")
                                .font(.system(size: 12.5, weight: .semibold))
                            Text("单个节点探测超过此时长判定为超时失败")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Picker("", selection: Binding(
                            get: { state.delayTimeoutMs },
                            set: { state.patchSettings(body: ["delayTimeoutMs": $0]) }
                        )) {
                            Text("1500 ms (激进)").tag(1500)
                            Text("2500 ms (推荐)").tag(2500)
                            Text("5000 ms (宽容)").tag(5000)
                        }
                        .pickerStyle(.menu)
                        .frame(width: 140)
                    }

                    Divider()

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("并发测速线程限制")
                                .font(.system(size: 12.5, weight: .semibold))
                            Text("批量并发测速时的工作池容量")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Picker("", selection: Binding(
                            get: { state.delayConcurrency },
                            set: { state.patchSettings(body: ["delayConcurrency": $0]) }
                        )) {
                            Text("8 并发 (推荐)").tag(8)
                            Text("16 并发").tag(16)
                            Text("32 并发").tag(32)
                        }
                        .pickerStyle(.menu)
                        .frame(width: 140)
                    }
                }
                .settingsCardStyle()
            }
        }
    }

    // MARK: - 4. 备份与恢复 Tab (本地 + iCloud + WebDAV 三合一统一体系)
    private var backupTabContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            // 板块 1: 本地便携配置文件导入与导出
            VStack(alignment: .leading, spacing: 10) {
                Label("本地配置备份与还原", systemImage: "internaldrive.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.primary)

                HStack(spacing: 12) {
                    // 导出卡片
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.12))
                                    .frame(width: 34, height: 34)
                                Image(systemName: "square.and.arrow.up.fill")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.accentColor)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("导出本地备份")
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundColor(.primary)
                                Text("归档打包为 .zip 文件")
                                    .font(.system(size: 10.5))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }

                        Text("打包全部订阅源、聚合节点、覆写脚本、分流规则及应用偏好。安全脱敏，不含本机敏感网络端口与密钥凭据。")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary.opacity(0.9))
                            .lineSpacing(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 4)

                        Button(action: {
                            Task {
                                do {
                                    try await state.exportLocalBackup()
                                } catch {
                                    let alert = NSAlert()
                                    alert.messageText = "导出本地备份失败"
                                    alert.informativeText = error.localizedDescription
                                    alert.alertStyle = .warning
                                    alert.runModal()
                                }
                            }
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.up.doc.fill")
                                    .font(.system(size: 11))
                                Text("导出本地备份包…")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.exquisitePrimary(height: 28, cornerRadius: AsterMetrics.radiusControl))
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, minHeight: 150)
                    .background(
                        RoundedRectangle(cornerRadius: AsterMetrics.radiusCard, style: .continuous)
                            .fill(Color.primary.opacity(0.025))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: AsterMetrics.radiusCard, style: .continuous)
                            .stroke(Color.primary.opacity(0.06), lineWidth: 0.8)
                    )

                    // 卡片 2: 恢复历史备份
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: "arrow.counterclockwise.circle.fill")
                                .foregroundColor(.teal)
                                .font(.system(size: 14))
                            Text("本地归档恢复")
                                .font(.system(size: 13, weight: .semibold))
                            Spacer()
                        }

                        Text("选取历史导出的 Aster 本地备份文件进行全量还原。配置载入完成后，核心进程将无缝平滑重载生效。")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary.opacity(0.9))
                            .lineSpacing(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 4)

                        Button(action: {
                            Task {
                                do {
                                    try await state.importLocalBackup()
                                } catch {
                                    let alert = NSAlert()
                                    alert.messageText = "还原本地备份失败"
                                    alert.informativeText = error.localizedDescription
                                    alert.alertStyle = .warning
                                    alert.runModal()
                                }
                            }
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.down.doc.fill")
                                    .font(.system(size: 11))
                                Text("导入本地备份…")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.exquisiteSecondary(height: 28, cornerRadius: AsterMetrics.radiusControl))
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, minHeight: 150)
                    .background(
                        RoundedRectangle(cornerRadius: AsterMetrics.radiusCard, style: .continuous)
                            .fill(Color.primary.opacity(0.025))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: AsterMetrics.radiusCard, style: .continuous)
                            .stroke(Color.primary.opacity(0.06), lineWidth: 0.8)
                    )
                }
                .settingsCardStyle()
            }

            // 板块 2: iCloud Drive 苹果云端同步
            VStack(alignment: .leading, spacing: 10) {
                Label("iCloud Drive 云端同步", systemImage: "icloud.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.primary)

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("基于 macOS 本地 iCloud Drive 安全同步订阅源与分流规则。")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("上次备份：\(formatTimestamp(state.iCloudStatus.updatedAt))")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                    }

                    HStack(spacing: 12) {
                        Button(action: {
                            isBackingUpICloud = true
                            icloudStatus = .loading("正在备份至 iCloud Drive…")
                            Task {
                                defer { isBackingUpICloud = false }
                                do {
                                    try await state.exportToICloud()
                                    icloudStatus = .success("已成功备份至 iCloud Drive")
                                } catch {
                                    icloudStatus = .error("备份失败：\(error.localizedDescription)")
                                }
                            }
                        }) {
                            HStack(spacing: 4) {
                                if isBackingUpICloud {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: "arrow.up.icloud")
                                }
                                Text("立即备份至 iCloud")
                            }
                        }
                        .buttonStyle(.exquisitePrimary(height: 28, cornerRadius: AsterMetrics.radiusControl))
                        .disabled(isBackingUpICloud || isRestoringICloud)

                        Button(action: {
                            showConfirmICloudRestore = true
                        }) {
                            HStack(spacing: 4) {
                                if isRestoringICloud {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: "arrow.down.icloud")
                                }
                                Text("从 iCloud 恢复配置")
                            }
                        }
                        .buttonStyle(.exquisiteSecondary(height: 28, cornerRadius: AsterMetrics.radiusControl))
                        .disabled(!state.iCloudStatus.hasBackup || isBackingUpICloud || isRestoringICloud)
                    }

                    if let icloudStatus {
                        HStack {
                            InlineStatusPill(kind: icloudStatus, onDismiss: { self.icloudStatus = nil })
                            Spacer()
                        }
                        .padding(.top, 4)
                    }
                }
                .settingsCardStyle()
            }

            // 板块 3: WebDAV 私有网盘同步
            VStack(alignment: .leading, spacing: 10) {
                Label("WebDAV 私有云同步 (坚果云 / Nextcloud / 群晖 NAS)", systemImage: "externaldrive.connected.to.line.below.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.primary)

                VStack(alignment: .leading, spacing: 12) {
                    VStack(spacing: 8) {
                        HStack {
                            Text("服务器 URL")
                                .font(.system(size: 11.5, weight: .medium))
                                .frame(width: 80, alignment: .leading)
                            TextField("https://dav.jianguoyun.com/dav/", text: $webdavServerURL)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11.5))
                        }

                        HStack {
                            Text("用户名")
                                .font(.system(size: 11.5, weight: .medium))
                                .frame(width: 80, alignment: .leading)
                            TextField("账号 / 邮箱", text: $webdavUsername)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11.5))
                        }

                        HStack {
                            Text("密码 / Token")
                                .font(.system(size: 11.5, weight: .medium))
                                .frame(width: 80, alignment: .leading)
                            SecureField("应用专用密码", text: $webdavPassword)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11.5))
                                .focused($isEditingWebDAVPassword)
                                .onChange(of: isEditingWebDAVPassword) { _, isEditing in
                                    guard !isEditing else { return }
                                    saveWebDAVCredentialIfPossible()
                                }
                        }

                        HStack {
                            Text("存储目录")
                                .font(.system(size: 11.5, weight: .medium))
                                .frame(width: 80, alignment: .leading)
                            TextField("/Aster", text: $webdavRemotePath)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11.5))
                        }
                    }

                    if let webdavCredentialError {
                        Label(webdavCredentialError, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider()

                    HStack(spacing: 12) {
                        Button(action: testWebDAV) {
                            HStack(spacing: 4) {
                                if isTestingWebDAV {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: "antenna.radiowaves.left.and.right")
                                }
                                Text("测试连接")
                            }
                        }
                        .buttonStyle(.exquisiteSecondary(height: 28, cornerRadius: AsterMetrics.radiusControl))
                        .disabled(webdavServerURL.isEmpty || isTestingWebDAV)

                        Spacer()

                        Button(action: backupToWebDAV) {
                            HStack(spacing: 4) {
                                if isBackingUpWebDAV {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: "arrow.up.circle")
                                }
                                Text("备份至 WebDAV")
                            }
                        }
                        .buttonStyle(.exquisitePrimary(height: 28, cornerRadius: AsterMetrics.radiusControl))
                        .disabled(webdavServerURL.isEmpty || isBackingUpWebDAV || isRestoringWebDAV)

                        Button(action: {
                            showConfirmWebDAVRestore = true
                        }) {
                            HStack(spacing: 4) {
                                if isRestoringWebDAV {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: "arrow.down.circle")
                                }
                                Text("从 WebDAV 恢复")
                            }
                        }
                        .buttonStyle(.exquisiteSecondary(height: 28, cornerRadius: AsterMetrics.radiusControl))
                        .disabled(webdavServerURL.isEmpty || isBackingUpWebDAV || isRestoringWebDAV)
                    }

                    if let webdavStatus {
                        HStack {
                            InlineStatusPill(kind: webdavStatus, onDismiss: { self.webdavStatus = nil })
                            Spacer()
                        }
                        .padding(.top, 4)
                    }

                    if webdavLastBackupAt > 0 {
                        HStack {
                            Spacer()
                            Text("上次 WebDAV 备份：\(formatTimestamp(Int64(webdavLastBackupAt)))")
                                .font(.system(size: 10.5))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .settingsCardStyle()
            }
        }
    }

    private func loadWebDAVCredential() {
        do {
            webdavPassword = try WebDAVCredentialStore.production.password() ?? ""
            webdavCredentialError = nil
        } catch {
            webdavCredentialError = "无法从钥匙串读取 WebDAV 密码。\(error.localizedDescription)"
        }
    }

    private func saveWebDAVCredentialIfPossible() {
        do {
            try WebDAVCredentialStore.production.save(password: webdavPassword)
            webdavCredentialError = nil
        } catch {
            webdavCredentialError = "WebDAV 密码未能保存到钥匙串。\(error.localizedDescription)"
        }
    }

    private func makeWebDAVConfig() throws -> WebDAVConfig {
        do {
            try WebDAVCredentialStore.production.save(password: webdavPassword)
            webdavCredentialError = nil
        } catch {
            webdavCredentialError = "WebDAV 密码未能保存到钥匙串。\(error.localizedDescription)"
            throw error
        }
        return WebDAVConfig(
            serverURL: webdavServerURL,
            username: webdavUsername,
            password: webdavPassword,
            remotePath: webdavRemotePath,
            lastBackupAt: Int64(webdavLastBackupAt)
        )
    }

    private func testWebDAV() {
        isTestingWebDAV = true
        webdavStatus = .loading("正在测试 WebDAV 连通性…")
        Task {
            defer { isTestingWebDAV = false }
            do {
                try await state.testWebDAVConnection(config: makeWebDAVConfig())
                webdavStatus = .success("WebDAV 连通性测试通过")
            } catch {
                webdavStatus = .error("连接失败：\(error.localizedDescription)")
            }
        }
    }

    private func backupToWebDAV() {
        isBackingUpWebDAV = true
        webdavStatus = .loading("正在上传备份至 WebDAV…")
        Task {
            defer { isBackingUpWebDAV = false }
            do {
                try await state.exportToWebDAV(config: makeWebDAVConfig())
                webdavLastBackupAt = Date().timeIntervalSince1970
                webdavStatus = .success("已成功备份至 WebDAV")
            } catch {
                webdavStatus = .error("备份失败：\(error.localizedDescription)")
            }
        }
    }

    private func restoreFromWebDAV() {
        isRestoringWebDAV = true
        webdavStatus = .loading("正在从 WebDAV 恢复…")
        Task {
            defer { isRestoringWebDAV = false }
            do {
                try await state.importFromWebDAV(config: makeWebDAVConfig())
                webdavStatus = .success("已成功从 WebDAV 恢复配置")
            } catch {
                webdavStatus = .error("恢复失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - 5. 关于与系统 Tab
    private var aboutTabContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                AsterBrandMark(size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Aster")
                        .font(.system(size: 16, weight: .bold))
                    Text("Native sing-box client")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .settingsCardStyle()

            // 内核状态
            VStack(alignment: .leading, spacing: 10) {
                Label("底层内核引擎", systemImage: "cpu.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.primary)

                VStack(spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("sing-box 官方内核")
                                .font(.system(size: 12.5, weight: .semibold))
                            Text("原生高性能网络代理核心与出站分流引擎")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Text(state.status.coreVersion.isEmpty ? "sing-box 原生内核" : state.status.coreVersion)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
                .settingsCardStyle()
            }

            // 诊断报告导出
            VStack(alignment: .leading, spacing: 10) {
                Label("脱敏诊断报告", systemImage: "stethoscope")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.primary)

                HStack(alignment: .center, spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.orange.opacity(0.12))
                            .frame(width: 36, height: 36)
                        Image(systemName: "shield.lefthalf.filled")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.orange)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("脱敏系统诊断归档 (.json)")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(.primary)
                        Text("导出核心运行状态、配置结构元数据及网络三级链路延时。所有订阅 URL、节点密码及私密凭据均已物理脱敏。")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 12)

                    Button {
                        Task {
                            do {
                                try await state.exportDiagnosticsReport()
                            } catch {
                                let alert = NSAlert()
                                alert.messageText = "导出诊断报告失败"
                                alert.informativeText = error.localizedDescription
                                alert.alertStyle = .warning
                                alert.runModal()
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.badge.gearshape")
                                .font(.system(size: 11))
                            Text("导出脱敏报告…")
                        }
                    }
                    .buttonStyle(.exquisiteSecondary(height: 28, cornerRadius: AsterMetrics.radiusControl))
                }
                .settingsCardStyle()
            }

            // 系统网络残留修复
            VStack(alignment: .leading, spacing: 10) {
                Label("系统网络与代理残留修复", systemImage: "wrench.and.screwdriver")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.primary)

                VStack(alignment: .leading, spacing: 8) {
                    Text("若曾非正常关机或强退导致 macOS 系统网络设置中残留了 127.0.0.1 代理，可一键清理并恢复网卡直连状态。")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    HStack(spacing: 8) {
                        if let clearProxyStatus {
                            InlineStatusPill(kind: clearProxyStatus, onDismiss: { self.clearProxyStatus = nil })
                        }
                        Spacer()
                        Button(action: {
                            isFlushingDNS = true
                            state.flushDNSCache()
                            clearProxyStatus = .success("系统 DNS 缓存已成功刷新")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                isFlushingDNS = false
                            }
                        }) {
                            HStack(spacing: 4) {
                                if isFlushingDNS {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: "bolt.horizontal.circle")
                                }
                                Text("刷新 DNS 缓存")
                            }
                        }
                        .buttonStyle(.exquisiteSecondary(height: 28, cornerRadius: AsterMetrics.radiusControl))
                        .disabled(isFlushingDNS)
                        .help("即刻清空 macOS 本地 DNS 解析缓存 (dscacheutil -flushcache)")

                        Button(action: {
                            isClearingProxy = true
                            clearProxyStatus = .loading("正在清理系统代理残留…")
                            Task {
                                defer { isClearingProxy = false }
                                do {
                                    try await state.clearSystemProxyResidue()
                                    clearProxyStatus = .success("系统代理残留已成功清除")
                                } catch {
                                    clearProxyStatus = .error("清理失败：\(error.localizedDescription)")
                                }
                            }
                        }) {
                            HStack(spacing: 4) {
                                if isClearingProxy {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: "arrow.counterclockwise")
                                }
                                Text("一键重置系统代理残留")
                            }
                        }
                        .buttonStyle(.exquisiteSecondary(height: 28, cornerRadius: AsterMetrics.radiusControl))
                        .disabled(isClearingProxy)
                    }
                }
                .settingsCardStyle()
            }
        }
    }

    private func updateProbe(_ url: String, success: String) {
        probeStatus = .loading("正在更新测速探针…")
        Task {
            do {
                try await state.updateDelayURL(url)
                probeStatus = .success(success)
            } catch {
                probeStatus = .error("更新失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - 标准 macOS 风格设置行组件 (统一接入公共组件 SettingSwitchRow)
    private func settingSwitchRow(title: String, subtitle: String, isOn: Binding<Bool>, isEnabled: Bool = true, disabledReason: String? = nil) -> some View {
        SettingSwitchRow(
            title: title,
            subtitle: subtitle,
            isOn: isOn,
            isEnabled: isEnabled,
            disabledReason: disabledReason
        )
    }
}

private extension View {
    func settingsCardStyle() -> some View {
        self.asterSettingsCard()
    }
}
