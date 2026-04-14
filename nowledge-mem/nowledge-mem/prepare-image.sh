#!/usr/bin/bash

set -euo pipefail

config_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
image="localhost/nowledge-mem-runtime"
tag="trixie"

if /usr/bin/podman image exists "${image}:${tag}"; then
    exit 0
fi

/usr/bin/podman build \
    -t "${image}:${tag}" \
    -f "$config_dir/Containerfile" \
    "$config_dir"

# Tag the image with the installed package version for tracking.
ver=$(/usr/bin/podman run --rm "${image}:${tag}" \
    dpkg-query -W -f='${Version}' nowledge-mem)
/usr/bin/podman tag "${image}:${tag}" "${image}:${ver}"
echo "Built ${image}:${tag} (nowledge-mem ${ver})"
