# 进程级请求监控与规则诊断面板实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 构建全栈联动的进程级请求监控、链路溯源、时序度量与规则即时模拟评估系统（支持 App 图标与进程识别、分流全景面包屑、异常关闭原因诊断、规则即时演算与抽屉式审查）。

**Architecture:** 
- 后端在 `internal/app` 提供 `RuleEvaluator` 规则仿真引擎，并通过 `GET /api/v1/rules/evaluate` 对外暴露毫秒级规则评估能力；在连接追踪层补全持续时长、瞬时吞吐与关闭原因推断。
- 前端抽取通用的 `ConnectionDetailDrawer`、`RuleTracePipelineView` 与 `ConnectionDiagnosticBadge`，在主窗口活动页（`ViewsActivity.swift`）与独立日志大视窗（`InspectorWindow.swift`）全面支持抽屉式审查与规则即时测试。

**Tech Stack:** Go (Go 1.22+, `net/netip`, `sync`, `gorilla/websocket`), Swift 5.9+ (SwiftUI, AppKit, `NSWorkspace`).

**Spec:** `docs/superpowers/specs/2026-09-19-process-inspection-and-rule-evaluator-design.md`

## Global Constraints

- Go 后端无 CGO 依赖，全部包必须通过 `go test -count=1 -race ./...` 检验。
- macOS 客户端使用纯 SwiftUI + AppKit，必须通过 `swiftc -parse macos-native/Sources/Aster/*.swift`。
- 视觉与间距遵循 `AsterMetrics` 与 `NativeHairlineBorder` 规范，杜绝高反差荧光阴影与割裂对齐。

---

### Task 1: 后端规则仿真求值引擎与 API (`internal/app`, `internal/api`)

**Files:**
- Create: `internal/app/rule_evaluator.go`
- Create: `internal/app/rule_evaluator_test.go`
- Modify: `internal/api/server.go`
- Modify: `internal/api/server_test.go`

**Interfaces:**
- Produces: `app.EvaluateRule(req RuleEvaluateRequest) (*RuleEvaluateResult, error)`
- Produces: `GET /api/v1/rules/evaluate`
- Consumes: `app.App.Config()`, `app.App.ClashRules()`

- [ ] **Step 1: 编写规则评估核心单元测试**

在 `internal/app/rule_evaluator_test.go` 中编写用例，覆盖：
- `DOMAIN` 完全匹配
- `DOMAIN-SUFFIX` 后缀匹配（如 `apple.com` 匹配 `www.apple.com` 与 `apple.com`）
- `DOMAIN-KEYWORD` 关键字匹配
- `IP-CIDR` 掩码匹配（如 `192.168.1.50` 匹配 `192.168.0.0/16`）
- `PROCESS-NAME` 进程匹配
- `MATCH` / 终态兜底规则
- 策略组落地节点解析

```go
package app

import (
	"testing"
)

func TestRuleEvaluator_DomainSuffix(t *testing.T) {
	eval := NewRuleEvaluator([]RuleEntry{
		{Type: "DOMAIN-SUFFIX", Payload: "google.com", Outbound: "Proxy"},
		{Type: "MATCH", Payload: "", Outbound: "DIRECT"},
	})
	res := eval.Evaluate("mail.google.com", "", 443, "tcp")
	if res.Outbound != "Proxy" || res.RuleType != "DOMAIN-SUFFIX" {
		t.Fatalf("unexpected result: %+v", res)
	}
}
```

- [ ] **Step 2: 运行测试并验证失败**

运行：`go test -v ./internal/app -run TestRuleEvaluator`
预期：编译失败（`RuleEvaluator` 未定义）

- [ ] **Step 3: 实现 `RuleEvaluator` 规则求值引擎**

在 `internal/app/rule_evaluator.go` 中实现结构体与评估逻辑：
- 解析 IP 地址（使用 `net/netip` 极速掩码计算，无堆分配）。
- 域名规范化与后缀切片匹配。
- 输出命中规则、负载、出站策略及耗时（纳秒转毫秒 `evaluationTimeMs`）。

- [ ] **Step 4: 暴露 API 端点 `GET /api/v1/rules/evaluate`**

在 `internal/api/server.go` 中注册路由 `GET /api/v1/rules/evaluate`：
- 读取 query 参数 `target`、`process`、`port`、`network`。
- 调用 `App.EvaluateRule(...)` 并以 JSON 格式返回。
- 在 `internal/api/server_test.go` 中添加端点鉴权与返回值单元测试。

- [ ] **Step 5: 运行并验证全部测试**

运行：`go test -count=1 -race ./internal/app ./internal/api`
预期：PASS

- [ ] **Step 6: 提交代码**

