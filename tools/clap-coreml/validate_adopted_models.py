#!/usr/bin/env python3
"""Fail-closed check that the bundled CLAP pair is the adopted int4/128-D pair.

Run after `make models` and before project generation / archive. It never
downloads anything and accepts no other model: every check must pass.

Per package it checks: presence, the archive SHA-256 recorded by
`scripts/fetch-models.sh` (`Resources/Models/.<name>.sha256`), the published
manifest (component, 128 dimensions, int4, projection SHA), and the Core ML
output width (128). The manifest is read from `--<kind>-manifest`, else
`<package>/manifest.json`, else `<package>.manifest.json`.
"""
import argparse
import json
import sys
from pathlib import Path

DIMENSIONS = 128


def output_dimensions(package):
    """Last dimension of each Core ML output, read from the model spec."""
    import coremltools as ct
    spec = ct.models.MLModel(str(package), skip_model_load=True).get_spec()
    result = []
    for out in spec.description.output:
        shape = list(out.type.multiArrayType.shape)
        result.append(int(shape[-1]) if shape else 0)
    return result


def find_manifest(package, explicit):
    for candidate in (explicit, package / "manifest.json",
                      package.with_name(package.name + ".manifest.json")):
        if candidate and Path(candidate).is_file():
            return Path(candidate)
    return None


def check_package(kind, package, archive_sha, projection_sha, manifest_path):
    errors = []
    package = Path(package)
    if not package.is_dir():
        return [f"{kind}: package missing: {package}"]
    marker = package.with_name("." + package.name + ".sha256")
    recorded = marker.read_text().strip() if marker.is_file() else None
    if recorded != archive_sha:
        errors.append(f"{kind}: archive sha256 {recorded!r} != expected {archive_sha}")
    manifest_file = find_manifest(package, manifest_path)
    if manifest_file is None:
        errors.append(f"{kind}: manifest.json not found")
    else:
        try:
            m = json.loads(manifest_file.read_text())
        except ValueError as e:
            m = {}
            errors.append(f"{kind}: manifest unreadable: {e}")
        if m.get("component") != kind:
            errors.append(f"{kind}: manifest component {m.get('component')!r}")
        if m.get("dimensions") != DIMENSIONS:
            errors.append(f"{kind}: manifest dimensions {m.get('dimensions')!r}")
        if m.get("precision") != "int4" or (m.get("quantization") or {}).get("dtype") != "int4":
            errors.append(f"{kind}: manifest is not int4")
        if m.get("projection_sha256") != projection_sha:
            errors.append(f"{kind}: manifest projection {m.get('projection_sha256')!r}")
        if m.get("archive_sha256") not in (None, archive_sha):
            errors.append(f"{kind}: manifest archive sha {m.get('archive_sha256')!r}")
    try:
        dims = output_dimensions(package)
    except Exception as e:  # missing coremltools or unreadable spec fails closed
        errors.append(f"{kind}: cannot read output shape: {e}")
    else:
        if dims != [DIMENSIONS]:
            errors.append(f"{kind}: output dimensions {dims}, expected [{DIMENSIONS}]")
    return errors


def main(argv=None):
    p = argparse.ArgumentParser()
    p.add_argument("--audio", required=True)
    p.add_argument("--text", required=True)
    p.add_argument("--audio-sha256", required=True)
    p.add_argument("--text-sha256", required=True)
    p.add_argument("--projection-sha256", required=True)
    p.add_argument("--audio-manifest")
    p.add_argument("--text-manifest")
    a = p.parse_args(argv)
    errors = (check_package("audio", a.audio, a.audio_sha256, a.projection_sha256, a.audio_manifest)
              + check_package("text", a.text, a.text_sha256, a.projection_sha256, a.text_manifest))
    for e in errors:
        print(f"validate_adopted_models: {e}", file=sys.stderr)
    if not errors:
        print("validate_adopted_models: audio and text are the adopted int4/128-D pair")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
