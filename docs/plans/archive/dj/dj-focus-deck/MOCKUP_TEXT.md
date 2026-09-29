# Platterhead DJ — Focus Deck: screen text & interaction spec

Status: **approved design, not yet implemented** (2026-09-28).
Companion to [`HANDOFF.md`](HANDOFF.md), which says how to build it.
Visual reference: [`../mockups/dj-focus-deck-mockups.html`](../mockups/dj-focus-deck-mockups.html)
(self-contained; open it in a browser — the A1 pad tabs are clickable). This file is
canonical wherever the two differ.

This file is the **source of truth for every visible string, every control's
place, and every gesture** on the redesigned DJ surface. Build views against
it, not against taste. Strings in `code` are exact copy, including case.

---

## 0. Design rules (apply to every screen)

| Rule | Detail |
|---|---|
| **Three tiers** | Tier 1 = on screen always. Tier 2 = one gesture away (Mixer sheet). Tier 3 = deck options sheet or a long-press. Every `DJControlID` has exactly one home (§7). |
| **Glass is chrome, never content** | Title bar, deck chips (unfocused), waveform card, tempo pill, pad tabs, dock and sheets are glass. Pads, Play, and waveforms are solid and saturated. |
| **Deck colour** | Deck A = `Palette.brass` (#E3A44B). Deck B = existing `DJDeckState.accent` blue. The focused deck's colour tints its chip border, Play, and ambient glow. |
| **Targets** | ≥ 44 × 44 pt for everything touched during performance. Segmented controls and switches in sheets may use the system 32 pt height. |
| **Type** | SF Pro (system). Numbers (BPM, %, times, key, dB) use `.monospacedDigit()`; BPM/time readouts use SF Mono via `.fontDesign(.monospaced)`. |
| **Reduce Transparency** | Every glass surface falls back to the opaque `#1B1D22` fill (`GlassSurface` already does this). |
| **Reduce Motion** | Pad-tab and sheet transitions cross-fade instead of sliding. The waveform still scrolls. |
| **Haptics** | Pad hit and CUE set: `.impact(.medium)`. Loop engage: `.impact(.rigid)`. Crossfader passing centre: `.selection`. Sync lock: `.success`. |
| **No codename** | Never show "Tonearm". The app is **Platterhead** (CI `Codename leak` guard). |
| **Honest state** | Nothing shows a value that isn't real. Unanalysed BPM is `—`, never 120 (existing `DJLoadTrackInfo` rule). |

Sizes in this file are for a 393 × 852 pt iPhone. Layouts scale by
flex, not by fixed y-positions.

---

## 1. Perform — Focus Deck (portrait, default)

Top-to-bottom stack, 16 pt side gutters, 10 pt vertical gaps.

### 1.1 Title bar (36 pt)

| Element | Copy | Behaviour | A11y label |
|---|---|---|---|
| Left glass circle, chevron-down icon | — | Close DJ (existing `onBack`) | `Close DJ` |
| Centre title | `Platterhead` | none | header trait |
| Right glass capsule, red 8 pt dot | `REC` | `toggleRecording()`. While recording: dot pulses, label becomes elapsed `REC 12:04` (mono), capsule fill `danger` at 20%. | `Record mix` / `Stop recording, 12 minutes 4 seconds` |

VOL, PHONES and INFO are **removed** from the title bar (→ Mixer sheet §3; Help → §4.6).

### 1.2 Deck chips (64 pt, two equal columns)

Each chip shows: letter badge (26 pt circle, deck colour, dark letter) · title
(15 pt semibold, 1 line, truncates) · readout line (12 pt mono, deck colour 90%).

| State | Readout copy |
|---|---|
| Empty | title `Load a track`, readout `Tap to browse` |
| Loading | readout from `DJLoadPhase.label` in title case: `Loading…`, `Decoding…`, `Analyzing…` |
| Loaded, stopped | `119.8 · cued` (BPM · `cued`) |
| Playing | `116.0 · −2:48` (effective BPM · remaining) |
| On air (channel audible in master) | add a 6 pt deck-colour dot before the BPM |
| Synced | add `SYNC` suffix: `116.0 · SYNC` |
| Unanalysed | `— · cued` |

| Gesture | Result |
|---|---|
| Tap unfocused chip | `selectDeck(id)` — focus moves; pads, transport, tempo pill follow. |
| Tap focused chip | Open Load sheet for that deck. |
| Tap empty chip | Open Load sheet for that deck. |
| Context menu (long-press) | `Load Track…` · `Reanalyze` · `Clear Hot Cues` · `Clear Cue` · `Clear Loop` (existing callbacks; destructive items red). |

Focused chip: 1.5 pt deck-colour border, deck colour 16% fill, soft glow.
Unfocused chip: plain glass.

### 1.3 Waveform card (≈190 pt, glass, radius 24)

- Header row (11 pt, 0.4 tracking, uppercase):
  - left, deck colour: **phrase hint** for the focused deck, e.g. `A · DROP IN 8 BARS` (from section detection; omitted when unknown)
  - right, mono: `BAR 33.2` (bar.beat of the focused deck).
- Two scrolling waveforms, A above B, 62 pt each, sharing one fixed centre
  playhead (2 pt white line with glow). The played half is dimmed 45%.
- Beat ticks; downbeats of each bar taller.
- Footer hint (11 pt, `ink3`): `Drag a waveform to nudge · press and hold to scratch`.
  The hint disappears after the user has nudged 3 times (persist `dj.focus.hint.jog`).

| Gesture on a waveform | Stopped | Playing, touch mode **Nudge** (default) | Playing, touch mode **Scratch** |
|---|---|---|---|
| Horizontal drag | seek (`movePaused`) | pitch-bend nudge (`nudge`) | scratch (`scratch(_:by:width:)`) |
| Press ≥ 0.35 s then drag | fine frame search | scratch while held | scratch |
| Flick | `flick` coast | — | `flick` |
| Tap | focus that deck | focus that deck | focus that deck |
| Pinch | zoom (existing `changeTempo(zoom:)` naming aside — it zooms) | same | same |

Touch mode lives in Deck options (§4.3), defaults to `Nudge`, and replaces the VINYL toggle.

### 1.4 Tempo row (44 pt)

| Element | Copy | Behaviour |
|---|---|---|
| Glass pill, flex | `−` · `116.0 BPM · +0.0%` · `+` | `−`/`+` tap = ±0.1%; hold = repeat. Horizontal drag across the pill body = tempo fader within the current range. Double-tap body = `resetTempo`. Long-press body = existing fine-slider popup. |
| Key chip | lock icon + `8A` | Tap = `toggleMasterTempo` (lock icon filled when on). Long-press = key-shift pad page (§1.7). Shifted key shows e.g. `9A +1`. |
| `•••` glass circle | — | Opens Deck options sheet (§4) for the focused deck. A11y `Deck A options`. |

When SYNC is on, the pill shows `116.0 BPM · SYNC` and drag is disabled (a light shake plus the toast `Turn off Sync to change tempo`).

### 1.5 Transport (64 pt)

| Button | Copy | Behaviour |
|---|---|---|
| CUE (glass, 1×) | `CUE` | `cueDown`/`cueUp` — existing CDJ CUE semantics (`DJCueTransport`). Border lights in deck colour when a cue point exists. |
| PLAY (solid deck colour, 1.5×) | play icon + `Play` / pause icon + `Pause` | `toggle(id)` |
| SYNC (glass, 1×) | sync icon + `SYNC` | Tap `toggleSync`. Long-press 0.6 s = `makeMaster`; master shows a small `MASTER` caption under the label. Active: deck colour 22% fill + border. |

KEY sync (old KEY button) → Deck options `Match B` (§4.4).

### 1.6 Pad tabs (40 pt glass segmented, 4 segments)

| Segment | Page | Tap again (alternate page) |
|---|---|---|
| `Hot Cue` | Hot cues 1–8 | — |
| `Loop` | Auto beat loop | `In/Out` manual loop page (label changes to `In/Out`) |
| `Pad FX` | Pad FX | `Beat FX` page (label changes to `Beat FX`; existing second-tap behaviour) |
| `Beat Jump` | Beat jump | — |

Selected segment: white 92% fill, near-black text. The alternate state shows
a small two-dot page indicator under the label so the second page is discoverable.

### 1.7 Pads (2 × 4, 78 pt tall, 8 pt gaps, radius 20)

Each pad: top-left title (15 pt bold), bottom-left caption (11 pt mono, 85%).

**Hot Cue**

| Pad state | Title | Caption | Style |
|---|---|---|---|
| Set | cue name, else `Cue 1` | `1 · 0:32` | solid hot-cue colour (existing 8-colour table), dark text |
| Set hot loop | cue name, else `Loop 1` | `1 · 4 beats` | solid colour + loop glyph |
| Empty | `1` | `tap to set` | 4% white fill, colour text, 1.5 pt dashed colour border |

Tap empty = set. Tap set = jump (`activateCue`). Hold 1 s = delete (existing), with a
0.3 s ring-fill animation so the hold is visible. Cue names are a v2 feature; until
then the title is `Cue n`.

**Loop · Auto** (FLX4 BEAT LOOP)

Titles: `¼` `½` `1` `2` / `4` `8` `16` `32`. Caption `beats`; the active size shows `looping`.
Tap = start an auto loop of that length at the (quantized) playhead; tap the active pad
again = exit. Active pad is solid green (#3DD6A5), others green-tinted glass.

**Loop · In/Out** (existing `.loop` page, relabelled)

`In` · `Out` · `Set 4` (current length) · `Enter`/`Exit` (caption `next pass` when exit pending) ·
`½×` · `2×` · `← 4` · `4 →`. Behaviour unchanged (`loopPad`).

**Pad FX** (existing `.fx` page)

`Echo ¼` · `Echo ½` · `Echo 1` · `Echo 2` / `Echo Out` · `Roll` · `Reverb` · `Brake`.
Caption: `hold` on momentary pads, `armed` on Echo Out when armed. Violet-tinted glass;
pressed/armed = solid violet.

**Beat FX** (existing `.beatFX` page)

`Type` (caption = current type name) · `← Beat` · `Beat →` (caption = current division) · `On`/`Off` ·
`Ch A` · `Ch B` · `Master` (the assigned one solid) · `Level` (caption `50%`; vertical drag adjusts).

**Beat Jump** (FLX4 BEAT JUMP)

`← 1` `1 →` `← 4` `4 →` / `← 16` `16 →` `← 32` `32 →`. Captions: `beat`, `1 bar`, `4 bars`, `8 bars`.
Blue-tinted glass. Quantize respected.

**Tool pages** (entered from Deck options or long-press; replace the pad grid until `Done`):
- Key shift: `♭ −1` `♯ +1` `♭ −2` `♯ +2` / `Key Sync` `Reset` `Key Lock` `Done`
- Beat grid: `← Grid` `Grid →` `1.1 Here` `Tap` / `BPM ÷2` `BPM ×2` `Reset` `Done`

While a tool page is up, the tab row is replaced by a 40 pt glass banner:
`Key shift — Deck A` or `Beat grid — Deck A`, with a trailing `Done` button.

### 1.8 Dock (72 pt glass capsule, pinned 24 pt above the home indicator)

| Element | Copy | Behaviour |
|---|---|---|
| Library button (52 pt circle, list icon) | — | Load sheet for the focused deck. A11y `Load track to Deck A`. |
| Crossfader | labels `A` (brass) · `CROSSFADER` (ink3) · `B` (blue) | 28 pt track, 44 × 28 thumb, centre detent snap (`DJFaderMapping.snapped`), `.selection` haptic at centre. |
| Mixer button (52 pt circle, sliders icon) | — | Mixer sheet. Shows a 6 pt dot when any EQ/filter/trim is off-centre. A11y `Mixer`. |

---

## 2. Load sheet

Keep the existing `DJLoadSheet` content. Changes:
- Title `Load to Deck A` with an `A | B` segmented target at the top right (defaults to the focused/tapped deck).
- Each row shows `DJLoadTrackInfo` BPM and key, plus a compatibility badge versus the *other* deck:
  `Key match` (green) when Camelot-compatible, `±2%` when BPM is within the tempo range.
- If the target deck is on air, the row button reads `Hold to replace` and needs a 1 s hold (existing rule), with a ring-fill.

---

## 3. Mixer sheet (Tier 2)

`.sheet` with detents `[.fraction(0.78), .large]`, glass background, grabber visible,
`presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.78)))` so the
deck chips and waveforms above stay live.

### 3.1 Header

`Mixer` (22 pt bold) · segmented `Channels | Master` · capsule `Auto Gain` with a green dot when on (`autoGain`).

### 3.2 Channels page

Two glass channel cards side by side (A left, B right). Each card:

| Row | Copy | Binding |
|---|---|---|
| Header | badge + track title | `deck.row` |
| Knob column (40 pt knobs, 52 pt rows) | `TRIM 0` · `HI 0` · `MID 0` · `LOW +3.9` · `FILTER` | `trim`, `eqHigh/Mid/Low` (`DJKnobMapping.display`), `colorFX` (`DJKnobMapping.cfxLabel`; shows `LPF 40` / `HPF 20`, blank when off) |
| Meter + channel fader | 16-segment meter (green / amber / red), vertical fader | `peakMeter`, `peakHold`, `channelLevel` |
| Cue button | headphones icon + `Cue`, active → `Cue · listening` | `toggleCue(id)` |

Knobs: vertical drag adjusts, double-tap resets to centre (with `.selection` haptic), and a VoiceOver adjustable action steps 1 dB.
EQ arcs are bipolar from 12 o'clock.

Below the cards, one glass group with three slider rows (label 92 pt · slider · mono value):
`Master` `93%` (`masterLevel`) · `Headphones` `70%` (`headphoneLevel`) · `Cue ⇄ Master` `50%` (`cueMasterMix`, centre detent).

### 3.3 Master page

| Group | Rows |
|---|---|
| Master isolator | three knobs `LOW` `MID` `HI` (`isolatorLow/Mid/High`) + `Reset` button (`flatMix`) |
| Bass swap | horizontal fader labelled `A bass` … `B bass` (`bassFader`) with explanatory caption `Swap basslines without touching the crossfader` |
| Headphone output | segmented `Stereo` · `Split L` · `Split R` (`outputMode`), caption from `DJOutputMode.helpText` |
| Recording | `Record mix` switch + elapsed time; caption `Saved to Files › Platterhead` |

---

## 4. Deck options sheet (Tier 3)

`.sheet` with detents `[.medium, .large]`. Header: letter badge · `Deck A` (17 pt bold) ·
subtitle `African Vibe · DHDMusic` · `Done` (white capsule).

### 4.1 Playback group (inset-grouped glass list, switches)

| Row | Subtitle | Binding |
|---|---|---|
| `Key lock` | `Tempo changes won't change pitch` | `masterTempo` |
| `Slip` | `Loops and scratches snap back in time` | `slip` |
| `Quantize` | `Cues and loops land on the beat` | `quantize` |

### 4.2 Tempo group

- `Tempo range` segmented `±6` `±10` `±16` `Wide` → `tempoRange` values `6`, `10`, `16`, `100` (exactly the set `cycleTempoRange` already cycles; the default stays `10`). Add no new ranges.
- Button row (44 pt): `Tap BPM` (`tapTempo`) · `Reset tempo` (`resetTempo`) · `Reverse` (`toggleDeckMode(.reverse)`; shows as selected while on).

### 4.3 Touch group

- `Waveform touch` segmented `Nudge` · `Scratch` → `vinyl` (Scratch ⇔ `vinyl == true`).
  Default for new installs is `Nudge`; existing users keep their current VINYL value.

### 4.4 Key group

- `Key` row: `−` · `8A` (mono, brass) · `+` → `setPitchShift`/key shift; `Match B` (or `Match A`) capsule → `keySync(deck:to:)`.
- `Key shift pads…` → opens the Key shift tool page (§1.7) and closes the sheet.

### 4.5 Track group

- `Beat grid…` → Beat grid tool page, closes the sheet.
- `Reanalyze track` → `onReanalyze`.

### 4.6 Footer

- `Help & gestures` → existing `DJHelpSheet`.

---

## 5. Both-decks layout (Concept B) — optional toggle

The title bar centre becomes a segmented `Focus | Both decks` when the user enables
**Settings › DJ › Show layout switch** (off by default; on automatically for the first 3 sessions).

Stack: title bar · Deck A card · mixer strip · Deck B card · coach card.

- **Deck card** (glass, deck-colour hairline): badge, title, artist, BPM (16 pt mono, deck colour) with
  remaining time; 56 pt waveform with playhead; `CUE` · `Play/Pause` · `SYNC`; four mini hot-cue pads (40 pt).
- **Mixer strip** (92 pt glass): `FILTER` knob A · crossfader (`A` · `CROSSFADER` · `B`) · `FILTER` knob B.
- **Coach card** (glass, blue tint, lightbulb icon, `Got it` button). Copy is chosen by `DJCoachPolicy` (Handoff T5):

| Situation | Copy |
|---|---|
| Nothing loaded | `Load a track on Deck A to start.` |
| A playing, B empty | `Load your next track on Deck B.` |
| B loaded, not synced | `Tap SYNC on Deck B to match A's tempo.` |
| B synced, stopped | `B is synced to A. Press Play on the next bar, then slide the crossfader toward B.` |
| B playing, crossfader < 0.35 | `Slide the crossfader toward B over the next 16 beats.` |
| Crossfader > 0.8, A still playing | `B is on air. Stop Deck A when you're ready.` |
| Keys clash (not Camelot-compatible) | `These keys clash. Try Key lock or pick a track marked Key match.` |

Coach tips can be turned off in **Settings › DJ › Coach tips** and by `Got it` (hides the current tip until the situation changes).

---

## 6. Landscape (Concept C)

Used automatically whenever width > height, in either layout.

- Top: waveform card spanning the full width (two 38 pt waveforms).
- Left deck card (A): jog platter 140 pt (existing `DJV2Jog` behaviour: vinyl/nudge, paused frame search, outer-ring beat seek) · 2 × 2 hot-cue pads · `CUE` `Pause/Play` `SYNC`.
- Centre mixer: rows `HI` `MID` `LOW` with A knob left, label centre, B knob right; `CUE A` · `CUE B`; crossfader.
- Right deck card (B): mirror of A (pads inboard, platter outboard).
- `•••` per deck sits in each deck card header; the Mixer sheet is reachable from a sliders button in the centre column.

---

## 7. Control → home map (the coverage contract)

Every `DJControlID` must appear exactly once here; `DJSurfaceMap` (Handoff T2) encodes
this table and a test fails if any case is unmapped.

| `DJControlID` | Tier | Home |
|---|---|---|
| title, loadA, loadB | 1 | Deck chips (§1.2), Library button (§1.8) |
| waveformA, waveformB, jog | 1 | Waveform card gestures (§1.3); landscape platter (§6) |
| cue, play, sync | 1 | Transport (§1.5) |
| hotCue, loop, fx, beatJump, pad1…pad8 | 1 | Pad tabs + pads (§1.6–1.7) |
| tempo, masterTempo | 1 | Tempo pill, key chip (§1.4) |
| crossfader | 1 | Dock (§1.8) |
| record | 1 | Title bar (§1.1) |
| loopIn, loopOut, loopSet, loopEnter, loopExit, loopHalf, loopDouble | 1 | Loop › In/Out page (§1.7) |
| echoOut, beatFX | 1 | Pad FX / Beat FX pages (§1.7) |
| eqHi, eqMid, eqLow, cfx, channelFaderA, channelFaderB, cueA, cueB, volume, phones, cueMaster | 2 | Mixer › Channels (§3.2) |
| mix, bass, output | 2 | Mixer › Master (§3.3); `mix` = Auto Gain + trims + isolator |
| vinyl, slip, reverse, quantize, range, reset, tap | 3 | Deck options (§4.1–4.3) |
| key, keyShift, grid | 3 | Deck options (§4.4–4.5) + tool pages |
| info | 3 | Deck options footer (§4.6) |

---

## 8. Empty, error and edge states

| State | Copy / behaviour |
|---|---|
| First launch, both decks empty | Waveform card shows `Load two tracks to start mixing` with a `Browse Library` button; pads disabled at 40% opacity. |
| Load failure | Existing `DJ Audio` alert; the chip readout shows `Couldn't load` in `danger`. |
| Analysis running | Chip readout `Analyzing…`; the waveform draws as bins arrive; BPM `—` until known. Never a fake number. |
| Sync unavailable (no BPM) | SYNC disabled; tap shows toast `Sync needs a BPM — analysis is still running`. |
| Recording at < 500 MB free | Toast `Low storage — recording will stop at 200 MB free`. |
