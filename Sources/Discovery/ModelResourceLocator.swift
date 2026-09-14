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
    /// Directories to search, in priority order — the fallback path when
    /// `bundle` is `nil` (tests / dev checkouts pointed at a plain
    /// filesystem folder, not a real app bundle). See `bundle` below for
    /// why this alone is NOT sufficient for real On-Demand Resource
    /// content.
    public var searchDirectories: [URL]

    /// The bundle to resolve On-Demand Resource content through, via
    /// `Bundle.url(forResource:withExtension:subdirectory:)` — the only
    /// Apple-documented way to find ODR-mounted files. This is not
    /// optional polish: a real device diagnostics export showed BOTH ODR
    /// tags reporting `beginAccessingResources` success ("finished") while
    /// `modelResourceAvailable` stayed `false` — the downloads completed,
    /// but nothing could find the files, because they were never where a
    /// guessed path expects them to be. Xcode mounts each ODR tag's
    /// content into a *hashed*, unpredictable asset-pack directory (a real
    /// CI archive showed
    /// `guru.parso.tonearm.clap-text-956b7b876cac28a5d0622945cf9adb21.assetpack`,
    /// not `Resources/CLAPTextEncoder.mlmodelc`) — `searchDirectories` +
    /// plain `FileManager.fileExists` can never construct that path, no
    /// matter how many subdirectories it's told to check. `Bundle`'s own
    /// resource APIs are what actually know where ODR content lives; they
    /// abstract over exactly this. `nil` in tests/dev checkouts, where
    /// `searchDirectories` point at a plain filesystem folder instead of a
    /// real app bundle.
    public var bundle: Bundle?

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
        bundle: Bundle? = nil,
        audioEncoderNames: [String] = ["CLAPAudioEncoder.mlmodelc", "CLAPAudioEncoder.mlpackage"],
        textEncoderNames: [String] = ["CLAPTextEncoder.mlmodelc", "CLAPTextEncoder.mlpackage"],
        tokenizerVocabName: String = "vocab.json",
        tokenizerMergesName: String = "merges.txt",
        melFilterBankName: String = "mel_filterbank_slaney_64.bin",
        nestedSubdirectories: [String] = ["CLAP", "Models"]
    ) {
        self.searchDirectories = searchDirectories
        self.bundle = bundle
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

    /// First `name` (in the given preference order) that exists — checked
    /// through `bundle`'s own resource-resolution APIs first (the only way
    /// that correctly finds ODR-mounted content, see `bundle`'s doc), then
    /// falling back to a plain filesystem check across `candidateDirectories`
    /// (directories checked outermost, names innermost so a compiled
    /// `.mlmodelc` in a later directory still beats an `.mlpackage` only if
    /// it is also in an earlier or equal directory — names win within a
    /// directory, directories win across).
    private func firstExisting(names: [String]) -> URL? {
        if let bundle, let found = firstExistingInBundle(bundle, names: names) {
            return found
        }
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

    /// Resolves `name` through `Bundle.url(forResource:withExtension:
    /// subdirectory:)` — first at the bundle's root, then inside each of
    /// `nestedSubdirectories` — trying both the bare filename form and the
    /// split base-name/extension form (folder resources like `.mlmodelc`
    /// are typically looked up as `("CLAPAudioEncoder", "mlmodelc")`, but a
    /// name with no extension, like a tokenizer sidecar, needs the bare
    /// form since `withExtension: nil` behaves differently than `""`).
    private func firstExistingInBundle(_ bundle: Bundle, names: [String]) -> URL? {
        for name in names {
            let ext = (name as NSString).pathExtension
            let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
            let subdirectories: [String?] = [nil] + nestedSubdirectories
            for subdirectory in subdirectories {
                if let url = bundle.url(
                    forResource: base, withExtension: ext.isEmpty ? nil : ext,
                    subdirectory: subdirectory)
                {
                    return url
                }
            }
        }
        return nil
    }
}
#endif
