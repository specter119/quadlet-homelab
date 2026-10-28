# DeepSeek Harness

DeepSeek Harness 的默认 Quadlet、Dotter 和 Traefik 规则分别见
[`docs/quadlet.md`](quadlet.md)、[`docs/dotter.md`](dotter.md) 和
[`docs/traefik.md`](traefik.md)。本文只记录本服务的额外差异。

## 运行时差异

镜像使用官方 `node:24-slim`，通过 `npm install` 安装 `package.json` 中固定
（exact）版本的 `@deepseek-ai/dsh`。Node 24 是 LTS，并满足当前上游要求的
Node `^22.19.0 || >=24.0.0`；不使用 Alpine，避免依赖树中的 native module
遇到 musl 兼容差异。

> [!NOTE]
> 本服务刻意不维护 `package-lock.json`：只有 dsh 被精确固定，传递依赖随每次构建时的
> registry 浮动。原因是 lockfile 的 `resolved` 会写死生成时的 registry host，而 npm 默认
> 只改写 npmjs host；曾因 lockfile 指向 npmmirror、在企业网络里返回 503，`npm ci` 无限重试而卡死。
> 若要恢复 lockfile，必须用 `npm ci --replace-registry-host=always`。

builder stage 提供 g++、make、Python，只在某个 native module 没有预编译二进制时作为编译后备
（当前 `node-pty` 和 `sharp` 都使用 linux-x64 预编译包）。最终 runtime 只保留运行所需的
Node、Bash 和 Git。

Quadlet 使用固定的本地镜像 tag `localhost/deepseek-harness:latest`。实际的
DeepSeek Harness 版本只在 `package.json` 中维护；`prepare-image.sh` 以
`Containerfile`、`package.json`、`run-web.sh` 的合并 sha256 为构建标记，镜像存在且
这些输入未变时直接跳过，任一变化后自动重建，不做额外版本 tag 或 OCI label。

上游 CLI 拒绝 wildcard 地址（`--host 0.0.0.0`），要求绑定本机某个具体接口 IP。容器 IP
由网络在启动时分配，因此 `run-web.sh` 启动时读取容器的非 loopback IPv4 并通过
`--host` 传入，使 Traefik 能够访问；同时用 Traefik 域名作为显式 trusted host。
HTTPS 路由引用 Traefik 共享的 `homelab-internal@file` middleware，只放行
`trusted_source_ranges` 配置的来源（本机网段 + Tailscale 预留段）。它是网络访问控制；
应用层认证见下节的启动 token。如果引入公网反向代理，不能因为代理位于可信网段就默认放行公网用户。
不要把容器发布到非 loopback 端口，也不要把该域名暴露给不受信任的网络。共享策略的定义和变量契约见
[`docs/traefik.md`](traefik.md) 与 [`docs/dotter.md`](dotter.md)。

## 持久化边界

服务将 `$DSH_HOME` 固定为 `/var/lib/dsh`，默认绑定到
`%D/dsh`，因此以下内容会持久化：

- `settings.yaml`：Web UI 的模型和界面设置
- `.credentials.yaml`：Web UI 保存的 API credentials，属于敏感数据
- `sessions/`：会话 JSONL 日志
- `attachments/v1/`：图片附件对象
- `storages/`：Web UI 的 JSON domain storage
- `profiles/`：dsh profile 和插件 fallback 链

默认 workspace `/workspace` 绑定到 `%D/dsh/workspace`。需要让 Agent
访问其他项目时，在 `.dotter/local.toml` 的 `[variables.deepseek-harness]`
中追加 `volumes`，例如：

```toml
[variables.deepseek-harness]
volumes = [
  '/home/user/project:/workspace/project:rw,Z',
]
```

然后在 Web UI 中选择 `/workspace/project`。只持久化 `$DSH_HOME` 而不挂载项目
目录时，服务仍能打开 Web UI，但 Agent 看不到宿主机上的项目文件。

## 访问与安全边界

dsh 的每个 RPC 和 WebSocket 都要求认证。每次进程启动都会生成一个随机启动 token，并在日志中打印带
`?token=...` 的 URL（`journalctl --user -u deepseek-harness.service` 或 Dozzle 中搜索 `dsh web:`）。
启用 `log-notify` 时，`deepseek-harness/log-notify/rules.d/deepseek-harness.toml` 会在每次启动后推送
`http://127.0.0.1:3080/?token=...` 登录链接（规则机制见 [`docs/log-notify.md`](log-notify.md)）。

- 首次访问时，把该 URL 里的主机换成实际入口（如 `https://deepseek-harness.<domain>/?token=...`
  或 `http://127.0.0.1:3080/?token=...`）打开，服务端换发 cookie 并 303 到干净 URL
- cookie 默认 30 天有效，绑定 host:port（域名入口和 loopback 入口需各自换一次）。按上游文档，签名密钥
  持久化在 `$DSH_HOME/.credentials.yaml`，重启容器后已有 cookie 仍然有效
- 没有 cookie 的请求返回 401；`Host` 不在 loopback、bind IP 或 `--trusted-host` 之内返回 403

容器通过 `PublishPort=127.0.0.1:3080:3080` 把 Web 端口发布到宿主 loopback（不暴露到 LAN），
供本机直连（利用 WSL 的 localhost 转发可从 Windows 浏览器直接访问）。不要改成 `0.0.0.0`
全接口发布。

Web UI 的「打开配置文件」不可用：服务端调用 `xdg-open`，容器内没有该命令。不做处理，配置文件在宿主机
`~/.local/share/dsh/` 下，可自行访问。

## 构建和启动

`deepseek-harness-prepare.service`（oneshot）执行部署副本
`~/.local/lib/deepseek-harness/prepare-image.sh`：镜像存在且构建输入哈希未变时
幂等跳过，输入变化后重建 `:latest`。构建时若宿主机存在 `~/.npmrc`，通过
`podman build --secret` 挂入 builder 的 npm install（同一底层 Artifactory 认证），
secret 不进入镜像层；容器运行时不挂载 npmrc（dsh 以 `node` 用户运行，且把
registry token 交给能执行 bash 的 agent 得不偿失）。

更新上游版本时，把 `deepseek-harness/runtime/package.json` 中 `@deepseek-ai/dsh` 改成目标版本
（先用 `npm view @deepseek-ai/dsh dist-tags` 确认；避免 `alpha` tag），再重新部署并重启：

```sh
dotter deploy
systemctl --user restart deepseek-harness-prepare.service deepseek-harness.service
```

`package.json` 哈希变化会触发 prepare 自动重建，无需手工改镜像 tag。升级后先确认
`run-web.sh` 用到的 CLI 参数（`web --help`）和上节认证行为是否仍成立。

哈希标记保存在 `~/.cache/deepseek-harness/build.inputhash`，标记缺失视为需要重建。要强制重建，删除该标记并重启
`deepseek-harness-prepare.service`。

## 参考

- <https://github.com/deepseek-ai/deepseek-harness/>
- <https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/user/guide/index.md>
- <https://github.com/nodejs/docker-node>
- <https://nodejs.org/en/about/previous-releases>
