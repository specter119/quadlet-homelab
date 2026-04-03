# Dotter Hook 脚本

`pre_deploy.sh` / `post_deploy.sh` 会被 dotter 的 handlebars 模板引擎处理。

## Handlebars 转义

若脚本中需要字面的 `{{`（如 podman `--format`），必须用 `\{{` 转义：

```bash
# ❌ 错误 - 被 handlebars 解析报错
podman secret ls --format '{{.Name}}'

# ✅ 正确 - 反斜杠转义
podman secret ls --format '\{{.Name}}'
```

## 典型用途

- `pre_deploy.sh`：初始化 Podman secrets（读取 `.dotter/secrets/*.conf`）
- `post_deploy.sh`：`systemctl --user daemon-reload`

> [!NOTE]
> hook 脚本不负责补写 Dotter 变量默认值。变量来源、覆盖规则与 namespaced table 约定统一见 [docs/dotter.md](dotter.md)。

## 参考

- [dotter 文档](https://github.com/SuperCuber/dotter)
