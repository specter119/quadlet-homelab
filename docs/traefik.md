# Traefik 配置指南

> 官方文档: <https://doc.traefik.io/traefik/>

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

### 域名解析配置

#### Linux：NetworkManager + dnsmasq

配置一次后自动解析所有子域名，新增服务无需手动添加条目。

1. 启用 dnsmasq：

   ```bash
   sudo tee /etc/NetworkManager/conf.d/dns.conf << 'EOF'
   [main]
   dns=dnsmasq
   EOF
   ```

1. 添加泛域名解析（以 `homelab.com` 为例）：

   ```bash
   sudo tee /etc/NetworkManager/dnsmasq.d/homelab.conf << 'EOF'
   address=/.homelab.com/127.0.0.1
   EOF
   ```

   > **远程访问**：如需通过 Tailscale 从外部访问 homelab，需将 `127.0.0.1` 改为 Tailscale IP。详见 [docs/tailscale.md](tailscale.md#2-配置-dnsmasq需要-sudo)。

1. 重启 NetworkManager：

   ```bash
   sudo systemctl restart NetworkManager
   ```

#### WSL：NRPT + dnsmasq（推荐）

目标：Windows 只把 `*.homelab.com` 的解析转发到 WSL 内的 dnsmasq，不改动系统默认 DNS，也不影响 WSL 自己的上网解析。

1. **安装 dnsmasq**（根据 WSL 发行版选择）：

   ```bash
   # Debian/Ubuntu
   sudo apt-get update && sudo apt-get install -y dnsmasq
   # Arch Linux
   sudo pacman -S dnsmasq
   ```

   ```

   ```

1. **停用 systemd-resolved**（WSL 不需要，且会占用 53 端口）：

   ```bash
   sudo systemctl disable --now systemd-resolved systemd-resolved-varlink.socket systemd-resolved-monitor.socket
   ```

   > WSL 的 DNS 解析依赖 `/etc/resolv.conf`（由 WSL 自动生成），不依赖 systemd-resolved。

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

   > **注意**：不要加 `interface=eth0`，只用 `listen-address` 即可。加了会导致 dnsmasq 尝试绑定 WSL 内置 DNS 地址（10.255.255.254）而失败。

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

   > 说明：
   >
   > - NRPT 仅影响系统 DNS 解析器。若浏览器启用了 DoH，请改为系统解析器或关闭 DoH。
   > - 若 WSL IP 变化，需要重新添加 NRPT 规则。

#### WSL：Windows hosts（备用）

如果你不想启用 dnsmasq，可在 Windows `C:\Windows\System32\drivers\etc\hosts` 添加（IP 通过 `ip addr show eth0` 获取）：

```plain
<WSL_IP> traefik.<your-domain>
<WSL_IP> silverbullet.<your-domain>
<WSL_IP> <other services>.<your-domain>
```

> 将 `<your-domain>` 替换为你的实际域名（如 `homelab.com`）

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

> **注**：`{{domain}}` 是 dotter 模板变量，可在 `.dotter/local.toml` 设置，例如 `homelab.com`。

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
