import SwiftUI
import AppKit
import Combine
import Darwin
@preconcurrency import UserNotifications

@MainActor
private enum AsterStatusGlyph {
    static func draw(running: Bool, in rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        var transform = AffineTransform.identity
        transform.translate(x: rect.minX, y: rect.minY)
        transform.scale(x: rect.width / 16, y: rect.height / 16)
        let path = cursiveAS()
        path.transform(using: transform)
        path.lineWidth = (running ? 1.65 : 1.35) * min(rect.width, rect.height) / 16
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        NSColor.labelColor.setStroke()
        path.stroke()
    }

    private static func cursiveAS() -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0.6, y: 10.6))
        path.curve(
            to: NSPoint(x: 8.1, y: 4),
            controlPoint1: NSPoint(x: 3.2, y: 8.6),
            controlPoint2: NSPoint(x: 6.2, y: 4.8)
        )
        path.curve(
            to: NSPoint(x: 9.1, y: 6.6),
            controlPoint1: NSPoint(x: 8.8, y: 3.6),
            controlPoint2: NSPoint(x: 9.4, y: 4.6)
        )
        path.curve(
            to: NSPoint(x: 6.2, y: 9.8),
            controlPoint1: NSPoint(x: 8.9, y: 8),
            controlPoint2: NSPoint(x: 7.8, y: 9.4)
        )
        path.curve(
            to: NSPoint(x: 8.5, y: 6.2),
            controlPoint1: NSPoint(x: 5.2, y: 10.1),
            controlPoint2: NSPoint(x: 6.2, y: 8.4)
        )
        path.curve(
            to: NSPoint(x: 13.1, y: 5.5),
            controlPoint1: NSPoint(x: 9.6, y: 5),
            controlPoint2: NSPoint(x: 11.8, y: 4.7)
        )
        path.curve(
            to: NSPoint(x: 12.4, y: 7.4),
            controlPoint1: NSPoint(x: 14, y: 6),
            controlPoint2: NSPoint(x: 13.8, y: 6.9)
        )
        path.curve(
            to: NSPoint(x: 9.6, y: 8.8),
            controlPoint1: NSPoint(x: 11, y: 7.8),
            controlPoint2: NSPoint(x: 9.9, y: 8.4)
        )
        path.curve(
            to: NSPoint(x: 14, y: 9.3),
            controlPoint1: NSPoint(x: 11, y: 9),
            controlPoint2: NSPoint(x: 13.4, y: 8.8)
        )
        path.curve(
            to: NSPoint(x: 12, y: 10.9),
            controlPoint1: NSPoint(x: 14.6, y: 9.8),
            controlPoint2: NSPoint(x: 14.1, y: 10.8)
        )
        return path
    }
}

@MainActor
private final class StatusItemDisplayView: NSView {
    var running = false
    var upload = "0 B/s"
    var download = "0 B/s"
    var showSpeed = true

    override var isFlipped: Bool { true }
    override var allowsVibrancy: Bool { true }

    func preferredSize() -> NSSize {
        let thickness = max(NSStatusBar.system.thickness, 22)
        if !showSpeed {
            return NSSize(width: 18, height: thickness)
        }
        let textWidth = ceil(max(
            NSAttributedString(string: "↑ \(upload)", attributes: Self.speedAttributes).size().width,
            NSAttributedString(string: "↓ \(download)", attributes: Self.speedAttributes).size().width
        ))
        return NSSize(width: 16 + 3 + textWidth + 1, height: thickness)
    }

