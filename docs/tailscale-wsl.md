# Tailscale on WSL2（worklab.com）

homelab 运行在 WSL2（Debian 13）内、域名为 `worklab.com` 时的接入方式。Split DNS 的整体思路、ACL 与远程访问流程见 [tailscale.md](tailscale.md)，本文只记录与 m600 默认方案的差异。

## 与默认方案的差异

| 项       | m600（默认方案）                             | 本机 WSL2                                                                    |
| -------- | -------------------------------------------- | ---------------------------------------------------------------------------- |
| 域名     | `homelab.com`                                | `worklab.com`                                                                |
| 本机解析 | systemd-resolved + NetworkManager dispatcher | tailscaled 接管 `/etc/resolv.conf`（`100.100.100.100`）；Windows 侧仍走 NRPT |
| dnsmasq  | 单实例，监听 `127.0.0.1` + TS_IP，回答 TS_IP | 双实例：主实例回答 WSL IP，tailnet 实例回答 TS_IP                            |
| 网络     | 物理网卡                                     | WSL2 NAT，无 UDP 直连                                                        |

> 文中用 `<WSL_IP>` 指代 WSL eth0 地址，按实际值替换。TS IP 实测 `100.88.64.107`（2026-11-19）。

## 安装

使用官方 apt 源（Debian 13 trixie）：

```bash
curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg \
  | sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.tailscale-keyring.list \
  | sudo tee /etc/apt/sources.list.d/tailscale.list >/dev/null
sudo apt update && sudo apt install -y tailscale
sudo systemctl enable --now tailscaled
sudo tailscale up --hostname=office-wsl
```

> [!WARNING]
> 带 flag 的 `tailscale up` 会把未传的项按默认值处理，若因此改变现有设置就直接报错（除非加 `--reset`）。只想改单项就用 `tailscale set`，它只动显式给出的字段。

## DNS：两个 dnsmasq 实例

dnsmasq 的 `address=` 是全局配置，无法按查询来源返回不同 A 记录，而两类客户端需要的地址不同：

- Windows 浏览器经 NRPT 查询，必须拿到 WSL eth0 IP（`<WSL_IP>`），否则 Windows 到不了 `100.64.0.0/10`
- tailnet 设备经 Split DNS 查询，必须拿到 Tailscale IP（如 `100.88.64.107`），否则无法经 tailnet 路由

因此用 Debian 自带的 `dnsmasq@.service` 模板再起一个只监听 tailscale0 的实例。两份配置都属于 host 级配置，不在 dotter 管理范围内。

### 主实例

`/etc/dnsmasq.d/worklab.conf`：

```conf
listen-address=<WSL_IP>
no-resolv
domain-needed
bogus-priv
local=/worklab.com/
address=/.worklab.com/<WSL_IP>
bind-dynamic
```

> [!IMPORTANT]
> `bind-dynamic` 必需。默认情况下 dnsmasq 会绑 `0.0.0.0:53`，tailnet 实例就无法再绑 TS IP，开机顺序还会导致随机失败。

### tailnet 实例

`/etc/default/dnsmasq.tailnet`：

```conf
CONFIG_DIR=/etc/dnsmasq-tailnet.d
```

`/etc/dnsmasq-tailnet.d/tailnet.conf`：

```conf
bind-dynamic
listen-address=<TS_IP>
no-resolv
no-hosts
domain-needed
bogus-priv
local=/worklab.com/
address=/.worklab.com/<TS_IP>
cache-size=0
```

启用：

```bash
sudo systemctl enable --now dnsmasq@tailnet
```

> [!NOTE]
> 实例配置里没有 `--local-service`，所以会接受 `100.64.0.0/10` 的查询；`no-resolv` + 只有 `worklab.com` zone，不做通用递归。

## Windows NRPT 不变

Windows 侧仍把 `.worklab.com` 指到 WSL eth0 IP，路径不受 Tailscale 影响：

```text
Namespace   : {.worklab.com}
NameServers : <WSL_IP>
```

## Admin Console Split DNS

