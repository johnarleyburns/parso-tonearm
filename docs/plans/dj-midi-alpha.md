# MIDI — from "the code exists" to "a controller mixes the set"

**Goal, in one sentence:** a person plugs a class-compliant controller into an iPhone or iPad,
spends five minutes teaching Platterhead what its controls are, and then plays a full set with
their hands on the hardware — faders that don't jump, jogs that nudge, and a mapping that is
still there next week.

**Status when this plan was written (2026-08-15):** M6 commit 6.5 landed a well-built MIDI
stack — parsing, mapping, routing, learn, profiles, JSON interchange, `dj_v5` schema, 19 tests.
**None of it is connected to anything.** Two wires are missing and each is a one-line
consequence with a total-feature effect. Everything below is written so an agent with no prior
context can execute it end to end.

---

## 1 · Read this first: what is actually broken

Verified by reading the code, not inferred:

### 1.1 A learned mapping never reaches the engine

`WorkspaceModel.attachMidi(_:profile:)` is defined at
`Sources/DJ/Features/Workspace/WorkspaceModel.swift:1312` and is called **from nowhere** —
not the app, not the tests, not the regression lane:

```sh
grep -rn "attachMidi" Sources Tests UIRegressionTests --include="*.swift"
# -> exactly one hit: the definition
```

The MIDI screen is a separate navigation destination (`DJHomeView.swift:86`) from the
performance surface (`DJHomeView.swift:80` → `DJWorkspaceAssembly.makeModel`), and nothing joins
them. **Turning a mapped knob during a set does nothing at all.**

### 1.2 A learned mapping is never even saved

`MidiSettingsModel.init` takes `store: ControllerProfileStore? = nil`, and `persist()` is
`guard let store else { return }`. `DJHomeView.swift:86` constructs `MidiSettingsView()` with
the default model — so **`store` is nil in the shipping app** and every mapping is lost when the
user navigates away. The `dj_v5` tables are written and never used.

### 1.3 The tests could not have caught either

`UIRegressionTests/DJHardwareRegressionUITests.swift` AT-HW-03/04 assert that the MIDI *screen*
is reachable, that it is honest with no hardware, and that learn prompts and refuses to bind
nothing. `Tests/DJTests/MidiMappingTests.swift` tests the pure translation. Nothing follows a
message from `HardwareService` into the engine, and nothing asserts a mapping survives a
relaunch. **Adding those two tests is part of the fix, not a nicety** — they are the tests whose
absence allowed a whole feature to ship disconnected.

---

## 2 · What is already true (do not rebuild it)

The design is good and the split is the right one. Keep it.

- `Sources/DJ/Hardware/HardwareService.swift` — CoreMIDI plumbing only: client, input port, UMP
  parsing (MIDI 1.0 channel voice: CC `0xB`, note on/off `0x9`/`0x8`, pitch bend `0xE`),
  endpoint discovery with `msgSetupChanged` refresh, `receive(_:)` as the injectable seam, and
  an honest `lastError` when CoreMIDI refuses to start. Note-off and note-on-with-velocity-0
  are both correctly normalised to value 0.
