# AGENTS.md

## 文档索引

| 文档                | Scope                                                             |
| ------------------- | ----------------------------------------------------------------- |
| README.md           | 项目简介、服务列表（只保留 description）                          |
| AGENTS.md           | 文档契约、冷启动/维护入口、写作规范、新建服务检查清单             |
| docs/dotter.md      | Dotter 变量契约、覆盖规则、共享/私有变量约定                      |
| docs/quadlet.md     | Quadlet 文件类型、命名规范、网络架构、容器模板、Volume/Label 规范 |
| docs/secrets.md     | Secrets 格式定义、一致性检查                                      |
| docs/hooks.md       | pre/post_deploy 脚本、handlebars 转义                             |
| docs/traefik.md     | Traefik 配置：SSL、域名解析（本机访问）、架构设计、中间件         |
| docs/tailscale.md   | Tailscale 远程访问配置（替代本机 DNS 方案）                       |
| docs/browser-trust.md | Windows/Linux host 浏览器信任本地 Traefik 证书的验证记录      |
| `docs/<service>.md` | 仅记录服务相对基础模板的特殊处理、额外依赖与官方参考              |

## 文档契约

| 文档类型            | 应该包含                                           | 不应包含                                                        |
| ------------------- | -------------------------------------------------- | --------------------------------------------------------------- |
| `README.md`         | 服务简介、文档入口                                 | 冷启动细节、通用运维命令、逐服务配置步骤                        |
| `AGENTS.md`         | 文档分工、维护流程、冷启动入口、新建服务 checklist | 逐服务的配置细节复制                                            |
| 通用 `docs/*.md`    | 可复用的规则与默认模板                             | 只对单个服务成立的本地 workaround                               |
| `docs/<service>.md` | 偏离默认模板的差异、额外 systemd/secret/volume     | 重复 `docs/quadlet.md` / `docs/secrets.md` / `docs/traefik.md` |

> [!IMPORTANT]
> 只有当某个服务**偏离默认 Quadlet 模板**时，才创建 `docs/<service>.md`。未单独建文档的服务，默认直接遵循 `docs/quadlet.md`、`docs/dotter.md`、`docs/secrets.md`。

> [!IMPORTANT]
> **无 `docs/<service>.md` = 该服务完全继承默认规则。** 维护时不要自行推断额外 secret、hook、sidecar、启动顺序或本地 workaround。

### 服务文档写作约定

- 先引用基础文档，再只写该服务的 **delta**
- 优先记录这些特殊处理：自定义镜像构建、额外 volume/secret/network、辅助 systemd 单元、已知启动顺序问题、数据持久化约束
- 仅在步骤**明显依赖该服务特殊实现**时，才写初始化或排障步骤
- 若包含排障记录，必须写清触发条件，并标明它是本地特例还是稳定契约
- 本地排障 history 只保留可复现经验：触发条件、判断依据、修复命令、适用边界；不要写进默认模板或 `README.md`
- 文末必须保留官方参考链接，便于后续校验配置是否过时

### 内容归属原则

| 内容类型                             | 归属                 |
| ------------------------------------ | -------------------- |
| 服务是什么、做什么                   | `README.md`          |
| 冷启动和维护时先看什么、先做什么     | `AGENTS.md`          |
| 默认 Quadlet / Dotter / Secrets 规则 | 对应通用 `docs/*.md` |
| 服务额外处理与本地特殊约束           | `docs/<service>.md`  |

**避免重复**：默认规则只定义一次，服务文档只补充差异并给出引用。

## 冷启动入口（最小流程）

1. 启用 linger：`sudo loginctl enable-linger $USER`
2. 初始化 dotter 本地配置：`dotter init`
3. 按 [`docs/dotter.md`](docs/dotter.md) 设置本机变量
4. 按 [`docs/traefik.md`](docs/traefik.md) 完成 SSL、低端口和本机 DNS
5. `dotter deploy`
6. 启动基础服务或对应 `<stack>.target`

> [!NOTE]
> 非基础服务若有额外处理，再回到对应 `docs/<service>.md` 查看差异；不要把整套冷启动流程重复写进每个服务文档。

### 维护规范

修改服务文档前，**必须先查阅官方文档**验证配置是否过时：

1. 检查文档末尾「参考」章节的官方链接
2. 对比本地配置与官方最新推荐
3. 移除已废弃的配置方式，只保留当前推荐做法
4. 同步检查交叉引用是否仍指向当前 canonical source

## 版本控制约定

- 本仓库使用 colocated `jj + git`：保留 `.git/` 作为 Git 远端兼容层，本地变更优先用 `jj` 管理
- 默认分支保持为仓库的单一真实状态，原则上直接收敛到 default branch，不长期保留额外 branch/bookmark
- 只有在需要验证某个 package 的新实现或隔离高风险实验时，才临时创建 branch/bookmark
- 实验结束后应尽快合并回 default branch，并删除多余 branch/bookmark
- 删除服务时，按 package 维度清理对应配置、文档、secrets、systemd/containers 文件，避免遗留半套状态

### 文档写作规范

使用 [GitHub Alerts](https://docs.github.com/en/get-started/writing-on-github/getting-started-with-writing-and-formatting-on-github/basic-writing-and-formatting-syntax#alerts) 替代 `> **加粗前缀**：` 风格的 blockquote：

| Alert 类型       | 用途                           | 示例场景                         |
| ---------------- | ------------------------------ | -------------------------------- |
| `> [!NOTE]`      | 补充说明、设计决策             | 解释为什么用 Wants 而非 Requires |
| `> [!TIP]`       | 可选建议、平台特定提示         | WSL 用户额外操作                 |
| `> [!IMPORTANT]` | 必须遵守的规则、前置条件       | 修改文档前先查阅官方链接         |
| `> [!WARNING]`   | 会导致故障的错误配置           | 不要把 upstream 指向 127.0.0.53  |
| `> [!CAUTION]`   | 不可逆操作、数据丢失风险       | 删除数据库、重置配置             |

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
   packages = ["traefik", "dozzle", "silverbullet", "<service>"]
   ```

1. **更新 `README.md`** - 在服务列表补充一行 description

1. **判断是否需要 `docs/<service>.md`**

   - 无特殊处理：**不要新建服务文档**
   - 有特殊处理：只记录相对基础模板的差异与参考链接

1. **配置 Traefik labels** - 见 [docs/quadlet.md](docs/quadlet.md#单容器服务模板)
