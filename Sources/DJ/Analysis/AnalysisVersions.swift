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
    // `embedding` (CLAP) arrives in M2; excluded until then so reconcile never
    // enqueues a stage no implementation can run.

    /// Human note for each stage, registered in `analysis_version` so the
    /// registry row says what the version actually is.
    public static let descriptors: [String: String] = [
        "loudness": "BS.1770-4 / R128 integrated LUFS, true peak, LRA (48 kHz)",
        "fft": "vDSP STFT, Hann 4096/2048, spectral features (48 kHz)",
        "beat": "Ellis-style DP beat grid + downbeats",
        "key": "HPCP chroma + Krumhansl/Temperley key correlation, Camelot",
        "phrase": "self-similarity + energy contour segmentation, bar-aligned",
        "waveform": "multi-resolution min/max/RMS pyramid",
    ]
}
