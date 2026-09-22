import SwiftUI
import AppKit
import Combine
import Darwin
@preconcurrency import UserNotifications

@MainActor
public enum ModeBadgeHelper {
    public static func image(for mode: String) -> NSImage {
        let size = NSSize(width: 17, height: 17)
        let img = NSImage(size: size)
        img.lockFocus()

        let appMode = AppMode.from(string: mode)
        let letter = String(appMode.code.prefix(1))
        let bgColor = appMode.nsColor

        let rect = NSRect(origin: .zero, size: size)
        bgColor.setFill()
        let path = NSBezierPath(roundedRect: rect, xRadius: 3.5, yRadius: 3.5)
        path.fill()

        let font = NSFont.systemFont(ofSize: 11, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let str = NSAttributedString(string: letter, attributes: attrs)
        let strSize = str.size()
        let strRect = NSRect(
            x: (size.width - strSize.width) / 2,
            y: (size.height - strSize.height) / 2 - 0.5,
            width: strSize.width,
            height: strSize.height
        )
        str.draw(in: strRect)

        img.unlockFocus()
        return img
    }
}

@MainActor
private enum NetworkWaveformGlyph {
    static func draw(running: Bool, in rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        let tintColor: NSColor = running ? .labelColor : NSColor.labelColor.withAlphaComponent(0.35)
        tintColor.setFill()

        let scale = min(rect.width, rect.height) / 16.0
        let barW: CGFloat = 2.0 * scale
        let corner: CGFloat = 1.0 * scale
        let baseline = rect.maxY - 1.5 * scale

        // 4 proportional equalizer waveform bars (Surge signature waveform)
        let h1: CGFloat = 6.5 * scale
        let r1 = NSRect(x: rect.minX + 0.8 * scale, y: baseline - h1, width: barW, height: h1)
        NSBezierPath(roundedRect: r1, xRadius: corner, yRadius: corner).fill()

        let h2: CGFloat = 13.5 * scale
        let r2 = NSRect(x: rect.minX + 4.2 * scale, y: baseline - h2, width: barW, height: h2)
        NSBezierPath(roundedRect: r2, xRadius: corner, yRadius: corner).fill()

        let h3: CGFloat = 5.0 * scale
        let r3 = NSRect(x: rect.minX + 7.6 * scale, y: baseline - h3, width: barW, height: h3)
        NSBezierPath(roundedRect: r3, xRadius: corner, yRadius: corner).fill()

        let h4: CGFloat = 10.0 * scale
        let r4 = NSRect(x: rect.minX + 11.0 * scale, y: baseline - h4, width: barW, height: h4)
        NSBezierPath(roundedRect: r4, xRadius: corner, yRadius: corner).fill()

        // Top-right running beacon dot
        let dotSize: CGFloat = 2.6 * scale
        let dotRect = NSRect(x: rect.minX + 13.6 * scale, y: rect.minY + 1.2 * scale, width: dotSize, height: dotSize)
        if running {
            NSColor(srgbRed: 0.22, green: 0.72, blue: 0.48, alpha: 1.0).setFill()
        } else {
            NSColor.secondaryLabelColor.withAlphaComponent(0.3).setFill()
        }
        NSBezierPath(ovalIn: dotRect).fill()
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
        NetworkWaveformGlyph.draw(running: running, in: NSRect(x: 1, y: glyphY, width: 16, height: 16))
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
    private var appMenuRuleItem: NSMenuItem?
    private var appMenuGlobalItem: NSMenuItem?
    private var appMenuDirectItem: NSMenuItem?
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
    func showMainWindow(tab: SidebarTab? = nil) {
        if let tab = tab {
            AsterState.shared.selectedTab = tab
        }
        if window == nil {
            let defaultRect = NSRect(x: 0, y: 0, width: 1120, height: 760)
            let win = NSWindow(
                contentRect: defaultRect,
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            // 兼顾 MacBook 13" 屏幕原生半屏分屏 (Split View / Tile) 与全功能操作空间
            win.minSize = NSSize(width: 840, height: 560)
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

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        // 遵循 macOS 原生规范：由 minSize 严守物理底线，内部响应式自适应任意长宽比，
        // 绝不强行锁死固定比例，避免拖拽单边时发生鼠标光标抖动抗衡与系统分屏破坏
        let targetWidth = max(sender.minSize.width, frameSize.width)
        let targetHeight = max(sender.minSize.height, frameSize.height)
        return NSSize(width: targetWidth, height: targetHeight)
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
        let modeMenuItem = NSMenuItem(title: "出站模式", action: nil, keyEquivalent: "")
        let modeMenu = NSMenu(title: "出站模式")
        let ruleItem = modeMenu.addItem(withTitle: "规则分流 (Rule)", action: #selector(onSetModeRule), keyEquivalent: "1")
        ruleItem.keyEquivalentModifierMask = [.command, .control]
        ruleItem.target = self
        let globalItem = modeMenu.addItem(withTitle: "全局代理 (Global)", action: #selector(onSetModeGlobal), keyEquivalent: "2")
        globalItem.keyEquivalentModifierMask = [.command, .control]
        globalItem.target = self
        let directItem = modeMenu.addItem(withTitle: "直接连接 (Direct)", action: #selector(onSetModeDirect), keyEquivalent: "3")
        directItem.keyEquivalentModifierMask = [.command, .control]
        directItem.target = self
        modeMenuItem.submenu = modeMenu
        controlMenu.addItem(modeMenuItem)
        appMenuRuleItem = ruleItem
        appMenuGlobalItem = globalItem
        appMenuDirectItem = directItem
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

    // MARK: - 动态组装原生状态栏菜单 (完全对标 Surge macOS 规范)
    public func buildStatusMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let state = AsterState.shared

        // 1. 显示主窗口 ⌘M
        let showMainItem = NSMenuItem(title: "显示主窗口", action: #selector(onBringAllFront), keyEquivalent: "m")
        showMainItem.target = self
        menu.addItem(showMainItem)

        menu.addItem(NSMenuItem.separator())

        // 2. 出站模式 [R] >
        let mode = state.status.mode
        let modeItem = NSMenuItem(title: "出站模式", action: nil, keyEquivalent: "")
        modeItem.identifier = NSUserInterfaceItemIdentifier("aster.outbound-mode")
        updateModeMenuTitle(modeItem, mode: mode)

        let modeMenu = NSMenu(title: "出站模式")
        modeMenu.autoenablesItems = false

        let ruleItem = NSMenuItem(title: "规则分流 (Rule)", action: #selector(onSetModeRule), keyEquivalent: "")
        ruleItem.target = self
        ruleItem.state = (mode == "rule") ? .on : .off
        modeMenu.addItem(ruleItem)

        let globalItem = NSMenuItem(title: "全局代理 (Global)", action: #selector(onSetModeGlobal), keyEquivalent: "")
        globalItem.target = self
        globalItem.state = (mode == "global") ? .on : .off
        modeMenu.addItem(globalItem)

        let directItem = NSMenuItem(title: "直接连接 (Direct)", action: #selector(onSetModeDirect), keyEquivalent: "")
        directItem.target = self
        directItem.state = (mode == "direct") ? .on : .off
        modeMenu.addItem(directItem)

        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        // 3. 为当前网页设置规则…
        let addRuleItem = NSMenuItem(title: "为当前网页设置规则…", action: #selector(onAddRuleForWebpage), keyEquivalent: "")
        addRuleItem.target = self
        menu.addItem(addRuleItem)

        menu.addItem(NSMenuItem.separator())

        // 4. 策略组列表（纯文本无多余图标、左侧平齐、右侧次级色显示当前选中节点与国旗）
        let displayGroups = state.visibleStrategyGroups
        for group in displayGroups {
            let strategyItem = NSMenuItem(title: group.name, action: nil, keyEquivalent: "")
            strategyItem.identifier = NSUserInterfaceItemIdentifier("aster.group.\(group.tag)")
            strategyItem.representedObject = group.tag
            updateStrategyMenuItemTitle(strategyItem, group: group)
            strategyItem.submenu = makeStrategyMenu(group: group)
            menu.addItem(strategyItem)
        }

        menu.addItem(NSMenuItem.separator())

        // 5. Aster 面板… ⌘D
        let panelItem = NSMenuItem(title: "Aster 面板…", action: #selector(onOpenDashboard), keyEquivalent: "d")
        panelItem.target = self
        menu.addItem(panelItem)

        menu.addItem(NSMenuItem.separator())

        // 6. 设置为系统代理 ⌘S
        let sysProxyItem = NSMenuItem(title: "设置为系统代理", action: #selector(onToggleSystemProxy), keyEquivalent: "s")
        sysProxyItem.target = self
        statusBarSystemProxyItem = sysProxyItem
        menu.addItem(sysProxyItem)

        // 7. 增强模式 ⌘E
        let tunItem = NSMenuItem(title: "增强模式", action: #selector(onToggleTun), keyEquivalent: "e")
        tunItem.target = self
        statusBarTunItem = tunItem
        menu.addItem(tunItem)
        syncCaptureMenuItems()

        // 8. 复制终端代理命令 ⌘C
        let copyCmdItem = NSMenuItem(title: "复制终端代理命令", action: #selector(onCopyTerminalCommand), keyEquivalent: "c")
        copyCmdItem.target = self
        menu.addItem(copyCmdItem)

        menu.addItem(NSMenuItem.separator())

        // 9. 功能 >
        let featureRootItem = NSMenuItem(title: "功能", action: nil, keyEquivalent: "")
        let featureMenu = NSMenu(title: "功能")
        featureMenu.autoenablesItems = false

        let flushDNSItem = NSMenuItem(title: "清除 DNS 缓存", action: #selector(onFlushDNS), keyEquivalent: "")
        flushDNSItem.target = self
        featureMenu.addItem(flushDNSItem)

        let testAllItem = NSMenuItem(title: "测试全部节点延迟", action: #selector(onSpeedtestAll), keyEquivalent: "")
        testAllItem.target = self
        featureMenu.addItem(testAllItem)

        let restartCoreItem = NSMenuItem(title: "重载核心配置", action: #selector(onRestartCore), keyEquivalent: "r")
        restartCoreItem.target = self
        featureMenu.addItem(restartCoreItem)

        let relaunchItem = NSMenuItem(title: "重启应用", action: #selector(onRelaunchApp), keyEquivalent: "")
        relaunchItem.target = self
        featureMenu.addItem(relaunchItem)

        featureRootItem.submenu = featureMenu
        menu.addItem(featureRootItem)

        // 10. 配置 >
        if !state.configs.isEmpty {
            let configRootItem = NSMenuItem(title: "配置", action: nil, keyEquivalent: "")
            configRootItem.identifier = NSUserInterfaceItemIdentifier("aster.config-menu")
            let configSubmenu = NSMenu(title: "配置")
            configSubmenu.autoenablesItems = false
            for cfg in state.configs {
                let item = NSMenuItem(title: cfg.name, action: #selector(onSwitchProfile(_:)), keyEquivalent: "")
                item.representedObject = cfg.id
                item.target = self
                item.state = cfg.active ? .on : .off
                configSubmenu.addItem(item)
            }
            configRootItem.submenu = configSubmenu
            menu.addItem(configRootItem)
        }

        menu.addItem(NSMenuItem.separator())

        // 11. 退出 ⌘Q
        let quitItem = NSMenuItem(title: "退出", action: #selector(onQuitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
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
        let mode = AsterState.shared.status.mode
        appMenuRuleItem?.state = (mode == "rule") ? .on : .off
        appMenuGlobalItem?.state = (mode == "global") ? .on : .off
        appMenuDirectItem?.state = (mode == "direct") ? .on : .off
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
            if item.identifier?.rawValue == "aster.outbound-mode" {
                updateModeMenuTitle(item, mode: state.status.mode)
                if let modeSub = item.submenu {
                    modeSub.item(withTitle: "规则分流 (Rule)")?.state = (state.status.mode == "rule") ? .on : .off
                    modeSub.item(withTitle: "全局代理 (Global)")?.state = (state.status.mode == "global") ? .on : .off
                    modeSub.item(withTitle: "直接连接 (Direct)")?.state = (state.status.mode == "direct") ? .on : .off
                }
            } else if item.identifier?.rawValue == "aster.config-menu" {
                if let cfgSub = item.submenu {
                    for cfgItem in cfgSub.items {
                        if let id = cfgItem.representedObject as? String {
                            cfgItem.state = (state.configs.first(where: { $0.id == id })?.active == true) ? .on : .off
                        }
                    }
                }
            } else if let groupTag = item.representedObject as? String,
                      let group = state.visibleStrategyGroups.first(where: { $0.tag == groupTag }) {
                updateStrategyMenuItemTitle(item, group: group)
            }
            if let sub = item.submenu {
                if let group = state.visibleStrategyGroups.first(where: { $0.name == sub.title || $0.tag == sub.title }) {
                    updateStrategySubmenuItems(sub, group: group)
                }
            }
        }
        applyCaptureState(to: statusBarSystemProxyItem, systemProxy: true)
        applyCaptureState(to: statusBarTunItem, systemProxy: false)
    }

    private func updateModeMenuTitle(_ item: NSMenuItem, mode: String) {
        let badgeImg = ModeBadgeHelper.image(for: mode)
        let attachment = NSTextAttachment()
        attachment.image = badgeImg
        attachment.bounds = NSRect(x: 0, y: -2.5, width: 17, height: 17)

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.tabStops = [
            NSTextTab(textAlignment: .right, location: 240, options: [:])
        ]

        let titleAttr = NSMutableAttributedString(string: "出站模式\t", attributes: [
            .font: NSFont.menuFont(ofSize: 0),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle
        ])
        titleAttr.append(NSAttributedString(attachment: attachment))
        item.attributedTitle = titleAttr
    }

    private func updateStrategyMenuItemTitle(_ item: NSMenuItem, group: StrategyGroup) {
        let state = AsterState.shared
        let selectedLabel = state.selectedLabel(in: group)
        let cleanSelected = NodeNameSanitizer.clean(selectedLabel)
        let fullSelected = cleanSelected.truncated(toVisualWidth: 16)

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.tabStops = [
            NSTextTab(textAlignment: .right, location: 240, options: [:])
        ]

        let titleAttr = NSMutableAttributedString(string: "\(group.name)\t", attributes: [
            .font: NSFont.menuFont(ofSize: 0),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle
        ])
        if !fullSelected.isEmpty {
            titleAttr.append(NSAttributedString(string: fullSelected, attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraphStyle
            ]))
        }
        item.attributedTitle = titleAttr
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
        let state = AsterState.shared
        let isAuto = (tag == "auto")
        let isSpecial = (tag == "direct" || tag == "reject" || tag == "block")
        let childGroup = isAuto ? nil : state.group(tagged: tag)

        let title: String
        var toolTip: String

        if isAuto {
            let winner = state.autoWinnerName()
            let cleanWinner = winner.flatMap { NodeNameSanitizer.clean($0) }
            if let cleanWinner, !cleanWinner.isEmpty {
                title = "自动优选 ➔ \(cleanWinner)"
            } else {
                title = "自动优选"
            }
            var tip = "自动测速并分流至最低延迟节点"
            if let cleanWinner {
                tip += " (当前命中: \(cleanWinner))"
            }
            toolTip = tip
        } else if let childGroup {
            let groupName = childGroup.name.isEmpty ? tag : childGroup.name
            title = NodeNameSanitizer.clean(groupName)
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
            title = NodeNameSanitizer.clean(rawTitle)
            toolTip = title
        }

        let isTesting = state.isNodeTesting(tag) || (isAuto && state.isTestingGroup(group)) || state.isTestingDelays
        let delay: Int = {
            if let childGroup {
                return childGroup.delayMs ?? state.memberDelay(for: tag)
            }
            return state.memberDelay(for: tag)
        }()

        let checked = state.isMemberSelected(group: group, tag: tag)
        let enabled = state.canSelectMember(group: group, tag: tag)

        item.title = title
        item.state = checked ? .on : .off
        item.isEnabled = enabled
        item.toolTip = toolTip

        if let view = item.view as? StickyMenuItemView {
            view.apply(
                title: title,
                checked: checked,
                enabled: enabled,
                delay: delay,
                isTesting: isTesting,
                isSpecialOutbound: isSpecial,
                toolTip: toolTip
            )
        }
    }

    private func makeStrategyMenu(group: StrategyGroup) -> NSMenu {
        let nodeMenu = NSMenu(title: group.name)
        nodeMenu.autoenablesItems = false

        // 1. 置顶延迟测试项 (纯文字无多余图标，右侧带 spinner，点击原地测速绝不关闭菜单)
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
                kind: .node(group: group.tag, tag: tag)
            ) { [weak self, weak item] in
                self?.selectStrategyMember(groupTag: group.tag, tag: tag)
                item?.menu?.cancelTracking()
            }
            item.view = view
            applyStrategyMemberItem(item, group: group, tag: tag)
            nodeMenu.addItem(item)
        }
        return nodeMenu
    }

    @objc func onFlushDNS() {
        AsterState.shared.flushDNSCache()
    }

    // MARK: - 菜单点击事件响应
    @objc func onOpenPreferences() {
        showMainWindow(tab: .settings)
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
        showMainWindow(tab: .control)
    }

    @objc func onOpenInspector() {
        showMainWindow(tab: .activity)
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

// MARK: - Aster 统一延迟指示实心圆角徽章 (Latency Pill)
@MainActor
public final class LatencyPillView: NSView {
    private let label = NSTextField(labelWithString: "")
    private var currentText: String = ""
    private var pillColor: NSColor = .clear

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        wantsLayer = true
        layer?.cornerRadius = 3.5
        layer?.masksToBounds = true

        label.font = NSFont.monospacedDigitSystemFont(ofSize: 10.0, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        label.lineBreakMode = .byClipping
        addSubview(label)
    }

    public override func layout() {
        super.layout()
        label.frame = bounds
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard !currentText.isEmpty, pillColor != .clear else { return }
        pillColor.setFill()
        let path = NSBezierPath(roundedRect: bounds, xRadius: 3.5, yRadius: 3.5)
        path.fill()
        super.draw(dirtyRect)
    }

    public func configure(delay: Int, isTesting: Bool) {
        currentText = LatencyFormatter.badgeText(delayMs: delay, isTesting: isTesting)
        pillColor = LatencyFormatter.nsColor(delayMs: delay, isTesting: isTesting)
        isHidden = false
        label.stringValue = currentText
        needsDisplay = true
    }
}

// MARK: - 策略组成员自定义菜单项视图 (对标 Surge 二级子菜单)
@MainActor
final class StickyMenuItemView: NSView {
    enum Kind {
        case node(group: String, tag: String)
        case custom
    }

    let kind: Kind
    private var onClick: () -> Void
    private var titleText: String = ""
    private var checked: Bool = false
    private var itemEnabled: Bool = true
    private var isHighlighted: Bool = false
    private var trackingArea: NSTrackingArea?

    private let checkView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let pillView = LatencyPillView(frame: NSRect(x: 0, y: 0, width: 52, height: 18))

    init(
        kind: Kind,
        onClick: @escaping () -> Void
    ) {
        self.kind = kind
        self.onClick = onClick
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
        autoresizingMask = [.width]
        wantsLayer = true
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        checkView.imageScaling = .scaleProportionallyUpOrDown
        checkView.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        addSubview(checkView)

        titleLabel.font = NSFont.menuFont(ofSize: 0)
        titleLabel.isEditable = false
        titleLabel.isBordered = false
        titleLabel.drawsBackground = false
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        addSubview(pillView)
    }

    override func layout() {
        super.layout()
        if let sv = superview, sv.bounds.width > 0 {
            frame.size.width = sv.bounds.width
        }
        let height = bounds.height

        // 左侧勾选列：x: 8, 宽高 12x12
        checkView.isHidden = !checked
        checkView.frame = NSRect(x: 8, y: (height - 12) / 2, width: 12, height: 12)

        // 右侧延迟胶囊：固定 52pt 宽度，右边距 10pt
        let pillW: CGFloat = 52
        let pillH: CGFloat = 18
        let pillX = bounds.width - pillW - 10
        pillView.frame = NSRect(x: pillX, y: (height - pillH) / 2, width: pillW, height: pillH)

        // 节点名称文字：严格从 x: 26 起始（勾选列右侧对齐），右侧避让胶囊徽章
        let titleX: CGFloat = 26
        let titleW = pillView.isHidden ? max(bounds.width - titleX - 14, 40) : max(pillX - titleX - 8, 40)
        titleLabel.frame = NSRect(x: titleX, y: (height - 18) / 2, width: titleW, height: 18)
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
        title: String,
        checked: Bool,
        enabled: Bool,
        delay: Int,
        isTesting: Bool,
        isSpecialOutbound: Bool,
        toolTip: String?
    ) {
        self.titleText = title
        self.checked = checked
        self.itemEnabled = enabled

        titleLabel.stringValue = title
        if let toolTip { self.toolTip = toolTip }

        if isSpecialOutbound {
            pillView.isHidden = true
        } else {
            pillView.isHidden = false
            pillView.configure(delay: delay, isTesting: isTesting)
        }

        updateHighlightColors()
        alphaValue = itemEnabled ? 1 : 0.4
        needsLayout = true
        needsDisplay = true
    }

    func apply(
        checked: Bool? = nil,
        enabled: Bool? = nil,
        toolTip: String? = nil
    ) {
        if let checked {
            self.checked = checked
            checkView.isHidden = !checked
        }
        if let enabled { self.itemEnabled = enabled }
        if let toolTip { self.toolTip = toolTip }
        updateHighlightColors()
        alphaValue = itemEnabled ? 1 : 0.4
        needsLayout = true
        needsDisplay = true
    }

    private func updateHighlightColors() {
        let textTint: NSColor = isHighlighted ? .selectedMenuItemTextColor : .labelColor
        titleLabel.textColor = textTint
        checkView.contentTintColor = textTint
    }

    override func mouseEntered(with event: NSEvent) {
        guard itemEnabled else { return }
        isHighlighted = true
        updateHighlightColors()
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHighlighted = false
        updateHighlightColors()
        needsDisplay = true
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

        titleLabel.font = NSFont.menuFont(ofSize: 0)
        titleLabel.textColor = .labelColor
        titleLabel.isEditable = false
        titleLabel.isBordered = false
        titleLabel.drawsBackground = false
        addSubview(titleLabel)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isHidden = true
        addSubview(spinner)

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
        titleLabel.frame = NSRect(x: 26, y: (height - 18) / 2, width: 120, height: 18)
        let spinnerSize: CGFloat = 14
        spinner.frame = NSRect(x: bounds.width - spinnerSize - 14, y: (height - spinnerSize) / 2, width: spinnerSize, height: spinnerSize)
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
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.15).setFill()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 4.5, yRadius: 4.5)
            path.fill()
        }
    }

    func update(isTesting: Bool) {
        self.isTesting = isTesting
        titleLabel.stringValue = isTesting ? "正在测速…" : "延迟测试"
        if isTesting {
            spinner.isHidden = false
            spinner.startAnimation(nil)
            titleLabel.textColor = .controlAccentColor
        } else {
            spinner.stopAnimation(nil)
            spinner.isHidden = true
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
