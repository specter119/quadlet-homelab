# Nowledge Mem 特殊处理

> [!IMPORTANT]
> 本文只记录 Nowledge Mem 相对 [`docs/quadlet.md`](quadlet.md) 的额外处理；应用内 license、provider 等初始化遵循上游 CLI 文档，不在这里展开。

Base docs: [`docs/quadlet.md`](quadlet.md)

## 当前差异

- 服务直接运行官方镜像 `docker.io/nowledgelabs/mem`（`Pull=newer`），镜像入口即 `nmem-server`，默认监听 `0.0.0.0:14242`，无需 `Exec=` 覆盖
- `UserNS=keep-id:uid=10001,gid=10001`：官方镜像以 `nowledge`（uid 10001）运行。裸 `keep-id` 只映射宿主 uid 1000，容器内进程 uid 10001 落入映射外，写挂载卷会报 `Permission denied (os error 13)` / `Storage ownership admission refused`，必须显式指定
- Traefik 暴露入口为 `https://nowledge-mem.<domain>/app`，根路径会被重写到 `/app`

## 持久化目录

容器内布局跟随官方镜像（`XDG_CONFIG_HOME=/etc/nowledge-mem`、`NMEM_APP_DATA=/var/lib/nowledge-mem/NowledgeGraph`、`XDG_CACHE_HOME=/var/cache/nowledge-mem`），宿主侧路径保持以下约定，不随镜像切换迁移数据：

- `~/.config/co.nowledge.mem.desktop` → `/etc/nowledge-mem/co.nowledge.mem.desktop`
- `~/.local/share/NowledgeGraph` → `/var/lib/nowledge-mem/NowledgeGraph`
- `~/.cache/nowledge-graph` → `/var/cache/nowledge-mem`
- `~/.cache/huggingface` → `/var/cache/nowledge-mem/huggingface`（子挂载覆盖）

> [!WARNING]
> 不要只保留配置目录。记忆数据库、索引和模型缓存都在上述目录里，删错会导致重新下载模型或丢失数据。

## 辅助 systemd 单元

- `nowledge-mem-certifi-sync.path` / `.service`：保证宿主机 `nmem` CLI 信任 Traefik 证书。新版 `nmem-cli`（≥0.10.x）是原生 Rust ELF 二进制，不使用 python certifi；脚本检测到 ELF 后只验证 mkcert root CA 是否已装入**系统 CA 库**，缺失时按发行版打印安装命令（Debian/Ubuntu：`update-ca-certificates`；Arch：`update-ca-trust` 装到 `/etc/ca-certificates/trust-source/anchors/`）。**不注入任何 `SSL_CERT_FILE` 环境变量**（这类全局变量会污染所有 Rust/Go CLI 的证书验证）
- `nowledge-mem-sync-key.service`：`nowledge-mem.service` 启动后由其 `Wants=` 触发，运行 `~/.local/lib/nowledge-mem/sync-key.sh`（见下文「API Key 同步」）

> [!IMPORTANT]
> 切换到官方镜像后，本地镜像构建与更新检查机制（`nowledge-mem-prepare.service`、`nowledge-mem-check-update.service/.timer`、`prepare-image.sh`、`check-update.sh`、`Containerfile`）已整体移除。

## API Key 同步

两条写入 `~/.config/environment.d/nowledge.conf` 的路径方向相反、职责互补：

| 路径           | 职责          | 何时写入                           | 来源                                                                                |
| -------------- | ------------- | ---------------------------------- | ----------------------------------------------------------------------------------- |
| A. Dotter 基线 | 重建/部署基线 | `dotter deploy` 时                 | `.dotter/local.toml` 顶层 `[variables]` 的 `nmem_api_key` 模板渲染                  |
| B. 运行时同步  | 运行时权威    | 每次 `nowledge-mem.service` 启动后 | `sync-key.sh` 从 journal 提取服务自报 key，原子重写 env 文件 + `import-environment` |

> [!WARNING]
> 官方镜像的 `nmem-server` **不再把 API key 明文打印到启动日志**（key 以加密形式存于 `~/.config/co.nowledge.mem.desktop/remote-access.json` 的 `api_key_enc` 字段）。因此路径 B 的 journal 提取在当前镜像下失效，`sync-key.sh` 恒为 no-op，env 里的 key 停留在 Dotter 基线值。
> 当前基线 key 仍然有效（`nmem doctor` 的 authenticated probe 通过），宿主机 `nmem` CLI 可用；**只有服务轮换 key 后** env 才会过期，届时需将 key 同步来源改为解密 `remote-access.json` 或上游文档提供的其他方式（见下方参考链接），再更新 `sync-key.sh`。

### Key 流向与 secret 机制的区分

本仓库里 secret 有 **两个相反的流向**，不能混用机制：

- **Podman secret（`.dotter/secrets/*.conf` + Quadlet `Secret=`）**：容器 **消费**的输入依赖（数据库密码、上游 API token）。容器通过 `Secret=` 挂载读取。
- **`NMEM_API_KEY`**：方向相反。它由 nowledge-mem 容器在初始化时 **生产**（自动生成、哈希存于 `remote-access.json`），供 **容器外部** 的宿主机 `nmem` CLI 通过 systemd user env 消费。它不是容器的输入依赖，因此 **不能**走 podman `Secret=`。

因此把 `nmem_api_key` 放进 `.dotter/local.toml` 是「敏感值不要放进 `local.toml`」这条 dotter 约定的 **有正当理由的例外**：该规则推荐的替代手段（Quadlet `Secret=`）在语义上是错的（这是输出不是输入）。例外只在「容器生产、供宿主机 CLI 消费」的输出型 key 上成立，详见 [`docs/dotter.md`](dotter.md) 中的 NOTE。

## 参考

- <https://mem.nowledge.co/docs/zh/server-deployment>
- <https://github.com/wey-gu/mem-releases>（官方镜像来源）
