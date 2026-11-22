# Tailscale：WSL2 主机（worklab.com）

homelab 运行在 WSL2（Debian 13）内、域名为 `worklab.com` 时的接入方式。分层、占位符、ACL、Split DNS 路由、`dnsmasq@tailnet` 配置模板与时序见 [tailscale.md](tailscale.md)，本文只记录与 m600 的差异。

## 与 m600 的差异

| 项           | m600                                         | WSL2                                                                                                                                                                                         |
| ------------ | -------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 域名         | `homelab.com`                                | `worklab.com`                                                                                                                                                                                |
| 本机解析     | systemd-resolved + NetworkManager dispatcher | 默认无 systemd-resolved，tailscaled 接管 `/etc/resolv.conf`（`100.100.100.100`），可选方案见[改用 systemd-resolved](#%E5%8F%AF%E9%80%89%E6%94%B9%E7%94%A8-systemd-resolved)；Windows 走 NRPT |
| 主实例       | 监听 `127.0.0.1`，答 `127.0.0.1`             | 监听 `<WSL_IP>`，答 `<WSL_IP>`，供 Windows NRPT 使用                                                                                                                                         |
| tailnet 实例 | 自写 `dnsmasq@.service`                      | Debian 自带 `dnsmasq@.service`                                                                                                                                                               |
| 网络         | 物理网卡                                     | WSL2 NAT，发不出公网 UDP，peer 全部走 DERP                                                                                                                                                   |

> [!NOTE]
> WSL 自身解析 `*.worklab.com` 走的是 Split DNS（`100.100.100.100` → `<WSL_TS_IP>` 上的 tailnet 实例），不经过主实例；主实例只服务 Windows NRPT。所以默认模式下 tailscaled 停止后，WSL 内部也解析不了 `*.worklab.com`（`resolv.conf` 还原为 WSL 自带的上游 DNS），但 Windows 侧不受影响。

> [!NOTE]
> Windows 浏览器经 NRPT 查询，必须拿到 `<WSL_IP>`，否则到不了 `100.64.0.0/10`；tailnet 设备必须拿到 `<WSL_TS_IP>`。所以两个实例各答各的，理由与 m600 相同。

## 安装

使用官方 apt 源（Debian 13 trixie）：

```bash
curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg \
  | sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.tailscale-keyring.list \
  | sudo tee /etc/apt/sources.list.d/tailscale.list >/dev/null
sudo apt update && sudo apt install -y tailscale
sudo systemctl enable --now tailscaled
sudo tailscale up --hostname=office-wsl --advertise-tags=tag:homelab
```

`up` 与 `set` 的区别见 [tailscale.md](tailscale.md#%E9%85%8D%E7%BD%AE%E6%AD%A5%E9%AA%A4m600)。

## DNS：两个 dnsmasq 实例

两份配置都属于 host 级配置，不在 dotter 管理范围内。

### 主实例

与 [traefik.md](traefik.md) 的 WSL 分支相同，把域名换成 `worklab.com`。

> [!IMPORTANT]
> 主实例必须绑定具体地址，不能绑 `0.0.0.0:53`（`bind-interfaces` 或 `bind-dynamic` 均可，office-wsl 现用 `bind-dynamic`）。否则 `dnsmasq@tailnet` 启动时报 `failed to create listening socket for <WSL_TS_IP>: Address already in use`。修复：主实例加上其中一项，依次重启 `dnsmasq` 与 `dnsmasq@tailnet`。

### tailnet 实例

`/etc/default/dnsmasq.tailnet`：

```conf
CONFIG_DIR=/etc/dnsmasq-tailnet.d
```

`/etc/dnsmasq-tailnet.d/tailnet.conf`：内容使用 [tailscale.md](tailscale.md#2-%E8%B5%B7-dnsmasqtailnet-%E5%AE%9E%E4%BE%8B) 的模板，`homelab.com` 换成 `worklab.com`，地址换成 `<WSL_TS_IP>`。

```bash
sudo systemctl enable --now dnsmasq@tailnet
```

> [!NOTE]
> 实例配置里指定了 `listen-address`，Debian helper 追加的 `--local-service` 不再起限制作用，所以会接受 `100.64.0.0/10` 的查询。

### Windows NRPT

Windows 侧仍把 `.worklab.com` 指到 `<WSL_IP>`，路径不受 Tailscale 影响，配置见 [traefik.md](traefik.md) 的 WSL 分支。

## 验证

```bash
# 两个实例都在监听
ss -lnH 'sport = :53'

# tailnet 侧回答 WSL_TS_IP，本机侧回答 WSL_IP
dig +short @<WSL_TS_IP> dozzle.worklab.com
dig +short @<WSL_IP> dozzle.worklab.com

# Traefik 在 Tailscale IP 上可访问
curl -sk -o /dev/null -w '%{http_code}\n' \
  --resolve dozzle.worklab.com:443:<WSL_TS_IP> https://dozzle.worklab.com
```

## 可选：改用 systemd-resolved

默认情况下 WSL 没有 systemd-resolved，tailscaled 以 `direct` 模式改写 `/etc/resolv.conf`（`CorpDNS: true`）。改用 resolved 后结构与 m600 一致：`resolv.conf` 指向 resolved 的 stub，tailscaled 只配置 `tailscale0`，tailscaled 停止不再影响 WSL 自身解析。不想接管时，也可以只执行 `sudo tailscale set --accept-dns=false`，代价是 WSL 内部不再解析 `*.ts.net`、`homelab.com` 和 `worklab.com`。

> [!IMPORTANT]
> tailscaled 只看 `/etc/resolv.conf` 的内容归属选择模式：必须指向 `/run/systemd/resolve/stub-resolv.conf`，仅装上 resolved、`resolv.conf` 仍指向 `/mnt/wsl/resolv.conf` 时它依然走 `direct`。

`<WIN_DNS>` 取 `/mnt/wsl/resolv.conf` 中的 nameserver（NAT 模式下即默认网关）：

```bash
sudo apt install -y systemd-resolved   # 安装脚本会把 /etc/resolv.conf 换成指向 stub 的符号链接
sudo mkdir -p /etc/systemd/resolved.conf.d
printf '[Resolve]\nDNS=<WIN_DNS>\n' | sudo tee /etc/systemd/resolved.conf.d/wsl-upstream.conf
sudo systemctl enable --now systemd-resolved && sudo systemctl restart systemd-resolved
# /etc/wsl.conf 的 [network] 加 generateResolvConf = false，wsl --shutdown 后生效
sudo systemctl stop tailscaled         # 还原被接管的 resolv.conf
sudo ln -sfn /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
sudo systemctl start tailscaled
```

不配 `DNS=` 时 resolved 会回退到公网 Fallback DNS，而本机公网 UDP 不通，也绕开了 Windows 侧 DNS。tailscaled 官方单元已带 `After=systemd-resolved.service`，不需要额外的顺序单元。

验证：tailscaled 日志出现 `using "systemd-resolved" mode`，`resolvectl status` 里 `tailscale0` 带 `~worklab.com`、`~homelab.com`、`~ts.net`，公网域名走 eth0。

> [!WARNING]
> 切换前已经在运行的容器仍沿用旧的 rootless netns 快照：`169.254.1.1` 指向切换前的 `100.100.100.100`，resolved 模式下它对公网域名返回 SERVFAIL，表现为容器里能解析 `worklab.com`、解析不了公网域名。停掉**全部**容器（含 `http.socket`、`https.socket`）再启动即可重建快照，机制与核对方法见 [quadlet.md](quadlet.md#%E5%AE%B9%E5%99%A8%E7%9A%84%E5%A4%96%E9%83%A8-dns)。预期快照是 `169.254.1.1` 加上 `/run/systemd/resolve/resolv.conf` 中的非回环条目。`wsl --shutdown` 预期等价，未验证。

回滚：停止 tailscaled，删除 `/etc/systemd/resolved.conf.d/wsl-upstream.conf`，`ln -sfn /mnt/wsl/resolv.conf /etc/resolv.conf`，还原 `/etc/wsl.conf`，`systemctl disable --now systemd-resolved`，再启动 tailscaled。

## 已知限制

- **全部走 DERP**：`tailscale netcheck` 显示 `UDP: false`，本机发不出公网 UDP，所有 peer 只能走 DERP。能用但延迟高于直连，详见下一节。
- **Peer Relay 帮不上**：它同样要求客户端能用 UDP 到达 relay，见 [tailscale-relay.md](tailscale-relay.md)。
- **`resolv.conf` 备份**：tailscaled 接管后，原文件备份在 `/etc/resolv.pre-tailscale-backup.conf`，停止或重启后由 `ExecStopPost=tailscaled --cleanup` 还原。强制终止后残留时执行 `sudo tailscaled --cleanup`。
- **WSL 停止即离线**：节点和 DNS 都下线，客户端解析失败，不会回落到公网地址。
- **`worklab.com` 证书**：mkcert 签发，远程设备需安装根 CA，见 [browser-trust.md](browser-trust.md)。
- **地址稳定性**：实测 eth0 地址跨重启（含 Windows 重启）不变。只有重置 WSL 或更换发行版时，才需要重新对齐 NRPT 与主实例配置。

## 排障记录：全部 peer 走 DERP

**触发条件**：`tailscale netcheck` 显示 `UDP: false`，所有 peer 的 `CurAddr` 为空，`tailscale ping` 只出现 `via DERP(...)`，结尾是 `direct connection not established`，延迟 350~1100ms 且抖动明显。

**判断依据**：

```bash
tailscale status --json   # Peer[*].CurAddr 为空 = 无直连路径
tailscale netcheck        # UDP: false；IPv4: (no addr found)

# 绕开 tailscaled 直接测公网 UDP / TCP
dig +time=3 +tries=1 @1.1.1.1 example.com        # 超时
dig +tcp +time=3 +tries=1 @1.1.1.1 example.com   # 正常
```

公网 UDP 出站被上游丢弃，TCP 正常。对端 m600 的 netcheck 是 `UDP: true`，所以是**本机单边**发不出打洞包，改变连接方向无效。这属于上游网络策略，本地配置改不了。

> [!IMPORTANT]
> 「公网 UDP 不通」不等于「tailnet 内 UDP 不通」。m600 到 `<WSL_TS_IP>:53` 的 UDP 查询能正常应答，只是慢。不要据此推断 ACL 丢弃了 UDP 53。

**对 DNS 的影响**：`worklab.com` 的 Split DNS 指向 `<WSL_TS_IP>:53`，UDP 查询约 0.4s（一次 DERP 往返），TCP 约 0.8s（多一次握手），dnsmasq 日志证实查询到达并被应答，所以不是 ACL 或 dnsmasq 配置问题，是 DERP 中继的固有延迟。曾观测到 UDP 约 1.9s 的间歇性慢响应，后续未复现。

> [!WARNING]
> 测这条链路不要用 `dig +time=2`，DERP 抖动时容易误判成「UDP 不通」。至少用 `+time=3`，并以 dnsmasq 日志为准。

> [!TIP]
> 手机 App 不显示连接路径。设备详情页右上角的 Ping 图标 → 结果标题下方显示 `Direct connection`、`Relayed connection (<region>)` 或 `Peer relayed connection`。Linux 上看 `tailscale status`：`active; direct <ip:port>` 是直连，`active; relay "<region>"` 是 DERP。

## 参考

> [!IMPORTANT]
> 修改本文档前，先查阅以下官方链接验证配置是否过时。

- [Tailscale Split DNS](https://tailscale.com/kb/1054/dns)
- [Tailscale package repository](https://pkgs.tailscale.com/stable/)
- [tailscaled(8)](https://man.archlinux.org/man/tailscaled.8.en)
- [dnsmasq(8)](https://man.archlinux.org/man/dnsmasq.8.en)
