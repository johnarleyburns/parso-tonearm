# Platterhead DJ — manual device test script

**For the owner, on a real device, against a TestFlight build.** Everything in
this repository is a simulator claim; the simulator's audio is the Mac's Core
Audio and its thermal state is fiction. This script is the pass that turns
"tested" into "works", and it is the last agent-unreachable gate on M5 (plan
`dj-phase-4-stems-recording.md` §1 item 6) plus the deferred gates from M3, M4
and the stems plan.

Work top to bottom. **§1 is the milestone's own exit narrative** — if only one
section gets run, run that one. §§2–11 are the subsystem passes, and §12 is the
numbers table the plans are actually waiting on.

Write results straight into this file (it is version-controlled) or into a copy;
the point of the numbered expectations is that a failure can be reported as
"7.3 failed" rather than as a paragraph.

---

## 0 · Before you start

| | |
|---|---|
| **Build** | TestFlight, version shown on the DJ home screen's purchase row area / Settings → About |
| **Device** | Record which: model, iOS version, storage free, battery % |
| **Conditions** | Not plugged in, Low Power Mode **off**, Do Not Disturb **on** (a notification mid-set is its own test, later) |
| **Headphones** | Have wired or BT headphones ready, plus a splitter cable for §9 if you have one |

**What is in this build**

- Genre libraries (Jamendo) — the client key is compiled in; genres must list.
- Semantic search / auto-playlists — the CLAP models ship over On-Demand
  Resources.
- **Stems — first build that has them.** The Demucs model ships over ODR too.
- MIDI — learn/mapping/jog/soft-takeover, no factory profiles.

**Known limits, so they are not reported as bugs**

- **No factory MIDI profiles.** A controller must be MIDI-learned; the guided
  walkthrough does it in about two minutes.
- **No LED feedback.** A controller's lights will not reflect app state.
- **Hot cues are not bindable** to MIDI — nothing reads stored cue points yet.
- **Split cue makes the master mono.** The app says so where the mode is chosen.
- **Mixes are local-only.** No iCloud sync in this build; "Keep on device" is
  the only path.
- **Export is M4A/AAC, not MP3.** The platform ships no system MP3 encoder.
- **ODR is a download.** The first use of semantic search or stems fetches the
  model from Apple over the network. On a slow connection the honest
  "unavailable" state is what you will see until it lands — that is not a defect
  unless it never resolves.

---

## 1 · The milestone narrative, end to end (the M5 exit gate)

One continuous session. Do not skip steps; the point is that it works as a
sequence, not that each part works alone.

