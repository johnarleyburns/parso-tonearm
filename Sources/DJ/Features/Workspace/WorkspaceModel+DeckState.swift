import Combine
import CoreGraphics
import Foundation
import TonearmCore

/// The per-deck load state of the `WorkspaceModel.load(_:trackID:)` one-gesture
/// path (plan 5.1). The gate and decode failures are **honest states with a
/// message**, never a crash; the crate rows render them (plan: "a decode
/// failure is an honest state not a crash").
public enum DeckLoadState: Equatable, Sendable {
    case idle
    case loading(trackID: Int64)
    case loaded(trackID: Int64)
    /// The FR-LIB-8 gate refused the track — it is not deck-ready.
    case refused(trackID: Int64, reason: String)
    /// The decode or resolve failed; the deck is not armed.
    case failed(trackID: Int64, message: String)

    public var trackID: Int64? {
        switch self {
        case .idle: return nil
        case .loading(let id), .loaded(let id), .refused(let id, _), .failed(let id, _):
            return id
        }
    }

    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

/// The honest per-deck stem status (§36.5, FR-ENG-3; plan decision 4). The
/// stem faders are **live only when `.prepared`** — any other state renders
/// the honest disabled label, never a fader that looks live and does nothing.
public enum DeckStemStatus: Equatable, Sendable {
    /// No prepared set is on the deck — the deck plays the full mix (§36.5's
    /// fallback; "stems not prepared").
    case unavailable
    /// A separation job for the deck's track is in flight (§36.3) — the faders
    /// stay disabled until the set lands and is armed.
    case separating
    /// A cached, version-matched set is armed on the deck — the faders are live.
    case prepared

    /// The honest one-line label the surfaces render (§36.5).
    public var label: String {
        switch self {
        case .unavailable: return "stems not prepared"
        case .separating: return "separating…"
        case .prepared: return "stems ready"
        }
    }
}

/// The per-deck stem control state the shared session VM owns — the four
/// voices' gains plus the mute/solo sets, mirrored here (like the EQ/fader
/// state) so every surface's STEMS faders read and write the same state.
public struct StemControlState: Equatable, Sendable {
    /// Per-voice linear gain targets, indexed by `SeparationVoice`. Defaults to unity.
    public var gains: [SeparationVoice: Float]
    /// The muted voices.
    public var muted: Set<SeparationVoice>
    /// The soloed voices.
    public var soloed: Set<SeparationVoice>

    public init(gains: [SeparationVoice: Float] = StemControlState.unityGains,
                muted: Set<SeparationVoice> = [],
                soloed: Set<SeparationVoice> = []) {
        self.gains = gains
        self.muted = muted
        self.soloed = soloed
    }

    /// Unity gains for all four voices.
    public static var unityGains: [SeparationVoice: Float] {
        Dictionary(uniqueKeysWithValues: SeparationVoice.allCases.map { ($0, Float(1)) })
    }

    /// The stem fader's full-travel gain (1.5× = +3.5 dB boost). The faders
    /// span 0…this; the render side hard-clamps nothing — the smoothed gain
    /// and the master limiter (§35.5) keep the sum honest.
    public static let maxGain: Float = 1.5
}
