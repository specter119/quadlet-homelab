#!/usr/bin/env bash
set -euo pipefail

script_dir="$(dirname -- "$(readlink -f -- "$0")")"
config_dir="$script_dir"
image="localhost/deepseek-harness:latest"
marker="${XDG_CACHE_HOME:-$HOME/.cache}/deepseek-harness/build.inputhash"

inputhash="$(cat "$config_dir/Containerfile" "$config_dir/package.json" "$config_dir/run-web.sh" | sha256sum | cut -d' ' -f1)"

# Skip only when the image exists and was built from exactly these build inputs.
# A missing marker means the image's inputs are unknown, so rebuild.
if podman image exists "$image" && [[ -f "$marker" ]] && [[ "$(cat "$marker")" == "$inputhash" ]]; then
  echo "Image $image is up to date (build inputs unchanged)"
  exit 0
fi

# If ~/.npmrc exists, mount it as a build secret so npm install can reach the
# configured registry (e.g. Artifactory). Secrets never enter image layers.
# No lockfile is kept: its `resolved` URLs pin the registry host it was generated
# against, and npm by default only rewrites the npmjs host.
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
printf '%s\n' "$inputhash" >"$marker"
echo "Built $image from build inputs $inputhash"
