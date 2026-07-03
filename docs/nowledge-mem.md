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
- `nowledge-mem-sync-key.service`：`nowledge-mem.service` 启动后由其 `Wants=` 触发，运行 `~/.local/lib/nowledge-mem/sync-key.sh`，从 journal 提取服务每次启动打印的远程访问 API key，幂等地重写 `~/.config/environment.d/nowledge.conf` 并 `systemctl --user import-environment` 刷新会话环境

> [!NOTE]
> 更新检查基于 APT 仓库 `download-mem.nowledge.co` 的实际包版本，而不是上游 CLI 自报版本。

## API Key 同步

`NMEM_API_KEY` 在宿主机被两套机制共同写入 `~/.config/environment.d/nowledge.conf`，二者方向相反、职责互补：

| 路径 | 职责 | 何时写入 | 来源 |
| --- | --- | --- | --- |
| A. Dotter 基线 | 重建/部署基线 | `dotter deploy` 时 | `.dotter/local.toml` 顶层 `[variables]` 的 `nmem_api_key` 模板渲染 |
| B. 运行时同步 | 运行时权威 | 每次 `nowledge-mem.service` 启动后 | `sync-key.sh` 从 journal 提取服务自报 key，原子重写 env 文件 + `import-environment` |

- **运行时同步（B）是权威**：服务每次启动都会用 journal 中的真实 key 覆盖 dotter 基线，因此重启后宿主机 `nmem` CLI 永远拿到当前生效的 key。
- **Dotter 基线（A）是冷启动兜底**：当服务器从未启动过、journal 里还没有 key 时，dotter 渲染基线保证 env 文件存在、宿主机 CLI 有可用的初始值。两条都写 `~/.config/environment.d/nowledge.conf` 为普通文件（template 渲染，非符号链接），字节一致、互不冲突：`dotter deploy` 在 sync 覆盖后仍幂等（不加 `--force` 不报错）。

### Key 流向与 secret 机制的区分

本仓库里 secret 有 **两个相反的流向**，不能混用机制：

- **Podman secret（`.dotter/secrets/*.conf` + Quadlet `Secret=`）**：容器 **消费**的输入依赖（数据库密码、上游 API token）。容器通过 `Secret=` 挂载读取。
- **`NMEM_API_KEY`**：方向相反。它由 nowledge-mem 容器在初始化时 **生产**（自动生成、哈希存于 `remote-access.json`），供 **容器外部** 的宿主机 `nmem` CLI 通过 systemd user env 消费。它不是容器的输入依赖，因此 **不能**走 podman `Secret=`。

因此把 `nmem_api_key` 放进 `.dotter/local.toml` 是「敏感值不要放进 `local.toml`」这条 dotter 约定的 **有正当理由的例外**：该规则推荐的替代手段（Quadlet `Secret=`）在语义上是错的（这是输出不是输入）。例外只在「容器生产、供宿主机 CLI 消费」的输出型 key 上成立，详见 [`docs/dotter.md`](dotter.md) 中的 NOTE。

## 参考

- <https://mem.nowledge.co/docs/zh/server-deployment>
- <https://nowledge-co.github.io/community/apt/install.sh>
