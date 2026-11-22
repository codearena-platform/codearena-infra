#!/usr/bin/env python3
"""Render k8s YAML templates with immutable image references.

Source manifests keep ${IMAGE_NAME} placeholders so kubeconform can validate
them without a registry. The rendered manifests contain full
``registry/repository@sha256:<digest>`` references and are the only files that
should be applied to a cluster.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

PLACEHOLDER = re.compile(r"\$\{([A-Z][A-Z0-9_]*)\}")


def load_image_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise SystemExit(f"{path}: expected KEY=VALUE, got {line!r}")
        key, value = line.split("=", 1)
        key = key.strip()
        if not re.fullmatch(r"[A-Z][A-Z0-9_]*", key):
            raise SystemExit(f"{path}: invalid variable name {key!r}")
        values[key] = value.strip()
    return values


def render(source: Path, destination: Path, values: dict[str, str]) -> int:
    destination.mkdir(parents=True, exist_ok=True)
    rendered = 0
    for path in sorted(source.glob("*.yaml")):
        text = path.read_text(encoding="utf-8")

        def replace(match: re.Match[str]) -> str:
            key = match.group(1)
            if key not in values or not values[key]:
                raise SystemExit(f"{path.name}: missing image value for {key}")
            return values[key]

        output = PLACEHOLDER.sub(replace, text)
        leftover = PLACEHOLDER.search(output)
        if leftover:
            raise SystemExit(
                f"{path.name}: unresolved placeholder ${{{leftover.group(1)}}}"
            )
        (destination / path.name).write_text(output, encoding="utf-8")
        rendered += 1
    return rendered


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="directory with source YAML files")
    parser.add_argument("destination", type=Path, help="output directory")
    parser.add_argument(
        "--images-env",
        type=Path,
        default=Path("k8s/images.env"),
        help="KEY=VALUE file with image references",
    )
    args = parser.parse_args()

    if not args.source.is_dir():
        raise SystemExit(f"source directory not found: {args.source}")
    values = load_image_env(args.images_env)
    # Explicit environment overrides are useful for one-off promotion tests.
    for key in list(values):
        if key in os.environ:
            values[key] = os.environ[key]
    count = render(args.source, args.destination, values)
    print(f"Rendered {count} manifests into {args.destination}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
