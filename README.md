# Quadlet Homelab

通过 [dotter](https://github.com/SuperCuber/dotter) 管理的自托管服务配置，使用 [Podman Quadlet](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html) 生成 systemd 管理的容器服务。

> [!NOTE]
> `README.md` 只保留服务简介，通用维护流程、冷启动步骤与文档分工统一放在 [AGENTS.md](AGENTS.md)。

## 服务列表

### 基础服务

| 服务         | 说明                                                   |
| ------------ | ------------------------------------------------------ |
| Tailscale    | 远程访问 homelab（Split DNS）                          |
| Traefik      | 反向代理，统一域名访问，自动 HTTPS                     |
| PostgreSQL   | 共享数据库 (pgvector)，供 Langfuse/Plane/Omnivore 使用 |
| Garage       | 共享 S3 存储，替代各服务独立的 MinIO                   |
| Dozzle       | 容器日志查看器                                         |

### 业务服务

| 服务         | 说明                                                |
| ------------ | --------------------------------------------------- |
| SilverBullet | 个人知识管理                                        |
| Langfuse     | LLM 应用可观测性                                    |
| Omnivore     | Read-it-later 阅读服务                              |
| Plane        | 项目管理                                            |
| Copyparty    | 文件共享服务                                        |
| Marimo       | Python 交互式 Notebook                              |
| LunaTV       | 影视聚合播放器                                      |
| Unsloth      | GPU Notebook / LLM 实验环境                         |
| Multica      | AI Agent 协作看板与 Runtime 管理平台                |
| Nowledge Mem | 个人记忆与上下文管理服务（容器内运行 `nmem serve`） |
| Qoder Proxy  | OpenAI 兼容的 Qoder CLI API 代理（含 Dashboard）    |
| Phoenix      | LLM tracing / eval 可观测性，承接 OTLP trace 接入   |
| DeepSeek Harness | DeepSeek AI Agent Web UI                           |

## 文档入口

- 文档契约、冷启动与维护入口：[`AGENTS.md`](AGENTS.md)
- Quadlet 默认模板：[`docs/quadlet.md`](docs/quadlet.md)
- Dotter 变量契约：[`docs/dotter.md`](docs/dotter.md)
- Secrets 与 hook 约定：[`docs/secrets.md`](docs/secrets.md)、[`docs/hooks.md`](docs/hooks.md)
- 基础设施配置：[`docs/traefik.md`](docs/traefik.md)、[`docs/tailscale.md`](docs/tailscale.md)
- 仅当服务存在额外处理时，再查看 `docs/<service>.md`

## 参考文档

- Podman Quadlet: `man podman-systemd.unit`
- systemd: `man systemd.unit`
- dotter: <https://github.com/SuperCuber/dotter>
