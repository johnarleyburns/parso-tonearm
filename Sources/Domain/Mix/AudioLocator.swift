import Foundation

/// Where a track's audio bytes come from. Durable identity is the provider + stable ID; a cached
/// URL is refreshable cache data and never identity.
public enum AudioLocator: Sendable, Equatable {
    /// A Jamendo catalog track. `cachedURL` may be stale; `expiry` says when it should be refreshed.
    case jamendo(trackID: String, cachedURL: URL?, expiry: Date?)

    /// The Jamendo track ID this locator is for, if any.
    public var jamendoTrackID: String? {
        if case .jamendo(let id, _, _) = self { return id }
        return nil
    }
}

/// Why opening a Jamendo stream failed, as far as locator refresh is concerned.
public enum JamendoLocatorFailure: Error, Sendable, Equatable {
    /// 401/403/404/410 or an unplayable URL: the cached locator is stale; refresh from identity.
    case expiredOrInvalid
    /// Network blip or 5xx: retry with bounded backoff, no refresh.
    case transient
    /// Not recoverable (e.g. not licensed for streaming): stop and report truthfully.
    case permanent

    /// Maps an HTTP status from the ordinary remote loader: 401/403/404/410 stale, 408/429/5xx transient.
    public static func classify(httpStatus: Int) -> JamendoLocatorFailure {
        switch httpStatus {
        case 401, 403, 404, 410: return .expiredOrInvalid
        case 408, 429, 500...599: return .transient
        default: return .permanent
        }
    }
}

public enum JamendoResolveError: Error, Sendable, Equatable {
    case refreshFailed
    case permanent
    case transientExhausted
}

/// Resolves a playable Jamendo URL from provider identity and opens it, refreshing an expired
/// locator exactly once. Pure async logic: no decoding, nothing on the render callback.
public struct JamendoLocatorResolver: Sendable {
    public var maxTransientAttempts: Int
    public var backoff: @Sendable (Int) -> TimeInterval
    public var sleep: @Sendable (TimeInterval) async throws -> Void
    /// Asks Jamendo for a fresh stream URL for a stable track ID.
    public var refresh: @Sendable (_ trackID: String) async throws -> (url: URL, expiry: Date?)

    public init(maxTransientAttempts: Int = 3,
                backoff: @escaping @Sendable (Int) -> TimeInterval = { 0.5 * Double($0 + 1) },
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
                    try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
                },
                refresh: @escaping @Sendable (String) async throws -> (url: URL, expiry: Date?)) {
        self.maxTransientAttempts = max(1, maxTransientAttempts)
        self.backoff = backoff
        self.sleep = sleep
        self.refresh = refresh
    }

    /// Opens `locator` with `open` (a bounded range stream). A missing/expired cached URL is
    /// refreshed before opening; an expired/unauthorized/invalid failure refreshes once and retries.
    /// Cancellation propagates as `CancellationError`.
    public func open<T: Sendable>(_ locator: AudioLocator, now: Date = Date(),
                                  _ open: @Sendable (URL) async throws -> T) async throws -> T {
        guard case .jamendo(let trackID, let cached, let expiry) = locator else {
            throw JamendoResolveError.permanent
        }
        var refreshed = false
        var url: URL
        if let cached, expiry.map({ $0 > now }) ?? true {
            url = cached
        } else {
            url = try await refreshURL(trackID)
            refreshed = true
        }
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                return try await open(url)
            } catch is CancellationError {
                throw CancellationError()
            } catch let failure as JamendoLocatorFailure {
                switch failure {
                case .permanent:
                    throw JamendoResolveError.permanent
                case .expiredOrInvalid:
                    if refreshed { throw JamendoResolveError.refreshFailed }
                    url = try await refreshURL(trackID)
                    refreshed = true
                case .transient:
                    attempt += 1
                    if attempt >= maxTransientAttempts { throw JamendoResolveError.transientExhausted }
                    try await sleep(backoff(attempt - 1))
                }
            }
        }
    }

    /// Resolves a fresh URL from durable identity for an AVPlayer load. Unlike `open`, it does
    /// not trust a cached URL whose validity AVFoundation cannot preflight.
    public func refreshOnly(_ locator: AudioLocator) async throws -> (url: URL, expiry: Date?) {
        guard case .jamendo(let trackID, _, _) = locator else { throw JamendoResolveError.permanent }
        return try await retryingRefresh(trackID)
    }

    private func refreshURL(_ trackID: String) async throws -> URL {
        try await retryingRefresh(trackID).url
    }

    /// `refresh` itself — a single HTTP round trip asking Jamendo for a track's current stream
    /// URL — gets the same bounded retry/backoff `open`'s own transient-failure path already gives
    /// the later streaming step. Without this, a momentary timeout/DNS blip/5xx here permanently
    /// failed the whole play attempt even though the identical blip, one layer down, was already
    /// absorbed. `refresh`'s errors aren't classified (no HTTP status is available at this layer),
    /// so every failure but cancellation gets the bounded retry — there is nothing else to try.
    private func retryingRefresh(_ trackID: String) async throws -> (url: URL, expiry: Date?) {
        var attempt = 0
        while true {
            do {
                return try await refresh(trackID)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                attempt += 1
                guard attempt < maxTransientAttempts else { throw JamendoResolveError.refreshFailed }
                try await sleep(backoff(attempt - 1))
            }
        }
    }
}