- `Sources/DJ/Hardware/MidiMapping.swift` — `MidiAddress` (1…16 channels, as printed on the
  hardware), `MidiMessage`, `EngineAction` (with `target`/`parse` for persistence and
  `bindableActions` for the learn UI), `ValueTransform` (absolute/relative/toggle/trigger),
  `MidiBinding`, `ControllerProfile` (with `learn` replacing both the address *and* the action,
  so a half-relearn can't drive one action from two knobs).
- `Sources/DJ/Hardware/MidiRouter.swift` — pure `intent(for:profile:currentValue:)` →
  `.setContinuous` / `.press` / `.ignoredRelease`.
- `Sources/DJ/Hardware/ControllerProfileStore.swift` — `save(_:syncID:active:)`,
  `activeProfile()`, `exportData`/`importProfile`.
- `Sources/DJ/Data/DJMigrations+v5.swift` — `audio_device`, `channel_routing`,
  `controller_profile`, `midi_mapping`, `midi_binding` (§15 DDL verbatim, append-only).
- `WorkspaceModel.apply(_:)` / `applyContinuous` / `applyPress` / `currentValue(of:)`
  (`WorkspaceModel.swift:1344` onward) — every case goes through **the same public method a
  finger goes through** (`setEQKnobs`, `setCrossfader`, `toggleCue`), so a controller inherits
  the gesture journal, the transition recognisers and the Pro gate for free. **Preserve this
  property.** A second path into the engine that behaves subtly differently is the bug this
  design exists to prevent (§44.3).
- `Sources/DJ/Features/Workspace/JogGestureModel.swift` — `JogMode` (`vinyl`/`cdj`,
  `platter`/`ring`) and `Intent` (`.hold`, `.scrub(radians:)`, `.nudge(rate:)`, `.release`).
- `JogTransport` (`Sources/DJ/Features/Workspace/JogView.swift:232`) — routes those intents to
  the engine under `RTGuard.assertRTSafe`, with the tempo-bend base-rate bookkeeping already
  correct.

---

## 3 · Decisions taken up front

1. **Attaching is explicit, not automatic.** The existing doc comment on `attachMidi` is right:
   the workspace must not open a MIDI client just because one appeared, and a user with no
   controller pays nothing. Attach when the performance surface appears **and** an active
   profile exists.
2. **Soft takeover is not optional.** It is the difference between a controller that works and
   one that ruins a set on the first touch. It ships in the same milestone as the wiring.
3. **Jog goes through `JogTransport`, not a new path.** The mapping from a relative encoder to
   `.nudge`/`.scrub` is the only new code; the transport already knows how to bend tempo and
   restore it.
4. **MIDI output ships for buttons only.** LED feedback on toggles and triggers. Motorised
   faders and encoder rings are for hardware nobody here has; do not speculate.
5. **No factory profile for a controller nobody has plugged in.** A fabricated CC table is worse
   than none: it looks like it works and maps the wrong things. Ship the **guided learn
   walkthrough** (which works for every controller) as the primary answer, and add factory
   profiles only for hardware physically verified against the app.
6. **Hot cues stay unbindable** until something reads stored cue points into the workspace.
   `EngineAction.hotCue` remains in the vocabulary so a profile can carry it, and stays out of
   `bindableActions`. This is already the shipped behaviour and the reasoning is already in the
   code comment — keep both.
7. **The lane skips honestly without hardware** (§53.4). CI has no controller. The regression
   lane drives `HardwareService.receive` — a real seam, not a mock — so it tests the whole path
   below CoreMIDI without pretending a device is present.
8. **Every commit lands with its tests.** One task per commit, on `main`. Set the `git commit`
   timeout to **at least 300 s**; the pre-commit hook runs the full local suite.

---

## 4 · Commit sequence

### M1 — connect the wires (the blocking one)

Two changes, both small; without them nothing else in this plan matters.

**Persist the mapping.** `Sources/Features/DJ/DJHomeView.swift:86` constructs
`MidiSettingsView()` with a store-less model. Give it a real `ControllerProfileStore` backed by
the DJ database, and load the existing active profile at construction so the screen shows what
the user already taught it rather than an empty table.

**Attach it to the workspace.** In `DJWorkspaceAssembly.makeModel`
(`Sources/DJ/Features/Entry/DJEntryModel.swift:59`), after the model is built:

```swift
// §44.3, FR-HW-1: a mapped controller reaches the engine through the same
// methods a finger does. Attaching is explicit and conditional — no active
// profile means no MIDI client is opened at all.
if let profile = try? ControllerProfileStore(...).activeProfile() {
    let hardware = HardwareService()
    hardware.start()
    model.attachMidi(hardware, profile: profile)
}
```

Hold the `HardwareService` on the `WorkspaceModel` (it currently only keeps `midiTask` and
`midiProfile`) so it outlives the assembly call, and call `detachMidi()` when the surface goes
away. `HardwareService.deinit` already disposes the port and client.

There is a **latent bug in `attachMidi` to fix while you are here**
(`WorkspaceModel.swift:1320–1324`): `currentValue` is computed as

```swift
currentValue: self.currentValue(of: profile.binding(for: message.address)?.action ?? .crossfader)
```

An unbound address falls back to `.crossfader`, so an unmapped relative encoder reads the
crossfader's value as its base. The lookup should happen once, and an unbound address should
return before any value is read.

- Tests (`Tests/DJTests/`): a message injected through `HardwareService.receive` with a bound
  crossfader moves `model.crossfader`; an unbound address changes nothing; `detachMidi` stops
  delivery; a saved profile round-trips through `ControllerProfileStore` and comes back from
  `activeProfile()`.
- Regression lane: extend `DJHardwareRegressionUITests` with **AT-HW-06** — open the decks with
  an active profile, inject a CC, assert the crossfader identifier's value changed. Skip with a
  stated reason if the build has no injection hook.
- Gate: `swift test` green; a mapping survives navigating away and back.

### M2 — soft takeover

`ValueTransform.apply` in `.absolute` mode (`MidiMapping.swift`) returns the control's position
directly. Physical fader at 100 %, app at 20 %, first touch → the channel slams to full, in
front of people. Every DJ hits this within a minute of loading a controller mid-set or switching
which deck a control addresses.

Add takeover as a per-binding property, resolved in the router so it stays pure and testable:

```swift
public enum Takeover: String, Sendable, Codable {
    case jump      // today's behaviour; correct for a control the user is already holding
    case pickup    // ignore until the physical control crosses the engine value
    case scale     // move relative to the engine value, proportional to remaining travel
}
```

`pickup` needs one bit of memory per address, which must **not** live inside the pure router.
Keep the router a function and let the caller own the state:

```swift
public struct TakeoverState: Sendable, Equatable {
    // per address: whether the control has been picked up, and the last raw value seen
}

public static func intent(for message: MidiMessage,
                          profile: ControllerProfile,
                          currentValue: Float,
                          takeover: inout TakeoverState) -> Intent?
```

Add `.awaitingPickup(EngineAction, distance: Float)` to `Intent` so the UI can show the user
which way to move the control. Engage when the incoming value is within a small tolerance of
the engine value **or** when it crosses it since the previous message; once engaged, stay
engaged until the binding is re-attached or the action is driven from the touchscreen.

- Default `Takeover` per action: `pickup` for `channelFader`, `crossfader`, `eq`, `filter`,
  `tempo`, `stemGain`; `jump` is meaningless for buttons and is ignored there.
- Tests: a fader at 1.0 against an engine value of 0.2 produces `.awaitingPickup` until it
  crosses 0.2, then `.setContinuous`; the crossing is detected in both directions; tolerance
  behaviour at the ends of travel (a control already at 0 or 1 must be able to pick up);
  `jump` reproduces today's behaviour exactly so existing tests stay valid.
- UI: show the pending control in the workspace — a small "catch" indicator on the affected
  control. Without feedback, pickup feels identical to a broken fader.
- Gate: `swift test` green; no existing test changed except by adding the new parameter.

### M3 — jog wheels

`EngineAction` has no jog case, so the largest surface on every DJ controller is unbindable —
no nudge, no search, no scratch. This is what a tester reaches for the moment the beat drifts,
and its absence reads as "MIDI support is fake".

- Add to `EngineAction`: `case jog(deck: DeckID)` (continuous, relative) and
  `case jogTouch(deck: DeckID)` (the platter's touch sensor — a note or CC that most
  controllers send on capacitive touch). Add both to `target`/`parse` (`deckA.jog`,
  `deckA.jogTouch`) and to `bindableActions`.
- `JogTransport` is currently `internal` and declared **inside**
  `Sources/DJ/Features/Workspace/JogView.swift`. Move it to its own file
  (`Sources/DJ/Features/Workspace/JogTransport.swift`) and make it reachable from
  `WorkspaceModel` without importing a view. Do not duplicate it — one transport, one set of
  base-rate bookkeeping, or a MIDI nudge and a finger nudge will fight over `bendBaseRate`.
- Map in `WorkspaceModel.applyContinuous`/`applyPress`:
  - `jog` from a **relative** transform → `.nudge(rate:)` while moving, and `.release` when the
    encoder goes quiet (a short idle timer — controllers do not send "I stopped").
  - `jogTouch` press → `.hold`, release → `.release`. This is the one place `ignoredRelease`
    must **not** be ignored; handle it explicitly rather than weakening the rule for pads.
  - In `vinyl` mode a touched jog should `.scrub(radians:)` instead of `.nudge`; read the deck's
    `jogMode` (`WorkspaceModel.swift:2048`) rather than adding a second mode setting.
- Tests: relative encoder ticks produce `.nudge` with the expected sign and magnitude; idle
  produces exactly one `.release`; touch/release pairs produce `.hold`/`.release`; a MIDI nudge
  and a touchscreen nudge do not both claim `bendBaseRate`.
- Gate: `swift test` green; `RTGuard.assertRTSafe` still passes on the jog path (AT-TWIN-4).

### M4 — the guided learn walkthrough

Today a tester must open the mapping table and learn ~30 controls one at a time before their
first mix. That is where they stop.

- Add a "Set up my controller" flow to `MidiSettingsView` that walks the essential set in
  performance order and can be exited at any point with a usable partial mapping:
  crossfader → deck A/B channel faders → deck A/B play → deck A/B cue point → deck A/B
  headphone cue → deck A/B EQ (low/mid/high) → deck A/B filter → deck A/B tempo → deck A/B jog
  + jog touch → record.
- Reuse `beginLearning`/`commitLearning` unchanged — the two-step capture-then-confirm is
  already right, and the reasoning (a knob streams values while moving) is already in the code.
- Show progress ("6 of 18"), allow skip, and **name what the control will do in DJ words**, not
  in `EngineAction` words.
- Tests: the walkthrough's action list matches `bindableActions` membership (no step offers
  something unbindable); skipping leaves earlier bindings intact; completing writes one profile
  with the expected count.
