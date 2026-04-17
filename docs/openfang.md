# OpenFang 特殊处理

> [!IMPORTANT]
> 本文只记录 OpenFang 相对 [`docs/quadlet.md`](quadlet.md) 的差异；默认 Traefik / autostart / Dotter 规则不在这里重复。

Base docs: [`docs/quadlet.md`](quadlet.md)

## 当前差异

- 运行镜像固定为本地 `localhost/openfang-runtime:trixie`
- `openfang.service` 显式依赖 `openfang-prepare.service`
- 不在容器内单独安装 OpenFang，而是复用宿主机 `~/.local/bin/openfang`
- 容器默认挂载宿主机 `~/.local`、`~/.config`、`~/.cache`
- Traefik 转发端口固定为 `4200`

## 准备阶段

`openfang-prepare.service` 会做两件事：

1. 按当前 CPU 架构从 GitHub Release 下载最新 `openfang-<target>.tar.gz`
2. 若本地镜像不存在，则基于仓库内 `openfang/openfang/Containerfile` 构建 `localhost/openfang-runtime:trixie`

需要强制重建镜像时：

```bash
podman rmi localhost/openfang-runtime:trixie
systemctl --user restart openfang-prepare.service
```

## 可选额外挂载

通过 `openfang.volumes` 追加自定义挂载：

```toml
[variables.openfang]
volumes = [
  "/path/to/data:/data:ro",
  "/path/to/workdir:/workspace:Z",
]
```

## 本地排障记录

若 `openfang.service` 循环重启，且日志同时出现 Telegram bridge 初始化失败，这条记录视为**当前仓库的本地排障经验**，可先禁用 Telegram channel，再重启服务：

```bash
sed -i '/^TELEGRAM_BOT_TOKEN=/d' ~/.config/openfang/secrets.env
systemctl --user reset-failed openfang.service
systemctl --user restart openfang.service
```

## 参考

- <https://github.com/RightNow-AI/openfang>