```bash
git add internal/app/rule_evaluator.go internal/app/rule_evaluator_test.go internal/api/server.go internal/api/server_test.go
git commit -m "feat(app): implement RuleEvaluator and GET /api/v1/rules/evaluate endpoint"
```

---

### Task 2: 后端连接时序度量与异常原因推断 (`internal/clash`, `internal/app`, `internal/logstore`)

**Files:**
- Modify: `internal/clash/client.go`
- Modify: `internal/app/app.go`
- Modify: `internal/logstore/store.go`
- Modify: `internal/logstore/store_test.go`

**Interfaces:**
- Produces: `clash.ConnectionDiagnostics` (包含 `DurationMs`, `SpeedIn`, `SpeedOut`, `CloseReason`, `IsFailed`)
- Consumes: sing-box 连接快照流

- [ ] **Step 1: 在 `clash.Connection` 中扩展诊断结构**

在 `internal/clash/client.go` 中增加：
```go
type ConnectionDiagnostics struct {
	DurationMs   int64  `json:"durationMs"`
	SpeedIn      int64  `json:"speedIn"`
	SpeedOut     int64  `json:"speedOut"`
	CloseReason  string `json:"closeReason"`
	IsFailed     bool   `json:"isFailed"`
}
```
并在 `Connection` 结构体中增加字段 `Diagnostics ConnectionDiagnostics`。

- [ ] **Step 2: 编写连接时序与关闭原因推断的单测**

在 `internal/logstore/store_test.go` 或 `internal/app/` 中添加测试：
- 验证持续存续连接计算得出的 `DurationMs` > 0。
- 验证规则为 `REJECT` 时自动标记为 `CloseReason = "rejected"` 且 `IsFailed = true`。
- 验证正常传输完成后标记为 `CloseReason = "completed"`。

- [ ] **Step 3: 实现速率平滑与原因推断逻辑**

在 `internal/app/app.go` 中的 `observeConnections` 处理循环中：
- 缓存上一秒的连接快照 `map[string]clash.Connection`。
- 遍历计算当前连接相较上一秒的 `(Upload - prevUpload) / delta` 及 `Download` 差值，得出 `SpeedIn` 与 `SpeedOut`。
- 计算 `time.Since(startTime).Milliseconds()` 填入 `DurationMs`。
- 结合连接元数据识别异常原因并赋给 `Diagnostics`。

- [ ] **Step 4: 更新 `logstore` 存储与回溯逻辑**

确保 `internal/logstore/store.go` 在归档已关闭连接时保留完整的 `Diagnostics`。

- [ ] **Step 5: 运行全量后端测试**

运行：`go test -count=1 -race ./internal/clash ./internal/app ./internal/logstore`
预期：PASS

- [ ] **Step 6: 提交代码**

```bash
git add internal/clash/client.go internal/app/app.go internal/logstore/store.go internal/logstore/store_test.go
git commit -m "feat(core): add timing diagnostics, transfer rates, and failure inference to connections"
```

---

### Task 3: 前端诊断组件体系与链路溯源 (`UIComponents.swift`)

**Files:**
- Modify: `macos-native/Sources/Aster/Models.swift`
- Modify: `macos-native/Sources/Aster/AsterAPI.swift`
- Modify: `macos-native/Sources/Aster/UIComponents.swift`

**Interfaces:**
- Produces: `RuleTracePipelineView`
- Produces: `ConnectionDiagnosticBadge`
- Produces: `ConnectionDetailDrawer`
- Consumes: `ConnectionItem`, `ConnectionDiagnosticsItem`

- [ ] **Step 1: 在 `Models.swift` 与 `AsterAPI.swift` 中补充数据模型**

在 `Models.swift` 补充：
```swift
public struct ConnectionDiagnosticsItem: Codable, Equatable, Hashable {
    public let durationMs: Int64?
    public let speedIn: Int64?
    public let speedOut: Int64?
    public let closeReason: String?
    public let isFailed: Bool?
}
```
并在 `ConnectionItem` 中关联 `public let diagnostics: ConnectionDiagnosticsItem?`。
在 `AsterAPI.swift` 中新增 `evaluateRule(target: String, process: String?) async throws -> RuleEvaluateResult`。

- [ ] **Step 2: 实现全景分流链路追踪视图 `RuleTracePipelineView`**

在 `UIComponents.swift` 中实现水平阶段流向图组件：
- 节点 1：客户端应用与进程（使用 `iconForProcess` + 进程名）
- 节点 2：DNS 解析与目标寻址
- 节点 3：规则命中（标明类型与 Payload）
- 节点 4：出站策略（标明策略组及落地节点）
- 节点 5：传输终态与度量
- 包含阶段连接线与状态色彩。

- [ ] **Step 3: 实现状态微光与诊断徽标 `ConnectionDiagnosticBadge`**

