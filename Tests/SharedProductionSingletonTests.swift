import Testing

/// Umbrella suite for tests that either (a) read/write real production
/// singletons (`AudioPlayer.shared`, `LibraryStore.shared`,
/// `PlaybackStateFileStore`'s and `PlaybackStateStore`'s static overrides,
/// `AudioCache.shared`'s real actor), or (b) construct a real `AudioPlayer()`
/// instance at all — every one carries a real `AVPlayer`, `NWPathMonitor`,
/// and Combine subscriptions, and CI logs showed that running many of these
/// concurrently (Swift Testing's default) can make a real local `AVPlayerItem`
/// never reach `.readyToPlay` and can leave the whole `swift test` process
/// unable to exit even after every test has already reported a result,
/// needing a forced kill of an orphaned `swiftpm-testing` process. `.serialized`
/// here forces every nested suite declared via `extension
/// SharedProductionSingletonTests { @Suite struct Foo { ... } }` to run one at
/// a time relative to each other — both for the shared-singleton race this
/// umbrella originally existed for, and for the real-AVFoundation-resource
/// contention above. Suites that touch neither must not be nested here —
/// nesting is what pays the serialization cost, so it is reserved for tests
/// that actually need it.
///
/// `.timeLimit` is unconditionally recursive (`TimeLimitTrait.isRecursive`
/// is always `true`), so this applies to every nested test the same way
/// `.serialized` does. It exists as a safety net, not a fix: two different CI
/// runs on this branch's self-hosted runner each hung indefinitely on a
/// different one of these tests the first time it actually touched a real
/// `@MainActor` production singleton concurrently with this group's own
/// serialized scheduling — a genuine environment/concurrency risk inherent to
/// exercising real shared, `@MainActor`-isolated state under Swift Testing's
/// default parallelism, not something traceable to any one test's own body.
/// A future recurrence now fails fast with a clear time-out naming the actual
/// test, instead of blocking CI for up to the workflow's full 90-minute
/// timeout.
@Suite(.serialized, .timeLimit(.minutes(2)))
struct SharedProductionSingletonTests {}
