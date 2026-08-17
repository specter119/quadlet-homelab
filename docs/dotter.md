# Dotter 变量契约

本项目约定由 Dotter 负责**文件部署与模板渲染**，变量契约统一定义在这里。

变量分两类：

- `global.toml` / `local.toml` 覆盖变量：用于非敏感的模板参数
- Podman secret：用于密码、token、密钥等敏感值，见 [`docs/secrets.md`](secrets.md)

> [!IMPORTANT]
> 修改模板变量前，先确认是否符合 Dotter 的变量合并规则：package 默认值来自 `.dotter/global.toml` 的 `[package.variables]`，本机覆盖只来自 `.dotter/local.toml` 的顶层 `[variables]`。

## 覆盖顺序

```toml
# .dotter/global.toml
[package_name.variables]
scalar_value = ""
nested_value = { key_a = "", key_b = "" }
```

```toml
# .dotter/local.toml
[variables]
scalar_value = "local"
nested_value = { key_b = "overridden" }
```

- `[package.variables]` 在 `.dotter/global.toml` 中定义 package 级占位符和 schema
- `.dotter/local.toml` 不使用 `[package.variables]`，只使用顶层 `[variables]`
- Dotter 会先合并所有启用 package 的变量，再用 `.dotter/local.toml` 的 `[variables]` 按变量名递归覆盖
- 同名标量会直接替换；同名 table 会按子键递归合并
- 数组变量会由 local 完整替换，不会隐式追加；需要表达“保留部分 global 并追加本机值”时，local 应显式写出最终数组
- 没有合理默认值时，优先在 `.dotter/global.toml` 放空占位符，减少模板分支；这是 schema 声明，不代表推荐默认值

> [!WARNING]
> 不要让多个 package 提供同名标量默认值，例如同时定义 `domain = "..."`。这类冲突会在 package 合并阶段直接报错，`local.toml` 无法兜底。

## 来源规则

- **跨机器共享的非敏感默认值**：放在 `.dotter/global.toml` 的 `[package.variables]`
- **本机变量 / 不跨机器同步的值**：先在 `.dotter/global.toml` 定义占位符，再从 `.dotter/local.toml` 的顶层 `[variables]` 覆盖
- **只由本机决定且模板必须直接读取的变量**：必须在 `.dotter/local.toml` 的 `[variables]` 中显式定义，例如 `autostart_services = []`
- **敏感值**：不要放进 `.dotter/local.toml`，改用 `.dotter/secrets/*.conf` 和 Quadlet `Secret=`
- **服务私有配置**：使用 namespaced table，避免多个 package 共享顶层变量名

> [!NOTE]
> 上面的敏感值规则只适用于 **容器消费的输入依赖**（数据库密码、上游 API token 等容器通过 `Secret=` 读取的 secret）。对于 **容器生产、供宿主机 CLI 消费** 的输出型 key（例如 nowledge-mem 的 `NMEM_API_KEY`：容器初始化时自动生成，哈希存于 `remote-access.json`，宿主机 `nmem` CLI 通过 systemd user env 读取），走 podman `Secret=` 在语义上是错的（它是输出不是输入）。这类输出型 key 放进 `.dotter/local.toml` 作为冷启动基线、再由运行时同步脚本（`sync-key.sh`）在每次服务启动后覆盖，是上述规则的 **有正当理由的例外**。见 [`docs/nowledge-mem.md`](nowledge-mem.md) 的「API Key 同步」章节。

- hook 脚本不负责补写变量默认值；变量行为由模板和本文件约定保证

## 当前变量 Schema

| 变量 | 类型 | 来源 | 说明 |
| --- | --- | --- | --- |
| `domain` | string | `global + local` | Traefik 和服务路由使用的基础域名；默认由 `traefik` package 提供 |
| `autostart_services` | array of strings | `local` | 本机自启动服务列表；必须在 `.dotter/local.toml` 显式定义，可为空数组 |
| `traefik.trusted_source_ranges` | array of strings | `global + local` | 共享 `homelab-internal@file` middleware 的客户端 CIDR；global 放常用 LAN，local 显式覆盖为本机范围 |
| `marimo.volumes` | array of strings | `global + local` | Marimo 额外挂载；每项直接渲染为一行 `Volume=` |
| `unsloth.volumes` | array of strings | `global + local` | Unsloth 额外挂载；每项直接渲染为一行 `Volume=` |
| `deepseek-harness.volumes` | array of strings | `global + local` | DeepSeek Harness 额外挂载；每项直接渲染为一行 `Volume=` |
| `qoder-proxy.repo_overwrite` | string | `global + local` | Git 仓库 URL；设置后从源码构建本地镜像替代上游镜像 |
| `qoder-proxy.repo_branch` | string | `global + local` | 指定构建分支；留空则使用仓库默认分支 |

## 共享变量

`domain` 是共享标量变量，只能有一个 package 提供默认值：

```toml
# .dotter/global.toml
[traefik.variables]
domain = "homelab.com"

[traefik.variables.traefik]
trusted_source_ranges = [
  "127.0.0.1/32",
  "10.0.0.0/8",
  "172.16.0.0/12",
  "192.168.0.0/16",
]
```

本机覆盖写在顶层 `[variables]`：

```toml
# .dotter/local.toml
[variables]
domain = "worklab.com"
autostart_services = ["silverbullet", "marimo"]

[variables.traefik]
trusted_source_ranges = [
  "127.0.0.1/32",
  "192.168.0.0/16",
  "100.64.0.0/10",
]
```

## 服务私有变量

服务私有变量使用 namespaced table。模板读取 `marimo.volumes`、`unsloth.volumes`，所以 schema 必须写在对应 package 的同名 table 下：

```toml
# .dotter/global.toml
[marimo.variables.marimo]
volumes = []

[unsloth.variables.unsloth]
volumes = []
```

本机覆盖仍然写在 `.dotter/local.toml` 的顶层 `[variables]` 下；TOML 子表写法如下：

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

未定义对应 table 时，使用 `global.toml` 中的空数组，占位符不会生成额外 `Volume=`。

## 参考

- [Dotter](https://github.com/SuperCuber/dotter)
