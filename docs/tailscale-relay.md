# Tailscale Peer Relay 与 Homelab 共存配置

在已有 [Tailscale Split DNS 远程访问](tailscale.md) 的基础上，通过 Peer Relay 加速国内设备之间的 Tailnet 连接。

## 架构概述

Peer Relay（Tailscale ≥ 1.86）允许将任意 Tailnet 节点升级为原生 WireGuard UDP 中继，替代传统 DERP 的 HTTPS+WebSocket 路径。在国内 VPS 上启用后，国内设备间的 RTT 可从 ~160ms 降至 ~30ms。

```
┌─────────────────────────────────────────────────────────────┐
│  Remote Device (手机/笔记本)                                 │
│  └── Tailscale Client                                       │
│      ├── Split DNS: *.homelab.com → 100.x.x.x (m600)        │
│      └── WireGuard tunnel via Peer Relay (UDP)               │
└──────────┬──────────────────────────────────┬───────────────┘
           │                                  │
           │ peer-relay (UDP 40000)            │ WireGuard tunnel
           ▼                                  ▼
┌─────────────────────┐   ┌──────────────────────────────────┐
│  Relay VPS (阿里云)  │   │  Homelab Host (m600)             │
│  tag:relay           │   │  tag:homelab                     │
│  只做 UDP 中继       │   │  dnsmasq + Traefik + 全部服务    │
│  不参与 DNS/路由     │   │  DNS/反代/服务 一切不变          │
└─────────────────────┘   └──────────────────────────────────┘
```

**关键点**：Relay VPS 只在 L3（WireGuard UDP）层面参与，不接触 DNS 解析、HTTPS 路由或任何应用层逻辑。homelab 主机（m600）的 dnsmasq、Traefik、systemd-resolved 配置**完全不变**。

## 与现有配置的冲突点

### ⚠️ ACL 合并

现有 ACL（[tailscale.md](tailscale.md) 中的最小示例）只有 `tag:homelab`，需要合并 `tag:relay` 及其 grant。

现有 ACL：

```json
{
  "tagOwners": {
    "tag:homelab": ["autogroup:admin"]
  },
  "grants": [
    {
      "src": ["autogroup:member"],
      "dst": ["tag:homelab"],
      "ip": ["*"]
    }
  ]
}
```

合并后：

```json
{
  "tagOwners": {
    "tag:homelab": ["your-email@example.com"],
    "tag:relay": ["your-email@example.com"]
  },
  "grants": [
    {
      "src": ["autogroup:member"],
      "dst": ["tag:homelab"],
      "ip": ["*"]
    },
    {
      "src": ["*"],
      "dst": ["tag:relay"],
      "app": {
        "tailscale.com/cap/relay": [{}]
      }
    }
  ]
}
```

> [!IMPORTANT]
> `tagOwners` 统一改为邮箱。Free tailnet 上 `autogroup:admin` 作为 tagOwner 可能被拒绝（`requested tags [...] are invalid or not permitted`）。趁合并时将 `tag:homelab` 的 owner 也一并改为邮箱，避免后续授权失败。

> [!WARNING]
> ACL 必须在 `tailscale up --advertise-tags=tag:relay` **之前**保存到 Admin Console。顺序反了会导致授权被拒。如果已经失败，改完 ACL 后重新执行同一条 `tailscale up` 即可，不用 logout。

### ⚠️ 两个 tag 的角色分离

| 节点 | Tag | 角色 | DNS | 路由 |
|------|-----|------|-----|------|
| m600（homelab） | `tag:homelab` | 服务端：Traefik + dnsmasq + 全部服务 | `--accept-dns=false`，运行 dnsmasq | 不做子网路由 |
| VPS（relay） | `tag:relay` | 中继：仅转发 UDP | `--accept-dns=false`，保持系统 DNS | `--accept-routes=false` |

> [!NOTE]
> 不要给 VPS 加 `tag:homelab`，也不要给 m600 加 `tag:relay`（除非 m600 本身有公网 IP 且希望兼任中继）。角色分离可以避免 ACL 权限扩散。

