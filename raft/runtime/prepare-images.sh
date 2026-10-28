#!/usr/bin/env bash
# 构建 raft-server / raft-web / raft-rw-bootstrap 三个本地镜像。
#
# 上游不发布镜像（releases 只是源码快照，构建管线在私有仓），所以镜像必须自建。
# 这里沿用 deepseek-harness 的既有范式：localhost/<name>:latest + Quadlet 侧
# Pull=never，本脚本以 hash 标记做幂等判断，输入变化时才重建。
#
# 构建期只对上游 Dockerfile 做**三处机械改动**，不维护 fork：
#   1. `RUN corepack enable` → 用挂进来的 ~/.npmrc 认证，直接全局安装 packageManager
#      声明的那一版 pnpm
#   2. 两处 `RUN pnpm install --frozen-lockfile`（server 与 web 的 builder）→
#      带 --mount=type=secret 挂入 ~/.npmrc 与 CA bundle
#   3. 短名 `FROM <name>:<tag>` → 补成 `docker.io/library/<name>:<tag>`（见下）
# 前两处锚点缺失或 packageManager 不可解析时脚本失败退出，绝不静默产出一个
# 装不上依赖的镜像。
#
# 为什么不用 corepack：
#   * registry.npmjs.org 在本机网络不可达，必须走内网 npm 镜像
#   * 内网镜像匿名读返回 401，而 npm 凭据的 key 形如 `//host/path/:_authToken`，
#     无法通过环境变量注入
#   * corepack 不读 /root/.npmrc（也没有 token 类环境变量），它下载 pnpm 必然是
#     匿名请求并 401
#   npm 读 /root/.npmrc，所以「用 npm 装 pnpm」是既不把 token 写进镜像层/ENV、
#   又能认证的唯一路径。代价是必须显式钉住 prefix（见下）。
#
# 另一件事是 CA：企业网络用 MITM 代理，容器自带的信任库不含公司根 CA，而 Node
# 默认用自带的 Mozilla 库、**不读系统库**，所以必须显式给 NODE_EXTRA_CA_CERTS。
# 与 magpie.container 是同一套做法（复用宿主 /etc/ssl/certs/ca-certificates.crt），
# 区别只是构建期用 secret 挂载、不落进镜像层；运行时的挂载在 raft-server.container。
#
# web 镜像还有两个上游隐含要求（都踩过）：
#   * 短名 `FROM nginx:alpine` 依赖宿主 shortnames 别名，本机没有；本仓库约定写全限定名
#   * 必须传 VITE_COMMIT_SHA（或 VITE_FRONTEND_RELEASE_ID），否则 vite 插件不产出
#     dist/desktop-manifest.json，而上游 Dockerfile 会因 `test -f` 失败而**故意**中断
#     （仓库的 check-immutable-assets.mjs 容忍该文件缺失，所以失败点被推到最后一个 stage）
set -euo pipefail

script_dir="$(dirname -- "$(readlink -f -- "$0")")"

RAFT_SOURCE_REPO="${RAFT_SOURCE_REPO:-https://github.com/botiverse/raft-source.git}"
RAFT_SOURCE_TAG="${RAFT_SOURCE_TAG:-v1.21.23-source.1}"
RAFT_NPMRC="${RAFT_NPMRC:-$HOME/.npmrc}"
RAFT_HOST_CA_BUNDLE="${RAFT_HOST_CA_BUNDLE:-/etc/ssl/certs/ca-certificates.crt}"
RAFT_WEB_API_URL="${RAFT_WEB_API_URL:?RAFT_WEB_API_URL 必须由 raft-prepare.service 提供（https://raft-api.<domain>）}"

cache_root="${XDG_CACHE_HOME:-$HOME/.cache}/raft"
src_dir="$cache_root/src"
dockerfile_dir="$cache_root/dockerfiles"
marker="$cache_root/build.lockhash"

server_image="localhost/raft-server:latest"
web_image="localhost/raft-web:latest"
rw_bootstrap_image="localhost/raft-rw-bootstrap:latest"

fail() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[raft-prepare] $*"; }

[[ -f "$RAFT_NPMRC" ]] || fail "找不到 $RAFT_NPMRC；内网 npm 镜像需要认证，没有它无法安装依赖"
if ! grep -q '^registry=' "$RAFT_NPMRC"; then
  echo "[raft-prepare] 警告：$RAFT_NPMRC 没有 registry= 行；若本机无法直连 npmjs，构建会失败" >&2
fi

