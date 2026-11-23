import re
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from check_production_readiness import check  # noqa: E402

FILES = (
    "terraform/backend.tf.example",
    "terraform/backend.hcl.example",
    "terraform/production.tfvars.example",
    "docs/production-rollout.md",
    "docs/backup-runbook.md",
    "docs/oncall-runbook.md",
    "k8s/images.env",
    "README.md",
    "Makefile",
    ".dockerignore",
    ".github/workflows/validate.yml",
    ".github/workflows/images.yml",
)


def fixture(root: Path) -> None:
    for relative in FILES:
        target = root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(ROOT / relative, target)


def replace(root: Path, relative: str, old: str, new: str) -> None:
    path = root / relative
    path.write_text(path.read_text(encoding="utf-8").replace(old, new), encoding="utf-8")


class ProductionReadinessTest(unittest.TestCase):
    def test_repository_production_inputs_are_valid(self):
        self.assertEqual(check(ROOT), [])

    def test_detects_bootstrap_zero_digest(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fixture(root)
            path = root / "k8s/images.env"
            text = path.read_text(encoding="utf-8")
            text, count = re.subn(r"@sha256:[0-9a-f]{64}", "@sha256:" + "0" * 64, text, count=1)
            self.assertEqual(count, 1)
            path.write_text(text, encoding="utf-8")
            errors = check(root)
            self.assertTrue(any("zero digest" in e for e in errors), errors)

    def test_detects_missing_issue_traceability(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fixture(root)
            replace(root, "docs/production-rollout.md", "#21", "#XX")
            errors = check(root)
            self.assertTrue(any("production-rollout.md is missing: #21" in e for e in errors), errors)

    def test_detects_leaked_aws_key(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fixture(root)
            path = root / "terraform/production.tfvars.example"
            with path.open("a", encoding="utf-8") as handle:
                handle.write('\naccess_key = "AKIA1234567890ABCDEF"\n')
            errors = check(root)
            self.assertTrue(any("real-looking AWS access key" in e for e in errors), errors)

    def test_detects_missing_ci_gate(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fixture(root)
            replace(root, ".github/workflows/validate.yml", "make production-check", "true")
            errors = check(root)
            self.assertTrue(any("validate.yml is missing: make production-check" in e for e in errors), errors)

    def test_detects_missing_dockerignore(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fixture(root)
            (root / ".dockerignore").unlink()
            errors = check(root)
            self.assertTrue(any("nested .git directories" in e for e in errors), errors)


if __name__ == "__main__":
    unittest.main()
