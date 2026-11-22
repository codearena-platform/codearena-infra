# CodeArena Infrastructure

Infrastructure as code and Kubernetes manifests for the CodeArena platform.

## Directory Structure

- `terraform/`: namespace, datastore Helm releases, the application `Secret` and the TLS-terminating gateway `Ingress`.
- `k8s/`: Deployments, Services, ServiceAccounts, RBAC, NetworkPolicies, schema migrations and the scheduled backup for the CodeArena applications (`gateway`, `iam`, `competition`, `simulation`/`realtime`). YAML files are templates with `${...}` image placeholders.
- `k8s/images.env`: immutable registry/digest references used to render the templates.
- `scripts/render_k8s.py`: substitutes image references into `.rendered/k8s/` before validation or deployment.
- `scripts/check_migrations.py`: static checks CI runs against the migration manifests.
- `docs/backup-runbook.md`: backup verification, off-cluster configuration and full restore procedure.

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/downloads) >= 1.5 and the provider versions locked in `terraform/.terraform.lock.hcl`.
- [kubectl](https://kubernetes.io/docs/tasks/tools/) configured for the target cluster (Kubernetes >= 1.21, for automatic `kubernetes.io/metadata.name` namespace labels).
- A CNI that enforces `NetworkPolicy` (Calico, Cilium, Weave, etc.). Policies are inert on clusters without one.
- An Ingress controller. The default manifests expect `ingress-nginx` in the `ingress-nginx` namespace and class `nginx`; change `var.ingress_class_name` and the `namespaceSelector` in `k8s/networkpolicies.yaml` for other setups.
- A DNS record for `var.ingress_host` pointing at the ingress controller's external address.
- A TLS Secret in the application namespace (see [Ingress and TLS](#ingress-and-tls)).
- A `StorageClass` that supports dynamic provisioning. The default name is `standard`; set `var.storage_class` and the `storageClassName` in `k8s/backup.yaml` to match your cluster.
- For shared/production deployments, AWS credentials allowed to read/write an S3 bucket, a KMS key and a DynamoDB lock table (see [Remote state](#remote-state)). Local development can use local state.

Terraform itself only talks to the Kubernetes and Helm providers; no cloud provider CLI is needed after the remote backend resources exist.

## Usage

The namespace must be the same for Terraform and `kubectl`. Pass it explicitly when it differs from the default (`codearena`):

```bash
export NAMESPACE=my-namespace
make tf-init   # run init with -backend-config=backend.hcl for shared/prod use
make tf-fmt-check
make tf-validate
make tf-plan   # review the infrastructure changes
make tf-apply          # create the namespace, datastores, Secret and Ingress
make k8s-apply         # render immutable image refs, deploy apps/policies/migrations/backup
make migrations-check  # validate migration invariants locally
make k8s-migrate       # run the versioned migration Job and wait for completion
make k8s-validate
make k8s-delete
```

Terraform inputs (set as `TF_VAR_*` environment variables or in a `terraform.tfvars` file):

| Variable | Default | Purpose |
| --- | --- | --- |
| `namespace` | `codearena` | Namespace for all resources. |
| `ingress_host` | `codearena.example.com` | Public hostname of the gateway Ingress. |
| `ingress_tls_secret_name` | `codearena-tls` | Existing TLS Secret used by the Ingress. |
| `ingress_class_name` | `nginx` | Ingress class to use. |
| `storage_class` | `standard` | StorageClass for all datastore and backup PVCs. |
| `postgres_pvc_size` | `20Gi` | PostgreSQL data volume. |
| `mongodb_pvc_size` | `20Gi` | MongoDB data volume. |
| `redis_pvc_size` | `10Gi` | Redis data volume. |
| `ws_allowed_origins` | `""` | Comma-separated browser origins allowed to open Core realtime WebSockets; empty uses same-origin fallback. |
| `backup_s3` | `null` | Optional S3-compatible target for off-cluster backups; see [backup runbook](docs/backup-runbook.md). |
| `kube_config_path` | `~/.kube/config` | Kubeconfig; set to `null` for in-cluster/OIDC credentials. |

### Remote state

Local state is only acceptable for a throwaway cluster. For shared or production
use, copy the two templates and fill in your own infrastructure details:

```bash
cp terraform/backend.tf.example terraform/backend.tf
cp terraform/backend.hcl.example terraform/backend.hcl
# edit backend.hcl: bucket, key, region, kms_key_id, dynamodb_table
cd terraform
terraform init -backend-config=backend.hcl -migrate-state
```

`backend.tf` uses a partial S3 backend block, so no bucket names or account
details are committed. `backend.hcl` is gitignored. The backend uses SSE-KMS
(`kms_key_id`) and DynamoDB locking (`dynamodb_table`); restrict both to the
Terraform role. Use `-reconfigure` instead of `-migrate-state` when moving an
existing local state that should not be copied.

### Ingress and TLS

The gateway Service is `ClusterIP`. Terraform creates a `networking.k8s.io/v1` Ingress that terminates TLS and routes `/` to `gateway:8080`.

Create the TLS Secret before applying (keep the private key out of Terraform state):

```bash
kubectl -n "${NAMESPACE:-codearena}" create secret tls codearena-tls \
  --cert=tls.crt --key=tls.key
```

Point DNS for `ingress_host` at the ingress controller. The Ingress includes the nginx-specific `ssl-redirect` annotation; other controllers ignore it or can use their own annotation. The ingress controller must be allowed by `k8s/networkpolicies.yaml` (by default it is selected via the `ingress-nginx` namespace label).

### Secrets

Passwords and keys are generated by Terraform (`random_password` / `random_id`) and written to the `codearena-secrets` Kubernetes Secret as:

| Key | Consumer |
| --- | --- |
| `POSTGRES_DSN` | competition, backup |
| `MONGO_URI` | competition, iam, backup |
| `JWT_SECRET` | iam, simulation (realtime JWT validation) |
| `ENCRYPTER_KEY` | iam |
| `REDIS_ADDR` | iam, simulation |
| `WS_ALLOWED_ORIGINS` | simulation (realtime WebSocket origin allowlist) |

Terraform state therefore contains credentials. For anything beyond local development, configure the encrypted, access-controlled remote backend described in [Remote state](#remote-state) before running `tf-apply`.

## Images and promotion

`.github/workflows/images.yml` builds four images on every pull request (build
only) and on every push to `main`/`v*` tag (build and push to GHCR):

| Image | Dockerfile | Source context |
| --- | --- | --- |
| `codearena-gateway` | `codearena-platform/Dockerfile.gateway` | repository root |
| `codearena-iam` | `codearena-platform/Dockerfile.iam` | repository root |
| `codearena-competition` | `codearena-platform/Dockerfile.competition` | repository root |
| `codearena-core` | `codearena-core/Dockerfile` | `codearena-core/` |

Every push also gets an immutable `sha-<commit>` tag; version tags additionally
get the version and `latest`. After a successful push the workflow records the
resulting digests in `k8s/images.env` and pushes them to the
`chore/update-image-digests` branch. This organization disables "Allow GitHub
Actions to create and approve pull requests", so a maintainer must open (or
refresh) the PR manually from
[the compare page](https://github.com/codearena-platform/codearena-infra/compare/main...chore/update-image-digests)
with the title `chore: update service image digests`. The workflow writes that
link to the run summary whenever the branch changes, and says when the digests
are already current. Merge the PR to make the new digests the deployment
default. The checked-in bootstrap digests are all zeroes until the first
workflow run; they are not deployable.

Source manifests reference `${GATEWAY_IMAGE}`, `${IAM_IMAGE}`,
`${COMPETITION_IMAGE}` and `${CORE_IMAGE}`. `make k8s-render` writes resolved
YAML to `.rendered/k8s/`; `make k8s-apply` and `make k8s-validate` do this
automatically. `imagePullPolicy` is `IfNotPresent` because a digest cannot be
reused with different content.

To promote an existing build without rebuilding, edit `k8s/images.env` to the
desired `registry/repository@sha256:<digest>` values and open a PR. Roll back
by pointing those four variables at the previous digests and re-applying.

## Application topology

`k8s/core-deployment.yaml` deploys the CodeArena Core image as a single
`simulation` workload. Two Services select the same pods:

| Service | Port | Consumer |
| --- | --- | --- |
| `simulation` | `50051` gRPC | Competition judge (`SIMULATION_URL=simulation:50051`) |
| `realtime` | `8081` WebSocket | Gateway `/ws/` proxy (`REALTIME_URL=http://realtime:8081`) |

Core runs with `--runtime-addr=` so it does not attempt to reach a Docker
runtime; bot containers are not available in this deployment and bots must
connect through `BotService.Connect`. The embedded realtime service uses Redis
for fan-out and validates spectator JWTs with the IAM secret. `JWT_ISSUER` and
`JWT_AUDIENCE` in the Core Deployment match the claims IAM actually signs
(`codearena-iam` / `codearena`). SQLite match/replay state lives on the
`core-data` PVC; adjust its `storageClassName` for your cluster.

This makes judging and live spectators functional after `make k8s-apply`.
Kafka was removed because no service consumes `KAFKA_ADDR`.

## Schema migrations

`k8s/migrations-configmap.yaml` holds versioned, idempotent migrations and their
runners. `k8s/migrations-job.yaml` defines a `schema-migrations` CronJob whose
template runs two init containers in order:

1. `postgres-migrations` applies `postgres-V*.sql` with `psql`. All DDL and the
   matching row in `infra_schema_migrations` are committed in one transaction,
   serialised by `pg_advisory_xact_lock`. A recorded version whose file checksum
   changed makes the Job fail instead of silently applying modified DDL.
2. `mongo-migrations` creates the `codearena.matches`, `iam.users` and
   `iam.clients` lookup indexes from `mongo-001-indexes.js`. MongoDB is deployed
   as a standalone chart, so there is no multi-document transaction: index
   creation is idempotent and the tracking document is written only after all
   indexes succeed. A retry after a partial failure is therefore safe.

The DDL mirrors versions 1 and 2 of
`codearena-platform/internal/competition/db/postgres/migrations.go`. The app
still runs its own migrations at startup; both sets use `IF NOT EXISTS`, and
their tracking tables are separate. The IAM data migration stays application
owned and is intentionally not duplicated here.

### Release and upgrade

1. Take a backup (or confirm the latest scheduled dump is healthy).
2. Apply the infrastructure and manifests: `make tf-apply && make k8s-apply`.
3. Run the migration Job explicitly with `make k8s-migrate`. It is equivalent
   to `kubectl create job --from=cronjob/schema-migrations <unique-name>` and
   waits for completion. The monthly schedule is only an idempotent safety net.
4. Roll the workloads forward. With the image pipeline, merge the digest PR from
   `.github/workflows/images.yml` and re-apply before restarting the apps.
5. Verify the Job logs, `/health` through the Ingress, and that both tracker
   tables contain the expected versions.

New schema changes go in a new `postgres-VNNN-*.sql` file or a new entry in the
MongoDB `migrations` array. Never edit a version that has already been applied:
the checksum guard will reject it. Every statement must be safe to re-run.

### Rollback

There are no destructive down migrations. To undo a bad release:

1. If only application code is at fault, roll back the image digests in
   `k8s/images.env` (see [Images and promotion](#images-and-promotion)), re-apply
   and restart. Leave the applied schema in place.
2. If the schema itself is incompatible, stop writers with the first command in
   the [restore runbook](#restore-runbook), restore PostgreSQL/MongoDB from the
   backup taken before the release, and restart the applications. Restoring the
   dump also restores the tracking table to its pre-upgrade state.
3. Fix the problem forward with a new migration version. Do not delete rows from
   `infra_schema_migrations` by hand; on a standalone MongoDB, deleting the
   tracking document would allow old, changed index definitions to be recreated.

`make migrations-check` and CI reject destructive DDL, missing checksum guards
and unwired migration Jobs.

## Network isolation

`k8s/networkpolicies.yaml` applies deny-by-default ingress and egress to every pod in the namespace, then explicitly allows only:

- ingress controller → `gateway:8080`;
- gateway → `iam:7000`, `competition:7001/50052` and `simulation:8081` (realtime);
- competition → `iam:7000` and `simulation:50051`;
- iam → MongoDB:27017 and Redis:6379;
- simulation → Redis:6379;
- competition → PostgreSQL:5432 and MongoDB:27017;
- backup → PostgreSQL:5432, MongoDB:27017, DNS and the Kubernetes API (to read the Secret);
- migrations → PostgreSQL:5432 and MongoDB:27017;
- DNS (`kube-system` CoreDNS, UDP/TCP 53) for every pod;
- intra-datastore traffic for replication/quorum (PostgreSQL, MongoDB, Redis).

Notes for cluster-specific tuning:

- The CoreDNS selector is `k8s-app: kube-dns`; adjust it if your distribution uses a different label.
- The API-server egress rule allows private RFC1918 ranges plus `0.0.0.0/0` on TCP 443/6443 for public API endpoints and S3-compatible storage. Narrow it to your API server and object-storage addresses.
- Application pods use dedicated ServiceAccounts with no mounted API token. The backup ServiceAccount has a `Role` restricted to `get` on `codearena-secrets`, `get`/`list` on pods and `create` on `pods/exec` for the SQLite snapshot.
- Datastore Services are explicitly `ClusterIP`; nothing in the datastore layer is publicly reachable.

## Persistence, backup and restore

Helm chart versions are pinned, persistence is enabled, and all datastore Services are internal-only:

| Chart | Pinned version | PVC setting | Default size |
| --- | --- | --- | --- |
| `postgresql` | `16.2.2` | `primary.persistence.size` | `var.postgres_pvc_size` (20Gi) |
| `mongodb` | `16.3.2` | `persistence.size` | `var.mongodb_pvc_size` (20Gi) |
| `redis` | `20.6.1` | `master.persistence.size` | `var.redis_pvc_size` (10Gi) |

`k8s/backup.yaml` creates a shared `datastore-backups` PVC (20Gi, `standard` class) and a CronJob that runs daily at 02:00 UTC. It writes a compressed PostgreSQL custom-format dump, a gzipped MongoDB archive and a **consistent SQLite snapshot of `core-data`** (via `sqlite3 .backup` in the running Core pod), keeps seven days of files, and uses the least-privilege `backup` ServiceAccount. After all three dumps succeed, an AWS CLI container copies them to an optional S3-compatible target when `var.backup_s3` or the `codearena-backup-s3` Secret is configured. Redis is not backed up: it holds rebuildable cache/session data.

The Core image must include the `sqlite3` CLI (Alpine `sqlite` package) for the snapshot. See [docs/backup-runbook.md](docs/backup-runbook.md) for configuration, verification and the complete restore procedure, including the SQLite PVC.

### Restore runbook

The short PostgreSQL/MongoDB helper flow is below. For the full procedure,
including the Core SQLite PVC and off-cluster downloads, see
[docs/backup-runbook.md](docs/backup-runbook.md).

1. Stop writers to avoid a split-brain restore:

   ```bash
   kubectl -n "${NAMESPACE:-codearena}" scale deploy/gateway deploy/iam deploy/competition deploy/simulation --replicas=0
   ```

2. Start a temporary helper pod that mounts the backup PVC and reads the same Secret:

   ```bash
   kubectl -n "${NAMESPACE:-codearena}" apply -f - <<'EOF'
   apiVersion: v1
   kind: Pod
   metadata:
     name: restore-helper
     labels:
       app: backup
   spec:
     serviceAccountName: backup
     restartPolicy: Never
     securityContext:
       fsGroup: 1000
     containers:
       - name: pg
         image: postgres:16.4-alpine
         command: ["/bin/sh", "-c", "sleep 3600"]
         env:
           - name: POSTGRES_DSN
             valueFrom:
               secretKeyRef: { name: codearena-secrets, key: POSTGRES_DSN }
         volumeMounts:
           - { name: backups, mountPath: /backups }
       - name: mongo
         image: mongo:7.0.14
         command: ["/bin/sh", "-c", "sleep 3600"]
         env:
           - name: MONGO_URI
             valueFrom:
               secretKeyRef: { name: codearena-secrets, key: MONGO_URI }
         volumeMounts:
           - { name: backups, mountPath: /backups }
     volumes:
       - name: backups
         persistentVolumeClaim:
           claimName: datastore-backups
   EOF
   ```

3. Pick the newest files and restore (drop/recreate objects only when the target is the same environment):

   ```bash
   kubectl -n "${NAMESPACE:-codearena}" exec -it restore-helper -c pg -- sh
   # gunzip -c /backups/postgresql/<file>.dump.gz | \
   #   pg_restore --clean --if-exists --no-owner --no-acl --dbname="$POSTGRES_DSN"
   exit

   kubectl -n "${NAMESPACE:-codearena}" exec -it restore-helper -c mongo -- sh
   # mongorestore --uri="$MONGO_URI" --archive=/backups/mongodb/<file>.archive.gz --gzip --drop
   exit
   ```

4. Delete the helper, scale the applications back up and verify `/health` through the Ingress:

   ```bash
   kubectl -n "${NAMESPACE:-codearena}" delete pod restore-helper
   kubectl -n "${NAMESPACE:-codearena}" scale deploy/gateway deploy/iam deploy/competition deploy/simulation --replicas=1
   ```

### RPO and RTO

- **RPO:** up to 24 hours (daily 02:00 UTC logical backups). Shorten the CronJob schedule if a lower RPO is required.
- **RTO:** target 1 hour, assuming the PVC is available and the dataset fits the stated volume sizes; dominated by dump restore time and application validation.
- **Retention:** 7 daily copies on the in-cluster backup PVC, plus the lifecycle retention configured on the S3-compatible target. Perform a restore drill at least monthly.
- Configure `var.backup_s3` (or the `codearena-backup-s3` Secret) before relying on backups for regional disaster recovery; without it, copies stay on the same cluster as the datastores.

## Remaining work

- Provision the S3 bucket, KMS key and DynamoDB lock table referenced by `terraform/backend.hcl.example` and grant the Terraform role access. The encrypted backend configuration is included; the cloud resources are environment-specific.
- Enable "Allow GitHub Actions to create and approve pull requests" at the organization level, then restore automatic PR creation in `.github/workflows/images.yml` and remove the manual step from [Images and promotion](#images-and-promotion).
- Provision the S3-compatible bucket/credentials used by `var.backup_s3`; the uploader is optional until they exist.
- Add monitoring, alerting and log aggregation.
