# Tailscale 远程访问配置

通过 Tailscale Split DNS，从任意 tailnet 设备使用**相同域名**访问 homelab 服务。

## 架构

以 Dozzle 为例，本地和远程使用相同 URL（`https://dozzle.homelab.com`）：

```
┌─────────────────────────────────────────────────────────────┐
│  Remote Device (手机/笔记本)                                 │
│  └── Tailscale Client (同一 tailnet)                         │
│      └── Split DNS: *.homelab.com → 100.x.x.x (m600)        │
└────────────────────────┬────────────────────────────────────┘
                         │ WireGuard Tunnel (DNS on port 53)
                         ▼
┌─────────────────────────────────────────────────────────────┐
│  Homelab Host (m600)                                        │
│  ├── systemd-resolved (本机 DNS 调度)                        │
│  │   ├── 默认域名 → 上游 DNS                                 │
│  │   └── homelab.com → 127.0.0.1 (dnsmasq)                   │
│  ├── dnsmasq (127.0.0.1:53 + TS_IP:53，解析 *.homelab.com)   │
│  └── Traefik (Host-based routing) → Dozzle                  │
│                                                             │
│  DNS 查询流程：                                              │
│  Remote → Tailscale Split DNS → m600(TS_IP):53 → dnsmasq     │
│  Local  → systemd-resolved → 127.0.0.1(dnsmasq) → Traefik    │
└─────────────────────────────────────────────────────────────┘
```

## 前置条件

