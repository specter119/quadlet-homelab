#!/bin/bash
set -euo pipefail

DEP="${1:-}"
[[ -n "$DEP" ]] || exit 0

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SECRETS_DIR="$ROOT/.dotter/secrets"
LOCAL_TOML="$ROOT/.dotter/local.toml"

parse_packages() {
  python3 - <<'PY'
import tomllib
from pathlib import Path

path = Path(".dotter/local.toml")
if not path.exists():
    print("")
    raise SystemExit(0)
with path.open("rb") as fh:
    data = tomllib.load(fh)
packages = data.get("packages", [])
if isinstance(packages, list):
    print(" ".join(str(p) for p in packages))
else:
    print("")
PY
}

needs_dep() {
  local pkg=$1 dep=$2
  local dir="$ROOT/$pkg/containers/systemd"
  [[ -d "$dir" ]] || return 1
  grep -Eq "(^|[[:space:]])(Requires|After)=.*${dep}\\.service([[:space:]]|$)" "$dir"/*.container 2>/dev/null
}

needs_dep_conf() {
  local pkg=$1 dep=$2
  local conf="$SECRETS_DIR/$pkg.conf"
  local re=""
  [[ -f "$conf" ]] || return 1
  case "$dep" in
    postgres) re='postgresql://|postgres-password|postgres[_-]' ;;
    garage) re='-s3-|s3-|garage|minio' ;;
  esac
  [[ -n "$re" ]] || return 1
  grep -Eq "$re" "$conf"
}

if [[ -f "$LOCAL_TOML" ]]; then
  ENABLED_PACKAGES=$(parse_packages)
fi
if [[ -z "${ENABLED_PACKAGES:-}" ]]; then
  ENABLED_PACKAGES=$(ls "$SECRETS_DIR"/*.conf 2>/dev/null | xargs -n1 basename 2>/dev/null | sed "s/\.conf$//")
fi
ENABLED_PACKAGES=$(echo "$ENABLED_PACKAGES" | tr '\n' ' ' | xargs)

declare -A SEEN
LINES=()
for pkg in $ENABLED_PACKAGES; do
  [[ "$pkg" == "$DEP" ]] && continue
  [[ -f "$ROOT/$pkg/containers/systemd/$pkg.network" ]] || continue
  if needs_dep "$pkg" "$DEP" || needs_dep_conf "$pkg" "$DEP"; then
    if [[ -z "${SEEN[$pkg]:-}" ]]; then
      SEEN["$pkg"]=1
      LINES+=("Network=${pkg}.network")
    fi
  fi
done

if (( ${#LINES[@]} > 0 )); then
  IFS=$'\n'
  printf '%s' "${LINES[*]}"
fi
