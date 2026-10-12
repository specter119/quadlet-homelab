# Magpie

默认规则见 [Quadlet 指南](quadlet.md)、[Dotter 变量契约](dotter.md) 和 [Secrets 管理](secrets.md)。本文只记录 Magpie 的容器部署差异。

## 容器部署差异

- 使用上游 GHCR 镜像，以 `magpie web --addr 0.0.0.0:3430 --no-open` 提供浏览器界面；Traefik 只代理容器端口 `3430`。
- 上游镜像以 UID `65532` 运行，配置目录由 `XDG_CONFIG_HOME=/config` 指定。本服务把 `%D/magpie` 持久化挂载到 `/config`，并用 `UserNS=keep-id` 映射目录权限。
- Web UI 登录 key 由 `.dotter/secrets/magpie.conf` 初始化为 Podman Secret `magpie-web-key`，通过 `MAGPIE_WEB_KEY` 固定下来。首次访问使用 `https://magpie.<domain>/?k=<key>`；应用会把 key 换成浏览器 cookie。

> [!WARNING]
> 上游会把含登录 key 的链接打印到容器标准输出；Dozzle 可以查看该日志。因此能访问 Dozzle 日志的用户也能取得 Magpie Web UI key。只向可信管理员开放 Dozzle。

- 模型网关监听容器端口 `3425`，只发布到宿主机回环地址 `127.0.0.1:3425`，不经 Traefik 对外路由；宿主机上的 agent 可使用 `http://127.0.0.1:3425/v1`。同在 `traefik.network` 的容器仍可直接访问 Magpie 容器端口。若需从其他设备调用网关，先按上游的 LAN sharing 说明启用带 key 的访问，再单独配置并验证网关路由。
- 容器内启动的订阅 OAuth 登录无法完成回调；按上游说明，在安装了对应 CLI 且已登录的本机导入凭据，或在本机 Magpie 完成登录后导入。

## 公司网络下的 npm 全链路（插件安装 + 元数据）

公司封闭网络禁了 `registry.npmjs.org` 与国内镜像，且出站 HTTPS 走 MITM 代理（自定义 CA）。Magpie 有两条独立的 npm 消费链，都需要显式配置才能真正工作：

### 链路一：bun 安装插件 → 项目级 `bunfig.toml`

`magpie plugin add` / Web UI 安装最终都通过 bun 落包，bun 的 registry 优先级是：**env (`NPM_CONFIG_REGISTRY`/`BUN_CONFIG_REGISTRY`) > 项目级 `bunfig.toml` > 全局 `~/.bunfig.toml`**。本服务采用**项目级 bunfig**（不设任何 npm env），持久化在 magic 数据卷内，随 `%D/magpie` 备份迁移：

```toml
# /config/magpie/plugins/bunfig.toml（宿主 ~/.local/share/magpie/magpie/plugins/）
# url 以 .dotter/local.toml 的 artifactory_url_base / artifactory_registry_path 为准
[install.registry]
url = "{{artifactory_url_base}}{{artifactory_registry_path}}/"
token = "<artifactory_token>"
```

> [!IMPORTANT]
> 项目级 bunfig.toml **固定放在 `/config/magpie/plugins/`**（bun 以 `settings.Dir()/plugins` 为工作目录，只有这里的 bunfig 会被读到）。放 `$HOME/.bunfig.toml` 不生效——容器 passwd 的 home 是 `/home/nonroot` 而 `HOME` 变量指向 `/config/home`，两者不一致且容器重启即丢。

> [!WARNING]
> 前端 **切勿打开「国内镜像」（chinaMirror）开关**：magpie 的 `registryEnv()` 只在 chinaMirror 开启且 env 无 registry 时强制注入 `BUN_CONFIG_REGISTRY=https://registry.npmmirror.com/`，会覆盖项目级 bunfig，导致安装全部 503。

### 链路二：Magpie 自身（Go）读取 npm 元数据 → Traefik npm-mirror 改写

Web 插件列表的版本号/搜索/更新检查由 Magpie **进程内 Go 代码**请求 `registry.npmjs.org/@magpie-community%2F…/latest`（scope 以 `%2F` 编码，`npmPath` 硬编码）。该写法 npm 官方接受，但 Artifactory 只认未编码 `@scope/name/latest`。因此通过 Traefik 加一个内部改写入口：

- `magpie.container` 设 `MAGPIE_MIRRORS=on` + `MAGPIE_NPM_REGISTRY=http://systemd-traefik:8081`，让 Go 的 npm 元数据请求 fallback 到 Traefik 内部入口。
- `traefik.container`：`Secret=artifactory_token,type=env,target=ARTIFACTORY_NPM_TOKEN`（转发到 Artifactory 时注入 Bearer；Artifactory 走公网 DigiCert 证书，Traefik 镜像自备 CA 即可，无需额外 CA mount）
- `traefik.toml` 增加内部 entryPoint：`[entryPoints.npm-mirror] address = ":8081"`——同一条 rewriter 服务两个入口：容器内 `http://systemd-traefik:8081`，宿主机用对外域名 `https://npm-mirror.<domain>`（443）。
- `middlewares.toml` 的 `npm-mirror-internal` router（entryPoint `npm-mirror`）依次套三个中间件：
  1. `npm-mirror-prefix.addPrefix`：补 Artifactory 仓库前缀 `/artifactory/api/npm/npm-repository-virtual-external`
  1. `npm-mirror-decode.replacePathRegex`：`%2F` → `/`（该中间件作用于 RawPath，正是保留编码的那层）
  1. `npm-mirror-auth.headers.customRequestHeaders`：`Authorization = "Bearer \{{ env "ARTIFACTORY_NPM_TOKEN" }}"`

> [!NOTE]
> token 头用 Traefik file provider 的 Go template（`{{ env … }}`）从容器 env 读取，而非直接写死；因为是 TOML 先过 dotter handlebars 再给 Traefik 渲染，模板里的 `{{` 必须用 `\{{` 转义。

> [!WARNING]
> 容器不可通过宿主 443 访问 `npm-mirror.<domain>`：Traefik 的 80/443 是宿主 socket-activation 传入的 FD，容器网络 IP 上没有监听，必 Connection refused。所以 magpie 走的是 Traefik 容器网络内的 `:8081`。**Traefik v3 已移除 `rule = "true"` 语法**，内部入口用 `PathPrefix(\`/\`)\`。

### 两个 Podman Secret

| Secret              | 用途                                             | 初始化位置                                               |
| ------------------- | ------------------------------------------------ | -------------------------------------------------------- |
| `magpie-web-key`    | Web UI 登录 key                                  | `.dotter/secrets/magpie.conf`（`hex:32`，dotter 自动建） |
| `artifactory_token` | Artifactory npm token（bun 安装 + Traefik 注入） | **运行时手动创建**，不进仓库：\`echo -n "<token>"        |

> [!IMPORTANT]
> `artifactory_token` 由运行时手动创建（值来自贵司 Artifactory npm token），换机重建时必须先重新创建，否则 bun 安装回落 401、Traefik 注入空头。复制一份到 `/config/magpie/plugins/bunfig.toml` 的 token 字段是同一份配置的一部分，注意别同步进公开仓库。

## 参考

- [Magpie README：Docker、Web UI 与配置文件](https://github.com/yetone/magpie#docker)
- [Magpie releases](https://github.com/yetone/magpie-releases/releases)