- Gate: `swift test` green; AT-HW-04 still green.

### M5 — LED feedback (MIDI output)

`HardwareService` creates only `MIDIInputPortCreateWithProtocol`. There is no
`MIDIOutputPortCreate` and no `MIDISend` anywhere in `Sources/`. Every button on the controller
stays dark, and a user cannot tell what is mapped or what state a toggle is in by looking at
the hardware.

- Add an output port and a destination matching the connected source (same device name /
  `kMIDIPropertyDisplayName`), with an honest `lastError` when there is no destination — some
  controllers are input-only and that is not a failure.
- Send feedback for **toggle and trigger bindings only**: when the engine-side state of a bound
  action changes, send that address's on/off value back. Derive it from the existing published
  workspace state; do not add a second source of truth.
- Throttle. A controller that receives a message per render tick will flood its own input and
  some will echo it back — which is exactly the traffic `MidiRouter` documents as the reason an
  unmapped control must do nothing silently.
- Tests: state change → one message with the bound address; no destination → no crash and an
  honest error; the throttle collapses a burst.
- Gate: `swift test` green; verified against real hardware **or** the commit says plainly that
  it is unverified on hardware.

### M6 — 14-bit CC

A 7-bit tempo fader gives 128 steps across ±8 % — 0.125 % per step, audible as stepping on a
long blend. Pioneer and Traktor pitch faders send MSB/LSB pairs (CC *n* and CC *n+32*).

