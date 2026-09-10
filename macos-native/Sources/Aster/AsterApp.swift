import SwiftUI
import AppKit
import Combine
import Darwin
@preconcurrency import UserNotifications

@MainActor
private enum AsterStatusGlyph {
    private static let activeImage = makeImage(active: true)
    private static let inactiveImage = makeImage(active: false)

    static func image(running: Bool) -> NSImage {
        running ? activeImage : inactiveImage
    }

    private static func makeImage(active: Bool) -> NSImage {
        let imageSize = NSSize(width: 16, height: 16)
        let image = NSImage(size: imageSize, flipped: false) { _ in
            let center = NSPoint(x: 8, y: 8)
            NSColor.black.setStroke()
            NSColor.black.setFill()

            let star = asterStar(center: center, outerRadius: 6.8, innerRadius: 2.6)
            if active {
                star.fill()
            } else {
                star.lineWidth = 1.3
                star.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func asterStar(center: NSPoint, outerRadius: CGFloat, innerRadius: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        let points = 6
        for index in 0..<(points * 2) {
            let angle = CGFloat(index) * .pi / CGFloat(points) - .pi / 2
            let radius = (index % 2 == 0) ? outerRadius : innerRadius
            let point = NSPoint(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius
            )
            if index == 0 {
                path.move(to: point)
            } else {
                path.line(to: point)
            }
        }
        path.close()
        return path
    }
}

@main
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    public static var shared: AppDelegate?

    var window: NSWindow?
    var statusItem: NSStatusItem?
    var statusMenu: NSMenu?
    private var isMenuOpen: Bool = false
    private var statusItemSubscription: AnyCancellable?
    private var statusMenuStateSubscription: AnyCancellable?
    private var strategyGroupsSubscription: AnyCancellable?
    private var captureMenuSubscription: AnyCancellable?
    private var statusBarSystemProxyItem: NSMenuItem?
    private var statusBarTunItem: NSMenuItem?
    private var appMenuSystemProxyItem: NSMenuItem?
    private var appMenuTunItem: NSMenuItem?
    private var shouldReopenStatusMenuAfterSpeedtest = false

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        AppDelegate.shared = delegate
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1. 原生状态栏网速项初始化 (同步挂载 + 异步补验，避免 AppKit 偶发未就绪)
        installStatusItem(reason: "launch-sync")
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            self?.installStatusItem(reason: "launch-async")
        }

        // 2. 启动后台状态同步中枢与 Go 守护进程
        let state = AsterState.shared
        state.start()
        statusItemSubscription = Publishers.CombineLatest3(
            state.$currentUpSpeed,
            state.$currentDownSpeed,
            state.$status
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _, _, _ in
            self?.updateStatusItemTitle()
        }
        statusMenuStateSubscription = Publishers.CombineLatest3(
            state.$nodes,
            state.$isTestingDelays,
            state.$testingTags
        )
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in
                self?.refreshStatusMenu()
            }
        strategyGroupsSubscription = state.$strategyGroups
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshStatusMenu() }
        captureMenuSubscription = state.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncCaptureMenuItems() }

        // 3. 构建标准系统主菜单
        setupAppMainMenu()

        // 4. 主窗口调度
        let minimize = UserDefaults.standard.bool(forKey: "minimizeOnLaunch")
        if !minimize {
            showMainWindow()
        }
        updateDockPolicy()

        // 5. 前置主视窗
        NSApp.activate(ignoringOtherApps: true)

        // 6. 通知
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        // 8. 仅限 Debug 的手动规则弹窗测试入口。
#if DEBUG
        DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("app.aster.testAddRule"), object: nil, queue: .main) { notif in
            Task { @MainActor in
                let mode = notif.userInfo?["mode"] as? String ?? "webpage"
                if mode == "process" {
                    let icon = NSWorkspace.shared.icon(forFile: "/Applications")
                    AddRuleWindowController.shared.show(context: .forProcess(name: "钉钉", path: "/Applications/DingTalk.app/Contents/MacOS/DingTalk", icon: icon))
                } else if mode == "domain" {
                    AddRuleWindowController.shared.show(context: .forDomain(host: "ab.chatgpt.com:443", appName: "ChatGPT", appIcon: nil))
                } else if mode == "custom" {
                    AddRuleWindowController.shared.show(context: .forCustom(type: .domainSuffix, value: "services.googleapis.cn", action: "PROXY"))
                } else {
                    let safariPath = "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app"
                    let normalPath = "/System/Applications/Safari.app"
                    let path = FileManager.default.fileExists(atPath: normalPath) ? normalPath : safariPath
                    let icon = NSWorkspace.shared.icon(forFile: path)
                    AddRuleWindowController.shared.show(context: .forWebpage(url: "https://dagou.nosugar.tech/#/history/website", domain: "dagou.nosugar.tech", icon: icon))
                }
            }
        }
