#!/bin/bash
set -e

SOURCE_DIR="{{dotter.current_dir}}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -z "$SOURCE_DIR" || "$SOURCE_DIR" == *"{{dotter.current_dir}}"* ]]; then
  SOURCE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
fi
SECRETS_DIR="$SOURCE_DIR/.dotter/secrets"
LOCAL_TOML="$SOURCE_DIR/.dotter/local.toml"
VERBOSE=false
CREATED=0
TOTAL=0

[[ "$1" == "-v" || "$1" == "--verbose" ]] && VERBOSE=true

log() { $VERBOSE && echo "$@" || true; }

echo "[pre-deploy] Checking secrets..."
: > "$HOME/.cache/dotter-render.log"

# Parse enabled packages from local.toml
# Format: packages = ['traefik', 'silverbullet', 'dozzle', 'omnivore']
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

if [[ -f "$LOCAL_TOML" ]]; then
  ENABLED_PACKAGES=$(parse_packages)
fi
if [[ -z "$ENABLED_PACKAGES" ]]; then
  ENABLED_PACKAGES=$(ls "$SECRETS_DIR"/*.conf 2>/dev/null | xargs -n1 basename 2>/dev/null | sed "s/\.conf$//")
fi
ENABLED_PACKAGES=$(echo "$ENABLED_PACKAGES" | tr '\n' ' ' | xargs)
log "Enabled packages: $ENABLED_PACKAGES"

# Cache existing secrets once at startup
declare -A EXISTING_SECRETS
while read -r name; do
  [[ -n "$name" ]] && EXISTING_SECRETS["$name"]=1
done < <(podman secret ls --format '\{{.Name}}')

generate_hex() { openssl rand -hex "$1"; }
secret_exists() { [[ -v EXISTING_SECRETS["$1"] ]]; }

create_secret() {
  local name=$1 value=$2
  ((TOTAL++))
  if secret_exists "$name"; then
    log "  $name: exists"
    return 1
  fi
  if ! echo -n "$value" | podman secret create "$name" - >/dev/null 2>&1; then
    log "  $name: exists"
    EXISTING_SECRETS["$name"]=1
    return 1
  fi
  EXISTING_SECRETS["$name"]=1
  ((CREATED++))
  log "  $name: created"
}

get_secret() {
  podman secret inspect "$1" --showsecret --format '\{{.SecretData}}' 2>/dev/null | tr -d '\n'
}

declare -A SECRETS

process_conf() {
  local conf=$1
  local service=$(basename "$conf" .conf)
  [[ ! -f "$conf" ]] && return

  log "=== $service ==="

  while IFS=: read -r name type param; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    [[ "$type" == "computed" ]] && continue

    case "$type" in
    hex) value=$(generate_hex "$param") ;;
    fixed) value="$param" ;;
    esac

    create_secret "$name" "$value" && SECRETS["$name"]="$value" || SECRETS["$name"]=$(get_secret "$name")
  done <"$conf"

  while IFS=: read -r name type param; do
    [[ "$type" != "computed" ]] && continue
    local value="$param"
    for key in "${!SECRETS[@]}"; do
      value="${value//\$\{$key\}/${SECRETS[$key]}}"
    done
    create_secret "$name" "$value" || true
  done <"$conf"
}

# Only process secrets for enabled packages
# Process shared infrastructure first (postgres, garage) to ensure dependencies are available
for pkg in postgres garage; do
  [[ " $ENABLED_PACKAGES " == *" $pkg "* ]] && process_conf "$SECRETS_DIR/$pkg.conf"
done
for pkg in $ENABLED_PACKAGES; do
  [[ "$pkg" == "postgres" || "$pkg" == "garage" ]] && continue
  process_conf "$SECRETS_DIR/$pkg.conf"
done

echo "Secrets: $TOTAL valid ($CREATED newly created)"
