#!/usr/bin/env python3
"""Convert the official LAION-CLAP music checkpoint to Core ML.

Model: music_audioset_epoch_15_esc_90.14.pt (HTSAT-base, laion_clap, Apache-2.0).
The HF transformers conversion (laion/larger_clap_music) is NOT used: its text
branch is degenerate (wrong layer count), so we build from the original codebase.

Two Core ML models:
  CLAPAudioEncoder.mlpackage
      input  log_mel (1,1,1001,64) fp32   — CLAP "Spectrogram + LogmelFilterBank"
                                             output, i.e. 10*log10(clamp(mel,1e-10))
                                             with librosa slaney mel (48k, 1024/480,
                                             64 bins, 50-14000 Hz), (time,mels) layout.
      output audio_embedding (1,512) fp32  — HTSAT forward_features -> audio_projection
                                             -> L2 norm.
      (bn0 + reshape_wav2img + HTSAT Swin are inside the model; only the STFT/mel
       frontend lives in Swift — vDSP, exact per the spec below.)

  CLAPTextEncoder.mlpackage
      inputs input_ids (1,77) int32, attention_mask (1,77) int32
      output text_embedding (1,512) fp32   — RoBERTa pooler -> text_projection -> L2 norm.

Side outputs:
  mel_filterbank_slaney_64.bin  (513,64) fp32 — the model's own librosa slaney melW,
                                                for the Swift frontend.
  model_spec.json               the Swift EmbeddingModelSpec.

Swift Preprocess contract (audio):
  1. mono 48k window -> repeatpad to 480000 samples
  2. reflect-pad by 512 (numpy reflect semantics)
  3. 1001 frames: frame[t] = pad[t*480 : t*480+1024] * hann_symmetric(1024)
       hann_symmetric[n] = 0.5*(1 - cos(2*pi*n/1023))   (librosa get_window hann fftbins=True)
  4. power[k,t] = |DFT(frame)|^2  (n_fft 1024 -> 513 bins)
  5. mel = power.T @ melW                      -> (1001, 64)
  6. logmel = 10*log10(max(mel, 1e-10))        -> (1,1,1001,64)
"""
import json
import sys
import warnings
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as F

import laion_clap

warnings.filterwarnings("ignore")

CKPT = Path("clap/music_audioset_epoch_15_esc_90.14.pt")
OUT = Path("out-music")
OUT.mkdir(exist_ok=True)

import coremltools as ct


def replace_fmod(ep):
    """coremltools lacks fmod; rewrite fmod(x,d) -> x - d*floor(x/d) (x>=0)."""
    graph = ep.graph_module.graph
    nodes = [n for n in graph.nodes
             if n.op == "call_function" and "fmod" in str(n.target)]
    for n in nodes:
        x, divisor = n.args[0], n.args[1]
        val = x.meta.get("val")
        is_int = val is not None and val.dtype in (torch.int32, torch.int64,
                                                   torch.int16, torch.int8)
        with graph.inserting_before(n):
            if is_int:
                xf = graph.call_function(torch.ops.aten._to_copy.default,
                                         (x,), {"dtype": torch.float32})
            else:
                xf = x
            d = graph.call_function(torch.ops.aten.div.Tensor, (xf, divisor))
            fl = graph.call_function(torch.ops.aten.floor.default, (d,))
            qm = graph.call_function(torch.ops.aten.mul.Tensor, (fl, divisor))
            r = graph.call_function(torch.ops.aten.sub.Tensor, (xf, qm))
            if is_int:
                r = graph.call_function(torch.ops.aten._to_copy.default,
                                        (r,), {"dtype": val.dtype})
        n.replace_all_uses_with(r)
        graph.erase_node(n)
    if nodes:
        graph.lint()
        ep.graph_module.recompile()
    return ep


def finite_text_mask(model):
    """coremltools NaNs on torch.finfo(dtype).min; use -10000 (fp16-safe)."""
    import types

    def _mask(self, attention_mask, input_shape, device=None, dtype=None):
        if dtype is None:
            dtype = self.dtype
        if attention_mask.dim() == 2 and not self.config.is_decoder:
            extended = attention_mask[:, None, None, :]
        elif attention_mask.dim() == 3:
            extended = attention_mask[:, None, :, :]
        else:
            raise ValueError(f"unexpected attention_mask shape {tuple(attention_mask.shape)}")
        extended = extended.to(dtype=dtype)
        return (1.0 - extended) * torch.tensor(-10000.0, dtype=dtype)

    model.text_branch.get_extended_attention_mask = types.MethodType(_mask, model.text_branch)
    return model


