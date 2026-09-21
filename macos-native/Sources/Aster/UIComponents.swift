import SwiftUI
import AppKit
import Foundation
import Darwin

// MARK: - AsterMetrics (工业级 8pt 度量系统)
public enum AsterMetrics {
    // 间距节律 (8pt 网格)
    public static let spacingMicro: CGFloat = 4
    public static let spacingTight: CGFloat = 8
    public static let spacingStandard: CGFloat = 12
    public static let spacingRelaxed: CGFloat = 16
    public static let spacingSection: CGFloat = 24

    // 连续曲率圆角 (Continuous Curves)
    public static let radiusBadge: CGFloat = 4.5
    public static let radiusControl: CGFloat = 6.0
    public static let radiusCard: CGFloat = 12.0
    public static let radiusSheet: CGFloat = 12.0

    // 状态栏菜单对齐槽位
    public static let menuIconColumnWidth: CGFloat = 18.0
    public static let menuTextIndent: CGFloat = 26.0
    public static let menuAccessoryWidth: CGFloat = 64.0
}

// MARK: - Design Tokens (整齐分区统一度量)
public enum DesignTokens {
    public static let pagePadding: CGFloat = 24
    public static let sectionGap: CGFloat = 20
    public static let cardRadius: CGFloat = 12
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

extension AppMode {
    public var color: Color {
        switch self {
        case .rule: return Color(red: 0.22, green: 0.72, blue: 0.48)
        case .global: return .blue
        case .direct: return Color(red: 0.88, green: 0.62, blue: 0.22)
        }
    }

    public var nsColor: NSColor {
        switch self {
        case .rule: return NSColor(srgbRed: 0.22, green: 0.72, blue: 0.48, alpha: 1.0)
        case .global: return NSColor(srgbRed: 0.0, green: 0.48, blue: 1.0, alpha: 1.0)
        case .direct: return NSColor(srgbRed: 0.88, green: 0.62, blue: 0.22, alpha: 1.0)
        }
    }
}

// MARK: - 统一延迟格式化与高敏色阶系统 (LatencyFormatter)
public enum LatencyFormatter {
    public static func text(delayMs: Int, isTesting: Bool = false) -> String {
        if isTesting { return "测速中…" }
        if delayMs < 0 { return "超时" }
        if delayMs == 0 { return "---" }
        return "\(delayMs) ms"
    }

    public static func badgeText(delayMs: Int, isTesting: Bool = false) -> String {
        if isTesting { return "测速中" }
        if delayMs < 0 { return "超时" }
        if delayMs == 0 { return "---" }
        return "\(delayMs) ms"
    }

    public static func shortText(delayMs: Int, isTesting: Bool = false) -> String {
        if isTesting { return "测速中" }
        if delayMs < 0 { return "超时" }
        if delayMs == 0 { return "--" }
        return "\(delayMs)"
    }

    public static func color(delayMs: Int, isTesting: Bool = false) -> Color {
        switch LatencyGrade.grade(delayMs: delayMs, isTesting: isTesting) {
        case .testing:
            return .blue
        case .timeout:
            return Color(red: 0.85, green: 0.38, blue: 0.38)
        case .untested:
            return .secondary
        case .fast:
            return Color(red: 0.22, green: 0.72, blue: 0.48)
        case .medium:
            return Color(red: 0.88, green: 0.62, blue: 0.22)
        case .slow:
            return Color(red: 0.85, green: 0.38, blue: 0.38)
        }
    }

    public static func nsColor(delayMs: Int, isTesting: Bool = false) -> NSColor {
        switch LatencyGrade.grade(delayMs: delayMs, isTesting: isTesting) {
        case .testing:
            return .systemBlue
        case .timeout:
            return NSColor(srgbRed: 0.85, green: 0.38, blue: 0.38, alpha: 1.0)
        case .untested:
            return .secondaryLabelColor
        case .fast:
            return NSColor(srgbRed: 0.22, green: 0.72, blue: 0.48, alpha: 1.0)
        case .medium:
            return NSColor(srgbRed: 0.88, green: 0.62, blue: 0.22, alpha: 1.0)
        case .slow:
            return NSColor(srgbRed: 0.85, green: 0.38, blue: 0.38, alpha: 1.0)
        }
    }
}

// MARK: - 系统剪贴板通用工具 (带触觉反馈)
public enum ClipboardHelper {
    public static func copy(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
    }
}

// MARK: - 工业级搜索框输入组件 (ExquisiteSearchField)
public struct ExquisiteSearchField: View {
    public var placeholder: String
    @Binding public var text: String
    public var maxWidth: CGFloat? = nil

