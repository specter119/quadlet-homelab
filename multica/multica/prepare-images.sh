#!/usr/bin/env bash
set -euo pipefail

cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/multica"
src_dir="$cache_dir/src"
ref_file="$cache_dir/main.ref"
signature_file="$cache_dir/build.signature"
upstream_repo="https://github.com/multica-ai/multica.git"
upstream_branch="main"
server_image="localhost/multica-server:main"
web_image="localhost/multica-web:main"
server_containerfile="${XDG_CONFIG_HOME:-$HOME/.config}/multica-server/Containerfile"
web_containerfile="${XDG_CONFIG_HOME:-$HOME/.config}/multica-web/Containerfile"

mkdir -p "$cache_dir"

upstream_ref=""
if resolved_ref="$(git ls-remote "$upstream_repo" "refs/heads/$upstream_branch" | awk 'NR == 1 {print $1}')"; then
  upstream_ref="$resolved_ref"
else
  echo "[multica-prepare] warning: failed to resolve upstream ref, using cached source if available" >&2
fi

current_ref=""
if [[ -f "$ref_file" ]]; then
  current_ref="$(<"$ref_file")"
fi

current_signature=""
if [[ -f "$signature_file" ]]; then
  current_signature="$(<"$signature_file")"
fi

desired_signature="$(
  printf '%s\n' "${upstream_ref:-$current_ref}" &&
    sha256sum "$server_containerfile" "$web_containerfile"
)"

if [[ -e "$src_dir" && ! -d "$src_dir/.git" ]]; then
  rm -rf "$src_dir"
fi

refresh_source=false
if [[ ! -d "$src_dir/.git" ]]; then
  refresh_source=true
elif [[ -n "$upstream_ref" && "$current_ref" != "$upstream_ref" ]]; then
  refresh_source=true
fi

if [[ "$refresh_source" == true && -z "$upstream_ref" && ! -d "$src_dir/.git" ]]; then
  echo "[multica-prepare] failed to prepare source: upstream unavailable and cache missing" >&2
  exit 1
fi

if [[ "$refresh_source" == true ]]; then
  if [[ ! -d "$src_dir/.git" ]]; then
    git clone --depth 1 --branch "$upstream_branch" "$upstream_repo" "$src_dir"
  else
    git -C "$src_dir" fetch --depth 1 origin "$upstream_branch"
    git -C "$src_dir" reset --hard FETCH_HEAD
    git -C "$src_dir" clean -fd
  fi
fi

build_required=false
if [[ "$refresh_source" == true ]]; then
  build_required=true
elif ! podman image exists "$server_image"; then
  build_required=true
elif ! podman image exists "$web_image"; then
  build_required=true
elif [[ "$current_signature" != "$desired_signature" ]]; then
  build_required=true
fi

if [[ "$build_required" == true ]]; then
  echo "[multica-prepare] building $server_image"
  podman build \
    --build-arg GOPROXY=https://goproxy.cn,direct \
    --build-arg GOSUMDB=sum.golang.google.cn \
    -t "$server_image" \
    -f "$server_containerfile" \
    "$src_dir"

  echo "[multica-prepare] building $web_image"
  podman build \
    --build-arg REMOTE_API_URL=http://api:8080 \
    -t "$web_image" \
    -f "$web_containerfile" \
    "$src_dir"
fi

if [[ -n "$upstream_ref" ]]; then
  printf '%s\n' "$upstream_ref" >"$ref_file"
elif [[ -d "$src_dir/.git" ]]; then
  git -C "$src_dir" rev-parse HEAD >"$ref_file"
fi

printf '%s\n' "$desired_signature" >"$signature_file"
