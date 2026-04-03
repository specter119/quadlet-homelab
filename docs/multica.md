# Multica 配置指南

## 默认行为

- 入口域名：`https://multica.<domain>`
- 部署方式：`multica-prepare.service` 从上游 `main` 拉源码，并本地构建两个镜像
  - `localhost/multica-server:main`
  - `localhost/multica-web:main`
- 数据库：复用共享 PostgreSQL（已是 `pgvector/pgvector:pg17`），单独创建 `multica` 数据库和用户
- 数据库扩展：`multica-initdb.service` 会在 `multica` 库中执行 `CREATE EXTENSION IF NOT EXISTS vector`
- 对外暴露：仅 `multica-web` 通过 Traefik 暴露；`multica-api` 只在 `multica.network` 内部提供 `api:8080`

> [!IMPORTANT]
> `Multica` 官方 self-hosting 要求 PostgreSQL 17 + `pgvector`。本仓库当前共享 PostgreSQL 已满足该前提，不需要额外切换镜像。

## 服务结构

```plain
multica.target
├── multica-prepare.service
├── multica-initdb.service
├── multica-migrate.service
├── multica-api.service
└── multica-web.service
```

- `multica-prepare.service`：同步上游源码并构建本地镜像
- `multica-initdb.service`：创建 `multica` 数据库 / 用户，并启用 `vector` 扩展
- `multica-migrate.service`：执行上游数据库迁移
- `multica-api.service`：Go 后端，监听 `8080`
- `multica-web.service`：Next.js 前端，监听 `3000`

## 登录方式

若未配置 `RESEND_API_KEY`，`Multica` 仍可启动，但验证码不会发邮件，而是打印到 `multica-api` 日志：

```bash
journalctl --user -u multica-api.service -f
```

这是上游内置的开发回退行为，适合先本地试用；若要正式邮件登录，再自行接入 Resend。

## 启动与更新

首次部署：

```bash
dotter deploy
systemctl --user start multica.target
```

手动更新到上游最新 `main`：

```bash
systemctl --user restart multica-prepare.service
systemctl --user restart multica-migrate.service
systemctl --user restart multica-api.service
systemctl --user restart multica-web.service
```

## 参考

- <https://github.com/multica-ai/multica/blob/main/SELF_HOSTING.md>
- <https://github.com/multica-ai/multica/blob/main/.env.example>
- <https://github.com/multica-ai/multica/blob/main/docker-compose.yml>