def main():
    clap = laion_clap.CLAP_Module(enable_fusion=False, amodel="HTSAT-base", device="cpu")
    clap.load_ckpt(str(CKPT))
    m = clap.model
    for p in m.parameters():
        p.requires_grad_(False)
    for b in m.buffers():
        b.requires_grad_(False)
    m.eval()
    finite_text_mask(m)
    print("model loaded:", m.text_branch_type)

    # ---- dump the model's own mel filterbank for Swift ----
    melw = m.audio_branch.logmel_extractor.melW.detach().numpy().astype(np.float32)
    assert melw.shape == (513, 64)
    melw.tofile(OUT / "mel_filterbank_slaney_64.bin")
    print("wrote mel_filterbank_slaney_64.bin", melw.shape)

    # ---- audio encoder: log-mel -> embedding ----
    htsat = m.audio_branch

    class AudioEmbed(torch.nn.Module):
        def __init__(self, h, proj):
            super().__init__()
            self.h = h
            self.proj = proj

        def forward(self, log_mel):
            x = log_mel.transpose(1, 3)
            x = self.h.bn0(x)
            x = x.transpose(1, 3)
            x = self.h.reshape_wav2img(x)
            out = self.h.forward_features(x)
            emb = self.proj(out["embedding"])
            return F.normalize(emb, dim=-1)

    audio_in = torch.rand(1, 1, 1001, 64)
    audio_ep = torch.export.export(
        AudioEmbed(htsat, m.audio_projection).eval(), (audio_in,), strict=True)
    audio_ep = replace_fmod(audio_ep.run_decompositions())
    print("audio exported", len(audio_ep.graph_module.graph.nodes), "nodes")

    # ---- text encoder: ids -> embedding ----
    class TextEmbed(torch.nn.Module):
        def __init__(self, tb, proj):
            super().__init__()
            self.tb = tb
            self.proj = proj

        def forward(self, input_ids, attention_mask):
            pooled = self.tb(input_ids=input_ids,
                             attention_mask=attention_mask)["pooler_output"]
            return F.normalize(self.proj(pooled), dim=-1)

    ids = torch.randint(3, 50000, (1, 77), dtype=torch.int64)
    mask = torch.ones(1, 77, dtype=torch.int64)
    text_ep = torch.export.export(
        TextEmbed(m.text_branch, m.text_projection).eval(), (ids, mask), strict=True)
    text_ep = replace_fmod(text_ep.run_decompositions())
    print("text exported", len(text_ep.graph_module.graph.nodes), "nodes")

    # ---- convert ----
    min_ios = ct.target.iOS17
    audio_model = ct.convert(
        audio_ep,
        inputs=[ct.TensorType(name="log_mel", shape=(1, 1, 1001, 64), dtype=np.float32)],
        outputs=[ct.TensorType(name="audio_embedding")],
        convert_to="mlprogram",
        compute_units=ct.ComputeUnit.CPU_AND_GPU,   # HTSAT not ANE-compilable
        minimum_deployment_target=min_ios,
        source="pytorch",
    )
    audio_model.compute_precision = ct.precision.FLOAT16
    audio_model.save(OUT / "CLAPAudioEncoder.mlpackage")
    print("saved CLAPAudioEncoder.mlpackage")

    text_model = ct.convert(
        text_ep,
        inputs=[
            ct.TensorType(name="input_ids", shape=(1, 77), dtype=np.int32),
            ct.TensorType(name="attention_mask", shape=(1, 77), dtype=np.int32),
        ],
        outputs=[ct.TensorType(name="text_embedding")],
        convert_to="mlprogram",
        compute_units=ct.ComputeUnit.ALL,
        minimum_deployment_target=min_ios,
        source="pytorch",
    )
    text_model.compute_precision = ct.precision.FLOAT16
    text_model.save(OUT / "CLAPTextEncoder.mlpackage")
    print("saved CLAPTextEncoder.mlpackage")

    # ---- dump spec for Swift ----
    spec = {
        "modelName": "music_audioset_epoch_15_esc_90.14",
        "dimensions": 512,
        "audio": {
            "sampleRate": 48000,
            "windowSeconds": 10.0,
            "clipSamples": 480000,
            "nFft": 1024,
            "hopLength": 480,
            "melBins": 64,
            "frequencyMin": 50.0,
            "frequencyMax": 14000.0,
            "frames": 1001,
            "inputName": "log_mel",
            "outputName": "audio_embedding",
            "melFilterBankFile": "mel_filterbank_slaney_64.bin",
            "padMode": "repeatpad",
        },
        "text": {
            "maxLength": 77,
            "inputIdsName": "input_ids",
            "attentionMaskName": "attention_mask",
            "outputName": "text_embedding",
            "vocabFile": "vocab.json",
            "mergesFile": "merges.txt",
        },
    }
    (OUT / "model_spec.json").write_text(json.dumps(spec, indent=2))
    print("wrote model_spec.json")


if __name__ == "__main__":
    main()
