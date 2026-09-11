import SwiftUI
import AppKit

// MARK: - Design Tokens (整齐分区统一度量)
public enum DesignTokens {
    public static let pagePadding: CGFloat = 24
    public static let sectionGap: CGFloat = 20
    public static let cardRadius: CGFloat = 10
    public static let cardGap: CGFloat = 14
    public static let toolbarHeight: CGFloat = 64
    public static let sidebarExpanded: CGFloat = 208
    public static let sidebarCollapsed: CGFloat = 64
    public static let bentoCardHeight: CGFloat = 136
    /// Content-width breakpoints (window width minus sidebar).
    public static let breakThreeColumn: CGFloat = 860
    public static let breakTwoColumn: CGFloat = 560
}

public enum TrafficColors {
    // 克制、优雅、高质感的系统级网络指示色（低饱和莫兰迪调）
    public static let up = Color(red: 0.52, green: 0.46, blue: 0.76)   // 内敛浅紫
    public static let down = Color(red: 0.28, green: 0.58, blue: 0.74) // 典雅沉稳青蓝
    public static let subtle = Color.secondary.opacity(0.35)
}

// MARK: - Page Header (每页固定顶栏)
public struct PageHeader<Trailing: View>: View {
    public let title: String
    @ViewBuilder public var trailing: () -> Trailing

    public init(title: String, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.trailing = trailing
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.title2.bold())
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, DesignTokens.pagePadding)
        .frame(minHeight: DesignTokens.toolbarHeight)
        .padding(.vertical, 12)
    }
}

extension PageHeader where Trailing == EmptyView {
    public init(title: String) {
        self.init(title: title) { EmptyView() }
    }
}

// MARK: - Capture status pill (系统代理 / TUN)
public struct CaptureStatusPill: View {
    public let title: String
    public let active: Bool
    public let enabled: Bool
    public let disabledReason: String?
    public let action: () -> Void

    public init(title: String, active: Bool, enabled: Bool = true, disabledReason: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.active = active
        self.enabled = enabled
        self.disabledReason = disabledReason
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle()
                    .fill(active ? Color.green : Color.secondary.opacity(0.45))
                    .frame(width: 7, height: 7)
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(active ? .primary : .secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(active ? 0.06 : 0.04))
            .clipShape(.rect(cornerRadius: DesignTokens.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.cardRadius)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(disabledReason ?? "")
    }
}

// MARK: - 原生毛玻璃视窗组件 (NSVisualEffectView 桥接)
public struct VisualEffectView: NSViewRepresentable {
    public var material: NSVisualEffectView.Material
    public var blendingMode: NSVisualEffectView.BlendingMode
    public var state: NSVisualEffectView.State

    public init(
        material: NSVisualEffectView.Material = .sidebar,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
        state: NSVisualEffectView.State = .active
    ) {
        self.material = material
        self.blendingMode = blendingMode
        self.state = state
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        return view
    }

    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

// MARK: - Aster 品牌标（Dock 同款 icns，避免 SF Symbol 盾牌/旧星形残留）
public struct AsterBrandMark: View {
    public var size: CGFloat = 32

    public init(size: CGFloat = 32) {
        self.size = size
    }

    public var body: some View {
        Image(nsImage: Self.resolvedIcon)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    public static var resolvedIcon: NSImage {
        if let url = Bundle.main.url(forResource: "Aster", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSApp.applicationIconImage
    }
}

// MARK: - 本地原生应用图标提取器 (NSWorkspace)
public struct AppIconView: View {
    public var processPath: String
    public var processName: String
    public var size: CGFloat

    @State private var cachedImage: NSImage?

    public init(processPath: String, processName: String, size: CGFloat = 24) {
        self.processPath = processPath
        self.processName = processName
        self.size = size
    }

    public var body: some View {
        Group {
            if let image = cachedImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
                    .foregroundColor(.secondary)
            }
        }
        .onAppear {
            loadIcon()
        }
    }

    private func loadIcon() {
        self.cachedImage = AsterState.shared.iconForProcess(path: processPath, name: processName, size: size)
    }
}

// MARK: - 节点延迟气泡组件 (高敏彩色分级)
public struct LatencyBadge: View {
    public var delayMs: Int
    public var isTesting: Bool

