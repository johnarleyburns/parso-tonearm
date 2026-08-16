import Foundation

/// Compile-time constants for the current analysis algorithm versions (§17.2).
/// Each stage has an independent integer; `AnalysisCoordinator.reconcileVersions()`
/// re-runs only stages whose stored version is behind its constant (FR-ANL-3).
public enum AnalysisVersions {
    public static let loudness = 1
    public static let fft = 1
    public static let beat = 1
    public static let key = 1
    public static let phrase = 1
    public static let waveform = 1
    /// Stage 2 (M2): music-CLAP semantic embeddings. Lands at 1 in commit 2.1,
    /// when the real model is in-repo and the embedding lane is runnable.
    public static let embedding = 1
    /// Stage 3 (M5): Demucs 4-stem separation (§36). Keyed into the stem-cache
    /// directory layout so a model upgrade invalidates cleanly, like
    /// `analysis_version` (§36.4, plan decision 5). **2 since S5** — the model
    /// is wired (DemucsStemModel runs Core ML, FP32) and every stem_cache row
    /// written by the conversionPending shell (version 1) must be invalidated.
    public static let stems = 2

    /// Human note for each stage, registered in `analysis_version` so the
    /// registry row says what the version actually is.
    public static let descriptors: [String: String] = [
        "loudness": "BS.1770-4 / R128 integrated LUFS, true peak, LRA (48 kHz)",
        "fft": "vDSP STFT, Hann 4096/2048, spectral features (48 kHz)",
        "beat": "Ellis-style DP beat grid + downbeats",
        "key": "HPCP chroma + Krumhansl/Temperley key correlation, Camelot",
        "phrase": "self-similarity + energy contour segmentation, bar-aligned",
        "waveform": "multi-resolution min/max/RMS pyramid",
        "embedding": "music-CLAP HTSAT-base FP16, log-mel 48k 64b, 10s/5s attention-pooled 512-D",
        "stems": "Demucs 4-stem (vocals/drums/bass/other), chunked Core ML, content-addressed cache",
    ]
}
