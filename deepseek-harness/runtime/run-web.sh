#!/bin/sh
set -eu

exec node /opt/dsh/node_modules/@deepseek-ai/dsh/lib/bin.js \
  web \
  --patch /opt/dsh/quadlet-web.patch.yml \
  --trusted-host "${DSH_TRUSTED_HOST:?DSH_TRUSTED_HOST must be set}"
