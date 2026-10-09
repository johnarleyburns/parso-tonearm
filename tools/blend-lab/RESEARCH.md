# Flam-free automatic beatmatched transitions: research notes for Platterhead

Written 2026-10-08 for the blend-lab / iOS transition executor work. Each section separates
**Fact** (with a source) from **Inference** (my reading, which still needs testing in the lab).

---

## Executive summary

1. **Even the best beat trackers do not place beats precisely enough to layer two kicks.** madmom
   runs at 100 fps (10 ms frames). Beat This! and BeatNet run at 50 fps (20 ms). Essentia's Degara
   tracker uses a 1024-sample hop at 44.1 kHz (23 ms). They are all scored with a ±70 ms tolerance
   window. Hearing two kicks as one needs about 5 ms or better, so **no tracker's grid can be used
   as the final phase.** Pro DJ software gets around this with user-corrected grids. An automatic
   system has to add a second step: **refine the phase against the kick itself in the low band, to
   sub-millisecond precision.** Vande Veire & De Bie's open-source Auto-DJ does this with a 1 ms
   phase search over an onset function on a constant-tempo grid.
2. **The 20–30 ms flam is the right size for three error sources the lab has not ruled out yet:**
   - **WSOLA time-stretch jitter.** `blend.py` stretches with ffmpeg `atempo`. Its 2048-sample
     window searches ±1024 samples (±23 ms) for each splice point, so a kick in the stretched track
     can land up to about ±23 ms from `t / ratio`, or be doubled.
   - **Decoder priming.** The LAME delay is about 1105 samples (25 ms at 44.1 kHz). AAC priming
     is 2112 samples (48 ms). Mixxx's rekordbox importer applies exactly these 12/13/26/50 ms
     (MP3) and 48 ms (CoreAudio m4a) corrections.
   - **Per-track grid-to-kick offsets.** These come from the coarse analyser and are measured in
     `gridcheck`, but nothing compensates for them.
3. **How DJ software actually does it:**
   - Match tempo once, with keylock on.
   - **Jump** (seek) to the right phase when the deck starts or sync is engaged (Mixxx's
     `getNearestPositionInPhase`).
   - Keep the phase with a **small proportional rate controller** (Mixxx `BpmControl::calcSyncAdjustment`).
   - That controller compares **grid to grid**, never audio to audio. If the grid is wrong, sync
     locks the decks perfectly onto the wrong phase. The human corrects that by ear, and Mixxx
     stores the correction as a "user offset".
4. **The owner's plan (tempo once with keylock, then gradual nudging) is sound if three things hold:**
   - **The phase error is measured from the audio**, i.e. low-band onset cross-correlation of what
     will actually be played. It must not come from AVPlayer clock readings or grid-to-grid
     differences.
   - **Most of the offset is removed before the incoming track is audible**, by the scheduled start
     sample. Nudging is only for residual drift. A rate nudge small enough to be inaudible
     (≤0.2 %) takes about 5 s to remove 10 ms.
   - **Both tracks run in one sample-locked engine** (AVAudioEngine, or an offline render), so the
     only drift left is musical drift and tempo-estimate error. Two AVPlayers each have their own
     timeline. A controller that chases their reported positions is chasing measurement noise
     (this is a likely cause of the "volume up and down every second" symptom).
5. **Error budget:**
   - **≤ 5 ms p95** kick asynchrony while both drum parts are audible.
   - **≤ 2–3 ms** if both full basses are ever summed. At 50–60 Hz, a 5 ms offset is about 90° of
     phase and 8–10 ms is close to cancellation. A bass swap avoids this case.
   - **> 10 ms** is a hard failure, heard as a flam or a doubled kick.
   - **Tempo accuracy:** a 96-beat overlap at 124 BPM lasts 46 s. To drift ≤ 2 ms over it, the
     tempo ratio must be right to **4×10⁻⁵** (±0.005 BPM). That means storing per-beat times in
     samples, or a BPM to at least 4 decimals fitted by regression over the whole steady section.

### Top recommendations (prioritised)

1. **Finish the time-base fix**, then **store a sub-ms "kick phase" per track.** Fold a 1 ms-hop
   (or sample-rate) low-band onset envelope onto the fitted grid and interpolate the peak with a
   parabola. Analyse with the **same decoder and priming handling as playback** (AVAudioFile /
   ExtAudioFile on iOS, which trims AAC priming per TN2258). Record the decoder used in the
   analysis ID.
2. **Replace `atempo` in the lab with a phase-vocoder stretcher that preserves transients.** Use
   Rubber Band R3 offline, or render with Apple's own `AVAudioUnitTimePitch` in AVAudioEngine
   manual-rendering mode so the lab hears exactly what the phone will play. **Measure kick
   positions on the stretched audio** instead of assuming `t / ratio`.
3. **Per transition, before anything is audible:** cross-correlate the low-band onset envelope of
   the outgoing overlap region with the stretched incoming region. **Correct the scheduled entry
   sample by that lag.** Fit the slope of lag against time over the overlap to correct the tempo
   ratio. Verify the downbeat (bar phase) at the bass-swap point separately.
4. **On iOS, use one AVAudioEngine:** two `AVAudioPlayerNode`s, each feeding an
   `AVAudioUnitTimePitch`, into one mixer. Start both with `AVAudioTime` sample times on the same
   clock, and compensate the TimePitch latency (`auAudioUnit.latency`; about 90 ms has been
   reported). Gain ramps go in the render path (a mixer or per-buffer ramp), not in 0.5 s steps.
5. **Use continuous nudging only as a slow, capped PLL on audio-measured error:**
   - 1 ms deadband.
   - Rate cap ±0.2 %.
   - Slew limit.
   - Measured on the engine's own render (install a tap).
   - For tracks with real tempo variation, prefer **feed-forward per-beat warping** (beat map →
     time map) over feedback.

---

## 1. How DJ software handles tempo sync, phase sync and drift

### 1.1 Mixxx (open source; read from `mixxxdj/mixxx` `main`, Oct 2026)

**Facts, from the source:**

**Main source files:**

