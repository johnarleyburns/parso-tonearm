#!/usr/bin/env python3
"""Shared, deterministic CLAP candidate converter.

This is deliberately a release-tooling script, not production application code.
It never edits a model lock or uploads a release.  The workflow supplies a
checksum-verified checkpoint and publishes only the archive and evidence it
creates.  Both encoders use the exact frozen 512 -> 128 PCA projection embedded
in the starter database, so their output spaces remain comparable.
"""
import argparse
import hashlib
import json
import platform
import shutil
import sqlite3
import sys
import tempfile
import types
import zipfile
from pathlib import Path

import coremltools as ct
from coremltools.converters.mil.mil import types as mil_types
from coremltools.optimize.coreml import (OpLinearQuantizerConfig,
                                         OptimizationConfig,
                                         linear_quantize_weights)
import numpy as np
import torch
import torch.nn.functional as F
import laion_clap


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def frozen_projection(starter_dir):
    """Read Swift EmbeddingProjection.encoded: LE Float32 mean then row matrix."""
    dbs = list(Path(starter_dir).glob("*.sqlite")) + list(Path(starter_dir).glob("*.db"))
    if len(dbs) != 1:
        raise RuntimeError(f"expected exactly one starter SQLite database in {starter_dir}, found {dbs}")
    con = sqlite3.connect(f"file:{dbs[0]}?mode=ro", uri=True)
    try:
        row = con.execute("SELECT source_dims, dims, data FROM starter_projection").fetchone()
    finally:
        con.close()
    if row is None:
        raise RuntimeError("starter database has no frozen starter_projection")
    source_dims, dims, blob = row
    values = np.frombuffer(blob, dtype="<f4")
    if (source_dims, dims) != (512, 128) or values.size != source_dims * (dims + 1):
        raise RuntimeError(f"unexpected projection shape {(source_dims, dims)}, {values.size} floats")
    return (torch.from_numpy(values[:source_dims].copy()),
            torch.from_numpy(values[source_dims:].reshape(dims, source_dims).copy()),
            hashlib.sha256(blob).hexdigest())


def replace_fmod(ep):
    """coremltools cannot lower fmod; rewrite fmod(x,d) for non-negative inputs."""
    graph = ep.graph_module.graph
    nodes = [n for n in graph.nodes if n.op == "call_function" and "fmod" in str(n.target)]
    for n in nodes:
        x, divisor = n.args[0], n.args[1]
        val = x.meta.get("val")
        integer = val is not None and val.dtype in (torch.int32, torch.int64, torch.int16, torch.int8)
        with graph.inserting_before(n):
            xf = graph.call_function(torch.ops.aten._to_copy.default, (x,), {"dtype": torch.float32}) if integer else x
            q = graph.call_function(torch.ops.aten.div.Tensor, (xf, divisor))
            q = graph.call_function(torch.ops.aten.floor.default, (q,))
            out = graph.call_function(torch.ops.aten.sub.Tensor, (xf, graph.call_function(torch.ops.aten.mul.Tensor, (q, divisor))))
            if integer:
                out = graph.call_function(torch.ops.aten._to_copy.default, (out,), {"dtype": val.dtype})
        n.replace_all_uses_with(out)
        graph.erase_node(n)
    if nodes:
        graph.lint(); ep.graph_module.recompile()
    return ep


def finite_text_mask(model):
    def mask(self, attention_mask, input_shape, device=None, dtype=None):
        dtype = dtype or self.dtype
        extended = attention_mask[:, None, None, :] if attention_mask.dim() == 2 else attention_mask[:, None, :, :]
        return (1.0 - extended.to(dtype=dtype)) * torch.tensor(-10000.0, dtype=dtype)
    model.text_branch.get_extended_attention_mask = types.MethodType(mask, model.text_branch)


class Project128(torch.nn.Module):
    def __init__(self, mean, components):
        super().__init__()
        self.register_buffer("mean", mean)
        self.register_buffer("components", components)

    def project(self, x):
        # The app uses cosine retrieval; normalize the PCA coordinates at the boundary.
        return F.normalize((x - self.mean) @ self.components.T, dim=-1)


def load_model(checkpoint):
    clap = laion_clap.CLAP_Module(enable_fusion=False, amodel="HTSAT-base", device="cpu")
    clap.load_ckpt(str(checkpoint))
    model = clap.model
    for value in list(model.parameters()) + list(model.buffers()):
        value.requires_grad_(False)
    model.eval(); finite_text_mask(model)
    return clap, model


def make_encoder(component, model, mean, components):
    projector = Project128(mean, components)
    if component == "audio":
        class AudioEncoder(Project128):
            def __init__(self, h, projection, mean, components):
                super().__init__(mean, components); self.h = h; self.projection = projection
            def forward(self, log_mel):
                x = log_mel.transpose(1, 3); x = self.h.bn0(x); x = x.transpose(1, 3)
                out = self.h.forward_features(self.h.reshape_wav2img(x))
                return self.project(F.normalize(self.projection(out["embedding"]), dim=-1))
        return AudioEncoder(model.audio_branch, model.audio_projection, mean, components), (torch.zeros(1, 1, 1001, 64),)
    class TextEncoder(Project128):
        def __init__(self, text, projection, mean, components):
            super().__init__(mean, components); self.text = text; self.projection = projection
        def forward(self, input_ids, attention_mask):
            pooled = self.text(input_ids=input_ids, attention_mask=attention_mask)["pooler_output"]
            return self.project(F.normalize(self.projection(pooled), dim=-1))
    return TextEncoder(model.text_branch, model.text_projection, mean, components), (torch.ones(1, 77, dtype=torch.int64), torch.ones(1, 77, dtype=torch.int64))


