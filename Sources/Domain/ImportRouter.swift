import Foundation

/// Result of routing a `.fileImporter` selection into either a folder import
/// or an audio-files import.
public enum ImportSelection: Equatable {
    case folder(URL)
    case files([URL])
}

/// Pure, testable routing for the single `.fileImporter` used by "Add Local
/// Folder" and "Add Audio Files". A directory selection becomes `.folder`;
/// anything else is treated as picked audio files.
public enum ImportRouter {
    public static func route(_ urls: [URL]) -> ImportSelection? {
        guard let first = urls.first else { return nil }
        return first.hasDirectoryPath ? .folder(first) : .files(urls)
    }
}
