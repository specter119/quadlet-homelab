# Phoenix

> 官方文档: <https://arize.com/docs/phoenix/self-hosting/deployment-options/docker>

Phoenix 使用官方镜像 `arizephoenix/phoenix:latest`，作为单容器服务运行。

## 路由

- Web UI: `https://phoenix.<domain>`
- OTLP HTTP: `http://phoenix.<domain>:4318/v1/traces`

Phoenix 容器内的 UI 和 OTLP HTTP collector 共用 `6006` 端口；本项目通过 Traefik 的 `https` 和 `otlp-http` entrypoint 分别路由到同一个容器端口。

## Trace 接入迁移

Phoenix 承接原 tracing backend 的 OTLP HTTP surface。客户端侧只需要把 endpoint 的 host 改成 `phoenix.<domain>`，端口和路径保持 `4318/v1/traces`：

```bash
OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=http://phoenix.<domain>:4318/v1/traces
```

不再保留独立 tracing backend 域名；UI 查看和 trace 写入都收敛到 Phoenix 这个服务。

## 存储

默认使用 SQLite，`PHOENIX_WORKING_DIR=/mnt/data`，数据保存在 `phoenix-data.volume`。

## 限制

当前 Quadlet 只对外暴露 Web UI 和 OTLP HTTP collector。Phoenix 的 OTLP gRPC collector 仍在容器内监听 `4317`，但没有额外发布宿主机端口。
