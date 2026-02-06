# AGENTS.md

## 文档索引

| 文档                | Scope                                                             |
| ------------------- | ----------------------------------------------------------------- |
| README.md           | 用户入门：项目简介、服务列表、冷启动、常用命令                    |
| AGENTS.md           | 文档索引、内容归属、维护规范、写作规范、新建服务检查清单          |
| docs/quadlet.md     | Quadlet 文件类型、命名规范、网络架构、容器模板、Volume/Label 规范 |
| docs/secrets.md     | Secrets 格式定义、一致性检查                                      |
| docs/hooks.md       | pre/post_deploy 脚本、handlebars 转义                             |
| docs/traefik.md     | Traefik 配置：SSL、域名解析（本机访问）、架构设计、中间件        |
| docs/tailscale.md   | Tailscale 远程访问配置（替代本机 DNS 方案）                       |
| docs/\<service\>.md | 特定业务服务的详细配置                                            |

### 内容归属原则

| 内容类型                      | 归属                       |
| ----------------------------- | -------------------------- |
| **规范/规则**（How：如何做）  | 对应技术的 `docs/*.md`     |
| **流程/步骤**（What：做什么） | `AGENTS.md` 或 `README.md` |

**避免重复**：规则只在一处定义，流程通过链接引用

### 维护规范

修改服务文档前，**必须先查阅官方文档**验证配置是否过时：

1. 检查文档末尾「参考」章节的官方链接
2. 对比本地配置与官方最新推荐
3. 移除已废弃的配置方式，只保留当前推荐做法

### 文档写作规范

使用 [GitHub Alerts](https://docs.github.com/en/get-started/writing-on-github/getting-started-with-writing-and-formatting-on-github/basic-writing-and-formatting-syntax#alerts) 替代 `> **加粗前缀**：` 风格的 blockquote：

| Alert 类型       | 用途                           | 示例场景                       |
| ---------------- | ------------------------------ | ------------------------------ |
| `> [!NOTE]`      | 补充说明、设计决策             | 解释为什么用 Wants 而非 Requires |
| `> [!TIP]`       | 可选建议、平台特定提示         | WSL 用户额外操作               |
| `> [!IMPORTANT]` | 必须遵守的规则、前置条件       | 修改文档前先查阅官方链接       |
| `> [!WARNING]`   | 会导致故障的错误配置           | 不要把 upstream 指向 127.0.0.53 |
| `> [!CAUTION]`   | 不可逆操作、数据丢失风险       | 删除数据库、重置配置           |

**不使用 alert 的场景**：纯引用链接（如 `> 官方文档: <url>`）、交叉引用（如 `> 详见 [其他文档](...)`）。

## 新建服务检查清单

每次新建微服务时，必须完成以下步骤：

1. **创建服务目录结构**

   ```plain
   <service>/
   └── containers/systemd/
       └── <service>.container
   ```

1. **更新 `.dotter/global.toml`** - 添加部署配置

   ```toml
   [<service>.files]
   <service> = '~/.config'
   ```

1. **更新 `.dotter/local.toml`** - 启用新服务

   ```toml
   packages = ["traefik", "dozzle", "silverbullet",  "<service>"]
   ```

1. **更新 `README.md`** - 服务列表添加新服务

1. **配置 Traefik labels** - 见 [docs/quadlet.md](docs/quadlet.md#单容器服务模板)
