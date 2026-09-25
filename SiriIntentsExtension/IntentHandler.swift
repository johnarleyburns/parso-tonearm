// SPDX-License-Identifier: GPL-3.0-or-later
//
// Tonearm (Platterhead DJ) — Copyright (C) 2026 John Arley Burns.
// Licensed under the GNU General Public License v3.0 or later, with an
// additional permission under GPLv3 §7 allowing distribution through
// Apple's App Store. Full text, including that permission: ../LICENSE.
// Source: https://github.com/johnarleyburns/parso-tonearm

import Intents
import TonearmCore

/// SiriKit media entry point: "Hey Siri, play Hotel California on
/// Platterhead". It is also what makes the CarPlay "Ask Siri" assistant
/// cell legal. Apple's CPAssistantCellConfiguration docs require an Intents
/// extension that handles INPlayMediaIntent; declaring the cell without one
/// is what stopped CarPlay from opening in 3e34979.
///
/// Deliberately thin. The library lives in the app's own SQLite
/// (Application Support, not the app group), so this process can't search
/// it. It packs what Siri heard into a placeholder `INMediaItem`
/// (`SiriMediaRequest.identifier`) and answers `.handleInApp`. iOS then
/// launches the app in the background, and `TonearmPlayMediaHandler`
/// resolves the request through the same `IntentResolver` pipeline the App
/// Intents use and starts playback.
final class IntentHandler: INExtension, INPlayMediaIntentHandling {
    override func handler(for intent: INIntent) -> Any {
        self
    }

    func resolveMediaItems(for intent: INPlayMediaIntent) async -> [INPlayMediaMediaItemResolutionResult] {
        let request = SiriMediaRequest(
            query: intent.mediaSearch?.mediaName,
            artist: intent.mediaSearch?.artistName,
            kind: Self.kind(for: intent.mediaSearch?.mediaType ?? .unknown)
        )
        let item = INMediaItem(
            identifier: request.identifier,
            title: request.displayTitle,
            type: intent.mediaSearch?.mediaType ?? .unknown,
            artwork: nil
        )
        return [.success(with: item)]
    }

    func handle(intent: INPlayMediaIntent) async -> INPlayMediaIntentResponse {
        INPlayMediaIntentResponse(code: .handleInApp, userActivity: nil)
    }

    private static func kind(for type: INMediaItemType) -> SiriMediaRequest.Kind {
        switch type {
        case .song: return .song
        case .artist: return .artist
        case .album: return .album
        case .playlist: return .playlist
        default: return .unspecified
        }
    }
}
