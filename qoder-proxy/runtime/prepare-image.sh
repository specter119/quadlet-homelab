#!/usr/bin/env bash
set -euo pipefail

upstream_repo="{{qoder-proxy.repo_overwrite}}"
upstream_branch="{{qoder-proxy.repo_branch}}"

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

# Determine which branch to track
if [[ -n "$upstream_branch" ]]; then
  target_branch="$upstream_branch"
else
  # Resolve default branch from remote
  target_branch="main"
  if symref_output="$(git ls-remote --symref "$upstream_repo" HEAD 2>/dev/null)"; then
    branch="$(echo "$symref_output" | awk '/^ref:/ {sub("refs/heads/", "", $2); print $2}')"
    [[ -n "$branch" ]] && target_branch="$branch"
  fi
fi

# Resolve upstream HEAD for the target branch
upstream_ref=""
if ref_output="$(git ls-remote "$upstream_repo" "refs/heads/$target_branch" 2>/dev/null)"; then
  upstream_ref="$(echo "$ref_output" | awk '{print $1}')"
fi

if [[ -z "$upstream_ref" ]]; then
  echo "[qoder-proxy-prepare] warning: cannot reach upstream; using cache if available" >&2
fi

current_ref=""
[[ -f "$ref_file" ]] && current_ref="$(<"$ref_file")"

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
  echo "[qoder-proxy-prepare] syncing $upstream_repo ($target_branch)"
  if [[ ! -d "$src_dir/.git" ]]; then
    git clone --depth 1 --branch "$target_branch" "$upstream_repo" "$src_dir"
  else
    git -C "$src_dir" fetch --depth 1 origin "$target_branch"
    git -C "$src_dir" reset --hard FETCH_HEAD
    git -C "$src_dir" clean -fd
  fi
fi

build=false
if [[ "$refresh" == true ]]; then
  build=true
elif ! podman image exists "$image"; then
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
