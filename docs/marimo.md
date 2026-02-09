# Marimo 配置指南

## 额外 Volume 挂载

通过 `marimo_volumes` 变量可以向 marimo 容器添加额外的 `Volume=` 挂载，用于将宿主机目录映射到容器内供 notebook 访问。

在 `.dotter/local.toml` 中配置：

```toml
[marimo.variables]
autostart = true
marimo_volumes = [
  "/path/to/data:/data:ro",
  "/path/to/models:/models:ro",
]
```

不定义 `marimo_volumes` 时不会生成额外的 `Volume=` 行。

## 参考

- [Marimo Documentation](https://docs.marimo.io/)
