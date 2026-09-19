# UI 设计系统成熟化与订阅导入工作流实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 针对状态栏菜单选项图标错位、策略组展示缺陷，以及配置页缺少单订阅/节点订阅/本地文件双层分流工作流的问题，系统性升级 Aster 的 UI 设计语言，消除粗糙感与 AI 模板痕迹，达到接近 Surge 的专业、沉稳、严密对齐的原生质感。

**Architecture:** 
1. 在 `UIComponents.swift` 中建立严谨的 8pt 度量网格 `AsterMetrics`，用 0.5pt 连续圆角微边框 `NativeHairlineBorder` 取代生硬的渐变高光，规范按钮组件无多余发光阴影。
2. 在 `AsterApp.swift` 中重塑 AppKit 原生状态栏菜单，确立统一的 20px 图标列、统一的文本左缩进，为策略组配备专属 SF Symbol，并将子菜单延迟列固定 64pt 等宽右对齐。
3. 在 `ViewsProfiles.swift` 中重构「添加订阅」模态弹窗 `AddSubscriptionSheet`，顶层区分「从网络 URL 导入」与「从本地文件导入」，网络模式下提供「单订阅模式（仅限单链接，使用源规则与策略组）」与「节点订阅模式（多链接聚合，仅提取节点，支持所有 sing-box 协议类型）」。

**Tech Stack:** Swift 5.9 / 6.0, SwiftUI, AppKit (NSMenu, NSMenuItem, NSView), Go 1.22+ 后端接口。

**Spec:** `docs/superpowers/specs/2026-09-19-ui-system-and-subscription-import-design.md`

## Global Constraints

- 保持全项目零 CGO 依赖，Go 后端所有修改必须通过 `go test -count=1 -race ./...` 检验。
- macOS 原生界面必须完全遵循 HIG 与 Swift 语法，通过 `swiftc -parse macos-native/Sources/Aster/*.swift` 检验。
- 状态栏菜单必须兼顾原生 NSMenu 体验与原地交互能力，绝不允许出现由于节点名称长短导致的图标错位或延迟文字凹凸不平。
- 保持向后兼容：现有订阅配置的数据结构与管理接口无破坏性变更。

---

### Task 1: UI 设计规范与基础组件重构 (`UIComponents.swift`)

**Files:**
- Modify: `macos-native/Sources/Aster/UIComponents.swift`

**Interfaces:**
- Produces: `AsterMetrics` (8pt 网格间距、连续圆角及菜单槽位规范)
- Produces: `NativeHairlineBorder` (0.5pt 系统级微边框)
- Produces: 规范化的 `ExquisitePrimaryButtonStyle` 与 `ExquisiteSecondaryButtonStyle`

- [ ] **Step 1: 在 `UIComponents.swift` 中定义 `AsterMetrics` 度量系统**

在 `UIComponents.swift` 开头加入：
```swift
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
    public static let radiusCard: CGFloat = 10.0
    public static let radiusSheet: CGFloat = 12.0

    // 状态栏菜单对齐槽位
    public static let menuIconColumnWidth: CGFloat = 18.0
    public static let menuTextIndent: CGFloat = 26.0
    public static let menuAccessoryWidth: CGFloat = 64.0
}
```

- [ ] **Step 2: 替换 `LiquidGlassBevelBorder` 为 `NativeHairlineBorder`**

用低调、符合 Apple 原生风格的 0.5pt 微边框替代粗糙的渐变高光边框：
```swift
public struct NativeHairlineBorder: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    public var cornerRadius: CGFloat
    public var lineWidth: CGFloat

    public init(cornerRadius: CGFloat = AsterMetrics.radiusCard, lineWidth: CGFloat = 0.5) {
        self.cornerRadius = cornerRadius
        self.lineWidth = lineWidth
    }

    public func body(content: Content) -> some View {
        content.overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    colorScheme == .dark
                        ? Color.white.opacity(0.12)
                        : Color.black.opacity(0.08),
                    lineWidth: lineWidth
                )
        )
    }
}

public extension View {
    func nativeHairlineBorder(cornerRadius: CGFloat = AsterMetrics.radiusCard, lineWidth: CGFloat = 0.5) -> some View {
        self.modifier(NativeHairlineBorder(cornerRadius: cornerRadius, lineWidth: lineWidth))
    }
}
```
保留 `liquidGlassBorder` 别名映射至 `nativeHairlineBorder` 确保平滑兼容。

