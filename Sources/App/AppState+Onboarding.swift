import Foundation
import ParsoAudioStreaming
import SwiftUI
import TonearmCore
#if !os(macOS)
import UIKit
#endif

extension AppState {
    // MARK: - Onboarding (TF5, TF9)

    /// Adds the given archive.org libraries, persisting all of their tracks to the
    /// library (never caching), then builds the "Classical Piano Sonatas"
    /// starter playlist from every track that was added.
    func completeOnboarding(sourceURLs: [String]) async {
        let service = SourceService(preferFLAC: preferFLAC)
        var addedTrackIds: [Int64] = []
        for raw in sourceURLs {
            do {
                let preview = try await service.preview(from: raw)
                if let source = try? await service.add(preview: preview, followUpdates: true, store: store),
                   let sid = source.id {
                    let rows = (try? await store.tracks(forSource: sid)) ?? []
                    addedTrackIds.append(contentsOf: rows.map { $0.id })
                }
            } catch {
                print("onboarding add error for \(raw): \(error)")
            }
        }
        if !addedTrackIds.isEmpty {
            _ = try? await store.createManualPlaylist(title: "Classical Piano Sonatas",
                                                      trackIds: addedTrackIds)
        }
        didOnboard = true
        await reload()
    }
}