| Area | Files / classes |
|---|---|
| Sync engine (leader/follower, internal clock) | `src/engine/sync/enginesync.cpp`, `synccontrol.cpp`, `internalclock.cpp`, `syncable.h` |
| Tempo and phase control per deck | `src/engine/controls/bpmcontrol.cpp` (`BpmControl`) |
| Quantize | `src/engine/controls/quantizecontrol.cpp` |
| Beat grid data | `src/track/beats.cpp` (`mixxx::Beats`, made of constant-tempo "markers"), `src/track/beatutils.cpp`, `beatfactory.cpp` |
| Analysis | `src/analyzer/analyzerbeats.cpp`, plugins `analyzerqueenmarybeats.cpp` (QM-DSP tracker, Davies & Plumbley) and `analyzersoundtouchbeats.cpp` |
| Keylock / time-stretch | `src/engine/bufferscalers/enginebufferscalerubberband.cpp`, `rubberbandwrapper.cpp`, `enginebufferscalest.cpp` (SoundTouch), `enginebufferscalelinear.cpp` (no keylock) |
| Grids imported from other apps | `src/library/rekordbox/rekordboxfeature.cpp`, `src/track/serato/beatgrid.cpp` |

**Analysis** (`analyzerqueenmarybeats.cpp`, `beatutils.cpp`):

- The QM detector's step is `kStepSecs = 0.01161` (512 samples at 44.1 kHz). The code comment:
  *"Single beats have a jitter of +-12 ms around the actual position."*
- `BeatUtils::retrieveConstRegions` / `makeConstBpm` "iron" that jitter. They find long
  constant-tempo regions, which allow at most `kMaxSecsPhaseError = 0.025` s per beat and
  `kMaxSecsPhaseErrorSum = 0.1` s, with `kMinRegionBeatCount = 16`. The BPM is then snapped to a
  round value (`roundBpmWithinRange`: integer, then ½, then 1/12 BPM), and a constant grid is
  built.
- `adjustPhase` averages the offsets of detected beats that fall within ±25 ms of the grid.
- The "fixed tempo assumption" is on by default (`m_bPreferencesFixedTempo(true)`).
- The code comment calls 25 ms *"inaudible"*. That is for grid ironing. It is **not** a layering
  tolerance (see §3.4).

**Phase sync on engage or play** (`BpmControl::getNearestPositionInPhase` / `getPhaseOffset`):
the follower **seeks**. It computes this deck's position so that its beat fraction (0–1 between
grid beats) equals the leader's, plus `m_dUserOffset`. There is special handling for "pushed
sync late/early" (choosing the next, previous, or the one before).

**Holding phase while playing** (`BpmControl::calcSyncedRate` → `calcSyncAdjustment`):

- This runs only when quantize is on and both decks have beats.
- It is a **proportional rate controller**. The error is the shortest beat-fraction difference
  between leader and follower.
- Constants:
  - `kErrorThreshold = 0.01` beat: deadband, about 5 ms at 120 BPM.
  - `kSyncAdjustmentProportional = 0.7`.
  - `kSyncDeltaCap = 0.02`: slew limit per callback.
  - `kSyncAdjustmentCap = 0.05`: ±5 % rate.
  - `kTrainWreckThreshold = 0.2` beat: above this it just speeds up 5 % to catch up.
- **The error is computed from the grids** (`m_dSyncTargetBeatDistance` vs `m_pThisBeatDistance`).
  Mixxx never listens to the audio to check alignment.

**User offset:**

- If the user nudges while synced, `calcSyncAdjustment` stores the current error as
  `m_dUserOffset`. The controller then holds the human-chosen offset instead of fighting it.
- `beats_translate_earlier/later` shift the grid in small steps. Reading `slotTranslateBeatsMove`
  (`sampleRate * 0.01` samples ÷ 2 channels), that is about 5 ms per press.
- `beats_translate_match_alignment` writes the current by-ear offset into the grid permanently.
  This is the human version of "refine the phase against audio once, store it".

**Keylock and latency** (`enginebufferscalerubberband.cpp`):

- Runs `RubberBandStretcher::OptionProcessRealTime`, optionally `OptionEngineFiner` (R3) with
  `OptionChannelsTogether`, and optionally `OptionWindowShort`.
