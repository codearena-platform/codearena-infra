import shutil
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from check_migrations import check, parse_configmap  # noqa: E402


class MigrationChecksTest(unittest.TestCase):
    def test_repository_migrations_are_valid(self):
        self.assertEqual(check(ROOT), [])

    def test_parse_configmap_extracts_literal_blocks(self):
        text = (ROOT / "k8s/migrations-configmap.yaml").read_text(encoding="utf-8")
        data = parse_configmap(text)
        self.assertIn("postgres-run.sh", data)
        self.assertIn("postgres-V001-core-schema.sql", data)
        self.assertIn("mongo-001-indexes.js", data)
        self.assertIn("pg_advisory_xact_lock", data["postgres-run.sh"])

    def test_detects_removed_advisory_lock(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "k8s").mkdir()
            readme = (ROOT / "README.md").read_text(encoding="utf-8")
            (root / "README.md").write_text(readme, encoding="utf-8")
            for name in (
                "migrations-configmap.yaml",
                "migrations-job.yaml",
                "serviceaccounts.yaml",
                "networkpolicies.yaml",
            ):
                shutil.copy(ROOT / "k8s" / name, root / "k8s" / name)

            path = root / "k8s/migrations-configmap.yaml"
            text = path.read_text(encoding="utf-8").replace(
                "pg_advisory_xact_lock", "removed_lock"
            )
            path.write_text(text, encoding="utf-8")

            errors = check(root)
            self.assertTrue(
                any("pg_advisory_xact_lock" in error for error in errors), errors
            )

    def test_detects_destructive_ddl(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "k8s").mkdir()
            (root / "README.md").write_text(
                "kubectl create job --from=cronjob/schema-migrations\nRollback\nRelease and upgrade\n",
                encoding="utf-8",
            )
            configmap = (
                (ROOT / "k8s/migrations-configmap.yaml")
                .read_text(encoding="utf-8")
                .replace(
                    "-- Source: codearena-platform/internal/competition/db/postgres/migrations.go v1.\n",
                    "-- Source: codearena-platform/internal/competition/db/postgres/migrations.go v1.\n    DROP TABLE bots;\n",
                )
            )
            (root / "k8s/migrations-configmap.yaml").write_text(configmap, encoding="utf-8")
            for name in ("migrations-job.yaml", "serviceaccounts.yaml", "networkpolicies.yaml"):
                shutil.copy(ROOT / "k8s" / name, root / "k8s" / name)

            errors = check(root)
            self.assertTrue(any("DROP" in error for error in errors), errors)


if __name__ == "__main__":
    unittest.main()
