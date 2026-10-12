#!/usr/bin/bash

set -euo pipefail

host="${NMEM_CERT_HOST:-}"
port="${NMEM_CERT_PORT:-443}"
nmem_bin="${NMEM_BIN_PATH:-$HOME/.local/bin/nmem}"

if [[ -z "$host" ]]; then
    echo "[nowledge-mem-certifi] skip: NMEM_CERT_HOST is empty" >&2
    exit 0
fi

if [[ ! -x "$nmem_bin" ]]; then
    echo "[nowledge-mem-certifi] skip: nmem launcher not found at $nmem_bin" >&2
    exit 0
fi

launcher="$(readlink -f "$nmem_bin")"
shebang="$(head -n1 "$launcher" || true)"

# nmem 0.10.100+ 是原生 Rust ELF 二进制（uv tool 打包），无 shebang、不依赖 python certifi；
# 信任链交给系统 CA 库（sudo cp rootCA /usr/local/share/ca-certificates && update-ca-certificates），
# 不再注入 SSL_CERT_FILE 环境变量 —— 那会污染所有 Rust/Go CLI 的证书验证。
# 老版 python launcher 走下方 certifi 逻辑。
if [[ "$shebang" != '#!'* ]]; then
    if grep -q 'mkcert development CA' /etc/ssl/certs/ca-certificates.crt 2>/dev/null; then
        echo "[nowledge-mem-certifi] mkcert root CA already in system trust store"
        exit 0
    fi

    # 找候选 rootCA 路径，给出安装指引（无法自动 sudo）
    rootca=""
    for cand in "$HOME/.local/share/mkcert/rootCA.pem" "$HOME/.local/share/ca-certificates/mkcert-rootCA.pem" /mnt/c/Users/*/AppData/Local/mkcert/rootCA.pem; do
        if [[ -f "$cand" ]]; then
            rootca="$(readlink -f "$cand")"
            break
        fi
    done

    if [[ -z "$rootca" ]]; then
        echo "[nowledge-mem-certifi] mkcert root CA not found; run mkcert -install and re-run this unit" >&2
        exit 0
    fi

    echo "[nowledge-mem-certifi] mkcert root CA missing from system trust store; install it with:" >&2
    echo "  sudo cp '$rootca' /usr/local/share/ca-certificates/mkcert-rootCA.crt && sudo update-ca-certificates" >&2
    echo "[nowledge-mem-certifi] then verify with: nmem status" >&2
    exit 0
fi

if [[ "$shebang" != '#!'* ]]; then
    echo "[nowledge-mem-certifi] skip: unsupported nmem launcher format" >&2
    exit 0
fi

tool_python="${shebang#\#!}"

if [[ ! -x "$tool_python" ]]; then
    echo "[nowledge-mem-certifi] skip: tool python not executable at $tool_python" >&2
    exit 0
fi

certifi_bundle="$("$tool_python" - <<'PY'
import certifi
print(certifi.where())
PY
)"

if [[ ! -f "$certifi_bundle" ]]; then
    echo "[nowledge-mem-certifi] skip: certifi bundle missing at $certifi_bundle" >&2
    exit 0
fi

tmp_chain="$(mktemp)"
trap 'rm -f "$tmp_chain"' EXIT

openssl s_client -showcerts \
    -connect "${host}:${port}" \
    -servername "$host" \
    </dev/null >"$tmp_chain" 2>/dev/null

python3 - "$tmp_chain" "$certifi_bundle" <<'PY'
from __future__ import annotations

import hashlib
import re
import ssl
import sys
from pathlib import Path

chain_path = Path(sys.argv[1])
bundle_path = Path(sys.argv[2])

pattern = r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----"

chain_text = chain_path.read_text(encoding="utf-8")
bundle_text = bundle_path.read_text(encoding="utf-8")

source_certs = re.findall(pattern, chain_text, re.S)
bundle_certs = re.findall(pattern, bundle_text, re.S)

if not source_certs:
    print("[nowledge-mem-certifi] skip: no certificates found from TLS endpoint", file=sys.stderr)
    sys.exit(0)

def digest(pem: str) -> str:
    der = ssl.PEM_cert_to_DER_cert(pem)
    return hashlib.sha256(der).hexdigest()

known = {digest(pem) for pem in bundle_certs}
missing: list[str] = []

for pem in source_certs:
    normalized = pem.strip() + "\n"
    if digest(normalized) not in known:
        missing.append(normalized)
        known.add(digest(normalized))

if not missing:
    print("[nowledge-mem-certifi] certifi bundle already contains the current Nowledge Mem certificate chain")
    sys.exit(0)

with bundle_path.open("a", encoding="utf-8") as fh:
    fh.write("\n")
    for pem in missing:
        fh.write(pem)
        fh.write("\n")

print(f"[nowledge-mem-certifi] appended {len(missing)} certificate(s) to {bundle_path}")
PY
