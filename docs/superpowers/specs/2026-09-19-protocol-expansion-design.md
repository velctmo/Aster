# 新一代协议支持与可视化设计方案 (Protocol Expansion & Visualization)

**日期**：2026-09-19
**状态**：已确认 (Approved)
**目标**：为 Aster 代理客户端增加 WireGuard（含 Cloudflare WARP 衍生版）、Hysteria 2 全功能参数（混淆及流控）、TUIC v5（拥塞控制及 UDP 中继模式）、ShadowTLS 伪装链式出站的完整解析与 sing-box 1.14+ 映射，并在 macOS 原生 UI 中支持专属语义颜色徽章与特性指示。

---

## 1. 协议解析层设计 (`internal/sub/parse.go`)

### 1.1 WireGuard 协议解析
* **Clash 节点格式支持**：
  * `type: wireguard`
  * 字段映射：
    * `server`: 服务器地址 (IP 或域名)
    * `port`: 端口
    * `ip` / `ips`: 本地地址映射为 sing-box `local_address` (若无掩码自动补齐 `/32` 或 `/128`)
    * `public-key`: 转换为 `peer_public_key`
    * `private-key`: 转换为 `private_key`
    * `preshared-key`: 可选转换为 `pre_shared_key`
    * `reserved`: 支持数组 `[0, 0, 0]` 或逗号字符串 `"0,0,0"`，转为 `[]int`
    * `mtu`: 可选整数，默认 `1420`
* **URI 格式支持**：
  * `wireguard://<private-key>@<server>:<port>?public_key=...&address=...&reserved=...#<name>`
* **sing-box 1.14 出站结构**：
  ```json
  {
    "type": "wireguard",
    "tag": "<tag>",
    "server": "<server>",
    "server_port": <port>,
    "local_address": ["172.16.0.2/32"],
    "private_key": "<private_key>",
    "peer_public_key": "<peer_public_key>",
    "pre_shared_key": "<pre_shared_key>",
    "reserved": [0, 0, 0],
    "mtu": 1420
  }
  ```

### 1.2 Hysteria 2 全功能参数
* **混淆配置**：
  * 解析 `obfs` 与 `obfs-password`，映射为 sing-box 1.14 标准 `obfs` 对象：
    `"obfs": { "type": "salamander", "password": "<pass>" }`
* **流控带宽**：
  * 解析 `up` / `up_mbps` / `down` / `down_mbps`，支持诸如 `"100 Mbps"`、`"500"` 等格式，转为整数 Mbps。
* **URI 增强**：
  * `hysteria2://password@host:port?obfs=salamander&obfs-password=xxx&sni=xxx&insecure=1#tag`

### 1.3 TUIC v5 全功能参数
* **拥塞控制算法**：
  * 解析 `congestion-controller` / `congestion_controller`（支持 `bbr`, `cubic`, `new_reno`）。
* **UDP 中继与握手优化**：
  * 解析 `udp-relay-mode` / `udp_relay_mode`（`native`, `quic`）。
  * 默认启用 `zero_rtt_handshake: true`。

### 1.4 ShadowTLS 链式伪装出站
* **Clash 节点格式支持**：
  * `type: shadowtls`
  * 字段：`server`, `port`, `password`, `version`, `sni`。

---

## 2. 核心渲染集成 (`internal/render/render.go`)

* 针对所有包含域名形式 `server` 的出站节点，提取其 Hostname 统一加入 DNS 预解析列表（Bootstrap DNS），确保 Direct 解析。

---

## 3. macOS 原生 UI 可视化设计 (`macos-native/`)

### 3.1 协议专属色彩微标 (`ViewsOutbounds.swift`)
* `WIREGUARD` / `WG`: 蓝紫色 (`Color.indigo`)
* `HYSTERIA2` / `HY2`: 日落暖橙色 (`Color.orange`)
* `TUIC`: 青碧色 (`Color.teal`)
* `VLESS` / `VMESS`: 科技蓝 (`Color.blue`)
* `TROJAN`: 珊瑚红 (`Color.red.opacity(0.85)`)
* `SHADOWSOCKS` / `SS`: 翡翠绿 (`Color.green`)

### 3.2 节点高级特性微标签 (Micro Badges)
* 混淆节点标注：`[Obfs]`
* WARP 节点标注：`[WARP]`
* BBR 节点标注：`[BBR]`

---

## 4. 自动化测试与质量守门

* Go 侧单元测试：`internal/sub/parse_test.go` 覆盖 Clash YAML 及 URI 的 WG / Hy2 / TUIC / ShadowTLS 全量解析。
* 核心校验测试：通过 `sing-box check -c` 验证生成的出站 JSON 符合 sing-box 1.14+ 规范。
* 全量回归测试：`go test -race ./...` 确保全部 pass。
