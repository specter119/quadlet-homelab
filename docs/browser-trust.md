# Host 浏览器信任 Traefik 本地证书（验证记录）

## 结论

证书生成和信任应跟着**浏览器所在 host** 走：

- 浏览器在 Windows：Root CA 装到 Windows，Traefik 可在 WSL 中使用生成的 leaf cert/key。
- 浏览器在 Linux：Root CA 装到 Linux，本机 Traefik 直接使用生成的 leaf cert/key。

路线分工：

- **稳定使用**：`mkcert` 本地 Root CA + 独立 server cert。
- **快速尝试**：`certs-maker` 自签 wildcard cert，用来先跑通 HTTPS 入口和 Traefik 配置。

两者不矛盾：`certs-maker` 适合快速验证服务能起来；`mkcert` 适合长期让 Chrome / Firefox 正常信任。

## 公共约定

- `DOMAIN` 必须和 `.dotter/local.toml` 里的 `domain` 一致。
- Traefik 读取固定命名：
  - `~/.local/state/traefik/ssl/<domain>.pem.crt`
  - `~/.local/state/traefik/ssl/<domain>.pem.key`
- 替换证书后重启 Traefik：

  ```bash
  systemctl --user restart traefik.service
  ```

- 验证 Traefik 实际吐出的证书：

  ```bash
  openssl s_client -connect 127.0.0.1:443 -servername dozzle.worklab.com -showcerts </dev/null 2>/dev/null \
    | openssl x509 -noout -subject -issuer -dates -ext subjectAltName -ext basicConstraints
  ```

## 稳定使用：`mkcert`

### 公共流程

1. 在浏览器所在 host 安装 `mkcert`
2. 安装本地 Root CA：

   ```bash
   mkcert -install
   ```

3. 签发 wildcard server cert：

   ```bash
   mkcert worklab.com "*.worklab.com"
   ```

4. 将生成的 leaf cert/key 放到 Traefik 读取路径
5. 重启 Traefik 并验证证书

预期：

- `issuer` 是 `mkcert development CA`
- `subjectAltName` 包含 `worklab.com` 和 `*.worklab.com`
- leaf cert 只作为服务端证书使用

### Windows host 分支

适用：浏览器在 Windows，Traefik 在 WSL 或远端 Linux。

- 在 Windows PowerShell 里执行 `mkcert -install` 和 `mkcert worklab.com "*.worklab.com"`。
- WSL 只负责接收生成的 leaf cert/key，并按公共约定放到 Traefik 读取路径。
- Firefox 若不信任 Windows Root Store，检查 `about:config` 里的 `security.enterprise_roots.enabled`。
- 若无痕窗口正常、普通窗口仍显示 `Not secure`，优先清理对应站点的 site data / service worker / DNS cache / socket cache。

> [!NOTE]
> SilverBullet 属于 PWA/前端重应用，旧 service worker 或站点缓存可能导致普通窗口残留旧安全状态。

### Linux host 分支

适用：浏览器和 Traefik 都在同一台 Linux host。

- 在 Linux host 上安装 `mkcert`。
- 若使用 Firefox/Chromium，确保安装 NSS 工具：
  - Arch：`sudo pacman -S mkcert nss`
  - Debian/Ubuntu：`sudo apt install mkcert libnss3-tools`
  - Fedora：`sudo dnf install mkcert nss-tools`
- 在 Linux host 上执行 `mkcert -install` 和 `mkcert worklab.com "*.worklab.com"`。
- 将生成的 leaf cert/key 放到本机 Traefik 读取路径。

> [!TIP]
> 如果 Firefox 仍不信任，先确认 `certutil` 存在，再重新执行 `mkcert -install`。

## 快速尝试：`certs-maker`

适用：想先快速跑通 Traefik HTTPS 入口，不追求所有浏览器长期无提示信任。

```bash
mkdir -p ~/.local/state/traefik/ssl

DOMAIN=worklab.com

podman run --rm \
  -v ~/.local/state/traefik/ssl:/ssl \
  docker.io/soulteary/certs-maker \
  "--CERT_DNS=${DOMAIN},*.${DOMAIN}"
```

边界：

- 生成快，适合冷启动或排查 Traefik 证书加载。
- 浏览器可能需要手动信任、导入或临时放行。
- 当前生成形态可能是 `CA:TRUE` 自签证书直接作为站点证书，Firefox 可能不接受这种 end-entity。

## 参考

> [!IMPORTANT]
> 继续维护本文档前，先重新检查这些官方来源是否有变更。

- [mkcert README](https://github.com/FiloSottile/mkcert)
- [Mozilla Support: Enterprise Roots preference](https://support.mozilla.org/en-US/kb/how-disable-enterprise-roots-preference)
- [Chromium: Chrome Root Store FAQ](https://chromium.googlesource.com/chromium/src/+/main/net/data/ssl/chrome_root_store/faq.md)
- [Microsoft Learn: Import-Certificate](https://learn.microsoft.com/en-us/powershell/module/pki/import-certificate)
- [certs-maker](https://github.com/soulteary/certs-maker)