    private static var speedAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]
    }

    override func draw(_ dirtyRect: NSRect) {
        let glyphY = (bounds.height - 16) / 2
        AsterStatusGlyph.draw(running: running, in: NSRect(x: 1, y: glyphY, width: 16, height: 16))
        guard showSpeed else { return }
        let textX: CGFloat = 18
        let textWidth = max(bounds.width - textX, 0)
        NSAttributedString(string: "↑ \(upload)", attributes: Self.speedAttributes)
            .draw(in: NSRect(x: textX, y: glyphY - 1, width: textWidth, height: 10))
        NSAttributedString(string: "↓ \(download)", attributes: Self.speedAttributes)
            .draw(in: NSRect(x: textX, y: glyphY + 8, width: textWidth, height: 10))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@main
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    public static var shared: AppDelegate?
    var isRelaunching = false

    var window: NSWindow?
    var statusItem: NSStatusItem?
    private var statusItemView: StatusItemDisplayView?
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
        UserDefaults.standard.register(defaults: [
            "showStatusBarSpeed": true,
            "keepDockWhenWindowClosed": false,
        ])
        NSApp.applicationIconImage = AsterBrandMark.resolvedIcon
        let minimizeOnLaunch = UserDefaults.standard.bool(forKey: "minimizeOnLaunch")
        if minimizeOnLaunch && !UserDefaults.standard.bool(forKey: "keepDockWhenWindowClosed") {
            NSApp.setActivationPolicy(.accessory)
        }

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
            .sink { [weak self] _ in
                self?.syncCaptureMenuItems()
                self?.updateStatusItemTitle()
                self?.refreshStatusMenu()
            }

        // 3. 构建标准系统主菜单
        setupAppMainMenu()

        // 4. 主窗口调度
        if !minimizeOnLaunch {
            showMainWindow()
        } else {
            updateDockPolicy()
        }

        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateStatusItemTitle()
                self?.updateDockPolicy()
            }
        }

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
        // Restarting the UI must reconnect to the live daemon instead of
        // SIGTERM-racing a newly spawned instance.
        AsterState.shared.stopRealtimeStreams()
        if !isRelaunching {
            stopDaemonOnQuit()
        }
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

    // MARK: - 主控制台视窗与 Dock 栏图标生命周期策略
    public func updateDockPolicy() {
        let keepDock = UserDefaults.standard.bool(forKey: "keepDockWhenWindowClosed")
        let mainVisible = window?.isVisible == true
        let inspectorVisible = InspectorWindowController.shared.isVisible
        let wantsDock = keepDock || mainVisible || inspectorVisible
        let policy: NSApplication.ActivationPolicy = wantsDock ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
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
        prepareToShowWindow()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updateDockPolicy()
    }

    public func prepareToShowWindow() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        updateDockPolicy()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
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
        let aboutItem = appMenu.addItem(withTitle: "关于 Aster", action: #selector(onOpenAbout), keyEquivalent: "")
        aboutItem.target = self
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
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
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
        button.isHidden = false
        button.alphaValue = 1.0
        button.imageScaling = .scaleNone

        let menu = statusMenu ?? NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        buildStatusMenu(menu)
        statusMenu = menu
        item.menu = menu
        button.target = nil
        button.action = nil

        NSLog("[Aster] statusItem installed with native menu (%@)", reason)
        return true
    }

    private func statusItemDisplayView(in button: NSStatusBarButton) -> StatusItemDisplayView {
        if let view = statusItemView {
            return view
        }
        let view = StatusItemDisplayView(frame: .zero)
        view.autoresizingMask = [.height]
        button.addSubview(view)
        statusItemView = view
        return view
    }

    // MARK: - NSMenuDelegate 委托生命周期钩子
    public func menuNeedsUpdate(_ menu: NSMenu) {
        if AsterState.shared.strategyGroups.isEmpty {
            Task { @MainActor in
                await AsterState.shared.fetchStrategyGroups()
            }
        }
        // AppKit calls this immediately before it starts tracking the menu.
        // This is the one safe point to rebuild its hierarchy.
        if !isMenuOpen { buildStatusMenu(menu) }
    }

    public func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        if AsterState.shared.strategyGroups.isEmpty {
            Task { @MainActor in
                await AsterState.shared.fetchStrategyGroups()
                if self.isMenuOpen {
                    // Never remove/re-add menu items while AppKit is tracking
                    // the menu; that closes popups and loses mouse tracking.
                    self.updateLiveMenuItems(in: menu)
                }
            }
        }
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
        menu.addItem(makeStickyItem(title: "显示主窗口", icon: "macwindow") { [weak self] in
            self?.onOpenDashboard()
        })

        // 出站分流模式（指示标 + 快捷切换，专业英文全大写）
        let (modeBadge): (String) = {
            switch state.status.mode {
            case "global": return "GLOBAL"
            case "direct": return "DIRECT"
            default: return "RULE"
            }
        }()
        let modeRootItem = NSMenuItem(title: "出站模式", action: nil, keyEquivalent: "")
        modeRootItem.identifier = NSUserInterfaceItemIdentifier("aster.outbound-mode")
        let modeImage = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "出站模式")
        modeImage?.isTemplate = true
        modeRootItem.image = modeImage
        
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
        modeMenu.autoenablesItems = false
        modeMenu.addItem(makeStickyItem(
            title: "规则分流 (RULE)",
            icon: "arrow.triangle.branch",
            checked: state.status.mode == "rule",
            kind: .mode("rule")
        ) { AsterState.shared.setMode("rule") })
        modeMenu.addItem(makeStickyItem(
            title: "全局代理 (GLOBAL)",
            icon: "globe.asia.australia.fill",
            checked: state.status.mode == "global",
            kind: .mode("global")
        ) { AsterState.shared.setMode("global") })
        modeMenu.addItem(makeStickyItem(
            title: "直接连接 (DIRECT)",
            icon: "bolt.horizontal.fill",
            checked: state.status.mode == "direct",
            kind: .mode("direct")
        ) { AsterState.shared.setMode("direct") })

        modeRootItem.submenu = modeMenu
        menu.addItem(modeRootItem)

        menu.addItem(NSMenuItem.separator())

        // ==========================================
        // 2. 策略组列表（右侧展示当前选中节点，不堆砌生硬符号）
        // ==========================================
        let displayGroups = state.visibleStrategyGroups
        for group in displayGroups {
            let selectedLabel = state.selectedLabel(in: group)
            let nowLabel = selectedLabel.isEmpty ? "" : "   [\(selectedLabel.truncated(toVisualWidth: 14))]"
            let strategyItem = NSMenuItem(title: group.name, action: nil, keyEquivalent: "")
            let groupIcon: String = {
                if group.tag == "proxy" || group.name.contains("节点选择") {
                    return "slider.horizontal.3"
                } else if group.tag == "auto" || group.name.contains("自动") {
                    return "bolt.horizontal.circle.fill"
                } else if group.name.contains("港") || group.name.contains("HK") || group.name.contains("台") || group.name.contains("美") || group.name.contains("日") || group.name.contains("韩") || group.name.contains("新加坡") {
                    return "globe.asia.australia.fill"
                } else {
                    return "arrow.triangle.branch"
                }
            }()
            let groupImage = NSImage(systemSymbolName: groupIcon, accessibilityDescription: group.name)
            groupImage?.isTemplate = true
            strategyItem.image = groupImage

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
                let rawIcon = state.iconForProcess(path: proc.processPath ?? "", name: proc.name, size: 12)
                let pItem = makeStickyItem(
                    title: displayProcName,
                    image: makeRoundedIcon(rawIcon, size: 12, cornerRadius: 2.5),
                    accessory: speedStr,
                    toolTip: "\(proc.name) (\(speedStr)) - 点击打开请求日志审查"
                ) {
                    InspectorWindowController.shared.show()
                }
                menu.addItem(pItem)
            }
        }

        menu.addItem(NSMenuItem.separator())

        // ==========================================
        // 4. 网络控制与系统接管 (规范快捷键 ⌘D / ⌘S / ⌘E / ⌘C)
        // ==========================================
        menu.addItem(makeStickyItem(title: "请求日志…", icon: "list.bullet.rectangle.portrait") {
            InspectorWindowController.shared.show()
        })

        let sysProxyItem = makeStickyItem(
            title: "设置为系统代理",
            icon: "network",
            kind: .capture(systemProxy: true)
        ) { [weak self] in
            self?.onToggleSystemProxy()
        }
        statusBarSystemProxyItem = sysProxyItem
        menu.addItem(sysProxyItem)

        let tunItem = makeStickyItem(
            title: "虚拟网卡",
            icon: "shield.lefthalf.filled",
            kind: .capture(systemProxy: false)
        ) { [weak self] in
            self?.onToggleTun()
        }
        statusBarTunItem = tunItem
        menu.addItem(tunItem)
        syncCaptureMenuItems()

        menu.addItem(makeStickyItem(title: "复制终端代理命令", icon: "terminal") {
            AsterState.shared.copyTerminalProxyCommand()
        })

        menu.addItem(NSMenuItem.separator())

        // ==========================================
        // 5. 配置与控制 (⌘R / 切换配置 / 重启应用 / 退出 ⌘Q)
        // ==========================================
        if !state.configs.isEmpty {
            let activeConfigName = state.configs.first(where: { $0.active })?.name ?? "默认配置"
            let configRootItem = createMenuItem(title: "切换配置", icon: "doc.plaintext", action: nil)
            configRootItem.identifier = NSUserInterfaceItemIdentifier("aster.active-config")
            
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
            configSubmenu.autoenablesItems = false
            for cfg in state.configs {
                let symbol = cfg.kind == "subscription" ? "link.circle.fill" : "doc.text.fill"
                configSubmenu.addItem(makeStickyItem(
                    title: cfg.name.truncated(toVisualWidth: 26),
                    icon: symbol,
                    checked: cfg.active,
                    kind: .config(cfg.id)
                ) { [weak self] in
                    self?.onSwitchProfileID(cfg.id)
                })
            }
            configRootItem.submenu = configSubmenu
            menu.addItem(configRootItem)
        }

        menu.addItem(makeStickyItem(title: "重载配置", icon: "arrow.clockwise") { [weak self] in
            self?.onRestartCore()
        })
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

        let showSpeed = UserDefaults.standard.bool(forKey: "showStatusBarSpeed")
        button.title = ""
        button.image = nil
        button.imagePosition = .imageOnly
        let view = statusItemDisplayView(in: button)
        view.running = state.status.running
        view.upload = upload
        view.download = download
        view.showSpeed = showSpeed
        let size = view.preferredSize()
        let height = button.bounds.height > 0 ? button.bounds.height : size.height
        view.frame = NSRect(x: 0, y: 0, width: size.width, height: height)
        statusItem?.length = size.width
        view.needsDisplay = true
        if showSpeed {
            button.toolTip = "Aster：上传 \(upload)，下载 \(download)"
            button.setAccessibilityLabel("Aster，上传 \(upload)，下载 \(download)，\(state.status.running ? "核心运行中" : "核心未运行")")
        } else {
            button.toolTip = "Aster"
            button.setAccessibilityLabel("Aster，\(state.status.running ? "核心运行中" : "核心未运行")")
        }
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
        let checked: Bool
        let enabled: Bool
        let tip: String
        if systemProxy {
            checked = status.capture.systemProxy
            let available = status.capabilities?.systemProxy.available ?? true
            enabled = status.running && available
            tip = available ? (status.running ? "将 mixed 端口写入 macOS 系统代理" : "核心未运行时不能开启系统代理") : (status.capabilities?.systemProxy.reason ?? "")
        } else {
            checked = status.capture.tun
            let available = status.capabilities?.tun.available ?? true
            enabled = available
            tip = available ? "通过 PKG 网络组件启用虚拟网卡" : (status.capabilities?.tun.reason ?? "")
        }
        item.state = checked ? .on : .off
        item.isEnabled = enabled
        item.toolTip = tip
        if let view = item.view as? StickyMenuItemView {
            view.apply(checked: checked, enabled: enabled, toolTip: tip)
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
            switch item.identifier?.rawValue {
            case "aster.outbound-mode":
                updateModeMenuTitle(item, mode: state.status.mode)
            case "aster.active-config":
                updateConfigMenuTitle(item, configs: state.configs)
            default:
                break
            }
            if let view = item.view as? StickyMenuItemView {
                if case .capture(let systemProxy) = view.kind {
                    applyCaptureState(to: item, systemProxy: systemProxy)
                } else {
                    refreshStickyView(view)
                }
            }
            if let sub = item.submenu {
                if let group = state.visibleStrategyGroups.first(where: { $0.name == sub.title || $0.tag == sub.title }) {
                    let selectedLabel = state.selectedLabel(in: group)
                    let nowLabel = selectedLabel.isEmpty ? "" : "   [\(selectedLabel.truncated(toVisualWidth: 14))]"
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
                    item.attributedTitle = titleAttr
                    if item.image == nil {
                        let groupIcon: String = {
                            if group.tag == "proxy" || group.name.contains("节点选择") {
                                return "slider.horizontal.3"
                            } else if group.tag == "auto" || group.name.contains("自动") {
                                return "bolt.horizontal.circle.fill"
                            } else if group.name.contains("港") || group.name.contains("HK") || group.name.contains("台") || group.name.contains("美") || group.name.contains("日") || group.name.contains("韩") || group.name.contains("新加坡") {
                                return "globe.asia.australia.fill"
                            } else {
                                return "arrow.triangle.branch"
                            }
                        }()
                        let groupImage = NSImage(systemSymbolName: groupIcon, accessibilityDescription: group.name)
                        groupImage?.isTemplate = true
                        item.image = groupImage
                    }
                    updateStrategySubmenuItems(sub, group: group)
                } else {
                    updateLiveMenuItems(in: sub)
                }
            }
        }
    }

    private func updateModeMenuTitle(_ item: NSMenuItem, mode: String) {
        let badge: String
        switch mode {
        case "global": badge = "GLOBAL"
        case "direct": badge = "DIRECT"
        default: badge = "RULE"
        }
        let title = NSMutableAttributedString(string: "出站模式", attributes: [
            .font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.labelColor,
        ])
        title.append(NSAttributedString(string: "   [\(badge)]", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .bold),
            .foregroundColor: NSColor.controlAccentColor,
        ]))
        item.attributedTitle = title
    }

    private func updateConfigMenuTitle(_ item: NSMenuItem, configs: [ConfigProfileItem]) {
        let activeName = configs.first(where: { $0.active })?.name ?? "默认配置"
        let title = NSMutableAttributedString(string: "切换配置", attributes: [
            .font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.labelColor,
        ])
        title.append(NSAttributedString(string: "   \(activeName.truncated(toVisualWidth: 14))", attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        item.attributedTitle = title
    }

    private struct StrategyMemberPresentation {
        let title: String
        let accessory: String
        let delayColor: NSColor
        let attrAccessory: NSAttributedString
        let checked: Bool
        let enabled: Bool
        let toolTip: String
    }

    private func protocolShortCode(for rawProtocol: String) -> String? {
        let p = rawProtocol.trimmingCharacters(in: .whitespaces).lowercased()
        switch p {
        case "hysteria2", "hy2":
            return "HY2"
        case "hysteria", "hy":
            return "HY"
        case "tuic":
            return "TUIC"
        case "wireguard", "wg":
            return "WG"
        case "shadowtls", "shadow-tls":
            return "STLS"
        case "vless":
            return "VLESS"
        case "vmess":
            return "VMESS"
        case "trojan":
            return "TROJAN"
        case "shadowsocks", "ss":
            return "SS"
        case "socks", "socks5":
            return "SOCKS5"
        case "http", "https":
            return "HTTP"
        default:
            if !p.isEmpty && p != "unknown" {
                return p.uppercased()
            }
            return nil
        }
    }

    private func nodeDelayColor(delay: Int, isTesting: Bool) -> NSColor {
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
    }

    private func formatStrategyMember(group: StrategyGroup, tag: String) -> StrategyMemberPresentation {
        let state = AsterState.shared
        let isAuto = (tag == "auto")
        let childGroup = isAuto ? nil : state.group(tagged: tag)
        let node = state.findNode(for: tag)

        let title: String
        var toolTip: String

        if isAuto {
            let winner = state.autoWinnerName()
            if let winner, !winner.isEmpty {
                title = "♻️ 自动优选 ➔ \(NodeNameSanitizer.clean(winner))"
            } else {
                title = "♻️ 自动优选"
            }
            var tip = "自动测速并分流至最低延迟节点"
            if let winner {
                tip += " (当前命中: \(winner))"
            }
            toolTip = tip
        } else if let childGroup {
            let groupName = childGroup.name.isEmpty ? tag : childGroup.name
            let cleanName = NodeNameSanitizer.clean(groupName)
            title = cleanName.hasPrefix("[组]") ? cleanName : "[组] \(cleanName)"
            var tip = "策略组: \(childGroup.name)"
            if let now = childGroup.now, !now.isEmpty {
                tip += " (当前选择: \(state.memberTitle(for: now)))"
            }
            toolTip = tip
        } else if tag == "direct" {
            title = "DIRECT"
            toolTip = "直连出站"
        } else if tag == "block" || tag == "reject" {
            title = "REJECT"
            toolTip = "阻断出站"
        } else {
            let rawTitle = state.memberTitle(for: tag)
            if let proto = node?.protocolName, let badge = protocolShortCode(for: proto) {
                let badgePrefix = "[\(badge)]"
                if rawTitle.localizedCaseInsensitiveContains(badgePrefix) {
                    title = rawTitle
                } else {
                    title = "\(badgePrefix) \(rawTitle)"
                }
            } else {
                title = rawTitle
            }
            toolTip = title
        }

        let isTesting = state.isNodeTesting(tag) || (isAuto && state.isTestingGroup(group)) || state.isTestingDelays
        let delay: Int = {
            if let childGroup {
                return childGroup.delayMs ?? state.memberDelay(for: tag)
            }
            return state.memberDelay(for: tag)
        }()
        let accessory = nodeDelayText(delay: delay, tag: tag, isTesting: isTesting)
        let delayColor = nodeDelayColor(delay: delay, isTesting: isTesting)
        let checked = state.isMemberSelected(group: group, tag: tag)
        let enabled = state.canSelectMember(group: group, tag: tag)
        let finalToolTip = toolTip.contains(accessory) ? toolTip : "\(toolTip)  \(accessory)"

        let attrAccessory = NSAttributedString(
            string: accessory,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: delayColor
            ]
        )

        return StrategyMemberPresentation(
            title: title,
            accessory: accessory,
            delayColor: delayColor,
            attrAccessory: attrAccessory,
            checked: checked,
            enabled: enabled,
            toolTip: finalToolTip
        )
    }

    private func refreshStickyView(_ view: StickyMenuItemView) {
        let state = AsterState.shared
        switch view.kind {
        case .mode(let mode):
            view.apply(checked: state.status.mode == mode)
        case .config(let id):
            view.apply(checked: state.configs.first(where: { $0.id == id })?.active == true)
        case .node(let groupTag, let tag):
            guard let group = state.group(tagged: groupTag) else { return }
            let p = formatStrategyMember(group: group, tag: tag)
            view.apply(
                title: p.title,
                accessory: p.accessory,
                accessoryColor: p.delayColor,
                accessoryAttributedString: p.attrAccessory,
                checked: p.checked,
                enabled: p.enabled,
                toolTip: p.toolTip
            )
        case .action, .capture:
            break
        }
    }

    private func updateStrategySubmenuItems(_ sub: NSMenu, group: StrategyGroup) {
        sub.autoenablesItems = false
        let state = AsterState.shared
        for item in sub.items {
            if let targetView = item.view as? StrategySpeedHeaderView {
                targetView.update(isTesting: state.isTestingGroup(group))
            } else if let dict = item.representedObject as? [String: String],
                      let tag = dict["tag"] {
                applyStrategyMemberItem(item, group: group, tag: tag)
            }
        }
    }

    private func applyStrategyMemberItem(_ item: NSMenuItem, group: StrategyGroup, tag: String) {
        let p = formatStrategyMember(group: group, tag: tag)
        item.title = p.title.truncated(toVisualWidth: 26)
        item.state = p.checked ? .on : .off
        item.isEnabled = p.enabled
        item.toolTip = p.toolTip

        if let view = item.view as? StickyMenuItemView {
            view.apply(
                title: p.title,
                accessory: p.accessory,
                accessoryColor: p.delayColor,
                accessoryAttributedString: p.attrAccessory,
                checked: p.checked,
                enabled: p.enabled,
                toolTip: p.toolTip
            )
        } else {
            let delay = AsterState.shared.memberDelay(for: tag)
            item.attributedTitle = nodeMenuTitle(name: p.title, tag: tag, delay: delay)
        }
    }

    private func makeStrategyMenu(group: StrategyGroup) -> NSMenu {
        let nodeMenu = NSMenu(title: group.name)
        nodeMenu.autoenablesItems = false

        // 1. 置顶延迟测试项 (采用 NSView 自定义按钮：点击时在菜单内原地触发测速，绝不触发 NSMenu 的 dismiss 动作)
        let isTesting = AsterState.shared.isTestingGroup(group)
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

        for tag in group.members {
            let item = NSMenuItem()
            item.representedObject = ["group": group.tag, "tag": tag]
            let view = StickyMenuItemView(
                title: "",
                kind: .node(group: group.tag, tag: tag)
            ) { [weak self] in
                self?.selectStrategyMember(groupTag: group.tag, tag: tag)
            }
            item.view = view
            applyStrategyMemberItem(item, group: group, tag: tag)
            nodeMenu.addItem(item)
        }
        return nodeMenu
    }

    private func nodeMenuTitle(name: String, tag: String, delay: Int) -> NSAttributedString {
        let cleanName = name.truncated(toVisualWidth: 20)
        let isTesting = AsterState.shared.testingTags.contains(tag) || AsterState.shared.isTestingDelays
        let delayText = nodeDelayText(delay: delay, tag: tag, isTesting: isTesting)
        let textColor = nodeDelayColor(delay: delay, isTesting: isTesting)

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
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
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

    private func makeStickyItem(
        title: String,
        icon: String? = nil,
        image: NSImage? = nil,
        accessory: String = "",
        checked: Bool = false,
        enabled: Bool = true,
        toolTip: String? = nil,
        kind: StickyMenuItemView.Kind = .action,
        handler: @escaping () -> Void
    ) -> NSMenuItem {
        let item = NSMenuItem()
        let resolvedImage: NSImage? = image ?? icon.flatMap {
            let img = NSImage(systemSymbolName: $0, accessibilityDescription: title)
            img?.isTemplate = true
            return img
        }
        let view = StickyMenuItemView(
            title: title,
            accessory: accessory,
            icon: resolvedImage,
            checked: checked,
            enabled: enabled,
            kind: kind,
            onClick: handler
        )
        if let toolTip {
            view.toolTip = toolTip
        }
        item.view = view
        item.isEnabled = enabled
        item.state = checked ? .on : .off
        item.toolTip = toolTip
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

    @objc func onOpenAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationIcon: AsterBrandMark.resolvedIcon
        ])
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
              let group = AsterState.shared.group(tagged: tag) else { return }
        onTriggerStrategyGroupSpeedtest(group: group)
    }

    func onTriggerStrategyGroupSpeedtest(group: StrategyGroup) {
        AsterState.shared.testStrategyGroup(group)
    }

    @objc func onSelectStrategyNode(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? [String: String],
              let groupTag = value["group"],
              let tag = value["tag"] else { return }
        selectStrategyMember(groupTag: groupTag, tag: tag)
    }

    func selectStrategyMember(groupTag: String, tag: String) {
        guard let group = AsterState.shared.group(tagged: groupTag) else { return }
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
        onSwitchProfileID(configId)
    }

    func onSwitchProfileID(_ configId: String) {
        AsterState.shared.activateConfig(id: configId)
    }

    @objc func onRelaunchApp() {
        AsterState.shared.relaunchApplication()
    }

    @objc func onQuitApp() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - 状态栏菜单项自定义视图：点击不关闭菜单
