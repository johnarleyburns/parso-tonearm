#!/usr/bin/env python3
"""Regenerate the Swift frontend test fixtures from the official CLAP frontend.

Dumps what `Preprocess` must reproduce (all float32, matching the model's own
frontend after `spectrogram_extractor.float()` / `logmel_extractor.float()`):

  Tests/DJTests/Fixtures/mel_filterbank_slaney_64.bin   (513,64) f32, row-major
  Tests/DJTests/Fixtures/synth_pcm_f32.bin              (120000,) f32 mono @48k
  Tests/DJTests/Fixtures/synth_logmel_golden_f32.bin    (1001,64) f32 log-mel
  Tests/DJTests/Fixtures/text_tokenizer_golden.json     RoBERTa ids/mask for a
                                                          few phrases

The synthetic waveform is a pure closed-form sum of sines so it is reproducible
in Swift; the golden log-mel is computed by the model's own Spectrogram +
LogmelFilterBank (periodic Hann, reflect pad 512, 1001 frames, slaney mel).
Run from the temp workdir with the `clap-venv` activated:
  python tools/clap-coreml/golden_frontend.py
"""
import json
from pathlib import Path

import numpy as np
import torch

import laion_clap

REPO = Path(__file__).resolve().parent.parent.parent
FIX = REPO / "Tests" / "DJTests" / "Fixtures"
FIX.mkdir(parents=True, exist_ok=True)
CKPT = Path("clap/music_audioset_epoch_15_esc_90.14.pt")

torch.set_grad_enabled(False)
clap = laion_clap.CLAP_Module(enable_fusion=False, amodel="HTSAT-base", device="cpu")
clap.load_ckpt(str(CKPT))
m = clap.model
for p in m.parameters():
    p.requires_grad_(False)
m.eval()
h = m.audio_branch
h.spectrogram_extractor.float()
h.logmel_extractor.float()

sr = 48000
# 2.5 s closed-form waveform: a gated mix of sines across the mel range.
t = np.arange(sr * 5 // 2) / sr
s = (0.8 * np.sin(2 * np.pi * 55 * t)
     + 0.5 * np.sin(2 * np.pi * 165 * t)
     + 0.4 * np.sin(2 * np.pi * 440 * t)
     + 0.25 * np.sin(2 * np.pi * 2000 * t)
     + 0.15 * np.sin(2 * np.pi * 8000 * t))
s *= 0.5 + 0.5 * np.sin(2 * np.pi * 2 * t)
s = s / (np.max(np.abs(s)) + 1e-9)


def ref_logmel(waveform: np.ndarray) -> np.ndarray:
    w = torch.from_numpy(waveform.astype(np.float32)).unsqueeze(0)
    if w.shape[1] < 480000:
        n = 480000 // w.shape[1]
        w = w.repeat(1, n)
    w = torch.nn.functional.pad(w, (0, 480000 - w.shape[1]), mode="constant", value=0)
    sp = h.spectrogram_extractor(w)
    lm = h.logmel_extractor(sp)
    return lm.numpy().astype(np.float32)


melw = h.logmel_extractor.melW.detach().numpy().astype(np.float32)
assert melw.shape == (513, 64)
melw.tofile(FIX / "mel_filterbank_slaney_64.bin")

# The tokenizer tables are bundled in Resources/CLAP; the tests get hermetic copies.
for name in ("vocab.json", "merges.txt"):
    (FIX / name).write_bytes((REPO / "Resources" / "CLAP" / name).read_bytes())

s.astype(np.float32).tofile(FIX / "synth_pcm_f32.bin")

lm = ref_logmel(s)[0, 0]
assert lm.shape == (1001, 64)
lm.astype(np.float32).tofile(FIX / "synth_logmel_golden_f32.bin")

golden = {}
for phrase in ["dark driving bassline", "warm ambient pad chords", "harsh white noise"]:
    inp = clap.tokenizer(phrase)
    golden[phrase] = {
        "ids": inp["input_ids"].numpy().astype(int).tolist(),
        "mask": inp["attention_mask"].numpy().astype(int).tolist(),
    }
(FIX / "text_tokenizer_golden.json").write_text(json.dumps(golden, indent=2))

print("wrote fixtures to", FIX)
print("log-mel range", float(lm.min()), float(lm.max()))
for phrase, g in golden.items():
    print(f"  {phrase!r:28s} ids[:7]={g['ids'][:7]} mask={g['mask'][:7]}")
