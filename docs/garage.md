# Garage

共享 S3 兼容存储，供 Langfuse 等服务使用。

## 偏离默认模板

### 首次初始化

Garage 首次启动后需要手动完成 layout 分配，否则所有 S3 操作将失败：

```bash
# 查看节点 ID
podman exec systemd-garage /garage status

# 分配 layout（替换 <NODE_ID>）
podman exec systemd-garage /garage layout assign -z dc1 -c 1G <NODE_ID>
podman exec systemd-garage /garage layout apply --version 1
```

### Key 与 Bucket 管理

Garage v2 的 access key 必须以 `GK` 开头，**不能使用随机 hex 生成**。必须在 Garage 内创建后将结果存入 podman secret：

```bash
# 创建 key
podman exec systemd-garage /garage key create <key-name>
# 输出中包含 Key ID (GK...) 和 Secret key

# 创建 bucket 并授权
podman exec systemd-garage /garage bucket create <bucket-name>
podman exec systemd-garage /garage bucket allow --read --write --owner <bucket-name> --key <key-name>

# 更新 podman secrets（先删旧的再创建）
podman secret rm <access-key-secret> <secret-key-secret>
echo -n "<GK...>" | podman secret create <access-key-secret> -
echo -n "<secret-key>" | podman secret create <secret-key-secret> -
```

> [!IMPORTANT]
> `langfuse-s3-access-key` 和 `langfuse-s3-secret-key` 在 `langfuse.conf` 中定义为 `hex` 类型，但实际值必须从 Garage 获取。首次部署时需手动替换自动生成的值。

### RPC Secret

`garage.container` 的 ExecStartPre 从 podman secret `garage-rpc-secret` 提取 RPC secret 写入 volume。此 secret 为 32 bytes hex，可由 secrets 框架自动生成。

## 参考

- [Garage Quick Start](https://garagehq.deuxfleurs.fr/documentation/quick-start/)
- [Garage Configuration Reference](https://garagehq.deuxfleurs.fr/documentation/reference-manual/configuration/)
- [Garage CLI Reference](https://garagehq.deuxfleurs.fr/documentation/reference-manual/cli/)
