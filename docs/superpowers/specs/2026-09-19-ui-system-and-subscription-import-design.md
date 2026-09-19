# UI 设计系统成熟化与订阅导入工作流设计规范

- **文档标识**: `2026-09-19-ui-system-and-subscription-import-design`
- **目标分支**: `feat/protocol-expansion` (或由其演进的功能集)
- **对标标准**: Surge for Mac 原生设计哲学、Apple Human Interface Guidelines (macOS Sonoma / Sequoia)
- **受影响模块**:
  - `macos-native/Sources/Aster/UIComponents.swift` (设计系统、度量指标、边框与按钮)
  - `macos-native/Sources/Aster/AsterApp.swift` (状态栏原生菜单排版、图标对齐、策略组结构)
  - `macos-native/Sources/Aster/ViewsProfiles.swift` (配置管理页、全新「添加订阅」弹窗与导入工作流)

---

## 1. 设计目标与核心解决的问题

当前 Aster 的 macOS 界面已初具现代客户端框架，但在细节打磨上存在多处粗糙点：
1. **状态栏菜单选项图标严重错位**：原生 `NSMenuItem.image` 与自定义 `StickyMenuItemView` 混用，坐标写死；策略组没有图标导致文字向左突出；右侧延迟未固定列宽对齐。
2. **设计系统存在伪拟物与 AI 模板痕迹**：卡片上带有浮夸的白色渐变描边（`LiquidGlassBevelBorder`）与深重阴影，按钮带有光晕发光，缺乏 Surge 的沉稳工业感。
3. **配置页缺少规范的订阅分流入口**：原有的添加弹窗混杂，无法清晰区分「单订阅完整托管（带规则/分组）」与「多订阅节点聚合（仅提取节点，用本地规则）」。

本次设计旨在系统性重塑这三大板块，使界面呈现**高度一致、严密对齐、流畅大气**的专业工具品质。

---

## 2. 界面设计系统重构 (`UIComponents.swift`)

### 2.1 8pt 网格与度量系统 (`AsterMetrics`)
彻底废弃 `13.5`、`11.5`、`8.5` 等不规则尺寸，建立严谨的倍率体系：

```swift
public enum AsterMetrics {
    // 间距节律 (8pt 网格)
    public static let spacingMicro: CGFloat = 4
    public static let spacingTight: CGFloat = 8
    public static let spacingStandard: CGFloat = 12
    public static let spacingRelaxed: CGFloat = 16
    public static let spacingSection: CGFloat = 24
    
    // 连续曲率圆角 (Continuous Curves)
    public static let radiusBadge: CGFloat = 4.5    // 微型徽标、协议标签
    public static let radiusControl: CGFloat = 6.0  // 按钮、输入框、下拉框
    public static let radiusCard: CGFloat = 10.0    // 内容卡片容器
    public static let radiusSheet: CGFloat = 12.0   // 模态弹窗与视窗
    
    // 状态栏菜单槽位度量 (AppKit NSMenu)
    public static let menuIconColumnWidth: CGFloat = 18.0  // 图标固定宽
    public static let menuTextIndent: CGFloat = 26.0       // 文字绝对起始坐标
    public static let menuAccessoryWidth: CGFloat = 64.0   // 延迟右对齐固定宽
}
```

### 2.2 材质与边框重构（去假渐变，拥抱 Native Hairline）
- **废除** `LiquidGlassBevelBorder`：删除纯白高光渐变。
- **引入** `NativeHairlineBorder`：
  - 采用标准 0.5pt 连续圆角微边框。
  - 浅色模式：`Color.black.opacity(0.08)`
  - 暗色模式：`Color.white.opacity(0.12)`
- **卡片底色**：统一使用系统级 `Color(NSColor.controlBackgroundColor).opacity(0.45)` 叠加原生轻薄材质，消除多余的下落浮动阴影（仅浮层与弹窗保留系统级微投影）。

### 2.3 按钮系统重构
- **Primary 按钮 (`ExquisitePrimaryButtonStyle`)**：
  - 高度统一为 26pt / 28pt，6pt 连续圆角。
  - 纯色 `Color.accentColor` 填充，按下态明度平滑衰减，**移除外发光彩色阴影**。
- **Secondary 按钮 (`ExquisiteSecondaryButtonStyle`)**：
  - 采用系统 `Color.primary.opacity(0.06)` 底色配合 0.5pt 边框，Hover 时平滑加深至 `0.10`。
- **Icon / Ghost 按钮**：无底色，Hover 触发胶囊微高光。

---

## 3. 状态栏菜单排版与策略组展示重构 (`AsterApp.swift`)

### 3.1 菜单项目标结构与对齐系统
状态栏菜单全项采用单套严谨的排版坐标系：
- **左侧状态/图标列 (0 ~ 24pt)**：
  - 勾选态（Checkmark `✓`）：固定处于 `x: 8, width: 12` 槽位。
  - 项目图标（SF Symbol）：无论是否勾选，统一居中于 `x: 8 ~ 22` 槽位（宽度 16pt）。
- **主体文字列 (x: 26pt 起)**：
  - 每一项的标题严格从 `x: 26pt` 开始，字体采用系统标准菜单字体 `NSFont.menuFont(ofSize: 0)`。
  - 彻底杜绝无图标项直接左贴边的视觉断层。
- **右侧附件列 (bounds.width - 70 ~ bounds.width - 10)**：
  - 延迟指示（`nodeDelayText`）：固定 64pt 宽度右对齐，强制使用 `NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)`，彻底消除因数字跳动或节点名字长短导致的右侧凹凸不平。

