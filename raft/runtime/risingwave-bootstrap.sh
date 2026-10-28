#!/bin/sh
# 把镜像内 /sql 的 bootstrap SQL 应用到本机 RisingWave，且可重复执行。
#
# SQL 在构建期由上游 emitter 生成（见 raft-rw-bootstrap.Containerfile），顺序固定为：
#   cdc.sql       CREATE SOURCE（psql 参数化）+ CDC 表  ← 要求 PG 侧表已迁移完成
#   manifest.sql  物化视图 + 索引
# 上游 infra/risingwave/sql/README.md 明确这些 SQL 不是 PG 迁移、也不能按字母序全跑。
# 语句本身没有 IF NOT EXISTS，而 RisingWave 的状态是持久化的，所以重启后必须先判断
# 当前状态，而不是盲目重放。三种状态：
#   source 不存在                    首次 bootstrap：应用 SQL 并校验
#   source 存在且必需 relation 齐全  已就绪：直接 exit 0
#   source 存在但缺 relation         半途失败或视图代际变化：exit 3，需人工重建
#                                    （流程见 docs/raft.md；容器单元对 3 设了
#                                    RestartPreventExitStatus，避免无限重试）
#
# 参数经 psql -v 传入；PG 密码走 psql \getenv（读环境变量），不进入 argv。
set -eu

RW_HOST="${RW_HOST:?RW_HOST 必填}"
RW_PORT="${RW_PORT:-4566}"
RW_USER="${RW_USER:-root}"
RW_DB="${RW_DB:-dev}"
RW_SOURCE_NAME="${RW_SOURCE_NAME:?RW_SOURCE_NAME 必填}"
SQL_DIR="${SQL_DIR:-/sql}"

rw_psql() {
  psql --no-psqlrc --quiet -w -v ON_ERROR_STOP=1 \
    -h "$RW_HOST" -p "$RW_PORT" -U "$RW_USER" -d "$RW_DB" "$@"
}

for artifact in cdc.sql manifest.sql required_relations.txt; do
  [ -s "$SQL_DIR/$artifact" ] || {
    echo "[rw-bootstrap] 镜像内缺少 $SQL_DIR/$artifact；重建 raft-rw-bootstrap 镜像（raft-prepare.service）" >&2
    exit 1
  }
done

# 输出缺失的 relation（每行一个）。LIMIT 0 让「关系不存在」报错，且不读数据。
missing_relations() {
  while IFS= read -r relation; do
    [ -n "$relation" ] || continue
    rw_psql -c "SELECT 1 FROM $relation LIMIT 0" >/dev/null 2>&1 || echo "$relation"
  done <"$SQL_DIR/required_relations.txt"
}

source_count="$(printf "SELECT count(*) FROM rw_catalog.rw_sources WHERE name = :'rw_source_name';\n" \
  | rw_psql -At -v rw_source_name="$RW_SOURCE_NAME")"

if [ "$source_count" != "0" ]; then
  missing="$(missing_relations)"
  if [ -z "$missing" ]; then
    echo "[rw-bootstrap] 已就绪（source $RW_SOURCE_NAME 与全部必需 relation 都存在），跳过"
    exit 0
  fi
  echo "[rw-bootstrap] source $RW_SOURCE_NAME 已存在，但缺少以下 relation：" >&2
  echo "$missing" | sed 's/^/[rw-bootstrap]   /' >&2
  echo "[rw-bootstrap] 需要按 docs/raft.md 的「失槽后的重建流程」清理后重跑；不自动重放，避免半套状态" >&2
  exit 3
fi

# psql 16+ 的 \getenv：把 secret 环境变量注入 psql 变量，避免出现在命令行参数里
printf '\\getenv pg_password CDC_PG_PASSWORD\n' >/tmp/params.sql

echo "[rw-bootstrap] 应用 cdc.sql（CREATE SOURCE + CDC 表）"
rw_psql -f /tmp/params.sql \
  -v rw_source_name="$RW_SOURCE_NAME" \
  -v pg_host="$CDC_PG_HOST" \
  -v pg_port="$CDC_PG_PORT" \
  -v pg_user="$CDC_PG_USER" \
  -v pg_database="$CDC_PG_DATABASE" \
  -v pg_ssl_mode="$CDC_PG_SSL_MODE" \
  -v pg_slot_name="$CDC_SLOT_NAME" \
  -v pg_publication_name="$CDC_PUBLICATION_NAME" \
  -f "$SQL_DIR/cdc.sql"

echo "[rw-bootstrap] 应用 manifest.sql（物化视图 + 索引）"
rw_psql -v rw_source_name="$RW_SOURCE_NAME" -f "$SQL_DIR/manifest.sql"

echo "[rw-bootstrap] 校验必需 relation 都已存在"
missing="$(missing_relations)"
if [ -n "$missing" ]; then
  echo "[rw-bootstrap] 应用后仍缺少：" >&2
  echo "$missing" | sed 's/^/[rw-bootstrap]   /' >&2
  exit 1
fi

echo "[rw-bootstrap] 完成"
