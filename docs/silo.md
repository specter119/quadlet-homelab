# Silo

共享 S3 兼容对象存储（MinIO 社区分支），供 Langfuse / Omnivore / Plane / Raft 使用，替代各服务自带的 MinIO 实例。

Base docs: [`docs/quadlet.md`](quadlet.md), [`docs/secrets.md`](secrets.md), [`docs/dotter.md`](dotter.md)

> 官方文档: <https://github.com/pgsty/silo>

## 偏离默认模板

- S3 API：容器内 `9000`，网络别名 `silo`（`http://silo:9000`）；Console `9090` 不发布、不经过 Traefik。
- 浏览器直取：S3 API 默认只在业务子网内可达；需要让浏览器直接访问预签名 URL 的栈，在 `silo.container` 上按 bucket 路径前缀加 Traefik router，见下文「浏览器直取预签名 URL」。
- 数据：命名卷 `silo-data.volume` → `/data`。
- 网络：`.dotter/render_networks.sh silo` 动态加入依赖它的业务子网。
- 消费端统一 `AWS_REGION=us-east-1`（Silo/MinIO 默认 region）。
- 无 `[Install]`，按需拉起。`HealthCmd=curl -f http://127.0.0.1:9000/minio/health/ready` + `Notify=healthy`，所以 `After=silo.service` 即代表 S3 API 可服务（见 [`docs/quadlet.md`](quadlet.md) 的「依赖就绪门禁」）。

## Bucket 与凭据初始化

每个栈一个 oneshot 单元：`langfuse-s3-init`、`omnivore-s3-init`、`plane-s3-init`、`raft-s3-init`，通用规则见 [`docs/quadlet.md`](quadlet.md) 的「S3 桶与凭据初始化」。消费端同时依赖 `silo.service` 与自己的 `<stack>-s3-init.service`。

- 各单元共用 `silo/silo/s3-init.sh`（部署到 `~/.config/silo/`，只读挂载为 `/init.sh`）。bucket 由环境变量指定：`S3_BUCKET=<stack>`（单个，既有栈沿用）或 `S3_BUCKETS="a b"`（空格分隔多个），两者都给时取并集，都没有则失败。`raft-s3-init` 用的是 `S3_BUCKETS=raft`。
- 脚本为每个 bucket 建 bucket 本身和只覆盖它的 policy `<bucket>-rw`，并把全部 policy 挂到同一个用户（access/secret key 来自该栈的 secret）。用户只创建一次，在循环之前。已实测隔离有效：用某栈凭据访问其他栈的 bucket 返回 `Access Denied`。
- 栈的 S3 凭据沿用原 secret 名（`<stack>-s3-access-key` / `<stack>-s3-secret-key`），Silo 不要求 Garage 的 `GK` 前缀。

## Secrets

`silo-root-user` / `silo-root-password` 定义在 `.dotter/secrets/silo.conf`，只出现在 `silo.container` 和各栈的 init 单元里，业务容器拿不到 root 凭据。只启用 `langfuse` 等栈时，`pre_deploy.sh` 会按 `depends` 连带创建它们，见 [`docs/dotter.md`](dotter.md)。

## 运维

未发布 Console 端口。日常用容器内的 `mcli`（先建 alias）：

```bash
podman exec systemd-silo sh -c '
  mcli alias set local http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null &&
  mcli --no-color ls local/ &&
  mcli --no-color admin user list local'
```

需要 Web Console 时，临时在 `silo.container` 加 `PublishPort=127.0.0.1:9001:9090`，`systemctl --user daemon-reload && systemctl --user restart silo.service`，用完删掉。

## Plane proxy 的 `plane-minio` 别名

上游 `plane-proxy` 把对象存储主机**写死**为 `plane-minio:9000`：`apps/proxy/Dockerfile.ce` 将 `apps/proxy/Caddyfile.ce` 复制为 `/etc/caddy/Caddyfile`，其中是 `reverse_proxy /{$BUCKET_NAME}/* plane-minio:9000`（`$BUCKET_NAME` 可参数化，主机名不可）。`preview` 与 release commit 内容一致，因此 `:stable` 镜像同样受影响。

`silo.container` 因此额外声明 `NetworkAlias=plane-minio`，别名对 silo 加入的所有网络生效，只有 `plane.network` 里的 proxy 会用到。`BUCKET_NAME` 必须与 plane-api 的 `AWS_S3_BUCKET_NAME`（`plane`）一致，因为该路径就是 `/{bucket}/{key}`。

> [!NOTE]
> 浏览器侧的文件访问是 SigV4 预签名 URL（`apps/api/plane/settings/storage.py` 用 `boto3` + `s3v4`，`USE_MINIO=1` 时以 `request.get_host()` 构造端点，即走 proxy 域名），Caddy 默认转发原始 `Host`，所以签名有效，**不需要** bucket 匿名读。上游 `createbuckets` 里额外做了 `mc anonymous set download`，属于遗留便利（某些只返 key 的静态资源可能依赖）；本仓库默认不开，遇到 403 再按需执行：
>
> ```bash
> podman exec -it systemd-silo mcli anonymous set download local/plane
> ```

## 浏览器直取预签名 URL（Raft）

SigV4 预签名 URL 的 Host 参与签名，所以浏览器必须直接用签名时的 Host 访问 Silo。目前只有 Raft 需要这条路径（见 [`docs/raft.md`](raft.md) 的「附件存储」）：

- `silo.container` 加入 `traefik.network`，并设置 `traefik.docker.network=systemd-traefik`。
- router `raft-objects-{http,https}` 的规则是 `` Host(`silo.{{domain}}`) && PathPrefix(`/raft`) ``，只放行 `raft` 这一个 bucket 的 path-style 请求，**不是**把整个 S3 API 暴露出去。HTTPS router 使用 `homelab-internal@file` 中间件，沿用 `traefik.trusted_source_ranges`。
- Traefik 不重写 path、保留原始 Host，所以签名仍然有效。bucket 保持私有，不需要匿名读。
- 其他栈将来也要浏览器直取时，各自在 `silo.container` 加自己的 router（规则里换成自己的 bucket 前缀）。同一容器上有多个 Traefik service 时，**每个 router 都必须显式写 `service` label**，否则 Traefik 无法推断。

## 参考

- [Silo (pgsty/silo)](https://github.com/pgsty/silo)
- [MinIO 健康检查端点](https://min.io/docs/minio/linux/operations/monitoring/healthcheck-probe.html)
- [Plane proxy Caddyfile（上游写死 `plane-minio`）](https://github.com/makeplane/plane/blob/preview/apps/proxy/Caddyfile.ce)
- [Plane proxy Dockerfile](https://github.com/makeplane/plane/blob/preview/apps/proxy/Dockerfile.ce)
- [mc admin policy](https://min.io/docs/minio/linux/reference/minio-mc-admin/mc-admin-policy.html)