    public init(placeholder: String = "搜索…", text: Binding<String>, maxWidth: CGFloat? = nil) {
        self.placeholder = placeholder
        self._text = text
        self.maxWidth = maxWidth
    }

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空搜索内容")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: AsterMetrics.radiusControl, style: .continuous))
        .nativeHairlineBorder(cornerRadius: AsterMetrics.radiusControl, lineWidth: 0.6)
        .frame(maxWidth: maxWidth)
    }
}

// MARK: - 全局出站分流模式控制器组件 (ModeSegmentedControl)
public struct ModeSegmentedControl: View {
    @Binding public var selectedMode: String
    public var onSelect: ((AppMode) -> Void)? = nil

    public init(selectedMode: Binding<String>, onSelect: ((AppMode) -> Void)? = nil) {
        self._selectedMode = selectedMode
        self.onSelect = onSelect
    }

    public var body: some View {
        HStack(spacing: 3) {
            ForEach(AppMode.allCases) { mode in
                let isSelected = selectedMode == mode.rawValue
                Button {
                    selectedMode = mode.rawValue
                    onSelect?(mode)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: mode.icon)
                            .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                        Text(mode.title)
                            .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                        Text(mode.code)
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(isSelected ? mode.color : Color.secondary.opacity(0.7))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4.5)
                    .background(
                        isSelected ?
                            RoundedRectangle(cornerRadius: AsterMetrics.radiusControl, style: .continuous)
                                .fill(Color(NSColor.controlBackgroundColor))
                                .shadow(color: Color.black.opacity(0.06), radius: 2, x: 0, y: 1)
                            : nil
                    )
                    .overlay(
                        isSelected ?
                            RoundedRectangle(cornerRadius: AsterMetrics.radiusControl, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6)
                            : nil
                    )
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: AsterMetrics.radiusControl + 2, style: .continuous))
        .nativeHairlineBorder(cornerRadius: AsterMetrics.radiusControl + 2, lineWidth: 0.6)
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
                    .frame(width: 10, height: 10)
                Text(LatencyFormatter.badgeText(delayMs: delayMs, isTesting: true))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.blue)
            } else {
                Circle()
                    .fill(badgeColor)
                    .frame(width: 5.5, height: 5.5)
                Text(LatencyFormatter.badgeText(delayMs: delayMs, isTesting: false))
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
        LatencyFormatter.color(delayMs: delayMs, isTesting: isTesting)
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
                return "自动优选 ➔ \(clean(autoWinner))"
            }
            return "自动优选"
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

// MARK: - 原生微边框 (Native Hairline Border) 设计系统
public struct NativeHairlineBorder: ViewModifier, View {
    @Environment(\.colorScheme) private var colorScheme
    var cornerRadius: CGFloat
    var lineWidth: CGFloat

    public init(cornerRadius: CGFloat = AsterMetrics.radiusCard, lineWidth: CGFloat = 0.5) {
        self.cornerRadius = cornerRadius
        self.lineWidth = lineWidth
    }

    public func body(content: Content) -> some View {
        content.overlay(
            body
        )
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(
                colorScheme == .dark
                    ? Color.white.opacity(0.12)
                    : Color.black.opacity(0.08),
                lineWidth: lineWidth
            )
    }
}

public struct LiquidGlassBevelBorder: View {
    @Environment(\.colorScheme) private var colorScheme
    public var cornerRadius: CGFloat
    public var lineWidth: CGFloat

    public init(cornerRadius: CGFloat = AsterMetrics.radiusCard, lineWidth: CGFloat = 0.5) {
        self.cornerRadius = cornerRadius
        self.lineWidth = lineWidth
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(
                colorScheme == .dark
                    ? Color.white.opacity(0.12)
                    : Color.black.opacity(0.08),
                lineWidth: lineWidth
            )
    }
}

public extension View {
    func nativeHairlineBorder(cornerRadius: CGFloat = AsterMetrics.radiusCard, lineWidth: CGFloat = 0.5) -> some View {
        self.modifier(NativeHairlineBorder(cornerRadius: cornerRadius, lineWidth: lineWidth))
    }

