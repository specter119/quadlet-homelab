#!/bin/sh
# 在 Silo 中创建栈专属 bucket 与只覆盖该 bucket 的用户。需要环境变量 S3_BUCKET。
# 幂等：重复执行安全（policy attach 已生效时 mcli 可能报错，下面显式兜底）。
set -eu

POLICY="${S3_BUCKET}-rw"

mcli alias set local http://silo:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null
mcli mb --ignore-existing "local/$S3_BUCKET"

cat >/tmp/policy.json <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetBucketLocation", "s3:ListBucket", "s3:ListBucketMultipartUploads"],
      "Resource": ["arn:aws:s3:::$S3_BUCKET"]
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
      "Resource": ["arn:aws:s3:::$S3_BUCKET/*"]
    }
  ]
}
JSON

mcli admin user add local "$S3_ACCESS_KEY" "$S3_SECRET_KEY"
mcli admin policy create local "$POLICY" /tmp/policy.json
mcli admin policy attach local "$POLICY" --user "$S3_ACCESS_KEY" \
  || mcli admin user info local "$S3_ACCESS_KEY" | grep -qw "$POLICY"

echo "silo: bucket $S3_BUCKET 已就绪"
