# raft-rw-bootstrap：RisingWave bootstrap 的自包含镜像（SQL + 应用脚本 + psql）。
#
# 上游 packages/server/Dockerfile 只 COPY packages/* 与 manual/，**不含 infra/ 和
# 根 scripts/**，所以 bootstrap SQL 的生成器不在 server 镜像里。这里分两阶段：
#   emit   在 raft-server 镜像上补 infra/ + emitter，**构建期**生成 SQL 并注入 heartbeat
#   final  只带 psql 与产物，不带 node 和上游源码
# SQL 因此与镜像同生命周期：不存在「镜像已升级而宿主机 SQL 还是旧版」，宿主机上也
# 没有需要单独维护的 SQL 目录。
#
# 额外构建上下文 `homelab` 指向本文件所在目录（见 prepare-images.sh 的 --build-context）。

FROM localhost/raft-server:latest AS emit
WORKDIR /app
COPY infra/risingwave/sql/ infra/risingwave/sql/
COPY scripts/dev/raftdev-risingwave-bootstrap.ts scripts/dev/
COPY scripts/dev/emit-risingwave-bootstrap.ts scripts/dev/
COPY --from=homelab prepare-bootstrap-sql.mjs /tmp/prepare-bootstrap-sql.mjs
RUN mkdir /out \
 && node --import @oxc-node/core/register scripts/dev/emit-risingwave-bootstrap.ts \
      --source-root /app \
      --cdc-out /out/cdc.sql \
      --manifest-out /out/manifest.sql \
      --contract-out /out/contract.json \
 && node /tmp/prepare-bootstrap-sql.mjs /out

# 与 raft-initdb 同一个 postgres 主版本，psql 16+ 才有 \getenv（见 risingwave-bootstrap.sh）
FROM docker.io/library/postgres:17-alpine
COPY --from=emit /out/cdc.sql /out/manifest.sql /out/required_relations.txt /sql/
COPY --from=homelab risingwave-bootstrap.sh /bootstrap.sh
ENTRYPOINT ["/bin/sh", "/bootstrap.sh"]