    func liquidGlassBorder(cornerRadius: CGFloat = AsterMetrics.radiusCard, lineWidth: CGFloat = 0.5) -> some View {
        self.nativeHairlineBorder(cornerRadius: cornerRadius, lineWidth: lineWidth)
    }
}

// 原生液态玻璃通用卡片容器 (升级为 NativeHairlineBorder，去除粗暴投影)
public struct LiquidGlassCard<Content: View>: View {
    public var cornerRadius: CGFloat
    public var content: () -> Content

    public init(cornerRadius: CGFloat = AsterMetrics.radiusCard, @ViewBuilder content: @escaping () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content
    }

    public var body: some View {
        content()
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .nativeHairlineBorder(cornerRadius: cornerRadius)
    }
}

// MARK: - 典雅曜石流光玻璃卡片容器 (ElevatedGlassCard)
public struct ElevatedGlassCard<Content: View>: View {
    public var cornerRadius: CGFloat
    public var content: () -> Content
    @Environment(\.colorScheme) private var colorScheme

    public init(cornerRadius: CGFloat = AsterMetrics.radiusCard, @ViewBuilder content: @escaping () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content
    }

    public var body: some View {
        content()
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        colorScheme == .dark
                            ? Color.white.opacity(0.12)
                            : Color.black.opacity(0.07),
                        lineWidth: 0.6
                    )
            )
            .shadow(
                color: colorScheme == .dark
                    ? Color.black.opacity(0.28)
                    : Color.black.opacity(0.04),
                radius: 8,
                x: 0,
                y: 2
            )
    }
}

public struct ElevatedGlassCardModifier: ViewModifier {
    public var cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    public init(cornerRadius: CGFloat = AsterMetrics.radiusCard) {
        self.cornerRadius = cornerRadius
    }

    public func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        colorScheme == .dark
                            ? Color.white.opacity(0.12)
                            : Color.black.opacity(0.07),
                        lineWidth: 0.6
                    )
            )
            .shadow(
                color: colorScheme == .dark
                    ? Color.black.opacity(0.28)
                    : Color.black.opacity(0.04),
                radius: 8,
                x: 0,
                y: 2
            )
    }
}

public extension View {
    func elevatedGlassCard(cornerRadius: CGFloat = AsterMetrics.radiusCard) -> some View {
        self.modifier(ElevatedGlassCardModifier(cornerRadius: cornerRadius))
    }
}

// MARK: - 实时运行状态信标指示点 (带呼吸微光脉冲)
public struct StatusBeaconDot: View {
    public var active: Bool
    public var color: Color
    public var size: CGFloat
    @State private var isPulsing: Bool = false

    public init(active: Bool, color: Color = Color(red: 0.20, green: 0.78, blue: 0.45), size: CGFloat = 8) {
        self.active = active
        self.color = color
        self.size = size
    }

