#!/usr/bin/bash
#
# sync-key.sh — 从 nowledge-mem.service 的 journal 中提取最新的远程访问 API key，
# 原子地刷新 ~/.config/environment.d/nowledge.conf，并把变量导入当前 systemd user 会话。
#
# 设计为在每次 nowledge-mem.service 启动后由 nowledge-mem-sync-key.service 触发，
# 必须幂等、安全、可在没有任何 key 时静默退出（不阻断服务启动）。

set -euo pipefail

tag="[nowledge-mem-sync-key]"
_env_dir="$HOME/.config/environment.d"
_env_file="$_env_dir/nowledge.conf"
_api_url="https://nowledge-mem.worklab.com"
_log_unit="nowledge-mem.service"

# 服务刚启动时 key 可能还没被刷进 journal，最多重试 3 次，每次间隔 1 秒。
key=""
for attempt in 1 2 3; do
    raw="$(journalctl --user -u "$_log_unit" --no-pager -n 100 \
        | grep -oE '(remote_access_api_key=|API Key  )nmem_[A-Za-z0-9_]+' \
        | tail -1 \
        | sed -E 's/.*(nmem_.*)/\1/' || true)"
    if [[ -n "$raw" ]]; then
        key="$raw"
        break
    fi
    [[ "$attempt" -lt 3 ]] && sleep 1
done

if [[ -z "$key" ]]; then
    echo "$tag no API key found in journal yet; nothing to do" >&2
    exit 0
fi

# 读出当前 env 文件里的 key（如果文件不存在则视为空）。
current_key=""
if [[ -f "$_env_file" ]]; then
    current_key="$(sed -n 's/^NMEM_API_KEY=//p' "$_env_file" 2>/dev/null || true)"
fi

if [[ "$key" == "$current_key" ]]; then
    echo "$tag API key unchanged; no-op" >&2
    exit 0
fi

# 原子写入：temp 文件放在同目录，确保 mv 是同一文件系统上的 rename。
mkdir -p "$_env_dir"
tmp="$(mktemp "$_env_dir/nowledge.conf.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
{
    printf 'NMEM_API_URL=%s\n' "$_api_url"
    printf 'NMEM_API_KEY=%s\n' "$key"
} > "$tmp"
chmod 644 "$tmp"
mv "$tmp" "$_env_file"
trap - EXIT

echo "$tag refreshed $_env_file with new API key" >&2

# `systemctl --user import-environment VARNAME` reads VARNAME from the
# *calling process* environment (not from any env file), so we must export
# the values here before importing them into the running user manager.
export NMEM_API_KEY="$key"
export NMEM_API_URL="$_api_url"
systemctl --user import-environment NMEM_API_KEY NMEM_API_URL
