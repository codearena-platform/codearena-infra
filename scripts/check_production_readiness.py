#!/usr/bin/env python3
"""Static production-readiness checks.

A real rollout needs cluster and cloud credentials, which CI does not have.
These checks protect the repository-side invariants that make the documented
rollout safe: real image digests, complete production input templates, runbooks,
issue traceability and the CI gates that enforce all of it.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

IMAGE_KEYS = ("GATEWAY_IMAGE", "IAM_IMAGE", "COMPETITION_IMAGE", "CORE_IMAGE")
DIGEST = re.compile(r"^([A-Z_]+)=([^\s@]+)@sha256:([0-9a-f]{64})$")
AWS_KEY = re.compile(r"AKIA[0-9A-Z]{16}")


def read(root: Path, relative: str) -> str:
    path = root / relative
    return path.read_text(encoding="utf-8") if path.is_file() else ""


def check(root: Path) -> list[str]:
    errors: list[str] = []

    for relative in (
        "terraform/backend.tf.example",
        "terraform/backend.hcl.example",
        "terraform/production.tfvars.example",
        "docs/production-rollout.md",
        "docs/backup-runbook.md",
        "docs/oncall-runbook.md",
    ):
        if not (root / relative).is_file():
            errors.append(f"missing required file: {relative}")

    images = read(root, "k8s/images.env")
    parsed: dict[str, str] = {}
    for line in images.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        match = DIGEST.match(line)
        if not match:
            errors.append(f"k8s/images.env has an invalid image reference: {line!r}")
            continue
        key, repository, digest = match.groups()
        parsed[key] = digest
        if not digest.strip("0"):
            errors.append(f"k8s/images.env still has a bootstrap zero digest for {key}")
        if not repository.startswith("ghcr.io/codearena-platform/"):
            errors.append(f"unexpected registry for {key}: {repository}")
    for key in IMAGE_KEYS:
        if key not in parsed:
            errors.append(f"k8s/images.env is missing {key}")

    tfvars = read(root, "terraform/production.tfvars.example")
    for needle in (
        'environment                = "prod"',
        "ingress_host",
        "ingress_tls_secret_name",
        "storage_class",
        "backup_s3",
        'endpoint   = "REPLACE_WITH_S3_ENDPOINT_OR_EMPTY"',
        "access_key",
        "secret_key",
        "alert_slack_webhook_url",
        "alert_pagerduty_routing_key",
        "log_retention_period",
        'kube_prometheus_stack_version = "70.0.0"',
    ):
        if needle not in tfvars:
            errors.append(f"terraform/production.tfvars.example is missing: {needle}")
    if tfvars.count("REPLACE_WITH_") < 8:
        errors.append("production.tfvars.example does not use obvious placeholders")
    if AWS_KEY.search(tfvars):
        errors.append("production.tfvars.example contains a real-looking AWS access key")

    rollout = read(root, "docs/production-rollout.md")
    for needle in (
        "#20",
        "#21",
        "#22",
        "#23",
        ".github#2",
        "## Gate 0",
        "## Gate 1",
        "## Gate 5",
        "## Go / No-go checklist",
        "## Rollback",
        "terraform init -backend-config=backend.hcl -migrate-state",
        "aws s3 ls",
        "PRAGMA integrity_check",
        "alert_slack_webhook_url",
        "/health",
    ):
        if needle not in rollout:
            errors.append(f"docs/production-rollout.md is missing: {needle}")

    readme = read(root, "README.md")
    for needle in (
        "docs/production-rollout.md",
        "docs/backup-runbook.md",
        "docs/oncall-runbook.md",
        "production.tfvars.example",
        "pin their base images",
        "-buildvcs=false",
    ):
        if needle not in readme:
            errors.append(f"README.md is missing: {needle}")

    dockerignore = read(root, ".dockerignore")
    if "**/.git" not in dockerignore:
        errors.append(".dockerignore must exclude nested .git directories")

    makefile = read(root, "Makefile")
    if not re.search(r"^production-check:\s*$", makefile, re.MULTILINE):
        errors.append("Makefile has no production-check target")

    ci = read(root, ".github/workflows/validate.yml")
    for needle in ("make production-check", "python3 scripts/check_monitoring.py"):
        if needle not in ci:
            errors.append(f".github/workflows/validate.yml is missing: {needle}")

    workflow = read(root, ".github/workflows/images.yml")
    for needle in ("paths-ignore", "k8s/images.env", "Publish digest branch for manual PR"):
        if needle not in workflow:
            errors.append(f".github/workflows/images.yml is missing: {needle}")
    if re.search(r"^\s+labels:\s*\$\{\{", workflow, re.MULTILINE):
        errors.append("images.yml still attaches commit-derived OCI labels")

    return errors


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    errors = check(root)
    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        print(f"Failed production readiness checks: {len(errors)}", file=sys.stderr)
        return 1
    print("OK: production rollout plan, inputs, runbooks and CI gates are wired")
    return 0


if __name__ == "__main__":
    sys.exit(main())
