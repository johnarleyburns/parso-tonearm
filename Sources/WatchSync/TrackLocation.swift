import Foundation

public enum PhoneDownloadState: Equatable, Sendable {
    case notDownloaded
    case downloaded
    case downloading(Double?)
}