1. **Open the app → DJ tab** (the dock's slider icon). The home screen reads
   **Platterhead DJ** with sections in this order: Purchase; **Library**
   (Playlists, Recorded Mixes); **Perform** (Open DJ Mixer); **Hardware** (MIDI
   controller). "Playlists" opens the Playlists screen as a sheet.
2. **Pick a genre.** Libraries → **Add** → **Add Remote Library** → the Jamendo
   genre connector → expand **Electronic** → select **Techno** *and* **House** →
   **Add**.
   - ✅ The genre list is **populated**. A "not configured" state here means the
     Jamendo key did not reach the build — stop and report, the rest of the
     narrative depends on it.
3. **Browse each genre** and confirm the track list is ordered by interest, with
   real titles and artists.
4. **Add each genre to its own playlist.** In the genre's browse screen tap the
   header **+** → set the count (the stepper, or the slider for a big library) →
   the playlist picker → **Create a new playlist…** → name it for the genre →
   **Add**.
   - ✅ The sheet reports the outcome honestly ("N added · N unavailable") and
     the tracks download as they land. A playlist is now the crate concept —
     there is no "Send to DJ" button, by design.
5. **DJ → Open DJ Mixer → CRATE.** The sheet has a half for each deck. On deck
   A's half tap **Import playlist**, expand **Techno** to see its songs, select
   it and **Import**; do the same on deck B's half with **House**. Each half's
   header then reads `DECK A — Techno` / `DECK B — House`.
   - ✅ A track whose audio is not on the device is listed as **not on this
     device** and reported as skipped — never silently dropped.
   - ✅ The crate sheet never covers the crossfader bar.
6. **Load from the crates.** Tap a Techno row on deck A and a House row on deck
   B, each from its own half.
   - ✅ The waveforms are **real** — band-split colour, a phrase ribbon, a beat
     grid that lines up with what you hear. Placeholder geometry (flat, uniform,
     identical between tracks) is a failure.
7. **Play both. Beatmatch and mix**, using all five transitions at least once:
   **Bass Swap, Filter, Echo Out, Fader Cut, Blend** (§2 below has what each
   should sound like). The transitions panel is the **?** in the surface's
   top-right corner.
8. **Record a 20-minute set** — the record chip in the transport. Keep mixing;
   change tracks as you go.
9. **Stop and finish.** Title it. The finish sheet shows duration, **M4A · AAC
   256 kbps**, file size, the timeline of what played, and attribution.
10. **Listen to it immediately, in the app** — the review-listen transport on the
    finish sheet. Scrub it. Tap a green transition marker.
    - ✅ It plays *in place*, with no export step and no re-encode wait.
11. **Export and share it** — Save to Files and/or the share sheet. Play the
    exported file somewhere else: Music, QuickTime, another phone.
    - ✅ It plays elsewhere, start to end, and sounds like the set you performed.

**This section passes only if all eleven do.** Note anything that surprised you
even if it technically passed — this is the narrative a first tester meets.

---

## 2 · The five transitions — what each should sound like

Perform each deliberately, on a phrase boundary, and judge by ear.

| # | Transition | Controls | Passes when |
|---|---|---|---|
| 2.1 | **Bass Swap** | LOW EQ on both channels | The outgoing deck's low disappears and the incoming deck's low takes over, while both mids keep playing. No hole in the middle, no doubling boom. |
| 2.2 | **Filter** | The channel's FILTER (sweep) | Sweeping up thins the outgoing deck from the bottom; the top stays. Returning to centre is a **hard bypass** — the low comes back exactly as it was, not approximately. |
| 2.3 | **Echo Out** | ECHO on + channel fader down | The echo tail keeps ringing **after** the fader is down, in time with the beat, decaying to nothing. If the tail dies with the fader, the echo is in the wrong place in the chain — report it. |
| 2.4 | **Fader Cut** | Channel fader, fast | The channel goes away inside one beat, cleanly. **Listen for a click.** A zipper here is a real defect. |
| 2.5 | **Blend** | Crossfader to centre | Both decks audible together for eight bars, phase-locked, and the master never clips or pumps. |

---

## 3 · Stems — first device pass (this is the S7 gate)

The stems model ships in this build and **has never run on real hardware**. This
section is the measurement the plan is waiting for; take the numbers.

1. Load a track and open the deck's **STEMS** module (the module slot on iPad;
   the stem faders on the compact surface).
2. Ask for separation.
   - ✅ The state is honest throughout: **"stems not prepared" → "separating…" →
     prepared with live faders**. A fader that looks live and does nothing is the
     defect this design exists to prevent.
3. **Time it.** Start a stopwatch when separation begins and stop when the faders
   go live. Note the track's length.
4. While it runs, watch the thermal readout on the workspace.
5. When prepared: pull the **vocal** fader to the floor mid-playback.
   - ✅ The vocal goes away and the rest keeps playing, with no click and no
     level jump on the other stems.
6. Mute/solo each stem in turn. Play with all four under a live mix.
7. Force it: separate a second track **while a set is recording**. The lane is
   supposed to yield to audio and to abandon on a serious thermal state.
   - ✅ Audio never glitches. If the device gets hot, separation stops rather
     than the music.

