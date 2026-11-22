import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "render_k8s.py"


class RenderK8sTest(unittest.TestCase):
    def render(self, yaml_text: str, images_env: str, env=None):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "src"
            destination = root / "rendered"
            source.mkdir()
            (source / "deployment.yaml").write_text(yaml_text, encoding="utf-8")
            env_file = root / "images.env"
            env_file.write_text(images_env, encoding="utf-8")
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    str(source),
                    str(destination),
                    "--images-env",
                    str(env_file),
                ],
                capture_output=True,
                text=True,
                env=env,
                check=False,
            )
            rendered = (
                (destination / "deployment.yaml").read_text(encoding="utf-8")
                if (destination / "deployment.yaml").exists()
                else None
            )
            return result, rendered

    def test_replaces_image_placeholders(self):
        result, rendered = self.render(
            "image: ${GATEWAY_IMAGE}\n",
            "GATEWAY_IMAGE=ghcr.io/codearena-platform/gateway@sha256:abc\n",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            rendered, "image: ghcr.io/codearena-platform/gateway@sha256:abc\n"
        )

    def test_missing_value_fails(self):
        result, rendered = self.render("image: ${CORE_IMAGE}\n", "GATEWAY_IMAGE=x\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(rendered)
        self.assertIn("missing image value for CORE_IMAGE", result.stderr)

    def test_environment_override_wins(self):
        env = dict(os.environ)
        env["GATEWAY_IMAGE"] = "registry.example/gateway@sha256:override"
        result, rendered = self.render(
            "image: ${GATEWAY_IMAGE}\n",
            "GATEWAY_IMAGE=ghcr.io/codearena-platform/gateway@sha256:abc\n",
            env=env,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(rendered, "image: registry.example/gateway@sha256:override\n")

    def test_malformed_images_env_fails(self):
        result, _ = self.render("image: x\n", "not-a-key-value\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("expected KEY=VALUE", result.stderr)


if __name__ == "__main__":
    unittest.main()
