# Aster

极致轻量的 Apple Silicon（arm64）macOS 原生 **sing-box** 客户端：SwiftUI + AppKit 界面，Go headless 守护进程。

开源分发：ad-hoc 签名的 `.app` / zip，以及可选的 `.pkg` 网络组件安装包。若 Gatekeeper 拦截，请**右键 → 打开**。

## 架构

```
Aster.app (Swift UI)
    │  REST + WebSocket + Bearer token
    ▼
aster-daemon (:1780)
    │  render state → config.json / local helper IPC
    ▼
sing-box (mixed :2080, clash_api :2090)
```

数据目录：`~/Library/Application Support/Aster/`。

## 配置模式与运行边界

- **订阅模式**：导入一个完整的 sing-box JSON（本地 `.json` 快照或 HTTP(S) URL）。Aster 默认原样校验并运行，不自动修改其入站、DNS、路由、出站或 Clash API。只有用户显式绑定配置覆写脚本时，才会运行脚本输出；完整配置的 TUN 由配置自身管理，App 不提供开关。
- **节点模式**：输入多个 HTTP(S) 订阅 URL（一行一个）。Aster 仅提取可用节点，并生成 sing-box 原生入站、DNS、路由、selector 与 urltest。单个来源刷新失败时保留其上次成功节点并显示来源级错误。
- **节点覆写**：节点模式支持受限 JavaScript `transform(nodes, profile)`。覆写必须保留既有节点 ID，因此不能凭空创建没有订阅来源的节点；保存前会渲染并校验候选配置。

配置列表始终只有一个活动项。活动切换与覆写会先校验候选配置；失败时保留原活动配置和原核心。诊断报告仅包含脱敏元数据、运行历史和网络诊断，不包含订阅 URL、配置原文、节点凭据、密钥或覆写源码。

## 平台与权限

仅支持 macOS 14+ Apple Silicon（`darwin/arm64`）。普通系统代理无需特权 helper。启用 TUN 前请安装一次网络组件：`make pkg` 会产出 `build/Aster.pkg`，安装时以管理员权限注册一个 root `launchd` helper；之后 TUN 的启动、停止和重载不会再调用 `osascript` 或重复请求授权。TUN 始终使用 PKG 安装并由 root 管理的内置 sing-box；下载或导入的自定义内核仅适用于普通代理模式。

Helper 不是 SUID 程序：安装脚本记录当前控制台用户 UID，Helper 只接受该用户发出的受限本地 IPC，并只处理固定的 bundled sing-box、root-owned 运行目录和受控 PID。主 UI、Go daemon、订阅解析及 REST/WebSocket 始终以当前用户权限运行。

## 构建

```bash
make test   # Go 测试
make app    # 产出 build/Aster.app 与 build/Aster-macos-*.zip
make pkg    # 产出带一次性网络组件授权的 build/Aster.pkg
make benchmark        # 500 节点渲染、100 活跃连接增量、节流 SQLite 写入与大订阅状态快照基准
make integration-test # 打包后的 500 节点 / 100 并发代理数据路径验证
make run
```

可选环境变量：

| 变量 | 含义 |
|------|------|
| `SING_BOX_VERSION` | 打包时下载的 sing-box 版本（默认 1.14.0） |
| `SING_BOX_BINARY_SHA256` | sing-box 可执行文件的 SHA-256；非默认版本必须提供 |
| `ASTER_DAEMON` | 开发时 UI 拉起的 daemon 路径 |
| `ASTER_API_BASE` | 控制面 base URL |
| `ASTER_DATA_DIR` | 覆盖数据目录（测试用） |

Xcode 工程：`macos-native/Aster.xcodeproj`（调试用）；日常仍可用 `make app`。

## 目录

```
cmd/aster-daemon/     Go 守护进程入口
internal/             api / app / core / render / state / sub / …
macos-native/         Swift 源码与 Xcode 工程
scripts/              打包脚本
vendor/               可复现内核缓存（构建生成）
```

## 许可证

MIT — 见 [LICENSE](LICENSE)。贡献说明见 [CONTRIBUTING.md](CONTRIBUTING.md)。
