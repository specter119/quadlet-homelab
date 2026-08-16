#!/usr/bin/env bash
set -euo pipefail

script_dir="$(dirname -- "$(readlink -f -- "$0")")"
config_dir="$script_dir"
image="localhost/deepseek-harness:runtime"
lock_file="$config_dir/package-lock.json"
version="$(awk '
  /"node_modules\/@deepseek-ai\/dsh": \{/ { in_dsh=1; next }
  in_dsh && /"version":/ {
    value=$2
    gsub(/[",]/, "", value)
    print value
    exit
  }
' "$lock_file")"

if [[ -z "$version" ]]; then
  echo "Unable to read @deepseek-ai/dsh version from $lock_file" >&2
  exit 1
fi

podman build \
  --pull=always \
  --build-arg "DSH_VERSION=$version" \
  --tag "$image" \
  "$config_dir"
podman tag "$image" "localhost/deepseek-harness:$version"
echo "Built $image (DeepSeek Harness $version)"
