# AGENT.md - Aster 核心开发规则与易错避坑条令 (Crucial Rules & Pitfalls)

> **最高宪章**：本文档精简收录高频易错、极具杀伤力的核心约束。所有 AI 智能体与开发者必须严格无条件执行。

---

## 一、 单元测试与 CI 纯净环境隔离（最高频踩坑点 ⚠️）

1. **严禁在单元测试中隐式依赖 `sing-box` 内核二进制**
   - **痛点根因**：CI（GitHub Actions）虚拟机为全新环境，未预装内核。任何调用 `ActivateProfile` 的行为都会触发内核重启与真实二进制存在性校验，导致 `未找到 sing-box 内核` 直接阻断 CI。
   - **执行准则**：
     - 测试纯逻辑（如节点提取、配置生成、数据解析、内容检视）时，直接通过 `a.Store().Update(func(cur *state.File) { cur.ActiveConfigID = id })` 修改内存状态，**严禁调用 `ActivateProfile`**；
     - 若必须测试完整内核生效或校验逻辑，必须在测试中创建 `fakeCore`（返回 exit 0 的临时可执行脚本）并注入 `cur.Settings.CorePath`。
2. **强制无缓存全量竞态检测**
   - 验证必须执行 `GOOS=darwin GOARCH=arm64 go test -race -count=1 ./...`，严禁依赖带缓存的 `(cached)` 测试结果。

---

## 二、 数据真实性与严禁虚假兜底（零容忍红线 🚫）

1. **测速超时严禁重置为 0**
   - 超时状态必须严格记录并返回 `-1`（0 仅代表未测速，-1 代表超时失败）。
2. **网络与 IP 状态严禁伪造**
   - 断网或未探测到时，严禁硬编码返回 `127.0.0.1`，必须如实返回 `检测中…` 或 `离线`；
   - 断网时严禁伪造 `en0 以太网`，默认路由信息必须如实返回空；
   - 未激活配置时严禁返回虚构的“默认配置”，必须如实返回 `未激活配置`。
3. **分流规则严禁凭空捏造**
   - 严禁在界面硬编码展示不存在的系统规则集（如虚构的 `geosite-category-ads-all`）。

---

## 三、 SwiftUI 设计系统与组件化（杜绝样式碎片化 🧩）

1. **强制复用 `UIComponents.swift` 公共组件库**
   - 严禁在页面私自手写二级卡片样式。一律复用：
     - **二级子卡片**：`.asterSubcard(cornerRadius:padding:)`
     - **空状态**：`AsterEmptyState(icon:title:subtitle:actionTitle:action:)`
     - **提示/状态横幅**：`InfoNoticeBanner(text:icon:style:trailingText:onDismiss:)`
     - **单选/切换药丸**：`SelectionCapsule(title:icon:isSelected:tintColor:action:)`
     - **控制/设置行**：`SettingSwitchRow(title:subtitle:isOn:isEnabled:disabledReason:)`
     - **带反馈复制按钮**：`ExquisiteCopyButton(text:title:copiedTitle:)`
2. **模态与独立弹窗必须消除穿透**
   - 所有 Sheet 与独立 `NSWindow` 根视图必须挂载 `.unifiedWindowBackdrop(...)`，严禁红黄绿交通灯区域成透明黑洞。
3. **微发丝边框与几何连续曲率**
   - 边框一律使用 `NativeHairlineBorder`；卡片必须使用几何连续曲率，大卡片固定 12pt，控件固定 6pt。
4. **窗口物理硬边界与平滑缩放**
   - 窗口物理底线统一设为 `win.minSize = NSSize(width: 840, height: 560)`；
   - **严禁强制锁定窗口宽高比**（杜绝光标拖动对抗）；超宽屏依靠 `maxWidth: 1360` 居中容器防畸变。

---

## 四、 交互克制与命名规范

1. **绝对禁止侵入式打扰**
   - 复制、节点切换、测速、启停核心、配置切换等常规操作，**彻底严禁**弹出系统通知横幅（`notify` / `NSUserNotification`）或屏幕级全局 Toast；
   - 一律使用 `ClipboardHelper`（带物理轻触震动）+ 就地胶囊（`InlineStatusPill` / `InfoNoticeBanner`）在行内呈现。
2. **规范命名**
   - 系统初始默认配置统一且唯一命名为 **`Default`**；
   - 组合订阅统一称为 **“节点聚合”**，严禁在代码、注释或界面中出现“节点池”粗糙术语。

---

## 五、 提交前强制验证流水线（Iron Gate 门禁）

在声称任务完成或执行 `git push` 前，必须依次通过：
1. `swiftc -parse macos-native/Sources/Aster/*.swift`（确保 0 警告 0 报错）
2. 确认所有新 `.swift` 文件已包含在 `macos-native/Aster.xcodeproj/project.pbxproj` 中
3. `GOOS=darwin GOARCH=arm64 go test -race -count=1 ./...`（确保 14 个包 100% 绿色通过）
