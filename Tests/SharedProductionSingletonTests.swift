import Testing

/// EXPERIMENTAL: `.serialized`/`.timeLimit` removed (2026-11-19) to test
/// whether that trait combination itself — not any test's content, not
/// concurrent real-`AVPlayer` construction — was the cause of a CI hang
/// where exactly one nested suite would run and everything after it in the
/// serialized sequence never got a turn, even past the 2-minute time limit.
/// Voxglass has no precedent for this combination: its own `.serialized`
/// usage never also carries a recursive `.timeLimit`, and none of its tests
/// touch a real shared singleton or a real `AVPlayer` at all. This umbrella
/// still exists as the nesting point for `extension
/// SharedProductionSingletonTests { @Suite struct Foo { ... } }` so those
/// files don't need touching either way; it just currently applies no
/// special scheduling. If this experiment confirms the suite runs clean,
/// decide deliberately whether any of the originally-protected tests
/// (real shared `LibraryStore.shared`/`AudioCache.shared`/`PlaybackState`
/// statics, or real-`AVPlayer` timing suites) need a different, narrower
/// protection mechanism — not a blind revert to these two traits.
@Suite
struct SharedProductionSingletonTests {}
