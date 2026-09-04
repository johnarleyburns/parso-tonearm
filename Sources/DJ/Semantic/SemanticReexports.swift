import Foundation
@_exported import ParsoAudioNeural

/// Phase 7b (audio-engine unification): the CLAP embedding/pooling/quantization/
/// ranking plumbing moved verbatim into `ParsoAudioNeural` — see PAE's
/// ATTRIBUTION.md and current_status.md "Phase 7". This app keeps only what
/// is genuinely app policy: ODR delivery (`ModelResourceService`), GRDB
/// scheduling (`EmbeddingCoordinator`), and GRDB persistence
/// (`VectorStore`/`VectorStoreTierA` in VectorStore.swift, now built on
/// `ParsoAudioNeural.VectorMatrixScanner`).
///
/// Renamed on the move (avoid ambiguity with future PAE-side types):
/// `Preprocess` → `SemanticPreprocess`, `Pooling` → `SemanticPooling`,
/// `Quantization` → `VectorQuantization`. `VectorMatch.trackID` /
/// `RankedMatch.trackID` → `.rowID` (PAE is storage-agnostic; this app's
/// `rowID` is always a `DJTrack` id).
