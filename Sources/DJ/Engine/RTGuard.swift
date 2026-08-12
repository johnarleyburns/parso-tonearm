import Foundation

/// The debug-only RT-assertion shim (§46.3, normative — non-negotiable, §49.3.1).
///
/// A render callback must never allocate, lock, or log (§12.3). To catch
/// violations during development, every render body is wrapped in
/// `withRenderContext`, which marks the calling thread as the render thread.
/// Anything that might be unsafe calls `assertRTSafe` first; under the shim
/// that traps with the offending operation named. In RELEASE everything
/// compiles out to nothing (no flag, no trap, no barrier).
public enum RTGuard: Sendable {

    #if DEBUG
    private enum ThreadKey {
        static let flag = "guru.parso.tonearm.RTGuard.inRenderContext"
    }
    #endif

    /// True when the current thread is inside an RT render callback. Always
    /// false in RELEASE builds.
    public static var isInRenderContext: Bool {
        #if DEBUG
        (Thread.current.threadDictionary[ThreadKey.flag] as? Bool) ?? false
        #else
        false
        #endif
    }

    /// Wraps a render callback body. In DEBUG this flags the calling thread for
    /// the duration; the flag is restored afterwards so the same thread may do
    /// non-RT work between callbacks. RELEASE: a passthrough that inlines away.
    @inline(__always)
    public static func withRenderContext<T>(_ body: () throws -> T) rethrows -> T {
        #if DEBUG
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[ThreadKey.flag]
        dictionary[ThreadKey.flag] = true
        defer {
            if let previous {
                dictionary[ThreadKey.flag] = previous
            } else {
                dictionary.removeObject(forKey: ThreadKey.flag)
            }
        }
        return try body()
        #else
        return try body()
        #endif
    }

    /// Returns the violation message when the current thread is the render
    /// thread, else nil. The `@autoclosure` is evaluated only on a violation,
    /// so the safe path costs nothing.
    @inline(__always)
    public static func checkRTSafe(_ what: @autoclosure () -> String) -> String? {
        #if DEBUG
        isInRenderContext ? what() : nil
        #else
        nil
        #endif
    }

    /// Debug assertion: traps if called while on the render thread. RELEASE:
    /// no-op.
    @inline(__always)
    public static func assertRTSafe(_ what: @autoclosure () -> String) {
        #if DEBUG
        if let violation = checkRTSafe(what()) {
            assertionFailure("RT-UNSAFE: \(violation) on audio thread")
        }
        #endif
    }
}
