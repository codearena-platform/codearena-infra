# Production rollout plan

This document turns the remaining operational issues into an ordered, verifiable
rollout. It does **not** apply anything by itself. Every gate must pass before
the next one starts.

| Gate | Issue | Outcome |
| --- | --- | --- |
| 1 | #20 | Terraform state is remote, encrypted and locked. |
| 2 | — | Namespace, datastores, secrets, Ingress and applications are running. |
| 3 | #21 | Backups exist on the PVC and off-cluster. |
| 4 | #22 | Alerts reach humans and dashboards/logs are usable. |
| 5 | #23 | A real restore drill passed and the runbook is corrected. |

Related decision: `.github#2` records whether GitHub Actions may create PRs.
The current manual digest promotion works either way.

## Gate 0 — Prerequisites

Confirm before touching the cluster:

- `kubectl config current-context` points at the production cluster.
- The cluster has a CNI that enforces `NetworkPolicy`; otherwise the policies in
  `k8s/` are inert.
- The chosen `StorageClass` exists and supports dynamic provisioning.
- An ingress controller is installed. The default configuration expects
  `ingress-nginx`; if yours differs, change `ingress_class_name` and the
  `namespaceSelector` in `k8s/networkpolicies.yaml`.
- DNS for `ingress_host` resolves to the ingress controller.
- A TLS Secret for `ingress_host` already exists in the namespace.
- The four image digests in `k8s/images.env` are non-zero (checked by
  `make production-check`).

If any item fails, stop. Do not "fix it during apply".

## Gate 1 — Encrypted Terraform backend (#20)

1. Create the cloud resources outside this repository: a versioned private S3
   bucket, a KMS key allowing the Terraform principal to encrypt/decrypt, and a
   DynamoDB table with a `LockID` partition key.
2. Copy the templates and fill in real values:

   ```bash
   cd codearena-infra
   cp terraform/backend.tf.example terraform/backend.tf
   cp terraform/backend.hcl.example terraform/backend.hcl
   # edit backend.hcl: bucket, key, region, kms_key_id, dynamodb_table
   cd terraform
   terraform init -backend-config=backend.hcl -migrate-state
   ```

3. Verify `terraform state pull` works and that no bucket name, key ARN or
   credential was committed. `terraform/backend.tf`,
   `terraform/backend.hcl` and `*.tfvars` are gitignored.

**Exit criterion:** state is remote and encrypted, and a second operator can
acquire the DynamoDB lock.

## Gate 2 — Platform rollout

1. Copy `terraform/production.tfvars.example` to
   `terraform/production.tfvars` and replace every `REPLACE_WITH_*` value.
2. Review the plan carefully; it creates the namespace, Helm releases, the
   application Secret and the Ingress:

   ```bash
   make tf-fmt-check tf-validate
   make tf-plan
   ```

3. Apply infrastructure, then applications:

   ```bash
   make tf-apply
   make k8s-apply
   make k8s-migrate
   ```

4. Smoke test:

   ```bash
   kubectl -n codearena rollout status deploy/gateway deploy/iam deploy/competition deploy/simulation
   curl -fsS https://<ingress_host>/health
   kubectl -n codearena get jobs,pvc,ingress
   ```

**Exit criterion:** all deployments are ready, migrations completed, and
`/health` answers through TLS.

## Gate 3 — Off-cluster backups (#21)

1. Fill `backup_s3` in `terraform/production.tfvars` (or create the
   `codearena-backup-s3` Secret out of band). Use `endpoint = ""` for AWS S3.
2. Re-run `make tf-apply` so the Secret is created, then trigger a backup:

   ```bash
   kubectl -n codearena create job --from=cronjob/datastore-backup verify-backup
   kubectl -n codearena logs -f job/verify-backup -c postgres-backup
   kubectl -n codearena logs -f job/verify-backup -c mongodb-backup
   kubectl -n codearena logs -f job/verify-backup -c sqlite-backup
   kubectl -n codearena logs -f job/verify-backup -c offcluster-copy
   ```

3. Confirm the three completion markers and `Off-cluster backup upload
   complete`, then list remote objects:

   ```bash
   aws s3 ls s3://<bucket>/<prefix>/ --recursive
   ```

**Exit criterion:** a complete new dump set exists both on the PVC and in the
bucket. Redis is intentionally excluded: it holds rebuildable cache/session
data.

## Gate 4 — Observability and alert routing (#22)

1. Set `alert_slack_webhook_url` and `alert_pagerduty_routing_key` in the
   gitignored tfvars, then `make tf-apply`.
2. Open the provisioned `CodeArena Operational Overview` Grafana dashboard.
   Confirm workload panels, datastore panels and the Loki log panel show data.
3. Query logs by namespace and pod to prove collection works:

   ```logql
   {namespace="codearena", pod=~"gateway-.*"} |= ""
   ```

4. Fire a test alert through Alertmanager and confirm delivery to the Slack
   channel and PagerDuty service. Update `docs/oncall-runbook.md` with the real
   rotation and escalation path.

**Exit criterion:** an on-call engineer receives a test alert and can navigate
from it to the dashboard and logs.

## Gate 5 — Restore drill (#23)

Follow `docs/backup-runbook.md` in an isolated namespace or maintenance window:

1. Stop writers.
2. Restore PostgreSQL, MongoDB and the Core SQLite PVC from the same dump set.
3. Run `PRAGMA integrity_check;` on the restored SQLite database.
4. Check migration tracker rows in both datastores.
5. Verify `/health` through the Ingress and run one end-to-end bot match.
6. Record elapsed time and compare with RPO 24h / RTO target 1h. Fix any
   runbook drift discovered during the drill.

**Exit criterion:** a complete restore succeeded and the runbook reflects the
commands that actually worked.

## Go / No-go checklist

- [ ] Gate 1 passed: remote encrypted state.
- [ ] Gate 2 passed: deployments ready and `/health` green.
- [ ] Gate 3 passed: complete dump set off-cluster.
- [ ] Gate 4 passed: alerts delivered and logs queryable.
- [ ] Gate 5 passed: restore drill recorded.
- [ ] No open production-blocking issues remain.

## Rollback

- **Application regression:** restore the previous digests in `k8s/images.env`,
  run `make k8s-apply`, and re-run `make k8s-migrate`. Migrations are idempotent
  and versioned; do not reverse them by hand.
- **Terraform regression:** re-apply the last known-good tfvars from version
  control. Never `terraform destroy` datastores as a rollback step.
- **Data loss:** stop writers immediately and follow
  `docs/backup-runbook.md`; do not attempt an in-place repair first.
