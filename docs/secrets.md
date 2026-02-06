# Secrets 管理

使用 **Podman Secret** 管理敏感配置，密钥存储在本地，不进 git。

> [!IMPORTANT]
> 当 `.container` 文件中发现明文密码/密钥时，应提取到 `.dotter/secrets/<service>.conf`，改用 `Secret=` 引用。

## 文件结构

```
.dotter/
├── secrets/
│   ├── langfuse.conf         # 密钥定义，提交 git
│   ├── plane.conf
│   └── omnivore.conf
├── pre_deploy.sh             # 部署前初始化 secrets
└── post_deploy.sh            # 部署后 daemon-reload
```

> [!NOTE]
> dotter 没有 ignore/exclude 机制。若放在各 service 目录，简单的目录映射会产生同名冲突或误部署。

## secrets.conf 格式

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

## Container 引用

```ini
[Container]
Secret=<secret-name>,type=env,target=<ENV_VAR>
```

## 数据库连接一致性

当应用容器通过 `DATABASE_URL` 连接共享 PostgreSQL 时，**URL 中的用户名/数据库名必须已在 PostgreSQL 中创建**。

示例 - `<service>.conf` 定义：

```
<service>-app-password:hex:16
<service>-database-url:computed:postgresql://app_user:${<service>-app-password}@postgres:5432/<service>
```

**检查清单**：

| DATABASE_URL 参数 | 说明 |
| ----------------- | ---- |
| 用户名 (`app_user:`) | 需在 postgres 中创建该用户 |
| 数据库名 (`/<service>`) | 需在 postgres 中创建该数据库 |
| 主机名 (`@postgres:`) | 通过 `render_networks.sh` 加入业务子网后可访问 |

## 参考

- `man podman-secret`
