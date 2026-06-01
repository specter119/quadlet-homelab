# Quadlet 配置指南

> [!IMPORTANT]
> 本文定义项目里的默认 Quadlet 模板。若某个服务只是套用这里的默认模式，不要在 `docs/<service>.md` 重复抄写；服务文档只记录偏离默认模板的差异。

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
\{{#if (command_success "timedatectl show -p Timezone --value")}}
Environment=TZ=\{{command_output "timedatectl show -p Timezone --value"}}
\{{/if}}
Image=<image>
# Pull=newer
Network=traefik.network

# Dozzle group
Label=dev.dozzle.group=quadlet

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

\{{#if (contains autostart_services "<service>")}}
[Install]
WantedBy=default.target
\{{/if}}
```

**说明**：

- `<service>`: 服务名，如 `dozzle`, `silverbullet`
- `<port>`: 容器内部端口，如 `8080`, `3000`
- `DefaultDependencies=false`: 仅在 WSL 环境下添加，禁用 Quadlet 默认的网络依赖避免启动超时
- `domain`: Dotter 共享变量，默认值与本机覆盖规则见 [docs/dotter.md](dotter.md)
- `autostart_services`: 自启动服务列表，在 `.dotter/local.toml` 的 `[variables]` 中设置，使用自定义 `contains` helper 判断
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

> [!NOTE]
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

### 依赖就绪门禁（排障）

当遇到“依赖服务已启动，但应用仍连接失败”的冷启动时序问题（例如 `connection refused`）时，可尝试在 `[Service]` 增加 health gate：

```ini
[Service]
Type=oneshot
RemainAfterExit=yes
Restart=on-failure
RestartSec=2s
ExecStartPre=/usr/bin/podman healthcheck run systemd-postgres
```

前提是被依赖服务已配置 `HealthCmd=`（例如 `postgres.container`）。

> [!TIP]
> 该做法适合 `initdb`、`migrate` 这类一次性初始化任务。若当前服务未出现就绪时序问题，可先保持现状。

参考：

- <https://hub.docker.com/_/postgres>
- <https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-envvars.html>
- <https://docs.aws.amazon.com/sdkref/latest/guide/feature-endpoints.html>

## Volume 规范

### 默认不创建 log volume

容器日志输出到 stdout/stderr，由 Podman journald 驱动统一管理。

- 查看日志：`journalctl --user -u <service> -f` 或使用 Dozzle Web UI
- 日志持久化、轮转由 systemd-journald 处理

```ini
# ❌ 不推荐 - 日志不需要持久化
Volume=xxx-logs.volume:/var/log/xxx

# ✅ 正确 - 只持久化数据
Volume=xxx-data.volume:/var/lib/xxx
```

**例外情况**（需要单独 log volume）：

1. 日志内容与 stdout 不同（如应用写入特定格式的审计日志）
2. 日志量极大且需要独立管理（如数据库查询日志）
3. 第三方工具需要读取日志文件（如日志分析器）

若无上述情况，**禁止创建 log volume**，避免数据重复和磁盘浪费。

## Label 规范

### 特殊字符必须加引号

```ini
# ❌ 错误 - 特殊字符后的内容会被截断
Label=traefik.http.routers.xxx.rule=Host(`a.com`) && PathPrefix(`/path`)

# ✅ 正确 - 双引号保护完整值
Label=traefik.http.routers.xxx.rule="Host(`a.com`) && PathPrefix(`/path`)"
```

## 非 HTTP 端口通过 Traefik 代理（OTLP / 专用协议）

当服务暴露非标准 HTTP(S) 端口（如 OTLP、gRPC、SSH、纯 API 等——只要不是浏览器访问的 UI 服务）时，不要用 `PublishPort` 直接绑主机端口，也不要分配独立域名。那样绕过 Traefik，无法按域名路由，也无法与其他服务复用端口。

两类做法：

1. **协议不同（OTLP、gRPC、SSH 等）** → 自定义 EntryPoint，见下方模式
2. **HTTP API 但无 UI**（如 GraphQL API）→ 不暴露独立域名，通过主服务的路径前缀路由

> [!NOTE]
> 浏览器端直调的 API（如 Omnivore 的 `omnivore-api`）仍需独立域名，不在上述第 2 条范畴。

### 模式：自定义 EntryPoint + 路由

以 Jaeger OTLP HTTP（端口 4318）为例：

**1. 在 Traefik 添加 EntryPoint**

`traefik/traefik/traefik.toml`：

```toml
[entryPoints.otlp-http]
address = ":4318"
```

**2. 创建 systemd socket unit**

`traefik/systemd/user/otlp-http.socket`：

```ini
[Socket]
ListenStream=4318
FileDescriptorName=otlp-http
Service=traefik.service

[Install]
WantedBy=sockets.target
```

**3. 在 Traefik 容器声明 socket 依赖**

`traefik/containers/systemd/traefik.container`：

```ini
[Unit]
After=http.socket https.socket otlp-http.socket podman.socket
Requires=http.socket https.socket otlp-http.socket podman.socket

[Service]
Sockets=http.socket https.socket otlp-http.socket
```

**4. 在业务容器添加 Traefik 路由 labels**

```ini
# OTLP HTTP — 走自定义 entrypoint
Label=traefik.http.routers.jaeger-otlp.entrypoints=otlp-http
Label=traefik.http.routers.jaeger-otlp.rule=Host(`jaeger.{{domain}}`)
Label=traefik.http.routers.jaeger-otlp.service=jaeger-otlp
Label=traefik.http.services.jaeger-otlp.loadbalancer.server.port=4318
```

> [!IMPORTANT]
> 当同一容器有多个 Traefik service 时（如 Jaeger 同时有 UI 的 `jaeger` 和 OTLP 的 `jaeger-otlp`），**每个 router 必须显式指定 `service` label**，否则 Traefik 无法自动关联，router 会被忽略。

### 对比：不要用 PublishPort

```ini
# ❌ 绕过 Traefik，无法按域名路由，端口冲突风险
PublishPort=4318:4318

# ✅ 通过 Traefik entrypoint 代理，支持域名路由和端口复用
Label=traefik.http.routers.xxx-otlp.entrypoints=otlp-http
Label=traefik.http.routers.xxx-otlp.rule=Host(`xxx.{{domain}}`)
Label=traefik.http.routers.xxx-otlp.service=xxx-otlp
Label=traefik.http.services.xxx-otlp.loadbalancer.server.port=4318
```

## 参考命令

| 主题                               | 命令                      |
| ---------------------------------- | ------------------------- |
| Quadlet 参数                       | `man podman-systemd.unit` |
| systemd 单元（specifiers、依赖等） | `man systemd.unit`        |
