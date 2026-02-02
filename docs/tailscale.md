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

- Tailscale 已安装并登录 (`tailscale status`)
- [Tailscale Admin Console](https://login.tailscale.com/admin) 访问权限
- 系统级 dnsmasq 已安装（见下文 2.2）
- sudo 权限

## 配置步骤

### 1. 在 homelab server 上启动 Tailscale 并添加标签

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
      "ip":  ["*"]
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

后续步骤都使用 `$TS_IP` 变量（仅在这台机器作为 homelab server 时需要）。

如果多次修改配置不确定当前状态，可先重置再重新执行：

```bash
sudo tailscale up --reset
sudo tailscale up --accept-dns=false --advertise-tags=tag:homelab
```

### 2. 配置系统 dnsmasq + split DNS（推荐）

目标：本机默认 DNS 走上游（避免容器回环），`homelab.com` 走本机 dnsmasq（127.0.0.1）。

#### 2.0 为什么需要 systemd-resolved

这里有两个目标会冲突：

- 本机要解析 `homelab.com`（需要走本机 dnsmasq）
- 容器不能继承 `127.0.0.1`（否则回环）

systemd-resolved 负责 **本机 DNS 分流**：

- 默认域名 → 上游 DNS（由 NetworkManager 提供）
- `homelab.com` → `tailscale0` 的 per-link DNS（127.0.0.1 → dnsmasq）

结果：主机可解析 `homelab.com`，容器仍使用上游 DNS。

> **注意**：该方案会替换 [docs/traefik.md](traefik.md) 的本机 DNS 配置，两者不可叠加。

#### 2.1 NetworkManager 使用 systemd-resolved

```bash
sudo tee /etc/NetworkManager/conf.d/dns.conf > /dev/null << 'EOF'
[main]
dns=systemd-resolved
EOF

sudo systemctl enable --now systemd-resolved
sudo systemctl restart NetworkManager
```

> **注意**：不要使用 NetworkManager 的 dnsmasq 插件（会导致容器 DNS 指向 127.0.0.1）。

#### 2.2 配置 dnsmasq 监听 Tailscale IP

```bash
# 1) 启动系统 dnsmasq
sudo systemctl enable --now dnsmasq

# 2) 写入配置（TS_IP 为 homelab server 自己的 Tailscale IP）
sudo tee /etc/dnsmasq.d/homelab.conf > /dev/null << EOF
interface=tailscale0
listen-address=127.0.0.1,${TS_IP}
bind-interfaces

address=/.homelab.com/${TS_IP}
EOF

sudo systemctl restart dnsmasq
```

> **建议**：如果 `dnsmasq` 因为 `tailscale0` 尚未创建而启动失败，可用 systemd drop-in 增加依赖：
>
> ```bash
> sudo install -d /etc/systemd/system/dnsmasq.service.d
> sudo tee /etc/systemd/system/dnsmasq.service.d/override.conf > /dev/null << 'EOF'
> [Unit]
> After=tailscaled.service network-online.target
> Wants=network-online.target
> Requires=tailscaled.service
> EOF
>
> sudo systemctl daemon-reload
> sudo systemctl restart dnsmasq
> ```

> **注意**：dnsmasq 只在 homelab server 上配置，`TS_IP` 就是该 server 自己的 Tailscale IP。
> 其他客户端通过 Tailscale Split DNS 转发到 server。
>
> **提示**：`/etc/dnsmasq.d/*.conf` 可能默认未启用，需要在 `/etc/dnsmasq.conf` 里开启。

#### 2.3 上游 DNS（动态写入 upstream.conf）

```bash
sudo tee /etc/NetworkManager/dispatcher.d/60-dnsmasq-upstream > /dev/null << 'EOF'
#!/bin/bash
IFACE="$1"
STATE="$2"

[[ "$STATE" != "up" ]] && exit 0

DNS=$(nmcli -g IP4.DNS dev show "$IFACE" | head -n1)

if [[ -n "$DNS" ]]; then
  cat > /etc/dnsmasq.d/upstream.conf <<EOT
no-resolv
server=$DNS
server=1.1.1.1
EOT
else
  cat > /etc/dnsmasq.d/upstream.conf <<EOT
no-resolv
server=1.1.1.1
EOT
fi

systemctl restart dnsmasq
EOF

sudo chmod +x /etc/NetworkManager/dispatcher.d/60-dnsmasq-upstream
```

> **提示**：不要把 upstream 指向 `127.0.0.53`（systemd-resolved stub），否则会形成回环。

#### 2.4 配置 split DNS（systemd-resolved + systemd drop-in）

为避免依赖 NetworkManager 的 dispatcher，推荐在 `tailscaled` 启动后由
systemd 直接设置 split DNS：

```bash
sudo install -d /etc/systemd/system/tailscaled.service.d
sudo tee /etc/systemd/system/tailscaled.service.d/split-dns.conf > /dev/null << 'EOF'
[Service]
ExecStartPost=/usr/bin/resolvectl dns tailscale0 127.0.0.1
ExecStartPost=/usr/bin/resolvectl domain tailscale0 "~homelab.com"
EOF

sudo systemctl daemon-reload
sudo systemctl restart tailscaled
```

验证本机 dnsmasq 正常运行：

```bash
ss -u -lpn | rg ':53'
# 应看到 127.0.0.1:53 和 ${TS_IP}:53
```

### 3. 配置 Tailscale Split DNS（Admin Console）

1. 打开 [Tailscale Admin Console](https://login.tailscale.com/admin/dns)
2. 进入 **DNS** 页面
3. 在 **Nameservers** → **Add nameserver** → **Custom**
4. 添加 Split DNS 配置：
   - **Nameserver**: homelab server 的 `$TS_IP`
   - **Restrict to domain**: `homelab.com`
5. 保存

> 配置后，tailnet 内所有设备查询 `*.homelab.com` 时会自动转发到 m600 的 dnsmasq。

### 3.1 附录：FlClash 与 Tailscale 共存

Android 上同时使用 FlClash 和 Tailscale 时，在 FlClash 中配置域名服务器策略：

**工具** → **基本配置** → **DNS** → **域名服务器策略** → 新建：

- 域名：`+.homelab.com`
- 服务器：`<TS_IP>`（如 `100.94.150.93`）

### 3.2 可选：修复 Tailscale UDP GRO warning

```bash
sudo tee /etc/NetworkManager/dispatcher.d/50-tailscale-gro > /dev/null << 'EOF'
#!/bin/bash
[[ "$1" == "enp1s0" && "$2" == "up" ]] && ethtool -K enp1s0 rx-udp-gro-forwarding on rx-gro-list off
EOF

sudo chmod +x /etc/NetworkManager/dispatcher.d/50-tailscale-gro
```

### 4. 验证

#### 本机验证

```bash
# DNS 解析
dig dozzle.homelab.com +short
# 应返回: $TS_IP

# HTTP 访问
curl -k https://dozzle.homelab.com
```

#### 远程设备验证（手机/其他电脑）

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
# 检查监听端口（应看到 127.0.0.1:53）
ss -u -lpn | rg ':53'

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
2. **Tailscale ACL**：可在 Admin Console 限制哪些设备能访问 m600 的 DNS 端口

## 参考

> **维护提示**：修改本文档前，先查阅以下官方链接验证配置是否过时。

- [Tailscale Split DNS](https://tailscale.com/kb/1054/dns)
- [Split DNS Policies](https://tailscale.com/kb/1588/split-dns-policies)
- [MagicDNS](https://tailscale.com/kb/1081/magicdns)
- [dnsmasq(8)](https://man.archlinux.org/man/dnsmasq.8.en)
- [systemd-resolved(8)](https://man.archlinux.org/man/systemd-resolved.8.en)
