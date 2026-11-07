# Tailscale：WSL2 主机（worklab.com）

homelab 运行在 WSL2（Debian 13）内、域名为 `worklab.com` 时的接入方式。分层、占位符、ACL、Split DNS 路由、`dnsmasq@tailnet` 配置模板与时序见 [tailscale.md](tailscale.md)，本文只记录与 m600 的差异。

## 与 m600 的差异

| 项           | m600                                         | WSL2                                                                     |
| ------------ | -------------------------------------------- | ------------------------------------------------------------------------ |
| 域名         | `homelab.com`                                | `worklab.com`                                                            |
| 本机解析     | systemd-resolved + NetworkManager dispatcher | tailscaled 接管 `/etc/resolv.conf`（`100.100.100.100`）；Windows 走 NRPT |
| 主实例       | 监听 `127.0.0.1`，答 `127.0.0.1`             | 监听 `<WSL_IP>`，答 `<WSL_IP>`，供 Windows NRPT 使用                     |
| tailnet 实例 | 自写 `dnsmasq@.service`                      | Debian 自带 `dnsmasq@.service`                                           |
| 网络         | 物理网卡                                     | WSL2 NAT，发不出公网 UDP，peer 全部走 DERP                               |

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

**对 DNS 的影响**：`worklab.com` 的 Split DNS 指向 `<WSL_TS_IP>:53`，UDP 查询约 1.9s，TCP 约 380ms，dnsmasq 日志证实查询到达并被应答，所以不是 ACL 或 dnsmasq 配置问题，是 DERP 中继放大了 UDP 延迟。

> [!WARNING]
> 测这条链路不要用 `dig +time=2`：回包约 1.9s 才到，会间歇性超时，容易误判成「UDP 不通」。至少用 `+time=3`，并以 dnsmasq 日志为准。

> [!TIP]
> 手机 App 不显示连接路径。设备详情页右上角的 Ping 图标 → 结果标题下方显示 `Direct connection`、`Relayed connection (<region>)` 或 `Peer relayed connection`。Linux 上看 `tailscale status`：`active; direct <ip:port>` 是直连，`active; relay "<region>"` 是 DERP。

## 参考

> [!IMPORTANT]
> 修改本文档前，先查阅以下官方链接验证配置是否过时。

- [Tailscale Split DNS](https://tailscale.com/kb/1054/dns)
- [Tailscale package repository](https://pkgs.tailscale.com/stable/)
- [tailscaled(8)](https://man.archlinux.org/man/tailscaled.8.en)
- [dnsmasq(8)](https://man.archlinux.org/man/dnsmasq.8.en)