@MainActor
final class StickyMenuItemView: NSView {
    enum Kind {
        case action
        case mode(String)
        case capture(systemProxy: Bool)
        case node(group: String, tag: String)
        case config(String)
    }

    let kind: Kind
    private var onClick: () -> Void
    private var titleText: String
    private var accessoryText: String
    private var accessoryColor: NSColor
    private var accessoryAttributedString: NSAttributedString?
    private var checked: Bool
    private var itemEnabled: Bool
    private var isHighlighted = false
    private var trackingArea: NSTrackingArea?

    private let checkView = NSImageView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let accessoryLabel = NSTextField(labelWithString: "")

    private var isSubmenuItem: Bool {
        switch kind {
        case .node, .mode, .config:
            return true
        case .action, .capture:
            return false
        }
    }

    init(
        title: String,
        accessory: String = "",
        accessoryColor: NSColor = .secondaryLabelColor,
        accessoryAttributedString: NSAttributedString? = nil,
        icon: NSImage? = nil,
        checked: Bool = false,
        enabled: Bool = true,
        kind: Kind = .action,
        onClick: @escaping () -> Void
    ) {
        self.kind = kind
        self.onClick = onClick
        self.titleText = title
        self.accessoryText = accessory
        self.accessoryColor = accessoryColor
        self.accessoryAttributedString = accessoryAttributedString
        self.checked = checked
        self.itemEnabled = enabled
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        autoresizingMask = [.width]
        wantsLayer = true
        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        setupUI()
        apply(
            title: title,
            accessory: accessory,
            accessoryColor: accessoryColor,
            accessoryAttributedString: accessoryAttributedString,
            checked: checked,
            enabled: enabled
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        checkView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(checkView)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)
        titleLabel.font = NSFont.menuFont(ofSize: 0)
        titleLabel.isEditable = false
        titleLabel.isBordered = false
        titleLabel.drawsBackground = false
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)
        accessoryLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        accessoryLabel.alignment = .right
        accessoryLabel.isEditable = false
        accessoryLabel.isBordered = false
        accessoryLabel.drawsBackground = false
        addSubview(accessoryLabel)
    }

    override func layout() {
        super.layout()
        if let sv = superview, sv.bounds.width > 0 {
            frame.size.width = sv.bounds.width
        }
        let height = bounds.height

        if isSubmenuItem {
            // 二级子菜单节点项（带左侧勾选列）
            checkView.isHidden = !checked
            checkView.frame = NSRect(x: 8, y: (height - 12) / 2, width: 12, height: 12)

            let hasIcon = iconView.image != nil
            if hasIcon {
                iconView.isHidden = false
                iconView.frame = NSRect(x: 24, y: (height - 14) / 2, width: 14, height: 14)
            } else {
                iconView.isHidden = true
                iconView.frame = .zero
            }

            let titleX: CGFloat = hasIcon ? 44 : 26

            if !accessoryText.isEmpty {
                accessoryLabel.isHidden = false
                accessoryLabel.frame = NSRect(x: bounds.width - 74, y: 3, width: 64, height: 18)
                titleLabel.frame = NSRect(
                    x: titleX,
                    y: 3,
                    width: max(bounds.width - titleX - 74 - 4, 40),
                    height: 18
                )
            } else {
                accessoryLabel.isHidden = true
                accessoryLabel.frame = .zero
                titleLabel.frame = NSRect(
                    x: titleX,
                    y: 3,
                    width: max(bounds.width - titleX - 14, 40),
                    height: 18
                )
            }
        } else {
            // 主菜单项（无左侧勾选列）
            // checkView: 隐藏或作为右侧指示器
            if checked {
                checkView.isHidden = false
                checkView.frame = NSRect(x: bounds.width - 24, y: (height - 12) / 2, width: 12, height: 12)
            } else {
                checkView.isHidden = true
                checkView.frame = .zero
            }

            // iconView: 居中于 NSRect(x: 13, y: (height - 16) / 2, width: 16, height: 16)，完美对齐原生 NSMenuItem.image（x=13~14）
            if iconView.image != nil {
                iconView.isHidden = false
                iconView.frame = NSRect(x: 13, y: (height - 16) / 2, width: 16, height: 16)
            } else {
                iconView.isHidden = true
                iconView.frame = .zero
            }

            // titleLabel: 严格起始于 x: 35，完全对齐原生 NSMenuItem.title（x=34~35）
            let titleX: CGFloat = 35

            if !accessoryText.isEmpty {
                accessoryLabel.isHidden = false
                let accWidth: CGFloat = 72
                accessoryLabel.frame = NSRect(x: bounds.width - accWidth - 10, y: 3, width: accWidth, height: 18)
                titleLabel.frame = NSRect(
                    x: titleX,
                    y: 3,
                    width: max(bounds.width - titleX - accWidth - 14, 40),
                    height: 18
                )
            } else {
                accessoryLabel.isHidden = true
                accessoryLabel.frame = .zero
                let trailingReserved: CGFloat = checked ? 28 : 14
                titleLabel.frame = NSRect(
                    x: titleX,
                    y: 3,
                    width: max(bounds.width - titleX - trailingReserved, 40),
                    height: 18
                )
            }
        }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        needsLayout = true
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
        if isHighlighted && itemEnabled {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 4.5, yRadius: 4.5).fill()
        }
    }

    func apply(
        title: String? = nil,
        accessory: String? = nil,
        accessoryColor: NSColor? = nil,
        accessoryAttributedString: NSAttributedString? = nil,
        icon: NSImage? = nil,
        checked: Bool? = nil,
        enabled: Bool? = nil,
        toolTip: String? = nil
    ) {
        if let title { titleText = title }
        if let accessory {
            accessoryText = accessory
            if accessoryAttributedString == nil {
                self.accessoryAttributedString = nil
            }
        }
        if let accessoryColor { self.accessoryColor = accessoryColor }
        if let accessoryAttributedString {
            self.accessoryAttributedString = accessoryAttributedString
            self.accessoryText = accessoryAttributedString.string
        }
        if let icon { iconView.image = icon }
        if let checked { self.checked = checked }
        if let enabled { itemEnabled = enabled }
        if let toolTip { self.toolTip = toolTip }

        titleLabel.stringValue = titleText

        if let attrStr = self.accessoryAttributedString {
            if isHighlighted {
                let m = NSMutableAttributedString(attributedString: attrStr)
                m.addAttribute(.foregroundColor, value: NSColor.selectedMenuItemTextColor, range: NSRange(location: 0, length: m.length))
                accessoryLabel.attributedStringValue = m
            } else {
                accessoryLabel.attributedStringValue = attrStr
            }
        } else {
            accessoryLabel.stringValue = accessoryText
            accessoryLabel.textColor = isHighlighted ? .selectedMenuItemTextColor : self.accessoryColor
        }

        checkView.image = self.checked ? NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil) : nil
        checkView.contentTintColor = isHighlighted ? .selectedMenuItemTextColor : .labelColor
        iconView.contentTintColor = isHighlighted ? .selectedMenuItemTextColor : .labelColor
        titleLabel.textColor = isHighlighted ? .selectedMenuItemTextColor : .labelColor
        alphaValue = itemEnabled ? 1 : 0.4
        needsLayout = true
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) {
        guard itemEnabled else { return }
        isHighlighted = true
        apply()
    }

    override func mouseExited(with event: NSEvent) {
        isHighlighted = false
        apply()
    }

    override func mouseUp(with event: NSEvent) {
        guard itemEnabled else { return }
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick()
    }
}

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
        layer?.cornerRadius = 4.5

        iconView.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "延迟测试")
        iconView.contentTintColor = .labelColor
        iconView.frame = NSRect(x: 8, y: 6, width: 14, height: 14)
        addSubview(iconView)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.frame = NSRect(x: 8, y: 6, width: 14, height: 14)
        spinner.isHidden = true
        addSubview(spinner)

        titleLabel.font = NSFont.menuFont(ofSize: 0)
        titleLabel.textColor = .labelColor
        titleLabel.frame = NSRect(x: 28, y: 4, width: max(bounds.width - 38, 180), height: 18)
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
        let height = bounds.height
        let iconY = (height - 14) / 2
        iconView.frame = NSRect(x: 8, y: iconY, width: 14, height: 14)
        spinner.frame = NSRect(x: 8, y: iconY, width: 14, height: 14)
        titleLabel.frame = NSRect(x: 28, y: (height - 18) / 2, width: max(bounds.width - 36, 180), height: 18)
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
            NSColor.quaternaryLabelColor.withAlphaComponent(0.2).setFill()
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
            titleLabel.textColor = .systemBlue
        } else {
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            iconView.isHidden = false
            iconView.contentTintColor = .labelColor
            titleLabel.textColor = .labelColor
        }
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) {
        isHighlighted = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHighlighted = false
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        guard !isTesting, AsterState.shared.status.running else { return }
        update(isTesting: true)
        onClick()
    }
}