    public var body: some View {
        ZStack {
            if active {
                Circle()
                    .fill(color.opacity(isPulsing ? 0.15 : 0.38))
                    .frame(width: size * 2.2, height: size * 2.2)
                    .scaleEffect(isPulsing ? 1.25 : 0.85)
                    .animation(
                        Animation.easeInOut(duration: 1.8)
                            .repeatForever(autoreverses: true),
                        value: isPulsing
                    )
            }
            Circle()
                .fill(active ? color : Color.secondary.opacity(0.4))
                .frame(width: size, height: size)
                .shadow(color: active ? color.opacity(0.5) : Color.clear, radius: 2)
        }
        .frame(width: size * 2.2, height: size * 2.2)
        .onAppear {
            if active { isPulsing = true }
        }
        .onChange(of: active) { _, newValue in
            isPulsing = newValue
        }
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
            return (Color(red: 0.25, green: 0.55, blue: 0.95), "PROXY")
        default:
            return (Color.accentColor.opacity(0.85), trimmed.isEmpty ? "DIRECT" : trimmed)
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

// MARK: - 协议专属色彩微标组件
public struct ProtocolBadge: View {
    public var proto: String
    public var isSelected: Bool

    public init(proto: String, isSelected: Bool = false) {
        self.proto = proto
        self.isSelected = isSelected
    }

    public var body: some View {
        let (color, text) = protocolMeta(proto)
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(isSelected ? color.opacity(0.20) : color.opacity(0.10))
            .foregroundStyle(isSelected ? color : color.opacity(0.95))
            .clipShape(.rect(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(isSelected ? color.opacity(0.40) : color.opacity(0.18), lineWidth: 0.5)
            )
    }

    public static func protocolColor(_ proto: String) -> Color {
        let p = proto.trimmingCharacters(in: .whitespaces).lowercased()
        switch p {
        case "wireguard", "wg":
            return Color.indigo
        case "hysteria2", "hysteria", "hy2":
            return Color.orange
        case "tuic":
            return Color.teal
        case "shadowtls", "shadow-tls":
            return Color.purple
        case "vless", "vmess":
            return Color.blue
        case "trojan":
            return Color(red: 0.88, green: 0.35, blue: 0.35)
        case "shadowsocks", "ss":
            return Color(red: 0.22, green: 0.72, blue: 0.48)
        default:
            return Color.secondary
        }
    }

    private func protocolMeta(_ proto: String) -> (Color, String) {
        let trimmed = proto.trimmingCharacters(in: .whitespaces)
        let color = Self.protocolColor(trimmed)
        let text = trimmed.uppercased()
        return (color, text.isEmpty ? "PROXY" : text)
    }
}

// MARK: - 精致按钮样式系统 (高质感原生控件 + 连续平滑圆角，无发光彩色阴影)
public struct ExquisitePrimaryButtonStyle: ButtonStyle {
    public var height: CGFloat
    public var cornerRadius: CGFloat

    public init(height: CGFloat = 26, cornerRadius: CGFloat = AsterMetrics.radiusControl) {
        self.height = height
        self.cornerRadius = cornerRadius
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.accentColor.opacity(configuration.isPressed ? 0.82 : 1.0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
            )
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

public struct ExquisiteSecondaryButtonStyle: ButtonStyle {
    public var height: CGFloat
    public var cornerRadius: CGFloat

    public init(height: CGFloat = 26, cornerRadius: CGFloat = AsterMetrics.radiusControl) {
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
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.06))
            )
            .nativeHairlineBorder(cornerRadius: cornerRadius, lineWidth: 0.5)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

public struct ExquisiteDestructiveButtonStyle: ButtonStyle {
    public var height: CGFloat
    public var cornerRadius: CGFloat

    public init(height: CGFloat = 26, cornerRadius: CGFloat = AsterMetrics.radiusControl) {
        self.height = height
        self.cornerRadius = cornerRadius
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(Color(red: 0.90, green: 0.35, blue: 0.35))
            .padding(.horizontal, 12)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(red: 0.90, green: 0.35, blue: 0.35).opacity(configuration.isPressed ? 0.16 : 0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color(red: 0.90, green: 0.35, blue: 0.35).opacity(0.25), lineWidth: 0.5)
            )
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

public struct ExquisitePillButtonStyle: ButtonStyle {
    public var height: CGFloat

    public init(height: CGFloat = 22) {
        self.height = height
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10.5, weight: .medium))
            .foregroundColor(.primary.opacity(0.85))
            .padding(.horizontal, 8)
            .frame(height: height)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.10 : 0.05))
            )
            .overlay(
                Capsule()
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            )
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == ExquisitePrimaryButtonStyle {
    public static var exquisitePrimary: ExquisitePrimaryButtonStyle { ExquisitePrimaryButtonStyle() }
    public static func exquisitePrimary(height: CGFloat = 26, cornerRadius: CGFloat = AsterMetrics.radiusControl) -> ExquisitePrimaryButtonStyle {
        ExquisitePrimaryButtonStyle(height: height, cornerRadius: cornerRadius)
    }
}

extension ButtonStyle where Self == ExquisiteSecondaryButtonStyle {
    public static var exquisiteSecondary: ExquisiteSecondaryButtonStyle { ExquisiteSecondaryButtonStyle() }
    public static func exquisiteSecondary(height: CGFloat = 26, cornerRadius: CGFloat = AsterMetrics.radiusControl) -> ExquisiteSecondaryButtonStyle {
        ExquisiteSecondaryButtonStyle(height: height, cornerRadius: cornerRadius)
    }
}

extension ButtonStyle where Self == ExquisiteDestructiveButtonStyle {
    public static var exquisiteDestructive: ExquisiteDestructiveButtonStyle { ExquisiteDestructiveButtonStyle() }
    public static func exquisiteDestructive(height: CGFloat = 26, cornerRadius: CGFloat = AsterMetrics.radiusControl) -> ExquisiteDestructiveButtonStyle {
        ExquisiteDestructiveButtonStyle(height: height, cornerRadius: cornerRadius)
    }
}

extension ButtonStyle where Self == ExquisitePillButtonStyle {
    public static var exquisitePill: ExquisitePillButtonStyle { ExquisitePillButtonStyle() }
    public static func exquisitePill(height: CGFloat = 22) -> ExquisitePillButtonStyle {
        ExquisitePillButtonStyle(height: height)
    }
}

// MARK: - 3. 全景分流链路追踪视图
public struct RuleTracePipelineView: View {
    public var conn: ConnectionItem

    public init(conn: ConnectionItem) {
        self.conn = conn
    }

    private var themeColor: Color {
        if conn.isReject || conn.diagnostics?.isFailed == true || conn.diagnostics?.closeReason == "rejected" {
            return Color(red: 0.85, green: 0.38, blue: 0.38) // Reject 警示红
        } else if conn.isDirect {
            return Color(red: 0.22, green: 0.72, blue: 0.48) // Direct 柔绿
        } else {
            return Color(red: 0.28, green: 0.58, blue: 0.74) // Proxy 科技蓝
        }
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .center, spacing: 6) {
                // 1. 应用进程
                stageCard(
                    stageNumber: "1",
                    stageName: "应用进程",
                    mainContent: conn.effectiveProcess,
                    subContent: nil,
                    icon: AnyView(
                        AppIconView(
                            processPath: conn.metadata?.processPath ?? "",
                            processName: conn.effectiveProcess,
                            size: 14
                        )
                    )
                )

                arrowDivider

                // 2. DNS 与寻址
                dnsStageCard

                arrowDivider

                // 3. 分流规则
                ruleStageCard

                arrowDivider

                // 4. 出站决策
                outboundStageCard

                arrowDivider

                // 5. 终态状态
                statusStageCard
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 2)
        }
    }