实现多态胶囊：
- 活跃传输中：绿色微光小圆点 + 动态瞬时网速（如 `↓ 1.2 MB/s`）
- 正常完成：低调灰色标签（`✓ 2.3s`）
- 规则阻断：警示红底（`⊘ 阻断`）
- 传输超时：醒目橙底（`⏱ 超时`）
- DNS 异常：暗紫底色（`⚠ DNS 异常`）

- [ ] **Step 4: 实现通用右侧属性审查抽屉 `ConnectionDetailDrawer`**

将审查抽屉组件化：
- 宽度固定 340pt，支持右上角关闭或 `Esc` 键退出。
- 包含发起端、目标网络、链路决策、时序度量、快捷规则操作五大卡片。

- [ ] **Step 5: 语法编译验证**

运行：`swiftc -parse macos-native/Sources/Aster/*.swift`
预期：0 errors, 0 warnings

- [ ] **Step 6: 提交代码**

```bash
git add macos-native/Sources/Aster/Models.swift macos-native/Sources/Aster/AsterAPI.swift macos-native/Sources/Aster/UIComponents.swift
git commit -m "feat(ui): implement RuleTracePipelineView, ConnectionDiagnosticBadge, and ConnectionDetailDrawer"
```

---

### Task 4: 主窗口活动页交互升级与规则即时测试器 (`ViewsActivity.swift`)

**Files:**
- Modify: `macos-native/Sources/Aster/ViewsActivity.swift`

**Interfaces:**
- Produces: 抽屉联动交互（点击单行滑出 `ConnectionDetailDrawer`，键盘上下键选择）
- Produces: 规则模拟测试器 `RuleEvaluatorBar`
- Produces: 搜索与状态分段过滤器

- [ ] **Step 1: 实现工具栏快速搜索、状态过滤与规则测试入口**

在 `ViewsActivity.swift` 的实时连接区域顶栏：
- 加入 `TextField("搜索应用、域名、IP 或规则…", text: $connectionSearchText)`。
- 加入分段过滤器：`全部` / `活跃` / `已关闭` / `异常`。
- 加入「⚡️ 规则测试」按钮，点击平滑展开测试输入条。

- [ ] **Step 2: 实现嵌入式规则即时测试条 `RuleEvaluatorBar`**

- 提供单行紧凑输入框，支持回车直接调用 `state.evaluateRule(...)`。
- 预测结果以卡片形式优雅呈现：命中类型、匹配规则、目标节点与耗时。

- [ ] **Step 3: 改造 `LiveConnectionRow` 并支持抽屉联动**

- 将列表行升级为支持点击高亮与悬浮反馈的交互卡片，集成 `ConnectionDiagnosticBadge`。
- 在 `HStack` 容器右侧嵌入 `if let selected = selectedConnection { ConnectionDetailDrawer(conn: selected, onClose: { selectedConnection = nil }) }`。
- 加入动画过渡与键盘导航监听。

- [ ] **Step 4: 语法编译验证**

运行：`swiftc -parse macos-native/Sources/Aster/*.swift`
预期：0 errors, 0 warnings

- [ ] **Step 5: 提交代码**

```bash
git add macos-native/Sources/Aster/ViewsActivity.swift
git commit -m "feat(activity): upgrade connection table with slide-over drawer and inline rule evaluator"
```

---

### Task 5: 独立请求日志视窗打磨与全量回归检验 (`InspectorWindow.swift`, 全量测试)

**Files:**
- Modify: `macos-native/Sources/Aster/InspectorWindow.swift`
- Test: 全量 Go 后端与 Swift 前端

**Interfaces:**
- Produces: 统一使用 `RuleTracePipelineView`、`ConnectionDiagnosticBadge` 与 `ConnectionDetailDrawer`
- Produces: 独立视窗顶栏规则测试器

- [ ] **Step 1: 升级 `InspectorWindow.swift`**

- 替换原有的行内分散组件，统一采用 `ConnectionDiagnosticBadge` 与 `RuleTracePipelineView`。
- 在顶栏工具区集成规则模拟测试入口。
- 保证独立视窗与主窗口在视觉度量、时序计算与链路诊断上保持 100% 一致。

- [ ] **Step 2: 运行全量 Go 单元测试**

运行：`go test -count=1 -race ./...`
预期：全部 13 个包全部通过，无 data race。

- [ ] **Step 3: 运行 Swift 语法与类型校验**

运行：`swiftc -parse macos-native/Sources/Aster/*.swift`
预期：0 errors, 0 warnings。

- [ ] **Step 4: 提交代码**

```bash
git add macos-native/Sources/Aster/InspectorWindow.swift
git commit -m "feat(inspector): unify standalone logs window with diagnostics pipeline and rule evaluator"
```

- [ ] **Step 5: 生成最终验证 Walkthrough**

更新验证报告。
