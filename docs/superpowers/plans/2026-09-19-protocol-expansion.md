# 新一代协议支持与可视化 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 Aster 增加 WireGuard、Hysteria 2 深度参数（混淆及流控）、TUIC v5（拥塞控制及 UDP 中继）、ShadowTLS 的完整解析与 sing-box 1.14+ 映射，并在 macOS 原生 UI 中提供专属协议色彩徽章。

**Architecture:** 在 `internal/sub/parse.go` 中扩充 Clash YAML 解析与 URI Scheme 解析，将目标协议精准映射为 sing-box 1.14+ 原生 outbound JSON；在 `macos-native/` 中扩展 SwiftUI 协议标签视觉渲染系统。

**Tech Stack:** Go 1.22+, sing-box 1.14.0, Swift 6, SwiftUI, AppKit

**Spec:** `docs/superpowers/specs/2026-09-19-protocol-expansion-design.md`

## Global Constraints
- 所有生成的 outbound 必须完全符合 sing-box 1.14+ 规范。
- 绝不引入任何 CGO 依赖，保持全纯 Go 编译特性。
- `go test -race ./...` 必须持续 100% 通过，无竞态告警。

---

### Task 1: WireGuard 协议解析与 sing-box 映射

**Files:**
- Modify: `internal/sub/parse.go`
- Test: `internal/sub/parse_test.go`

**Interfaces:**
- Produces: `func parseWireGuard(p map[string]any) ([]byte, error)`, `func wireguardURI(u *url.URL) (state.Node, error)`
- Output: sing-box outbound JSON with `type: "wireguard"`, `local_address`, `peer_public_key`, `private_key`, `reserved`, `mtu`

- [ ] **Step 1: 编写 WireGuard 单元测试用例**
在 `internal/sub/parse_test.go` 中添加 `TestParseWireGuard_ClashYAML` 和 `TestParseWireGuard_URI`，测试普通 WG 节点以及带有 `reserved: [0,0,0]` / `"0,0,0"` 的 Cloudflare WARP 节点。

- [ ] **Step 2: 运行测试验证失败**
执行 `go test ./internal/sub -run TestParseWireGuard`，确认由于协议未实现而报错。

- [ ] **Step 3: 在 `internal/sub/parse.go` 中实现 WireGuard 解析与映射**
在 `mapToOutbound` 中增加 `case "wireguard", "wg":`，处理 IP 掩码自动补齐、`peer_public_key`、`private_key`、`reserved` 切片转换；并在 `ParseURI` 中注册 `case "wireguard", "wg":`。

- [ ] **Step 4: 运行测试验证通过**
执行 `go test -race ./internal/sub -run TestParseWireGuard`，确保测试通过。

---

### Task 2: Hysteria 2 混淆与流控带宽深度解析

**Files:**
- Modify: `internal/sub/parse.go`
- Test: `internal/sub/parse_test.go`

**Interfaces:**
- Consumes: Clash YAML map 或 URI query 参数
- Produces: `obfs` 对象（`type: "salamander"`, `password`）与 `up_mbps`, `down_mbps` 整数值

- [ ] **Step 1: 编写 Hysteria 2 深度参数测试**
在 `internal/sub/parse_test.go` 中编写 `TestParseHysteria2_FullOptions`，测试包含 `obfs: salamander`、`obfs-password` 以及字符串带宽 `"100 Mbps"`、`"500"` 的解析。

- [ ] **Step 2: 运行测试验证失败**
执行 `go test ./internal/sub -run TestParseHysteria2_FullOptions`，确认断言失败。

- [ ] **Step 3: 在 `internal/sub/parse.go` 中扩展 Hysteria 2 解析逻辑**
解析 `obfs` 与 `obfs-password` 生成 sing-box 混淆对象；解析 `up` / `up_mbps` / `down` / `down_mbps` 转为整数字段；在 URI 中支持 `obfs` 与 `obfs-password` 查询参数。

- [ ] **Step 4: 运行测试验证通过**
执行 `go test -race ./internal/sub -run TestParseHysteria2_FullOptions`，确保通过。

---

### Task 3: TUIC v5 拥塞控制与中继模式深度解析

**Files:**
- Modify: `internal/sub/parse.go`
- Test: `internal/sub/parse_test.go`

**Interfaces:**
- Produces: `congestion_controller` (`bbr`, `cubic`), `udp_relay_mode` (`native`, `quic`), `zero_rtt_handshake: true`

- [ ] **Step 1: 编写 TUIC 深度参数测试**
在 `internal/sub/parse_test.go` 中扩展 `TestParseTUIC`，验证包含 `congestion-controller: bbr` 与 `udp-relay-mode: native` 的映射。

- [ ] **Step 2: 运行测试验证失败**
执行 `go test ./internal/sub -run TestParseTUIC` 确认未包含新字段。

- [ ] **Step 3: 在 `internal/sub/parse.go` 中扩展 TUIC 解析**
透传 `congestion_controller`、`udp_relay_mode`、设置默认或指定的 `zero_rtt_handshake`。

- [ ] **Step 4: 运行测试验证通过**
执行 `go test -race ./internal/sub -run TestParseTUIC` 确保通过。

---

### Task 4: ShadowTLS 协议支持

**Files:**
- Modify: `internal/sub/parse.go`
- Test: `internal/sub/parse_test.go`

**Interfaces:**
- Produces: sing-box `shadowtls` 出站结构（`server`, `server_port`, `version`, `password`, `tls`）

- [ ] **Step 1: 编写 ShadowTLS 测试**
在 `internal/sub/parse_test.go` 中编写 `TestParseShadowTLS`。

- [ ] **Step 2: 运行测试验证失败**
执行 `go test ./internal/sub -run TestParseShadowTLS` 确认失败。

- [ ] **Step 3: 实现 ShadowTLS 解析**
在 `internal/sub/parse.go` 中增加 `case "shadowtls":`，映射对应字段与 TLS sni。

- [ ] **Step 4: 运行测试验证通过**
执行 `go test -race ./internal/sub -run TestParseShadowTLS` 确保通过。

---

### Task 5: 原生 UI 专属协议色彩徽章与特性指示

**Files:**
- Modify: `macos-native/Sources/Aster/ViewsOutbounds.swift`
- Modify: `macos-native/Sources/Aster/InspectorWindow.swift`

- [ ] **Step 1: 在 `ViewsOutbounds.swift` 中升级 ProtocolBadge 样式**
添加协议颜色分配函数：
- `HY2` / `HYSTERIA2` -> `Color.orange`
- `TUIC` -> `Color.teal`
- `WG` / `WIREGUARD` -> `Color.indigo`
- `VLESS` / `VMESS` -> `Color.blue`
- `TROJAN` -> `Color.red.opacity(0.85)`
- `SS` -> `Color.green`

- [ ] **Step 2: 在 `InspectorWindow.swift` 请求流水表中统一协议颜色徽标**
确保请求详情与流水行中的出站协议呈现相同的专属颜色。

---

### Task 6: 全量回归测试与端到端核心语法校验

- [ ] **Step 1: 运行全量 Go 单元测试**
执行 `go test -race ./...`，确认所有包测试通过。

- [ ] **Step 2: 验证生成的 sing-box 1.14 核心配置校验**
通过 `sing-box check` 验证生成的出站节点配置有效。
