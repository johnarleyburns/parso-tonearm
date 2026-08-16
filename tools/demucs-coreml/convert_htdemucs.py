#!/usr/bin/env python3
"""Convert htdemucs to Core ML with both transforms lifted into Swift.

Core ML has complex tensors as a type but almost no MIL op accepts them
(slice_by_index does not), and it has no istft at all. So the model takes the
real spectrogram and the raw waveform, and returns the real masked spectrogram
and the waveform branch; Swift owns STFT and ISTFT.

Outputs, next to this script:
  HTDemucsCore.mlpackage   the converted model (FP32)
  reference.pt            torch reference tensors for the Swift golden tests
"""
import warnings
warnings.filterwarnings("ignore")
import pathlib
import numpy as np
import torch
import torch.nn as nn

import coremltools as ct
from coremltools.converters.mil.frontend.torch import ops as tops
from coremltools.converters.mil import Builder as mb

HERE = pathlib.Path(__file__).parent


def _cast_patched(context, node, dtype, dtype_name):
    """coremltools' own _cast does dtype(np.array([N])); NumPy 2 rejects that.

    This is the entire cause of the `aten::Int` failure that earlier notes
    blamed on complex tensors. All 36 sites in the htdemucs graph are this bug.
    """
    inputs = tops._get_inputs(context, node, expected=1)
    x = inputs[0]
    if not (len(x.shape) == 0 or np.all([d == 1 for d in x.shape])):
        raise ValueError("input to cast must be either a scalar or a length 1 tensor")
    if x.can_be_folded_to_const():
        val = x.val
        if isinstance(val, np.ndarray) and val.size == 1:
            val = val.reshape(()).item()
        res = mb.const(val=dtype(val), name=node.name)
    elif len(x.shape) > 0:
        squeezed = mb.squeeze(x=x, name=node.name + "_item")
        res = mb.cast(x=squeezed, dtype=dtype_name, name=node.name)
    else:
        res = mb.cast(x=x, dtype=dtype_name, name=node.name)
    context.add(res, node.name)


tops._cast = _cast_patched

# nn.MultiheadAttention traces into the fused _native_multi_head_attention op,
# which no converter implements. The unfused path is numerically identical.
torch.backends.mha.set_fastpath_enabled(False)

from demucs.pretrained import get_model


class Core(nn.Module):
    """htdemucs with both transforms lifted out: (mag, mix) -> (spec, xt).

    `_spec`/`_magnitude` are replaced by the caller-supplied real spectrogram,
    and `_mask`/`_ispec` are cut so no complex op reaches the graph. Everything
    between — encoders, cross-transformer, decoders, the normalisation and its
    inverse — is untouched, which is why the outputs match torch exactly.
    """

    def __init__(self, model):
        super().__init__()
        self.model = model
        self.stash = {}

    def forward(self, mag, mix):
        m, stash = self.model, self.stash
        saved = (m._spec, m._magnitude, m._mask, m._ispec)
        m._spec = lambda x: None                      # z is unused downstream in cac mode
        m._magnitude = lambda z: mag
        m._mask = lambda z, x: (stash.__setitem__("spec", x), x)[1]
        m._ispec = lambda z, length=None, scale=0: torch.zeros(
            mag.shape[0], 4, m.audio_channels, length, dtype=mag.dtype, device=mag.device)
        try:
            xt = m(mix)
        finally:
            m._spec, m._magnitude, m._mask, m._ispec = saved
        return stash["spec"], xt


def main():
    bag = get_model("htdemucs")
    model = (bag.models[0] if hasattr(bag, "models") else bag).eval()
    model.use_train_segment = False
    seg = int(model.segment * model.samplerate)     # 343980
    print(f"sources={model.sources} sr={model.samplerate} nfft={model.nfft} "
          f"hop={model.hop_length} segment={seg}")

    torch.manual_seed(0)
    audio = torch.randn(1, model.audio_channels, seg) * 0.1

    with torch.no_grad():
        z = model._spec(audio)                      # complex64 [1, 2, 2048, 336]
        mag = model._magnitude(z)                   # real      [1, 4, 2048, 336]

    core = Core(model).eval()
    with torch.no_grad():
        ref_spec, ref_xt = core(mag, audio)
        traced = torch.jit.freeze(torch.jit.trace(core, (mag, audio), check_trace=False))

    kinds = {}
    for n in traced.graph.nodes():
        kinds[n.kind()] = kinds.get(n.kind(), 0) + 1
    bad = {k: v for k, v in kinds.items()
           if any(s in k for s in ("stft", "complex", "view_as"))}
    assert not bad, f"complex-domain ops still in graph: {bad}"

    ml = ct.convert(
        traced,
        inputs=[ct.TensorType(name="mag", shape=tuple(mag.shape), dtype=np.float32),
                ct.TensorType(name="audio", shape=tuple(audio.shape), dtype=np.float32)],
        outputs=[ct.TensorType(name="spec"), ct.TensorType(name="waveform")],
        minimum_deployment_target=ct.target.iOS18,
        # FLOAT16 produces NaN in the spectral branch. Do not change without
        # re-running the verification below.
        compute_precision=ct.precision.FLOAT32,
        convert_to="mlprogram")
    ml.save(str(HERE / "HTDemucsCore.mlpackage"))

    out = ml.predict({"mag": mag.numpy().astype(np.float32),
                      "audio": audio.numpy().astype(np.float32)})
    ok = True
    for name, ref in (("spec", ref_spec), ("waveform", ref_xt)):
        got = torch.from_numpy(np.asarray(out[name], dtype=np.float32)).reshape(ref.shape)
        d = (got - ref).abs().max().item()
        rms = ref.pow(2).mean().sqrt().item()
        print(f"{name}: max|d| {d:.3e}  rms {rms:.3e}  -> {'PASS' if d <= 1e-4 else 'FAIL'}")
        ok &= d <= 1e-4
    if not ok:
        raise SystemExit("numeric verification failed")

    # Golden vectors for the Swift transform tests (task S2).
    torch.save({"audio": audio, "mag": mag, "spec": ref_spec, "xt": ref_xt,
                "ispec": model._ispec(model._mask(None, ref_spec), seg)},
               HERE / "reference.pt")
    print("saved HTDemucsCore.mlpackage + reference.pt")


if __name__ == "__main__":
    main()
