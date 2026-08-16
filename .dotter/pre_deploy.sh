#!/bin/bash
set -e

SOURCE_DIR="{{dotter.current_dir}}"
SOURCE_PLACEHOLDER="{"
SOURCE_PLACEHOLDER+="{dotter.current_dir}}"
if [[ -z "$SOURCE_DIR" || "$SOURCE_DIR" == "$SOURCE_PLACEHOLDER" ]]; then
  SOURCE_DIR="$(pwd -P)"
fi
SECRETS_DIR="$SOURCE_DIR/.dotter/secrets"
LOCAL_TOML="$SOURCE_DIR/.dotter/local.toml"
VERBOSE=false
CREATED=0
TOTAL=0

[[ "$1" == "-v" || "$1" == "--verbose" ]] && VERBOSE=true

log() { $VERBOSE && echo "$@" || true; }
warn() { echo "[pre-deploy][warning] $*" >&2; }

check_trusted_source_ranges() {
  local global_toml="$SOURCE_DIR/.dotter/global.toml"

  python3 - "$global_toml" "$LOCAL_TOML" <<'PY'
import ipaddress
import sys
import tomllib
from pathlib import Path


def read_ranges(path: Path, table_path: tuple[str, ...]) -> list[tuple[str, object | None]] | None:
    if not path.exists():
        return None

    with path.open("rb") as handle:
        data = tomllib.load(handle)

    table = data
    for key in table_path:
        if not isinstance(table, dict) or key not in table:
            return None
        table = table[key]

    if not isinstance(table, dict) or "trusted_source_ranges" not in table:
        return None
    ranges = table["trusted_source_ranges"]
    if not isinstance(ranges, list) or not all(isinstance(item, str) for item in ranges):
        raise ValueError(f"{path}: trusted_source_ranges must be an array of strings")

    parsed = []
    for item in ranges:
        try:
            network = ipaddress.ip_network(item, strict=False)
        except ValueError:
            warning(f"{path}: invalid trusted_source_ranges CIDR: {item}")
            network = None
        parsed.append((item, network))
    return parsed


def warning(message: str) -> None:
    print(f"[pre-deploy][warning] {message}", file=sys.stderr)


try:
    global_ranges = read_ranges(Path(sys.argv[1]), ("traefik", "variables"))
    local_ranges = read_ranges(Path(sys.argv[2]), ("variables", "traefik"))
except (KeyError, OSError, TypeError, tomllib.TOMLDecodeError, ValueError) as error:
    warning(f"unable to validate traefik.trusted_source_ranges: {error}")
    raise SystemExit(0)

if global_ranges is None:
    warning("global traefik.trusted_source_ranges is not defined")
    raise SystemExit(0)
if local_ranges is None:
    raise SystemExit(0)

global_networks = [network for _, network in global_ranges if network is not None]
local_networks = [network for _, network in local_ranges if network is not None]
overlap = any(
    local_network.overlaps(global_network)
    for local_network in local_networks
    for global_network in global_networks
)
local_only = any(
    not any(local_network.overlaps(global_network) for global_network in global_networks)
    for local_network in local_networks
)

if not overlap:
    warning("local trusted_source_ranges has no range shared with global defaults")
if not local_only:
    warning("local trusted_source_ranges adds no local-only range")
PY
}

echo "[pre-deploy] Checking secrets..."
mkdir -p "$HOME/.cache/dotter"
: >"$HOME/.cache/dotter/render.log"

echo "[pre-deploy] Checking shared trusted network policy..."
check_trusted_source_ranges || warn "trusted network policy check failed; continuing deployment"

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
