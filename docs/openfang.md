# OpenFang 本地部署

## 必要信息

- 不在容器内编译 OpenFang，直接复用宿主机二进制：`~/.local/bin/openfang`
- 运行镜像：`localhost/openfang-runtime:trixie`（基于 `debian:trixie`）
- 运行服务：`openfang.service`（依赖 `openfang-prepare.service`）
- 默认挂载：`~/.local`、`~/.config`、`~/.cache`
- Traefik 转发端口：`4200`

## 构建运行镜像

```bash
podman build -t localhost/openfang-runtime:trixie -f openfang/openfang/Containerfile openfang/openfang
```

## 服务行为

- 启动 `openfang.service` 时，会先执行 `openfang-prepare.service`
  - 先按 Linux 架构从 GitHub Release 下载最新 `openfang-<target>.tar.gz`
  - 同步到宿主机 `~/.local/bin/openfang`（容器挂载复用该 binary）
- 仅当本地不存在 `localhost/openfang-runtime:trixie` 时才会 build
- 需要强制重建时，先删除本地镜像再重启 `openfang-prepare.service`

```bash
podman rmi localhost/openfang-runtime:trixie
systemctl --user restart openfang-prepare.service
```

## 额外挂载（可选）

通过 `openfang.volumes` 添加额外挂载，格式与 marimo 一致：

```toml
[variables.openfang]
volumes = [
  "/path/to/data:/data:ro",
  "/path/to/workdir:/workspace:Z",
]
```

## 常见故障

> [!NOTE]
> 截至当前版本 `openfang 0.3.17`，OpenFang 尚不支持通过 WebSocket 连接飞书 channel。国内 IM 可用性目前不够高，因此暂不启用，后续视 OpenFang 能力演进再评估开启。

### `openfang.service` 循环重启（`Another daemon ... 4200`）

若日志同时出现 Telegram bridge 连接失败（例如 `Failed to start telegram bridge`），可先禁用 Telegram channel：

```bash
# 1) 删除 telegram token（宿主机）
sed -i '/^TELEGRAM_BOT_TOKEN=/d' ~/.config/openfang/secrets.env

# 2) 移除 telegram channel 配置段（宿主机）
# 编辑 ~/.config/openfang/config.toml，删除 [channels.telegram] 段

# 3) 重启服务
systemctl --user reset-failed openfang.service
systemctl --user restart openfang.service
```

## 参考

- <https://github.com/RightNow-AI/openfang>
