import shutil
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from check_backup import check  # noqa: E402


def fixture(root: Path) -> None:
    (root / "k8s").mkdir()
    (root / "terraform").mkdir()
    (root / "docs").mkdir()
    for relative in (
        "k8s/backup.yaml",
        "k8s/rbac.yaml",
        "k8s/networkpolicies.yaml",
        "terraform/backup-variables.tf",
        "terraform/backup-secrets.tf",
        "docs/backup-runbook.md",
        "README.md",
    ):
        target = root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(ROOT / relative, target)


class BackupChecksTest(unittest.TestCase):
    def test_repository_backup_is_valid(self):
        self.assertEqual(check(ROOT), [])

    def test_detects_missing_sqlite_snapshot(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fixture(root)
            path = root / "k8s/backup.yaml"
            path.write_text(
                path.read_text(encoding="utf-8").replace(".backup '$SNAPSHOT'", "cp"),
                encoding="utf-8",
            )
            errors = check(root)
            self.assertTrue(any(". backup" in e or "$SNAPSHOT" in e for e in errors), errors)

    def test_detects_missing_offcluster_upload(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fixture(root)
            path = root / "k8s/backup.yaml"
            path.write_text(
                path.read_text(encoding="utf-8").replace("aws s3 cp", "true"),
                encoding="utf-8",
            )
            errors = check(root)
            self.assertTrue(any("aws s3 cp" in e for e in errors), errors)

    def test_detects_rendering_placeholder(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fixture(root)
            path = root / "k8s/backup.yaml"
            path.write_text(
                path.read_text(encoding="utf-8")
                + "\n# accidental ${S3_BUCKET} placeholder\n",
                encoding="utf-8",
            )
            errors = check(root)
            self.assertTrue(any("unrenderable placeholder" in e for e in errors), errors)


if __name__ == "__main__":
    unittest.main()