    private var arrowDivider: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(themeColor.opacity(0.45))
    }

    private func stageCard(
        stageNumber: String,
        stageName: String,
        mainContent: String,
        subContent: String? = nil,
        icon: AnyView? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                Text(stageNumber)
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(themeColor)
                Text(stageName)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                if let icon {
                    icon
                }
                Text(mainContent.isEmpty ? "—" : mainContent)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            if let subContent, !subContent.isEmpty {
                Text(subContent)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(themeColor.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(themeColor.opacity(0.18), lineWidth: 0.5)
        )
    }

    private var isPureIPAddress: Bool {
        let host = conn.metadata?.host ?? ""
        if host.isEmpty { return true }
        if host.contains(":") { return true }
        let parts = host.split(separator: ".")
        if parts.count == 4 && parts.allSatisfy({ sub in
            if let val = Int(sub), (0...255).contains(val) { return true }
            return false
        }) {
            return true
        }
        return false
    }

    private var dnsStageCard: some View {
        let host = conn.metadata?.host ?? ""
        let destIP = conn.metadata?.destinationIP ?? ""

        if !isPureIPAddress {
            return stageCard(
                stageNumber: "2",
                stageName: "DNS 与寻址",
                mainContent: "DNS 解析",
                subContent: destIP.isEmpty ? host : destIP
            )
        } else {
            return stageCard(
                stageNumber: "2",
                stageName: "DNS 与寻址",
                mainContent: "目标直寻",
                subContent: destIP.isEmpty ? (host.isEmpty ? "直接寻址" : host) : destIP
            )
        }
    }

    private var ruleStageCard: some View {
        let ruleType = (conn.rule?.trimmingCharacters(in: .whitespaces).uppercased()).flatMap { $0.isEmpty ? nil : $0 } ?? "MATCH"
        let payload = (conn.rulePayload?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? "—"
        return stageCard(
            stageNumber: "3",
            stageName: "分流规则",
            mainContent: ruleType,
            subContent: payload
        )
    }

    private var outboundStageCard: some View {
        let (action, node) = resolvedOutboundAndNode
        return stageCard(
            stageNumber: "4",
            stageName: "出站决策",
            mainContent: action,
            subContent: node
        )
    }

    private var resolvedOutboundAndNode: (String, String?) {
        if conn.isReject {
            return ("REJECT", "阻断")
        }
        if conn.isDirect {
            return ("DIRECT", "直连出站")
        }
        if let chains = conn.chains, !chains.isEmpty {
            let group = chains.first ?? "Proxy"
            let landing = chains.count > 1 ? chains.last : nil
            return (group, landing)
        }
        return ("Proxy", nil)
    }

    private var statusStageCard: some View {
        let statusText: String
        let subText: String?
        if conn.diagnostics?.isFailed == true || conn.diagnostics?.closeReason == "rejected" || conn.diagnostics?.closeReason == "timeout" || conn.diagnostics?.closeReason == "dns_failed" {
            statusText = "异常终止"
            subText = conn.diagnostics?.closeReason ?? "失败"
        } else if conn.isClosed == true || conn.diagnostics?.closeReason == "completed" {
            statusText = "正常结束"
            if let ms = conn.diagnostics?.durationMs {
                subText = ms < 1000 ? "\(ms)ms" : String(format: "%.1fs", Double(ms) / 1000.0)
            } else {
                subText = nil
            }
        } else {
            statusText = "活跃传输"
            if let speedIn = conn.diagnostics?.speedIn, speedIn > 0 {
                subText = "↓ \(Formatters.bytesString(speedIn))/s"
            } else {
                subText = nil
            }
        }

        return stageCard(
            stageNumber: "5",
            stageName: "终态状态",
            mainContent: statusText,
            subContent: subText
        )
    }
}

// MARK: - 4. 状态微光与异常诊断徽标
public struct ConnectionDiagnosticBadge: View {
    public var conn: ConnectionItem

    public init(conn: ConnectionItem) {
        self.conn = conn
    }

    private var durationText: String {
        if let ms = conn.diagnostics?.durationMs {
            if ms < 1000 {
                return "\(ms)ms"
            } else {
                return String(format: "%.1fs", Double(ms) / 1000.0)
            }
        }
        return "完成"
    }

    public var body: some View {
        Group {
            if conn.diagnostics?.closeReason == "rejected" || conn.isReject {
                badgeLayout(
                    icon: "nosign",
                    text: "阻断",
                    textColor: Color(red: 0.88, green: 0.35, blue: 0.35),
                    bgColor: Color(red: 0.88, green: 0.35, blue: 0.35).opacity(0.12),
                    borderColor: Color(red: 0.88, green: 0.35, blue: 0.35).opacity(0.30)
                )
            } else if conn.diagnostics?.closeReason == "timeout" {
                badgeLayout(
                    icon: "clock",
                    text: "超时",
                    textColor: Color.orange,
                    bgColor: Color.orange.opacity(0.12),
                    borderColor: Color.orange.opacity(0.30)
                )
            } else if conn.diagnostics?.closeReason == "dns_failed" {
                badgeLayout(
                    icon: "exclamationmark.triangle",
                    text: "DNS 异常",
                    textColor: Color(red: 0.65, green: 0.40, blue: 0.85),
                    bgColor: Color(red: 0.65, green: 0.40, blue: 0.85).opacity(0.12),
                    borderColor: Color(red: 0.65, green: 0.40, blue: 0.85).opacity(0.30)
                )
            } else if conn.isClosed == true || conn.diagnostics?.closeReason == "completed" {
                badgeLayout(
                    icon: "checkmark",
                    text: durationText,
                    textColor: Color.secondary,
                    bgColor: Color.secondary.opacity(0.10),
                    borderColor: Color.secondary.opacity(0.22)
                )
            } else {
                activeBadge
            }
        }
    }

    private func badgeLayout(icon: String? = nil, text: String, textColor: Color, bgColor: Color, borderColor: Color) -> some View {
        HStack(spacing: 3.5) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 8.5, weight: .bold))
            }
            Text(text)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
        }
        .foregroundStyle(textColor)
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(bgColor)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .strokeBorder(borderColor, lineWidth: 0.5)
        )
    }

    private var activeBadge: some View {
        HStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.25))
                    .frame(width: 8, height: 8)
                Circle()
                    .fill(Color.green)
                    .frame(width: 5, height: 5)
            }
            if let speedIn = conn.diagnostics?.speedIn, speedIn > 0 {
                Text("↓ \(Formatters.bytesString(speedIn))/s")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.green)
            } else {
                Text("活跃")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.green)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(Color.green.opacity(0.09))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color.green.opacity(0.25), lineWidth: 0.5)
        )
    }
}

