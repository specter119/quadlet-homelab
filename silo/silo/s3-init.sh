#!/bin/sh
# 在 Silo 中创建栈专属 bucket 与只覆盖这些 bucket 的用户。
#
# 需要 S3_BUCKET（单 bucket，既有栈）或 S3_BUCKETS（空格分隔多 bucket）之一；
# 两者都给时取并集。幂等：重复执行安全（policy attach 已生效时 mcli 可能报错，下面显式兜底）。
set -eu

BUCKETS="${S3_BUCKET:-}"
if [ -n "${S3_BUCKETS:-}" ]; then
  BUCKETS="${BUCKETS:+$BUCKETS }$S3_BUCKETS"
fi
if [ -z "$(echo "$BUCKETS" | tr -d ' ')" ]; then
  echo "需要 S3_BUCKET 或 S3_BUCKETS" >&2
  exit 1
fi

mcli alias set local http://silo:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null

mcli admin user add local "$S3_ACCESS_KEY" "$S3_SECRET_KEY"

for bucket in $BUCKETS; do
  policy="${bucket}-rw"

  mcli mb --ignore-existing "local/$bucket"

  cat >/tmp/policy.json <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetBucketLocation", "s3:ListBucket", "s3:ListBucketMultipartUploads"],
      "Resource": ["arn:aws:s3:::$bucket"]
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts"
      ],
      "Resource": ["arn:aws:s3:::$bucket/*"]
    }
  ]
}
JSON

  mcli admin policy create local "$policy" /tmp/policy.json
  mcli admin policy attach local "$policy" --user "$S3_ACCESS_KEY" \
    || mcli admin user info local "$S3_ACCESS_KEY" | grep -qw "$policy"
done

echo "silo: bucket(s) [$BUCKETS] 已就绪"