    public init(delayMs: Int, isTesting: Bool = false) {
        self.delayMs = delayMs
        self.isTesting = isTesting
    }

    public var body: some View {
        HStack(spacing: 4) {
            if isTesting {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.65)
                    .frame(width: 12, height: 12)
                Text("测速中")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.blue)
            } else {
                Circle()
                    .fill(badgeColor)
                    .frame(width: 5.5, height: 5.5)
                Text(delayText)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(badgeColor)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(badgeColor.opacity(0.08))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .strokeBorder(badgeColor.opacity(0.22), lineWidth: 0.5)
        )
    }

    private var badgeColor: Color {
        if isTesting {
            return .blue
        } else if delayMs < 0 {
            return Color(red: 0.85, green: 0.38, blue: 0.38)
        } else if delayMs == 0 {
            return .secondary
        } else if delayMs <= 150 {
            return Color(red: 0.22, green: 0.72, blue: 0.48)
        } else if delayMs <= 500 {
            return Color(red: 0.88, green: 0.62, blue: 0.22)
        } else {
            return Color(red: 0.85, green: 0.38, blue: 0.38)
        }
    }

    private var delayText: String {
        if delayMs < 0 {
            return "超时"
        } else if delayMs == 0 {
            return "---"
        }
        return "\(delayMs)ms"
    }
}

// MARK: - 数据格式化工具
public enum Formatters {
    public static func speedString(_ bytesPerSec: Int64) -> String {
        if bytesPerSec < 1024 {
            return "\(bytesPerSec) B/s"
        } else if bytesPerSec < 1024 * 1024 {
            return "\((Double(bytesPerSec) / 1024).formatted(.number.precision(.fractionLength(1)))) KB/s"
        } else if bytesPerSec < 1024 * 1024 * 1024 {
            return "\((Double(bytesPerSec) / (1024 * 1024)).formatted(.number.precision(.fractionLength(1)))) MB/s"
        } else {
            return "\((Double(bytesPerSec) / (1024 * 1024 * 1024)).formatted(.number.precision(.fractionLength(2)))) GB/s"
        }
    }

    public static func bytesString(_ bytes: Int64) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            return "\((Double(bytes) / 1024).formatted(.number.precision(.fractionLength(1)))) KB"
        } else if bytes < 1024 * 1024 * 1024 {
            return "\((Double(bytes) / (1024 * 1024)).formatted(.number.precision(.fractionLength(2)))) MB"
        } else {
            return "\((Double(bytes) / (1024 * 1024 * 1024)).formatted(.number.precision(.fractionLength(2)))) GB"
        }
    }
}

