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
            if not path.is_file():
                continue
            info = zipfile.ZipInfo(str(path.relative_to(package.parent)), date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_STORED
            info.external_attr = 0o644 << 16
            z.writestr(info, path.read_bytes())


MIN_COSINE = 0.995
MIN_TOP10_OVERLAP = 0.95
CORPUS_SIZE = 48
COSINE_FIXTURES = 5
TOP_K = 10


def dir_size(path):
    return sum(p.stat().st_size for p in Path(path).rglob("*") if p.is_file())


def fixture_waveforms(count, sr=48000, seconds=10):
    """Deterministic 10 s / 48 kHz waveforms: seeded sine mixtures plus shaped noise."""
    t = np.arange(sr * seconds) / sr
    out = []
    for i in range(count):
        rng = np.random.RandomState(1000 + i)
        w = np.zeros_like(t)
        for _ in range(int(rng.randint(2, 6))):
            w += rng.uniform(0.1, 1.0) * np.sin(2 * np.pi * float(np.exp(rng.uniform(np.log(40), np.log(12000)))) * t + rng.uniform(0, 6.28))
        w *= 0.5 + 0.5 * np.sin(2 * np.pi * rng.uniform(0.2, 4.0) * t)
        w += rng.uniform(0.0, 0.4) * np.cumsum(rng.randn(t.size)) / np.sqrt(t.size)
        out.append((w / (np.max(np.abs(w)) + 1e-9)).astype(np.float32))
    return out


def log_mel(model, waveform):
    h = model.audio_branch
    h.spectrogram_extractor.float(); h.logmel_extractor.float()
    with torch.no_grad():
        lm = h.logmel_extractor(h.spectrogram_extractor(torch.from_numpy(waveform).unsqueeze(0)))
    lm = lm.numpy().astype(np.float32)
    if lm.shape != (1, 1, 1001, 64):
        raise RuntimeError(f"unexpected log-mel shape {lm.shape}")
    return lm


def unit(x):
    return x / np.linalg.norm(x, axis=-1, keepdims=True)


def top_k_overlap(ref, cand, k=TOP_K):
    """Per-query overlap of top-k neighbours (query excluded) between two embedding sets."""
    def neighbours(m, i):
        sims = m @ m[i]
        sims[i] = -np.inf
        return set(np.argsort(-sims, kind="stable")[:k].tolist())
    return [len(neighbours(ref, i) & neighbours(cand, i)) / k for i in range(len(ref))]


def convert_audio_base512(model, ep_inputs, deployment):
    """FP16 (default ML Program precision) 512-D reference: the numerical ground truth."""
    class Base(torch.nn.Module):
        def __init__(self, h, projection):
            super().__init__(); self.h = h; self.projection = projection
        def forward(self, log_mel):
            x = log_mel.transpose(1, 3); x = self.h.bn0(x); x = x.transpose(1, 3)
            out = self.h.forward_features(self.h.reshape_wav2img(x))
            return F.normalize(self.projection(out["embedding"]), dim=-1)
    base = Base(model.audio_branch, model.audio_projection).eval()
    example = (torch.zeros(1, 1, 1001, 64),)
    ep = replace_fmod(torch.export.export(base, example, strict=True).run_decompositions())
    return ct.convert(ep, inputs=ep_inputs, outputs=[ct.TensorType(name="audio_embedding")], source="pytorch",
                      convert_to="mlprogram", compute_units=ct.ComputeUnit.CPU_AND_GPU,
                      minimum_deployment_target=deployment)


def verify_audio(model, reference_ml, cm, mean, components):
    """Run the five-fixture cosine gate and the fixed-corpus top-10 overlap gate."""
    mean_np, comp_np = mean.numpy(), components.numpy()
    waves = fixture_waveforms(CORPUS_SIZE)
    ref_vecs, cand_vecs = [], []
    for w in waves:
        feed = {"log_mel": log_mel(model, w)}
        base = unit(np.asarray(reference_ml.predict(feed)["audio_embedding"], dtype=np.float64))
        ref_vecs.append(unit((base - mean_np) @ comp_np.T)[0])
        cand_vecs.append(np.asarray(cm.predict(feed)["audio_embedding"], dtype=np.float64)[0])
    ref, cand = np.stack(ref_vecs), np.stack(cand_vecs)
    failures = []
    if cand.shape[1] != 128 or not np.all(np.isfinite(cand)):
        failures.append("candidate output is not finite 128-D")
    norms = np.linalg.norm(cand, axis=1)
    if np.any(np.abs(norms - 1.0) > 1e-2):
        failures.append(f"candidate output not unit length (min {norms.min():.6f}, max {norms.max():.6f})")
    cosines = [float(np.dot(ref[i], cand[i]) / (np.linalg.norm(ref[i]) * np.linalg.norm(cand[i]))) for i in range(COSINE_FIXTURES)]
    for i, c in enumerate(cosines):
        if not np.isfinite(c) or c < MIN_COSINE:
            failures.append(f"fixture {i} cosine {c:.6f} < {MIN_COSINE}")
    overlaps = top_k_overlap(ref, cand)
    mean_overlap = float(np.mean(overlaps))
    failed_queries = [{"query": i, "overlap": o} for i, o in enumerate(overlaps) if o < MIN_TOP10_OVERLAP]
    if mean_overlap < MIN_TOP10_OVERLAP:
        failures.append(f"mean top-{TOP_K} overlap {mean_overlap:.4f} < {MIN_TOP10_OVERLAP}")
    return {"fixture_cosines": cosines, "min_fixture_cosine": min(cosines), "minimum_cosine": MIN_COSINE,
            "corpus_size": CORPUS_SIZE, "top_k": TOP_K, "mean_top10_overlap": mean_overlap,
            "minimum_mean_top10_overlap": MIN_TOP10_OVERLAP, "failed_queries": failed_queries,
            "candidate_norm_min": float(norms.min()), "candidate_norm_max": float(norms.max()),
            "failures": failures, "passed": not failures}


TEXT_PROMPTS = [
    "calm acoustic guitar", "energetic electronic dance music", "slow jazz piano ballad",
    "heavy distorted metal guitars", "orchestral strings and brass", "lo-fi hip hop beat",
    "upbeat pop song with female vocals", "ambient synthesizer drone", "solo violin classical",
    "reggae with offbeat guitar", "thunderstorm and rain sounds", "tribal drums and percussion",
]


def quantize(raw, precision):
    dtype = mil_types.int4 if precision == "int4" else mil_types.int8
    config = OptimizationConfig(global_config=OpLinearQuantizerConfig(mode="linear_symmetric", dtype=dtype, granularity="per_block", block_size=32))
    return linear_quantize_weights(raw, config)


def convert_text_base512(model, deployment):
    """FP16 512-D text reference (L2-normalized text embedding, before the frozen projection)."""
    class Base(torch.nn.Module):
        def __init__(self, text, projection):
            super().__init__(); self.text = text; self.projection = projection
        def forward(self, input_ids, attention_mask):
            pooled = self.text(input_ids=input_ids, attention_mask=attention_mask)["pooler_output"]
            return F.normalize(self.projection(pooled), dim=-1)
    base = Base(model.text_branch, model.text_projection).eval()
    example = (torch.ones(1, 77, dtype=torch.int64), torch.ones(1, 77, dtype=torch.int64))
    ep = replace_fmod(torch.export.export(base, example, strict=True).run_decompositions())
    ins = [ct.TensorType(name="input_ids", shape=(1, 77), dtype=np.int32), ct.TensorType(name="attention_mask", shape=(1, 77), dtype=np.int32)]
    return ct.convert(ep, inputs=ins, outputs=[ct.TensorType(name="text_embedding")], source="pytorch",
                      convert_to="mlprogram", compute_units=ct.ComputeUnit.ALL, minimum_deployment_target=deployment)


def build_audio_candidate(model, mean, components, precision, workdir):
    """Rebuild the #180 audio candidate (same code path, projection and precision) plus its FP16 reference."""
    encoder, example = make_encoder("audio", model, mean, components)
    encoder.eval()
    ep = replace_fmod(torch.export.export(encoder, example, strict=True).run_decompositions())
    inputs = [ct.TensorType(name="log_mel", shape=(1, 1, 1001, 64), dtype=np.float32)]
    raw = ct.convert(ep, inputs=inputs, outputs=[ct.TensorType(name="audio_embedding")], source="pytorch", convert_to="mlprogram",
                     compute_units=ct.ComputeUnit.CPU_AND_GPU, minimum_deployment_target=ct.target.iOS18)
    cand_path = Path(workdir) / "audio-candidate.mlpackage"
    quantize(raw, precision).save(str(cand_path))
    ref_path = Path(workdir) / "audio-reference-fp16-512.mlpackage"
    convert_audio_base512(model, inputs, ct.target.iOS18).save(str(ref_path))
    return (ct.models.MLModel(str(cand_path), compute_units=ct.ComputeUnit.CPU_ONLY),
            ct.models.MLModel(str(ref_path), compute_units=ct.ComputeUnit.CPU_ONLY))


def verify_text(clap, model, reference_ml, cm, mean, components, audio_cm, audio_ref_ml, text_projection_sha, audio_projection_sha):
    """Fixed-prompt cosine gate plus text-to-audio retrieval overlap against the projected FP16 references."""
    mean_np, comp_np = mean.numpy(), components.numpy()
    ref_t, cand_t = [], []
    for prompt in TEXT_PROMPTS:
        tok = clap.tokenizer(prompt)
        feed = {"input_ids": tok["input_ids"].numpy().astype(np.int32), "attention_mask": tok["attention_mask"].numpy().astype(np.int32)}
        if feed["input_ids"].shape != (1, 77):
            raise RuntimeError(f"unexpected token shape {feed['input_ids'].shape}")
        base = unit(np.asarray(reference_ml.predict(feed)["text_embedding"], dtype=np.float64))
        ref_t.append(unit((base - mean_np) @ comp_np.T)[0])
        cand_t.append(np.asarray(cm.predict(feed)["text_embedding"], dtype=np.float64)[0])
    ref_a, cand_a = [], []
    for w in fixture_waveforms(CORPUS_SIZE):
        feed = {"log_mel": log_mel(model, w)}
        base = unit(np.asarray(audio_ref_ml.predict(feed)["audio_embedding"], dtype=np.float64))
        ref_a.append(unit((base - mean_np) @ comp_np.T)[0])
        cand_a.append(np.asarray(audio_cm.predict(feed)["audio_embedding"], dtype=np.float64)[0])
    ref_t, cand_t, ref_a, cand_a = map(np.stack, (ref_t, cand_t, ref_a, cand_a))
    failures = []
    if text_projection_sha != audio_projection_sha:
        failures.append(f"projection SHA mismatch: text {text_projection_sha} audio {audio_projection_sha}")
    if cand_t.shape[1] != 128 or not np.all(np.isfinite(cand_t)):
        failures.append("candidate output is not finite 128-D")
    norms = np.linalg.norm(cand_t, axis=1)
    if np.any(np.abs(norms - 1.0) > 1e-2):
        failures.append(f"candidate output not unit length (min {norms.min():.6f}, max {norms.max():.6f})")
    cosines = [float(np.dot(ref_t[i], cand_t[i]) / (np.linalg.norm(ref_t[i]) * np.linalg.norm(cand_t[i]))) for i in range(len(TEXT_PROMPTS))]
    for prompt, c in zip(TEXT_PROMPTS, cosines):
        if not np.isfinite(c) or c < MIN_COSINE:
            failures.append(f"prompt {prompt!r} cosine {c:.6f} < {MIN_COSINE}")
    overlaps = []
    for i in range(len(TEXT_PROMPTS)):
        top_ref = set(np.argsort(-(ref_a @ ref_t[i]), kind="stable")[:TOP_K].tolist())
        top_cand = set(np.argsort(-(cand_a @ cand_t[i]), kind="stable")[:TOP_K].tolist())
        overlaps.append(len(top_ref & top_cand) / TOP_K)
    mean_overlap = float(np.mean(overlaps))
    if mean_overlap < MIN_TOP10_OVERLAP:
        failures.append(f"mean text-to-audio top-{TOP_K} overlap {mean_overlap:.4f} < {MIN_TOP10_OVERLAP}")
    return {"prompts": TEXT_PROMPTS, "prompt_cosines": cosines, "min_prompt_cosine": min(cosines), "minimum_cosine": MIN_COSINE,
            "audio_corpus_size": CORPUS_SIZE, "top_k": TOP_K, "text_to_audio_top10_overlaps": overlaps,
            "mean_top10_overlap": mean_overlap, "minimum_mean_top10_overlap": MIN_TOP10_OVERLAP,
            "candidate_norm_min": float(norms.min()), "candidate_norm_max": float(norms.max()),
            "text_projection_sha256": text_projection_sha, "audio_projection_sha256": audio_projection_sha,
            "projection_sha_match": text_projection_sha == audio_projection_sha,
            "failures": failures, "passed": not failures}


def main(component):
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint", required=True, type=Path)
    parser.add_argument("--checkpoint-revision", required=True)
    parser.add_argument("--checkpoint-sha256", required=True)
    parser.add_argument("--starter-dir", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--audio-manifest", type=Path, help="published #180 audio manifest.json; its projection_sha256 must match")
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
    candidate = quantize(raw, args.precision)
    package = args.output_dir / f"clap-{component}-{args.precision}-128.mlpackage"
    candidate.save(package)
    # A real Core ML prediction is mandatory evidence; candidates below the gates fail closed.
    cm = ct.models.MLModel(str(package), compute_units=ct.ComputeUnit.CPU_ONLY)
    if component == "audio":
        reference_ml = convert_audio_base512(model, inputs, ct.target.iOS18)
        source_path = args.output_dir / "reference-fp16-512.mlpackage"
        reference_ml.save(str(source_path))
        reference_ml = ct.models.MLModel(str(source_path), compute_units=ct.ComputeUnit.CPU_ONLY)
        verification = verify_audio(model, reference_ml, cm, mean, components)
        verification["component"] = component
        verification["reference"] = "FP16 512-D Core ML model, then frozen projection, L2-normalized"
        source_size = dir_size(source_path)
        shutil.rmtree(source_path)
        cosine = verification["min_fixture_cosine"]
        if not verification["passed"]:
            (args.output_dir / "verification.json").write_text(json.dumps(verification, indent=2) + "\n")
            raise RuntimeError("candidate quality gates failed: " + "; ".join(verification["failures"]))
    else:
        published_sha = json.loads(args.audio_manifest.read_text())["projection_sha256"] if args.audio_manifest else projection_sha
        with tempfile.TemporaryDirectory() as tmp:
            audio_cm, audio_ref = build_audio_candidate(model, mean, components, args.precision, tmp)
            ref_path = Path(tmp) / "text-reference-fp16-512.mlpackage"
            convert_text_base512(model, ct.target.iOS18).save(str(ref_path))
            text_ref = ct.models.MLModel(str(ref_path), compute_units=ct.ComputeUnit.CPU_ONLY)
            source_size = dir_size(ref_path)
            verification = verify_text(clap, model, text_ref, cm, mean, components, audio_cm, audio_ref, projection_sha, published_sha)
        verification["component"] = component
        verification["reference"] = "FP16 512-D Core ML text model, then frozen projection, L2-normalized"
        cosine = verification["min_prompt_cosine"]
        if not verification["passed"]:
            (args.output_dir / "verification.json").write_text(json.dumps(verification, indent=2) + "\n")
            raise RuntimeError("candidate quality gates failed: " + "; ".join(verification["failures"]))
    archive = args.output_dir / f"clap-{component}-{args.precision}-128.mlpackage.zip"
    package_dir(package, archive)
    manifest = {"component": component, "dimensions": 128, "precision": args.precision, "minimum_deployment_target": "iOS18", "source_checkpoint_revision": args.checkpoint_revision, "source_checkpoint_sha256": args.checkpoint_sha256, "projection_sha256": projection_sha, "coremltools_version": ct.__version__, "python_version": platform.python_version(), "inputs": [x.name for x in inputs], "outputs": [output], "quantization": {"algorithm": "linear_symmetric", "granularity": "per_block", "block_size": 32, "weights_only": True, "api": "coremltools.optimize.coreml.linear_quantize_weights", "dtype": args.precision, "mixed_precision_exceptions": "none configured; ops Core ML cannot quantize remain at their converted precision"}, "projection": {"source_dims": 512, "target_dims": 128, "sha256": projection_sha, "applied_after": f"normalized 512-D {component} embedding, then L2-normalized"}, "package_size_bytes": dir_size(package), "verification": verification, "source_fp16_512_package_size_bytes": source_size, "archive_size_bytes": archive.stat().st_size, "archive_sha256": sha256(archive)}
    (args.output_dir / "verification.json").write_text(json.dumps(verification, indent=2) + "\n")
    (args.output_dir / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    lines = [f"# CLAP {component} {args.precision} 128-D candidate", "",
             f"- Gate metric (min fixture cosine to reference): `{cosine:.6f}`",
             f"- Package size: `{manifest['package_size_bytes']}` bytes (FP16 512-D source: `{source_size}`); archive `{manifest['archive_size_bytes']}` bytes",
             f"- Weight-only `{args.precision}` per-block (32) linear_symmetric compression; not a runtime-speed claim.",
             f"- Frozen starter 512-to-128 projection SHA-256: `{projection_sha}`",
             f"- Archive SHA-256: `{manifest['archive_sha256']}`",
             "- Minimum deployment target: iOS 18."]
    if component == "audio":
        lines += [f"- Fixture cosines: `{[round(c, 6) for c in verification['fixture_cosines']]}` (gate `{MIN_COSINE}`)",
                  f"- Mean top-{TOP_K} overlap over {CORPUS_SIZE} fixtures: `{verification['mean_top10_overlap']:.4f}` (gate `{MIN_TOP10_OVERLAP}`)",
                  f"- Queries below overlap gate: `{verification['failed_queries']}`"]
    if component == "text":
        lines += [f"- Prompt cosines (min): `{verification['min_prompt_cosine']:.6f}` over {len(TEXT_PROMPTS)} prompts (gate `{MIN_COSINE}`)",
                  f"- Mean text-to-audio top-{TOP_K} overlap over {CORPUS_SIZE} audio fixtures: `{verification['mean_top10_overlap']:.4f}` (gate `{MIN_TOP10_OVERLAP}`)",
                  f"- Audio projection SHA-256 matches text: `{verification['projection_sha_match']}` (`{verification['audio_projection_sha256']}`)"]
    (args.output_dir / "REPORT.md").write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    raise SystemExit("run generate_candidate_audio.py or generate_candidate_text.py")
