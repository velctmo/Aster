import SwiftUI
import Charts
import AppKit

public struct SettingsView: View {
    @ObservedObject var state = AsterState.shared
    @AppStorage("showNodeBandwidthBadge") private var showNodeBandwidthBadge: Bool = true
    @AppStorage("sortNodesByDelay") private var sortNodesByDelay: Bool = false
    @AppStorage("showConnectionQuickRule") private var showConnectionQuickRule: Bool = true
    @AppStorage("enableStrictRoute") private var enableStrictRoute: Bool = false
    @AppStorage("allowLanSharing") private var allowLanSharing: Bool = true
    @AppStorage("autoLaunchOnLogin") private var autoLaunchOnLogin: Bool = true
    @AppStorage("minimizeOnLaunch") private var minimizeOnLaunch: Bool = false
    @AppStorage("speedtestTimeoutMs") private var speedtestTimeoutMs: Int = 2500
    @AppStorage("speedtestConcurrency") private var speedtestConcurrency: Int = 16
    // WebDAV 持久化配置
    @AppStorage("webdavServerURL") private var webdavServerURL: String = ""
    @AppStorage("webdavUsername") private var webdavUsername: String = ""
    @AppStorage("webdavRemotePath") private var webdavRemotePath: String = "/Aster"
    @AppStorage("webdavLastBackupAt") private var webdavLastBackupAt: Double = 0
    @State private var webdavPassword: String = ""
    @State private var webdavCredentialError: String?
    @FocusState private var isEditingWebDAVPassword: Bool

    // 端口自定义状态
    @State private var mixedPortInput: String = "2080"
    @State private var clashPortInput: String = "2090"
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

