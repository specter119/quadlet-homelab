# AGENTS.md

## 文档索引

| 文档                | Scope                                                             |
| ------------------- | ----------------------------------------------------------------- |
| README.md           | 用户入门：项目简介、服务列表、冷启动、常用命令                    |
| AGENTS.md           | 新建服务检查清单                                                  |
| docs/quadlet.md     | Quadlet 文件类型、命名规范、网络架构、容器模板、Volume/Label 规范 |
| docs/secrets.md     | Secrets 格式定义、一致性检查                                      |
| docs/hooks.md       | pre/post_deploy 脚本、handlebars 转义                             |
| docs/traefik.md     | Traefik 配置：SSL、域名解析、中间件                               |
| docs/tailscale.md   | Tailscale 远程访问配置                                            |
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