// MARK: - 5. 标准化连接属性审查抽屉
public struct ConnectionDetailDrawer: View {
    public var conn: ConnectionItem
    public var onClose: () -> Void

    public init(conn: ConnectionItem, onClose: @escaping () -> Void) {
        self.conn = conn
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 顶栏：标题「连接属性审查」、目标域名、关闭按钮
            headerView

            Divider()
                .opacity(0.5)

            // 主体分 5 个卡片分区
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 12) {
                    // 1. 发起端信息
                    initiatorCard

                    // 2. 目标网络
                    destinationCard

                    // 3. 全景分流链路
                    pipelineCard

                    // 4. 时序与吞吐
                    timingCard

                    // 5. 快捷分流动作
                    quickActionsCard
                }
                .padding(14)
            }
        }
        .frame(width: 340)
        .background(.ultraThinMaterial)
        .overlay(
            Rectangle()
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    private var headerView: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("连接属性审查")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.primary)
                Text(conn.metadata?.host ?? conn.effectiveTarget)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("关闭审查抽屉")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // 1. 发起端信息
    private var initiatorCard: some View {
        DrawerCard(title: "发起端信息", icon: "app.dashed") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    AppIconView(
                        processPath: conn.metadata?.processPath ?? "",
                        processName: conn.effectiveProcess,
                        size: 22
                    )
                    Text(conn.effectiveProcess)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                DrawerInfoRow(
                    label: "二进制路径",
                    value: conn.metadata?.processPath ?? "—",
                    isMonospaced: true,
                    copyable: true
                )
                let srcIP = conn.metadata?.sourceIP?.trimmingCharacters(in: .whitespaces) ?? ""
                DrawerInfoRow(
                    label: "来源 IP",
                    value: srcIP.isEmpty ? "本机" : (srcIP == "127.0.0.1" ? "本机 (127.0.0.1)" : srcIP),
                    isMonospaced: true
                )
            }
        }
    }

    // 2. 目标网络
    private var destinationCard: some View {
        DrawerCard(title: "目标网络", icon: "network") {
            VStack(alignment: .leading, spacing: 6) {
                let host = conn.metadata?.host ?? conn.effectiveTarget
                DrawerInfoRow(label: "目标主机", value: host, isMonospaced: true, copyable: true)
                DrawerInfoRow(label: "目标 IP", value: conn.metadata?.destinationIP ?? "—", isMonospaced: true)
                DrawerInfoRow(label: "端口", value: conn.metadata?.destinationPort ?? "—", isMonospaced: true)
                DrawerInfoRow(label: "网络协议", value: (conn.metadata?.network ?? "tcp").uppercased(), isMonospaced: true)
            }
        }
    }

    // 3. 全景分流链路
    private var pipelineCard: some View {
        DrawerCard(title: "全景分流链路", icon: "arrow.triangle.branch") {
            RuleTracePipelineView(conn: conn)
        }
    }

    // 4. 时序与吞吐
    private var timingCard: some View {
        DrawerCard(title: "时序与吞吐", icon: "gauge.with.needle") {
            VStack(alignment: .leading, spacing: 6) {
                DrawerInfoRow(label: "开始时间", value: formatStartTime(conn.start), isMonospaced: true)
                DrawerInfoRow(label: "持续时间", value: formatDuration(conn.diagnostics?.durationMs), isMonospaced: true)
                DrawerInfoRow(
                    label: "瞬时下行",
                    value: conn.diagnostics?.speedIn.map { "\(Formatters.bytesString($0))/s" } ?? "0 B/s",
                    isMonospaced: true
                )
                DrawerInfoRow(
                    label: "瞬时上行",
                    value: conn.diagnostics?.speedOut.map { "\(Formatters.bytesString($0))/s" } ?? "0 B/s",
                    isMonospaced: true
                )
                DrawerInfoRow(label: "累计下行", value: Formatters.bytesString(conn.download), isMonospaced: true)
                DrawerInfoRow(label: "累计上行", value: Formatters.bytesString(conn.upload), isMonospaced: true)
                DrawerInfoRow(label: "关闭原因", value: formatCloseReason)
            }
        }
    }

    // 5. 快捷分流动作
    private var quickActionsCard: some View {
        DrawerCard(title: "快捷分流动作", icon: "bolt.fill") {
            VStack(spacing: 8) {
                Button {
                    let host = conn.metadata?.host ?? conn.effectiveTarget
                    ClipboardHelper.copy(host)
                } label: {
                    HStack {
                        Image(systemName: "doc.on.doc")
                        Text("复制目标主机")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.exquisiteSecondary(height: 28))

                Button {
                    AsterState.shared.closeConnection(conn.id)
                    onClose()
                } label: {
                    HStack {
                        Image(systemName: "xmark.circle")
                        Text("一键断开连接")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.exquisiteSecondary(height: 28))
                .foregroundStyle(.red)
            }
        }
    }

    private func formatStartTime(_ start: String?) -> String {
        guard let start, !start.isEmpty else { return "—" }
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: start) {
            let df = DateFormatter()
            df.dateFormat = "HH:mm:ss.SSS"
            return df.string(from: date)
        }
        isoFormatter.formatOptions = [.withInternetDateTime]
        if let date = isoFormatter.date(from: start) {
            let df = DateFormatter()
            df.dateFormat = "HH:mm:ss"
            return df.string(from: date)
        }
        return start
    }

    private func formatDuration(_ ms: Int64?) -> String {
        guard let ms else { return "—" }
        if ms < 0 { return "0ms" }
        if ms < 1000 {
            return "\(ms)ms"
        } else {
            return String(format: "%.2fs", Double(ms) / 1000.0)
        }
    }

    private var formatCloseReason: String {
        if let reason = conn.diagnostics?.closeReason {
            switch reason {
            case "rejected": return "规则阻断"
            case "timeout": return "连接超时"
            case "dns_failed": return "DNS 异常"
            case "completed": return "正常完成"
            case "active": return "活跃传输中"
            default: return reason
            }
        }
        if conn.isReject { return "规则阻断" }
        if conn.isClosed == true { return "已关闭" }
        return "活跃传输中"
    }
}

