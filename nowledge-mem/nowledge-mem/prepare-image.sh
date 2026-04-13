#!/usr/bin/bash

set -euo pipefail

config_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
image="localhost/nowledge-mem-runtime:trixie"

if /usr/bin/podman image exists "$image"; then
    exit 0
fi

/usr/bin/podman build \
    -t "$image" \
    -f "$config_dir/Containerfile" \
    "$config_dir"
