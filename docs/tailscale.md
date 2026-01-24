# Tailscale 远程访问配置

通过 Tailscale Split DNS，从任意 tailnet 设备使用**相同域名**访问 homelab 服务。

## 架构

以 Dozzle 为例，本地和远程使用相同 URL（`https://dozzle.homelab.com`）：

```
┌─────────────────────────────────────────────────────────────┐
│  Remote Device (手机/笔记本)                                 │
│  └── Tailscale Client (登录同一 tailnet)                     │
│      └── Split DNS: *.homelab.com → 100.x.x.x (m600)        │
└────────────────────────┬────────────────────────────────────┘
                         │ WireGuard Tunnel (DNS on port 53)
                         ▼
┌─────────────────────────────────────────────────────────────┐
│  Homelab Host (m600)                                        │
│  ├── Tailscale IP: 100.x.x.x                                │
│  ├── dnsmasq (127.0.0.1:53，解析 *.homelab.com → TS_IP)      │
│  └── Traefik (Host-based routing) → Dozzle                  │
│                                                             │
│  DNS 查询流程：                                              │
│  Remote → Tailscale Split DNS → m600:53 → dnsmasq → TS_IP   │
└─────────────────────────────────────────────────────────────┘
```

## 前置条件

- Tailscale 已安装并登录 (`tailscale status`)
- [Tailscale Admin Console](https://login.tailscale.com/admin) 访问权限
- NetworkManager + dnsmasq 已配置（见 [docs/traefik.md](traefik.md#域名解析配置)）
- sudo 权限

## 配置步骤

### 1. 启动 Tailscale 并添加标签

首先在 [Tailscale ACL](https://login.tailscale.com/admin/acls) 中定义 tag owner：

```json
{
  "tagOwners": {
    "tag:homelab": ["autogroup:admin"]
  }
}
```

然后启动 Tailscale 并获取 IP：

```bash
sudo tailscale up --advertise-tags=tag:homelab
TS_IP=$(tailscale ip -4)
echo "Tailscale IP: $TS_IP"
# 输出示例: 100.81.77.106
```

后续步骤都使用 `$TS_IP` 变量。

> **重要**：如果 ACL 规则使用了 `"dst": ["tag:homelab"]` 限制访问，没有这个标签会导致远程设备无法访问主机。

### 2. 配置 dnsmasq（需要 sudo）

修改 dnsmasq 配置，将 `*.homelab.com` 解析到 Tailscale IP：

```bash
sudo tee /etc/NetworkManager/dnsmasq.d/homelab.conf << EOF
address=/.homelab.com/${TS_IP}
EOF

sudo systemctl restart NetworkManager
```

> **注意**：NetworkManager 的 dnsmasq 插件硬编码了 `--bind-interfaces --listen-address=127.0.0.1`，
> 无法通过配置文件让 dnsmasq 额外监听 Tailscale IP（`bind-dynamic` 与 `--bind-interfaces` 互斥）。
> 因此我们依赖 Tailscale Split DNS 将 DNS 查询转发到 127.0.0.1，而不是直接让 dnsmasq 监听 Tailscale IP。

验证本机 dnsmasq 正常运行：

```bash
ss -tlnp | grep :53
# 应看到 127.0.0.1:53
```

### 3. 配置 Tailscale Split DNS（Admin Console）

1. 打开 [Tailscale Admin Console](https://login.tailscale.com/admin/dns)
2. 进入 **DNS** 页面
3. 在 **Nameservers** → **Add nameserver** → **Custom**
4. 添加 Split DNS 配置：
   - **Nameserver**: 你的 `$TS_IP`
   - **Restrict to domain**: `homelab.com`
5. 保存

> 配置后，tailnet 内所有设备查询 `*.homelab.com` 时会自动转发到 m600 的 dnsmasq。

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
ss -tlnp | grep :53

# 检查配置语法
cat /etc/NetworkManager/dnsmasq.d/homelab.conf

# 重启 NetworkManager
sudo systemctl restart NetworkManager
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

## 安全注意事项

1. **限制 DNS 递归**：当前 dnsmasq 只服务 `homelab.com` zone，不做通用递归解析
2. **Tailscale ACL**：可在 Admin Console 限制哪些设备能访问 m600 的 DNS 端口

## 附录：FlClash 与 Tailscale 共存

Android 上同时使用 FlClash 和 Tailscale 时，在 FlClash 中配置域名服务器策略：

**工具** → **基本配置** → **DNS** → **域名服务器策略** → 新建：

- 域名：`+.homelab.com`
- 服务器：`<TS_IP>`（如 `100.81.77.106`）

## 参考

> **维护提示**：修改本文档前，先查阅以下官方链接验证配置是否过时。

- [Tailscale Split DNS](https://tailscale.com/kb/1054/dns)
- [Split DNS Policies](https://tailscale.com/kb/1588/split-dns-policies)
- [MagicDNS](https://tailscale.com/kb/1081/magicdns)
- [NetworkManager dnsmasq](https://wiki.archlinux.org/title/NetworkManager#dnsmasq)
