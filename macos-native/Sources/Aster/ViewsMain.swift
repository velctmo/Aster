import SwiftUI
import Charts
import AppKit

// MARK: - 主窗口专业侧边栏双态导航 (Aster 原生全功能拓扑)
public struct MainWindowView: View {
    @ObservedObject var state = AsterState.shared
    @State private var isCollapsed: Bool = false

    public init() {}

    public var body: some View {
        GeometryReader { proxy in
            let compactSidebar = proxy.size.width < 860
            ZStack {
                // 全局底层材质基座 (彻底消除红绿灯/顶栏等无视图区域完全透明穿透的 Bug)
                VisualEffectView(material: .sidebar, blendingMode: .behindWindow)
                    .ignoresSafeArea()

                HStack(spacing: 0) {
                    // 1. 左侧原生可折叠侧边栏
                    VStack(spacing: 0) {
                        // 顶部品牌微标与配置状态 (避开 macOS 红绿灯)
                        sidebarBrandHeader(collapsed: isCollapsed || compactSidebar)
                            .padding(.top, 48)
                            .padding(.bottom, 12)
                            .padding(.horizontal, (isCollapsed || compactSidebar) ? 8 : 12)

                        Divider().opacity(0.3)
                            .padding(.horizontal, (isCollapsed || compactSidebar) ? 8 : 12)
                            .padding(.bottom, 10)

                        // 导航选项卡列表 (分组展示)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 14) {
                                sidebarSection(title: "运行", tabs: [.control, .activity], collapsed: isCollapsed || compactSidebar)
                                sidebarSection(title: "分流", tabs: [.nodes, .rules], collapsed: isCollapsed || compactSidebar)
                                sidebarSection(title: "管理", tabs: [.configuration, .settings], collapsed: isCollapsed || compactSidebar)
                            }
                            .padding(.horizontal, (isCollapsed || compactSidebar) ? 8 : 12)
                            .padding(.top, 2)
                        }
                        .scrollIndicators(.hidden)

                        Spacer()

                        // 底部网络接管状态胶囊 (TUN / PROXY / STANDBY)
                        if !isCollapsed && !compactSidebar {
                            sidebarTakeoverPill
                                .padding(.horizontal, 12)
                                .padding(.bottom, 4)
                        }

                        Divider().opacity(0.3)
                            .padding(.horizontal, isCollapsed ? 8 : 12)
                            .padding(.vertical, 6)

                        // 底部折叠/展开控制按钮
                        Button(action: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                isCollapsed.toggle()
                            }
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: (isCollapsed || compactSidebar) ? "sidebar.right" : "sidebar.left")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.secondary)

                                if !isCollapsed && !compactSidebar {
                                    Text("收起侧边栏")
                                        .font(.system(size: 11.5))
                                        .foregroundColor(.secondary)
                                    Spacer()
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .padding(.horizontal, (isCollapsed || compactSidebar) ? 0 : 16)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help((isCollapsed || compactSidebar) ? "展开侧边栏" : "收起侧边栏")
                        .padding(.bottom, 8)
                    }
                    .frame(width: (isCollapsed || compactSidebar) ? DesignTokens.sidebarCollapsed : DesignTokens.sidebarExpanded)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(2)
                    .background(VisualEffectView(material: .sidebar, blendingMode: .behindWindow))
                    .ignoresSafeArea()

                    Divider().opacity(0.5)

                    // 2. 右侧主内容区域 (原生玻璃材质 + 通透液态磨砂)
                    ZStack {
                        VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
                            .ignoresSafeArea()

                        switch state.selectedTab {
                        case .control:
                            OverviewDashboardView()
                        case .activity:
                            ActivityDashboardView()
                        case .nodes:
                            OutboundsView()
                        case .rules:
                            RulesView()
                        case .configuration:
                            ProfilesView()
                        case .settings:
                            SettingsView()
                        }
                    }
                    .ignoresSafeArea()
                }
                .ignoresSafeArea()
            }
            .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private func sidebarBrandHeader(collapsed: Bool) -> some View {
        if collapsed {
            VStack(spacing: 6) {
                AsterBrandMark(size: 24)
                StatusBeaconDot(active: state.status.running, size: 4.5)
            }
            .frame(maxWidth: .infinity)
            .help("Aster · \(state.status.activeConfigName ?? "Default")")
        } else {
            HStack(spacing: 10) {
                AsterBrandMark(size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Aster")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .tracking(0.6)
                            .foregroundStyle(.primary)
                        StatusBeaconDot(active: state.status.running, size: 5)
                    }
                    let activeName = state.status.activeConfigName ?? "Default"
                    Text(activeName)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .nativeHairlineBorder(cornerRadius: 8, lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private var sidebarTakeoverPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(state.status.running ? (state.status.capture.tun ? Color.green : Color.blue) : Color.secondary.opacity(0.4))
                .frame(width: 5.5, height: 5.5)
            Text(state.status.capture.tun ? "TUN 模式" : (state.status.capture.systemProxy ? "系统代理" : (state.status.running ? "核心就绪" : "待命")))
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(.secondary)
            Spacer()
            Text(":\(state.status.mixedPort ?? 6780)")
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.7))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .nativeHairlineBorder(cornerRadius: 6, lineWidth: 0.4)
    }

    @ViewBuilder
    private func sidebarSection(title: String, tabs: [SidebarTab], collapsed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if !collapsed {
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.7))
                    .padding(.horizontal, 8)
                    .padding(.bottom, 2)
            }
            ForEach(tabs) { tab in
                SidebarTabButton(
                    tab: tab,
                    isSelected: state.selectedTab == tab,
                    isCollapsed: collapsed
                ) {
                    withAnimation(.easeInOut(duration: 0.14)) {
                        state.selectedTab = tab
                    }
                }
            }
        }
    }
}

// 侧边栏按钮组件 (展开显示 图标+文字+流体指示柱，折叠仅显示 图标+Tooltip)
public struct SidebarTabButton: View {
    public var tab: SidebarTab
    public var isSelected: Bool
    public var isCollapsed: Bool
    public var action: () -> Void

    @State private var isHovered = false

    public var body: some View {
        Button(action: action) {
            ZStack(alignment: .leading) {
                // 选中项流体纵向指示柱 (3pt continuous capsule)
                if isSelected && !isCollapsed {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 3, height: 16)
                        .padding(.leading, 1)
                }

                HStack(spacing: 10) {
                    Image(systemName: tab.icon)
                        .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                        .foregroundColor(isSelected ? Color.accentColor : (isHovered ? Color.primary : Color.primary.opacity(0.72)))
                        .frame(width: 20, height: 20)

                    if !isCollapsed {
                        Text(tab.rawValue)
                            .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                            .foregroundColor(isSelected ? Color.accentColor : (isHovered ? Color.primary : Color.primary.opacity(0.78)))
                        Spacer()
                    }
                }
                .padding(.leading, (isSelected && !isCollapsed) ? 10 : 8)
                .padding(.trailing, 8)
                .padding(.vertical, 7)
            }
            .frame(maxWidth: .infinity, alignment: isCollapsed ? .center : .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : (isHovered ? Color.primary.opacity(0.05) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.24) : Color.clear, lineWidth: 0.7)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isCollapsed ? tab.rawValue : "")
        .onHover { isHovered = $0 }
    }
}

// MARK: - 1. 主控制台「活动 (Activity)」Bento 仪表盘