build_secrets=(--secret "id=raft_npmrc,src=$RAFT_NPMRC")
ca_mount=""
ca_env=""
if [[ -f "$RAFT_HOST_CA_BUNDLE" ]]; then
  ca_mount="--mount=type=secret,id=raft_ca,target=/etc/raft-host-ca.crt"
  ca_env="NODE_EXTRA_CA_CERTS=/etc/raft-host-ca.crt "
  build_secrets+=(--secret "id=raft_ca,src=$RAFT_HOST_CA_BUNDLE")
else
  echo "[raft-prepare] 警告：找不到 $RAFT_HOST_CA_BUNDLE；若本机走 MITM 代理，构建会在拉取外部 tarball（如 cdn.sheetjs.com）时 TLS 失败" >&2
fi

# 先同步源码再算 hash：让 hash 覆盖解析出的 commit，tag 被移动（或本机有陈旧 clone）
# 时能自愈，而不是安静地复用旧镜像。
log "同步 $RAFT_SOURCE_REPO 的 $RAFT_SOURCE_TAG"
if [[ -d "$src_dir/.git" ]]; then
  # 开机时网络可能还没通：本地已有该 tag 就带着告警继续，不让整个栈卡在 git fetch 上。
  # 前导 + 允许 tag 被上游移动后强制更新，否则「自愈」只是注释里的愿望。
  if ! git -C "$src_dir" fetch --quiet --depth 1 origin "+refs/tags/$RAFT_SOURCE_TAG:refs/tags/$RAFT_SOURCE_TAG"; then
    git -C "$src_dir" rev-parse -q --verify "refs/tags/$RAFT_SOURCE_TAG^{commit}" >/dev/null \
      || fail "无法获取 $RAFT_SOURCE_TAG，且本地没有该 tag"
    echo "[raft-prepare] 警告：git fetch 失败，使用本地已有的 $RAFT_SOURCE_TAG" >&2
  fi
  git -C "$src_dir" checkout --quiet --detach "$RAFT_SOURCE_TAG" 2>/dev/null
  # 这是我们自己管理的缓存 clone；清掉 untracked 以免上一次构建的残留污染上下文。
  git -C "$src_dir" clean -qffd
else
  mkdir -p "$(dirname "$src_dir")"
  git clone --quiet --depth 1 --branch "$RAFT_SOURCE_TAG" "$RAFT_SOURCE_REPO" "$src_dir"
fi
commit_sha="$(git -C "$src_dir" rev-parse HEAD)"
log "commit $commit_sha"

# pnpm 版本从上游 packageManager 派生，不硬编码：上游升级 pnpm 时我们自动跟随，
# 也让 pnpm 的 manage-package-manager-versions 自管理变成 no-op（版本已一致）。
pnpm_version="$(python3 - "$src_dir/package.json" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
field = data.get("packageManager", "")
if not field.startswith("pnpm@") or len(field) <= len("pnpm@"):
    raise SystemExit(f"package.json 的 packageManager 不是 pnpm@<version>：{field!r}")
print(field.split("@", 1)[1])
PY
)" || fail "无法从 $src_dir/package.json 解析 pnpm 版本"
log "pnpm $pnpm_version（来自上游 packageManager）"

lockhash() {
  {
    printf 'tag=%s\n' "$RAFT_SOURCE_TAG"
    printf 'commit=%s\n' "$commit_sha"
    printf 'repo=%s\n' "$RAFT_SOURCE_REPO"
    printf 'web_api_url=%s\n' "$RAFT_WEB_API_URL"
    printf 'pnpm=%s\n' "$pnpm_version"
    # 故意不含 ~/.npmrc 内容：token 轮换不该触发全量重建（token 只在构建期使用）。
    cat "$script_dir/prepare-images.sh" \
      "$script_dir/raft-rw-bootstrap.Containerfile" \
      "$script_dir/prepare-bootstrap-sql.mjs" \
      "$script_dir/risingwave-bootstrap.sh"
  } | sha256sum | cut -d' ' -f1
}

lockhash_now="$(lockhash)"

if podman image exists "$server_image" \
  && podman image exists "$web_image" \
  && podman image exists "$rw_bootstrap_image" \
  && [[ -f "$marker" ]] \
  && [[ "$(cat "$marker")" == "$lockhash_now" ]]; then
  log "镜像已是最新（输入未变），跳过构建"
  exit 0
fi

# 把上游 Dockerfile 机械改写成可走内网镜像构建的版本，写到 clone 之外
# （避免污染 git 工作树，也避免被上面的 clean 删掉）。
mkdir -p "$dockerfile_dir"
python3 - "$src_dir/packages/server/Dockerfile" "$dockerfile_dir/server.Dockerfile" \
  "$src_dir/packages/web/Dockerfile" "$dockerfile_dir/web.Dockerfile" \
  "$pnpm_version" "$ca_mount" "$ca_env" <<'PY'
import re
import sys
from pathlib import Path

