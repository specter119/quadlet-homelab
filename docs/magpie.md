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

## 参考

- [Magpie README：Docker、Web UI 与配置文件](https://github.com/yetone/magpie#docker)
- [Magpie releases](https://github.com/yetone/magpie-releases/releases)