- [ ] **Step 3: 优化 `ExquisitePrimaryButtonStyle` 与 `ExquisiteSecondaryButtonStyle`**

去除外发光彩色阴影，使按钮具备系统级严谨的微明度反馈：
```swift
public struct ExquisitePrimaryButtonStyle: ButtonStyle {
    public var height: CGFloat = 26
    public var cornerRadius: CGFloat = AsterMetrics.radiusControl

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
                    .fill(Color.accentColor.opacity(configuration.isPressed ? 0.8 : 1.0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
            )
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
```

- [ ] **Step 4: 编译检查**

执行 `swiftc -parse macos-native/Sources/Aster/*.swift`，验证无语法错误。

- [ ] **Step 5: 提交**

```bash
git add macos-native/Sources/Aster/UIComponents.swift
git commit -m "feat(ui): implement AsterMetrics and native hairline border system"
```

---

### Task 2: 状态栏菜单排版与对齐系统重构 (`AsterApp.swift`)

**Files:**
- Modify: `macos-native/Sources/Aster/AsterApp.swift`

**Interfaces:**
- Consumes: `AsterMetrics`
- Produces: 绝对等宽 20px 图标槽位、统一文字起始坐标与右侧等宽附件列的 `StickyMenuItemView` 与 `buildStatusMenu`

- [ ] **Step 1: 重构 `StickyMenuItemView` 的内部布局与度量**

在 `StickyMenuItemView.swift` 的 `layout()` 方法中：
- 勾选态 `checkView`：`NSRect(x: 6, y: (height - 12) / 2, width: 12, height: 12)`
- 图标槽位 `iconView`：无论是否有图标，固定在 `NSRect(x: 6, y: (height - 14) / 2, width: 14, height: 14)`。有图标时居中显示，无图标时隐去。
- 文本槽位 `titleLabel`：起点绝对固定在 `x: 26`（确保有图标项和无图标项的文字垂直中轴绝对一致）。
- 附件槽位 `accessoryLabel`：固定宽度 64pt，靠右排列在 `NSRect(x: bounds.width - 70, y: 3, width: 64, height: 18)`，使用 `NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)`。

- [ ] **Step 2: 为状态栏菜单中的策略组项补齐标准 SF Symbol**

在 `buildStatusMenu` 的策略组循环中：
```swift
let strategyItem = NSMenuItem(title: group.name, action: nil, keyEquivalent: "")
let groupIcon: String = {
    if group.tag == "proxy" || group.name.contains("节点选择") {
        return "slider.horizontal.3"
    } else if group.tag == "auto" || group.name.contains("自动") {
        return "bolt.horizontal.circle.fill"
    } else if group.name.contains("港") || group.name.contains("HK") || group.name.contains("台") || group.name.contains("美") || group.name.contains("日") {
        return "globe.asia.australia.fill"
    } else {
        return "arrow.triangle.branch"
    }
}()
strategyItem.image = NSImage(systemSymbolName: groupIcon, accessibilityDescription: group.name)
```
确保策略组拥有标准系统图标，与上下项在左侧图标列中完全对其。

- [ ] **Step 3: 统一 `createMenuItem` 与根菜单项的图标规范**

确保 `createMenuItem`（如「重载配置」「重启应用」「退出」等）生成的系统菜单项图标大小、模板属性和对齐标准与自定义项视觉平齐。

- [ ] **Step 4: 编译检查**

执行 `swiftc -parse macos-native/Sources/Aster/*.swift`，验证无语法错误。

- [ ] **Step 5: 提交**

