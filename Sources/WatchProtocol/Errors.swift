import Foundation

/// §5.5 — the stable machine codes. These raw values are wire format: renaming one is a protocol
/// change, not a refactor.
public enum WatchProtocolErrorCode: String, Codable, Sendable, CaseIterable {
    case phoneUnavailable
    case requestTimedOut
    case protocolUpgradeRequired
    case pairedLibraryChanged
    case contentNotFound
    case sourceUnavailable
    case authenticationRequired
    case waitingForWiFi
    case unsupportedAudio
    case insufficientWatchStorage
    case transferFailed
    case checksumMismatch
    case installationFailed
    case audioRouteUnavailable
    case playbackItemFailed
    case storeRecovered
}

/// What the UI is allowed to do about a code. Encoded as its own type rather than a comment so a
/// new error cannot quietly acquire a background retry loop (I-10 forbids idle polling).
public enum WatchProtocolRetryPolicy: String, Codable, Sendable {
    /// The user may retry, but only once the connection is back.
    case userRetryAfterReconnect
    /// Exactly one user-initiated retry. Never a background spin.
    case singleUserRetry
    /// Nothing retries; the app itself has to be updated.
    case appUpgradeRequired
    /// Blocked on an explicit user confirmation.
    case userConfirmationRequired
    /// Refresh the surrounding result set; do not retry the same request.
    case refreshWithoutRetry
    /// The user or the remote source has to act first.
    case externalActionRequired
    /// Resumes on its own once the network policy allows it.
    case automaticWhenPolicyPermits
    /// Permanent for this content.
    case permanentForContent
    /// The user must free space first.
    case freeSpaceThenRetry
    /// The scheduler retries with backoff, bounded.
    case boundedSchedulerRetry
    /// No retry at all — informational only.
    case informationalOnly
}

extension WatchProtocolErrorCode {
    public var retryPolicy: WatchProtocolRetryPolicy {
        switch self {
        case .phoneUnavailable: .userRetryAfterReconnect
        case .requestTimedOut: .singleUserRetry
        case .protocolUpgradeRequired: .appUpgradeRequired
        case .pairedLibraryChanged: .userConfirmationRequired
        case .contentNotFound: .refreshWithoutRetry
        case .sourceUnavailable: .externalActionRequired
        case .authenticationRequired: .externalActionRequired
        case .waitingForWiFi: .automaticWhenPolicyPermits
        case .unsupportedAudio: .permanentForContent
        case .insufficientWatchStorage: .freeSpaceThenRetry
        case .transferFailed: .boundedSchedulerRetry
        case .checksumMismatch: .boundedSchedulerRetry
        case .installationFailed: .boundedSchedulerRetry
        case .audioRouteUnavailable: .externalActionRequired
        case .playbackItemFailed: .singleUserRetry
        case .storeRecovered: .informationalOnly
        }
    }

    /// The safe display message §5.5 promises, derived from the code rather than transmitted with
    /// it. This is the whole of A-06's guarantee: because the wire carries only the enum, a
    /// diagnostic can never contain a title, a query, a URL, a token, or an absolute path — there
    /// is no field for one to travel in. Localization replaces this table in the UI layer.
    public var safeDisplayMessage: String {
        switch self {
        case .phoneUnavailable: "iPhone isn't reachable right now."
        case .requestTimedOut: "iPhone didn't answer in time."
        case .protocolUpgradeRequired: "Update Platterhead on iPhone and Apple Watch."
        case .pairedLibraryChanged: "This iPhone's library is different from the one on your watch."
        case .contentNotFound: "That item is no longer in the library."
        case .sourceUnavailable: "iPhone can't reach that source."
        case .authenticationRequired: "Sign in to that source on iPhone."
        case .waitingForWiFi: "Waiting for Wi‑Fi."
        case .unsupportedAudio: "This audio can't play on Apple Watch."
        case .insufficientWatchStorage: "Not enough space on Apple Watch."
        case .transferFailed: "The transfer didn't finish. Trying again."
        case .checksumMismatch: "The downloaded file was damaged. Trying again."
        case .installationFailed: "The download couldn't be saved. Trying again."
        case .audioRouteUnavailable: "Choose an audio output for Apple Watch."
        case .playbackItemFailed: "This track wouldn't play."
        case .storeRecovered: "Your watch library was rebuilt. Reconciling with iPhone."
        }
    }
}

/// The `.error` payload. Deliberately has no free-text field — see `safeDisplayMessage`.
public struct WatchProtocolFault: Codable, Equatable, Sendable, Error {
    public var code: WatchProtocolErrorCode
    /// Present only for `waitingForWiFi`/`transferFailed`-style scheduling hints. A number, never a
    /// message.
    public var retryAfterSeconds: Double?

    public init(code: WatchProtocolErrorCode, retryAfterSeconds: Double? = nil) {
        self.code = code
        self.retryAfterSeconds = retryAfterSeconds
    }

    public var retryPolicy: WatchProtocolRetryPolicy { code.retryPolicy }
    public var safeDisplayMessage: String { code.safeDisplayMessage }
}

/// Why an envelope could not become a usable message. Kept separate from `WatchProtocolFault`
/// because these are decode-time facts about the transport, not domain answers from the peer.
public enum WatchEnvelopeFailure: Error, Equatable, Sendable {
    case malformed
    case unsupportedVersion(peer: Int, local: Int)
    case unsupportedKind(String)

    /// The §5.5 code this failure surfaces as. An unknown *kind* inside a supported version is a
    /// peer that knows something we do not, which is still an upgrade problem for us.
    public var errorCode: WatchProtocolErrorCode {
        switch self {
        case .malformed: .transferFailed
        case .unsupportedVersion, .unsupportedKind: .protocolUpgradeRequired
        }
    }
}