### 3.2 策略组菜单项重构
1. **主菜单入口**：
   - 为策略组提供清晰的 SF Symbol 图标（如主策略组使用 `slider.horizontal.3`，子策略组使用 `arrow.triangle.branch` 或地区定位图标）。
   - 主菜单行格式：
     `[ 􀌇 图标 ]  策略组名称                   [当前节点] 􀆊`
2. **策略组二级子菜单 (`makeStrategyMenu`)**：
   - **顶部**：`[ ⚡️ 延迟测试 ]`（原生设计交互行，带小风车 Loading 与轻微底色，点击在菜单内原地测速，不退出菜单）。
   - **分割线**：`NSMenuItem.separator()`。
   - **节点成员列表**：
     - 若成员为**普通代理节点**：展示 `[✓ / 空] [协议彩色微标] 节点名称`，右侧固定 64pt 呈现 `85 ms`（支持绿/黄/红彩色指示点）。
     - 若成员为**嵌套子策略组**（如 `auto` 或地区组）：展示该子策略组标签与指示箭头，点击无缝展开第三级菜单或切换。

---

## 4. 配置页「添加订阅」全新工作流 (`ViewsProfiles.swift`)

### 4.1 顶栏交互改造
- 将顶栏原单一的「添加配置」按钮升级为 **「＋ 添加订阅」** 主操作按钮。
- 点击按钮唤起结构清晰、Surge 风格的专业导入模态弹窗 `AddSubscriptionSheet`（固定宽度 540pt，垂直优雅自适应）。

### 4.2 模态弹窗双层分流架构

```
┌─────────────────────────────────────────────────────────────┐
│ ＋ 添加订阅配置                                         [✕] │
│ 选择导入方式以初始化代理策略与分流规则                      │
├─────────────────────────────────────────────────────────────┤
│   [ 🌐 从网络 URL 导入 ]        [ 📁 从本地文件导入 ]        │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  [ 当选中“从网络 URL 导入”时：展示模式分段器 ]               │
│  导入模式:                                                  │
│  ┌────────────────────────────┬───────────────────────────┐ │
│  │ ⚡️ 单订阅模式 (完整托管)    │ 🔗 节点订阅模式 (多源聚合)  │ │
│  │ 使用源订阅策略组与路由分流  │ 仅提取节点，本地自定义规则│ │
│  └────────────────────────────┴───────────────────────────┘ │
│                                                             │
│  配置名称 (可选):                                           │
│  [ 例如：My Airport 01                                  ]   │
│                                                             │
│  订阅链接:                                                  │
│  - 单订阅模式：呈现单行 TextField + 右侧剪贴板快捷粘贴按钮    │
│  - 节点订阅模式：呈现多行 TextEditor (每行一个链接，带行数提示)│
│                                                             │
│  💡 支持 sing-box、Clash YAML 与 Base64 订阅链接，自动嗅探  │
│                                                             │
│  ---------------------------------------------------------  │
│  [ 当选中“从本地文件导入”时：展示专业文件选择区 ]           │
│  ┌────────────────────────────────────────────────────────┐ │
│  │ 􀈷 点击选择配置文件或将 .json / .yaml 文件拖拽至此      │ │
│  │   [ 浏览本地文件… ] (已选文件名及大小预览)              │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                             │
│  [ 挂载覆写脚本 (可选下拉框) ]                              │
│  [✓] 添加后立即设为当前生效配置                              │
├─────────────────────────────────────────────────────────────┤
│                                      [ 取消 ]  [ 立即导入 ] │
└─────────────────────────────────────────────────────────────┘
```

### 4.3 数据映射与后端接口适配

1. **单订阅模式 (Single Subscription Mode)**：
   - 校验仅能输入一个合法的 HTTP/HTTPS 链接。
   - 调用后端 `state.createConfigAndReturn(name: name, kind: "subscription", url: url, content: "", urls: [], activate: activate)`。
   - 后端使用 `CreateSubscriptionProfile`，完整保留远端配置的 `outbounds` 策略组与 `route.rules` 分流规则。

2. **节点订阅模式 (Node Subscription Mode)**：
   - 支持换行输入多个订阅链接（过滤空行与重复链接）。
   - 支持所有 sing-box / Aster 支持的订阅格式（Clash YAML、sing-box JSON、Base64 等）。
   - 调用后端 `state.createConfigAndReturn(name: name, kind: "nodes", url: "", content: "", urls: lines, activate: activate)`。
   - 后端使用 `CreateNodeProfile`，仅提取各个订阅源中的代理节点聚合为节点池，使用 Aster 内置/自定义的本地分流策略组。

3. **本地文件导入 (Local File Mode)**：
   - 读取本地 `.json`、`.yaml` 或 `.yml` 文本内容。
   - 调用后端 `state.createConfigAndReturn(name: name, kind: "subscription", url: "", content: fileContent, urls: [], activate: activate)`。

---

## 5. 验证与验收标准

1. **视觉对齐验证**：
   - 状态栏菜单展开时，顶部「显示主窗口」、中段「出站模式」「策略组」「网络接管」以及底段「设置」「退出」的左侧图标绝对垂直居中对齐，文字起始位置完全一致。
   - 策略组二级菜单中，所有节点的协议徽标、节点名称与右侧 `ms` 延迟列呈网格状整齐排列，无折行跳动。
2. **交互与功能验证**：
   - 点击配置页「添加订阅」，能够无缝切换「单订阅模式」、「节点订阅模式」与「本地文件导入」。
   - 单订阅模式输入单个链接能成功创建带完整规则的分组配置。
   - 节点订阅模式输入多个链接能聚合生成纯节点池配置。
   - 本地文件模式能成功拖拽或选择导入。
3. **编译与回归验证**：
   - 执行 `swiftc -parse macos-native/Sources/Aster/*.swift` 语法校验通过。
   - 执行 `go test -count=1 -race ./...` 全量回归无竞态、全部通过。
