# Phase 9 — GPL/LGPL-only backends used by this app, not by PAE

Platterhead DJ (`parso-tonearm`) is GPLv3-or-later (see `LICENSE`) with an
App Store distribution exception. Being under a copyleft license itself,
this app can use libraries that PAE (MIT, shared with other apps) must not
depend on. Both swaps below go through a seam PAE declares and this app
implements — PAE's own `ParsoAudioCore`/`ParsoAudioNeural` targets gain no
new dependency and ship identically for every other consumer.

## MP3 encoding: LAME (LGPL-2.1)

PAE's `AudioFileWriter` calls its own MIT/from-scratch Glint encoder for
`.mp3` codecs unless given an `mp3Encoder: (any MP3Encoding)`
(`docs/BYO-CODEC.md` in `parso-audio-engine`, the seam this follows exactly).
This app supplies `LAMEEncoder` (`Sources/CLAMEBridge`, `Sources/DJ/Encoding`)
— see that target's own header comment for the vendored LAME version and
where it came from; `ATTRIBUTION.md` records the same.

## Stem separation: Demucs is the active backend, not Spleeter

`StemSeparationBackends.makeRegistry` (`Sources/DJ/Stems/StemSeparationBackends.swift`)
registers both `SpleeterStemModel` and `DemucsStemModel` and, as of this
phase, makes **Demucs the active default** for this app.

This is a deliberate change from PAE's own recommended stance. PAE's
README ("On-device neural" survey) documents a real, on-record licensing
concern with Demucs's pretrained weights: Meta's own maintainers have
stated the released `htdemucs` weights are "not covered by the MIT
license, and are provided only for scientific purposes"
([facebookresearch/demucs#327](https://github.com/facebookresearch/demucs/issues/327)),
and the training data (MUSDB18/MUSDB18-HQ) is itself academic-use-only with
some tracks CC BY-NC-SA. PAE's default stays Spleeter for exactly this
reason, and nothing in this document changes that — PAE's stance is
unaffected by this app's choice.

The decision to activate Demucs in this app regardless, and to secure
whatever license or clearance that requires for shipping it commercially
(a different weights source, a commercial license, retraining on
appropriately-licensed data, or a legal opinion that the intended use is
covered), is the author's own and was made independently of this
documentation. This file exists to record the change and point back at the
PAE-side finding it deliberately diverges from — not to assert that the
divergence has been legally cleared. `SpleeterStemModel` remains registered
so the backend can be switched back (`registry.setActive(.spleeter)`)
without any other code change if that determination changes.
