# Silo

共享 S3 兼容对象存储（MinIO 社区分支），供 Langfuse / Omnivore / Plane 使用，替代各服务自带的 MinIO 实例。

Base docs: [`docs/quadlet.md`](quadlet.md), [`docs/secrets.md`](secrets.md), [`docs/dotter.md`](dotter.md)

> 官方文档: <https://github.com/pgsty/silo>

## 偏离默认模板

- S3 API：容器内 `9000`，网络别名 `silo`（`http://silo:9000`）；Console `9090` 不发布、不经过 Traefik。
- 数据：命名卷 `silo-data.volume` → `/data`。
- 网络：`.dotter/render_networks.sh silo` 动态加入依赖它的业务子网。
- 消费端统一 `AWS_REGION=us-east-1`（Silo/MinIO 默认 region）。
- 无 `[Install]`，按需拉起。`HealthCmd=curl -f http://127.0.0.1:9000/minio/health/ready` + `Notify=healthy`，所以 `After=silo.service` 即代表 S3 API 可服务（见 [`docs/quadlet.md`](quadlet.md) 的「依赖就绪门禁」）。

## Bucket 与凭据初始化

每个栈一个 oneshot 单元：`langfuse-s3-init`、`omnivore-s3-init`、`plane-s3-init`，通用规则见 [`docs/quadlet.md`](quadlet.md) 的「S3 桶与凭据初始化」。消费端同时依赖 `silo.service` 与自己的 `<stack>-s3-init.service`。

- 三个单元共用 `silo/silo/s3-init.sh`（部署到 `~/.config/silo/`，只读挂载为 `/init.sh`），通过 `Environment=S3_BUCKET=<stack>` 区分栈。
- 脚本建 bucket `<stack>`、用户（access/secret key 来自该栈的 secret）和只覆盖该 bucket 的 policy `<stack>-rw`。已实测隔离有效：用某栈凭据访问其他栈的 bucket 返回 `Access Denied`。
- 栈的 S3 凭据沿用原 secret 名（`<stack>-s3-access-key` / `<stack>-s3-secret-key`），Silo 不要求 Garage 的 `GK` 前缀。

## Secrets

`silo-root-user` / `silo-root-password` 定义在 `.dotter/secrets/silo.conf`，只出现在 `silo.container` 和三个 init 单元里，业务容器拿不到 root 凭据。只启用 `langfuse` 等栈时，`pre_deploy.sh` 会按 `depends` 连带创建它们，见 [`docs/dotter.md`](dotter.md)。

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

## 参考

- [Silo (pgsty/silo)](https://github.com/pgsty/silo)
- [MinIO 健康检查端点](https://min.io/docs/minio/linux/operations/monitoring/healthcheck-probe.html)
- [Plane proxy Caddyfile（上游写死 `plane-minio`）](https://github.com/makeplane/plane/blob/preview/apps/proxy/Caddyfile.ce)
- [Plane proxy Dockerfile](https://github.com/makeplane/plane/blob/preview/apps/proxy/Dockerfile.ce)
- [mc admin policy](https://min.io/docs/minio/linux/reference/minio-mc-admin/mc-admin-policy.html)
