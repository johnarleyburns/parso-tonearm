import Testing

/// Umbrella suite for tests that read/write real production singletons
/// (`AudioPlayer.shared`, `LibraryStore.shared`, `PlaybackStateFileStore`'s and
/// `PlaybackStateStore`'s static overrides). Swift Testing parallelizes across
/// suites by default; `.serialized` here forces every nested suite declared
/// via `extension SharedProductionSingletonTests { @Suite struct Foo { ... } }`
/// to run one at a time relative to each other, matching the serial execution
/// these tests always had under `swift test` with XCTest. Suites that do not
/// touch one of those shared singletons must not be nested here — nesting is
/// what pays the serialization cost, so it is reserved for tests that
/// actually need it.
@Suite(.serialized)
struct SharedProductionSingletonTests {}
