# Magpie

默认规则见 [Quadlet 指南](quadlet.md)、[Dotter 变量契约](dotter.md) 和 [Secrets 管理](secrets.md)。本文只记录 Magpie 的容器部署差异。

## 容器部署差异

- 使用上游 GHCR 镜像，以 `magpie web --addr 0.0.0.0:3430 --no-open` 提供浏览器界面；Traefik 只代理容器端口 `3430`。

- 上游镜像以 UID `65532` 运行、`XDG_CONFIG_HOME=/config`，所有 XDG 目录都在 `/config` 之下。持久化拆成两层，并用 `UserNS=keep-id` 映射目录权限：

  - `/config` 是命名卷（`magpie-data.volume` → `systemd-magpie-data`），放 `cache/`（models.dev 目录、bun）、`state/`、`data/`、`home/`。
  - 宿主 `~/.config/magpie`（`%E/magpie`）bind 到 `/config/magpie`，**嵌套覆盖卷内同名目录**，与宿主机 `magpie` CLI 共用。
  - `ExecStartPre` 先 `mkdir -p %E/magpie`：bind 源不存在时 podman 以 125 退出。

- Web UI 登录 key 由 `.dotter/secrets/magpie.conf` 初始化为 Podman Secret `magpie-web-key`，通过 `MAGPIE_WEB_KEY` 固定下来。首次访问使用 `https://magpie.<domain>/?k=<key>`；应用会把 key 换成浏览器 cookie。

> [!WARNING]
> 上游会把含登录 key 的链接打印到容器标准输出；Dozzle 可以查看该日志。因此能访问 Dozzle 日志的用户也能取得 Magpie Web UI key。只向可信管理员开放 Dozzle。

- 模型网关与插件 MCP 监听容器端口 `3425`，宿主机只发布到回环地址 `127.0.0.1:3425`；Traefik 只代理 web 端口 `3430`。Base URL：宿主机 `http://127.0.0.1:3425`，同在 `traefik.network` 的容器 `http://systemd-magpie:3425`，其他设备 `https://magpie.<domain>`。API 追加 `/v1`，插件 MCP 追加 `/mcp/magpie/tools/<plugin>`，都使用网关 Bearer key；HTTPS 复用现有 Web 入口，不需要额外的 Traefik 路由。

- `MAGPIE_PUBLIC_URL=https://magpie.<domain>` 只改变 UI 展示和复制出来的地址，不覆盖 Library 自动登记的 MCP 地址（由 `MAGPIE_ADDR` 推导，每次插件加载都会重写）；外部应用直接填上面那行里的 HTTPS MCP 地址和 Bearer key。

## 记忆插件（Nowledge Mem）

可选：用 `@magpie-community/gateway-nowledge-mem` 对接 [Nowledge Mem](nowledge-mem.md)（召回 + 采集）。以下仅针对模型请求，`/mcp` 不经过这些钩子。

- `serverUrl=http://systemd-nowledge-mem:14242`：容器内的回环指向自己，跨容器只能走明文，所以插件要开 `allowInsecureHttp=true`，且仅限可信容器网络。
- 带命名 key 的调用方都按 `gateway-key` 处理：当前 rootless 端口转发下，宿主回环的 `curl 127.0.0.1:3425` 也算这一类。需要召回/采集时分别开启 `recallRemote` / `captureRemote`；只采集用户消息时设 `captureFilter="human"`。
- 插件页的 Test 按钮在 `magpie web` 模式下不可用，用真实模型请求验证；`apiKey` 只在插件页填，别走 CLI 参数（会留在 shell history）。
- Mem 的蒸馏 LLM 若指向 Magpie（`http://systemd-magpie:3425/v1`），它自己的请求也会被召回、采集，形成回环。把 Mem 的 agent 名加入 `skipAgents`；agent 名取自 `usage.jsonl`，设置前先确认它非空且不与真实客户端重名。已形成回环时先停用插件：`magpie plugin off @magpie-community/gateway-nowledge-mem`。

