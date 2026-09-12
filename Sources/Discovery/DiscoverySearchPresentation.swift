#if !os(watchOS)
import Foundation
import ParsoAudioNeural
import TonearmCore

/// The two ways the search field interprets its text (plan §10.1: "search field
/// with metadata / 'Find by sound' mode toggle"). `metadata` never needs the
/// CLAP text model; `findBySound` runs the semantic engine.
public enum DiscoverySearchInputMode: String, Sendable, CaseIterable, Identifiable {
    case metadata
    case findBySound
    public var id: String { rawValue }
}

/// The selected source scope (plan §10.1 "source-scope picker"). An explicit
/// selection — a deleted scope resolves to `sourceUnavailable`/`emptyScope`,
/// never a silent widening to all music (plan §9).
public enum DiscoverySearchScope: Equatable, Sendable {
    case allMusic
    case sources([Int64])
    case playlist(Int64)
}

/// Which retrieval mode produced a result set — the UI labels metadata vs
/// semantic distinctly (plan §9 "Label metadata and semantic result modes
/// distinctly") and shows a score disclosure only where one exists.
public enum DiscoverySearchResultKind: String, Equatable, Sendable {
    /// Free-text CLAP similarity fused with musical attributes.
    case semantic
    /// "More like this track".
    case similar
    /// Hard SQL scope + BPM/key only, stable metadata order, no score.
    case filterOnly
    /// Empty text, no filters — ordinary scoped library browse.
    case metadataBrowse

    public var showsSemanticScore: Bool { self == .semantic || self == .similar }
}

/// Every distinct response the search screen can be in. Each maps to a visibly
/// different UI (plan §10.1 / §9: "Map every distinct response state to distinct
/// UI"). The pure `make(from:)` mapping is exhaustively unit-tested.
public enum DiscoverySearchScreenState: Equatable, Sendable {
    /// No query yet — the ordinary starting state.
    case idle
    /// A query is debouncing / running.
    case loading
    /// The query was rejected; carries the specific issues to show (plan §9).
    case validationError([QueryValidationIssue])
    /// Ranked / ordered results. `kind` distinguishes semantic vs filter-only
    /// vs browse; `stillIndexing` drives a "still building the index" note.
    case results(kind: DiscoverySearchResultKind, count: Int, stillIndexing: Bool)
    /// The query ran but nothing matched.
    case noMatches(kind: DiscoverySearchResultKind)
    /// A fresh library with nothing to search.
    case emptyLibrary
    /// The selected scope is explicitly empty.
    case emptyScope
    /// The selected source was deleted / is unavailable.
    case sourceUnavailable
    /// Scope has tracks but none are indexed yet (no embeddings, no jobs).
    case zeroIndexed
    /// Semantic search needs the CLAP text model and it is not downloaded.
    /// Offers "Download models" / a link to the sound-index status screen.
    case modelMissing
    /// The model is present but failed to load / run.
    case modelDownloadFailed
    /// "More like this" whose reference track has no / a stale embedding —
    /// offers "Analyze this track" (plan §9).
    case analyzeReference(trackID: Int64)
    /// A real SQL / vector-cache error — a retryable failure, not "no matches".
    case searchFailed
    /// A superseded query's late response was received and discarded — the
    /// visible state did not change (plan §9 "A cancelled search must not
    /// update results/errors"). Defensive: the coordinator normally prevents
    /// delivery entirely.
    case staleSuppressed

    /// Whether results (of any kind) are on screen.
    public var hasResults: Bool {
        if case .results = self { return true }
        return false
    }
}

/// Pure `DiscoverySearchResponse` → `DiscoverySearchScreenState` mapping. No
/// SwiftUI, no I/O — the whole state machine the view model publishes, in one
/// exhaustively-tested place (plan §10.1: "ALL scoring/validation/state logic
/// stays in the tested portable layer; the VM is cadence + plumbing only").
public enum DiscoverySearchPresentation {

    public static func resultKind(
        for mode: DiscoverySearchMode
    ) -> DiscoverySearchResultKind {
        switch mode {
        case .semantic: return .semantic
        case .similar: return .similar
        case .filterOnly: return .filterOnly
        case .metadataBrowse: return .metadataBrowse
        }
    }

    /// `stillIndexing` is true when the selected scope still has jobs pending —
    /// results are valid but partial, and the UI says so (plan §9: coverage is
    /// "Separately show count matching hard filters" and indexing progress).
    public static func make(from response: DiscoverySearchResponse) -> DiscoverySearchScreenState {
        let kind = resultKind(for: response.mode)
        let stillIndexing: Bool = {
            switch response.coverage?.state {
            case .indexingInProgress: return true
            default: return false
            }
        }()

        switch response.state {
        case .ready:
            return .results(kind: kind, count: response.results.count, stillIndexing: stillIndexing)
        case .noMatches:
            return .noMatches(kind: kind)
        case .validationFailed(let issues):
            return .validationError(issues)
        case .emptyLibrary:
            return .emptyLibrary
        case .emptyScope:
            return .emptyScope
        case .sourceUnavailable:
            return .sourceUnavailable
        case .zeroIndexed:
            return .zeroIndexed
        case .indexingInProgress:
            // SearchService never returns this as a terminal state (it proceeds
            // to a real scan), but map it defensively to a partial-results note.
            return .results(kind: kind, count: response.results.count, stillIndexing: true)
        case .modelMissing:
            return .modelMissing
        case .modelDownloadFailed:
            return .modelDownloadFailed
        case .unindexedReference:
            if case .similar(let referenceTrackID) = response.mode {
                return .analyzeReference(trackID: referenceTrackID)
            }
            return .analyzeReference(trackID: -1)
        case .searchFailed:
            return .searchFailed
        case .cancelled:
            return .staleSuppressed
        }
    }
}

/// The score-detail disclosure for one result row (plan §10.1: "a score-detail
/// disclosure showing the *actual available* `RankBreakdown` components (label
/// the raw number 'similarity', never '% confident')"). Returns an empty array
/// for filter-only / browse rows, which carry no score.
public enum RankBreakdownDisplay {
    public struct Component: Equatable, Sendable, Identifiable {
        public let label: String
        public let value: Double
        /// Pre-formatted, 2-decimal, no percent sign.
        public let formattedValue: String
        public var id: String { label }
    }

    public static func components(for result: DiscoverySearchResult) -> [Component] {
        guard let breakdown = result.breakdown else { return [] }
        var out: [Component] = []
        // The raw signed cosine, labelled exactly "similarity" (−1…1), never a
        // probability (plan §9).
        if let similarity = result.similarity {
            out.append(make("similarity", similarity))
        }
        out.append(make("tempo fit", breakdown.bpm))
        out.append(make("key fit", breakdown.key))
        out.append(make("energy fit", breakdown.energy))
        out.append(make("phrase fit", breakdown.phrase))
        if let fused = result.finalScore {
            out.append(make("match score", fused))
        } else {
            out.append(make("match score", breakdown.fused))
        }
        return out
    }

    private static func make(_ label: String, _ value: Double) -> Component {
        let clean = value.isFinite ? value : 0
        return Component(
            label: label, value: clean, formattedValue: String(format: "%.2f", clean))
    }
}
#endif