// MARK: - 节点名称净化器 (自动剥离订阅源域名前缀，保留节点自带 Emoji 与国旗)
public enum NodeNameSanitizer {
    public static func clean(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for separator in [" · ", " • ", " - ", " | "] {
            if let sepRange = trimmed.range(of: separator) {
                let prefix = String(trimmed[..<sepRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                // 如果前缀为订阅源域名（包含 '.' 且无中文字符），剥离该前缀以呈现纯净节点名
                let containsCJK = prefix.contains { $0.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } }
                if prefix.contains(".") && !containsCJK {
                    trimmed = String(trimmed[sepRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
            }
        }
        return trimmed.isEmpty ? raw : trimmed
    }
}

/// 策略组展示与选择的单一规则：主界面和状态栏菜单必须走这里，避免两套逻辑再分叉。
public enum StrategyPresentation {
    public static func memberTitle(tag: String, node: ProxyNode?, autoWinner: String?) -> String {
        switch tag {
        case "direct":
            return "DIRECT"
        case "block", "reject":
            return "REJECT"
        case "auto":
            if let autoWinner, !autoWinner.isEmpty {
                return "♻️ 自动优选 ➔ \(clean(autoWinner))"
            }
            return "♻️ 自动优选"
        default:
            return clean(node?.name ?? tag)
        }
    }

    public static func selectedTag(in group: StrategyGroup, fallbackSelected: String) -> String {
        if let now = group.now, !now.isEmpty {
            return now
        }
        if group.tag == "proxy" || group.tag == fallbackSelected {
            return fallbackSelected
        }
        return ""
    }

    public static func selectedLabel(tag: String, node: ProxyNode?, autoWinner: String?) -> String {
        if tag.isEmpty { return "" }
        if tag == "auto" {
            if let autoWinner, !autoWinner.isEmpty {
                return "自动 ➔ \(clean(autoWinner))"
            }
            return "自动优选"
        }
        return memberTitle(tag: tag, node: node, autoWinner: autoWinner)
    }

    public static func canSelect(group: StrategyGroup, tag: String) -> Bool {
        group.type == "selector" && group.members.contains(tag)
    }

    public static func isSelected(group: StrategyGroup, tag: String, fallbackSelected: String) -> Bool {
        selectedTag(in: group, fallbackSelected: fallbackSelected) == tag
    }

    public static func canTest(tag: String) -> Bool {
        tag != "direct" && tag != "block" && tag != "reject" && tag != "dns"
    }

    public static func memberDelay(tag: String, node: ProxyNode?, autoDelay: Int, statusDelay: Int) -> Int {
        if tag == "auto" {
            return autoDelay > 0 ? autoDelay : statusDelay
        }
        return node?.delayMs ?? 0
    }

    private static func clean(_ raw: String) -> String {
        NodeNameSanitizer.clean(raw)
    }
}

// MARK: - macOS 26 液态玻璃 (Liquid Glass) 设计系统
public struct LiquidGlassBevelBorder: View {
    @Environment(\.colorScheme) private var colorScheme
    public var cornerRadius: CGFloat
    public var lineWidth: CGFloat

    public init(cornerRadius: CGFloat = 12, lineWidth: CGFloat = 0.8) {
        self.cornerRadius = cornerRadius
        self.lineWidth = lineWidth
    }

    public var body: some View {
        let gradient = LinearGradient(
            stops: [
                .init(color: colorScheme == .dark ? Color.white.opacity(0.24) : Color.white.opacity(0.55), location: 0.0),
                .init(color: colorScheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.18), location: 0.40),
                .init(color: colorScheme == .dark ? Color.black.opacity(0.25) : Color.black.opacity(0.06), location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )

        RoundedRectangle(cornerRadius: cornerRadius)
            .strokeBorder(gradient, lineWidth: lineWidth)
    }
}

public extension View {
    func liquidGlassBorder(cornerRadius: CGFloat = 12, lineWidth: CGFloat = 0.8) -> some View {
        self.overlay(
            LiquidGlassBevelBorder(cornerRadius: cornerRadius, lineWidth: lineWidth)
        )
    }
}

// 原生液态玻璃通用卡片容器
public struct LiquidGlassCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    public var cornerRadius: CGFloat
    public var content: () -> Content

    public init(cornerRadius: CGFloat = 12, @ViewBuilder content: @escaping () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content
    }

    public var body: some View {
        content()
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(.ultraThinMaterial)
            )
            .liquidGlassBorder(cornerRadius: cornerRadius)
            .shadow(
                color: colorScheme == .dark ? Color.black.opacity(0.22) : Color.black.opacity(0.04),
                radius: 8,
                x: 0,
                y: 3
            )
    }
}

// MARK: - 字符串视觉列宽智能截断 (CJK/全角占 2 列，Emoji/国旗占 2 列，ASCII/半角占 1 列)
extension String {
    public func truncated(toVisualWidth maxCols: Int) -> String {
        var currentCols = 0
        var result = ""
        for ch in self {
            let cols: Int
            let scalar = ch.unicodeScalars.first?.value ?? 0
            if (0x4E00...0x9FFF).contains(scalar) || (0x3400...0x4DBF).contains(scalar) || (0xFF01...0xFF60).contains(scalar) {
                cols = 2
            } else if ch.unicodeScalars.count > 1 || (0x1F300...0x1FAFF).contains(scalar) {
                cols = 2 // Emoji 或 国旗字符
            } else {
                cols = 1
            }
            if currentCols + cols > maxCols {
                return result.trimmingCharacters(in: .whitespaces) + "…"
            }
            result.append(ch)
            currentCols += cols
        }
        return self
    }
}

// MARK: - 策略动作胶囊 (全大写规范: PROXY, DIRECT, REJECT)
public struct ActionBadge: View {
    public var action: String

    public init(action: String) {
        self.action = action
    }

    public var body: some View {
        let (dotColor, text) = badgeMeta
        HStack(spacing: 5) {
            if let dot = dotColor {
                Circle()
                    .fill(dot)
                    .frame(width: 5, height: 5)
            }
            Text(text)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.88))
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.045))
        .clipShape(.rect(cornerRadius: 4.5))
        .overlay(
            RoundedRectangle(cornerRadius: 4.5)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6)
        )
        .help(tooltipText)
    }

    private var badgeMeta: (Color?, String) {
        let trimmed = action.trimmingCharacters(in: .whitespaces)
        switch trimmed.lowercased() {
        case "direct":
            return (Color(red: 0.22, green: 0.72, blue: 0.48), "DIRECT")
        case "reject":
            return (Color(red: 0.85, green: 0.38, blue: 0.38), "REJECT")
        case "proxy":
            return (Color.secondary.opacity(0.7), "PROXY")
        default:
            return (nil, trimmed.isEmpty ? "DIRECT" : trimmed)
        }
    }

    private var tooltipText: String {
        let trimmed = action.trimmingCharacters(in: .whitespaces)
        switch trimmed.lowercased() {
        case "direct": return "直连出站 (DIRECT)"
        case "reject": return "阻断连接 (REJECT)"
        case "proxy": return "分流至默认主代理策略组"
        default: return "分流至策略组「\(trimmed)」"
        }
    }
}

