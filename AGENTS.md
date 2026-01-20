# AGENTS.md

## 文档分工

| 文档       | 读者      | 内容                                           |
| ---------- | --------- | ---------------------------------------------- |
| README.md  | 用户      | 项目简介、服务列表、冷启动、常用命令           |
| AGENTS.md  | 开发者/AI | 新建服务流程、Quadlet 规范、模板、Secrets 管理 |
| docs/\*.md | 开发者/AI | 特定服务的详细配置（如 Traefik SSL、路由规则） |

### docs/\*.md 维护规范

修改服务文档前，**必须先查阅官方文档**验证配置是否过时：

1. 检查文档末尾「参考」章节的官方链接
2. 对比本地配置与官方最新推荐
3. 移除已废弃的配置方式，只保留当前推荐做法

## 新建服务检查清单

每次新建微服务时，必须完成以下步骤：

1. **创建服务目录结构**

   ```plain
   <service>/
   └── containers/systemd/
       └── <service>.container
   ```

2. **更新 `.dotter/global.toml`** - 添加部署配置

   ```toml
   [<service>.files]
   <service> = '~/.config'
   ```

3. **更新 `.dotter/local.toml`** - 启用新服务

   ```toml
   packages = ["traefik", "dozzle", "silverbullet",  "<service>"]
   ```

4. **更新 `README.md`** - 服务列表添加新服务

5. **更新 `docs/traefik.md`** - hosts 临时配置添加新域名

6. **配置 Traefik labels** - 在 .container 文件中添加（见下方模板）

## Quadlet 基础

### 文件类型

| 扩展名       | 用途       | 部署位置                        |
| ------------ | ---------- | ------------------------------- |
| `.container` | 容器定义   | `~/.config/containers/systemd/` |
| `.volume`    | 命名卷定义 | `~/.config/containers/systemd/` |
| `.network`   | 网络定义   | `~/.config/containers/systemd/` |
| `.target`    | 服务组     | `~/.config/systemd/user/`       |

### 命名规范

**保持简洁，让 Quadlet 自动命名**。Quadlet 生成的资源会自动加 `systemd-` 前缀，便于区分。

| 资源类型        | 是否指定名称 | 说明                           |
| --------------- | ------------ | ------------------------------ |
| `ContainerName` | ❌ 不指定    | 自动生成 `systemd-<filename>`  |
| `VolumeName`    | ❌ 不指定    | 自动生成 `systemd-<filename>`  |
| `NetworkName`   | ❌ 不指定    | 自动生成 `systemd-<filename>`  |
| `NetworkAlias`  | ✅ 按需指定  | 服务栈内被其他容器访问时才需要 |

**例外**：`NetworkAlias` 用于容器间通信的 DNS 别名，只有需要被访问的容器才指定（如数据库、Redis），主动访问其他服务的容器（如 Web、Worker）无需设置。

### 自启动

Quadlet 文件由 generator 生成，**不能用 `systemctl enable`**。
自启动通过 `[Install] WantedBy=...` 配置，`daemon-reload` 时自动生效。

### 注意事项

**默认不创建 log volume**：

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

**Label 值特殊字符必须加引号**：

```ini
# ❌ 错误 - 特殊字符后的内容会被截断
Label=traefik.http.routers.xxx.rule=Host(`a.com`) && PathPrefix(`/path`)

# ✅ 正确 - 双引号保护完整值
Label=traefik.http.routers.xxx.rule="Host(`a.com`) && PathPrefix(`/path`)"
```

## 单容器服务模板

新服务 `.container` 文件模板：

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
Restart=unless-stopped

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

当服务需要数据库等辅助容器时，涉及：容器编排、容器间通信、Secrets 管理。

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

### Secrets 管理

使用 **Podman Secret** 管理敏感配置，密钥存储在本地，不进 git。

> **触发条件**：当 `.container` 文件中发现明文密码/密钥时，应提取到 `.dotter/secrets/<service>.conf`，改用 `Secret=` 引用。

#### 文件结构

```
.dotter/
├── secrets/
│   ├── langfuse.conf         # 密钥定义，提交 git
│   ├── plane.conf
│   └── omnivore.conf
├── pre_deploy.sh             # 部署前初始化 secrets
└── post_deploy.sh            # 部署后 daemon-reload
```

> **为什么放在 `.dotter/secrets/`**：dotter 没有 ignore/exclude 机制。若放在各 service 目录，简单的目录映射会产生同名冲突或误部署。

#### secrets.conf 格式

```
# <Service> Secrets
# Reference: <官方配置文件链接>
#   - <官方 docker-compose.yml 链接>
#   - <其他参考链接，如 .env.example 等, 允许多个，继续向下扩展列表。>

<name>:<type>:<param>
```

| type       | 说明                 | param                     |
| ---------- | -------------------- | ------------------------- |
| `hex`      | 随机 hex 字符串      | 字节数                    |
| `fixed`    | 固定值（用户名等）   | 值                        |
| `computed` | 依赖其他 secret 构造 | 模板（`${other-secret}`） |

#### Container 引用

```ini
[Container]
Secret=<secret-name>,type=env,target=<ENV_VAR>
```

### 数据库连接一致性

当应用容器通过 `DATABASE_URL` 连接数据库容器时，**两边配置必须一致**：

示例 - `<service>.conf` 定义：

```
<service>-postgres-password:hex:16
<service>-database-url:computed:postgresql://<service>:${<service>-postgres-password}@postgres:5432/<service>
```

对应的 `<service>-postgres.container` 必须匹配：

```ini
# ✅ 正确
Environment=POSTGRES_USER=<service>
Environment=POSTGRES_DB=<service>
NetworkAlias=postgres

# ❌ 错误 - 会导致认证失败
Environment=POSTGRES_USER=postgres
Environment=POSTGRES_DB=postgres
```

**检查清单**：

| DATABASE_URL 参数       | 对应容器配置              |
| ----------------------- | ------------------------- |
| 用户名 (`<service>:`)   | `POSTGRES_USER=<service>` |
| 数据库名 (`/<service>`) | `POSTGRES_DB=<service>`   |
| 主机名 (`@postgres:`)   | `NetworkAlias=postgres`   |

### Hook 脚本注意事项

`pre_deploy.sh` / `post_deploy.sh` 会被 dotter 的 handlebars 模板引擎处理。
若脚本中需要字面的 `{{`（如 podman `--format`），必须用 `\{{` 转义：

```bash
# ❌ 错误 - 被 handlebars 解析报错
podman secret ls --format '{{.Name}}'

# ✅ 正确 - 反斜杠转义
podman secret ls --format '\{{.Name}}'
```

## 参考命令

| 主题                               | 命令                      |
| ---------------------------------- | ------------------------- |
| Quadlet 参数                       | `man podman-systemd.unit` |
| systemd 单元（specifiers、依赖等） | `man systemd.unit`        |
| Podman Secret                      | `man podman-secret`       |