**Write down** (§12 table): seconds per separation, track length, peak memory if
you can get it (Xcode → Devices, or the workspace's own memory readout), thermal
state at start and end, and whether any device class reported stems
**unavailable** rather than running.

---

## 4 · Waveforms and analysis

1. Import or subscribe to a handful of tracks and let analysis run.
2. ✅ Each waveform is distinct, band-split coloured, with a phrase ribbon and an
   overview.
3. ✅ The beat grid lines up with the beat by ear — start playback and watch the
   playhead cross gridlines on the beat.
4. ✅ The BPM readout matches a tap-tempo check within a fraction of a BPM.
5. Nudge a grid correction if the grid is off; ✅ it holds after leaving and
   returning to the deck.

---

## 5 · Recording, crash safety, and the artifact

1. Start a recording. Let it run **at least two minutes**.
2. **Force-quit the app** (swipe it away) mid-recording.
3. Reopen → DJ → **Mixes**.
   - ✅ The recording is there, playable, and has lost **at most the last
     segment** (30 seconds). A missing or corrupt file is a hard failure — this
     is NFR-REL-2.
4. Record a second set. Stop it normally.
   - ✅ Duration on the finish sheet matches the wall clock you observed.
   - ✅ The timeline lists the tracks you actually played, in order.
5. Delete a mix from the Mixes screen. ✅ It goes, and the storage figure drops.

---

## 6 · Audio session behaviour (the physical AT-SESS-\* pass)

Each of these happens *during a live mix, while recording*.

| # | Do this | Passes when |
|---|---|---|
| 6.1 | Take a phone call (or FaceTime yourself) | Audio ducks/stops cleanly, the app says what happened, and the recording resumes or ends honestly — never a running timer with no audio |
| 6.2 | Unplug wired headphones mid-set | The classic route change: playback pauses rather than blasting the speaker |
| 6.3 | Connect Bluetooth headphones mid-set | Route moves, no crash, latency is stated if the app states it |
| 6.4 | Background the app for 60 s, come back | The mix kept playing and the recording kept recording |
| 6.5 | Lock the screen for 60 s | Same |
| 6.6 | Trigger a loud notification | Audio is not interrupted, or is interrupted honestly |

---

## 7 · Thermals and memory (AT-THERM-1 / AT-MEM-1)

1. Run a **20-minute two-deck set** with EQ, filter, echo and at least one
   separation, unplugged.
2. Every 5 minutes note: thermal state readout, whether audio glitched, render
   load, and battery %.
3. ✅ Audio never drops out. As the device heats, background work (analysis,
   separation) is shed **before** audio is affected.
4. ✅ The app does not get killed for memory. If it does, note exactly what was
   on screen and whether stems were prepared on both decks.

---

## 8 · Semantic search and auto-playlists

1. Use vibe/semantic search with a natural phrase ("late night warehouse", "sunny
   rooftop") .
   - ✅ Results are plausibly related, and arrive in a couple of seconds.
   - ✅ If the CLAP model has not downloaded yet, the app says so rather than
     returning nothing silently.
2. Generate an auto-playlist. **Time it** (§12) — the gate is a few seconds on
   device, and Low Power Mode is allowed to be slower.
3. ✅ The ordering is musically sensible: no wild BPM or key jumps between
   adjacent tracks.

---

## 9 · Headphone cue (needs a splitter cable)

1. Plug in the splitter: headphones on cue, speakers/second output on master.
2. Cue deck B while deck A plays to the master.
   - ✅ You hear B in the headphones only, **pre-fader**.
3. Try each of the three cue modes.
4. Try **split cue**. ✅ The master goes mono, and the app told you it would.

---

## 10 · MIDI (if you have a controller)

1. DJ → **MIDI** → **Set up my controller**.
2. Walk the 24 steps. ✅ Each control is named in DJ words, progress shows
   "n of 24", and skipping keeps what you already mapped.
3. Quit the app and reopen. ✅ **The mapping survived.**
4. Move a channel fader on the controller to a position that disagrees with the
   on-screen fader, then push it.
   - ✅ **Soft takeover**: the channel does not slam. The catch indicator shows
     which control and which way to move it.
5. Spin a jog wheel. ✅ It nudges the pitch; the platter touch sensor holds and
   releases; vinyl mode scrubs.
6. Touch a control on screen, then move the same control on the controller.
   ✅ No fight between them.

---

## 11 · Purchase (App Store Connect §3)

1. As a **free** user, tap **Open DJ Mixer**. ✅ The surface is the real one,
   dimmed, with a lock chip — not a blank wall.
2. Tap the lock chip. ✅ The paywall shows a **real localised price**, not a
   placeholder dash.
3. Buy it (sandbox). ✅ The decks unlock **with no relaunch**.
4. Delete and reinstall the app → **Restore**. ✅ Pro comes back, and the purchase
   row states where the grant came from.

---

## 12 · The numbers to write down

These are what the plans are actually blocked on.

### Stems (S7 gate)

| Measurement | Value |
|---|---|
| Device / iOS version | |
| Track length used | |
| Wall-clock time for one full separation | |
| Implied segments per second (≈46 segments per 5-minute track) | |
| Peak memory during separation | |
| Thermal state at start → end | |
| Any device class reporting stems unavailable? | |
| Audio glitched during separation? | |

### Thermals (AT-THERM-1) / memory (AT-MEM-1)

| Minute | Thermal state | Render load | Audio OK? | Battery % |
|---|---|---|---|---|
| 0 | | | | |
| 5 | | | | |
| 10 | | | | |
| 15 | | | | |
| 20 | | | | |

### Auto-playlists (AT-PLIST-2)

| Measurement | Value |
|---|---|
| Library size (tracks) | |
| Time to generate a playlist | |
| Same, in Low Power Mode | |

---

## 13 · Reporting

For each failure, note: **section number**, what you did, what happened, what you
expected, and whether the app **said** anything about it. The last part matters
more than it sounds — this codebase's rule is that a degraded state is announced
rather than hidden, so "it did nothing and said nothing" is a different and worse
bug than "it said the model was unavailable".
