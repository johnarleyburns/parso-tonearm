import Testing

/// Historical umbrella that used to carry `.serialized` + a recursive
/// `.timeLimit` to protect tests touching real process-wide singletons and
/// real `AVPlayer`s.
///
/// Those tests now use deterministic seams instead:
/// - `AudioPlayer.makeForTesting()` + `FakePlayerEngine` (no real `AVPlayer`),
/// - `InMemoryPlaybackStatePersistence` / `InMemoryDefaultsStore` (no real
///   App Group file or preferences domain),
/// - async waits instead of `RunLoop`/`Thread.sleep`/`DispatchSemaphore`.
///
/// It stays as the nesting point for `extension SharedProductionSingletonTests
/// { @Suite struct Foo { ... } }`, but applies no scheduling traits. Nothing
/// left under it constructs a real `AVPlayer` or mutates real preferences
/// state, so no suite needs the old umbrella-wide serialization. A few tests
/// still read production singletons (`LibraryStore.shared`,
/// `AudioCache.shared`) with unique ids/keys chosen to coexist with one another.
@Suite
struct SharedProductionSingletonTests {}
