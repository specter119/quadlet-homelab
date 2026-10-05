# Phoenix

> 官方文档: <https://arize.com/docs/phoenix/self-hosting/deployment-options/docker>

Phoenix 使用官方镜像 `arizephoenix/phoenix:latest`，作为可选的单容器服务运行。

## 当前默认暴露

- Web UI：`https://phoenix.<domain>`（Phoenix 服务显式启用后）
- 专用 OTLP HTTP host ingress：**未启用**。Traefik 默认不监听 `:4318`，也没有 Phoenix 的 `otlp-http` router。

当前本机 Pi traces 使用 Aspire dashboard 的 OTLP/gRPC `127.0.0.1:4317`，不依赖 Phoenix 的 host `:4318` ingress。

Phoenix 容器内的 Web UI 和 OTLP HTTP collector 共用 `6006`；其 gRPC collector 默认监听容器内 `4317`。移除 `:4318` 只会关闭专用 host OTLP HTTP 入口，不会改动 Phoenix 镜像的容器内监听配置。Phoenix 的 HTTPS router 仍转发到容器 `6006`，因此这里不把关闭 `:4318` 描述为 Phoenix collector 的完整访问控制边界。

## 以后需要 OTLP HTTP host ingress 时

按 [`docs/quadlet.md` 的自定义 EntryPoint 模式](quadlet.md) 显式恢复 Traefik `otlp-http` entrypoint、socket activation 和 Phoenix OTLP router。客户端 endpoint 使用：

```bash
OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=http://phoenix.<domain>:4318/v1/traces
```

## 存储

默认使用 SQLite，`PHOENIX_WORKING_DIR=/mnt/data`，数据保存在 `phoenix-data.volume`。

## 参考

- [Phoenix Docker deployment](https://arize.com/docs/phoenix/self-hosting/deployment-options/docker)
- [Traefik 自定义 EntryPoint 配置](quadlet.md)