    private func syncFromBackendSettings() {
        mixedPortInput = "\(state.status.mixedPort ?? 2080)"
        clashPortInput = "\(state.status.clashPort ?? 2090)"
        Task {
            await state.fetchSettings()
            await MainActor.run {
                if let p = state.status.mixedPort, p > 0 { mixedPortInput = "\(p)" }
                if let cp = state.status.clashPort, cp > 0 { clashPortInput = "\(cp)" }
                enableStrictRoute = UserDefaults.standard.object(forKey: "enableStrictRoute") as? Bool ?? enableStrictRoute
                allowLanSharing = UserDefaults.standard.object(forKey: "allowLanSharing") as? Bool ?? allowLanSharing
                autoLaunchOnLogin = UserDefaults.standard.object(forKey: "autoLaunchOnLogin") as? Bool ?? autoLaunchOnLogin
                if let ms = UserDefaults.standard.object(forKey: "speedtestTimeoutMs") as? Int {
                    speedtestTimeoutMs = ms
                }
                if let n = UserDefaults.standard.object(forKey: "speedtestConcurrency") as? Int {
                    speedtestConcurrency = n
                }
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
        .onChange(of: enableStrictRoute) { _, v in
            state.patchSettings(body: ["strictRoute": v])
        }
        .onChange(of: allowLanSharing) { _, v in
            state.patchSettings(body: ["allowLan": v])
        }
        .onChange(of: autoLaunchOnLogin) { _, v in
            state.patchSettings(body: ["autostart": v])
        }
        .onChange(of: speedtestTimeoutMs) { _, v in
            state.patchSettings(body: ["delayTimeoutMs": v])
        }
        .onChange(of: speedtestConcurrency) { _, v in
            state.patchSettings(body: ["delayConcurrency": v])
        }
        .confirmationDialog(
            "确认从 iCloud 恢复配置？",
            isPresented: $showConfirmICloudRestore,
            titleVisibility: .visible
        ) {
            Button("立即恢复 (覆盖本地配置)", role: .destructive) {
                isRestoringICloud = true
                Task {
                    defer { isRestoringICloud = false }
                    do {
                        try await state.importFromICloud()
                    } catch {
                        state.actionError = error.localizedDescription
                        state.notify(message: "恢复失败：\(error.localizedDescription)", type: .error)
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
                        isOn: $autoLaunchOnLogin
                    )

                    Divider()

                    settingSwitchRow(
                        title: "启动时隐藏主窗口",
                        subtitle: "启动时不弹出大窗口，仅在菜单栏保持就绪",
                        isOn: $minimizeOnLaunch
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
            // 卡片 1: 端口自定义与监听
            VStack(alignment: .leading, spacing: 10) {
                Label("核心监听端口自定义", systemImage: "slider.horizontal.3")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.primary)

                VStack(spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("混合代理监听端口 (Mixed Port)")
                                .font(.system(size: 12.5, weight: .semibold))
                            Text("合并支持 HTTP / HTTPS 与 SOCKS5 双协议接入 (默认: 2080)")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        TextField("2080", text: $mixedPortInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                    }

                    Divider()

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Clash RESTful API 端口")
                                .font(.system(size: 12.5, weight: .semibold))
                            Text("用于外部控制端、面板及节点切换接入 (默认: 2090)")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        TextField("2090", text: $clashPortInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                    }

                    Divider()

                    HStack {
                        Text("修改端口将自动热重载 Sing-box 内核")
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                        Spacer()
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
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
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
                        isOn: $allowLanSharing,
                        isEnabled: !importedProfile,
                        disabledReason: "完整订阅由外部配置管理"
                    )

                    Divider()

                    settingSwitchRow(
                        title: "严格路由模式 (Strict Route)",
                        subtitle: "强制非本地私有网段流量全量进入虚拟网卡，严防 IPv6 与直连旁路泄露真实 IP",
                        isOn: $enableStrictRoute,
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
                        Text("按需管理员权限校验")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(.primary)
                        Text("开启或关闭 TUN 模式时按需调用 macOS 管理员授权。系统不常驻提权 Helper，不修改二进制 SUID 位，安全性最高。")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                .settingsCardStyle()
            }
        }
    }

    private func saveCustomPorts() {
        guard let mixed = Int(mixedPortInput.trimmingCharacters(in: .whitespaces)),
              let clash = Int(clashPortInput.trimmingCharacters(in: .whitespaces)) else {
            state.notify(message: "端口必须为纯数字", type: .error)
            return
        }
        guard (1024...65535).contains(mixed), (1024...65535).contains(clash) else {
            state.notify(message: "端口范围必须在 1024 ~ 65535 之间", type: .error)
            return
        }
        guard mixed != clash else {
            state.notify(message: "混合代理端口与 Clash API 端口不能相同", type: .error)
            return
        }
        isSavingPorts = true
        state.patchSettings(body: [
            "mixedPort": mixed,
            "clashPort": clash
        ])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            self.isSavingPorts = false
            self.state.notify(message: "端口配置已更新，内核已热重载", type: .success)
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
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
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
                        Picker("", selection: $speedtestTimeoutMs) {
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
                        Picker("", selection: $speedtestConcurrency) {
                            Text("8 并发").tag(8)
                            Text("16 并发 (推荐)").tag(16)
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
                Label("本地文件备份与还原", systemImage: "internaldrive")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.primary)

                VStack(alignment: .leading, spacing: 10) {
                    Text("将订阅、自定义节点、覆写脚本、分流规则及应用偏好打包为 Zip。不会导出本机端口、权限、内核路径、API 身份或运行记录；恢复成功后 Aster 自动重新启动。")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    HStack(spacing: 12) {
                        Button(action: {
                            Task {
                                do {
                                    try await state.exportLocalBackup()
                                    state.notify(message: "已成功导出本地备份归档", type: .success)
                                } catch {
                                    state.notify(message: "导出失败: \(error.localizedDescription)", type: .error)
                                }
                            }
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "square.and.arrow.up")
                                Text("导出本地备份包…")
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button(action: {
                            Task {
                                do {
                                    try await state.importLocalBackup()
                                } catch {
                                    state.notify(message: "还原失败: \(error.localizedDescription)", type: .error)
                                }
                            }
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "square.and.arrow.down")
                                Text("导入本地备份…")
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
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
                            Task {
                                defer { isBackingUpICloud = false }
                                do {
                                    try await state.exportToICloud()
                                    state.notify(message: "已成功将当前配置备份至 iCloud Drive", type: .success)
                                } catch {
                                    state.actionError = error.localizedDescription
                                    state.notify(message: "备份失败：\(error.localizedDescription)", type: .error)
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
                        .buttonStyle(.bordered)
                        .controlSize(.small)
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
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!state.iCloudStatus.hasBackup || isBackingUpICloud || isRestoringICloud)
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
                        .buttonStyle(.bordered)
                        .controlSize(.small)
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
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
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
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(webdavServerURL.isEmpty || isBackingUpWebDAV || isRestoringWebDAV)
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
        Task {
            defer { isTestingWebDAV = false }
            do {
                try await state.testWebDAVConnection(config: makeWebDAVConfig())
                state.notify(message: "WebDAV 连通性测试成功", type: .success)
            } catch {
                state.notify(message: error.localizedDescription, type: .error)
            }
        }
    }

    private func backupToWebDAV() {
        isBackingUpWebDAV = true
        Task {
            defer { isBackingUpWebDAV = false }
            do {
                try await state.exportToWebDAV(config: makeWebDAVConfig())
                webdavLastBackupAt = Date().timeIntervalSince1970
                state.notify(message: "已成功上传备份至 WebDAV", type: .success)
            } catch {
                state.notify(message: "备份失败: \(error.localizedDescription)", type: .error)
            }
        }
    }

    private func restoreFromWebDAV() {
        isRestoringWebDAV = true
        Task {
            defer { isRestoringWebDAV = false }
            do {
                try await state.importFromWebDAV(config: makeWebDAVConfig())
            } catch {
                state.notify(message: "恢复失败: \(error.localizedDescription)", type: .error)
            }
        }
    }

    // MARK: - 5. 关于与系统 Tab
    private var aboutTabContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            // 内核状态
            VStack(alignment: .leading, spacing: 10) {
                Label("底层内核引擎", systemImage: "cpu.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.primary)

                VStack(spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Sing-box 官方内核")
                                .font(.system(size: 12.5, weight: .semibold))
                            Text("原生高性能网络代理核心与出站分流引擎")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Text(state.status.coreVersion.isEmpty ? "Sing-box 原生内核" : state.status.coreVersion)
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

                VStack(alignment: .leading, spacing: 8) {
                    Text("导出核心运行状态、配置结构元数据及网络三级链路延时，不包含任何订阅 URL、节点密码或敏感凭据。")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    HStack {
                        Spacer()
                        Button("导出脱敏诊断报告…") {
                            Task {
                                do {
                                    try await state.exportDiagnosticsReport()
                                    state.notify(message: "已导出脱敏诊断报告", type: .success)
                                } catch {
                                    state.notify(message: "导出失败：\(error.localizedDescription)", type: .error)
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
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

                    HStack {
                        Spacer()
                        Button(action: {
                            isClearingProxy = true
                            Task {
                                defer { isClearingProxy = false }
                                do {
                                    try await state.clearSystemProxyResidue()
                                    state.notify(message: "已成功清理系统代理残留设置", type: .success)
                                } catch {
                                    state.notify(message: "清理失败: \(error.localizedDescription)", type: .error)
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
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isClearingProxy)
                    }
                }
                .settingsCardStyle()
            }
        }
    }

    private func updateProbe(_ url: String, success: String) {
        Task {
            do {
                try await state.updateDelayURL(url)
                state.notify(message: success, type: .success)
            } catch {
                state.actionError = error.localizedDescription
                state.notify(message: "更新失败：\(error.localizedDescription)", type: .error)
            }
        }
    }

    // MARK: - 标准 macOS 风格设置行组件 (左对齐文字 + 右侧原生 Switch 开关)
    private func settingSwitchRow(title: String, subtitle: String, isOn: Binding<Bool>, isEnabled: Bool = true, disabledReason: String? = nil) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(.primary)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(!isEnabled)
                .help(disabledReason ?? title)
        }
        .opacity(isEnabled ? 1 : 0.55)
    }
}

private extension View {
    func settingsCardStyle() -> some View {
        self.padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.ultraThinMaterial)
            )
            .liquidGlassBorder(cornerRadius: 12)
            .shadow(color: Color.black.opacity(0.04), radius: 6, x: 0, y: 2)
    }
}