// MARK: - 抽屉辅助卡片与行布局容器
private struct DrawerCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }
}

private struct DrawerInfoRow: View {
    let label: String
    let value: String
    var isMonospaced: Bool = false
    var copyable: Bool = false

    @State private var copied: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 68, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
                .font(.system(size: 11, weight: .medium, design: isMonospaced ? .monospaced : .default))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if copyable && !value.isEmpty && value != "—" {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(copied ? Color.green : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(copied ? "已复制" : "复制")
            }
        }
    }
}

// MARK: - 统一就地精美提示组件 (替代全局侵入式红条，对标 Surge 细腻微胶囊)
public enum InlineStatusKind: Equatable {
    case success(String)
    case warning(String)
    case error(String)
    case info(String)
    case loading(String)
}

public struct InlineStatusPill: View {
    public let kind: InlineStatusKind
    public var onDismiss: (() -> Void)? = nil

    public init(kind: InlineStatusKind, onDismiss: (() -> Void)? = nil) {
        self.kind = kind
        self.onDismiss = onDismiss
    }

    public var body: some View {
        HStack(spacing: 5) {
            iconView
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            if let dismiss = onDismiss {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(tintColor.opacity(0.8))
                }
                .buttonStyle(.plain)
                .padding(.leading, 2)
                .help("关闭提示")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(
            RoundedRectangle(cornerRadius: AsterMetrics.radiusControl, style: .continuous)
                .fill(tintColor.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AsterMetrics.radiusControl, style: .continuous)
                .strokeBorder(tintColor.opacity(0.24), lineWidth: 0.5)
        )
        .foregroundStyle(tintColor)
    }

    @ViewBuilder
    private var iconView: some View {
        switch kind {
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10, weight: .bold))
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .bold))
        case .error:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 10, weight: .bold))
        case .info:
            Image(systemName: "info.circle.fill")
                .font(.system(size: 10, weight: .bold))
        case .loading:
            ProgressView()
                .controlSize(.mini)
                .frame(width: 10, height: 10)
        }
    }

    private var title: String {
        switch kind {
        case .success(let t), .warning(let t), .error(let t), .info(let t), .loading(let t):
            return t
        }
    }

    private var tintColor: Color {
        switch kind {
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        case .info: return .blue
        case .loading: return .secondary
        }
    }
}
