# M6 — the live-mixing alpha: purchase, liveness, cue, stems, genres, MIDI

**Goal, in one sentence:** a person who is not us can install Platterhead from TestFlight, buy
Pro, load real music, cue the incoming track in headphones, mix it with a controller if they
own one, and record the result — without the app lying to them about any of it.

This is the working plan for the push the owner asked for on 2026-08-15, after M5 closed
(`56afb11`, `5ea1d78`). It pulls **M6 hardware work forward** (§44, FR-HW-1/2/3/4) and closes
the four alpha blockers recorded in `current_status.md`'s "Alpha readiness" section.

## 1 · What is already true (do not rebuild it)

- The mix chain works and is **proven acoustically** end to end (M5 5.14): gesture → command
  ring → engine → mixer → record tap → encoder → export, with all five §53.9 transition
  signatures verified in the app's own recording, at 6 and 20 minutes.
- The **purchase machinery exists** — `ProStore`, `ProPaywallModel`, `PaywallModel`/`PaywallView`
  (DJ), `ProPaywallView` (settings), `EntitlementStore`, `FoundersGrant`, and
  `Resources/Tonearm.storekit` carrying `guru.parso.tonearm.pro` ("Platterhead DJ"). 4.13 landed
  it. What is unverified is whether it *works against App Store Connect on a device*.
- The **stem pipeline exists and is tested** (5.7–5.9) — chunking, overlap-add, cache, budget,
  the crate lane. Only the **model** is missing: `DemucsStemModel` is an honest shell that throws
  `conversionPending` (ADR-10).
- The **Jamendo connector exists and is tested** against recorded fixtures (5.6). Only the
  **credential** is missing: `TONEARM_JAMENDO_CLIENT_ID` is empty, so a shipped build is the
  honest `.notConfigured` state.
- `AudioSessionCoordinator` already handles route changes, interruptions and media-services
  reset (4.2, 5.11). The gap is **engine-side**, not session-side.

## 2 · Decisions taken up front

1. **The Jamendo client id is an application credential and never enters the repo.** It reaches
   a local build through an untracked `Config/Secrets.xcconfig`, and TestFlight through a CI
   secret. `.jamendo_client_id`/`.jamendo_client_secret` are gitignored (done). §54.2 stands:
   no credential in a tracked file, ever.
2. **A user may supply their own Jamendo credential instead of the app's** (owner's request).
   Stored in the **Keychain**, never `UserDefaults`; the app's credential is the fallback. This
   also means the feature degrades honestly if the app's own key is ever rate-limited or pulled.
   Jamendo v3.0 read access needs only `client_id`; the `client_secret` is OAuth-only, so the UI
   asks for the id and accepts an optional secret for the OAuth path we do not use yet.
3. **Cue monitoring ships modes 2 and 3 first** (§44.2a): **split output** (master→L, cue→R,
   both summed to mono, −6 dB) and **cue-in-place**. Mode 1 (true multichannel) lands with the
   routing table but cannot be verified without hardware, so it is written to be *inert and
   honest* until a >2-channel route appears. Mode 2 is the one that makes an alpha possible on
   a phone with a $10 cable.
4. **The cue bus is pre-fader, pre-crossfader, per deck** — that is what "pre-listen" means. It
   is a second summing path inside the existing render closure, not a second engine.
5. **MIDI is data, not code** (§44.4): `dj_v5` adds `controller_profile`/`midi_binding`/
   `channel_routing`/`audio_device`; translation is a pure function so it is unit-testable
   without a controller; bundled profiles ship as JSON.
6. **Stems: convert `htdemucs` following the CLAP precedent** (`tools/clap-coreml`, commit
   `9f42cf5`) — a reproducible script under `tools/demucs-coreml/`, verified against the torch
   reference, ODR-tagged. If conversion or the licence blocks it, the deck keeps playing the
   full mix and the faders stay honestly disabled — that behaviour is already shipped and
   tested, so this can fail without failing the alpha.
7. **Every commit lands with its tests**, and the regression suite grows lanes where a lane can
   actually see the thing (§53.4's skip-versus-fail applies: no controller in CI means the MIDI
   lane skips with its remedy, it does not fake a pass).

## 3 · Commit sequence

| # | Commit | Gate |
|---|---|---|
| 6.1 | **Engine liveness** — `AVAudioEngineConfigurationChange` + `isRunning`, honest recording state, recovery | unit: a stopped graph surfaces as stopped and the recording is finalised, never a running timer over a dead engine |
| 6.2 | **Purchase path** — audit + complete: restore, states, failure surfaces, `.storekit` parity, an ASC checklist for the owner | unit: paywall states; a StoreKit-config test run |
| 6.3 | **Jamendo enabled** — xcconfig injection, Keychain-stored user credential, settings UI, honest states | unit + `LANES=djlive` green against the real API |
| 6.4 | **Cue monitoring** — cue bus, split-output matrix, cue-in-place, UI + the mono warning | unit: offline render proves master→L / cue→R and pre-fader behaviour; regression lane drives the cue button |
| 6.5 | **MIDI** — `dj_v5`, `HardwareService`, learn, bindings, bundled profiles, export/import | unit: pure translation + binding round-trip; lane skips without hardware |
| 6.6 | **Stems model** — `tools/demucs-coreml/`, ODR tag, verification | the existing `AT-STEM-*` rows go from "model absent" to real separation |
| 6.7 | **Regression coverage** — lanes for cue/MIDI/stems/live-genre + the liveness probe | `LANES=djmix` still green; new lanes green or honestly skipped |

**Then, and only then:** push → CI → TestFlight (owner's gate), with the tester note listing
what is and is not in the build.

## 4 · What stays user-owned

App Store Connect product configuration and pricing; the on-device shakedown (AT-THERM-1,
AT-MEM-1, physical AT-SESS-\*); approving the push; and buying a controller if the MIDI lane is
to be exercised against real hardware rather than a virtual endpoint.
