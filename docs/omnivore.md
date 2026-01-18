# Omnivore 配置指南

> 官方文档: <https://github.com/omnivore-app/omnivore/tree/main/self-hosting>

Omnivore 是一个 Read-it-later 阅读服务，支持文章保存、标注和全文搜索。

## 架构

```
┌─────────────────────────────────────────────────────────────┐
│  omnivore.target                                             │
├─────────────────────────────────────────────────────────────┤
│  基础设施                                                    │
│  ├── omnivore-postgres    (pgvector)                        │
│  ├── omnivore-redis                                         │
│  └── omnivore-minio       (S3 兼容存储)                      │
├─────────────────────────────────────────────────────────────┤
│  一次性任务                                                  │
│  ├── omnivore-migrate     (数据库迁移)                       │
│  └── omnivore-createbuckets (MinIO bucket 初始化)            │
├─────────────────────────────────────────────────────────────┤
│  应用服务                                                    │
│  ├── omnivore-api         → omnivore-api.{{domain}}         │
│  ├── omnivore-web         → omnivore.{{domain}}             │
│  ├── omnivore-content-fetch                                 │
│  ├── omnivore-image-proxy                                   │
│  └── omnivore-queue-processor                               │
└─────────────────────────────────────────────────────────────┘
```

## Secrets 配置

参考官方 [.env.example](https://github.com/omnivore-app/omnivore/blob/main/self-hosting/docker-compose/.env.example)。

本项目使用 Podman Secret 管理敏感配置，定义在 `.dotter/secrets/omnivore.conf`：

| Secret 名称 | 用途 | 对应官方变量 |
|------------|------|-------------|
| `omnivore-postgres-password` | PostgreSQL 超级用户密码 | `POSTGRES_PASSWORD`, `PGPASSWORD` |
| `omnivore-app-password` | app_user 密码 | `PG_PASSWORD` |
| `omnivore-jwt-secret` | API JWT 签名 | `JWT_SECRET` |
| `omnivore-sso-jwt-secret` | SSO JWT 签名 | `SSO_JWT_SECRET` |
| `omnivore-image-proxy-secret` | 图片代理签名 | `IMAGE_PROXY_SECRET` |
| `omnivore-minio-user` | MinIO 用户名 | `AWS_ACCESS_KEY_ID` |
| `omnivore-minio-password` | MinIO 密码 | `AWS_SECRET_ACCESS_KEY` |

## 启动顺序问题

### 问题

Quadlet 生成的 systemd 依赖（`After=`, `Requires=`）只等待容器启动，**不等待容器内应用 ready**。

```
migrate 启动时 → postgres 容器已启动 → 但 PostgreSQL 还在初始化 → migrate 连接失败
```

对比 docker-compose 的 `depends_on: condition: service_healthy`，Quadlet 没有等效机制。

### 症状

冷启动后 `omnivore-api` 反复重启，日志显示：

```
password authentication failed for user "app_user"
Role "app_user" does not exist
```

这是因为 migrate 失败，`app_user` 没有被创建。

### 解决方法

手动重启 migrate 服务：

```bash
systemctl --user restart omnivore-migrate.service

# 确认成功后重启 api
systemctl --user restart omnivore-api.service
```

## 常用命令

```bash
# 启动整个服务栈
systemctl --user start omnivore.target

# 停止整个服务栈
systemctl --user stop omnivore.target

# 查看所有 omnivore 服务状态
systemctl --user status 'omnivore-*'

# 查看 api 日志
journalctl --user -u omnivore-api.service -f

# 重置数据（删除所有数据重新初始化）
systemctl --user stop omnivore.target
podman volume rm omnivore-postgres-data omnivore-redis-data omnivore-minio-data
systemctl --user start omnivore.target
# 等几秒后手动重启 migrate
systemctl --user restart omnivore-migrate.service
```

## Demo 用户

migrate 会自动创建一个演示用户：

- Email: `demo@omnivore.work`
- Password: `demo_password`
