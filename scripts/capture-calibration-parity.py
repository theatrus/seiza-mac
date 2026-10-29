#!/usr/bin/env python3
"""Capture decisions using PSF Guard's public API and a temporary catalog."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import tomllib

REVISION = "79f5e31d53b8371e8fcd0b22a9b69692412cd8b4"
ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "Tests/Fixtures/CalibrationParity"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("psf_guard", type=Path, help="Clean checkout at the pinned revision")
    parser.add_argument("--output", type=Path, default=FIXTURES / "psf-guard.json")
    args = parser.parse_args()
    source = args.psf_guard.resolve()
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
    if revision != REVISION:
        parser.error(f"Expected PSF Guard {REVISION}, found {revision}")
    subprocess.run(["git", "diff", "--quiet", "HEAD", "--"], cwd=source, check=True)
    locked = tomllib.loads((source / "Cargo.lock").read_text())["package"]
    for name, version in [("seiza-calibration", "0.8.1"), ("seiza-stacking", "0.51.2")]:
        versions = [p["version"] for p in locked if p["name"] == name]
        if versions != [version]:
            parser.error(f"Expected {name} {version}, found {versions}")
    with tempfile.TemporaryDirectory(prefix="seiza-parity-capture-") as temp:
        project = Path(temp)
        (project / "src").mkdir()
        shutil.copyfile(FIXTURES / "capture.rs", project / "src/main.rs")
        shutil.copyfile(source / "Cargo.lock", project / "Cargo.lock")
        (project / "Cargo.toml").write_text(
            '[package]\nname = "seiza-calibration-parity-capture"\nversion = "0.0.0"\nedition = "2024"\n'
            '[dependencies]\npsf-guard = { path = ' + json.dumps(str(source)) + ' }\n'
            'anyhow = "1.0"\nserde_json = "1.0"\nrusqlite = "0.40"\ntempfile = "3"\n'
        )
        env = dict(os.environ, PSF_GUARD_SKIP_FRONTEND_BUILD="1")
        result = subprocess.check_output(
            ["cargo", "run", "--offline", "--quiet", "--manifest-path", str(project / "Cargo.toml"),
             "--target-dir", str(source / "target")], env=env, text=True
        )
        fixture = json.loads(result)
        args.output.write_text(json.dumps(fixture, indent=2, sort_keys=True) + "\n")
        print(args.output)


if __name__ == "__main__":
    main()
