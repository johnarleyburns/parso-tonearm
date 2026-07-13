import Foundation

enum ProTool: String, CaseIterable, Equatable {
    case smartPlaylist
    case tagEditor
    case duplicateDetection
    case parametricEQ
    case crossfeed
    case convolution
    case bitPerfect

    var feature: ProFeature {
        switch self {
        case .smartPlaylist:
            return .smartPlaylists
        case .tagEditor:
            return .tagEditor
        case .duplicateDetection, .parametricEQ, .crossfeed, .convolution, .bitPerfect:
            return .proAudioTools
        }
    }
}

enum ProToolsAccessPolicy {
    static func decision(for tool: ProTool, isPro: Bool) -> ProGateDecision {
        isPro ? .allow : .requiresPro(tool.feature)
    }

    static func decisionForToolsSurface(isPro: Bool) -> ProGateDecision {
        isPro ? .allow : .requiresPro(.proAudioTools)
    }
}
