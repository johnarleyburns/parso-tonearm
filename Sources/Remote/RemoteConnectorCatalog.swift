import Foundation

public enum RemoteConnectorTier: String, Codable, Equatable {
    case guided
    case advanced

    public var title: String {
        switch self {
        case .guided: return "Guided"
        case .advanced: return "Advanced"
        }
    }
}

public enum RemoteConnectorAuthKind: String, Codable, Equatable {
    case oauth
    case usernamePassword
    case token
    case folderPicker
    case urlOnly
}

public struct RemoteConnectorGuide: Equatable, Codable {
    public struct Section: Equatable, Codable {
        public var title: String
        public var body: String

        public init(title: String, body: String) {
            self.title = title
            self.body = body
        }
    }

    public var title: String
    public var sections: [Section]

    public init(title: String, sections: [Section]) {
        self.title = title
        self.sections = sections
    }
}

public struct RemoteConnector: Identifiable, Equatable, Codable {
    public var id: String { connectorID ?? sourceKind.rawValue }
    public var sourceKind: SourceKind
    public var connectorID: String?
    public var title: String
    public var proDisplayName: String
    public var subtitle: String
    public var tier: RemoteConnectorTier
    public var authKind: RemoteConnectorAuthKind
    public var icon: String
    public var guide: RemoteConnectorGuide

    public init(sourceKind: SourceKind,
                connectorID: String? = nil,
                title: String,
                proDisplayName: String? = nil,
                subtitle: String,
                tier: RemoteConnectorTier,
                authKind: RemoteConnectorAuthKind,
                icon: String,
                guide: RemoteConnectorGuide) {
        self.sourceKind = sourceKind
        self.connectorID = connectorID
        self.title = title
        self.proDisplayName = proDisplayName ?? title
        self.subtitle = subtitle
        self.tier = tier
        self.authKind = authKind
        self.icon = icon
        self.guide = guide
    }
}

public enum RemoteConnectorCatalog {
    public static let all: [RemoteConnector] = [
        RemoteConnector(
            sourceKind: .iaList,
            connectorID: "iaPublicList",
            title: "archive.org",
            proDisplayName: "archive.org (public lists, items, collections)",
            subtitle: "Public list, item, or collection — URL only",
            tier: .guided,
            authKind: .urlOnly,
            icon: "link",
            guide: guide(
                "Add archive.org Library",
                prerequisites: "An archive.org URL: item, public user list, favorites page, or collection.",
                steps: "Paste the URL. Tonearm resolves the metadata and streams audio files in place.",
                troubleshooting: "Collections are capped at 100 members. Favorites pages and public lists should resolve within a few seconds. If a URL does not resolve, confirm the item or list is public.",
                privacy: "No credentials needed for public lists. Tonearm streams audio only from the URLs you add."
            )
        ),
        RemoteConnector(
            sourceKind: .iaList,
            connectorID: "iaPrivateList",
            title: "archive.org (Private List)",
            proDisplayName: "archive.org (private lists)",
            subtitle: "Private list — URL, username, and password",
            tier: .guided,
            authKind: .usernamePassword,
            icon: "lock.doc",
            guide: guide(
                "Add archive.org Private List",
                prerequisites: "An archive.org private list URL and the archive.org username/password that can access it.",
                steps: "Enter the list URL, archive.org username, and password. Tonearm validates access before saving.",
                troubleshooting: "Private lists require the correct archive.org account credentials. If access is denied, confirm the username and password and that the account has access to the list.",
                privacy: "Credentials are stored locally in Apple Keychain. Tonearm sends credentials only to archive.org when resolving the list."
            )
        ),
        RemoteConnector(
            sourceKind: .subsonic,
            title: "Subsonic",
            proDisplayName: "Subsonic/Navidrome",
            subtitle: "Subsonic or Navidrome",
            tier: .guided,
            authKind: .usernamePassword,
            icon: "server.rack",
            guide: guide(
                "Connect Subsonic or Navidrome",
                prerequisites: "A reachable Subsonic-compatible server URL, username, and password.",
                steps: "Enter the server URL, username, and password. Tonearm pings the server, then browses artists, albums, and tracks through the Subsonic API.",
                troubleshooting: "If connection fails, confirm the URL includes the correct path and port, HTTPS certificate trust is valid, and the account can stream music.",
                privacy: "Credentials are stored locally in Apple Keychain. Tonearm asks for stream URLs only when browsing or playing."
            )
        ),
        RemoteConnector(
            sourceKind: .webDAV,
            title: "WebDAV",
            subtitle: "Nextcloud, ownCloud, rclone",
            tier: .guided,
            authKind: .usernamePassword,
            icon: "externaldrive.connected.to.line.below",
            guide: guide(
                "Connect WebDAV",
                prerequisites: "A WebDAV HTTPS URL and an account or app password with read access to your music folder.",
                steps: "Enter the WebDAV endpoint, username, and password. Tonearm lists folders with PROPFIND and streams audio files in place.",
                troubleshooting: "Use an app password when your provider has two-factor authentication. Check that the URL points at the actual WebDAV root.",
                privacy: "Credentials are stored locally in Apple Keychain. Files are listed and streamed only from the server you add."
            )
        ),
        RemoteConnector(
            sourceKind: .smb,
            title: "SMB",
            subtitle: "Folder shared through Files",
            tier: .advanced,
            authKind: .folderPicker,
            icon: "externaldrive.connected.to.line.below",
            guide: guide(
                "Connect SMB",
                prerequisites: "An SMB share already added in the iOS Files app.",
                steps: "Connect the server in Files first, then choose the shared music folder in Tonearm. Tonearm stores folder access as a security-scoped bookmark.",
                troubleshooting: "If the folder is unavailable, reopen Files and confirm the share is mounted before returning to Tonearm.",
                privacy: "Tonearm does not store SMB passwords. Access is mediated by Files and the bookmark granted by iOS."
            )
        ),
        RemoteConnector(
            sourceKind: .jellyfin,
            title: "Jellyfin",
            subtitle: "Music library server",
            tier: .guided,
            authKind: .usernamePassword,
            icon: "server.rack",
            guide: guide(
                "Connect Jellyfin",
                prerequisites: "A Jellyfin server URL and account with access to the music library.",
                steps: "Enter the server URL, username, and password. Tonearm authenticates with Jellyfin and browses album artists, albums, and tracks.",
                troubleshooting: "Check reverse proxy paths and HTTPS certificate trust if authentication works in a browser but not in Tonearm.",
                privacy: "Tonearm stores the Jellyfin access token locally in Apple Keychain and sends it only to the server you add."
            )
        ),
        RemoteConnector(
            sourceKind: .plex,
            title: "Plex",
            subtitle: "Plex music section",
            tier: .advanced,
            authKind: .token,
            icon: "server.rack",
            guide: guide(
                "Connect Plex",
                prerequisites: "A reachable Plex server URL and a Plex token for the account that can access the music library.",
                steps: "Enter the Plex server URL and token. Tonearm browses music sections, artists, albums, and tracks through the Plex server API.",
                troubleshooting: "If no music appears, confirm the token belongs to a user with library access and that the URL reaches the Plex Media Server directly.",
                privacy: "The Plex token is stored locally in Apple Keychain and sent only to the Plex server URL you add."
            )
        ),
        RemoteConnector(
            sourceKind: .dropbox,
            title: "Dropbox",
            subtitle: "Sign in with read-only access",
            tier: .guided,
            authKind: .oauth,
            icon: "externaldrive.connected.to.line.below",
            guide: cloudGuide("Dropbox", permission: "read-only file metadata and content access")
        ),
        RemoteConnector(
            sourceKind: .googleDrive,
            title: "Google Drive",
            subtitle: "Sign in with Drive readonly",
            tier: .guided,
            authKind: .oauth,
            icon: "externaldrive.connected.to.line.below",
            guide: cloudGuide("Google Drive", permission: "Drive readonly access")
        ),
        RemoteConnector(
            sourceKind: .oneDrive,
            title: "OneDrive",
            subtitle: "Sign in with Files.Read",
            tier: .guided,
            authKind: .oauth,
            icon: "externaldrive.connected.to.line.below",
            guide: cloudGuide("OneDrive", permission: "Microsoft Graph Files.Read access")
        ),
        RemoteConnector(
            sourceKind: .pCloud,
            title: "pCloud",
            subtitle: "Sign in with pCloud",
            tier: .guided,
            authKind: .oauth,
            icon: "externaldrive.connected.to.line.below",
            guide: cloudGuide("pCloud", permission: "pCloud file listing and download access")
        ),
    ]

