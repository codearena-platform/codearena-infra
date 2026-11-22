# Backup and restore runbook

## What is backed up

The `datastore-backup` CronJob runs daily at 02:00 UTC and produces three sets
of files on the `datastore-backups` PVC. Each container writes a completion
marker; the uploader only starts after all three succeed, so an off-cluster copy
is always a complete set.

| Set | Format | Source |
| --- | --- | --- |
| `postgresql/` | `*.dump.gz` (pg_dump custom format) | `competition` database |
| `mongodb/` | `*.archive.gz` (mongodump archive) | all MongoDB databases, including `iam` |
| `sqlite/` | `*.db` (SQLite online `.backup`) | `/data/codearena.db` on the `core-data` PVC |

The SQLite snapshot uses `sqlite3 .backup` inside the running Core pod, so it is
a consistent copy even while Core serves traffic. It requires the `sqlite`
Alpine package in the Core image (codearena-core PR #13). A snapshot is written
beside the live database first, so the `core-data` PVC needs free space of at
least the size of the database. The snapshot is deleted from the pod after it is
streamed to the backup volume.

Local retention is 7 days (`find -mtime +7 -delete`). If `codearena-backup-s3`
is configured, the same files are copied to `s3://<bucket>/<prefix>/{postgresql,mongodb,sqlite}/`
with the AWS CLI. Object-storage lifecycle rules should enforce the same or a
longer retention; the Job does not delete remote objects.

- **RPO:** up to 24 hours (daily 02:00 UTC backups).
- **RTO:** target 1 hour, dominated by restoring the two datastore dumps and
  validating the platform.
- **Restore drill:** perform at least monthly and record the result.

## Configuring the off-cluster target

Either set the `backup_s3` Terraform variable (sensitive; sensitive values are
stored in the encrypted state backend):

In a gitignored `terraform.tfvars`:

```hcl
backup_s3 = {
  endpoint   = "https://s3.example.com" # S3-compatible endpoint, or "" for AWS
  bucket     = "codearena-backups"
  region     = "us-east-1"
  prefix     = "prod"
  access_key = "..."
  secret_key = "..."
}
```

or as an environment variable for a single run:

```bash
export TF_VAR_backup_s3='{"endpoint":"","bucket":"codearena-backups","region":"us-east-1","prefix":"prod","access_key":"...","secret_key":"..."}'
```

or create the Secret out of band:

```bash
kubectl -n codearena create secret generic codearena-backup-s3 \
  --from-literal=endpoint=https://s3.example.com \
  --from-literal=bucket=codearena-backups \
  --from-literal=region=us-east-1 \
  --from-literal=prefix=prod \
  --from-literal=access_key=... \
  --from-literal=secret_key=...
```

All keys are optional except `bucket`. When the Secret is absent, the uploader
logs that no target is configured and exits successfully after the local dumps
finish. Grant the backup identity write/list access to the prefix only.

## Verify a backup

```bash
kubectl -n codearena create job --from=cronjob/datastore-backup verify-backup
kubectl -n codearena logs -f job/verify-backup -c postgres-backup
kubectl -n codearena logs -f job/verify-backup -c mongodb-backup
kubectl -n codearena logs -f job/verify-backup -c sqlite-backup
kubectl -n codearena logs -f job/verify-backup -c offcluster-copy
```

Check that the three marker lines and `Off-cluster backup upload complete`
appear. List the destination with `aws s3 ls s3://<bucket>/<prefix>/ --recursive`.

## Restore

Always stop writers before restoring. Keep the namespace name consistent with
`NAMESPACE` below.

### 1. Stop writers

```bash
NAMESPACE=codearena
kubectl -n "$NAMESPACE" scale deploy/gateway deploy/competition --replicas=0
kubectl -n "$NAMESPACE" scale deploy/simulation --replicas=0
kubectl -n "$NAMESPACE" rollout status deploy/simulation --timeout=5m
```

### 2. Restore PostgreSQL

```bash
POD=$(kubectl -n "$NAMESPACE" get pods -l app.kubernetes.io/name=postgresql \
  -o jsonpath='{.items[0].metadata.name}')
kubectl -n "$NAMESPACE" exec -i "$POD" -- sh -c \
  'gunzip | pg_restore --clean --if-exists --no-owner --no-acl -U postgres -d competition' \
  < postgresql/competition-<timestamp>.dump.gz
```

### 3. Restore MongoDB

```bash
POD=$(kubectl -n "$NAMESPACE" get pods -l app.kubernetes.io/name=mongodb \
  -o jsonpath='{.items[0].metadata.name}')
kubectl -n "$NAMESPACE" exec -i "$POD" -- sh -c \
  'mongorestore --drop --archive --gzip' \
  < mongodb/admin-<timestamp>.archive.gz
```

Restoring MongoDB also restores the `iam` database and the infrastructure
migration tracking collection.

### 4. Restore the Core SQLite PVC

Mount `core-data` in a temporary helper pod while `simulation` is scaled to
zero, copy the snapshot in, then remove the helper:

```bash
kubectl -n "$NAMESPACE" apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: sqlite-restore
  namespace: codearena
spec:
  restartPolicy: Never
  containers:
    - name: restore
      image: alpine:3.20
      command: ["sh", "-c", "sleep 3600"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: core-data
EOF
kubectl -n "$NAMESPACE" wait --for=condition=Ready pod/sqlite-restore
kubectl -n "$NAMESPACE" cp sqlite/codearena-<timestamp>.db \
  "$NAMESPACE/sqlite-restore:/data/codearena.db"
kubectl -n "$NAMESPACE" delete pod/sqlite-restore
```

Verify the restored file with `sqlite3 /data/codearena.db 'PRAGMA integrity_check;'`
from a pod that mounts the PVC (or after scaling `simulation` back up and
executing into it). Then restart the workloads:

```bash
kubectl -n "$NAMESPACE" scale deploy/simulation --replicas=1
kubectl -n "$NAMESPACE" scale deploy/gateway deploy/competition --replicas=1
```

### 5. Validate

Check `/health` through the Ingress, the migration tracker tables, and a single
end-to-end bot match. Only then re-enable normal traffic.
