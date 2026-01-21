# AGENTS.md

## 文档索引

| 文档 | Scope |
| ---- | ----- |
| README.md | 用户入门：项目简介、服务列表、冷启动、常用命令 |
| AGENTS.md | 新建服务检查清单、核心规则 |
| docs/quadlet.md | Quadlet 文件类型、命名规范、网络架构、容器模板 |
| docs/secrets.md | Secrets 格式定义、一致性检查 |
| docs/hooks.md | pre/post_deploy 脚本、handlebars 转义 |
| docs/traefik.md | Traefik 配置：SSL、域名解析、中间件 |
| docs/tailscale.md | Tailscale 远程访问配置 |
| docs/\<service\>.md | 特定业务服务的详细配置 |

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

2. **更新 `.dotter/global.toml`** - 添加部署配置

   ```toml
   [<service>.files]
   <service> = '~/.config'
   ```

3. **更新 `.dotter/local.toml`** - 启用新服务

   ```toml
   packages = ["traefik", "dozzle", "silverbullet",  "<service>"]
   ```

4. **更新 `README.md`** - 服务列表添加新服务

5. **更新 `docs/traefik.md`** - hosts 临时配置添加新域名

6. **配置 Traefik labels** - 见 [docs/quadlet.md](docs/quadlet.md#单容器服务模板)

## 核心规则

### 默认不创建 log volume

容器日志输出到 stdout/stderr，由 Podman journald 驱动统一管理。

- 查看日志：`journalctl --user -u <service> -f` 或使用 Dozzle Web UI
- 日志持久化、轮转由 systemd-journald 处理

```ini
# ❌ 不推荐 - 日志不需要持久化
Volume=xxx-logs.volume:/var/log/xxx

# ✅ 正确 - 只持久化数据
Volume=xxx-data.volume:/var/lib/xxx
```

**例外情况**（需要单独 log volume）：

1. 日志内容与 stdout 不同（如应用写入特定格式的审计日志）
2. 日志量极大且需要独立管理（如数据库查询日志）
3. 第三方工具需要读取日志文件（如日志分析器）

若无上述情况，**禁止创建 log volume**，避免数据重复和磁盘浪费。

### Label 值特殊字符必须加引号

```ini
# ❌ 错误 - 特殊字符后的内容会被截断
Label=traefik.http.routers.xxx.rule=Host(`a.com`) && PathPrefix(`/path`)

# ✅ 正确 - 双引号保护完整值
Label=traefik.http.routers.xxx.rule="Host(`a.com`) && PathPrefix(`/path`)"
```
