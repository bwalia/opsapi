#!/bin/bash
set -x
if [ -z "$BACKUP_FREQUENCY" ]; then
echo "BACKUP_FREQUENCY set to hourly."
BACKUP_FREQUENCY="hourly"
fi
TIMESTAMP=$(date +'%Y-%m-%d_%H-%M-%S')
BACKUP_FILE="backup_$TIMESTAMP.sql.gz"

pg_dump -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -F c | gzip > "/tmp/$BACKUP_FILE"

# Install MinIO Client
curl -O https://dl.min.io/client/mc/release/linux-amd64/mc
chmod +x mc && mv mc /usr/local/bin/

# Configure MinIO and upload backup
mc alias set myminio "$MINIO_ENDPOINT" "$MINIO_ACCESS_KEY" "$MINIO_SECRET_KEY"
mc cp "/tmp/$BACKUP_FILE" myminio/"$MINIO_BUCKET"/"$BACKUP_FILE"

# Cleanup
rm -f "/tmp/$BACKUP_FILE"