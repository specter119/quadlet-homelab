#!/bin/bash
set -e

SOURCE_DIR="{{dotter.current_dir}}"
SECRETS_DIR="$SOURCE_DIR/.dotter/secrets"
LOCAL_TOML="$SOURCE_DIR/.dotter/local.toml"
VERBOSE=false
CREATED=0
TOTAL=0

[[ "$1" == "-v" || "$1" == "--verbose" ]] && VERBOSE=true

log() { $VERBOSE && echo "$@" || true; }

echo "[pre-deploy] Checking secrets..."

# Parse enabled packages from local.toml
# Format: packages = ['traefik', 'silverbullet', 'dozzle', 'omnivore']
ENABLED_PACKAGES=$(grep -E "^packages\s*=" "$LOCAL_TOML" | \
    sed "s/.*\[//;s/\].*//;s/'//g;s/\"//g;s/,/ /g;s/  */ /g")
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
    echo -n "$value" | podman secret create "$name" - >/dev/null
    EXISTING_SECRETS["$name"]=1
    ((CREATED++))
    log "  $name: created"
}

get_secret() {
    podman secret inspect "$1" --format '\{{.SecretData}}' 2>/dev/null | base64 -d
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
            hex)   value=$(generate_hex "$param") ;;
            fixed) value="$param" ;;
        esac

        create_secret "$name" "$value" && SECRETS["$name"]="$value" || SECRETS["$name"]=$(get_secret "$name")
    done < "$conf"

    while IFS=: read -r name type param; do
        [[ "$type" != "computed" ]] && continue
        local value="$param"
        for key in "${!SECRETS[@]}"; do
            value="${value//\$\{$key\}/${SECRETS[$key]}}"
        done
        create_secret "$name" "$value" || true
    done < "$conf"
}

# Only process secrets for enabled packages
for pkg in $ENABLED_PACKAGES; do
    process_conf "$SECRETS_DIR/$pkg.conf"
done

echo "Secrets: $TOTAL valid ($CREATED newly created)"
