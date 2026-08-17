# DeepSeek Harness

DeepSeek Harness 的默认 Quadlet、Dotter 和 Traefik 规则分别见
[`docs/quadlet.md`](quadlet.md)、[`docs/dotter.md`](dotter.md) 和
[`docs/traefik.md`](traefik.md)。本文只记录本服务的额外差异。

## 运行时差异

镜像使用官方 `node:24-slim`，通过 `package-lock.json` 和 `npm ci`
安装固定版本的 `@deepseek-ai/dsh`。Node 24 是 LTS，并满足当前上游要求的
Node `^22.19.0 || >=24.0.0`；不使用 Alpine，避免依赖树中的 native module
遇到 musl 兼容差异。

镜像使用 builder stage 编译 `node-pty` native module，最终 runtime 只保留
运行所需的 Node、Bash 和 Git，不把 Python、make、g++ 带入最终镜像。

Quadlet 使用固定的本地镜像 tag `localhost/deepseek-harness:latest`。实际的
DeepSeek Harness 版本只在 `package.json` 和 `package-lock.json` 中维护；
`prepare-image.sh` 以 lockfile 的 sha256 为构建标记，镜像存在且 lockfile 未变时
直接跳过，lockfile 变化后自动重建，不做额外版本 tag 或 OCI label。

上游 CLI 刻意拒绝 `--host 0.0.0.0`。容器通过内置 patch 将 Web server 绑定到
所有容器接口，使 Traefik 能够访问；同时用 Traefik 域名作为显式 trusted host。
HTTPS 路由引用 Traefik 共享的 `homelab-internal@file` middleware，只放行
`trusted_source_ranges` 配置的来源（本机网段 + Tailscale 预留段）。它是网络访问控制，不是用户登录认证；如果引入
公网反向代理，不能因为代理位于可信网段就默认放行公网用户。不要把容器发布到非 loopback 端口，
也不要把该域名暴露给不受信任的网络（loopback 例外的 PublishPort 见下节）。共享策略的定义和变量契约见
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

dsh 把配置面（`settings.*`、`credentials.*`、`llm.discoverModels` 等）列为特权方法：即使配置了
`trustedHosts`，这些 RPC 也强制要求 loopback 同源（源码 `PRIVILEGED_METHODS` + 空信任列表）。
`trustedHosts` 只是 DNS-rebinding 防御，不是认证；在真正的认证层出现前，整个配置面钉死在 loopback。
因此：

- 非特权面（会话、模型目录 `llm.providers` 等）可通过 HTTPS 域名入口访问
- 设置/凭据页面走域名入口必然 403，这是设计行为，不是故障

容器通过 `PublishPort=127.0.0.1:3080:3080` 把 Web 端口发布到宿主 loopback（不暴露到 LAN）：
本机浏览器访问 `http://127.0.0.1:3080` 获得完整功能（含设置与凭据面），利用 WSL 的
localhost 转发可从 Windows 浏览器直接访问。不要移除该 PublishPort，否则特权面不可用；
也不要改成 `0.0.0.0` 全接口发布，会把无认证的配置面暴露到局域网。

Web UI 的「打开配置文件」不可用：它走 `settings.openDocument`，服务端硬编码调用
`xdg-open`（桌面打开器），容器内没有该命令，点击必报「无法打开」。`agentPreset.openDocument`
有 `canOpenPaths()` 保护（降级返回路径文本），`settings.openDocument` 没有此检查，属上游疏漏；
不做处理。配置文件在宿主机 `~/.local/share/dsh/settings.yaml`，可自行访问。

## 构建和启动

`deepseek-harness-prepare.service`（oneshot）执行部署副本
`~/.local/lib/deepseek-harness/prepare-image.sh`：镜像存在且 lockfile 哈希未变时
幂等跳过，lockfile 变化后重建 `:latest`。构建时若宿主机存在 `~/.npmrc`，通过
`podman build --secret` 挂入 builder 的 npm ci（同一底层 Artifactory 认证），
secret 不进入镜像层；容器运行时不挂载 npmrc（dsh 以 `node` 用户运行，且把
registry token 交给能执行 bash 的 agent 得不偿失）。

更新上游版本时，在仓库的 `deepseek-harness/runtime/` 目录执行：

```sh
npm install --package-lock-only --save-exact @deepseek-ai/dsh@latest \
  --ignore-scripts --no-audit --no-fund
```

该命令更新 `package.json` 和 `package-lock.json`；随后重新部署并重启：

```sh
dotter deploy
systemctl --user restart deepseek-harness-prepare.service deepseek-harness.service
```

lockfile 哈希变化会触发 prepare 自动重建，无需手工改镜像 tag。

## 参考

- <https://github.com/deepseek-ai/deepseek-harness/>
- <https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/user/guide/index.md>
- <https://github.com/nodejs/docker-node>
- <https://nodejs.org/en/about/previous-releases>