- Add `resolution: .sevenBit | .fourteenBit` to `MidiBinding` (default `.sevenBit`).
- Assemble pairs in a new pure `MidiValueAssembler` **above** `HardwareService.parse` — parse
  stays stateless and per-packet. Pair CC *n* with CC *n+32* arriving within a short window;
  emit a 0…16383 value.
- Opt-in per binding, never inferred: a plain CC in 0…31 that is *not* part of a pair would
  otherwise wait forever for an LSB.
- Offer it in learn only when the assembler actually observed a pair during capture — that is
  the honest signal, and it saves the user understanding the MIDI spec.
- Tests: MSB then LSB assembles; MSB alone after the window emits the 7-bit value; out-of-order
  and interleaved pairs from two controls do not cross-contaminate.
- Gate: `swift test` green.

### M7 — multi-device honesty

`HardwareService.connect` deliberately supports several sources at once (its comment: "a
controller plus a foot switch is an ordinary rig"), but `connectedEndpointID` is a single value,
so the UI can only ever show one as connected and disconnect detection only tracks one.

- Make it a set; render every connected endpoint; drop from the set on `msgSetupChanged`.
- Tests: two endpoints connect and both show; unplugging one leaves the other connected.
- Gate: `swift test` green.

### M8 — factory profiles, for verified hardware only

Only after M4, and only for a controller physically tested against the app.

- Ship `ControllerProfile` JSON in the bundle (the format already exists — `exportData`/
  `importProfile` round-trip it) plus a `BundledProfiles` catalogue matched on `endpointName`.
- On first connect of a matching endpoint, **offer** the profile; never apply it silently.
- Tests: every bundled JSON decodes, and every action it names round-trips through
  `EngineAction.parse` (a profile from a newer version with an unknown target must not silently
  bind something else — `parse` already returns nil for unknown targets; assert it).
- Gate: `swift test` green.

---

## 5 · What "a good MIDI alpha" means, minimally

If time runs out, this is the cut line:

| | Required for a usable alpha |
|---|---|
| **M1** | Yes — without it the feature does not exist |
| **M2** | Yes — without it the first touch ruins a mix |
| **M3** | Yes — without it the controller's biggest surface is dead |
| **M4** | Yes — without it most testers never finish mapping |
| M5 | No — the controller feels dead but works |
| M6 | No — stepping on the pitch fader is survivable |
| M7 | No — cosmetic |
| M8 | No — M4 covers every controller |

**Write into the tester note:** no factory profiles, so a controller must be MIDI-learned; hot
cues are not bindable because nothing reads stored cue points yet; and (until M5) no LED
feedback, so the controller's lights will not reflect app state.

---

## 6 · Risks, ranked

1. **A second path into the engine.** The current design's best property is that MIDI and a
   finger go through the same public methods. Adding jog and takeover is exactly where someone
   will be tempted to reach into the engine directly. Any new `EngineAction` case must land in
   `applyContinuous`/`applyPress` and call an existing public method.
2. **Takeover state leaking into the router.** Keep `MidiRouter` a pure function; the moment it
   owns mutable state it stops being testable without a controller, which is the property that
   makes this stack verifiable at all.
3. **Jog fighting itself.** `bendBaseRate` is per-`JogTransport`. Two transports for one deck —
   one from the view, one from MIDI — will restore the wrong rate. One transport per deck,
   owned by the model.
4. **Feedback loops.** LED output echoing into input is a real failure mode on some controllers
   and looks like ghost automation. The throttle and the "unmapped controls do nothing" rule are
   the defences.
5. **Testing against nothing.** No hardware here means every claim is about `receive`, not about
   CoreMIDI. Say so in commits. The lane must skip, not fake, and a commit that has not touched
   hardware should say it has not.

---

## 7 · Definition of done

- A CC injected through `HardwareService.receive` moves the crossfader on the performance
  surface, asserted by a test **and** by the regression lane.
- A mapping learned on the MIDI screen is still there after force-quitting and relaunching.
- A physical fader at the wrong position does not jump the engine value; the UI shows which way
  to move it.
- A relative encoder bound to jog nudges the deck and releases cleanly.
- The guided walkthrough takes a new user from nothing to a playable mapping without opening
  the full table.
- `swift test` green; `LANES=djmix` still green; `LANES=djhw` green or honestly skipped.
- `current_status.md` updated, and the tester note lists what is not there.
