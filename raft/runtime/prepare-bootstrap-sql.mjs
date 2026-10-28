// 在 emit 阶段对 emitter 的输出做后处理：
//   1. 给 CREATE SOURCE 注入 debezium heartbeat
//   2. 把 contract.json 的 required_relations 展开成逐行清单，供 bootstrap 脚本判断是否已就绪
import { readFileSync, writeFileSync } from "node:fs";
import path from "node:path";

const dir = process.argv[2];
if (!dir) throw new Error("usage: prepare-bootstrap-sql.mjs <dir>");

// RisingWave 在写入稀疏时槽 offset 不推进，WAL 会持续滞留（上游 issue #16697 记录单个
// 槽涨到 19GB）。我们设了 max_slot_wal_keep_size=256MB，滞留超预算 slot 就被 PG 作废、
// 必须全量重建视图，所以 heartbeat 是必须的，不是优化。
const cdcPath = path.join(dir, "cdc.sql");
const anchor = "  publication.name = :'pg_publication_name'\n";
const text = readFileSync(cdcPath, "utf8");
if (text.split(anchor).length !== 2) {
  throw new Error("cdc.sql 里找不到唯一的 publication.name 行，无法注入 heartbeat；上游 emitter 的输出结构已变");
}
const heartbeat =
  ",\n" +
  "  debezium.heartbeat.interval.ms = '30000',\n" +
  "  debezium.heartbeat.action.query = 'SELECT pg_logical_emit_message(true, ''raft_cdc_heartbeat'', '''')'";
writeFileSync(cdcPath, text.replace(anchor, anchor.trimEnd() + heartbeat + "\n"));
console.log("[raft-prepare] 已向 CREATE SOURCE 注入 debezium heartbeat");

const contract = JSON.parse(readFileSync(path.join(dir, "contract.json"), "utf8"));
const relations = contract.required_relations;
if (!Array.isArray(relations) || relations.length === 0) {
  throw new Error("contract.json 的 required_relations 为空或缺失");
}
writeFileSync(path.join(dir, "required_relations.txt"), relations.join("\n") + "\n");
console.log(`[raft-prepare] required_relations: ${relations.length}`);
