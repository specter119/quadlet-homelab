# Quadlet Homelab

通过 [dotter](https://github.com/SuperCuber/dotter) 管理的自托管服务配置，使用 [Podman Quadlet](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html) 生成 systemd 管理的容器服务。

## 服务列表

### 基础设施

| 服务 | 说明 | 文档 |
|------|------|------|
| Tailscale | 远程访问 homelab（Split DNS） | [docs/tailscale.md](docs/tailscale.md) |
| Traefik | 反向代理，统一域名访问，自动 HTTPS | [docs/traefik.md](docs/traefik.md) |
| PostgreSQL | 共享数据库 (pgvector)，供 Langfuse/Plane/Omnivore 使用 | - |
| Garage | 共享 S3 存储，替代各服务独立的 MinIO | - |
| Dozzle | 容器日志查看器 | - |

### 业务服务

| 服务 | 说明 | 文档 |
|------|------|------|
| SilverBullet | 个人知识管理 | - |
| Langfuse | LLM 应用可观测性 | - |
| Omnivore | Read-it-later 阅读服务 | [docs/omnivore.md](docs/omnivore.md) |
| Plane | 项目管理 | - |

## 快速开始

### 前置条件

| 工具 | 用途 |
|------|------|
| podman | 容器运行时 |
| dotter | dotfiles 管理，部署配置文件 |

```bash
# 启用 linger，允许用户服务在登出后继续运行
sudo loginctl enable-linger $USER
```

### 冷启动（新机器）

```bash
# 1. 克隆仓库
git clone <repo-url>
cd quadlet-homelab

# 2. 创建 dotter 本地配置
dotter init  # 按提示配置，设置 domain 变量

# 3. 配置 Traefik（SSL 证书、低端口绑定、hosts）
# 详见 docs/traefik.md

# 4. 部署配置文件（pre_deploy 自动初始化 secrets，post_deploy 触发 daemon-reload）
dotter deploy

# 5. 启动服务
systemctl --user start <service>          # 单容器服务
systemctl --user start <stack>.target     # 多容器服务栈
```

### dotter 常用命令

```bash
dotter deploy           # 部署配置文件到目标位置
dotter undeploy         # 移除已部署的配置文件
dotter diff             # 查看本地与目标的差异
dotter watch            # 监听文件变更自动部署
```

## 常用命令

```bash
# systemctl - 服务管理
systemctl --user start|stop|restart <service>
systemctl --user status <service>

# journalctl - 日志查看
journalctl --user -u <service> -f

# podman - 容器操作
podman ps -a
podman logs <container>

# quadlet - 调试
podman quadlet list
```

更多 Quadlet 配置细节见 [AGENTS.md](./AGENTS.md)。

## 参考文档

- Podman Quadlet: `man podman-systemd.unit`
- systemd: `man systemd.unit`
- dotter: <https://github.com/SuperCuber/dotter>
