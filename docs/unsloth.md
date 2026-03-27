# Unsloth 配置指南

## 默认行为

- 镜像：`docker.io/unsloth/unsloth`
- Traefik 域名：`https://unsloth.<domain>`
- 容器内 Jupyter 端口：`8888`
- 默认工作目录挂载：`%D/unsloth/work -> /workspace/work`
- 若 deploy 时宿主机可执行 `nvidia-smi -L`，会自动注入 `--gpus all`

> [!NOTE]
> 当前仅通过 Traefik 暴露 Web UI，对外入口是 `https://unsloth.<domain>`，不保留宿主机直连端口映射。

## 密码管理

`JUPYTER_PASSWORD` 不写死在 `.container`，而是通过 Podman secret 注入：

```ini
Secret=unsloth-jupyter-password,type=env,target=JUPYTER_PASSWORD
```

secret 定义在 `.dotter/secrets/unsloth.conf`，首次 `dotter deploy` 会自动生成。

查看当前密码：

```bash
podman secret inspect unsloth-jupyter-password --showsecret --format '{{.SecretData}}'
```

## 可选配置

> [!IMPORTANT]
> 当前模板只在宿主机检测到 NVIDIA GPU 时注入 `--gpus all`。若 GPU 存在但 Podman / NVIDIA / CDI 运行时未配好，服务仍可能启动失败。

### 额外挂载

若还需要额外挂载数据目录：

```toml
[variables]
unsloth_volumes = [
  "/path/to/models:/models:ro",
  "/path/to/datasets:/datasets:ro",
]
```

## 参考

- <https://docs.unsloth.ai/basics/docker-installation>
- <https://hub.docker.com/r/unsloth/unsloth>
