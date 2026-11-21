import Foundation

/// Bounded, resumable backfill of `asset.contentSampleHash` for local files
/// that were ingested before the v53 fingerprint column existed. Runs off the
/// main actor; the database actor is touched only to read candidates and apply
/// the results. A library larger than one batch simply continues next launch.
public enum LocalContentFingerprintBackfill {
    @discardableResult
    public static func run(store: LibraryStore, limit: Int = 200) async -> Int {
        guard let candidates = try? await store.localFingerprintCandidates(limit: limit),
              !candidates.isEmpty else { return 0 }

        var updates: [(assetId: Int64, hash: String, sizeBytes: Int64)] = []
        for candidate in candidates {
            guard let fingerprint = fingerprint(for: candidate) else { continue }
            updates.append((candidate.assetId, fingerprint.sampleHash, fingerprint.sizeBytes))
        }
        guard !updates.isEmpty else { return 0 }
        do {
            try await store.applyContentFingerprints(updates)
            return updates.count
        } catch {
            return 0
        }
    }

    private static func fingerprint(for candidate: LocalFingerprintCandidate)
        -> DuplicateDetection.Fingerprint? {
        if let bookmark = candidate.bookmark {
            let resolved = BookmarkVault.withAccess(bookmark) { url -> DuplicateDetection.Fingerprint? in
                guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
                return DuplicateDetection.fingerprint(bytes: data)
            }
            if let resolved, let fingerprint = resolved { return fingerprint }
        }
        if let relPath = candidate.relPath,
           let support = try? FileManager.default.url(
               for: .applicationSupportDirectory, in: .userDomainMask,
               appropriateFor: nil, create: false) {
            let url = support.appendingPathComponent(relPath)
            if let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) {
                return DuplicateDetection.fingerprint(bytes: data)
            }
        }
        if let raw = candidate.remoteURL, let url = URL(string: raw), url.isFileURL,
           let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) {
            return DuplicateDetection.fingerprint(bytes: data)
        }
        return nil
    }
}
