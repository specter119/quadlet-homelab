#!/usr/bin/env bash
set -euo pipefail

script_dir="$(dirname -- "$(readlink -f -- "$0")")"
config_dir="$script_dir"
image="localhost/deepseek-harness:latest"
lock_file="$config_dir/package-lock.json"
marker="${XDG_CACHE_HOME:-$HOME/.cache}/deepseek-harness/build.lockhash"

lockhash="$(sha256sum "$lock_file" | cut -d' ' -f1)"

# Skip when the image exists and was built from this exact lockfile state.
if podman image exists "$image"; then
  if [[ -f "$marker" ]] && [[ "$(cat "$marker")" == "$lockhash" ]]; then
    echo "Image $image is up to date (lockfile unchanged)"
    exit 0
  fi
  if [[ ! -f "$marker" ]]; then
    # First run under this script: adopt the existing image's state.
    mkdir -p "$(dirname "$marker")"
    printf '%s\n' "$lockhash" >"$marker"
    echo "Image $image exists; recorded lockfile state"
    exit 0
  fi
fi

# If ~/.npmrc exists, mount it as a build secret so npm ci can reach the
# configured registry (e.g. Artifactory). Secrets never enter image layers.
npm_build_args=()
if [[ -f "$HOME/.npmrc" ]]; then
  npm_build_args=(--secret id=npmrc,src="$HOME/.npmrc")
fi

mkdir -p "$(dirname "$marker")"
podman build \
  --pull=always \
  "${npm_build_args[@]}" \
  --tag "$image" \
  "$config_dir"
printf '%s\n' "$lockhash" >"$marker"
echo "Built $image from lockfile $lockhash"