1. 打开 [Tailscale Admin Console](https://login.tailscale.com/admin/dns)
1. **Nameservers** → **Add nameserver** → **Custom**
1. Nameserver 填 `<TS_IP>`，**Restrict to domain** 填 `worklab.com`
1. 不要开启 Override local DNS

当前控制台下发的路由（`tailscale dns status`）：

```text
homelab.com  -> 100.94.150.93
ts.net.      -> 199.247.155.53 / 2620:111:8007::53
worklab.com  -> 100.88.64.107
```

## ACL 与跨主机访问

当前生效的 `grants`：

| src                | dst           | ip                                      |
| ------------------ | ------------- | --------------------------------------- |
| `autogroup:member` | `tag:homelab` | `*`                                     |
| `tag:homelab`      | `tag:homelab` | `tcp:80`、`tcp:443`、`udp:53`、`tcp:53` |
| `*`                | `tag:relay`   | `app: tailscale.com/cap/relay`          |

- `autogroup:member → tag:homelab`：member 设备（手机、PC）访问 homelab，这是 Split DNS 生效的前置条件
- `tag:homelab → tag:homelab`：homelab 节点之间互访。不加时，两台 tagged 节点不会出现在彼此的 `tailscale status` 里，`tailscale ping` 报 `no matching peer`
- 端口按需开：只走 Traefik 时给 `tcp:80`、`tcp:443`；需要跨主机查 DNS 再补 `udp:53`、`tcp:53`

实测（office-wsl → m600）：`tcp:443`、`tcp:80`、`tcp:53` 通，`udp:53` 应答，`tcp:22` 被拦 —— 与上表一致。

> [!NOTE]
> `ip: ["*"]` 会把 SSH、数据库等全部端口一起放行。homelab 内部互访优先用窄端口列表，或按角色拆 tag 后逐对授权。

## 验证

```bash
# 两个实例都在监听
ss -lntup | grep ':53 '

# tailnet 侧回答 TS IP，本机侧回答 WSL IP
dig +short @<TS_IP> dozzle.worklab.com
dig +short @<WSL_IP> dozzle.worklab.com

# 控制台下发的 Split DNS 路由（需要管理员/操作员权限）
tailscale dns status

# Traefik 在 TS IP 上可访问
curl -sk -o /dev/null -w '%{http_code}\n' \
  --resolve dozzle.worklab.com:443:<TS_IP> https://dozzle.worklab.com
```

## 排障记录：`dnsmasq@tailnet` 启动失败

- **触发条件**：主实例仍是默认的 wildcard 绑定（`0.0.0.0:53`）时启动 `dnsmasq@tailnet`
- **判断依据**：`journalctl -u dnsmasq@tailnet` 出现 `failed to create listening socket for <TS_IP>: Address already in use`；`ss -lntup | grep ':53 '` 显示主实例占 `0.0.0.0:53`
- **修复**：主实例配置加 `bind-dynamic` → `sudo systemctl restart dnsmasq` → `sudo systemctl restart dnsmasq@tailnet`
- **适用边界**：WSL 上这台机器的本地契约；m600 的单实例方案不适用

## 已知限制

- `tailscale netcheck` 会显示 `UDP: false`：本机发不出公网 UDP，拿不到 STUN 映射，全部 peer 只能走 DERP 中继。能用但延迟高于直连，详见下方排障记录
- tailscaled 接管 `/etc/resolv.conf` 后，原文件备份在 `/etc/resolv.pre-tailscale-backup.conf`。停止、重启、乃至启动失败后都由 systemd 的 `ExecStopPost=tailscaled --cleanup` 还原；只有断电或强制终止导致来不及收尾时才会残留。补救：`sudo tailscaled --cleanup`，或直接 `sudo mv /etc/resolv.pre-tailscale-backup.conf /etc/resolv.conf`
- Split DNS 里的 `homelab.com` 查询要经 DERP 送到 m600，实测约 1.6s；本机通常不需要它
- WSL 停止时节点和 DNS 都离线；客户端会解析失败，而不是回落到公网地址
- `*.worklab.com` 是 mkcert 证书，远程设备需安装根 CA，见 [browser-trust.md](browser-trust.md)
- WSL 把 NAT 地址持久化在注册表 `HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss` 的 `NatIpAddress`，实测三次启动（含一次 Windows 重启）eth0 地址始终不变，日常重启不需要同步 NRPT 与主实例配置；只有重置 WSL 或更换发行版时才需重新对齐。TS IP 在节点删除重建后会变，届时更新 tailnet 实例配置和 Admin Console

## 排障记录：全部 peer 走 DERP

### 现象

| 设备                   | Relay | `tailscale ping`     |
| ---------------------- | ----- | -------------------- |
| `m600`                 | sfo   | 350~1100ms，抖动明显 |
| `nothing-phone-4a-pro` | sfo   | 519~956ms            |
| `relay-vps`            | lax   | 376~1192ms           |

所有 peer 的 `CurAddr` 为空，`ping` 结尾固定是 `direct connection not established`。

### 判断依据

```bash
tailscale status --json   # Peer[*].CurAddr 为空 = 无直连路径
tailscale ping m600       # 只出现 via DERP(...)，结尾 direct connection not established
tailscale netcheck        # UDP: false；IPv4: (no addr found)；PortMapping 为空
```

绕开 tailscaled 直接测公网 UDP：

```bash
dig +time=3 +tries=1 @1.1.1.1 example.com        # 超时
dig +tcp +time=3 +tries=1 @1.1.1.1 example.com   # 正常
```

公网 UDP 出站被上游丢弃，TCP 正常。对端 `m600` 的 netcheck 是 `UDP: true` 且公网映射成功，所以是**本机单边**发不出打洞包。

> [!IMPORTANT]
> 只说明「公网 UDP 不通」，**不等于 tailnet 内 UDP 不通**。`m600 -> 100.88.64.107:53` 的 UDP 查询能正常应答，只是慢（约 1.9s）。不要据此推断 ACL 丢弃了 UDP 53。

### 结论与边界

- **换方向无效**：WireGuard 路径按 peer 对协商，本机 ↔ 对端走 DERP，反向也是同一条。
- **peer relay 不可用**：`tag:relay` 加 ACL 的 `tailscale.com/cap/relay` 只是许可；peer relay 同样要求客户端能发 UDP 到 relay。本机发不出 UDP 时这条路走不通，不要投入时间。
- **只影响本机这一对**：手机 ↔ m600 是独立路径，与本机访问 `worklab.com` 无关。
- **DERP region 由每台设备各自 netcheck 决定**，本地改不了对端的选择；它只影响中继手感，不影响能否直连。

### tailnet 内 DNS 的实测延迟

`worklab.com` 的 Split DNS 指向 `100.88.64.107:53`，查询能成功，但延迟远高于 TCP：

```bash
# 从 m600 查询（UDP）
dig +time=3 +tries=1 @100.88.64.107 worklab.com
# Query time: 1924 msec

# 同一目标走 TCP
dig +tcp @100.88.64.107 worklab.com
# Query time: 380 msec

# 反向（本机 -> m600 的 dnsmasq，UDP）
dig @100.94.150.93 homelab.com
# Query time: 304~312 msec，偶发 696 / 1060 msec
```

dnsmasq 侧日志证实查询确实到达并被应答：

```text
query[A] worklab.com from 100.94.150.93
config worklab.com is 100.88.64.107
```

所以既不是 ACL 丢弃，也不是 dnsmasq 配置问题。根因仍是**全部流量走 DERP 中继**：UDP 在 DERP 上没有直连路径可复用，延迟被放大到接近 2 秒。

> [!WARNING]
> 不要用 `dig +time=2` 测这条链路。回包大约 1.9 秒才到，2 秒超时会间歇性失败，容易误判成「UDP 不通」。排查时至少用 `+time=3`，并以 dnsmasq 日志为准。

### 结论：别依赖 Split DNS，改用 hosts

`worklab.com` 目前只有一个目标 IP，走 Split DNS 的收益远小于它带来的延迟和不确定性。在需要访问的客户端上直接写 hosts 更可靠：

```bash
echo '100.88.64.107 worklab.com dozzle.worklab.com nowledge-mem.worklab.com multica.worklab.com multica-api.worklab.com magpie.worklab.com traefik.worklab.com' | sudo tee -a /etc/hosts
```

若改用 hosts，需同步删除 Admin Console 里的 `worklab.com -> 100.88.64.107` Split DNS 路由，否则客户端仍会先尝试该解析并等到超时，拖慢首次访问。

### 直连的前提条件（当前未达成）

DERP 之外要建立直连，需同时满足：

1. 两端都能向公网发 UDP，并各自拿到 STUN 映射
1. 至少一端可被直连，或双方 NAT 允许打洞
1. 中间链路不按目的地址或端口丢弃 UDP

当前第 1 条在本机就不成立（`UDP: false`、无公网映射），因此只能走 DERP。这属于上游网络策略，本地配置改不了；可尝试的只有绕开该策略，或换到有公网 IPv4/IPv6 的节点。

> [!NOTE]
> 用 `tailscale netcheck` 排查对端时，它只是只读诊断，不会让 daemon 重新选 region。想强制重评估要重启 `tailscaled`。

### 手机上如何看直连还是中继

App 的设备列表和详情页只有 `Connected` / 地址 / 系统 / 密钥到期，**不显示路径**。路径只在 ping 面板里：设备详情页右上角的 Ping 图标 → 出现结果后标题下方显示 `Direct connection`、`Relayed connection (<region>)` 或 `Peer relayed connection`。

在 Linux 节点上交叉验证更快：`tailscale status` 中该 peer 显示 `active; direct <ip:port>` 即直连，`active; relay "<region>"` 即中继。

## 参考

> [!IMPORTANT]
> 修改本文档前，先查阅以下官方链接验证配置是否过时。

- [Tailscale Split DNS](https://tailscale.com/kb/1054/dns)
- [Tailscale package repository](https://pkgs.tailscale.com/stable/)
- [tailscaled(8)](https://man.archlinux.org/man/tailscaled.8.en)
- [dnsmasq(8)](https://man.archlinux.org/man/dnsmasq.8.en)
