# Tailscale Peer Relay（relay-vps）

在 [tailscale.md](tailscale.md) 的 tailnet 之上，把国内 VPS 升级为 Peer Relay（Tailscale ≥ 1.86），让两端无法直连的国内设备走原生 WireGuard UDP 中继，替代 DERP 的 HTTPS 路径。

relay-vps 只在 L3 转发 UDP，不参与 DNS、HTTPS 路由或任何应用层逻辑：m600 的 dnsmasq、Traefik、systemd-resolved 配置完全不变。

## 前置条件

- ACL 已包含 `tag:relay` 与 `tailscale.com/cap/relay` grant，且**先保存、再** `tailscale up --advertise-tags=tag:relay`，见 [tailscale.md](tailscale.md#acl)
- relay-vps 与使用它的客户端都是 Tailscale ≥ 1.86
- 使用方必须能用 UDP 到达 relay 的端口。发不出公网 UDP 的节点（如 [WSL2](tailscale-wsl.md)）用不了

## 部署步骤

### 1. 放行 UDP 端口

在云厂商控制台的**安全组入站规则**里放行：

- **UDP 40000**：Peer Relay 中继端口（必需）
- **UDP 41641**：tailscaled 默认端口（可选，只影响直连打洞）

> [!IMPORTANT]
> 安全组在主机外部，必须在控制台放行。当前 VPS（腾讯云 CVM，Debian）未启用 `ufw` / `nftables` / `firewalld`，只需要改安全组。除此之外 Tailscale 不需要任何入站端口。

### 2. 安装 Tailscale

```bash
curl -fsSL https://tailscale.com/install.sh | sh
tailscale version  # 确认 >= 1.86
```

### 3. 加入 tailnet

```bash
sudo tailscale up \
    --hostname=relay-vps \
    --accept-dns=false \
    --advertise-tags=tag:relay \
    --operator=$USER
```

`--accept-dns=false` 让 VPS 保持系统 DNS，不参与任何 Split DNS；`--operator` 让后续 `tailscale set`、`tailscale debug` 不再需要 sudo。

### 4. 启用 Peer Relay

```bash
tailscale set --relay-server-port=40000
```

固定端口是为了和安全组规则一一对应。不设置或设为 `""` 表示关闭中继；`0` 由内核随机选端口，无法提前放行。

> [!IMPORTANT]
> 只执行 `tailscale up --advertise-tags=tag:relay` 不会开启中继，必须再执行这一步。

## 验证

在 VPS 上：

```bash
tailscale debug prefs | grep RelayServerPort   # "RelayServerPort": 40000
ss -ulnH 'sport = :40000'                      # 0.0.0.0:40000 与 [::]:40000
tailscale debug peer-relay-sessions
# Server port: 40000
# Sessions count: <N>
```

在使用方设备上：

```bash
tailscale debug peer-relay-servers             # 应列出 relay-vps 的 Tailscale IP
tailscale status                               # 走中继时显示 peer-relay <ip:port>:vni:<N>
tailscale ping <对端 Tailscale IP>             # 走中继时显示 via peer-relay(...)
```

手机上用设备详情页的 Ping 面板，走中继时显示 `Peer relayed connection`。

> [!NOTE]
> `Sessions count` 为 `0` 是正常的：只有两端都无法直连、又都能用 UDP 到达 relay 时才会建立会话。

## Peer Relay 不是什么

- **不是 Exit Node**：不会让其他设备从 VPS 出网
- **不是 Subnet Router**：不做子网路由
- **不替代 Split DNS**：`*.homelab.com` 的解析仍由 m600 的 dnsmasq 提供，Peer Relay 只加速隧道本身

VPS 上另有 tailnet 内的 Serve 服务，不归本仓库管理。

## 回滚

只关闭 relay，不卸载 Tailscale（VPS 上其他服务仍依赖它）：

```bash
tailscale set --relay-server-port=""
```

然后在安全组删除 UDP 40000 规则（保留 41641），并在 ACL 里删除 `tag:relay` 的 relay grant。其他设备会自动回退到 DERP。

## 参考

> [!IMPORTANT]
> 修改本文档前，先查阅以下官方链接验证配置是否过时。

- [Tailscale Peer Relays](https://tailscale.com/docs/features/peer-relay)
- [Tailscale CLI：set](https://tailscale.com/docs/reference/tailscale-cli#set)
- [Tailscale ACL Tags](https://tailscale.com/kb/1068/acl-tags)
- [Tailscale ACL Grants](https://tailscale.com/kb/1324/acl-grants)
