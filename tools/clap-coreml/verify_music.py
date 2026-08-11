#!/usr/bin/env python3
"""Verify Core ML music-CLAP encoders against the official laion_clap reference."""
import numpy as np
import torch
import torch.nn.functional as F
import coremltools as ct

import laion_clap

CKPT = "clap/music_audioset_epoch_15_esc_90.14.pt"
OUT = "out-music"

torch.set_grad_enabled(False)
clap = laion_clap.CLAP_Module(enable_fusion=False, amodel="HTSAT-base", device="cpu")
clap.load_ckpt(CKPT)
m = clap.model
for p in m.parameters():
    p.requires_grad_(False)
for b in m.buffers():
    b.requires_grad_(False)
m.eval()
h = m.audio_branch
# torchlibrosa builds the frontend in float64; run it in float32 for verification.
h.spectrogram_extractor.float()
h.logmel_extractor.float()

# finite mask to match the conversion
import types


def _mask(self, attention_mask, input_shape, device=None, dtype=None):
    if dtype is None:
        dtype = self.dtype
    extended = (attention_mask[:, None, None, :] if attention_mask.dim() == 2
                else attention_mask[:, None, :, :])
    extended = extended.to(dtype=dtype)
    return (1.0 - extended) * torch.tensor(-10000.0, dtype=dtype)


m.text_branch.get_extended_attention_mask = types.MethodType(_mask, m.text_branch)


def ref_logmel(waveform: np.ndarray) -> np.ndarray:
    """Exact frontend from the model's own Spectrogram + LogmelFilterBank."""
    w = torch.from_numpy(waveform.astype(np.float32)).unsqueeze(0)
    if w.shape[1] < 480000:
        n = 480000 // w.shape[1]
        w = w.repeat(1, n)
    w = F.pad(w, (0, 480000 - w.shape[1]), mode="constant", value=0)
    sp = h.spectrogram_extractor(w)                       # (1, 1, 1001, 513)
    lm = h.logmel_extractor(sp)                           # (1, 1, 1001, 64)
    return lm.numpy().astype(np.float32)


def ref_audio_emb(logmel: np.ndarray) -> np.ndarray:
    x = torch.from_numpy(logmel).transpose(1, 3)
    x = h.bn0(x)
    x = x.transpose(1, 3)
    x = h.reshape_wav2img(x)
    out = h.forward_features(x)
    return F.normalize(m.audio_projection(out["embedding"]), dim=-1).numpy()


def ref_text_emb(text: str) -> np.ndarray:
    inp = clap.tokenizer(text)
    pooled = m.text_branch(input_ids=inp["input_ids"],
                           attention_mask=inp["attention_mask"])["pooler_output"]
    return F.normalize(m.text_projection(pooled), dim=-1).numpy()


audio_cm = ct.models.MLModel(f"{OUT}/CLAPAudioEncoder.mlpackage", compute_units=ct.ComputeUnit.CPU_ONLY)
text_cm = ct.models.MLModel(f"{OUT}/CLAPTextEncoder.mlpackage", compute_units=ct.ComputeUnit.CPU_ONLY)

rng = np.random.default_rng(7)
sr = 48000


def kick():
    t = np.zeros(sr * 10)
    for i in range(20):
        s = int(i * sr / 2)
        env = np.exp(-np.arange(sr // 5) / (sr * 0.03))
        t[s:s + sr // 5] += np.sin(2 * np.pi * 50 * np.arange(sr // 5) / sr) * env
    return t + 0.1 * np.sin(2 * np.pi * 110 * np.arange(len(t)) / sr)


def pad():
    t = np.zeros(sr * 10)
    for i in range(0, sr * 10, sr * 2):
        for f in (196, 246, 293):
            t[i:i + sr * 2] += 0.3 * np.sin(2 * np.pi * f * np.arange(sr * 2) / sr)
    return t


print("=== AUDIO encoder match ===")
sig = {"kick": kick(), "pad": pad(),
       "noise": 0.5 * rng.standard_normal(sr * 10),
       "sine": np.sin(2 * np.pi * 220 * np.arange(sr * 10) / sr),
       "silence": np.zeros(sr * 10)}
for name, s in sig.items():
    s = s / (np.max(np.abs(s)) + 1e-9)
    lm = ref_logmel(s)
    ref = ref_audio_emb(lm)[0]
    got = audio_cm.predict({"log_mel": lm})["audio_embedding"][0]
    print(f"  {name:8s} cosine={float(np.dot(ref, got)):.6f} maxdiff={float(np.max(np.abs(ref-got))):.6f}")

print("=== TEXT encoder match ===")
for t in ["dark driving bassline", "warm ambient pad chords", "harsh white noise"]:
    ref = ref_text_emb(t)[0]
    inp = clap.tokenizer(t)
    got = text_cm.predict({"input_ids": inp["input_ids"].numpy().astype(np.int32),
                           "attention_mask": inp["attention_mask"].numpy().astype(np.int32)})["text_embedding"][0]
    print(f"  {t!r:30s} cosine={float(np.dot(ref, got)):.6f} maxdiff={float(np.max(np.abs(ref-got))):.6f}")

print("=== Cross-modal retrieval through Core ML ===")
with torch.no_grad():
    aemb = {k: audio_cm.predict({"log_mel": ref_logmel(v / (np.max(np.abs(v)) + 1e-9))})["audio_embedding"][0]
            for k, v in sig.items()}
queries = ["four on the floor kick drum", "warm ambient pad chords", "harsh white noise", "complete silence"]
temb = []
for q in queries:
    inp = clap.tokenizer(q)
    temb.append(text_cm.predict({"input_ids": inp["input_ids"].numpy().astype(np.int32),
                                 "attention_mask": inp["attention_mask"].numpy().astype(np.int32)})["text_embedding"][0])
print(f"{'query':30s} kick     pad    noise silence")
for qi, q in enumerate(queries):
    print(f"{q:30s} " + " ".join(f"{float(np.dot(temb[qi], aemb[k])):7.3f}" for k in sig))
