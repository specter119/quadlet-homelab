# Nowledge Mem 无头部署

## 必要信息

- 运行镜像：`localhost/nowledge-mem-runtime:trixie`（基于 `debian:trixie-slim`）
- 运行服务：`nowledge-mem.service`（依赖 `nowledge-mem-prepare.service`）
- 后端命令：`nmem serve --host 0.0.0.0 --port 14242`
- Web 入口：`https://nowledge-mem.<domain>/app`
- 宿主持久化目录：
  - `~/.config/co.nowledge.mem.desktop`
  - `~/.local/share/NowledgeGraph`
  - `~/.cache/nowledge-graph`
  - `~/.cache/huggingface/hub`

## 镜像构建

镜像构建时会按官方 APT 安装方式执行：

```bash
curl -fsSL https://nowledge-co.github.io/community/apt/install.sh | bash
apt-get install -y nowledge-mem
```

首次启动 `nowledge-mem.service` 前，会先由 `nowledge-mem-prepare.service` 构建本地镜像。

若宿主机使用 `uv` 安装的 `nmem-cli`，仓库还会部署一个用户级 watcher：

- `nowledge-mem-certifi-sync.path`
- `nowledge-mem-certifi-sync.service`

它们现在作为 `nowledge-mem` 的一部分一起部署：

- `dotter deploy` 后会自动 `enable --now nowledge-mem-certifi-sync.path`
- 若 `nowledge-mem.service` 当时已在运行，会立刻触发一次 `nowledge-mem-certifi-sync.service`
- 后续每次 `nowledge-mem.service` 启动时，也会补跑一次同步
- 若检测到 `~/.local/share/uv/tools/nmem-cli/uv-receipt.toml` 变化，也会再次同步

同步逻辑会把 `https://nowledge-mem.<domain>` 当前返回的证书链补进该 tool 环境的
`certifi` bundle，避免 `nmem status` 因自签名证书报 `CERTIFICATE_VERIFY_FAILED`。

需要强制重建并拉取新版包时：

```bash
podman rmi localhost/nowledge-mem-runtime:trixie
systemctl --user restart nowledge-mem-prepare.service
systemctl --user restart nowledge-mem.service
```

## 初始化步骤

启动服务：

```bash
systemctl --user start nowledge-mem.service
```

确认服务已经起来：

```bash
podman exec -it systemd-nowledge-mem nmem status
```

激活许可证：

```bash
podman exec -it systemd-nowledge-mem nmem license activate <key> [email]
```

下载搜索索引模型：

```bash
podman exec -it systemd-nowledge-mem nmem models download
```

配置并测试 LLM provider：

```bash
podman exec -it systemd-nowledge-mem nmem config provider set <provider> --api-key <key>
podman exec -it systemd-nowledge-mem nmem config provider test
```

打印当前登录地址和 API key：

```bash
podman exec -it systemd-nowledge-mem nmem key --show-login
```

如果宿主机的 `nmem status` 仍然报证书错误，可手动触发一次同步：

```bash
systemctl --user start nowledge-mem-certifi-sync.service
```

## 远程访问

本地配置把 `nmem serve` 绑定到 `0.0.0.0`，因此经 Traefik 暴露后，其他设备访问时会要求 API key。

如果只想查看当前 key：

```bash
podman exec -it systemd-nowledge-mem nmem key
```

> [!IMPORTANT]
> 数据库和搜索索引默认位于 `~/.local/share/NowledgeGraph`，嵌入模型缓存当前位于 `~/.cache/huggingface/hub`。
> 不要只保留配置目录，否则容器重建后会丢失记忆数据，且 `bge-m3` 之类的模型会被重新下载。

## 参考

- <https://mem.nowledge.co/docs/zh/server-deployment>
- <https://nowledge-co.github.io/community/apt/install.sh>
