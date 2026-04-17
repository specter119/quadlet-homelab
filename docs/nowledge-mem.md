# Nowledge Mem 特殊处理

> [!IMPORTANT]
> 本文只记录 Nowledge Mem 相对 [`docs/quadlet.md`](quadlet.md) 的额外处理；应用内 license、provider 等初始化遵循上游 CLI 文档，不在这里展开。

Base docs: [`docs/quadlet.md`](quadlet.md)

## 当前差异

- 服务运行本地镜像 `localhost/nowledge-mem-runtime:trixie`，而不是直接拉远端镜像
- `nowledge-mem.service` 显式依赖 `nowledge-mem-prepare.service`
- 容器入口固定为 `nmem serve --host 0.0.0.0 --port 14242`
- Traefik 暴露入口为 `https://nowledge-mem.<domain>/app`，根路径会被重写到 `/app`

## 本地镜像构建

`nowledge-mem-prepare.service` 会执行仓库内的 `prepare-image.sh`，按官方 APT 安装方式构建运行镜像：

```bash
curl -fsSL https://nowledge-co.github.io/community/apt/install.sh | bash
apt-get install -y nowledge-mem
```

需要强制重建时：

```bash
podman rmi localhost/nowledge-mem-runtime:trixie
systemctl --user restart nowledge-mem-prepare.service
systemctl --user restart nowledge-mem.service
```

## 持久化目录

以下目录是当前模板里的默认持久化路径：

- `~/.config/co.nowledge.mem.desktop`
- `~/.local/share/NowledgeGraph`
- `~/.cache/nowledge-graph`
- `~/.cache/huggingface/hub`

> [!WARNING]
> 不要只保留配置目录。记忆数据库、索引和模型缓存都在上述目录里，删错会导致重新下载模型或丢失数据。

## 辅助 systemd 单元

- `nowledge-mem-prepare.service`：构建或刷新本地运行镜像
- `nowledge-mem-check-update.service` / `.timer`：按 APT 仓库版本检查并重建新镜像
- `nowledge-mem-certifi-sync.path` / `.service`：当宿主机 `uv` 安装的 `nmem-cli` 变化时，同步 `https://nowledge-mem.<domain>` 的证书链到对应 `certifi` bundle

> [!NOTE]
> 更新检查基于 APT 仓库 `download-mem.nowledge.co` 的实际包版本，而不是上游 CLI 自报版本。

## 参考

- <https://mem.nowledge.co/docs/zh/server-deployment>
- <https://nowledge-co.github.io/community/apt/install.sh>
