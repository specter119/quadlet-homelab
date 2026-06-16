#!/usr/bin/env bash
set -euo pipefail

declare -A seen=()
emitted=0
resolv_conf=${PODMAN_NETWORK_DNS_RESOLV_CONF:-/etc/resolv.conf}

is_usable_dns() {
    local ip=${1%%%*}

    [[ -n "$ip" ]] || return 1
    [[ "$ip" != 127.* ]] || return 1
    [[ "$ip" != 0.* ]] || return 1
    [[ "$ip" != 169.254.* ]] || return 1
    [[ "$ip" != 28.* ]] || return 1
    [[ "$ip" != 198.18.* ]] || return 1
    [[ "$ip" != 198.19.* ]] || return 1
    [[ "$ip" != "::1" ]] || return 1
    [[ "$ip" != fe80:* ]] || return 1

    return 0
}

emit_dns() {
    local ip=${1%%%*}

    [[ "$emitted" -eq 0 ]] || return 0
    is_usable_dns "$ip" || return 0
    [[ -z "${seen[$ip]+x}" ]] || return 0

    seen["$ip"]=1
    emitted=1
    printf 'DNS=%s\n' "$ip"
}

default_route_links() {
    command -v ip >/dev/null 2>&1 || return 0

    ip -o -4 route show default 2>/dev/null \
        | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); break}}' \
        | awk '!seen[$0]++'
}

emit_resolvectl_dns_for_link() {
    local link=$1 line servers server

    command -v resolvectl >/dev/null 2>&1 || return 0

    while IFS= read -r line; do
        servers=${line#*:}
        [[ "$servers" != "$line" ]] || continue
        for server in $servers; do
            emit_dns "$server"
            [[ "$emitted" -eq 0 ]] || return 0
        done
    done < <(resolvectl dns "$link" 2>/dev/null || true)
}

emit_nmcli_dns_for_link() {
    local link=$1 server

    command -v nmcli >/dev/null 2>&1 || return 0

    while IFS= read -r server; do
        emit_dns "$server"
        [[ "$emitted" -eq 0 ]] || return 0
    done < <(
        nmcli -g IP4.DNS device show "$link" 2>/dev/null || true
        nmcli -g IP6.DNS device show "$link" 2>/dev/null || true
    )
}

emit_dns_for_default_route() {
    local link

    while IFS= read -r link; do
        [[ -n "$link" ]] || continue

        emit_resolvectl_dns_for_link "$link"
        [[ "$emitted" -eq 0 ]] || return 0

        emit_nmcli_dns_for_link "$link"
        [[ "$emitted" -eq 0 ]] || return 0
    done < <(default_route_links)
}

emit_resolv_conf_dns() {
    local keyword server rest

    [[ -r "$resolv_conf" ]] || return 0

    while read -r keyword server rest; do
        [[ "$keyword" == "nameserver" ]] || continue
        emit_dns "$server"
        [[ "$emitted" -eq 0 ]] || return 0
    done < "$resolv_conf"
}

emit_dns_for_default_route
[[ "$emitted" -ne 0 ]] || emit_resolv_conf_dns