#endif

        // 9. 持续跟踪用户前台激活应用，用于为当前网页/进程精准注入规则 (对标 Surge)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { notif in
            guard let app = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let name = app.localizedName,
                  name != "Aster" else { return }
            Task { @MainActor in
                AsterState.shared.recordActiveApp(name: name, bundleId: app.bundleIdentifier)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The daemon is intentionally independent while the window is merely
        // hidden. An explicit app quit, however, must release the local
        // control/mixed/Clash ports and stop a root-owned TUN core as well.
        AsterState.shared.stopRealtimeStreams()
        stopDaemonOnQuit()
    }

    private func stopDaemonOnQuit() {
        let dataDirectory: URL
        if let override = ProcessInfo.processInfo.environment["ASTER_DATA_DIR"], !override.isEmpty {
            dataDirectory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            dataDirectory = FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Application Support/Aster", directoryHint: .isDirectory)
        }
        let pidURL = dataDirectory.appending(path: "daemon.pid")
        guard let rawPID = try? String(contentsOf: pidURL, encoding: .utf8),
              let pid = Int32(rawPID.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0 else {
            return
        }
        _ = Darwin.kill(pid, SIGTERM)
    }

    // MARK: - 主控制台视窗与 Dock 栏图标生命周期策略 (常驻 Dock 图标与状态栏双入口)
    public func updateDockPolicy() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
    }

    // MARK: - 主控制台视窗管理 (无滚动条默认尺寸 + 窗口缩放位置记忆)
    func showMainWindow() {
        if window == nil {
            let defaultRect = NSRect(x: 0, y: 0, width: 1120, height: 760)
            let win = NSWindow(
                contentRect: defaultRect,
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            // All primary pages remain usable without horizontal scrolling at
            // this size.  The default size is intentionally larger, but the
            // user must not be able to resize the window into a broken layout.
            win.minSize = NSSize(width: 1_024, height: 700)
            win.title = "Aster"
            win.titlebarAppearsTransparent = true
            win.titleVisibility = .hidden
            win.titlebarSeparatorStyle = .none
            win.isOpaque = false
            win.backgroundColor = .clear
            win.hasShadow = true
            win.isReleasedWhenClosed = false
            win.delegate = self
            win.setFrameAutosaveName("AsterMainWindowAutosave_v4")
            if !win.setFrameUsingName("AsterMainWindowAutosave_v4") {
                win.setContentSize(NSSize(width: 1120, height: 760))
                win.center()
            }
            if let screen = NSScreen.main, !screen.visibleFrame.intersects(win.frame) {
                win.center()
            }
            win.contentView = NSHostingView(rootView: MainWindowView())
            self.window = win
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updateDockPolicy()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // 点击红色关闭按钮仅隐藏视窗，保持后台代理与 Dock 栏图标常驻
        sender.orderOut(nil)
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    // MARK: - 构建 macOS 标准系统主菜单 (NSApp.mainMenu)
    func setupAppMainMenu() {
        let mainMenu = NSMenu()

        // 1. App 菜单 (Aster)
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "Aster")
        appMenu.addItem(withTitle: "关于 Aster", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        let settingsItem = appMenu.addItem(withTitle: "偏好设置…", action: #selector(onOpenPreferences), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "隐藏 Aster", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthersItem = appMenu.addItem(withTitle: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "显示全部", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        let quitItem = appMenu.addItem(withTitle: "退出 Aster", action: #selector(onQuitApp), keyEquivalent: "q")
        quitItem.target = self
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // 2. 编辑菜单 (Edit - 标准文本/剪贴板操作)
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: #selector(UndoManager.undo), keyEquivalent: "z")
        let redoItem = editMenu.addItem(withTitle: "重做", action: #selector(UndoManager.redo), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // 3. 视图菜单 (View)
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "视图")
        let refreshItem = viewMenu.addItem(withTitle: "刷新状态", action: #selector(onRefreshAll), keyEquivalent: "r")
        refreshItem.target = self
        let inspectorItem = viewMenu.addItem(withTitle: "请求日志", action: #selector(onOpenInspector), keyEquivalent: "d")
        inspectorItem.target = self
        viewMenu.addItem(NSMenuItem.separator())
        let actualSizeItem = viewMenu.addItem(withTitle: "实际大小", action: #selector(onActualSize), keyEquivalent: "0")
        actualSizeItem.target = self
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // 4. 控制与代理菜单 (Proxy Controls)
        let controlMenuItem = NSMenuItem()
        let controlMenu = NSMenu(title: "控制")
        let showMainItem = controlMenu.addItem(withTitle: "显示主窗口", action: #selector(onBringAllFront), keyEquivalent: "m")
        showMainItem.target = self
        let openInspItem = controlMenu.addItem(withTitle: "请求日志…", action: #selector(onOpenInspector), keyEquivalent: "")
        openInspItem.target = self
        let addWebRuleItem = controlMenu.addItem(withTitle: "为当前网页添加规则…", action: #selector(onAddRuleForWebpage), keyEquivalent: "r")
        addWebRuleItem.keyEquivalentModifierMask = [.command, .shift]
        addWebRuleItem.target = self
        controlMenu.addItem(NSMenuItem.separator())
        let sysProxyItem = controlMenu.addItem(withTitle: "系统代理", action: #selector(onToggleSystemProxy), keyEquivalent: "s")
        sysProxyItem.target = self
        appMenuSystemProxyItem = sysProxyItem
        let tunItem = controlMenu.addItem(withTitle: "虚拟网卡", action: #selector(onToggleTun), keyEquivalent: "e")
        tunItem.target = self
        appMenuTunItem = tunItem
        let copyCmdItem = controlMenu.addItem(withTitle: "复制终端代理", action: #selector(onCopyTerminalCommand), keyEquivalent: "c")
        copyCmdItem.keyEquivalentModifierMask = [.command, .shift]
        copyCmdItem.target = self
        controlMenu.addItem(NSMenuItem.separator())
        let testAllItem = controlMenu.addItem(withTitle: "测速全部节点", action: #selector(onSpeedtestAll), keyEquivalent: "t")
        testAllItem.target = self
        let reloadItem = controlMenu.addItem(withTitle: "重载配置", action: #selector(onRestartCore), keyEquivalent: "R")
        reloadItem.keyEquivalentModifierMask = [.command, .shift]
        reloadItem.target = self
        controlMenuItem.submenu = controlMenu
        mainMenu.addItem(controlMenuItem)

        // 5. 窗口菜单 (Window)
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(NSMenuItem.separator())
        let frontItem = windowMenu.addItem(withTitle: "前置全部窗口", action: #selector(onBringAllFront), keyEquivalent: "")
        frontItem.target = self
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        // 6. 帮助菜单 (Help)
        let helpMenuItem = NSMenuItem()
        let helpMenu = NSMenu(title: "帮助")
        let helpItem = helpMenu.addItem(withTitle: "Aster 使用文档", action: #selector(onOpenHelp), keyEquivalent: "?")
        helpItem.target = self
        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - 状态栏：原生 NSStatusItem 自适应紧凑图标 + 左键现代 NSPopover + 右键原生菜单
    func setupStatusMenu() {
        installStatusItem(reason: "setupStatusMenu")
    }

    @discardableResult
    private func installStatusItem(reason: String) -> Bool {
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: 72)
        }
        guard let item = statusItem else {
            NSLog("[Aster] statusItem create failed (%@)", reason)
            return false
        }
        item.isVisible = true

        guard let button = item.button else {
            NSLog("[Aster] statusItem.button == nil (%@) — will retry", reason)
            return false
        }

        updateStatusItemTitle()
        button.toolTip = "Aster"
        button.isHidden = false
        button.alphaValue = 1.0

        let menu = statusMenu ?? NSMenu()
        menu.delegate = self
        buildStatusMenu(menu)
        statusMenu = menu
        item.menu = menu
        button.target = nil
        button.action = nil

        NSLog("[Aster] statusItem installed with native menu (%@)", reason)
        return true
    }

    private func makeStatusDisplayImage(running: Bool, upload: String, download: String) -> NSImage {
        let size = NSSize(width: 72, height: 22)
        let image = NSImage(size: size, flipped: false) { _ in
            AsterStatusGlyph.image(running: running).draw(
                in: NSRect(x: 2, y: 3, width: 16, height: 16),
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: nil
            )

            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .medium),
                .foregroundColor: NSColor.black,
            ]
            let up = NSAttributedString(string: "↑ \(upload)", attributes: attributes)
            let down = NSAttributedString(string: "↓ \(download)", attributes: attributes)
            up.draw(in: NSRect(x: 21, y: 11, width: 48, height: 10))
            down.draw(in: NSRect(x: 21, y: 1, width: 48, height: 10))
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - NSMenuDelegate 委托生命周期钩子
    public func menuNeedsUpdate(_ menu: NSMenu) {
        if !isMenuOpen {
            buildStatusMenu(menu)
        }
    }

    public func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        buildStatusMenu(menu)
    }

    public func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
    }

    // MARK: - 动态组装原生菜单项 (按使用频度重构：高频核心控制置顶 + 节点列表居中平铺 + 辅助工具与退出置底)
    public func buildStatusMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let state = AsterState.shared

        // ==========================================
        // 1. 顶部高频控制区（快捷键体系规范：⌘M / ⌘D / ⌘S / ⌘E）
        // ==========================================
        menu.addItem(createMenuItem(title: "显示主窗口", icon: "macwindow", action: #selector(onOpenDashboard), key: "m"))

        // 出站分流模式（指示标 + 快捷切换，专业英文全大写）
        let (modeBadge): (String) = {
            switch state.status.mode {
            case "global": return "GLOBAL"
            case "direct": return "DIRECT"
            default: return "RULE"
            }
        }()
        let modeRootItem = NSMenuItem(title: "出站模式", action: nil, keyEquivalent: "")
        modeRootItem.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "出站模式")
        
        let modeAttr = NSMutableAttributedString(string: "出站模式", attributes: [
            .font: NSFont.menuFont(ofSize: 0),
            .foregroundColor: NSColor.labelColor
        ])
        modeAttr.append(NSAttributedString(string: "   [\(modeBadge)]", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .bold),
            .foregroundColor: NSColor.controlAccentColor
        ]))
        modeRootItem.attributedTitle = modeAttr

        let modeMenu = NSMenu(title: "出站模式")
        let ruleItem = createMenuItem(title: "规则分流 (RULE)", icon: "arrow.triangle.branch", action: #selector(onSetModeRule), key: "1")
        ruleItem.state = (state.status.mode == "rule") ? .on : .off
        modeMenu.addItem(ruleItem)

        let globalItem = createMenuItem(title: "全局代理 (GLOBAL)", icon: "globe.asia.australia.fill", action: #selector(onSetModeGlobal), key: "2")
        globalItem.state = (state.status.mode == "global") ? .on : .off
        modeMenu.addItem(globalItem)

        let directItem = createMenuItem(title: "直接连接 (DIRECT)", icon: "bolt.horizontal.fill", action: #selector(onSetModeDirect), key: "3")
        directItem.state = (state.status.mode == "direct") ? .on : .off
        modeMenu.addItem(directItem)

        modeRootItem.submenu = modeMenu
        menu.addItem(modeRootItem)

        menu.addItem(NSMenuItem.separator())

        // ==========================================
        // 2. 策略组列表（右侧展示当前选中节点，不堆砌生硬符号）
        // ==========================================
        let displayGroups = state.strategyGroups.filter { group in
            if (group.tag == "proxy" || group.name == "proxy") && group.members.count == 1 {
                let target = group.members[0]
                if state.strategyGroups.contains(where: { $0.tag == target }) {
                    return false
                }
            }
            if group.tag == "auto" && group.type == "urltest" {
                let hasSelectorParent = state.strategyGroups.contains(where: { $0.type == "selector" && $0.members.contains("auto") })
                if hasSelectorParent {
                    return false
                }
            }
            return true
        }
        for group in displayGroups {
            // 解析当前选中的节点显示名称
            var nowLabel = ""
            if let nowTag = group.now, !nowTag.isEmpty {
                var cleanNow = NodeNameSanitizer.clean(state.nodes.first(where: { $0.tag == nowTag })?.name ?? nowTag)
                if nowTag == "auto" {
                    if let autoGroup = state.strategyGroups.first(where: { $0.tag == "auto" }), let autoNow = autoGroup.now, !autoNow.isEmpty {
                        let win = NodeNameSanitizer.clean(state.nodes.first(where: { $0.tag == autoNow })?.name ?? autoNow)
                        cleanNow = "自动 ➔ \(win)"
                    } else {
                        cleanNow = "自动优选"
                    }
                }
                nowLabel = "   [\(cleanNow.truncated(toVisualWidth: 14))]"
            }
            let strategyItem = NSMenuItem(title: group.name, action: nil, keyEquivalent: "")
            // 彻底移除策略组生硬的系统方块图标，还原本色 Emoji 与纯净文本排版

            let titleAttr = NSMutableAttributedString(string: group.name, attributes: [
                .font: NSFont.menuFont(ofSize: 0),
                .foregroundColor: NSColor.labelColor
            ])
            if !nowLabel.isEmpty {
                titleAttr.append(NSAttributedString(string: nowLabel, attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]))
            }
            strategyItem.attributedTitle = titleAttr
            strategyItem.submenu = makeStrategyMenu(group: group)
            menu.addItem(strategyItem)
        }

        // ==========================================
        // 3. 进程与客户端监控 (严格过滤无效/占位空进程)
        // ==========================================
        let validProcesses = state.topProcesses.filter { p in
            let clean = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return !clean.isEmpty && clean != "-" && (p.upSpeed + p.downSpeed > 0)
        }

        if !validProcesses.isEmpty {
            menu.addItem(NSMenuItem.separator())
            let procHeader = NSMenuItem(title: "进程与客户端", action: nil, keyEquivalent: "")
            procHeader.isEnabled = false
            menu.addItem(procHeader)

            for proc in validProcesses.prefix(5) {
                let totalSpeed = proc.upSpeed + proc.downSpeed
                let speedStr = Formatters.speedString(totalSpeed)
                let displayProcName = proc.name.truncated(toVisualWidth: 16)
                let pItem = NSMenuItem(title: "", action: #selector(onOpenInspector), keyEquivalent: "")

                let paragraphStyle = NSMutableParagraphStyle()
                paragraphStyle.tabStops = [
                    NSTextTab(textAlignment: .right, location: 220, options: [:])
                ]

                let fullText = "\(displayProcName)\t\(speedStr)"
                let attrTitle = NSMutableAttributedString(string: fullText, attributes: [
                    .font: NSFont.systemFont(ofSize: 11.5, weight: .regular),
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: paragraphStyle
                ])
                if let tabRange = fullText.range(of: "\t") {
                    let nsRange = NSRange(tabRange.upperBound..<fullText.endIndex, in: fullText)
                    attrTitle.addAttributes([
                        .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular),
                        .foregroundColor: NSColor.secondaryLabelColor,
                    ], range: nsRange)
                }
                pItem.attributedTitle = attrTitle
                pItem.toolTip = "\(proc.name) (\(speedStr)) - 点击打开请求日志审查"
                pItem.target = self
                let rawIcon = state.iconForProcess(path: proc.processPath ?? "", name: proc.name, size: 12)
                pItem.image = makeRoundedIcon(rawIcon, size: 12, cornerRadius: 2.5)
                menu.addItem(pItem)
            }
        }

        menu.addItem(NSMenuItem.separator())

        // ==========================================
        // 4. 网络控制与系统接管 (规范快捷键 ⌘D / ⌘S / ⌘E / ⌘C)
        // ==========================================
        menu.addItem(createMenuItem(title: "请求日志…", icon: "list.bullet.rectangle.portrait", action: #selector(onOpenInspector), key: "d"))

        let sysProxyItem = createMenuItem(title: "设置为系统代理", icon: "network", action: #selector(onToggleSystemProxy), key: "s")
        statusBarSystemProxyItem = sysProxyItem
        menu.addItem(sysProxyItem)

        let tunItem = createMenuItem(title: "虚拟网卡", icon: "shield.lefthalf.filled", action: #selector(onToggleTun), key: "e")
        statusBarTunItem = tunItem
        menu.addItem(tunItem)
        syncCaptureMenuItems()

        let copyItem = createMenuItem(title: "复制终端代理命令", icon: "terminal", action: #selector(onCopyTerminalCommand), key: "c")
        menu.addItem(copyItem)

        menu.addItem(NSMenuItem.separator())

        // ==========================================
        // 5. 配置与控制 (⌘R / 切换配置 / 重启应用 / 退出 ⌘Q)
        // ==========================================
        if !state.configs.isEmpty {
            let activeConfigName = state.configs.first(where: { $0.active })?.name ?? "默认配置"
            let configRootItem = createMenuItem(title: "切换配置", icon: "doc.plaintext", action: nil)
            
            let cfgAttr = NSMutableAttributedString(string: "切换配置", attributes: [
                .font: NSFont.menuFont(ofSize: 0),
                .foregroundColor: NSColor.labelColor
            ])
            cfgAttr.append(NSAttributedString(string: "   \(activeConfigName.truncated(toVisualWidth: 14))", attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor
            ]))
            configRootItem.attributedTitle = cfgAttr

            let configSubmenu = NSMenu(title: "切换配置")
            for cfg in state.configs {
                let cItem = NSMenuItem(title: cfg.name.truncated(toVisualWidth: 26), action: #selector(onSwitchProfile(_:)), keyEquivalent: "")
                cItem.representedObject = cfg.id
                cItem.target = self
                cItem.state = cfg.active ? .on : .off
                cItem.image = NSImage(systemSymbolName: cfg.kind == "subscription" ? "link.circle.fill" : "doc.text.fill", accessibilityDescription: cfg.name)
                configSubmenu.addItem(cItem)
            }
            configRootItem.submenu = configSubmenu
            menu.addItem(configRootItem)
        }

        menu.addItem(createMenuItem(title: "重载配置", icon: "arrow.clockwise", action: #selector(onRestartCore), key: "r"))
        menu.addItem(createMenuItem(title: "重启应用", icon: "arrow.triangle.2.circlepath", action: #selector(onRelaunchApp)))

        menu.addItem(NSMenuItem.separator())
        menu.addItem(createMenuItem(title: "退出", icon: "power", action: #selector(onQuitApp), key: "q"))
    }

    func updateStatusItemTitle() {
        // 若启动时 button 曾为 nil，定时器路径也会补装
        if statusItem?.button == nil {
            _ = installStatusItem(reason: "timer-reinstall")
            return
        }
        guard let button = statusItem?.button else { return }
        let state = AsterState.shared
        let upload = Formatters.speedString(state.currentUpSpeed)
        let download = Formatters.speedString(state.currentDownSpeed)

        button.title = ""
        button.imagePosition = .imageOnly
        button.image = makeStatusDisplayImage(running: state.status.running, upload: upload, download: download)
        button.toolTip = "Aster：上传 \(upload)，下载 \(download)"
        button.setAccessibilityLabel("Aster，上传 \(upload)，下载 \(download)，\(state.status.running ? "核心运行中" : "核心未运行")")
        statusItem?.length = 72
    }

    public func syncCaptureMenuItems() {
        applyCaptureState(to: statusBarSystemProxyItem, systemProxy: true)
        applyCaptureState(to: statusBarTunItem, systemProxy: false)
        applyCaptureState(to: appMenuSystemProxyItem, systemProxy: true)
        applyCaptureState(to: appMenuTunItem, systemProxy: false)
    }

    private func applyCaptureState(to item: NSMenuItem?, systemProxy: Bool) {
        guard let item else { return }
        let status = AsterState.shared.status
        if systemProxy {
            item.state = status.capture.systemProxy ? .on : .off
            let available = status.capabilities?.systemProxy.available ?? true
            item.isEnabled = status.running && available
            item.toolTip = available ? (status.running ? "将 mixed 端口写入 macOS 系统代理" : "核心未运行时不能开启系统代理") : (status.capabilities?.systemProxy.reason ?? "")
        } else {
            item.state = status.capture.tun ? .on : .off
            let available = status.capabilities?.tun.available ?? true
            item.isEnabled = available
            item.toolTip = available ? "通过 PKG 网络组件启用虚拟网卡" : (status.capabilities?.tun.reason ?? "")
        }
    }

    public func refreshStatusMenu() {
        guard let menu = statusMenu else { return }
        // 如果菜单正在显示中，仅平滑更新内部菜单项的文字和状态，严禁 removeAllItems() 导致菜单意外关闭
        if isMenuOpen {
            updateLiveMenuItems(in: menu)
            return
        }
        buildStatusMenu(menu)
    }

    @MainActor
    public func notifyNodeDelayUpdated(tag: String, delay: Int) {
        refreshStatusMenu()
    }

    private func updateLiveMenuItems(in menu: NSMenu) {
        let state = AsterState.shared
        for item in menu.items {
            if let sub = item.submenu {
                // 如果是策略组二级菜单，更新其节点延迟与打勾
                if let group = state.strategyGroups.first(where: { $0.name == sub.title || $0.tag == sub.title }) {
                    updateStrategySubmenuItems(sub, group: group)
                } else if sub.title == "出站模式" {
                    // 更新模式打勾
                    for modeItem in sub.items {
                        if modeItem.action == #selector(onSetModeRule) { modeItem.state = (state.status.mode == "rule") ? .on : .off }
                        if modeItem.action == #selector(onSetModeGlobal) { modeItem.state = (state.status.mode == "global") ? .on : .off }
                        if modeItem.action == #selector(onSetModeDirect) { modeItem.state = (state.status.mode == "direct") ? .on : .off }
                    }
                }
            } else if item.action == #selector(onToggleSystemProxy) {
                applyCaptureState(to: item, systemProxy: true)
            } else if item.action == #selector(onToggleTun) {
                applyCaptureState(to: item, systemProxy: false)
            }
        }
    }

    private func findNode(for tag: String) -> ProxyNode? {
        return AsterState.shared.findNode(for: tag)
    }

    private func updateStrategySubmenuItems(_ sub: NSMenu, group: StrategyGroup) {
        let state = AsterState.shared
        for item in sub.items {
            if let targetView = item.view as? StrategySpeedHeaderView {
                let isGroupTesting = group.leafTags.contains { state.testingTags.contains($0) } || state.testingTags.contains(group.tag) || state.isTestingDelays
                targetView.update(isTesting: isGroupTesting)
            } else if item.action == #selector(onSelectStrategyNode(_:)),
                      let dict = item.representedObject as? [String: String],
                      let tag = dict["tag"] {
                let isAuto = (tag == "auto")
                let node = findNode(for: tag)
                let rawTitle: String
                let delay: Int
                if isAuto {
                    rawTitle = "♻️ 自动优选 (URLTest)"
                    let gDelay = state.strategyGroups.first(where: { $0.tag == "auto" })?.delayMs ?? 0
                    delay = gDelay > 0 ? gDelay : state.status.delayMs
                } else {
                    rawTitle = NodeNameSanitizer.clean(node?.name ?? tag)
                    delay = node?.delayMs ?? 0
                }
                item.attributedTitle = nodeMenuTitle(name: rawTitle, tag: tag, delay: delay)
                let isSelected = (group.now == tag) || (group.tag == "proxy" && state.status.selected == tag)
                item.state = isSelected ? .on : .off
            }
        }
    }

    private func makeStrategyMenu(group: StrategyGroup) -> NSMenu {
        let nodeMenu = NSMenu(title: group.name)
        
        // 1. 置顶延迟测试项 (采用 NSView 自定义按钮：点击时在菜单内原地触发测速，绝不触发 NSMenu 的 dismiss 动作)
        let isTesting = group.leafTags.contains { AsterState.shared.testingTags.contains($0) } || AsterState.shared.testingTags.contains(group.tag) || AsterState.shared.isTestingDelays
        let headerView = StrategySpeedHeaderView(group: group, isTesting: isTesting) { [weak self] in
            self?.onTriggerStrategyGroupSpeedtest(group: group)
        }
        let customItem = NSMenuItem()
        customItem.view = headerView
        nodeMenu.addItem(customItem)
        
        nodeMenu.addItem(NSMenuItem.separator())
        
        if group.members.isEmpty {
            let emptyItem = NSMenuItem(title: "暂无可用节点", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            nodeMenu.addItem(emptyItem)
            return nodeMenu
        }
        
        // 2. 节点列表
        for tag in group.members {
            let isAuto = (tag == "auto")
            let node = findNode(for: tag)
            let rawTitle: String
            let delay: Int
            if isAuto {
                rawTitle = "♻️ 自动优选 (URLTest)"
                let gDelay = AsterState.shared.strategyGroups.first(where: { $0.tag == "auto" })?.delayMs ?? 0
                delay = gDelay > 0 ? gDelay : AsterState.shared.status.delayMs
            } else {
                rawTitle = NodeNameSanitizer.clean(node?.name ?? tag)
                delay = node?.delayMs ?? 0
            }
            let item = NSMenuItem(title: rawTitle.truncated(toVisualWidth: 26), action: #selector(onSelectStrategyNode(_:)), keyEquivalent: "")
            item.attributedTitle = nodeMenuTitle(name: rawTitle, tag: tag, delay: delay)
            if isAuto {
                var tip = "自动测速并分流至最低延迟节点"
                if let autoGroup = AsterState.shared.strategyGroups.first(where: { $0.tag == "auto" }), let now = autoGroup.now, !now.isEmpty {
                    let win = AsterState.shared.findNode(for: now)?.name ?? now
                    tip += " (当前命中: \(win))"
                }
                item.toolTip = tip
            } else {
                item.toolTip = "\(rawTitle)  \(nodeDelayText(delay: delay, tag: tag, isTesting: false))"
            }
            item.representedObject = ["group": group.tag, "tag": tag]
            item.target = self
            
            // 当前选中的节点打勾
            let isSelected = (group.now == tag) || (group.tag == "proxy" && AsterState.shared.status.selected == tag)
            item.state = isSelected ? .on : .off
            item.isEnabled = group.type == "selector"
            nodeMenu.addItem(item)
        }
        return nodeMenu
    }

    private func nodeMenuTitle(name: String, tag: String, delay: Int) -> NSAttributedString {
        let cleanName = name.truncated(toVisualWidth: 20)
        let isTesting = AsterState.shared.testingTags.contains(tag) || AsterState.shared.isTestingDelays
        let delayText = nodeDelayText(delay: delay, tag: tag, isTesting: isTesting)
        
        let textColor: NSColor = {
            if isTesting {
                return .systemBlue
            }
            if delay < 0 {
                return NSColor(calibratedRed: 0.85, green: 0.38, blue: 0.38, alpha: 1.0)
            }
            if delay == 0 {
                return .secondaryLabelColor
            }
            if delay <= 150 {
                return NSColor(calibratedRed: 0.22, green: 0.72, blue: 0.48, alpha: 1.0)
            }
            if delay <= 500 {
                return NSColor(calibratedRed: 0.88, green: 0.62, blue: 0.22, alpha: 1.0)
            }
            return NSColor(calibratedRed: 0.85, green: 0.38, blue: 0.38, alpha: 1.0)
        }()

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.tabStops = [
            NSTextTab(textAlignment: .right, location: 260, options: [:])
        ]

        let fullText = "\(cleanName)\t\(delayText)"
        let title = NSMutableAttributedString(string: fullText, attributes: [
            .font: NSFont.menuFont(ofSize: 0),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle
        ])

        if let tabRange = fullText.range(of: "\t") {
            let nsRange = NSRange(tabRange.upperBound..<fullText.endIndex, in: fullText)
            title.addAttributes([
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: textColor,
            ], range: nsRange)
        }

        return title
    }

    private func nodeDelayText(delay: Int, tag: String, isTesting: Bool) -> String {
        if isTesting { return "测速中…" }
        if delay < 0 { return "超时" }
        if delay == 0 { return "---" }
        return "\(delay) ms"
    }

    // MARK: - 辅助方法：生成 12px 极细微圆角图标 (macOS 现代设计规范)
    private func makeRoundedIcon(_ image: NSImage, size: CGFloat = 12, cornerRadius: CGFloat = 2.5) -> NSImage {
        let newImg = NSImage(size: NSSize(width: size, height: size))
        newImg.lockFocus()
        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        path.addClip()
        image.draw(in: rect, from: NSRect(origin: .zero, size: image.size), operation: .sourceOver, fraction: 1.0)
        newImg.unlockFocus()
        return newImg
    }

    // MARK: - 辅助方法：统一创建具备原生高清晰 SF Symbol 图标的菜单项
    private func createMenuItem(
        title: String,
        icon: String,
        action: Selector?,
        key: String = "",
        modifier: NSEvent.ModifierFlags = []
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !modifier.isEmpty {
            item.keyEquivalentModifierMask = modifier
        }
        if let img = NSImage(systemSymbolName: icon, accessibilityDescription: title) {
            img.isTemplate = true
            item.image = img
        }
        item.target = self
        return item
    }

    // MARK: - 菜单点击事件响应
    @objc func onOpenPreferences() {
        showMainWindow()
    }

    @objc func onRefreshAll() {
        AsterState.shared.refreshAll()
        AsterState.shared.fetchIPInfo(force: true)
    }

    @objc func onActualSize() {
        window?.setContentSize(NSSize(width: 1120, height: 760))
        window?.center()
    }

    @objc func onBringAllFront() {
        showMainWindow()
    }

    @objc func onOpenHelp() {
        if let url = URL(string: "https://github.com/SagerNet/sing-box") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func onOpenDashboard() {
        showMainWindow()
    }

    @objc func onOpenInspector() {
        InspectorWindowController.shared.show()
    }

    @objc func onCopyTerminalCommand() {
        AsterState.shared.copyTerminalProxyCommand()
    }

    @objc func onToggleSystemProxy() {
        let state = AsterState.shared
        state.setCapture(systemProxy: !state.status.capture.systemProxy, tun: state.status.capture.tun)
    }

    @objc func onToggleTun() {
        let state = AsterState.shared
        state.setCapture(systemProxy: state.status.capture.systemProxy, tun: !state.status.capture.tun)
    }

    @objc func onSetModeRule() {
        AsterState.shared.setMode("rule")
    }

    @objc func onSetModeGlobal() {
        AsterState.shared.setMode("global")
    }

    @objc func onSetModeDirect() {
        AsterState.shared.setMode("direct")
    }

    @objc func onAddRuleForWebpage() {
        AsterState.shared.promptAddRuleForCurrentWebpage()
    }

    @objc func onSpeedtestAll() {
        let state = AsterState.shared
        guard !state.isTestingDelays else { return }
        state.testAllNodes()
    }

    @objc func onSpeedtestStrategyGroup(_ sender: NSMenuItem) {
        guard let tag = sender.representedObject as? String,
              let group = AsterState.shared.strategyGroups.first(where: { $0.tag == tag }) else { return }
        onTriggerStrategyGroupSpeedtest(group: group)
    }

    func onTriggerStrategyGroupSpeedtest(group: StrategyGroup) {
        guard AsterState.shared.status.running else { return }
        let tags = group.leafTags
        AsterState.shared.testingTags.formUnion(tags)
        refreshStatusMenu()
        AsterState.shared.testStrategyGroup(group)
    }

    @objc func onSelectStrategyNode(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? [String: String], let groupTag = value["group"], let tag = value["tag"],
              let group = AsterState.shared.strategyGroups.first(where: { $0.tag == groupTag }) else { return }
        AsterState.shared.selectStrategyGroupNode(group: group, tag: tag)
    }

    // MARK: - UNUserNotificationCenterDelegate (前台统一弹出系统横幅与声音)
    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // MARK: - 统一系统通知分发
    public func postSystemNotification(
        title: String,
        body: String,
        category: String = "general",
        autoDismissAfter: TimeInterval = 0
    ) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            let deliver: @Sendable () -> Void = {
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = .default
                let request = UNNotificationRequest(identifier: "aster-\(category)-\(UUID().uuidString)", content: content, trigger: nil)
                center.add(request)
            }
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in if granted { deliver() } }
            case .authorized, .provisional, .ephemeral:
                deliver()
            default:
                break
            }
        }
    }

    @objc func onSelectNode(_ sender: NSMenuItem) {
        if let nodeId = sender.representedObject as? String {
            AsterState.shared.selectNode(nodeId)
        }
    }

    @objc func onRestartCore() {
        AsterState.shared.restartCore()
    }

    @objc func onSwitchProfile(_ sender: NSMenuItem) {
        guard let configId = sender.representedObject as? String else { return }
        AsterState.shared.activateConfig(id: configId)
    }

    @objc func onRelaunchApp() {
        AsterState.shared.relaunchApplication()
    }

    @objc func onQuitApp() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - 策略组二级菜单置顶「延迟测试」自定义交互视图 (点击时在菜单内原地触发测速，绝不触发 NSMenu 关闭)
// MARK: - 策略组二级菜单置顶「延迟测试」自定义交互视图 (全宽自适应，点击原地测速绝不关闭菜单)
@MainActor
final class StrategySpeedHeaderView: NSView {
    private let group: StrategyGroup
    private let onClick: () -> Void
    private let titleLabel = NSTextField(labelWithString: "延迟测试")
    private let iconView = NSImageView()
    private let spinner = NSProgressIndicator()
    private var isHighlighted: Bool = false
    private var isTesting: Bool = false
    private var trackingArea: NSTrackingArea?

    init(group: StrategyGroup, isTesting: Bool, onClick: @escaping () -> Void) {
        self.group = group
        self.isTesting = isTesting
        self.onClick = onClick
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
        autoresizingMask = [.width]
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        wantsLayer = true
        layer?.cornerRadius = 4.0

        iconView.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "延迟测试")
        iconView.contentTintColor = .labelColor
        iconView.frame = NSRect(x: 14, y: 5, width: 14, height: 14)
        addSubview(iconView)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.frame = NSRect(x: 14, y: 5, width: 14, height: 14)
        spinner.isHidden = true
        addSubview(spinner)

        titleLabel.font = NSFont.menuFont(ofSize: 0)
        titleLabel.textColor = .labelColor
        titleLabel.frame = NSRect(x: 34, y: 4, width: max(bounds.width - 44, 180), height: 18)
        titleLabel.autoresizingMask = [.width]
        addSubview(titleLabel)

        update(isTesting: isTesting)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let sv = superview, sv.bounds.width > 0 {
            frame.size.width = sv.bounds.width
            needsLayout = true
        }
    }

    override func viewWillDraw() {
        super.viewWillDraw()
        if let sv = superview, sv.bounds.width > 0, abs(frame.size.width - sv.bounds.width) > 0.5 {
            frame.size.width = sv.bounds.width
            needsLayout = true
        }
    }

    override func layout() {
        super.layout()
        if let sv = superview, sv.bounds.width > 0 && abs(frame.size.width - sv.bounds.width) > 0.5 {
            frame.size.width = sv.bounds.width
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isHighlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 4.5, yRadius: 4.5)
            path.fill()
        }
    }

    func update(isTesting: Bool) {
        self.isTesting = isTesting
        titleLabel.stringValue = isTesting ? "正在测速…" : "延迟测试"
        if isTesting {
            iconView.isHidden = true
            spinner.isHidden = false
            spinner.startAnimation(nil)
            titleLabel.textColor = isHighlighted ? .selectedMenuItemTextColor : .systemBlue
        } else {
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            iconView.isHidden = false
            iconView.contentTintColor = isHighlighted ? .selectedMenuItemTextColor : .labelColor
            titleLabel.textColor = isHighlighted ? .selectedMenuItemTextColor : .labelColor
        }
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) {
        isHighlighted = true
        titleLabel.textColor = .selectedMenuItemTextColor
        iconView.contentTintColor = .selectedMenuItemTextColor
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHighlighted = false
        titleLabel.textColor = isTesting ? .systemBlue : .labelColor
        iconView.contentTintColor = isTesting ? .systemBlue : .labelColor
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        guard !isTesting, AsterState.shared.status.running else { return }
        update(isTesting: true)
        onClick()
    }
}