```bash
git add macos-native/Sources/Aster/AsterApp.swift
git commit -m "feat(menu): unify status bar icon grid and alignment system"
```

---

### Task 3: 策略组子菜单展示优化与延迟对齐 (`AsterApp.swift`)

**Files:**
- Modify: `macos-native/Sources/Aster/AsterApp.swift`

**Interfaces:**
- Produces: 平整、不晃动、带协议色彩微标的 `makeStrategyMenu` 节点选择子菜单

- [ ] **Step 1: 优化置顶「延迟测试」交互按钮视图 (`StrategySpeedHeaderView`)**

在 `StrategySpeedHeaderView` 中：
- 将图标左间距严格设为 `x: 8`，与菜单主体项保持绝对相同的水平基准。
- 背景高亮使用 `NSColor.quaternaryLabelColor.withAlphaComponent(0.2)`，在 Hover 时平滑浮现。

- [ ] **Step 2: 在策略组子菜单项中加入协议色彩指示与等宽延迟列**

在 `applyStrategyMemberItem` 中：
- 获取对应节点的协议（通过 `state.findNode(for: tag)?.protocolName`）。
- 节点项目标题支持带上协议微缩文本标签（如 `[HY2]`、`[VLESS]`、`[WG]`）。
- 延迟数值文字采用固定 64pt 宽度，右对齐，使用 `monospacedDigitSystemFont`，未测速显示 `---`，超时显示 `超时`，测通显示 `xx ms`，且数值带有对应的绿/橙/红色彩。

- [ ] **Step 3: 支持嵌套策略组识别与层级展示**

若 `group.members` 中的某个 `memberTag` 对应另一个策略组（如 `auto` 属于 `proxy` 的子组），在菜单项中以带箭头的二级子菜单或专属标识展示，避免将其视为普通节点导致点击失效。

- [ ] **Step 4: 编译检查**

执行 `swiftc -parse macos-native/Sources/Aster/*.swift`，验证无语法错误。

- [ ] **Step 5: 提交**

```bash
git add macos-native/Sources/Aster/AsterApp.swift
git commit -m "feat(menu): polish strategy group submenu layout and delay formatting"
```

---

### Task 4: 配置页全新「添加订阅」双层分流模态与工作流 (`ViewsProfiles.swift`)

**Files:**
- Modify: `macos-native/Sources/Aster/ViewsProfiles.swift`

**Interfaces:**
- Produces: `AddSubscriptionSheet` (包含「从网络 URL 导入」与「从本地文件导入」两层分流，网络导入包含「单订阅模式」与「节点订阅模式」)
- Produces: 配置页右上角标准的「＋ 添加订阅」主按钮

- [ ] **Step 1: 重构配置页右上角操作栏**

在 `ProfilesView` 的 `PageHeader` 中：
将按钮文案从「添加配置」升级为「添加订阅」：
```swift
Button { 
    showingAddSheet = true 
} label: { 
    Label("添加订阅", systemImage: "plus") 
}
.buttonStyle(.exquisitePrimary)
.disabled(state.isConfigMutationInFlight)
```

- [ ] **Step 2: 构建全新的 `AddSubscriptionSheet` 视图骨架**

设计包含双层分流选择器的模态视图：
```swift
public struct AddSubscriptionSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject private var state = AsterState.shared
    
    // 来源选择：0 = 网络 URL, 1 = 本地文件
    @State private var sourceTab: Int = 0
    // 网络模式：0 = 单订阅模式 (使用源分流/分组), 1 = 节点订阅模式 (仅提取节点聚合池)
    @State private var networkMode: Int = 0
    
    @State private var name: String = ""
    @State private var singleUrl: String = ""
    @State private var nodeUrls: String = ""
    @State private var localContent: String = ""
    @State private var localFileName: String = ""
    @State private var activateImmediately: Bool = true
    @State private var selectedScriptId: String = ""
    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String?
```

- [ ] **Step 3: 编写网络导入下的双模式交互表单**