> [!WARNING]
> 开启远程召回/采集后，获准经过该插件的 caller key 就获得了相应的 Mem 访问能力，包括以后新建的 key；不要把 caller key 当作记忆隔离边界。

## 公司网络下的 npm 源

公司封闭网络禁了 `registry.npmjs.org` 与国内镜像，只能访问需要 token 的 Artifactory npm 仓库。Magpie 有两条 npm 消费链，都读同一个文件 `/config/magpie/plugins/.npmrc`（宿主 `~/.config/magpie/plugins/.npmrc`）：

- **bun 安装插件**：bun 以 `plugins/` 为工作目录，读取 `package.json` 旁边的 `.npmrc`。
- **Magpie 自身（Go）的 npm 元数据**：Discover 的版本号、更新检查、README 与搜索。自 v0.1.2274 起它们请求「当前 npm 源」，不再硬编码 `registry.npmjs.org`。

该文件由 dotfiles 仓库的 `magpie` package 渲染，需要 `registry=` 与 `//<host>/<path>/:_authToken=` 两行，本仓库不管理它。

> [!IMPORTANT]
> Go 侧只从 `.npmrc` 的 `_authToken` 读 token（`plugins/.npmrc` 与 `$HOME/.npmrc`，`$HOME` 在容器内是 `/config/home`），**不读** bunfig 的 `token`，也不支持 `_auth`。token 只放在 bunfig 里时 bun 安装正常，但 Go 侧匿名请求会得到 401，Discover 版本号显示为空。`${VAR}` 展开只认这一种写法，`${VAR?}` 不被识别。

选择顺序（先命中先用）：界面/`magpie plugin registry` 设置（`settings.json` 的 `npmRegistry`）> 进程环境 `BUN_CONFIG_REGISTRY`/`NPM_CONFIG_REGISTRY` > 登录 shell 同名变量 > `plugins/bunfig.toml` > `plugins/.npmrc` > `$XDG_CONFIG_HOME/.bunfig.toml` > `~/.bunfig.toml` > `~/.npmrc` > 国内镜像开关 > npm 官方源。

> [!WARNING]
> 不要点界面「npm 源」一行的「修改」。它只存 URL、不能填 token，写入的 `settings.json` 又由 dotfiles 渲染；设置后 Magpie 还会向 bun 注入 `BUN_CONFIG_REGISTRY`，覆盖 `.npmrc` 里的配置。这一行只用来确认当前来源，应显示 `来自 /config/magpie/plugins/.npmrc`。

> [!WARNING]
> **切勿打开「国内镜像」（chinaMirror）开关**：它会先请求返回 503 的 npmmirror 和被封的 jsDelivr 再回退。

> [!NOTE]
> 旧版本需要 Traefik 内部入口把 `@scope%2Fname` 改写成未编码路径并注入 Bearer。现在不再需要：Artifactory 已接受 `%2F`，前缀由 registry URL 自带，认证由 `.npmrc` 提供。若换了不接受 `%2F` 的仓库，才需要恢复那层改写。

已知缺口：Agent CLI 的更新检查仍硬编码 `registry.npmjs.org`，没有回退。容器里没有检测到任何 Agent CLI，影响可忽略。Discover 搜索请求 Artifactory 的 `/-/v1/search`，实测约 55 秒，属于仓库侧延迟。

### Podman Secret

| Secret           | 用途            | 初始化位置                                               |
| ---------------- | --------------- | -------------------------------------------------------- |
| `magpie-web-key` | Web UI 登录 key | `.dotter/secrets/magpie.conf`（`hex:32`，dotter 自动建） |

## 参考

- [Magpie README：Docker、Web UI 与配置文件](https://github.com/yetone/magpie#docker)
- [Magpie releases](https://github.com/yetone/magpie-releases/releases)（npm 源设置自 v0.1.2274）
- [Magpie 插件文档：The npm registry plugins come from](https://github.com/yetone/magpie/blob/main/docs/subsystems/provider-plugins.md)
- [Bun：.npmrc 支持](https://bun.com/docs/pm/npmrc)
