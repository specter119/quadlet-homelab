# Raft

Raft 的自托管部署。默认 Quadlet / Dotter / Traefik / Secrets 规则分别见
[`docs/quadlet.md`](quadlet.md)、[`docs/dotter.md`](dotter.md)、[`docs/traefik.md`](traefik.md)、
[`docs/secrets.md`](secrets.md)。本文只记录本服务的额外处理。

> 官方文档: <https://github.com/botiverse/raft-source>

## Client 与 Server 的边界

Raft 有两个互不相干的部分，共用 `raft` 这个名字，所以必须先分清：

|            | Client：Raft Computer                                  | Server：本仓库 `raft` package                                                                        |
| ---------- | ------------------------------------------------------ | ---------------------------------------------------------------------------------------------------- |
| 作用       | 把这台机器接入某个 Raft server，让 agent 在本机运行    | 自托管的 API + realtime + Web                                                                        |
| 管理者     | dotfiles 仓库的 `raft` package                         | 本仓库                                                                                               |
| 程序/镜像  | `~/.local/bin/raft-computer`                           | `localhost/raft-{server,web,rw-bootstrap}`                                                           |
| systemd    | `raft-computer.service`                                | `raft.target`、`raft-*`                                                                              |
| 宿主机目录 | `~/.local/share/raft/`（`SLOCK_HOME`，含 `computer/`） | `~/.local/lib/raft/`（仅构建入口脚本）、`~/.cache/raft/`（上游源码、改写后的 Dockerfile、构建 hash） |
| 状态       | 同左                                                   | podman volume `raft-*`、共享 postgres、共享 silo                                                     |

> [!IMPORTANT]
> Server **不使用任何 `share/` 目录**：`~/.local/share/raft/` 归 client 独占，`[raft.files]`
> 不要指向它。`~/.local/lib/raft/` 里只有构建入口，丢了重新 `dotter deploy` 即可；
> `~/.cache/raft/` 里全是可再生产物。

> [!NOTE]
> client 的 unit 原名 `raft.service`，已改名 `raft-computer.service`，与 server 的
> `raft.target` / `raft-*` 区分开。

## 镜像自建

上游只发布源码快照（release mirror，构建管线在私有仓），**没有官方镜像**，所以
`server` 与 `web` 必须自建，沿用 deepseek-harness 的既有范式：`localhost/raft-*:latest`

- `Pull=never` + `raft-prepare.service` 以 hash 幂等判断是否重建。

| 镜像                          | 说明                                                                                      |
| ----------------------------- | ----------------------------------------------------------------------------------------- |
| `localhost/raft-server`       | API + realtime + 迁移工具链（上游 `packages/server/Dockerfile`）                          |
| `localhost/raft-web`          | 静态 SPA（上游 `packages/web/Dockerfile`），API 地址 build-time 烤入                      |
| `localhost/raft-rw-bootstrap` | `postgres:17-alpine` + 构建期生成的 bootstrap SQL + 应用脚本，只用于 RisingWave bootstrap |

`prepare-images.sh` 不维护上游 Dockerfile 的 fork，只做三处机械改动（锚点缺失即失败退出）：
把 `RUN corepack enable` 换成用内网 npmrc 认证后安装 `packageManager` 声明的那版 pnpm；
给两处 `pnpm install` 挂入 npmrc 与 CA 的构建 secret；把短名 `FROM` 补成全限定名。

构建期有三个**非可选**的环境前提，缺任一个都会失败，且失败点离根因较远：

| 前提                                     | 原因                                                                                                                                                                                              |
| ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| npm 走内网镜像并带认证                   | `registry.npmjs.org` 在本机网络不可达，内网镜像匿名读 401；而 npm 凭据 key 形如 `//host/path/:_authToken`，无法用环境变量注入，corepack 又不读 `/root/.npmrc`，所以改为「用认证过的 npm 装 pnpm」 |
| `NODE_EXTRA_CA_CERTS` 指向宿主 CA bundle | 企业 MITM 代理；Node 默认用自带的 Mozilla 库、不读系统库，否则拉取外部 tarball（如 `cdn.sheetjs.com`）TLS 校验失败                                                                                |
| 传 `VITE_COMMIT_SHA`                     | 缺它 vite 插件不产出 `dist/desktop-manifest.json`，而上游 Dockerfile 会因 `test -f` 失败而故意中断（仓库的 `check-immutable-assets.mjs` 容忍该文件缺失，所以失败点被推到最后一个 stage）          |

升级上游版本：改 `.dotter/global.toml` 的 `raft.raft_source_tag` → `dotter deploy` →
重新运行 prepare 与迁移/bootstrap（见下方「启停」）。

## RisingWave 是硬依赖

`NODE_ENV=production` 下缺 `RISINGWAVE_DATABASE_URL` 服务端直接 `exit(1)`：Activity、
未读、followed-thread 统计**只从 RisingWave 读，没有 Postgres 回退**。

