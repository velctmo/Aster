import SwiftUI
import Charts
import AppKit

// MARK: - 主窗口专业侧边栏双态导航 (Aster 原生全功能拓扑)
public struct MainWindowView: View {
	@State private var selectedTab: SidebarTab = .control
	@State private var isCollapsed: Bool = false

    public enum SidebarTab: String, CaseIterable, Identifiable {
        case control = "控制台"
        case activity = "活动"
        case nodes = "节点"
        case rules = "规则"
        case configuration = "配置"
        case settings = "设置"

        public var id: String { rawValue }

        public var icon: String {
            switch self {
            case .control: return "slider.horizontal.3"
            case .activity: return "waveform.path.ecg"
            case .nodes: return "network"
            case .rules: return "arrow.triangle.branch"
            case .configuration: return "doc.badge.gearshape"
            case .settings: return "gearshape.fill"
            }
        }

        public var group: String {
            switch self {
            case .control, .activity: return "运行"
            case .nodes, .rules: return "分流"
            case .configuration, .settings: return "管理"
            }
        }
    }

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
                    // 导航选项卡列表 (分组展示)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            sidebarSection(title: "运行", tabs: [.control, .activity], collapsed: isCollapsed || compactSidebar)
                            sidebarSection(title: "分流", tabs: [.nodes, .rules], collapsed: isCollapsed || compactSidebar)
                            sidebarSection(title: "管理", tabs: [.configuration, .settings], collapsed: isCollapsed || compactSidebar)
                        }
                        .padding(.horizontal, (isCollapsed || compactSidebar) ? 8 : 12)
                        .padding(.top, 8)
                    }
                    .padding(.top, 52)
                    .scrollIndicators(.hidden)

                    Spacer()

                    Divider().opacity(0.4)
                        .padding(.horizontal, isCollapsed ? 8 : 12)
                        .padding(.vertical, 6)

                    // 底部折叠/展开控制按钮
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            isCollapsed.toggle()
                        }
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: (isCollapsed || compactSidebar) ? "sidebar.right" : "sidebar.left")
                                .font(.system(size: 13))
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

                    switch selectedTab {
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
    private func sidebarSection(title: String, tabs: [SidebarTab], collapsed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if !collapsed {
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.8))
                    .padding(.horizontal, 8)
                    .padding(.bottom, 2)
            }
            ForEach(tabs) { tab in
                SidebarTabButton(
                    tab: tab,
                    isSelected: selectedTab == tab,
                    isCollapsed: collapsed
                ) {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        selectedTab = tab
                    }
                }
            }
        }
    }
}


// 侧边栏按钮组件 (展开显示 图标+文字，折叠仅显示 图标+Tooltip)
public struct SidebarTabButton: View {
    public var tab: MainWindowView.SidebarTab
    public var isSelected: Bool
    public var isCollapsed: Bool
    public var action: () -> Void

    @State private var isHovered = false

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: tab.icon)
                    .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? Color.accentColor : (isHovered ? Color.primary : Color.primary.opacity(0.72)))
                    .frame(width: 20, height: 20)

                if !isCollapsed {
                    Text(tab.rawValue)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                        .foregroundColor(isSelected ? Color.accentColor : (isHovered ? Color.primary : Color.primary.opacity(0.78)))
                    Spacer()
                }
            }
            .padding(.horizontal, isCollapsed ? 14 : 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: isCollapsed ? .center : .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.14) : (isHovered ? Color.primary.opacity(0.06) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.28) : Color.clear, lineWidth: 0.8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isCollapsed ? tab.rawValue : "")
        .onHover { isHovered = $0 }
    }
}

// MARK: - 1. 主控制台「活动 (Activity)」Bento 仪表盘
