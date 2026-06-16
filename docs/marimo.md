# Marimo 特殊处理

> [!IMPORTANT]
> 本文只记录 Marimo 相对 [`docs/quadlet.md`](quadlet.md) 与 [`docs/dotter.md`](dotter.md) 的差异。

Base docs: [`docs/quadlet.md`](quadlet.md), [`docs/dotter.md`](dotter.md)

## 当前差异

- 镜像使用 `docker.io/astral/uv:python3.13-trixie`
- 容器入口直接执行 `uvx ... marimo edit --headless`
- 默认持久化以下路径：
  - `%D/marimo:/workspace:Z`
  - `%E/marimo/marimo.toml:/root/.config/marimo/marimo.toml:Z`
  - `%E/uv/uv.toml:/root/.config/uv/uv.toml:Z`
- 若宿主机存在 `~/.netrc`，额外挂载为 `/root/.netrc:ro,Z`，用于让 `uv` 读取可选的私有源凭据；文件不存在时不生成该挂载。

## 可选额外挂载

通过 `marimo.volumes` 追加自定义 `Volume=`：

```toml
[variables.marimo]
volumes = [
  "/path/to/data:/data:ro",
  "/path/to/models:/models:ro",
]
```

未定义 `[variables.marimo]` 时，不生成额外 `Volume=`。

## 参考

- [Marimo Documentation](https://docs.marimo.io/)