- 版本 `v3.0.3`，按 **manifest list digest** 钉死（多架构；钉单个架构的 image digest 会在
  另一架构上 `Exec format error`，v3.0.3 的 arm64 digest 曾踩过一次）；形态是 upstream
  文档给的 standalone `single_node`
- 状态存储是内嵌 `LocalFs` + `SQLite`，默认目录 `~/.risingwave`，挂 `raft-risingwave-data.volume`
- 官方把 standalone / docker compose 标为「非生产」（无 failover 与资源管理），这里接受该取舍
- 就绪探针只探 pgwire（4566）。**不要在探针里等视图**：视图由 bootstrap 单元建，会互锁

### CDC 与视图 bootstrap

`infra/risingwave/sql/` 的 SQL 不是 Postgres 迁移，必须按 `RISINGWAVE_BOOTSTRAP_ARTIFACTS`
的顺序应用，且**不能按字母序全跑**（多代视图共存，部分被新版本取代）。这些文件也不在
server 镜像里（上游 Dockerfile 只 `COPY packages/*` 与 `manual/`），所以：

1. `raft-rw-bootstrap` 镜像的 emit 阶段在 `raft-server` 之上补 `infra/` 与上游自带的
   emitter（`scripts/dev/emit-risingwave-bootstrap.ts`），**构建期**生成 `cdc.sql` /
   `manifest.sql` / `contract.json`，final 阶段只保留产物和 `psql`。SQL 与镜像同生命周期，
   宿主机上没有需要单独维护的 SQL 目录
1. `raft-risingwave-bootstrap` 运行该镜像：参数走 `-v`，PG 密码走 `\getenv`（不进 argv）。
   顺序是「PG 迁移 → CREATE SOURCE + CDC 表 → 视图 + 索引 → 校验 `required_relations` 都存在」

SQL 语句没有 `IF NOT EXISTS`，而 RisingWave 状态持久化，所以脚本先判断状态再决定是否应用：

| 状态                            | 行为                                                                                                                             |
| ------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| source 不存在                   | 首次 bootstrap：应用 SQL 并校验                                                                                                  |
| source 存在且必需 relation 齐全 | 已就绪，`exit 0`（重启机器、重复 `start raft.target` 都走这条）                                                                  |
| source 存在但缺 relation        | `exit 3`：首次应用半途失败，或升级后出现新一代视图。单元对 3 设了 `RestartPreventExitStatus`，不会无限重试，需按下文重建流程处理 |

上游的 `bootstrap-risingwave-local.ts` 自我标注 "destructive, local-only"，不能用于这里。

> [!IMPORTANT]
> emitter 输出的 `CREATE SOURCE` **没有** heartbeat，`prepare-bootstrap-sql.mjs`（emit 阶段）会注入
> `debezium.heartbeat.interval.ms` 与 `debezium.heartbeat.action.query`。这是必需的：
> 写入稀疏时 slot offset 不推进、WAL 会持续滞留（上游 issue #16697，单个 slot 曾涨到 19GB）。

### WAL 预算与失槽重建

共享 postgres 开了 `wal_level=logical`（见 `postgres.container` 的注释）并设
`max_slot_wal_keep_size=256MB`：

- 本机实测 WAL 生成约 1.5–6 MB/h，所以 256MB 预算 ≈ 容忍 RisingWave 停机 1.8–7 天
- 超预算时 PG **作废 slot**（不会把磁盘填满）；后果是 CDC 断，必须全量重建视图
- 该参数在 checkpoint 时评估（本机 `checkpoint_timeout=300s`），所以预算是硬的
- 建议监控 `pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)` 并在 50% 预算处告警：
  处置是「拉起 RisingWave 追上」（无损），而不是等失槽（有损）

> [!WARNING]
> 上游 README 描述的 `_build`/rename 零停机切换**没有**实现进 SQL 文件（`grep _build`
> 无命中），那是他们的人工流程。这里走停机重建，不要指望热切换。

失槽后的重建流程：

```sh
systemctl --user stop raft-server.service
# RisingWave 侧：DROP 失效的 source 及其 CDC 表/视图（psql -h raft-risingwave -p 4566 -U root -d dev）
# Postgres 侧：确认 slot/publication 已随 source 一起消失，必要时手工 DROP
systemctl --user restart raft-risingwave-bootstrap.service
systemctl --user start raft-server.service
```

## Redis 是软依赖

单副本下所有调用点都有 `isRedisAvailable()` 回退（Socket.IO adapter、跨副本路由、
会话驱逐、崩溃循环断路器、访问计数与各类缓存）。因此 `raft-redis` 只声明
`Requires=`/`After=`，**刻意不加 `Notify=healthy`**：就绪门禁会把软依赖变成致命的
启动阻塞（与 `langfuse-redis` 的既有做法一致）。代价是断路器计数与缓存状态在重启后归零。

## 域名与网络

| 域名                  | 用途                             |
| --------------------- | -------------------------------- |
| `raft.{{domain}}`     | Web SPA                          |
| `raft-api.{{domain}}` | API + Socket.IO（同一端口 3001） |
| `silo.{{domain}}`     | 附件预签名 URL 直取（见下节）    |

