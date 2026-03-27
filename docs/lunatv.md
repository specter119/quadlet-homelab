# LunaTV

LunaTV 使用官方 Docker 镜像 `ghcr.io/moontechlab/lunatv:latest`，存储后端使用上游推荐的 Kvrocks。

## 组成

- `lunatv-kvrocks.container`：保存收藏、播放记录、站点配置
- `lunatv.container`：Web 应用，通过 Traefik 暴露为 `https://lunatv.{{domain}}`

## 登录信息

- 用户名固定为 `admin`
- 密码来自 Podman secret `lunatv-password`

查看当前密码：

```bash
podman secret inspect lunatv-password --showsecret --format '{{.SecretData}}'
```

## 参考

- <https://github.com/MoonTechLab/LunaTV>
- <https://github.com/MoonTechLab/LunaTV/blob/main/README.md>
