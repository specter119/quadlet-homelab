# Unsloth 特殊处理

> [!IMPORTANT]
> 本文只记录 Unsloth 相对 [`docs/quadlet.md`](quadlet.md) 与 [`docs/secrets.md`](secrets.md) 的差异。

Base docs: [`docs/quadlet.md`](quadlet.md), [`docs/secrets.md`](secrets.md)

## 当前差异

- 镜像使用 `docker.io/unsloth/unsloth`，并配置 `Pull=newer`
- 通过 Traefik 暴露两个入口：
  - `https://unsloth.<domain>` → Studio (`8000`)
  - `https://jupyterlab.unsloth.<domain>` → Jupyter (`8888`)
- 默认挂载工作目录 `%D/unsloth/work:/workspace/work:Z`
- `JUPYTER_PASSWORD` 通过 Podman secret `unsloth-jupyter-password` 注入

## GPU 注入策略

模板只在宿主机成功执行 `nvidia-smi -L` 时注入：

```ini
PodmanArgs=--gpus all
```

> [!IMPORTANT]
> 这只是“检测到 GPU 就尝试开启”，不保证 Podman / NVIDIA / CDI 运行时已经配置完整。

## 可选额外挂载

通过 `unsloth.volumes` 追加自定义挂载：

```toml
[variables.unsloth]
volumes = [
  "/path/to/models:/models:ro",
  "/path/to/datasets:/datasets:ro",
]
```

## 参考

- <https://docs.unsloth.ai/basics/docker-installation>
- <https://hub.docker.com/r/unsloth/unsloth>
