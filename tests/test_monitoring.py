import shutil
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from check_monitoring import (  # noqa: E402
    MONITORING_TF,
    NETWORK_POLICY,
    REQUIRED_FILES,
    RUNBOOK,
    VARIABLES_TF,
    check,
)


def seeded_root(destination: Path) -> Path:
    """Copy the monitoring files into a temporary repository root."""
    for relative in REQUIRED_FILES:
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(ROOT / relative, target)
    return destination


def replace(destination: Path, relative: str, old: str, new: str) -> None:
    path = destination / relative
    text = path.read_text(encoding="utf-8")
    if old not in text:
        raise AssertionError(f"{old!r} not present in {relative}")
    path.write_text(text.replace(old, new), encoding="utf-8")


class MonitoringChecksTest(unittest.TestCase):
    def test_repository_monitoring_is_valid(self):
        self.assertEqual(check(ROOT), [])

    def test_detects_removed_alert_expression(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = seeded_root(Path(tmp))
            replace(
                root,
                MONITORING_TF,
                "kube_pod_container_status_restarts_total",
                "missing_restart_metric",
            )
            errors = check(root)
            self.assertTrue(
                any("kube_pod_container_status_restarts_total" in error for error in errors),
                errors,
            )

    def test_detects_unpinned_chart(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = seeded_root(Path(tmp))
            replace(root, VARIABLES_TF, 'default     = "70.0.0"', 'default     = ""')
            errors = check(root)
            self.assertTrue(
                any("kube_prometheus_stack_version" in error for error in errors), errors
            )

    def test_detects_missing_log_retention(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = seeded_root(Path(tmp))
            replace(root, MONITORING_TF, "retention_enabled", "retention_disabled")
            errors = check(root)
            self.assertTrue(any("retention_enabled" in error for error in errors), errors)

    def test_detects_missing_dashboard(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = seeded_root(Path(tmp))
            replace(root, MONITORING_TF, "codearena-overview.json", "removed.json")
            errors = check(root)
            self.assertTrue(any("dashboard wiring" in error for error in errors), errors)

    def test_detects_missing_runbook_section(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = seeded_root(Path(tmp))
            replace(root, RUNBOOK, "### Ingress error rate", "### Removed section")
            errors = check(root)
            self.assertTrue(any("Ingress error rate" in error for error in errors), errors)

    def test_detects_missing_network_policy(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = seeded_root(Path(tmp))
            (root / NETWORK_POLICY).unlink()
            errors = check(root)
            self.assertTrue(any(NETWORK_POLICY in error for error in errors), errors)


if __name__ == "__main__":
    unittest.main()