    public static var productSourceKinds: [SourceKind] {
        let allKinds = all.map(\.sourceKind)
        // Deduplicate while preserving order
        var seen = Set<String>()
        return allKinds.filter { seen.insert($0.rawValue).inserted }
    }

    public static var proDisplayList: String {
        // Deduplicate proDisplayNames
        var seen = Set<String>()
        let unique = all.compactMap { connector -> String? in
            let name = connector.proDisplayName
            guard seen.insert(name).inserted else { return nil }
            return name
        }
        return unique.joined(separator: ", ")
    }

    public static func displayName(_ kind: SourceKind) -> String {
        connector(for: kind)?.proDisplayName ?? kind.rawValue
    }

    public static func connector(for kind: SourceKind) -> RemoteConnector? {
        all.first { $0.sourceKind == kind }
    }

    public static func connector(byID id: String) -> RemoteConnector? {
        all.first { $0.id == id }
    }

    public static func requireConnector(for kind: SourceKind) throws -> RemoteConnector {
        guard let connector = connector(for: kind) else {
            throw URLError(.unsupportedURL)
        }
        return connector
    }

    private static func guide(_ title: String,
                              prerequisites: String,
                              steps: String,
                              troubleshooting: String,
                              privacy: String) -> RemoteConnectorGuide {
        RemoteConnectorGuide(title: title, sections: [
            .init(title: "Prerequisites", body: prerequisites),
            .init(title: "Setup", body: steps),
            .init(title: "Troubleshooting", body: troubleshooting),
            .init(title: "Privacy", body: privacy),
        ])
    }

    private static func cloudGuide(_ provider: String, permission: String) -> RemoteConnectorGuide {
        guide(
            "Connect \(provider)",
            prerequisites: "A \(provider) account with music files stored in folders Tonearm can read.",
            steps: "Tap Sign In, approve \(permission), then choose music by browsing folders in Tonearm.",
            troubleshooting: "If sign-in does not return to Tonearm, confirm the OAuth redirect URL is registered for this app build and try again.",
            privacy: "OAuth tokens are stored locally in Apple Keychain. Tonearm requests file lists and stream URLs only from \(provider) when you browse or play."
        )
    }
}
