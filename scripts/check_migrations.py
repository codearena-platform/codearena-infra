#!/usr/bin/env python3
"""Static checks for the Kubernetes migration strategy.

The migration Job runs against live datastores, so CI cannot execute it. These
checks protect the invariants that make a rerun safe: idempotent DDL, a locked
apply+record transaction, a checksum guard, and the RBAC/network wiring needed
for the Job to reach both datastores.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

MIGRATION_KEY = re.compile(r"^  ([A-Za-z0-9._-]+): \|\s*$")
TOP_LEVEL_KEY = re.compile(r"^  \S")
PG_FILE = re.compile(r"^postgres-V(\d{3})-(.+)\.sql$")


def read(root: Path, relative: str) -> str:
    path = root / relative
    if not path.is_file():
        return ""
    return path.read_text(encoding="utf-8")


def parse_configmap(text: str) -> dict[str, str]:
    """Extract literal-block keys from a ConfigMap's ``data`` section."""
    blocks: dict[str, list[str]] = {}
    current: str | None = None
    for line in text.splitlines():
        match = MIGRATION_KEY.match(line)
        if match:
            current = match.group(1)
            blocks[current] = []
            continue
        if current and TOP_LEVEL_KEY.match(line) and not line.lstrip().startswith("#"):
            current = None
        if current:
            if line.startswith("    "):
                blocks[current].append(line[4:])
            elif not line.strip():
                blocks[current].append("")
    return {key: "\n".join(lines).strip() + "\n" for key, lines in blocks.items()}


def check(root: Path) -> list[str]:
    errors: list[str] = []

    configmap_text = read(root, "k8s/migrations-configmap.yaml")
    if not configmap_text:
        return ["k8s/migrations-configmap.yaml is missing"]
    data = parse_configmap(configmap_text)

    runner = data.get("postgres-run.sh", "")
    for needle in (
        "pg_advisory_xact_lock",
        "BEGIN;",
        "COMMIT;",
        "infra_schema_migrations",
        "checksum <>",
        "sha256sum",
        "psql -v ON_ERROR_STOP=1",
        "ON CONFLICT (version) DO NOTHING",
        'postgres-V*.sql',
    ):
        if needle not in runner:
            errors.append(f"postgres-run.sh is missing required guard: {needle}")

    pg_files = sorted(key for key in data if PG_FILE.match(key))
    if len(pg_files) < 2:
        errors.append("expected at least two versioned Postgres migration files")
    versions = [int(PG_FILE.match(key).group(1)) for key in pg_files]  # type: ignore[union-attr]
    if versions != list(range(1, len(versions) + 1)):
        errors.append(f"Postgres migration versions must be sequential from 1, got {versions}")

    for key in pg_files:
        sql = data[key].upper()
        if "CREATE TABLE IF NOT EXISTS" not in sql and "CREATE INDEX IF NOT EXISTS" not in sql and "ADD COLUMN IF NOT EXISTS" not in sql:
            errors.append(f"{key} must use idempotent DDL")
        for forbidden in ("DROP ", "TRUNCATE", "DELETE FROM"):
            if forbidden in sql:
                errors.append(f"{key} contains destructive statement {forbidden.strip()}")

    mongo = data.get("mongo-001-indexes.js", "")
    for needle in (
        "createIndex",
        "$setOnInsert",
        "updateOne",
        'getSiblingDB("codearena")',
        "getSiblingDB(index.db)",
        '"matches"',
        '"users"',
        '"clients"',
        "checksum mismatch",
    ):
        if needle not in mongo:
            errors.append(f"mongo-001-indexes.js is missing required guard: {needle}")

    job = read(root, "k8s/migrations-job.yaml")
    for needle in (
        "kind: CronJob",
        "name: schema-migrations",
        "concurrencyPolicy: Forbid",
        "automountServiceAccountToken: false",
        "serviceAccountName: migrations",
        "name: postgres-migrations",
        "name: mongo-migrations",
        "key: POSTGRES_DSN",
        "key: MONGO_URI",
        "$(MONGO_URI)",
        "mongo-001-indexes.js",
        "ttlSecondsAfterFinished",
    ):
        if needle not in job:
            errors.append(f"k8s/migrations-job.yaml is missing required wiring: {needle}")

    serviceaccounts = read(root, "k8s/serviceaccounts.yaml")
    if "name: migrations" not in serviceaccounts:
        errors.append("migrations ServiceAccount is missing")

    policies = read(root, "k8s/networkpolicies.yaml")
    if "allow-migrations-egress" not in policies or policies.count("app: migrations") < 2:
        errors.append("migrations NetworkPolicy ingress/egress rules are missing")

    readme = read(root, "README.md")
    for needle in (
        "kubectl create job --from=cronjob/schema-migrations",
        "Rollback",
        "Release and upgrade",
    ):
        if needle not in readme:
            errors.append(f"README.md is missing documentation: {needle}")

    return errors


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    errors = check(root)
    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        print(f"Failed migration checks: {len(errors)}", file=sys.stderr)
        return 1
    print("OK: migration manifests are idempotent, versioned and wired to both datastores")
    return 0


if __name__ == "__main__":
    sys.exit(main())
