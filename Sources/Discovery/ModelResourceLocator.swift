#if !os(watchOS)
import Foundation

/// Resolves the on-disk URLs the CLAP audio encoder needs, the same way the
/// rest of the app delivers Core ML resources (plan §8: "Resolve actual
/// resource URLs AFTER successful acquisition ... Recognize compiled
/// `.mlmodelc` when supplied by the build as well as `.mlpackage`").
///
/// Two artefacts are required (see `tools/clap-coreml/README.md`):
///
///  - the converted audio encoder — `CLAPAudioEncoder`, delivered as the
///    On-Demand Resource tag `clap-audio` (`Config/models-odr.yml`); Xcode
///    compiles the `.mlpackage` to `CLAPAudioEncoder.mlmodelc` inside the
///    asset pack, so `.mlmodelc` is looked for first and `.mlpackage` second
///    (a bare SwiftPM checkout / conversion working tree has the latter).
///  - the mel filterbank — `mel_filterbank_slaney_64.bin`, which ships
///    bundled in `Resources/CLAP/` (the STFT/mel frontend lives in Swift, not
///    in the model).
///
/// When either artefact is genuinely absent the corresponding field is `nil`
/// and `ModelManager` parks jobs at `waitingForModel` — never a fabricated
/// embedding (plan §8: "Do not substitute fake embeddings when resources are
/// missing").
public struct ModelResourceLocator: Sendable {
    /// Directories to search, in priority order. The app passes the main
    /// bundle's resource URL (ODR content is mounted there); tests pass a
    /// temp directory or the repo's `Resources/` subdirectories.
    public var searchDirectories: [URL]

    /// Audio-encoder file names, in preference order (compiled first).
    public var audioEncoderNames: [String]

    /// Text-encoder file names, in preference order (compiled first). Delivered
    /// as the On-Demand Resource tag `clap-text` (`Config/models-odr.yml`);
    /// Xcode compiles the `.mlpackage` to `CLAPTextEncoder.mlmodelc` inside the
    /// asset pack, so `.mlmodelc` is looked for first and `.mlpackage` second.
    public var textEncoderNames: [String]

    /// RoBERTa byte-level-BPE tokenizer sidecars, bundled in `Resources/CLAP/`
    /// (the tokenizer runs in Swift — `ParsoAudioNeural.RoBERTaTokenizer` —
    /// not in the model). Both are required for the text encoder.
    public var tokenizerVocabName: String
    public var tokenizerMergesName: String

    /// Mel-filterbank file name.
    public var melFilterBankName: String

    /// Subdirectories (relative to each search directory) also checked for
    /// each artefact — `Resources/CLAP/` is preserved as a folder in some
    /// bundle layouts.
    public var nestedSubdirectories: [String]

    public init(
        searchDirectories: [URL],
        audioEncoderNames: [String] = ["CLAPAudioEncoder.mlmodelc", "CLAPAudioEncoder.mlpackage"],
        textEncoderNames: [String] = ["CLAPTextEncoder.mlmodelc", "CLAPTextEncoder.mlpackage"],
        tokenizerVocabName: String = "vocab.json",
        tokenizerMergesName: String = "merges.txt",
        melFilterBankName: String = "mel_filterbank_slaney_64.bin",
        nestedSubdirectories: [String] = ["CLAP", "Models"]
    ) {
        self.searchDirectories = searchDirectories
        self.audioEncoderNames = audioEncoderNames
        self.textEncoderNames = textEncoderNames
        self.tokenizerVocabName = tokenizerVocabName
        self.tokenizerMergesName = tokenizerMergesName
        self.melFilterBankName = melFilterBankName
        self.nestedSubdirectories = nestedSubdirectories
    }

    /// Resolve the resources present right now. Pure and synchronous — safe to
    /// call from `ModelManager`'s `@Sendable () -> Resources` provider.
    public func resolve() -> ModelManager.Resources {
        ModelManager.Resources(
            audioEncoderURL: firstExisting(names: audioEncoderNames),
            melFilterBankURL: firstExisting(names: [melFilterBankName]),
            textEncoderURL: firstExisting(names: textEncoderNames),
            tokenizerVocabURL: firstExisting(names: [tokenizerVocabName]),
            tokenizerMergesURL: firstExisting(names: [tokenizerMergesName]))
    }

    /// The candidate directories: each search directory, then each of its
    /// declared nested subdirectories.
    private var candidateDirectories: [URL] {
        var dirs: [URL] = []
        for base in searchDirectories {
            dirs.append(base)
            for sub in nestedSubdirectories {
                dirs.append(base.appendingPathComponent(sub, isDirectory: true))
            }
        }
        return dirs
    }

    /// First `name` (in the given preference order) that exists in any
    /// candidate directory (directories checked outermost, names innermost so
    /// a compiled `.mlmodelc` in a later directory still beats an `.mlpackage`
    /// only if it is also in an earlier or equal directory — names win within
    /// a directory, directories win across).
    private func firstExisting(names: [String]) -> URL? {
        let fm = FileManager.default
        for dir in candidateDirectories {
            for name in names {
                let candidate = dir.appendingPathComponent(name)
                if fm.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return nil
    }
}
#endif