web 的 nginx 是纯静态 SPA，**不代理 `/api` 与 `/socket.io`**，所以 web 与 api 必须是两个
域名。`SERVER_URL` / `APP_URL` / `CORS_ORIGIN` 三处必须与上表一致。

> [!IMPORTANT]
> `RAFT_WEB_API_URL` 是 build-time 烤进 web 镜像的，**换域名必须重建 web 镜像**；
> 运行期改环境变量无效。

## 附件存储（共享 silo）

只用一个私有桶 `raft`，**不开 CDN 桶、不给任何桶开匿名读**：

- 未设 `S3_CDN_BUCKET` / `CDN_BASE_URL` 时，`storageService` 回落到主桶 + 服务端路由
  （`resolvePublicAssetUrl` 返回 null），所以公开 CDN 面不存在
- `S3_FORCE_PATH_STYLE=true` 是必需的：预签名 URL 的 Host 参与签名，path-style 才能让
  浏览器直接命中 `silo.{{domain}}`；否则会要求 `bucket.silo.{{domain}}`，即通配 DNS 与证书
- `silo.container` 因此加入 `traefik.network`，并用
  `Host(silo.{{domain}}) && PathPrefix(/raft)` 把路由收窄到 raft 的桶，而不是暴露整个 S3 API。
  Traefik 不重写 path、保留原始 Host，所以 SigV4 签名仍然有效（`plane-proxy` 走 Caddy 时同理）。
  其他栈若也需要浏览器访问，各自加自己的 router；同一容器有多个 Traefik service 时，
  每个 router 必须显式写 `service` label
- `UPLOADS_LOCAL=false`：S3 已配置，配置漏了应当失败，而不是把附件写进容器层

## 启停

多容器栈的 target 需要显式启用（`dotter deploy` 只做渲染与 `daemon-reload`）：

```sh
systemctl --user start raft.target          # 首次启动整个栈
systemctl --user enable raft.target         # 需要开机自启时再加
```

`dotter deploy` **不会**重建镜像、不会跑迁移或 bootstrap。改了这些要显式重跑：

```sh
systemctl --user restart raft-prepare.service            # 重建镜像（含 bootstrap SQL）
systemctl --user restart raft-migrator.service           # 有新迁移时
systemctl --user restart raft-risingwave-bootstrap.service  # 见下方说明
systemctl --user restart raft-server.service
```

`raft-prepare` 是其余单元的 `Requires=`，重启它会连带重启 migrator、bootstrap、server 和 web，
顺序由 `After=` 保证；上面几条通常只在单独调试时才需要。

- bootstrap 是幂等的：已就绪时重跑只会输出「已就绪」。升级后若上游引入了新一代视图，
  它会以 `exit 3` 报告缺 relation，需要走「失槽后的重建流程」（先 DROP 旧 source 再重跑），
  不会自动覆盖已有视图。
- 开机时网络未通：`prepare-images.sh` 的 `git fetch` 失败且本地已有该 tag 时只告警并继续，
  hash 未变就跳过构建；本地没有该 tag 才会失败。

## 排障

- 构建失败在 `pnpm install`：先确认 `~/.npmrc` 有 `registry=` 与对应 token，且
  `registry.npmjs.org` 是否真的不可达（可达时不需要内网镜像）
- 构建失败在 web 最后一个 stage 的 `test -f desktop-manifest.json`：说明没传
  `VITE_COMMIT_SHA`（见「镜像自建」）
- `raft-server` 起不来且日志提到 RisingWave：确认 `raft-risingwave.service` 已 healthy，
  且 `raft-risingwave-bootstrap.service` 已成功（视图缺失时相关读路径会直接报错）
- 附件 403/无法显示：确认预签名 URL 的 host 是 `silo.{{domain}}` 且该 host 在
  `traefik.trusted_source_ranges` 内；`S3_FORCE_PATH_STYLE` 漏设会产生
  `bucket.silo.{{domain}}` 形式的 URL 而无法解析

## 参考

- [Raft source](https://github.com/botiverse/raft-source)
- [`packages/server/.env.example`](https://github.com/botiverse/raft-source/blob/main/packages/server/.env.example)（服务端环境变量契约）
- [`infra/risingwave/sql/README.md`](https://github.com/botiverse/raft-source/blob/main/infra/risingwave/sql/README.md)（bootstrap 顺序与代际说明）
- [RisingWave standalone mode](https://docs.risingwave.com/operate/rw-standalone-mode)
- [RisingWave hardware requirements](https://docs.risingwave.com/deploy/hardware-requirements)
- [RisingWave PostgreSQL CDC](https://docs.risingwave.com/ingestion/sources/postgresql/pg-cdc)
- [RisingWave issue #16697（无写入时 slot 停滞）](https://github.com/risingwavelabs/risingwave/issues/16697)
- [PostgreSQL `max_slot_wal_keep_size`](https://www.postgresql.org/docs/17/runtime-config-replication.html)
