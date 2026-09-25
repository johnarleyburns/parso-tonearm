# Basic two-waveform DJ touch mockup

Companion notes for [`dj-basic-two-deck-mockups.html`](dj-basic-two-deck-mockups.html).

## Surface and orientation

- Portrait and landscape previews are shown together.
- Both orientations use the same structure: app header, equal-height waveform A and waveform B regions, and an equal-height two-column mixer footer.
- The header and mixer footer use the same fixed rail height in both orientations.
- The mixer and separate deck-control sections are removed. Transport and performance control happen directly on each waveform.

## Header and output routing

- The left side identifies the Platterhead DJ surface.
- The centered output button cycles `STEREO`, `SPLIT L`, and `SPLIT R`.
- `STEREO` is the normal stereo output.
- `SPLIT L` sends the mono mix to the left output and the headphone cue to the right output.
- `SPLIT R` sends the mono mix to the right output and the headphone cue to the left output.
- The `(i)` button opens the complete gesture and help sheet. Gesture instructions are not shown on the main surface.

## Loading tracks

- Tapping an unloaded waveform or its unloaded track-name area opens the **Load a track** dialog.
- Tapping the name of a loaded track also opens the dialog so it can be replaced.
- Loading a track resets its waveform volume to `0%` every time.
- Hot cues are stored per track and restored when that track is loaded again.

## Waveform gestures

- Single tap anywhere in a loaded waveform toggles play/pause.
- Pinch-to-zoom-in (fingers spread) decreases tempo by `0.1 BPM`.
- Pinch-to-zoom-out (fingers close) increases tempo by `0.1 BPM`.
- Swipe right or left nudges the track forward or backward by `1/75` of a second, whether playing or paused.
- While playing, holding and dragging back and forth produces a scratch effect.
- While paused, horizontal touch-and-drag moves the waveform underneath the stationary centered playhead. The movement follows the finger directly.
- Releasing a paused drag with velocity produces an inertial slide that decelerates naturally, like scrolling. This does not move the centered playhead.
- Vertical swipes do not control volume. The separate waveform volume faders have been removed.

## Hot cues

- The minimap is four times the height of one hot-cue button.
- Four equally sized square hot-cue buttons sit directly below the minimap.
- Buttons are flat when their track-specific hot-cue buffer is empty and lit when a position is stored.
- Tapping a blank button stores the current centered waveform-head position in registers 1–4 and persists it for that track.
- Tapping a lit button moves the waveform head to its saved position.
- Touch-and-hold a lit button for `600 ms` deletes its saved position and returns it to the flat state.

## Mixer footer

- The footer has two equal columns and the same height as the app header.
- `Bassfader` defaults to the center blend. Far left is all waveform A bass, far right is all waveform B bass, and intermediate positions blend the two bass signals.
- `Crossfader` defaults to the center blend. Far left is all waveform A volume, far right is all waveform B volume, and intermediate positions blend the two volumes.

## Visual rules

- The vertical line at the horizontal center of each waveform is the current play/pause head position.
- Waveform A uses amber accents; waveform B uses blue accents.
- BPM is shown at the bottom left; elapsed and remaining time are centered at the bottom.
- The minimap stays at the top right of the waveform region, with hot cues immediately beneath it.