当 `sourceTab == 0` 时：
1. 顶部呈现带有说明的模式分段选择器：
   - **⚡️ 单订阅模式 (完整托管)**：说明「仅输入 1 个链接，使用源订阅分组与分流规则」。
   - **🔗 节点订阅模式 (多源聚合)**：说明「支持多个链接，仅提取节点，使用本地规则」。
2. 当 `networkMode == 0`（单订阅）时：
   - 渲染单行 `TextField("https://example.com/api/v1/client/subscribe?token=...", text: $singleUrl)`，右侧自带“粘贴”按钮。
3. 当 `networkMode == 1`（节点订阅）时：
   - 渲染多行 `TextEditor(text: $nodeUrls)`，右下角标明「已识别 X 行订阅源」，支持输入所有 sing-box 能解析的类型（Clash YAML、sing-box JSON、Base64 等）。

- [ ] **Step 4: 编写本地文件导入表单**

当 `sourceTab == 1` 时：
- 展示优雅的拖拽/选择卡片，支持 `.json`、`.yaml`、`.yml` 文件的拖拽与选择。
- 显示已选中文件名及文件体积。

- [ ] **Step 5: 编写提交处理逻辑，精确调用后端 API**

```swift
private func submit() {
    isSubmitting = true
    errorMessage = nil
    
    Task {
        do {
            let created: ConfigProfileItem
            if sourceTab == 0 {
                if networkMode == 0 {
                    // 单订阅模式
                    let trimmed = singleUrl.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let _ = URL(string: trimmed) else {
                        throw NSError(domain: "Aster", code: -1, userInfo: [NSLocalizedDescriptionKey: "请输入有效的订阅 URL"])
                    }
                    created = try await state.createConfigAndReturn(
                        name: name,
                        kind: "subscription",
                        url: trimmed,
                        content: "",
                        urls: [],
                        activate: activateImmediately
                    )
                } else {
                    // 节点订阅模式
                    let lines = nodeUrls.split(whereSeparator: \.isNewline)
                        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    guard !lines.isEmpty else {
                        throw NSError(domain: "Aster", code: -1, userInfo: [NSLocalizedDescriptionKey: "请至少输入一个有效的订阅链接"])
                    }
                    created = try await state.createConfigAndReturn(
                        name: name,
                        kind: "nodes",
                        url: "",
                        content: "",
                        urls: lines,
                        activate: activateImmediately
                    )
                }
            } else {
                // 本地文件导入
                guard !localContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw NSError(domain: "Aster", code: -1, userInfo: [NSLocalizedDescriptionKey: "请选择包含有效配置的文件"])
                }
                created = try await state.createConfigAndReturn(
                    name: name,
                    kind: "subscription",
                    url: "",
                    content: localContent,
                    urls: [],
                    activate: activateImmediately
                )
            }
            
            if !selectedScriptId.isEmpty {
                try await state.bindScript(profileId: created.id, scriptId: selectedScriptId)
            }
            
            await MainActor.run {
                isSubmitting = false
                isPresented = false
            }
        } catch {
            await MainActor.run {
                isSubmitting = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
```

- [ ] **Step 6: 编译检查**

执行 `swiftc -parse macos-native/Sources/Aster/*.swift`，验证无语法错误。

- [ ] **Step 7: 提交**

```bash
git add macos-native/Sources/Aster/ViewsProfiles.swift
git commit -m "feat(profiles): implement AddSubscriptionSheet with single and multi-node modes"
```

---

### Task 5: 全量回归测试与端到端编译检验

**Files:**
- Test: `internal/...`
- Test: `macos-native/Sources/Aster/*.swift`

- [ ] **Step 1: 运行全量 Go 单元测试**

执行 `go test -count=1 -race ./...`，确认所有包测试通过。

- [ ] **Step 2: 运行 Swift 语法与类型校验**

执行 `swiftc -parse macos-native/Sources/Aster/*.swift`，确保 0 警告 0 错误。

- [ ] **Step 3: 提交并生成最终验证报告**

更新相关进展记录。
