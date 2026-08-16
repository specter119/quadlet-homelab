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

Quadlet 使用固定的本地镜像 tag `localhost/deepseek-harness:runtime`。实际的
DeepSeek Harness 版本只在 `package.json` 和 `package-lock.json` 中维护；构建脚本
会从 lock 文件读取解析后的版本，写入 OCI label，并额外创建版本 tag 供追踪。

上游 CLI 刻意拒绝 `--host 0.0.0.0`。容器通过内置 patch 将 Web server 绑定到
所有容器接口，使 Traefik 能够访问；同时用 Traefik 域名作为显式 trusted host。
HTTPS 路由引用 Traefik 共享的 `homelab-internal@file` middleware，默认只放行
本机配置的 LAN 和 Tailscale 来源。它是网络访问控制，不是用户登录认证；如果引入
公网反向代理，不能因为代理位于可信网段就默认放行公网用户。不要把容器直接发布
到宿主机端口，也不要把该域名暴露给不受信任的网络。共享策略的定义和变量契约见
[`docs/traefik.md`](traefik.md) 与 [`docs/dotter.md`](dotter.md)。

## 持久化边界

服务将 `$DSH_HOME` 固定为 `/var/lib/dsh`，默认绑定到
`%D/deepseek-harness`，因此以下内容会持久化：

- `settings.yaml`：Web UI 的模型和界面设置
- `.credentials.yaml`：Web UI 保存的 API credentials，属于敏感数据
- `sessions/`：会话 JSONL 日志
- `attachments/v1/`：图片附件对象
- `storages/`：Web UI 的 JSON domain storage
- `profiles/`：dsh profile 和插件 fallback 链

默认 workspace `/workspace` 绑定到 `%D/deepseek-harness/workspace`。需要让 Agent
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

## 构建和启动

`deepseek-harness-prepare.service` 会构建 `:runtime` 镜像，并从 lock 文件读取
实际的上游版本。更新上游版本时，在该服务目录执行：

```sh
npm install --package-lock-only --save-exact @deepseek-ai/dsh@latest \
  --ignore-scripts --no-audit --no-fund
```

该命令更新 `package.json` 和 `package-lock.json`；随后重新部署并重启：

```sh
dotter deploy
systemctl --user restart deepseek-harness-prepare.service deepseek-harness.service
```

不需要手工修改镜像 tag；prepare unit 会重新构建 `:runtime`，并保留一个与
上游 npm 版本对应的追踪 tag。

## 参考

- <https://github.com/deepseek-ai/deepseek-harness/>
- <https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/user/guide/index.md>
- <https://github.com/nodejs/docker-node>
- <https://nodejs.org/en/about/previous-releases>