server_src, server_dst, web_src, web_dst, pnpm_version, ca_mount, ca_env = sys.argv[1:8]

COREPACK_ANCHOR = "RUN corepack enable"
INSTALL_ANCHOR = "RUN pnpm install --frozen-lockfile"
SECRET_MOUNT = "--mount=type=secret,id=raft_npmrc,target=/root/.npmrc"
# 必须显式钉住全局 prefix：挂进来的 ~/.npmrc 可能带 prefix= 设置（本机就有），
# 不钉的话 npm 会照它把 pnpm 装到 ~/.local/bin——不在 PATH 上，后续 `pnpm` 找不到。
PNPM_PREFIX = "npm_config_prefix=/usr/local"
# 短名 FROM 依赖宿主 shortnames 别名（本机只有 node 有、nginx 没有），而本仓库约定
# 写全限定名（如 docker.io/library/traefik），所以这里统一补上 docker.io/library/。
UNQUALIFIED_FROM = re.compile(
    r"^FROM\s+(--platform=\S+\s+)?([A-Za-z0-9][A-Za-z0-9._-]*:[A-Za-z0-9._${}-]+)\s*$"
)

mounts = SECRET_MOUNT + (" " + ca_mount if ca_mount else "")


def patch(src: str, dst: str) -> None:
    lines = Path(src).read_text(encoding="utf-8").splitlines(keepends=True)

    for index, line in enumerate(lines):
        match = UNQUALIFIED_FROM.match(line.rstrip("\n"))
        if match is None:
            continue
        platform, image = match.group(1) or "", match.group(2)
        lines[index] = f"FROM {platform}docker.io/library/{image}\n"
        print(f"[raft-prepare] 限定基础镜像：{image} → docker.io/library/{image}")

    corepack = [i for i, line in enumerate(lines) if line.strip() == COREPACK_ANCHOR]
    if len(corepack) != 1:
        raise SystemExit(
            f"{src}: 期望恰好一行 `{COREPACK_ANCHOR}`，实际 {len(corepack)} 行；"
            "上游 Dockerfile 结构已变，需同步 raft/runtime/prepare-images.sh 的补丁锚点"
        )
    install = [i for i, line in enumerate(lines) if line.strip() == INSTALL_ANCHOR]
    if len(install) != 1:
        raise SystemExit(
            f"{src}: 期望恰好一行 `{INSTALL_ANCHOR}`，实际 {len(install)} 行；"
            "上游 Dockerfile 结构已变，需同步 raft/runtime/prepare-images.sh 的补丁锚点"
        )

    lines[corepack[0]] = f"RUN {mounts} {ca_env}{PNPM_PREFIX} npm install --global pnpm@{pnpm_version}\n"
    lines[install[0]] = f"RUN {mounts} {ca_env}{INSTALL_ANCHOR[len('RUN ') :]}\n"

    Path(dst).write_text("".join(lines), encoding="utf-8")
    print(f"[raft-prepare] 生成 {dst}")


patch(server_src, server_dst)
patch(web_src, web_dst)
PY

log "构建 $server_image"
podman build --pull=always "${build_secrets[@]}" \
  --tag "$server_image" \
  --file "$dockerfile_dir/server.Dockerfile" \
  "$src_dir"

# VITE_COMMIT_SHA 不是可选项：缺它 vite 插件不产出 desktop-manifest.json，
# 上游 Dockerfile 会因此失败（见文件头注释）。releaseId 会自动回退到 commitSha，
# 所以不需要单独传 VITE_FRONTEND_RELEASE_ID。
log "构建 $web_image（VITE_API_URL=$RAFT_WEB_API_URL，build-time 烤入）"
podman build --pull=always "${build_secrets[@]}" \
  --build-arg "VITE_API_URL=$RAFT_WEB_API_URL" \
  --build-arg "VITE_COMMIT_SHA=$commit_sha" \
  --build-arg "VITE_BUILD_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --build-arg "VITE_RELEASE_BRANCH=$RAFT_SOURCE_TAG" \
  --tag "$web_image" \
  --file "$dockerfile_dir/web.Dockerfile" \
  "$src_dir"

# 必须晚于 server 镜像（FROM localhost/raft-server）。SQL 在这一步的 emit 阶段生成，
# 我们自己的脚本经额外构建上下文 homelab 传入（它们不在上游源码里）。
log "构建 $rw_bootstrap_image"
podman build \
  --build-context "homelab=$script_dir" \
  --tag "$rw_bootstrap_image" \
  --file "$script_dir/raft-rw-bootstrap.Containerfile" \
  "$src_dir"

mkdir -p "$cache_root"
printf '%s\n' "$lockhash_now" >"$marker"
log "完成，标记写入 $marker"