- On reset it **pads the input with `getPreferredStartPad()` and drops `getStartDelay()` output
  samples** (PR #11120), so the stretched output is time-aligned with the source position.
- The SoundTouch scaler sets `SETTING_USE_QUICKSEEK`.

**Decoder offsets** (`rekordboxfeature.cpp`, PR #2119):

- Rekordbox cue and beat times are shifted per MP3 "timing shift case", detected by
  `mp3guessenc`:
  - CoreAudio: 12, 13, 26 or 50 ms.
  - libmad: 26 ms.
  - FFmpeg: 26 ms.
- **CoreAudio .m4a files get 48 ms.**
- Different decoders handle encoder delay differently, and a grid made with one decoder is off by
  that much when played through another.

**Inference:** Mixxx's design shows the split that matters here:

- **Open-loop phase from the grid:** a seek, plus a grid-to-grid P controller.
- **One-time human correction from the audio:** user offset or grid translate.

An automatic DJ has to do that human step itself, offline, from the audio.

### 1.2 Traktor (Native Instruments)

- **Fact.**
  - The manual defines **TempoSync** as *"the tempo is locked but not the phase"* and **BeatSync**
    (the default) as *"will always maintain tempo and phase synchronization … the phase is locked
    accordingly to the Beatgrid and not to the beat."*
  - A Master Clock or tempo-master deck leads.
  - In TempoSync a phase offset can appear and is shown on the phase meter.
  - Traktor Pro 3 uses zplane **élastique 3** for keylock (NI press material).
  - Sources: the Traktor Pro manual's "Global Concepts" page and NI's Traktor Pro 3 press page.
- **Inference.** Traktor keeps phase continuously from the grid, like Mixxx. A wrong grid means
  locked-in flamming until the DJ moves the grid.

### 1.3 Serato DJ

- **Fact.**
  - **Simple Sync** matches BPM and *"snap[s] the two closest transients together"*, with no
    beatgrid needed.
  - **Smart Sync** syncs BPM and beat position from the beatgrids and *"requires … accurate
    beatgrids"*.
  - Serato uses its own *Pitch 'n Time* stretcher.
  - Sources: Serato support article "SYNC with Serato DJ"; DJ TechTools 2014.
- **Inference.** Simple Sync is a one-shot **audio-transient** phase alignment, which is the same
  idea as recommendation 3, done once at engage.

### 1.4 rekordbox / Pioneer CDJ

- **Fact.**
  - Beat Sync matches tempo and beat positions *"based on the track's beat grid information as
    analyzed with rekordbox"*.
  - Quantize snaps cues and loops to the grid, marketed as "1 ms accurate".
  - rekordbox has a **Normal** (constant) and a **Dynamic** (variable-tempo) analysis mode, and
    users can lock grid sections.
  - Sources: Pioneer XDJ-RX2 manual; London Sound Academy grid guides.
- **Fact** (from Mixxx above): rekordbox's stored beat times depend on how its decoder treats MP3
  and AAC priming.

### 1.5 djay (Algoriddim): Automix, Neural Mix, Fluid Beatgrid

- **Fact.**
  - Automix *"scans the current and upcoming song, identifying the best sections … for fading
    between the outro of one and the intro of the next"*. It "optimizes EQs and filters for each
    transition", and Algoriddim says it was trained with *"machine learning and training sets from
    human DJs"* (djay Pro 2, 2017).
  - The Automix settings offer transition styles (Automatic, Fade, Filter, EQ, Echo, Dissolve,
    Neural Mix).
  - djay Pro 5 (Dec 2023) added **Fluid Beatgrid**, which *"automatically detects and adjusts to
    varying tempo and rhythmic changes"*, and **Crossfader Fusion** transition presets.
  - Neural Mix is real-time stem separation (drums, bass, vocals, instruments), so a transition
    can swap stems.
  - Community and forum sources say djay uses zplane élastique Pro V3 for keylock. This is
    unverified secondary information.
- **Not public.** How Automix corrects phase drift has not been published.
- **Inference.** Fluid Beatgrid implies **per-beat (variable) grids with tempo-following sync**,
  i.e. feed-forward warping rather than a constant BPM.
- **Inference.** Neural Mix lets a transition use **one drum stem at a time** (a drum swap rather
  than layering), which hides small residual phase errors entirely. That is a cheap strategy
  Platterhead could imitate with EQ: never let two full kick and bass bands play at full level
  together.

---

## 2. Beat-tracking accuracy: state of the art

| System | Frame rate / hop | Notes |
|---|---|---|
| **madmom** RNN + DBN (Böck, Krebs, Widmer, ISMIR 2016 "Joint beat and downbeat tracking with recurrent neural networks"; DBN state space: Krebs, Böck, Widmer, ISMIR 2015) | **100 fps (10 ms)** | `RNNDownBeatProcessor` → `DBNDownBeatTrackingProcessor` (beats plus position in bar). The DBN enforces a smooth tempo. |
| **BeatNet** (Heydari, Cwitkowitz, Duan, ISMIR 2021) | 22.05 kHz, **50 fps (20 ms)** | Causal particle filter (online) or DBN (offline). |
| **Beat This!** (Foscarin, Schlüter, Widmer, ISMIR 2024, "Beat this! Accurate beat tracking without DBN postprocessing") | 22.05 kHz, hop 441 → **50 fps (20 ms)** | Transformer + conv. **"Minimal" postprocessing**: frame-wise max-pool peak picking (±70 ms, kernel 7) and `beat_frame / fps`, so it is quantised to **20 ms**. Shift-tolerant loss, because the annotations themselves are imprecise. A DBN is optional. Best F1 overall, weaker on continuity metrics. |
| **Essentia** `BeatTrackerDegara` / `BeatTrackerMultiFeature` (Degara et al. 2012; Zapata, Davies, Gómez 2014) | 2048/1024 at 44.1 kHz (**23 ms hop**) | Requires 44.1 kHz input. |
| **librosa** `beat_track` (Ellis 2007, "Beat tracking by dynamic programming", JNMR 36(1)) | default sr 22050, hop 512 (**23 ms**) | DP over an onset envelope with a global tempo. |
| **QM-DSP** (Mixxx; Davies & Plumbley 2007, IEEE TASLP) | 512 at 44.1 kHz (11.6 ms) | Mixxx documents a ±12 ms jitter. |
| **Platterhead analyser (current)** | 2048 at 48 kHz (**42.7 ms**) + 441/440 time-base bug | Being fixed. |

**Evaluation tolerance.**

- **Fact.** Standard beat-tracking F-measure counts a beat as correct within **±70 ms** (Davies,
  Degara, Plumbley 2009, "Evaluation methods for musical audio beat tracking algorithms",
  QMUL C4DM-TR-09-06; used by MIREX and mir_eval).
- **Inference.** A state-of-the-art F-measure says almost nothing about whether the error is 2 ms
  or 30 ms. Per-beat precision is limited by the frame rate (10–23 ms quantisation before any
  interpolation) and by how consistently the annotators placed beats.

**Where the beat sits relative to the kick.**

- **Fact.** Trackers learn to peak where annotators placed beats. Annotations are made by tapping
  and then corrected, and they sit near the perceived onset.
- **Fact.** Perceptual attack time (PAT) can differ from the physical onset:
  - Gordon 1987, "The perceptual attack time of musical tones", JASA 82.
  - Wright 2008, PhD thesis "The shape of an instant".
  - Polfreman 2013, ISMIR, "Comparing onset detection and perceptual attack time".
  - For sharp percussive sounds the PAT is at, or a few ms after, the onset. For slow attacks it
    can be tens of ms later.
- **Inference.**
  - For layering two tracks, what matters is that **the same reference point is used on both
    kicks**.
  - Cross-correlating low-band onset envelopes aligns the *shapes*. That is more robust than
    peak-picking each kick when one kick has a click and the other a slow sub.
  - A consistent per-track bias drops out of the pairwise difference. A **track-dependent** bias
    does not: different kick shapes, different encoders, a hi-hat-driven tracker locking a few ms
    off the kick.

**Encoder and decoder delay.**

| Codec | Delay | Source | How it is handled |
|---|---|---|---|
| MP3 (LAME) | 1105 samples ≈ **25 ms** at 44.1 kHz (commonly cited: 576 encoder + 529 decoder) | LAME tech FAQ: ISO decoders add a **528-sample** delay; the padding/delay is stored in the LAME/Xing tag | Gapless decoders (ffmpeg, Core Audio) trim using the tag. Decoders without gapless support, or files without the tag, do not. |
| AAC | **2112 samples** priming ≈ 48 ms at 44.1 kHz (44 ms at 48 kHz) | Apple TN2258, "AAC Audio – Encoder Delay and Synchronization: The 2112 Sample Assumption" | `ExtAudioFile` trims priming automatically. `AudioConverter` and `AudioQueue` do **not**: the client must. |

- **Inference.** Mixxx's 26 ms and 48 ms rekordbox offsets are exactly these delays. **If
  Platterhead's prep pipeline (ffmpeg, server) and the phone's playback (AVFoundation) disagree
  about priming for some files, that produces a per-track constant offset of 0, ~25 or ~48 ms.**
  That is the size of the flam heard.
- **To check:** decode the same MP3/AAC with ffmpeg and with `AVAudioFile`, then cross-correlate
  the two.

---

## 3. Research on automatic DJ mixing

### 3.1 Systems

- **Cliff 2000**, "Hang the DJ: Automatic sequencing and seamless mixing of dance-music tracks"
  (HP Labs Tech Report HPL-2000-104). An early beat-matched auto-mixer.
- **Ishizaki, Hoashi, Takishima 2009**, "Full-automatic DJ mixing system with optimal tempo
  adjustment based on measurement function of user discomfort", ISMIR 2009, pp. 135–140. Tempo
  changes are planned to minimise a measured discomfort function. Relevant if Platterhead ever
  ramps tempo rather than holding it.
- **Liebman, Saar-Tsechansky, Stone 2015**, "DJ-MC: A reinforcement-learning agent for music
  playlist recommendation", AAMAS 2015. This is about *sequencing*, not signal-level mixing.
- **Bittner et al. 2017**, "Automatic playlist sequencing and transitions", ISMIR 2017 (Spotify).
- **Vande Veire & De Bie 2018**, "From raw audio to a seamless mix: creating an automated DJ
  system for Drum and Bass", EURASIP J. Audio, Speech, Music Proc. 2018:13,
  doi:10.1186/s13636-018-0134-8. Code: github.com/lenvdv/auto-dj.
  - **Fact, from the code** (`Application/BeatTracker.py`):
    - Assumes **constant BPM**.
    - Builds a melflux onset function (1024/512 at 44.1 kHz).
    - Finds tempo by autocorrelation comb over 160–190 BPM in **0.01 BPM** steps.
    - Finds phase by an exhaustive **1 ms phase search**, folding the onset function onto the
      grid.
    - Emits an equidistant grid.
    - Downbeats come from a separate classifier on beat-synchronous features (loudness, MFCC,
      onset integrals). Phrases come from structural segmentation.
  - **Fact, from the code** (`timestretching.py`): the time-stretch is **HPSS-based**. The
    percussive part is stretched with short-frame OLA, the harmonic part with WSOLA (after
    Driedger, Müller, Ewert 2014). A code comment warns that fragments longer than a 16th note
    cause *"doubling transients"*.
  - **Inference.** This is the most directly reusable recipe: constant-tempo grid, fine
    regression on tempo, 1 ms phase fold on the onset function, a separate downbeat model, and a
    transient-aware stretch.
- **Chen et al. 2022**, "Automatic DJ transitions with differentiable audio effects and generative
  adversarial networks", ICASSP 2022. Learns EQ/fader curves; it assumes the beats are already
  aligned.

### 3.2 Reverse-engineering real DJ mixes

- **Kim, Choi, Sacks, Yang, Nam 2020**, "A computational analysis of real-world DJ mixes using
  mix-to-track subsequence alignment", ISMIR 2020 (arXiv:2008.10267; code
  github.com/mir-aidj/djmix-analysis).
  - 1,557 mixes, 13,728 tracks and 20,765 transitions from 1001Tracklists.
  - **Subsequence DTW** on tempo- and key-robust features finds cue points and transition
    lengths, and how much DJs change tempo and key.
- **Kim et al. 2021**, "Reverse-engineering the transition regions of real-world DJ mixes using
  sub-band analysis with convex optimization", NIME 2021. Recovers per-band gain trajectories,
  i.e. what EQ/bass-swap curves real DJs use.
- **Schwarz & Fourer 2018**, "UnmixDB: A dataset for DJ-mix information retrieval", ISMIR 2018
  late-breaking (zenodo 1422385). Beat-synchronous generated mixes with ground truth, made with
  linear crossfades and several time-scaling variants.
- **Schwarz & Fourer 2019/2021**, "Methods and datasets for DJ-mix reverse engineering"
  (hal-02172427 / hal-03184436).
- **Sonnleitner, Arzt, Widmer 2016**, "Landmark-based audio fingerprinting for DJ mix
  monitoring", ISMIR 2016. This is the source of the Mixotic track set.
- **Inference.** These papers measure *where* and *how long* DJs mix, and what gain curves they
  use. They confirm DJ-style bass/EQ swaps and 16–32-bar transitions. None of them report the
  sub-10 ms phase precision of real mixes. That precision comes from the DJ's ear or the
  software's grid.

### 3.3 Perceptual thresholds: when do two kicks sound like a flam?

**Facts:**

- **Temporal order** of two sounds needs about **15–20 ms** of onset asynchrony, even for trained
  listeners (Hirsh 1959, "Auditory perception of temporal order", JASA 31; Hirsh & Sherrick
  1961).
- In **ensemble performance**, asynchronies between players are typically **30–50 ms** (Rasch
  1979, "Synchronization in performed ensemble music", Acustica 43). Those are different timbres,
  where asynchrony is partly heard as attack texture.
- Shifting one tone in an **isochronous sequence** is detectable at about **6 ms** for
  inter-onset intervals below about 240 ms, and at about 2.5 % of the interval above that
  (Friberg & Sundberg 1995, "Time discrimination in a monotonic, isochronous sequence", JASA 98).
  For a 124 BPM quarter-note kick (484 ms) that is about 12 ms. For 16th-note hats (121 ms) it
  is about 6 ms.
- Longer rise times increase tolerance to asynchrony, and sharp percussive attacks reduce it
  (see the onset-asynchrony literature, e.g. PMC6561579).
- Mixxx treats ≤25 ms as "inaudible" for grid ironing (§1.1).

**Inference, for the error budget:**

- **Two nearly identical kicks summed** are the worst case. They do not mask each other's attacks
  the way different timbres do.
- **Δ ≳ 10 ms:** audible as a doubled or flammed kick, in agreement with the observation that
  "20–30 ms is a clear flam".
- **3 ms ≲ Δ ≲ 10 ms:** not heard as two hits but as a smeared, softer or "thick" kick. If both
  sub-basses are present they **comb-filter**. At 55 Hz (18.2 ms period):
  - 5 ms ≈ 99°: the sum is about +3 dB instead of +6 dB.
  - 9 ms ≈ 180°: cancellation.
  - So with both full basses up, the requirement is **≤ 2–3 ms**.
- **Δ ≤ 2 ms:** effectively fused.
- **Targets:** ≤5 ms p95 during the overlap with only one track's bass up (bass swap); ≤2–3 ms if
  both basses are ever at full level; >10 ms is a failure.

---

## 4. Phase alignment beyond grids

1. **Cross-correlating low-band onset envelopes.**
   - Band-limit to about 35–150 Hz (kick fundamental and body), take the RMS envelope at 1 ms hops
     or finer, half-wave-rectify the difference (spectral flux), and cross-correlate within ±½
     beat. Refine the peak with parabolic interpolation to **< 0.5 ms**.
   - GCC-PHAT, directly on the low-passed waveforms, gives even sharper peaks for nearly identical
     kicks.
   - `blend.py` already does this (`kick_offset_ms`, `kick_lag_ms`), but only to *report* the
     offset. **Feed it back into the plan.**
   - Related: Ewert, Müller, Grosche 2009, "High resolution audio synchronization using chroma
     onset features", ICASSP. Adding onset features to DTW gives alignment far finer than the
     frame size.
2. **Per-track phase fold.** This is `gridphase.py`, the approach of Vande Veire's 1 ms phase
   search and of Mixxx `BeatUtils::adjustPhase`. Fold the onset envelope onto the fitted period
   and take the argmax. Store it as a per-track **kick offset** relative to the grid, or simply
   shift the grid by it.
3. **Phase-locked loops and oscillator models** for continuous tempo and phase tracking:
   - Large & Kolen 1994, "Resonance and the perception of musical meter", Connection Science 6.
     Adaptive oscillators with separate phase and period correction.
   - Repp 2005, "Sensorimotor synchronization: a review of the tapping literature", Psychonomic
     Bull. & Rev. 12. Humans use fast **phase correction** and slower **period correction**:
     exactly the P and I terms of a PI loop.
   - Robertson & Plumbley 2007, "B-Keeper: a beat-tracker for live performance", NIME 2007.
     Follows a live drummer by adjusting Ableton's tempo to hold phase.
   - Dixon 2001, "Automatic extraction of tempo and beat from expressive performances", JNMR
     (BeatRoot).
   - Stark, Davies, Plumbley 2009, "Real-time beat-synchronous analysis of musical audio",
     DAFx 2009.
   - Mixxx's `calcSyncAdjustment` is a P controller with a deadband and slew limit (§1.1).
   - **Inference.** For two pre-analysed files in one engine the "PLL" can be partly
     **feed-forward**. The planned rate for each incoming beat k is

     `rate_k = (b_in[k+1] − b_in[k]) / (b_out[j+1] − b_out[j])`

     taken from the two per-beat maps. Feedback is then only needed on the residual measured from
     audio.
4. **DTW and time maps for drifting or live recordings.**
   - Dixon 2005, "Live tracking of musical performances using on-line time warping", DAFx 2005.
   - Müller 2015, *Fundamentals of Music Processing* (Springer), ch. 3.
   - Kim et al. 2020 use subsequence DTW.
   - **Inference.** For tracks that are not perfectly steady (live drums, old disco, Fluid-Beatgrid
     material), store **per-beat times** (a beat map, as rekordbox Dynamic mode does) instead of
     a single BPM. Drive the stretcher with a **time map** that warps incoming beat k onto
     outgoing beat j. Rubber Band offline mode supports this directly through
     `setKeyFrameMap()`. In real time, update the stretch ratio every beat (lookahead-compensated,
     §5).
5. **Sub-beat micro-alignment.** When the two kicks have different shapes, align by
   cross-correlation over **4–8 beats** of envelope, not by individual peaks. Shifting by a
   constant ½ ms has no audible side effect. Avoid aligning on hi-hats: their timing is often
   swung and does not follow the kick.
6. **Unsteady tracks and safety.**
   - Measure the lag every few beats across the planned overlap offline.
   - If the lag has a slope, correct the tempo ratio. If it wanders (residual > 5 ms after
     removing the slope), **shorten the overlap**, choose a different entry or exit section, or
     use a non-layered transition (echo-out, filter, cut on a downbeat).
   - djay offers Echo and Dissolve styles, and real DJs avoid long blends of unsteady tracks.

---

## 5. Time-stretch quality with keylock

**Rubber Band** (Breakfast Quay; GPL, or a commercial licence):

- **Fact.**
  - Engines are R2 ("faster") and R3 ("finer", `OptionEngineFiner`, higher quality and CPU cost).
  - Since 3.1, `OptionWindowShort` with R3 gives lower delay and CPU.
  - Real-time start delays (`getStartDelay`): R2 short/standard/long = 512/1024/2048 samples;
    R3 short/standard = 1280/2048 samples.
  - The docs say ratio changes apply *"immediately to the next input it processes, but there is a
    lag"*, so **schedule ratio changes early by `getStartDelay()`**.
  - Pad with `getPreferredStartPad()` and drop `getStartDelay()` output samples. Mixxx does exactly
    this.
  - Offline mode handles alignment itself and supports `setKeyFrameMap` (time maps).
- **Inference.** Use R2 crisp or R3 for drums, and offline R3 for the lab.

**zplane élastique** (commercial):

- **Fact.** Used in Traktor Pro 3 (élastique 3) and reportedly in djay. It is the de facto
  standard for DJ keylock.
- **Fact.** The newer versions market better transient preservation and bass resolution.
  Latency and API figures are behind the SDK licence.

**SoundTouch** (LGPL):

- **Fact.** A WSOLA-style time-domain method. Defaults (`TDStretch.h`): sequence 40 ms (now
  auto), seek window 15 ms (now auto), overlap 8 ms. Mixxx uses it as the "faster" keylock.
- **Inference.** Like any WSOLA, local timing can jitter by up to the seek window, and transients
  can be doubled or skipped at large ratios.

**ffmpeg `atempo`** (what blend-lab uses now):

- **Fact** (`af_atempo.c`):
  - *"an implementation of WSOLA"*.
  - Window = `sample_rate/24`, rounded up to a power of two: **2048 samples (46 ms) at 44.1 kHz**.
  - Correlation search `delta_max = window/2` (**±1024 samples ≈ ±23 ms**), with a drift penalty
    so the offset does not accumulate.
- **Inference.** This alone can move individual stretched kicks by up to tens of ms and can double
  transients. **It is a credible cause of the 20–30 ms flam and of "occasional misaligned beats"
  in the offline renders, independent of the grid.**
- **Test:** run `kick_lag_ms` per beat on `decode(b, tempo=ratio)` against
  `grid.scaled(measured)`, and look at the per-beat spread, not just the median.

**Apple `AVAudioUnitTimePitch` / `AVPlayerItem.audioTimePitchAlgorithm`:**

- **Fact.**
  - The algorithms are `.spectral` ("highest quality … suitable for music"), `.timeDomain`
    ("modest quality … suitable for voice"), `.varispeed` (no pitch correction), and
    `.lowQualityZeroLatency`. Rates run 1/32–32.
  - `AVAudioUnitTimePitch` exposes `rate`, `pitch` and `overlap` (3–32, default 8).
  - **A latency of about 0.09 s has been reported** (Apple Developer Forums thread 708168). Read
    it at runtime from `auAudioUnit.latency` rather than hard-coding it.
  - Apple does not document the algorithm's transient handling.
- **Inference.**
  - `.spectral` is a phase vocoder. Phase vocoders smear transients ("phasiness"; Laroche &
    Dolson 1999, "Improved phase vocoder time-scale modification of audio", IEEE TSAP 7) unless
    they reset phase at transients (Röbel 2003, DAFx; Bonada 2000, ICMC).
  - That smearing slightly blunts and spreads stretched kicks. It sounds like a "soft kick", but
    as long as the latency is compensated it does not *shift* them by tens of ms.
  - `.timeDomain` behaves like WSOLA and has the jitter risk above.
  - **Measure both on device**, using AVAudioEngine **manual rendering mode**
    (`enableManualRenderingMode(.offline, …)`), which renders the exact iOS graph offline.

**Is it safe to vary the rate continuously?**

- **Fact.**
  - Mixxx changes the Rubber Band/SoundTouch ratio continuously (up to ±5 % sync adjustment)
    during playback.
  - Rubber Band supports ratio changes in real-time mode.
  - Driedger & Müller 2016, "A review of time-scale modification of music signals" (Applied
    Sciences 6(2)), covers time-varying TSM. Driedger, Müller, Ewert 2014, "Improving
    time-scale modification of music signals using harmonic-percussive separation" (IEEE SPL) is
    the HPSS approach Vande Veire copied.
- **Inference.**
  - Small, smooth ratio changes (≤0.5 %, slewed over hundreds of ms) are inaudible in phase
    vocoders.
  - The risks:
    1. Step changes at a coarse rate (every 0.5 s) with AVPlayer, which may restart internal
       processing or glitch.
    2. Latency means a correction takes effect ~90 ms later, so a fast loop oscillates.
    3. Jitter in the error measurement gets turned into pitch and level wobble.
  - Alternative: keep TimePitch at the fixed tempo ratio and apply micro-nudges with a downstream
    **`AVAudioUnitVarispeed`**. ±0.1–0.2 % is a 1.7–3.5 cent pitch shift, below typical pitch
    JNDs, and the forum reports varispeed adds no noticeable latency. That keeps keylock
    "permanent" in practice.

---

## 6. Practical recommendations

### 6a. Offline per-track analysis: what to store

**Decode with the playback decoder.**
- On iOS that is `AVAudioFile` / `ExtAudioFile`, which trims AAC priming (TN2258) and handles the
  LAME gapless tag.
- If prep runs on a server with ffmpeg, **verify per format that ffmpeg and AVFoundation produce
  sample-identical starts.** Otherwise store a `decoderOffsetSamples` per file, or re-analyse on
  device.
- Put the decoder identity in the analysis algorithm ID.

**Beats.** Use a proper tracker (madmom DBN downbeat, or Beat This! with DBN), then:
1. **Fit a constant-tempo grid by robust regression** of beat index against time over the steady
   sections (Mixxx `makeConstBpm`-style regions, outliers removed). Do not snap the BPM to an
   integer unless the residual confirms it.
2. **Tempo precision:** store the beat period in samples as a double. Target a relative error of
   ≤1×10⁻⁵ (sampleRate·60/BPM to ±0.5 sample per beat over 300 beats is easily reachable).
3. **Phase refinement:** fold the 35–150 Hz onset envelope (1 ms hop, or sample-domain) onto the
   grid, take the argmax and parabolic-interpolate it, and store **`kickPhaseOffsetMs`** to
   0.1 ms. Also store the fold **peak contrast** as a confidence value (`gridphase.py` computes
   it).
4. **Steadiness:** compute the per-beat residual (detected kick minus grid) and store p50/p90 and
   the slope per 32-beat block. If p90 > 5 ms or blocks disagree, flag the track as `variableTempo`
   and store a **per-beat map** (sample positions of each beat, kick-refined) instead of relying
   on the constant grid.

**Downbeats and phrases.**
- Store the downbeat (bar phase 0–3) with a confidence value.
- Store 8/16/32-bar phrase boundaries (structural novelty), as Vande Veire did.
- Plan the bass-swap point only on a high-confidence downbeat that falls on a phrase boundary in
  both tracks.

**Per region.** Store a kick-presence mask per beat (low-band energy), so the planner knows
whether a section has kicks to align (outro breakdowns often do not), plus the existing key and
loudness values.

### 6b. Per-transition planning (offline, or a few seconds ahead on device)

1. Choose the tempo ratio `r = periodIn / periodOut` (kept for the rest of the incoming track,
   with keylock).
2. **Render or simulate the stretched incoming region** with the *same stretcher the phone uses*.
3. Cross-correlate low-band onset envelopes of the outgoing overlap against the stretched incoming
   region, in windows of 8 beats across the whole overlap. That gives lag(t).
   - **Constant term:** shift the entry sample by it.
   - **Slope:** correct `r`.
   - **Residual > 5 ms:** shorten or re-place the overlap, or change the transition style.
4. Check that the bar phase matches at the entry and at the bass-swap downbeat. An off-by-one-beat
   downbeat is a likely cause of "misaligned beats at the drop".

### 6c. Real-time execution on iOS

**Engine.**
- Use **AVAudioEngine**, not two AVPlayers.
- Per deck: `AVAudioPlayerNode` → `AVAudioUnitTimePitch` (fixed `rate = r`) → optional
  `AVAudioUnitVarispeed` (for nudges) → an EQ for the bass swap (`AVAudioUnitEQ` low shelf, or a
  crossover with two branches) → the main mixer.
- One engine is one hardware clock, so **the two decks cannot drift apart because of clocks.**

**Scheduling.**
- Start the incoming segment with `scheduleSegment(_:startingFrame:frameCount:at:)` /
  `play(at:)` using an `AVAudioTime(sampleTime:atRate:)` computed on the output node's timeline.
- Subtract the TimePitch latency, and add an equal delay to the outgoing path if it bypasses
  TimePitch (or route both decks through TimePitch so their latencies match).
- If AVPlayer has to stay for streaming reasons, at least use `setRate(_:time:atHostTime:)` with
  `automaticallyWaitsToMinimizeStalling = false` for a common host-time start. Its timing
  precision is not documented.

**Gain.** Ramp per render buffer, using `AVAudioMixerNode.outputVolume` updated with a short
parameter ramp or a custom `AVAudioSourceNode`/AU that applies sample-level curves. Not
`AVPlayer.volume` steps.

**Nudging (the owner's continuous correction), done safely:**
- **Measure:** install a tap on each deck's post-stretch node. Compute low-band onset envelopes
  and cross-correlate over a sliding 4–8 beat window once per beat. This gives the *heard*
  asynchrony e_k in ms. Ignore beats without kicks in both tracks (use the kick mask).
- **Control:** a PI loop on e_k:
  - 1 ms deadband.
  - `Δrate = clamp(Kp·e_k/T_beat + Ki·Σe, ±0.2 %)`, slew-limited to about 0.05 % per beat.
  - Apply it to the varispeed (or to TimePitch `rate`) **ahead of time by the stretcher latency**.
  - Start with Kp ≈ 0.25 per beat and a small Ki. At 0.2 % a 10 ms error takes about 5 s, which
    is fine because large errors were removed in 6b.
- **Never seek audible audio to fix phase.** If |e| > 15 ms while the incoming track is still
  inaudible (pre-roll or EQ-killed), a re-schedule or micro-crossfade (5–10 ms, between kicks) is
  acceptable. Once it is audible, only rate changes are allowed.
- For `variableTempo` tracks, drive the rate **feed-forward** from the per-beat maps every beat,
  and leave only the residual to the PI loop.

### 6d. Error budget (p95 kick asynchrony during the overlap)

| Source | Budget | How |
|---|---|---|
| Per-track grid phase (kick-refined) | ±1 ms | §6a.3 |
| Tempo-ratio error over 96 beats | ≤2 ms | relative error ≤4×10⁻⁵, or slope-corrected in §6b |
| Decoder priming mismatch | 0 | same decoder, or a stored offset |
| Stretcher latency | 0 | `getStartDelay` / `auAudioUnit.latency`, applied symmetrically |
| Stretcher local timing jitter | ≤1–2 ms | phase vocoder (spectral/R3), not WSOLA with a ±23 ms search |
| Scheduling / clocks | 0 | one AVAudioEngine, sample-time starts |
| Musical drift (unsteady tracks) | ≤2 ms | feed-forward beat map + PI trim, or reject the overlap |
| **Total target** | **≤5 ms** (≤2–3 ms if both basses are full) | Verify in the lab with `kick_offset_ms` per 8-beat window |

### 6e. Next lab experiments (cheap, decisive)

1. Per-beat kick lag of `atempo`-stretched audio against the scaled grid. If the p90 spread is
   above 10 ms, `atempo` is the flam source. Re-render with `rubberband -3 --crisp` (or
   pyrubberband) and compare.
2. Decode each test file with ffmpeg and with `AVAudioFile` (via a small Swift CLI) and
   cross-correlate the two. Record the per-format offset.
3. Add a "phase-corrected" variant to `blend.py`: entry shifted by the measured `kick_offset_ms`,
   ratio corrected by the lag slope. Expect |offset| ≤ 3 ms throughout.
4. For pair 3 (the outro changes its drum pattern), check whether the downbeat or the kick mask
   explains the +140 ms, before tuning anything else.

---

## References

**DJ software**
- Mixxx source, github.com/mixxxdj/mixxx (main):
  - `src/engine/controls/bpmcontrol.cpp` (`calcSyncAdjustment`, `getNearestPositionInPhase`, `slotTranslateBeatsMove`, `slotBeatsTranslateMatchAlignment`)
  - `src/engine/sync/{enginesync,synccontrol,internalclock}.cpp`
  - `src/engine/controls/quantizecontrol.cpp`
  - `src/track/{beats,beatutils,beatfactory}.cpp`
  - `src/analyzer/analyzerbeats.cpp`, `src/analyzer/plugins/analyzerqueenmarybeats.cpp`
  - `src/engine/bufferscalers/enginebufferscalerubberband.cpp`, `enginebufferscalest.cpp`
  - `src/library/rekordbox/rekordboxfeature.cpp` (PR #2119, MP3/M4A timing offsets)
- Mixxx manual, "DJing with Mixxx": https://manual.mixxx.org/2.4/en/chapters/djing_with_mixxx
- Traktor Pro manual, "Global Concepts": https://docs.native-instruments.com/online-guides/traktor-pro-manual/en/global-concepts
- Traktor Pro 3 press (élastique 3): https://www.native-instruments.com/en/press-area/djing/traktor-pro-3/
- Serato, "SYNC with Serato DJ": https://support.serato.com/hc/en-us/articles/203056994-SYNC-with-Serato-DJ
- DJ TechTools, "How to set beatgrids and use sync properly in Serato DJ" (2014): https://djtechtools.com/2014/04/23/how-to-set-beatgrids-and-use-sync-properly-in-serato-dj
- Pioneer DJ XDJ-RX2 manual (Beat Sync, Quantize): https://www.fullcompass.com/common/files/34186-PioneerDJXDJRX2UserManual.pdf
- London Sound Academy, rekordbox grid tips: https://londonsoundacademy.com/blog/rekordbox-beat-grid-tips
- Algoriddim djay Automix help: https://help.algoriddim.com/user-manual/djay-pro-mac/mixing-basics/using-automix
- Algoriddim, djay Pro 5 press release (Fluid Beatgrid, Neural Mix, Crossfader Fusion), Dec 2023: https://algoriddim.com/press_releases/447-algoriddim-unveils-djay-pro-5-with-next-generation-neural-mix-crossfader-fusion-and-fluid-beatgrid-
- Synthtopia, djay Pro 2 AI Automix (2017): https://synthtopia.com/content/2017/12/12/djay-pro-2-for-mac-brings-artificial-intelligence-to-djing

**Beat tracking**
- Böck, Krebs, Widmer (2016). Joint beat and downbeat tracking with recurrent neural networks. ISMIR. https://www.cp.jku.at/people/krebs/ismir2016/
- Krebs, Böck, Widmer (2015). An efficient state-space model for joint tempo and meter tracking. ISMIR.
- madmom docs: https://madmom.readthedocs.io/en/v0.16/modules/features/downbeats.html
- Heydari, Cwitkowitz, Duan (2021). BeatNet: CRNN and particle filtering for online joint beat, downbeat and meter tracking. ISMIR. https://github.com/mjhydri/BeatNet
- Foscarin, Schlüter, Widmer (2024). Beat this! Accurate beat tracking without DBN postprocessing. ISMIR. https://ismir2024program.ismir.net/poster_10.html, code https://github.com/CPJKU/beat_this
- Ellis (2007). Beat tracking by dynamic programming. J. New Music Research 36(1).
- Davies & Plumbley (2007). Context-dependent beat tracking of musical audio. IEEE TASLP 15(3).
- Degara et al. (2012). Reliability-informed beat tracking of musical signals. IEEE TASLP. Zapata, Davies, Gómez (2014). Multi-feature beat tracking. IEEE/ACM TASLP. Essentia: https://essentia.upf.edu/reference/std_BeatTrackerDegara.html
- Davies, Degara, Plumbley (2009). Evaluation methods for musical audio beat tracking algorithms. QMUL C4DM-TR-09-06.
- Gordon (1987). The perceptual attack time of musical tones. JASA 82(1). Wright (2008). The shape of an instant (PhD, UC Berkeley). Polfreman (2013). Comparing onset detection & perceptual attack time. ISMIR.

**Codec delay**
- Apple TN2258, AAC Audio – Encoder Delay and Synchronization: The 2112 Sample Assumption: https://developer.apple.com/library/archive/technotes/tn2258/_index.html
- LAME technical FAQ (encoder/decoder delay, padding): https://lame.sourceforge.io/tech-FAQ.txt

**Automatic DJ / mix analysis**
- Cliff (2000). Hang the DJ: Automatic sequencing and seamless mixing of dance-music tracks. HP Labs HPL-2000-104.
- Ishizaki, Hoashi, Takishima (2009). Full-automatic DJ mixing system with optimal tempo adjustment based on measurement function of user discomfort. ISMIR, 135–140. https://doi.org/10.5281/zenodo.1418231
- Liebman, Saar-Tsechansky, Stone (2015). DJ-MC: A reinforcement-learning agent for music playlist recommendation. AAMAS.
- Bittner et al. (2017). Automatic playlist sequencing and transitions. ISMIR.
- Vande Veire & De Bie (2018). From raw audio to a seamless mix: creating an automated DJ system for Drum and Bass. EURASIP JASMP. https://doi.org/10.1186/s13636-018-0134-8, code https://github.com/lenvdv/auto-dj
- Kim, Choi, Sacks, Yang, Nam (2020). A computational analysis of real-world DJ mixes using mix-to-track subsequence alignment. ISMIR. https://arxiv.org/abs/2008.10267, https://github.com/mir-aidj/djmix-analysis
- Kim, Yang, Nam (2021). Reverse-engineering the transition regions of real-world DJ mixes using sub-band analysis with convex optimization. NIME. https://nime.org/proc/nime21_87
- Schwarz & Fourer (2018). UnmixDB: A dataset for DJ-mix information retrieval. ISMIR LBD. https://zenodo.org/record/1422385, https://hal.archives-ouvertes.fr/hal-02010431
- Schwarz & Fourer (2019/2021). Methods and datasets for DJ-mix reverse engineering. https://hal.archives-ouvertes.fr/hal-02172427
- Chen et al. (2022). Automatic DJ transitions with differentiable audio effects and generative adversarial networks. ICASSP.

**Perception and synchronisation**
- Hirsh (1959). Auditory perception of temporal order. JASA 31. Hirsh & Sherrick (1961). Perceived order in different sense modalities. J. Exp. Psych. 62.
- Rasch (1979). Synchronization in performed ensemble music. Acustica 43.
- Friberg & Sundberg (1995). Time discrimination in a monotonic, isochronous sequence. JASA 98, 2524–2531.
- Repp (2005). Sensorimotor synchronization: a review of the tapping literature. Psychonomic Bulletin & Review 12(6).
- Onset-asynchrony and rise-time tolerance: https://pmc.ncbi.nlm.nih.gov/articles/PMC6561579

**Phase tracking and alignment**
- Large & Kolen (1994). Resonance and the perception of musical meter. Connection Science 6.
- Robertson & Plumbley (2007). B-Keeper: a beat-tracker for live performance. NIME.
- Dixon (2001). Automatic extraction of tempo and beat from expressive performances. JNMR 30(1).
- Dixon (2005). Live tracking of musical performances using on-line time warping. DAFx.
- Stark, Davies, Plumbley (2009). Real-time beat-synchronous analysis of musical audio. DAFx.
- Ewert, Müller, Grosche (2009). High resolution audio synchronization using chroma onset features. ICASSP.
- Müller (2015). Fundamentals of Music Processing. Springer.

**Time-stretching**
- Rubber Band integration notes (real-time, start delay/pad, engines): https://breakfastquay.com/rubberband/integration.html, CHANGELOG (R3, OptionWindowShort)
- SoundTouch `TDStretch.h` defaults: https://codeberg.org/soundtouch/soundtouch
- FFmpeg `libavfilter/af_atempo.c` (WSOLA, window and search range): https://github.com/FFmpeg/FFmpeg/blob/master/libavfilter/af_atempo.c
- zplane élastique: https://licensing.zplane.de (product information). djay/élastique claim: https://community.algoriddim.com/t/serato-stems-pitch-n-time-vs-djay-pro/41468
- Apple, AVAudioTimePitchAlgorithm: https://developer.apple.com/documentation/avfoundation/avaudiotimepitchalgorithm. AVAudioUnitTimePitch latency discussion: https://developer.apple.com/forums/thread/708168
- Laroche & Dolson (1999). Improved phase vocoder time-scale modification of audio. IEEE TSAP 7(3).
- Röbel (2003). A new approach to transient processing in the phase vocoder. DAFx.
- Bonada (2000). Automatic technique in frequency domain for near-lossless time-scale modification of audio. ICMC.
- Driedger, Müller, Ewert (2014). Improving time-scale modification of music signals using harmonic-percussive separation. IEEE Signal Processing Letters 21(1).
- Driedger & Müller (2016). A review of time-scale modification of music signals. Applied Sciences 6(2).
