# Omnivore 特殊处理

> [!IMPORTANT]
> 本文只记录 Omnivore 相对 [`docs/quadlet.md`](quadlet.md) 与 [`docs/secrets.md`](secrets.md) 的差异；通用 Quadlet、Traefik 和 Secret 规则不在这里重复。

Base docs: [`docs/quadlet.md`](quadlet.md), [`docs/secrets.md`](secrets.md)

> 官方文档: <https://github.com/omnivore-app/omnivore/tree/main/self-hosting>

## 架构

```
┌─────────────────────────────────────────────────────────────┐
│  omnivore.target                                            │
├─────────────────────────────────────────────────────────────┤
│  基础设施                                                   │
│  ├── postgres.service                                       │
│  ├── garage.service                                         │
│  └── omnivore-redis                                         │
├─────────────────────────────────────────────────────────────┤
│  一次性任务                                                 │
│  ├── omnivore-migrate                                       │
│  └── omnivore-createbuckets                                 │
├─────────────────────────────────────────────────────────────┤
│  应用服务                                                   │
│  ├── omnivore-api         → omnivore-api.{{domain}}         │
│  ├── omnivore-web         → omnivore.{{domain}}             │
│  ├── omnivore-content-fetch                                 │
│  ├── omnivore-image-proxy                                   │
│  └── omnivore-queue-processor                               │
└─────────────────────────────────────────────────────────────┘
```

## 当前差异

- 这是一个多容器栈，统一由 `omnivore.target` 编排
- 业务容器同时加入 `omnivore.network` 与 `traefik.network`
- 依赖共享 `postgres.service` 与 `garage.service`，而不是自带独立数据库 / 对象存储
- 数据库初始化通过一次性 `omnivore-migrate.container` 完成

## Secrets 映射

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

## 启动顺序注意事项

虽然 `omnivore-migrate.container` 已经通过 `ExecStartPre=/usr/bin/podman healthcheck run systemd-postgres` 等待 PostgreSQL 健康检查，但冷启动时仍应优先确认 migrate 已成功，再观察 API。

若 `omnivore-api` 因数据库尚未完成初始化而失败，可按下面顺序重试：

```bash
systemctl --user restart omnivore-migrate.service

# 确认成功后重启 api
systemctl --user restart omnivore-api.service
```

## 参考

- <https://github.com/omnivore-app/omnivore/tree/main/self-hosting>
- <https://github.com/omnivore-app/omnivore/blob/main/self-hosting/docker-compose/.env.example>
