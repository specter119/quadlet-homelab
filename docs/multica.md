# Multica

> [!IMPORTANT]
> 本文只记录 Multica 相对默认模板的差异与已验证的本地约束。默认规则见 [quadlet.md](quadlet.md)、[secrets.md](secrets.md)。

## 自托管 Git（GitLab）集成评估

2026-11-19 评估结论：**Multica → GitLab 可用，GitLab → Multica 的 Webhook 回连不可达**，因此暂未启用。

已验证：

- `glab` 1.53.0 登录 `hkggitlab.oocl.com`（GitLab 18.11.13-ee）；PAT `glab-cli` scope 为 `api,write_repository`，对 `liuky3/iot-forge` 为 Owner，可创建 Webhook。
- 后端容器可解析并连通 GitLab（`<GITLAB_IP>`），失败点只在 TLS 信任。

阻塞项：

- **私有 CA**：GitLab 证书链到 `OOCL Root Certificate Authority`，后端 Alpine 容器的 `ca-certificates.crt` 中 OOCL 条目为 0。需挂载 CA 并设置 `SSL_CERT_DIR`，否则连接时报证书不受信任。
- **Webhook 回连**：没有公网 DNS 指向本机，回调只能用 IP，见下节。

服务端开关（均为本地生成，不需要外部签发）：

```bash
MULTICA_VCS_INTEGRATION_ENABLED=true
MULTICA_VCS_SECRET_KEY=$(openssl rand -base64 32)
```

## Webhook 回连：只能走 IP

GitLab 的回调不经过本机 dnsmasq，走公网解析；而 `worklab.com` 在公网是通配记录，指向第三方站点，不是本机。所以回连用不了域名，只能直接写 IP。

可行性：

- 入口：`<WSL_IP>` 是 WSL NAT 地址，公司网段路由不到；唯一路径是 Windows 公司网段地址 + `portproxy` 到 `<WSL_IP>:443`
- 未验证：GitLab 能否路由到这台 Windows 主机没测过；该机防火墙三个 profile 当前全关，`portproxy` 一开即对所在网段直接暴露
- 证书：Traefik 只有 `DNS:worklab.com` 与 `DNS:*.worklab.com`，没有 IP SAN，用 IP 访问要在 GitLab 侧关掉 SSL 验证，此时 `MULTICA_VCS_SECRET_KEY` 是唯一鉴权

不在候选里：接入 tailnet（GitLab 在公司网段，不可能）、改公网 DNS（该记录不在本机控制范围内）。

容器侧还有一个前提：`ca-certificates.crt` 没有 OOCL 根证书，`wget https://<GITLAB_IP>/` 报 `certificate verify failed`，需挂载 CA。

## 参考

- <https://multica.ai/docs/zh/vcs-integration>
- <https://github.com/multica-ai/multica/blob/main/SELF_HOSTING.md>
