// SPDX-License-Identifier: GPL-3.0-or-later
//
// Tonearm (Platterhead DJ) — Copyright (C) 2026 John Arley Burns.
// See ../../LICENSE.

#if !os(watchOS)
import Foundation
import TonearmDiscovery

/// Resolves the converted CLAP audio + text encoders and their bundled
/// sidecars for the Discovery indexing/search pipeline.
///
/// Both CLAP Core ML packages are compiled into the app bundle (like the
/// starter SQLite catalog) by the `Config/models-bundled.yml` overlay that
/// `scripts/generate-project.sh` writes; Xcode compiles each `.mlpackage`
/// to a `.mlmodelc` in the main bundle. There is no On-Demand Resource
/// request, retry, or download progress for CLAP — only Demucs is ODR.
/// `mel_filterbank_slaney_64.bin` and the RoBERTa `vocab.json` /
/// `merges.txt` ship bundled in `Resources/CLAP/`.
///
/// A development checkout that has not run `make models` has no packages, so
/// `currentResources()` returns `.unavailable` and index jobs park at
/// `waitingForModel` — never a fabricated embedding, never a network
/// request. A release archive is prevented from reaching that state at
/// build time (`REQUIRE_BUNDLED_CLAP=1`, `scripts/audit-clap-archive.sh`).
final class DiscoveryModelResources: Sendable {
    static let shared = DiscoveryModelResources()

    /// Synchronously resolve whatever is in the main bundle right now.
    func currentResources() -> ModelManager.Resources {
        let directories = Bundle.main.resourceURL.map { [$0] } ?? []
        return ModelResourceLocator(searchDirectories: directories, bundle: Bundle.main).resolve()
    }

    func currentDownloadProgress() -> ModelDownloadProgress? { nil }
    func currentDownloadError() -> String? { nil }
    func currentPerTagDebugSummary() -> String { "not applicable (CLAP models are bundled)" }

    func currentDiagnosticsDetail() -> ModelDiagnosticsDetail {
        let resources = currentResources()
        let artifacts = [
            ModelDiagnosticsDetail.Artifact(
                name: String(localized: "Audio encoder"), isResolved: resources.audioEncoderURL != nil,
                resolvedName: resources.audioEncoderURL?.lastPathComponent),
            ModelDiagnosticsDetail.Artifact(
                name: String(localized: "Text encoder"), isResolved: resources.textEncoderURL != nil,
                resolvedName: resources.textEncoderURL?.lastPathComponent),
            ModelDiagnosticsDetail.Artifact(
                name: String(localized: "Mel filterbank"), isResolved: resources.melFilterBankURL != nil,
                resolvedName: resources.melFilterBankURL?.lastPathComponent),
            ModelDiagnosticsDetail.Artifact(
                name: String(localized: "Tokenizer vocab"), isResolved: resources.tokenizerVocabURL != nil,
                resolvedName: resources.tokenizerVocabURL?.lastPathComponent),
            ModelDiagnosticsDetail.Artifact(
                name: String(localized: "Tokenizer merges"), isResolved: resources.tokenizerMergesURL != nil,
                resolvedName: resources.tokenizerMergesURL?.lastPathComponent),
        ]
        return ModelDiagnosticsDetail(downloadTags: [], artifacts: artifacts, downloadError: nil)
    }
}
#endif
