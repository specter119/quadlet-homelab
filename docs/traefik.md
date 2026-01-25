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

#### WSL：Windows hosts

在 Windows `C:\Windows\System32\drivers\etc\hosts` 添加（IP 通过 `ip addr show eth0` 获取）：

```
<WSL_IP> traefik.<your-domain>
<WSL_IP> silverbullet.<your-domain>
<WSL_IP> dozzle.<your-domain>
<WSL_IP> langfuse.<your-domain>
<WSL_IP> omnivore.<your-domain>
<WSL_IP> omnivore-api.<your-domain>
<WSL_IP> plane.<your-domain>
<WSL_IP> copyparty.<your-domain>
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

| 服务 | 访问方式 | 说明 |
|------|----------|------|
| PostgreSQL | `postgres:5432` | 直接通过业务子网访问 |
| Garage S3 | `garage:3900` | 直接通过业务子网访问 |

详见 [docs/quadlet.md](quadlet.md#网络架构)。
