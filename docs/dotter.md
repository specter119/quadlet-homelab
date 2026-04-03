# Dotter 变量契约

本项目约定由 Dotter 负责**文件部署与模板渲染**，变量契约统一定义在这里。

> [!IMPORTANT]
> 修改模板变量前，先确认是否符合 Dotter 的变量合并规则：package 默认值来自 `.dotter/global.toml` 的 `[package.variables]`，本机覆盖只来自 `.dotter/local.toml` 的顶层 `[variables]`。

## 合并规则

- `.dotter/global.toml`：用 `[package.variables]` 定义 package 级默认变量
- `.dotter/local.toml`：只使用顶层 `[variables]`，不使用 `[package.variables]`
- Dotter 会先合并所有启用 package 的变量，再用 `.dotter/local.toml` 的 `[variables]` 递归覆盖
- 同名标量会直接冲突；同名 table 会递归合并子键

> [!WARNING]
> 不要让多个 package 提供同名标量默认值，例如同时定义 `domain = "..."`。这类冲突会在 package 合并阶段直接报错，`local.toml` 无法兜底。

## 当前约定

### 共享变量

```toml
# .dotter/global.toml
[traefik.variables]
domain = "homelab.com"
```

```toml
# .dotter/local.toml
[variables]
domain = "worklab.com"
autostart_services = ["silverbullet", "marimo"]
```

- `domain`：全局域名，默认由 `traefik` package 提供
- `autostart_services`：仅在本机配置中声明，不在 `global.toml` 提供默认值

### 服务私有变量

对服务私有变量使用 namespaced table，避免多个 package 共享顶层变量名：

```toml
# .dotter/global.toml
[marimo.variables.marimo]
volumes = []

[unsloth.variables.unsloth]
volumes = []

[openfang.variables.openfang]
volumes = []
```

```toml
# .dotter/local.toml
[variables.marimo]
volumes = [
  "/path/to/data:/data:ro",
]

[variables.unsloth]
volumes = [
  "/path/to/models:/models:ro",
]
```

- `marimo.volumes`、`unsloth.volumes`、`openfang.volumes` 只影响各自服务模板
- 若本机不需要额外挂载，可完全省略对应 table

## 设计原则

- 共享标量默认值只能有一个来源
- 服务私有配置优先使用 namespaced table
- 只应由本机决定的变量，不要在 `.dotter/global.toml` 提供默认值
- hook 脚本不负责补写变量默认值；变量行为由模板和本文件约定保证

## 参考

- [Dotter](https://github.com/SuperCuber/dotter)
