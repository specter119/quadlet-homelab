# Quadlet 配置指南

## 文件类型

| 扩展名       | 用途       | 部署位置                        |
| ------------ | ---------- | ------------------------------- |
| `.container` | 容器定义   | `~/.config/containers/systemd/` |
| `.volume`    | 命名卷定义 | `~/.config/containers/systemd/` |
| `.network`   | 网络定义   | `~/.config/containers/systemd/` |
| `.target`    | 服务组     | `~/.config/systemd/user/`       |

## 命名规范

**保持简洁，让 Quadlet 自动命名**。Quadlet 生成的资源会自动加 `systemd-` 前缀，便于区分。

| 资源类型        | 是否指定名称 | 说明                           |
| --------------- | ------------ | ------------------------------ |
| `ContainerName` | ❌ 不指定    | 自动生成 `systemd-<filename>`  |
| `VolumeName`    | ❌ 不指定    | 自动生成 `systemd-<filename>`  |
| `NetworkName`   | ❌ 不指定    | 自动生成 `systemd-<filename>`  |
| `NetworkAlias`  | ✅ 按需指定  | 服务栈内被其他容器访问时才需要 |

**例外**：`NetworkAlias` 用于容器间通信的 DNS 别名，只有需要被访问的容器才指定（如数据库、Redis），主动访问其他服务的容器（如 Web、Worker）无需设置。

## 网络架构

```
traefik.network     ← 需要域名代理的容器（web 入口）
langfuse.network    ← langfuse 栈内部通信
omnivore.network    ← omnivore 栈内部通信
plane.network       ← plane 栈内部通信
```

**设计原则**：

- `traefik.network`：只有需要被 Traefik 代理的容器加入
- 业务子网：栈内部通信，worker/redis 等不暴露到代理网络
- `postgres/garage`：通过 `render_networks.sh` 动态加入依赖它们的业务子网，不加入 traefik.network

**示例**：langfuse-web 加入两个网络（被代理 + 栈内部），langfuse-worker 只加入栈内部网络。

## 自启动

Quadlet 文件由 generator 生成，**不能用 `systemctl enable`**。
自启动通过 `[Install] WantedBy=...` 配置，`daemon-reload` 时自动生效。

## 单容器服务模板

```ini
[Unit]
Description=<Service Description>
After=traefik.service
Wants=traefik.service

# WSL 环境：禁用网络依赖，避免启动超时
\{{#if (command_success "uname -r | grep -qi wsl")}}
[Quadlet]
DefaultDependencies=false

\{{/if}}
[Service]
Restart=always

[Container]
Image=<image>
# Pull=newer
Network=traefik.network

# Traefik labels - 启用发现
Label=traefik.enable=true
Label=traefik.docker.network=systemd-traefik

# HTTP -> HTTPS 重定向
Label=traefik.http.routers.<service>-http.entrypoints=http
Label=traefik.http.routers.<service>-http.rule=Host(`<service>.{{domain}}`)
Label=traefik.http.routers.<service>-http.middlewares=redir-https@file
Label=traefik.http.routers.<service>-http.service=noop@internal

# HTTPS 路由
Label=traefik.http.routers.<service>-https.entrypoints=https
Label=traefik.http.routers.<service>-https.rule=Host(`<service>.{{domain}}`)
Label=traefik.http.routers.<service>-https.tls=true
Label=traefik.http.routers.<service>-https.middlewares=gzip@file
Label=traefik.http.services.<service>.loadbalancer.server.port=<port>

[Install]
WantedBy=default.target
```

**说明**：

- `<service>`: 服务名，如 `dozzle`, `silverbullet`
- `<port>`: 容器内部端口，如 `8080`, `3000`
- `DefaultDependencies=false`: 仅在 WSL 环境下添加，禁用 Quadlet 默认的网络依赖避免启动超时
- `redir-https@file`, `gzip@file`: 引用 `middlewares.toml` 中定义的共享中间件
- `noop@internal`: Traefik 内置空服务，用于重定向场景

**可选配置**：

- `Pull=newer`: 启动时检查镜像更新，有新版本自动拉取（适合追 latest 的服务）

## 多容器服务栈

当服务需要数据库等辅助容器时，涉及：容器编排、容器间通信。

### 容器编排

使用 `.target` 统一管理多个容器。

**容器文件配置**：

```ini
[Unit]
PartOf=<service>.target      # 随 target 一起 stop/restart

[Install]
WantedBy=<service>.target    # 随 target 一起 start（自启动关键）
```

**Target 文件** (`<service>.target`)：

```ini
[Unit]
Description=<Service> Stack

# 可选：若需整个栈随系统自启动，添加以下配置
[Install]
WantedBy=default.target
```

> `.target` 放在 `~/.config/systemd/user/`，不是 `containers/systemd/`。

### 容器间通信

使用 `NetworkAlias` 提供 DNS 别名，让其他容器通过短名称访问：

```ini
# 数据库容器 - 需要被其他容器访问，提供短别名
NetworkAlias=postgres

# Web 容器 - 只访问其他服务，无需 alias
```

### 基础服务依赖（Postgres / S3）

**有依赖就必须显式声明**。判断依据是环境变量中是否出现对应连接信息：

- Postgres：`PGHOST=postgres`、`PG_HOST=postgres`、`POSTGRES_USER=...`、`POSTGRES_DB=...`、`POSTGRES_PASSWORD=...`、
  `POSTGRES_PORT=5432`、`DATABASE_URL=postgresql://...@postgres:5432/...`
- S3/Garage：`AWS_S3_ENDPOINT_URL=http://garage:3900`、`LOCAL_MINIO_URL=http://garage:3900`、
  `AWS_ENDPOINT_URL=...garage...`、`S3_ENDPOINT=...garage...`、`MINIO_ENDPOINT=...garage...`

当容器配置包含上述变量时，必须在 `[Unit]` 中显式添加依赖：

```ini
Requires=postgres.service
After=postgres.service

Requires=garage.service
After=garage.service
```

参考：

- <https://hub.docker.com/_/postgres>
- <https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-envvars.html>
- <https://docs.aws.amazon.com/sdkref/latest/guide/feature-endpoints.html>

## 参考命令

| 主题                               | 命令                      |
| ---------------------------------- | ------------------------- |
| Quadlet 参数                       | `man podman-systemd.unit` |
| systemd 单元（specifiers、依赖等） | `man systemd.unit`        |
