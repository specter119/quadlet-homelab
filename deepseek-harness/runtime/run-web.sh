#!/bin/sh
set -eu

# dsh rejects wildcard bind addresses and wants one concrete local interface
# address; the container IP is assigned by the network at start, so resolve it here.
bind_host="$(node -p "Object.values(require('os').networkInterfaces()).flat().find((i) => i.family === 'IPv4' && !i.internal).address")"

exec node /opt/dsh/node_modules/@deepseek-ai/dsh/lib/bin.js \
  web \
  --no-open \
  --host "$bind_host" \
  --port 3080 \
  --trusted-host "${DSH_TRUSTED_HOST:?DSH_TRUSTED_HOST must be set}"
