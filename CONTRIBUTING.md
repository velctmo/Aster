# Contributing to Aster

## 开发环境

- macOS 14+
- Go 1.22+
- Xcode / Swift 5.9+（可用 `swiftc`）

## 常用命令

```bash
make test   # Go 单测
make build  # 仅编译二进制到 bin/
make app    # 可复现打包 build/Aster.app + zip
make benchmark        # 500 节点渲染及 100 活跃连接增量基准
make integration-test # 使用打包内核验证 500 节点 / 100 并发代理
make run    # 打包并打开
make stop   # 结束 Aster / aster-daemon
```

开发时可不打包 UI，单独跑守护进程：

```bash
go build -o bin/aster-daemon ./cmd/aster-daemon
export ASTER_DAEMON="$PWD/bin/aster-daemon"
# 可选：ASTER_DATA_DIR=/tmp/aster-dev
```

## 架构约定

- UI（Swift）只通过本机 Unix socket（`daemon.sock`）REST/WS 访问 daemon
- 写操作需 `Authorization: Bearer <apiToken>`（token 仅保存在 `~/Library/Application Support/Aster/machine.json`）
- `GET /api/v1/status` 保持公开，用于健康检查与单实例探测
- 状态目录：`~/Library/Application Support/Aster/`
  - `settings.json`：可迁移的全局偏好、当前配置与配置清单
  - `profiles/`、`scripts/`、`rules.json`：可迁移的订阅、节点、脚本与规则
  - `machine.json`：仅本机的端口、权限状态、内核路径、API token 与运行记录，绝不备份

## PR 建议

- 改动控制面时补 `go test`
- 避免硬编码本机绝对路径
- 不要提交 `bin/`、`build/` 或本机 Aster 状态目录中的任何文件
