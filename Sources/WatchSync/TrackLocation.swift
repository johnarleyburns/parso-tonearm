import Foundation

public enum PhoneDownloadState: Equatable {
    case notDownloaded
    case downloaded
    case downloading(Double?)
}