- **已完成 [traefik.md](traefik.md) 的 Linux DNS 配置**（NetworkManager + systemd-resolved + dnsmasq）
- Tailscale 已安装并登录 (`tailscale status`)
- [Tailscale Admin Console](https://login.tailscale.com/admin) 访问权限
- sudo 权限

### 清理本机 split DNS 配置

Tailscale 方案使用 `tailscale0` 接口做 split DNS，替换 traefik.md 中使用 `lo` 接口的方案。如果之前配置过，需要先清理：

```bash
sudo rm -f /etc/NetworkManager/dispatcher.d/99-homelab-dns
sudo resolvectl revert lo 2>/dev/null || true
```

## 配置步骤

### 1. 启动 Tailscale 并添加标签

在 [Tailscale ACL](https://login.tailscale.com/admin/acls) 中使用最小可用示例（只允许成员访问 homelab server）：

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

然后启动 Tailscale 并获取 IP：

```bash
sudo tailscale up --accept-dns=false --advertise-tags=tag:homelab
TS_IP=$(tailscale ip -4)
echo "Tailscale IP: $TS_IP"
# 输出示例: 100.94.150.93
```

后续步骤都使用 `$TS_IP` 变量。

如果多次修改配置不确定当前状态，可先重置再重新执行：

```bash
sudo tailscale up --reset
sudo tailscale up --accept-dns=false --advertise-tags=tag:homelab
```

### 2. 扩展 dnsmasq 监听 Tailscale IP

在 [traefik.md](traefik.md) 的基础配置上，让 dnsmasq 额外监听 Tailscale IP，并返回 `$TS_IP`（而非 127.0.0.1）：

```bash
# 更新 dnsmasq 配置（只用 listen-address，不要加 interface=tailscale0）
sudo tee /etc/dnsmasq.d/homelab.conf > /dev/null << EOF
listen-address=127.0.0.1,${TS_IP}
bind-interfaces
address=/.homelab.com/${TS_IP}
EOF

# dnsmasq 用了 bind-interfaces，必须在 tailscaled 之后启动，否则 ${TS_IP} 地址不存在会绑定失败
sudo install -d /etc/systemd/system/dnsmasq.service.d
sudo tee /etc/systemd/system/dnsmasq.service.d/override.conf > /dev/null << 'EOF'
[Unit]
After=tailscaled.service network-online.target
Wants=network-online.target tailscaled.service
EOF

sudo systemctl daemon-reload
sudo systemctl restart dnsmasq
```

> [!NOTE]
> 这里用 `Wants`（而非 `Requires`），这样 tailscaled 重启时不会连带停止 dnsmasq，本机 DNS 解析不受影响。

> [!TIP]
> `/etc/dnsmasq.d/*.conf` 可能默认未启用，需要在 `/etc/dnsmasq.conf` 里开启 `conf-dir`。

### 3. 配置 tailscale0 的 split DNS

让 systemd-resolved 把 `homelab.com` 通过 `tailscale0` 接口转发到 dnsmasq。

`resolvectl` 设置的 per-link DNS 是运行时状态，其他接口的 DHCP 更新、NM 重配等 `dns-change` 事件都可能将其冲掉。需要两层保障：

1. **ExecStartPost**：tailscaled 启动时初始配置
2. **NM dispatcher**：DNS 变化时自动恢复

```bash
# 1) tailscaled 启动时初始配置
sudo install -d /etc/systemd/system/tailscaled.service.d
sudo tee /etc/systemd/system/tailscaled.service.d/split-dns.conf > /dev/null << 'EOF'
[Service]
ExecStartPost=/usr/bin/resolvectl dns tailscale0 127.0.0.1
ExecStartPost=/usr/bin/resolvectl domain tailscale0 "~homelab.com"
EOF

sudo systemctl daemon-reload
sudo systemctl restart tailscaled

# 2) DNS 变化时自动恢复（处理 dns-change 和 tailscale0 up 事件）
sudo tee /etc/NetworkManager/dispatcher.d/99-tailscale-dns > /dev/null << 'EOF'
#!/bin/bash
# dns-change 事件没有接口参数，tailscale0 up 事件有
[[ "$2" == "dns-change" || ("$1" == "tailscale0" && "$2" == "up") ]] || exit 0
ip link show tailscale0 &>/dev/null || exit 0
resolvectl dns tailscale0 127.0.0.1
resolvectl domain tailscale0 "~homelab.com"
EOF

sudo chmod +x /etc/NetworkManager/dispatcher.d/99-tailscale-dns
```

> [!NOTE]
> `tailscale0` 接口在 tailscaled 启动时就会创建（不需要等认证），所以 `ExecStartPost` 可以直接执行。dispatcher 负责在后续 DNS 配置被冲掉时自动恢复。

手动验证 split DNS 是否生效：

```bash
resolvectl status tailscale0
# 应看到 DNS Servers: 127.0.0.1 和 DNS Domain: ~homelab.com
```

### 4. 配置 Tailscale Split DNS（Admin Console）

1. 打开 [Tailscale Admin Console](https://login.tailscale.com/admin/dns)
2. 进入 **DNS** 页面
3. 在 **Nameservers** → **Add nameserver** → **Custom**
4. 添加 Split DNS 配置：
   - **Nameserver**: homelab server 的 `$TS_IP`
   - **Restrict to domain**: `homelab.com`
5. 保存

> [!NOTE]
> 配置后，tailnet 内所有设备查询 `*.homelab.com` 时会自动转发到 homelab server 的 dnsmasq。

### 附录：FlClash 与 Tailscale 共存

Android 上同时使用 FlClash 和 Tailscale 时，在 FlClash 中配置域名服务器策略：

**工具** → **基本配置** → **DNS** → **域名服务器策略** → 新建：

- 域名：`+.homelab.com`
- 服务器：`<TS_IP>`（如 `100.94.150.93`）

### 附录：修复 Tailscale UDP GRO warning

```bash
sudo tee /etc/NetworkManager/dispatcher.d/50-tailscale-gro > /dev/null << 'EOF'
#!/bin/bash
[[ "$1" == "enp1s0" && "$2" == "up" ]] && ethtool -K enp1s0 rx-udp-gro-forwarding on rx-gro-list off
EOF

sudo chmod +x /etc/NetworkManager/dispatcher.d/50-tailscale-gro
```

## 验证

### 本机验证

```bash
# DNS 解析
dig dozzle.homelab.com +short
# 应返回: $TS_IP

# HTTP 访问
curl -k https://dozzle.homelab.com
```

### 远程设备验证（手机/其他电脑）

确保设备已连接 Tailscale，然后：

```bash
# DNS 解析（指定 nameserver 测试）
dig @$TS_IP dozzle.homelab.com +short
# 应返回: $TS_IP

# 浏览器访问
# https://dozzle.homelab.com
```

## 故障排除

### dnsmasq 未运行

```bash
# 检查监听端口
ss -u -lpn | rg ':53'
# 应看到 127.0.0.1:53 和 ${TS_IP}:53

# 检查配置语法
cat /etc/dnsmasq.d/homelab.conf

# 重启 dnsmasq
sudo systemctl restart dnsmasq
```

### 远程设备 DNS 解析失败

```bash
# 检查 Tailscale 连接
tailscale status

# 手动测试 DNS
dig @$TS_IP dozzle.homelab.com
```

### Split DNS 未生效

1. 确认 Tailscale Admin Console 配置已保存
2. 在客户端重启 Tailscale：
   - macOS/Windows: 退出并重新打开 Tailscale
   - Linux: `sudo systemctl restart tailscaled`
   - Android/iOS: 断开并重新连接

### 本机解析慢 / 首次查询延迟

```bash
resolvectl status
resolvectl query dozzle.homelab.com
```

- `Global DNS Servers` 不应是 `127.0.0.1`
- `tailscale0` 应有 `DNS Servers: 127.0.0.1` 和 `DNS Domain: ~homelab.com`

## 安全注意事项

1. **限制 DNS 递归**：当前 dnsmasq 只服务 `homelab.com` zone，不做通用递归解析
2. **Tailscale ACL**：可在 Admin Console 限制哪些设备能访问 homelab server 的 DNS 端口

## 参考

> [!IMPORTANT]
> 修改本文档前，先查阅以下官方链接验证配置是否过时。

- [Tailscale Split DNS](https://tailscale.com/kb/1054/dns)
- [Split DNS Policies](https://tailscale.com/kb/1588/split-dns-policies)
- [MagicDNS](https://tailscale.com/kb/1081/magicdns)
- [tailscaled(8)](https://man.archlinux.org/man/tailscaled.8.en)
- [NetworkManager-dispatcher(8)](https://man.archlinux.org/man/NetworkManager-dispatcher.8.en)
- [systemd-resolved(8)](https://man.archlinux.org/man/systemd-resolved.8.en)
- [systemd.exec(5) - ExecStartPost](https://man.archlinux.org/man/systemd.service.5.en#COMMAND_LINES)
- [dnsmasq(8)](https://man.archlinux.org/man/dnsmasq.8.en)
