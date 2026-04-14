#!/usr/bin/bash
#
# Check the nowledge-mem APT repo for a newer package version.
# If found, rebuild the runtime image and tag it.
# The running service is NOT restarted; the new image takes effect on
# the next `systemctl --user restart nowledge-mem.service`.

set -euo pipefail

config_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
image="localhost/nowledge-mem-runtime"
tag="trixie"
packages_url="https://download-mem.nowledge.co/apt/dists/stable/main/binary-amd64/Packages"

if ! /usr/bin/podman image exists "${image}:${tag}"; then
    echo "[nowledge-mem-check-update] image ${image}:${tag} not found, skipping"
    exit 0
fi

# Current installed package version inside the image.
current=$(/usr/bin/podman run --rm "${image}:${tag}" \
    dpkg-query -W -f='${Version}' nowledge-mem)

# Latest package version from the APT repository.
# Parse the Package stanza to avoid picking up versions from other packages.
latest=$(curl -fsSL "$packages_url" \
    | awk '/^Package: nowledge-mem$/ { found=1 }
           found && /^Version:/ { print $2; exit }')

if [[ -z "$latest" ]]; then
    echo "[nowledge-mem-check-update] failed to fetch latest version" >&2
    exit 1
fi

if [[ "$current" == "$latest" ]]; then
    echo "[nowledge-mem-check-update] up to date: ${current}"
    exit 0
fi

echo "[nowledge-mem-check-update] update available: ${current} -> ${latest}"

/usr/bin/podman build \
    --pull=newer \
    --no-cache \
    -t "${image}:${latest}" \
    -t "${image}:${tag}" \
    -f "$config_dir/Containerfile" \
    "$config_dir"

echo "[nowledge-mem-check-update] built ${image}:${latest}"
echo "[nowledge-mem-check-update] restart nowledge-mem.service to apply"

# Prune old version tags, keeping the two most recent.
/usr/bin/podman images --format '\{{.Tag}}' --filter "reference=${image}" \
    | grep -xE '[0-9]+\.[0-9]+\.[0-9]+.*' \
    | sort -rV \
    | tail -n +3 \
    | while read -r old; do
        echo "[nowledge-mem-check-update] removing old tag ${image}:${old}"
        /usr/bin/podman rmi "${image}:${old}" 2>/dev/null || true
    done
