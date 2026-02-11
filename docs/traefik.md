# Traefik 配置指南

## 冷启动配置

### 低端口绑定

Rootless Podman 默认无法绑定 80/443 端口。配置 sysctl 允许非特权用户绑定低端口：

```bash
sudo tee /etc/sysctl.d/99-unprivileged-ports.conf << 'EOF'
net.ipv4.ip_unprivileged_port_start=80
EOF

sudo sysctl --system  # 立即生效
```

验证：

```bash
sysctl net.ipv4.ip_unprivileged_port_start
# 输出应为 80
```

> [!TIP]
> **WSL 用户**：也可通过 `wsl --shutdown` 重启 WSL 使配置生效。

### SSL 证书初始化

使用 [certs-maker](https://github.com/soulteary/certs-maker) 生成自签名泛域名证书（以你的 domain 为例）：

```bash
# 创建证书目录
mkdir -p ~/.local/state/traefik/ssl

# 设置域名（与 .dotter/local.toml 中的 domain 一致）
DOMAIN=homelab.com  # 或 worklab.com

# 生成泛域名证书（有效期 10 年）
podman run --rm \
  -v ~/.local/state/traefik/ssl:/ssl \
  docker.io/soulteary/certs-maker \
  "--CERT_DNS=${DOMAIN},*.${DOMAIN}"

# 验证证书
openssl x509 -in ~/.local/state/traefik/ssl/${DOMAIN}.pem.crt -text -noout
```

配置 `traefik/certs.toml`（dotter 会自动替换 `{{domain}}`）：

```toml
[tls.stores.default.defaultCertificate]
certFile = "/data/ssl/{{domain}}.pem.crt"
keyFile = "/data/ssl/{{domain}}.pem.key"

[[tls.certificates]]
certFile = "/data/ssl/{{domain}}.pem.crt"
keyFile = "/data/ssl/{{domain}}.pem.key"
```

## 域名解析配置

配置一次后自动解析所有子域名，新增服务无需手动添加条目。

- **本机访问**：按本节配置即可
- **远程访问**：在本节基础上，额外配置 [Tailscale](tailscale.md)

### Linux：NetworkManager + systemd-resolved + dnsmasq

#### 为什么需要这套组合

目标是让本机能解析 `*.homelab.com`，同时容器不受影响：

- **问题**：如果把 DNS 设为 `127.0.0.1`，容器会继承这个配置导致回环
- **方案**：systemd-resolved 做本机 DNS 分流
  - 默认域名 → 上游 DNS（由 NetworkManager 提供）
  - `homelab.com` → 127.0.0.1（dnsmasq）

结果：主机可解析 `homelab.com`，容器仍使用上游 DNS。

#### 1. NetworkManager 使用 systemd-resolved

```bash
sudo tee /etc/NetworkManager/conf.d/dns.conf > /dev/null << 'EOF'
[main]
dns=systemd-resolved
EOF

sudo systemctl enable --now systemd-resolved
sudo systemctl restart NetworkManager
```

> [!WARNING]
> 不要使用 NetworkManager 的 dnsmasq 插件（会导致容器 DNS 指向 127.0.0.1）。

#### 2. 配置 dnsmasq

```bash
# 写入 homelab 域名配置
sudo tee /etc/dnsmasq.d/homelab.conf > /dev/null << 'EOF'
listen-address=127.0.0.1
bind-interfaces
address=/.homelab.com/127.0.0.1
EOF

# 写入初始上游 DNS（防止冷启动时 dnsmasq 读 /etc/resolv.conf 指向 127.0.0.53 形成回环）
sudo tee /etc/dnsmasq.d/upstream.conf > /dev/null << 'EOF'
no-resolv
server=1.1.1.1
EOF

# 启动 dnsmasq
sudo systemctl enable --now dnsmasq
```

> [!TIP]
> `/etc/dnsmasq.d/*.conf` 可能默认未启用，需要在 `/etc/dnsmasq.conf` 里开启 `conf-dir`。

> [!NOTE]
> `upstream.conf` 会在步骤 3 的 dispatcher 脚本触发后被动态覆盖为实际的上游 DNS。这里先写入一个安全的默认值，确保 dnsmasq 在 dispatcher 触发前不会回环。

#### 3. 上游 DNS（动态写入）

通过 NetworkManager dispatcher 自动获取上游 DNS：

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

systemctl restart --no-block dnsmasq
EOF

sudo chmod +x /etc/NetworkManager/dispatcher.d/60-dnsmasq-upstream
```

> [!WARNING]
> 不要把 upstream 指向 `127.0.0.53`（systemd-resolved stub），否则会形成回环。

#### 4. 配置 split DNS

让 systemd-resolved 把 `homelab.com` 查询转发到 dnsmasq（127.0.0.1）。使用 resolved 的 drop-in 配置，将 `~homelab.com` 设为全局 routing domain：

```bash
sudo install -d /etc/systemd/resolved.conf.d
sudo tee /etc/systemd/resolved.conf.d/homelab.conf > /dev/null << 'EOF'
[Resolve]
DNS=127.0.0.1
Domains=~homelab.com
EOF

sudo systemctl restart systemd-resolved
```

> [!NOTE]
> `Domains=~homelab.com` 中的 `~` 前缀表示 routing domain：只有 `*.homelab.com` 查询会转发到 `DNS=127.0.0.1`（dnsmasq），其他域名走默认链路的 DNS 服务器。静态配置不会被 D-Bus 客户端覆盖，比 `resolvectl` 运行时状态更稳定。

#### 5. 验证

```bash
# 检查 dnsmasq 监听
ss -u -lpn | rg ':53'
# 应看到 127.0.0.1:53

# 检查 split DNS 配置
resolvectl status | head -10
# Global 部分应有 DNS Servers: 127.0.0.1 和 DNS Domain: ~homelab.com

# 测试解析
dig dozzle.homelab.com +short
# 应返回 127.0.0.1

# 测试 HTTP 访问
curl -k https://dozzle.homelab.com
```

### WSL：NRPT + dnsmasq

目标：Windows 只把 `*.homelab.com` 的解析转发到 WSL 内的 dnsmasq，不改动系统默认 DNS，也不影响 WSL 自己的上网解析。

1. **安装 dnsmasq**（根据 WSL 发行版选择）：

   ```bash
   # Debian/Ubuntu
   sudo apt-get update && sudo apt-get install -y dnsmasq
   # Arch Linux
   sudo pacman -S dnsmasq
   ```

1. **启用 dnsmasq 配置目录**（Arch Linux 默认未启用）：

   ```bash
   # 检查 conf-dir 是否启用
   grep "^conf-dir" /etc/dnsmasq.conf

   # 如果没有输出，取消注释
   sudo sed -i 's/^#conf-dir=\/etc\/dnsmasq.d\/,\*\.conf$/conf-dir=\/etc\/dnsmasq.d\/,*.conf/' /etc/dnsmasq.conf
   ```

1. **获取 WSL IP**（记为 `<WSL_IP>`）：

   ```bash
   ip -4 -o addr show dev eth0 | awk '{print $4}' | cut -d/ -f1 | head -n1
   ```

1. **写入 dnsmasq 配置**（将 `<WSL_IP>` 替换为实际 IP，如 `172.26.109.61`）：

   ```bash
   sudo tee /etc/dnsmasq.d/homelab.conf > /dev/null << 'EOF'
   bind-interfaces
   listen-address=<WSL_IP>
   no-resolv
   domain-needed
   bogus-priv
   local=/homelab.com/
   address=/.homelab.com/<WSL_IP>
   EOF

   sudo systemctl enable --now dnsmasq
   ```

   > [!WARNING]
   > 不要加 `interface=eth0`，只用 `listen-address` 即可。加了会导致 dnsmasq 尝试绑定 WSL 内置 DNS 地址（10.255.255.254）而失败。

1. **Windows 管理员 PowerShell 添加 NRPT 规则**：

   ```powershell
   Add-DnsClientNrptRule -Namespace ".homelab.com" -NameServers "<WSL_IP>"
   ipconfig /flushdns
   ```

1. **验证**：

   ```powershell
   Resolve-DnsName dozzle.homelab.com
   # 应返回 <WSL_IP>
   ```

   如需移除 NRPT 规则：

   ```powershell
   Get-DnsClientNrptRule | Where-Object { $_.Namespace -contains ".homelab.com" } | Remove-DnsClientNrptRule -Force
   ```

   > [!NOTE]
   >
   > - NRPT 仅影响系统 DNS 解析器。若浏览器启用了 DoH，请改为系统解析器或关闭 DoH。
   > - 若 WSL IP 变化，需要重新添加 NRPT 规则。

## 架构设计

```
┌─────────────────────────────────────────────────────────────┐
│                        Traefik                              │
├─────────────────────────────────────────────────────────────┤
│  HTTP EntryPoints                                            │
│  ├── http (:80)   → 重定向到 https                           │
│  └── https (:443) → 业务服务                                 │
├─────────────────────────────────────────────────────────────┤
│  File Provider (middlewares.toml)                           │
│  ├── 共享中间件: gzip, redir-https                           │
│  └── Dashboard 路由 → api@internal                          │
├─────────────────────────────────────────────────────────────┤
│  Docker Provider (container labels)                         │
│  ├── dozzle      → dozzle.{{domain}}                        │
│  ├── silverbullet → silverbullet.{{domain}}                 │
│  └── <service>   → <service>.{{domain}}                     │
└─────────────────────────────────────────────────────────────┘
```

> [!NOTE]
> `{{domain}}` 是 dotter 模板变量，可在 `.dotter/local.toml` 设置，例如 `homelab.com`。

**设计原则**：

- Traefik Dashboard: 使用 File Provider 定义路由
- 其他服务: 使用 Container Labels，配置与服务绑定，易于管理
- 共享中间件: 定义在 File Provider，通过 `@file` 后缀引用
- Label 特殊字符处理: 见 [AGENTS.md](../AGENTS.md#label-值特殊字符必须加引号)

## API 和 Dashboard 配置

根据[官方文档](https://doc.traefik.io/traefik/operations/dashboard/)：

- `[api]` 启用 API，`dashboard` 默认为 `true`
- `insecure = true` 会自动创建 `traefik` entrypoint 监听 `:8080`
- 生产环境不用 `insecure`，通过 file provider 路由到 `api@internal`

```toml
# traefik.toml
[api]  # dashboard 默认启用

# middlewares.toml
[http.routers.traefik-dashboard]
  rule = "Host(`traefik.{{domain}}`)"
  entrypoints = ["https"]
  service = "api@internal"
  middlewares = ["gzip"]
  [http.routers.traefik-dashboard.tls]
```

## 共享中间件

定义在 `traefik/middlewares.toml`：

```toml
[http.middlewares]
  # Compression (zstd preferred, gzip fallback)
  [http.middlewares.gzip.compress]
    encodings = ["zstd", "gzip"]

  [http.middlewares.redir-https.redirectScheme]
    scheme = "https"
    permanent = false
```

## 服务 Labels 模板

> 完整的 Quadlet 服务模板（包含 Labels）详见 [docs/quadlet.md](quadlet.md#单容器服务模板)

## 共享基础设施访问

PostgreSQL 和 Garage 作为共享基础设施，通过 `render_networks.sh` 动态加入依赖它们的业务子网，**不经过 Traefik 代理**。

| 服务       | 访问方式        | 说明                 |
| ---------- | --------------- | -------------------- |
| PostgreSQL | `postgres:5432` | 直接通过业务子网访问 |
| Garage S3  | `garage:3900`   | 直接通过业务子网访问 |

详见 [docs/quadlet.md](quadlet.md#网络架构)。

## 参考

> [!IMPORTANT]
> 修改本文档前，先查阅以下官方链接验证配置是否过时。

- [Traefik Documentation](https://doc.traefik.io/traefik/)
- [Traefik Docker Provider](https://doc.traefik.io/traefik/providers/docker/)
- [Traefik File Provider](https://doc.traefik.io/traefik/providers/file/)
- [NetworkManager.conf(5)](https://man.archlinux.org/man/NetworkManager.conf.5.en)
- [NetworkManager-dispatcher(8)](https://man.archlinux.org/man/NetworkManager-dispatcher.8.en)
- [resolved.conf(5)](https://man.archlinux.org/man/resolved.conf.5.en)
- [systemd-resolved(8)](https://man.archlinux.org/man/systemd-resolved.8.en)
- [dnsmasq(8)](https://man.archlinux.org/man/dnsmasq.8.en)
- [NRPT (Name Resolution Policy Table)](https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-server-2012-r2-and-2012/dn593632(v=ws.11))
