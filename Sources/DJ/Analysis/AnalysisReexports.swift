//
//  AnalysisReexports.swift
//  Phase 5b of the audio-engine unification
//  (parso-audio-engine/docs/UNIFICATION_PLAN.md §4 Phase 5).
//
//  The Stage-1 analysis DSP that used to live in `Sources/DJ/Analysis/` — STFT,
//  spectral features, onsets, tempo, beats, key, energy, phrase and the waveform
//  pyramid, plus the canonical analysis buffer and decoder — now lives in
//  `ParsoAudioAnalysis`. This file re-exports it under the names the rest of the
//  DJ target already uses so `DeckLoader` / `StemService` / `WaveformRepository`
//  / `DJLibraryStore` / `AnalysisArtifacts` compile unchanged.
//
//  `Loudness.swift` is the one exception: Tonearm's hand-rolled BS.1770 analyzer
//  is gone; `LoudnessAnalyzer` there is now a thin mapping shim over
//  `ParsoAudioCore.LoudnessAnalyzer` that preserves the `loudness` GRDB row
//  shape (`replayGainDB` / `dynamicRangeDB`), so no schema migration is needed.
//

@_exported import ParsoAudioAnalysis

/// The canonical 48 kHz analysis buffer (was `Sources/DJ/Analysis/AudioDecode.swift`).
public typealias PCMBuffer = AnalysisAudio

/// The one-shot AVFoundation analysis decoder (was `AudioDecoder` in the same file).
public typealias AudioDecoder = AnalysisDecoder
