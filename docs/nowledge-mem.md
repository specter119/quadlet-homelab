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

## 镜像构建

镜像构建时会按官方 APT 安装方式执行：

```bash
curl -fsSL https://nowledge-co.github.io/community/apt/install.sh | bash
apt-get install -y nowledge-mem
```

首次启动 `nowledge-mem.service` 前，会先由 `nowledge-mem-prepare.service` 构建本地镜像。

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

## 远程访问

本地配置把 `nmem serve` 绑定到 `0.0.0.0`，因此经 Traefik 暴露后，其他设备访问时会要求 API key。

如果只想查看当前 key：

```bash
podman exec -it systemd-nowledge-mem nmem key
```

> [!IMPORTANT]
> 数据库和搜索索引默认位于 `~/.local/share/NowledgeGraph`。不要只保留配置目录，否则容器重建后会丢失记忆数据。

## 参考

- <https://mem.nowledge.co/docs/zh/server-deployment>
- <https://nowledge-co.github.io/community/apt/install.sh>