def package_dir(package, archive):
    # ZIP_STORED and sorted paths make the artifact contents independently inspectable.
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_STORED) as z:
        for path in sorted(Path(package).rglob("*")):
            if path.is_file(): z.write(path, path.relative_to(package.parent))


def main(component):
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint", required=True, type=Path)
    parser.add_argument("--checkpoint-revision", required=True)
    parser.add_argument("--checkpoint-sha256", required=True)
    parser.add_argument("--starter-dir", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--precision", choices=("int4", "int8"), required=True)
    args = parser.parse_args()
    if sha256(args.checkpoint) != args.checkpoint_sha256:
        raise RuntimeError("refusing an unverified checkpoint")
    args.output_dir.mkdir(parents=True, exist_ok=True)
    mean, components, projection_sha = frozen_projection(args.starter_dir)
    clap, model = load_model(args.checkpoint)
    encoder, example = make_encoder(component, model, mean, components)
    encoder.eval()
    with torch.no_grad(): reference = encoder(*example).numpy()
    ep = replace_fmod(torch.export.export(encoder, example, strict=True).run_decompositions())
    if component == "audio":
        inputs = [ct.TensorType(name="log_mel", shape=(1, 1, 1001, 64), dtype=np.float32)]
        output = "audio_embedding"; units = ct.ComputeUnit.CPU_AND_GPU
    else:
        inputs = [ct.TensorType(name="input_ids", shape=(1, 77), dtype=np.int32), ct.TensorType(name="attention_mask", shape=(1, 77), dtype=np.int32)]
        output = "text_embedding"; units = ct.ComputeUnit.ALL
    # INT4 weight palettes are an iOS 18 ML Program feature. INT8 is retained as a control.
    raw = ct.convert(ep, inputs=inputs, outputs=[ct.TensorType(name=output)], source="pytorch", convert_to="mlprogram", compute_units=units, minimum_deployment_target=ct.target.iOS18)
    dtype = mil_types.int4 if args.precision == "int4" else mil_types.int8
    config = OptimizationConfig(global_config=OpLinearQuantizerConfig(mode="linear_symmetric", dtype=dtype, granularity="per_block", block_size=32))
    candidate = linear_quantize_weights(raw, config)
    package = args.output_dir / f"clap-{component}-{args.precision}-128.mlpackage"
    candidate.save(package)
    # A real Core ML prediction is mandatory evidence; candidates below this fail closed.
    cm = ct.models.MLModel(package, compute_units=ct.ComputeUnit.CPU_ONLY)
    feed = {"log_mel": example[0].numpy()} if component == "audio" else {"input_ids": example[0].numpy().astype(np.int32), "attention_mask": example[1].numpy().astype(np.int32)}
    actual = cm.predict(feed)[output]
    cosine = float(np.dot(reference[0], actual[0]) / (np.linalg.norm(reference[0]) * np.linalg.norm(actual[0])))
    if not np.isfinite(cosine) or cosine < 0.985:
        raise RuntimeError(f"candidate fidelity gate failed: cosine={cosine:.6f} < 0.985")
    archive = args.output_dir / f"clap-{component}-{args.precision}-128.mlpackage.zip"
    package_dir(package, archive)
    verification = {"component": component, "fixture": "zero-input deterministic smoke fixture", "cosine_to_pytorch": cosine, "minimum_cosine": 0.985, "passed": True}
    manifest = {"component": component, "dimensions": 128, "precision": args.precision, "minimum_deployment_target": "iOS18", "source_checkpoint_revision": args.checkpoint_revision, "source_checkpoint_sha256": args.checkpoint_sha256, "projection_sha256": projection_sha, "coremltools_version": ct.__version__, "python_version": platform.python_version(), "inputs": [x.name for x in inputs], "outputs": [output], "quantization": {"algorithm": "linear_symmetric", "granularity": "per_block", "block_size": 32, "weights_only": True}, "archive_sha256": sha256(archive)}
    (args.output_dir / "verification.json").write_text(json.dumps(verification, indent=2) + "\n")
    (args.output_dir / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    (args.output_dir / "REPORT.md").write_text(f"# CLAP {component} {args.precision} 128-D candidate\n\n- Core ML prediction cosine to PyTorch: `{cosine:.6f}` (gate: `0.985`)\n- Weight-only `{args.precision}` compression; this is not a runtime-speed claim.\n- Uses the frozen starter 512-to-128 projection (`{projection_sha}`).\n- Minimum deployment target: iOS 18.\n")


if __name__ == "__main__":
    raise SystemExit("run generate_candidate_audio.py or generate_candidate_text.py")
