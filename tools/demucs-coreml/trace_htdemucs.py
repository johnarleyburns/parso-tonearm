#!/usr/bin/env python3
"""Trace htdemucs and report what blocks its Core ML conversion (M6 commit 6.6).

    python3 -m venv .venv && .venv/bin/pip install torch coremltools demucs
    .venv/bin/python tools/demucs-coreml/trace_htdemucs.py

Reproduces the findings in this directory's README: the model traces and freezes
cleanly, and conversion stops on the complex-valued STFT/ISTFT pair that a
hybrid model keeps *inside* the network. Core ML has no complex tensors, so the
fix is architectural (move the transform out, or convert a time-domain model),
not a converter flag.

This script does not ship a model. It exists so the next attempt starts from
evidence — which op, at what index, out of how many — instead of from scratch.
"""

import argparse
import warnings

warnings.filterwarnings("ignore")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", default="htdemucs")
    parser.add_argument("--convert", action="store_true",
                        help="also attempt the Core ML conversion and print where it stops")
    args = parser.parse_args()

    import torch
    from demucs.pretrained import get_model

    bag = get_model(args.model)
    model = (bag.models[0] if hasattr(bag, "models") else bag).eval()
    params = sum(p.numel() for p in model.parameters())
    print(f"{type(model).__name__}: {params:,} params "
          f"(~{params * 2 / 1e6:.0f} MB at FP16), {model.samplerate} Hz, "
          f"{model.audio_channels} ch, sources {model.sources}")

    # The dynamic 'train segment' branch computes padding from the input length,
    # which traces as shape arithmetic Core ML cannot fold. Turning it off and
    # freezing removes most of it — from op 29/2087 to op 594/1732.
    model.use_train_segment = False
    segment = int(model.segment * model.samplerate)
    example = torch.randn(1, model.audio_channels, segment)
    with torch.no_grad():
        frozen = torch.jit.freeze(torch.jit.trace(model, example, check_trace=False))
    print(f"traced + frozen at {segment} samples ({segment / model.samplerate:.2f} s)")

    kinds = {}
    for node in frozen.graph.nodes():
        kinds[node.kind()] = kinds.get(node.kind(), 0) + 1
    blocking = {k: v for k, v in kinds.items()
                if "stft" in k or "complex" in k or "view_as" in k}
    print(f"complex-domain ops remaining in the graph: {blocking or 'none'}")
    if blocking:
        print("  → Core ML has no complex tensors. See README: either move the STFT/ISTFT "
              "out of the model and do it in Swift, or convert a time-domain-only model.")

    if args.convert:
        import coremltools as ct
        try:
            ct.convert(frozen,
                       inputs=[ct.TensorType(name="audio",
                                             shape=(1, model.audio_channels, segment),
                                             dtype=float)],
                       minimum_deployment_target=ct.target.iOS18,
                       compute_precision=ct.precision.FLOAT16,
                       convert_to="mlprogram")
            print("CONVERTED — this README is out of date, and that is good news")
        except Exception as exc:  # noqa: BLE001 - the failure *is* the output here
            print(f"conversion stopped: {type(exc).__name__}: {str(exc)[:300]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