### ⚠️ DNS 互不干扰

两台都用 `--accept-dns=false`，各自系统 DNS 独立：

- **m600**：dnsmasq 处理 `*.homelab.com`，systemd-resolved 处理其他域名（见 [traefik.md](traefik.md#linux-networkmanager--systemd-resolved--dnsmasq)）
- **VPS**：保持系统默认 DNS（如阿里云的 `100.100.2.136` 或手动设置的 `223.5.5.5`），不装 dnsmasq
- **Admin Console Split DNS**（`*.homelab.com → m600 TS_IP`）只对开启 `accept-dns` 的客户端生效，两台服务器均不受影响

> [!WARNING]
> VPS 上 tailscaled 启动时可能仍会修改 `/etc/resolv.conf`（即使带了 `--accept-dns=false`）。建议在装 Tailscale **之前**锁定 DNS：
>
> ```bash
> # 1. 给 systemd-resolved 一个稳定兜底
> sudo tee /etc/systemd/resolved.conf.d/stable-dns.conf > /dev/null << 'EOF'
> [Resolve]
> DNS=223.5.5.5 119.29.29.29
> EOF
>
> # 2. 切回 stub 模式，防止 tailscaled 覆盖
> sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
> sudo systemctl restart systemd-resolved
> ```

## Relay VPS 部署步骤

> [!NOTE]
> 以下仅列出 VPS 侧操作。homelab 主机（m600）**不需要任何改动**。

### 1. 放行 UDP 端口

确保 VPS 防火墙（安全组 / ufw）放行：

- **UDP 40000**：Peer Relay 中继端口（可自选）
- **UDP 41641**：Tailscale daemon 默认打洞端口

```bash
# 如果 VPS 启用了 ufw
sudo ufw allow 40000/udp
sudo ufw allow 41641/udp
```

### 2. 安装 Tailscale

```bash
curl -fsSL https://tailscale.com/install.sh | sh
tailscale version  # 确认 >= 1.86
```

### 3. 加入 Tailnet

```bash
tailscale up \
    --hostname=relay-vps \
    --accept-routes=false \
    --accept-dns=false \
    --advertise-tags=tag:relay
```

按提示在浏览器打开授权 URL 登录。

### 4. 启用 Peer Relay

```bash
tailscale set --relay-server-port=40000
```

验证端口监听：

```bash
ss -ulnp | grep 40000
# UNCONN 0 0 0.0.0.0:40000 0.0.0.0:* users:(("tailscaled",...))
```

### 5. 验证

在任意国内 Tailnet 设备上：

```bash
tailscale status
# 预期看到 peer-relay <VPS_IP>:40000:vni:1

tailscale ping --c=5 <对端 Tailscale IP>
# 预期 RTT 显著降低（如 160ms → 30ms）
```

## Peer Relay 不是什么

- **不是 Exit Node**：不会让其他设备从 VPS 出网。需要另外 `--advertise-exit-node`
- **不是 Subnet Router**：不做子网路由
- **不替代 Split DNS**：远程设备访问 `*.homelab.com` 的 DNS 解析仍由 m600 的 dnsmasq 提供，Peer Relay 只加速隧道本身

## 回滚

如需在 VPS 上完全移除：

```bash
tailscale down
tailscale logout
sudo apt remove tailscale  # 或对应包管理器
sudo rm -rf /var/lib/tailscale
```

homelab 主机无需任何操作，其他设备会自动回退到 DERP。

## 参考

> [!IMPORTANT]
> 修改本文档前，先查阅以下官方链接验证配置是否过时。

- [Tailscale Peer Relays 官方公告](https://tailscale.com/blog/peer-relays)
- [Tailscale ACL Tags](https://tailscale.com/kb/1068/acl-tags)
- [Tailscale ACL Grants](https://tailscale.com/kb/1324/acl-grants)
- [国内自建 Peer Relay 实现 Tailscale 加速（部署实录）](https://5km.studio/blog/tailscale-peer-relay)
