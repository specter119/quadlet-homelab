#!/usr/bin/env bash
set -euo pipefail

upstream_repo="{{qoder-proxy.repo_overwrite}}"

if [[ -z "$upstream_repo" ]]; then
  echo "[qoder-proxy-prepare] repo_overwrite is empty; local build disabled" >&2
  exit 1
fi

cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/qoder-proxy"
src_dir="$cache_dir/src"
ref_file="$cache_dir/head.ref"
signature_file="$cache_dir/build.signature"
image="localhost/qoder-proxy:latest"

mkdir -p "$cache_dir"

# Resolve default branch and HEAD from remote
default_branch="main"
upstream_ref=""
if symref_output="$(git ls-remote --symref "$upstream_repo" HEAD 2>/dev/null)"; then
  branch="$(echo "$symref_output" | awk '/^ref:/ {sub("refs/heads/", "", $2); print $2}')"
  [[ -n "$branch" ]] && default_branch="$branch"
  upstream_ref="$(echo "$symref_output" | awk '!/^ref:/ && /HEAD/ {print $1}')"
else
  echo "[qoder-proxy-prepare] warning: cannot reach upstream; using cache if available" >&2
fi

current_ref=""
[[ -f "$ref_file" ]] && current_ref="$(<"$ref_file")"

current_sig=""
[[ -f "$signature_file" ]] && current_sig="$(<"$signature_file")"

desired_sig="$(printf '%s\n' "${upstream_ref:-$current_ref}" "$upstream_repo")"

# Clean corrupt cache
[[ -e "$src_dir" && ! -d "$src_dir/.git" ]] && rm -rf "$src_dir"

refresh=false
if [[ ! -d "$src_dir/.git" ]]; then
  refresh=true
elif [[ -n "$upstream_ref" && "$current_ref" != "$upstream_ref" ]]; then
  refresh=true
fi

if [[ "$refresh" == true && -z "$upstream_ref" && ! -d "$src_dir/.git" ]]; then
  echo "[qoder-proxy-prepare] upstream unavailable and no cache" >&2
  exit 1
fi

if [[ "$refresh" == true ]]; then
  echo "[qoder-proxy-prepare] syncing $upstream_repo ($default_branch)"
  if [[ ! -d "$src_dir/.git" ]]; then
    git clone --depth 1 --branch "$default_branch" "$upstream_repo" "$src_dir"
  else
    git -C "$src_dir" fetch --depth 1 origin "$default_branch"
    git -C "$src_dir" reset --hard FETCH_HEAD
    git -C "$src_dir" clean -fd
  fi
fi

build=false
if [[ "$refresh" == true ]]; then
  build=true
elif ! podman image exists "$image"; then
  build=true
elif [[ "$current_sig" != "$desired_sig" ]]; then
  build=true
fi

if [[ "$build" == true ]]; then
  echo "[qoder-proxy-prepare] building $image"
  podman build -t "$image" "$src_dir"
fi

# Persist tracking state
if [[ -n "$upstream_ref" ]]; then
  printf '%s\n' "$upstream_ref" >"$ref_file"
elif [[ -d "$src_dir/.git" ]]; then
  git -C "$src_dir" rev-parse HEAD >"$ref_file"
fi
printf '%s\n' "$desired_sig" >"$signature_file"