// MARK: - 精致按钮样式系统 (高质感液态玻璃微投影 + 连续平滑圆角)
public struct ExquisitePrimaryButtonStyle: ButtonStyle {
    public var height: CGFloat = 28
    public var cornerRadius: CGFloat = 7

    public init(height: CGFloat = 28, cornerRadius: CGFloat = 7) {
        self.height = height
        self.cornerRadius = cornerRadius
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 13)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.accentColor.opacity(configuration.isPressed ? 0.75 : 0.95))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.8)
            )
            .shadow(color: Color.accentColor.opacity(configuration.isPressed ? 0.08 : 0.22), radius: 4, x: 0, y: 2)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

public struct ExquisiteSecondaryButtonStyle: ButtonStyle {
    public var height: CGFloat = 28
    public var cornerRadius: CGFloat = 7

    public init(height: CGFloat = 28, cornerRadius: CGFloat = 7) {
        self.height = height
        self.cornerRadius = cornerRadius
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.primary)
            .padding(.horizontal, 12)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.1 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.8)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == ExquisitePrimaryButtonStyle {
    public static var exquisitePrimary: ExquisitePrimaryButtonStyle { ExquisitePrimaryButtonStyle() }
}

extension ButtonStyle where Self == ExquisiteSecondaryButtonStyle {
    public static var exquisiteSecondary: ExquisiteSecondaryButtonStyle { ExquisiteSecondaryButtonStyle() }
}
