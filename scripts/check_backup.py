#!/usr/bin/env python3
"""Static checks for the backup CronJob.

A real restore cannot run in CI. These checks protect the invariants that make
the backup set complete and restorable: a consistent SQLite snapshot, completion
markers before upload, optional S3 credentials, least-privilege pod/exec RBAC,
and a documented restore path.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

PLACEHOLDER = re.compile(r"\$\{[A-Z][A-Z0-9_]*\}")


def read(root: Path, relative: str) -> str:
    path = root / relative
    if not path.is_file():
        return ""
    return path.read_text(encoding="utf-8")


def check(root: Path) -> list[str]:
    errors: list[str] = []

    backup = read(root, "k8s/backup.yaml")
    for needle in (
        "name: sqlite-backup",
        "sqlite3 /data/codearena.db",
        ".backup '$SNAPSHOT'",
        "name: offcluster-copy",
        "amazon/aws-cli@sha256:",
        "/backups/.postgres.done",
        "/backups/.mongodb.done",
        "/backups/.sqlite.done",
        "until test -f \"$marker\"",
        "aws s3 cp",
        "--recursive",
        "-mtime +7 -delete",
        "name: codearena-backup-s3",
        "optional: true",
    ):
        if needle not in backup:
            errors.append(f"k8s/backup.yaml is missing: {needle}")

    for key in ("endpoint", "bucket", "region", "prefix", "access_key", "secret_key"):
        block = re.search(rf"key: {key}\n\s+optional: true", backup)
        if not block:
            errors.append(f"S3 secret key '{key}' is not optional")

    # The renderer resolves ${UPPER_CASE} from k8s/images.env; shell variables
    # with default expansions (${VAR:-}) are fine.
    for match in PLACEHOLDER.finditer(backup):
        errors.append(f"unrenderable placeholder in backup.yaml: {match.group(0)}")

    rbac = read(root, "k8s/rbac.yaml")
    for needle in ('resources: ["pods/exec"]', 'verbs: ["create"]', "name: backup-job"):
        if needle not in rbac:
            errors.append(f"k8s/rbac.yaml is missing: {needle}")

    policies = read(root, "k8s/networkpolicies.yaml")
    if "allow-backup-egress" not in policies or "cidr: 0.0.0.0/0" not in policies:
        errors.append("backup NetworkPolicy has no HTTPS egress to object storage")

    variables = read(root, "terraform/backup-variables.tf")
    for needle in ("variable \"backup_s3\"", "sensitive = true", "default   = null"):
        if needle not in variables:
            errors.append(f"terraform/backup-variables.tf is missing: {needle}")

    secret = read(root, "terraform/backup-secrets.tf")
    for needle in (
        "kubernetes_secret\" \"backup_s3",
        "count = var.backup_s3 == null ? 0 : 1",
        "secret_key = var.backup_s3.secret_key",
    ):
        if needle not in secret:
            errors.append(f"terraform/backup-secrets.tf is missing: {needle}")

    runbook = read(root, "docs/backup-runbook.md")
    for needle in (
        "RPO:",
        "RTO:",
        "Restore the Core SQLite PVC",
        "codearena-backup-s3",
        "integrity_check",
        "Stop writers",
    ):
        if needle not in runbook:
            errors.append(f"docs/backup-runbook.md is missing: {needle}")

    readme = read(root, "README.md")
    if "docs/backup-runbook.md" not in readme or "backup_s3" not in readme:
        errors.append("README.md must link the backup runbook and document backup_s3")

    return errors


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    errors = check(root)
    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        print(f"Failed backup checks: {len(errors)}", file=sys.stderr)
        return 1
    print("OK: backups cover all three stores and are copied off-cluster when configured")
    return 0


if __name__ == "__main__":
    sys.exit(main())
