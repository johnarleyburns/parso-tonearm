# CLAP → Core ML conversion (M2)

Reproduces the on-device semantic models that ship behind the ODR tags `clap-audio` /
`clap-text`.

## Source model

- Checkpoint: `lukewys/laion_clap` → `music_audioset_epoch_15_esc_90.14.pt` (HTSAT-base,
  official `laion_clap` codebase, **Apache-2.0**).
- Tokenizer: RoBERTa (vocab 50265, max length 77). `vocab.json` + `merges.txt` live in
  `Resources/CLAP/`.
- The HF port (`laion/larger_clap_music`) is **not** used: its text branch is degenerate
  (wrong `num_hidden_layers`), verified by degenerate text-text pair-wise cosine.

## Artifacts

| File | Size | Location |
|---|---|---|
| `CLAPAudioEncoder.mlpackage` | 137 MB (FP16) | `Resources/Models/`, ODR `clap-audio` |
| `CLAPTextEncoder.mlpackage` | 240 MB (FP16) | `Resources/Models/`, ODR `clap-text` |
| `mel_filterbank_slaney_64.bin` | 132 KB | `Resources/CLAP/` (bundled) |
| `vocab.json` / `merges.txt` | 0.5 / 1.5 MB | `Resources/CLAP/` (bundled) |

Model spec (`model_spec.json` output) is the authoritative `EmbeddingModelSpec`: sample rate
48000, 10 s window, 480000 clip samples, FFT 1024, hop 480, 64 mel bins (librosa **slaney**,
50–14000 Hz), 1001 frames, 512-dim L2-normalized embeddings, text max length 77.

## Regenerate

```sh
# workdir with: clap/<checkpoint>.pt clap/vocab.json clap/merges.txt
python -m venv .venv && .venv/bin/pip install torch==2.7.0 torchvision transformers==4.57.6 \
    coremltools==9.0 laion-clap librosa torchlibrosa
.venv/bin/python convert_music.py   # writes out-music/ (mlpackages + spec + mel filterbank)
.venv/bin/python verify_music.py    # cosine vs PyTorch reference; cross-modal retrieval
```

Notes on the conversion (`convert_music.py`):
- coremltools 9 rejects `torch.jit.trace` → uses `torch.export.export(...).run_decompositions()`.
- `fmod` is rewritten to `x - d*floor(x/d)` via an fx pass (int operands cast through fp32).
- The finite text attention mask (`-10000`) is patched onto
  `text_branch.get_extended_attention_mask` (coremltools NaNs on `torch.finfo.min`).
- Audio model converted with `compute_units = CPU_AND_GPU` (HTSAT ops are not ANE-compilable);
  text with `ALL`. Both FP16.
- The STFT/mel frontend (mel filterbank + hann + DFT) lives in Swift (vDSP), not in the model;
  `verify_music.py` pins the exact Swift contract (repeatpad → reflect pad 512 → 1001 frames →
  `hann_symmetric` 1024 → power spectrum → mel → `10*log10`).

## Verification status

Audio encoder cosine ≥ 0.9997 (vs PyTorch reference), text encoder ≥ 0.9999, cross-modal
retrieval through the Core ML models intact (kick → 0.213, pad → 0.163, noise → 0.478).
