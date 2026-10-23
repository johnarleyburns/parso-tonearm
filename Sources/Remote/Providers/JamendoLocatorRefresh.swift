import Foundation

extension JamendoLocatorResolver {
    /// A resolver that refreshes a stable Jamendo track ID into a fresh stream URL through the app's
    /// configured Jamendo client (`JamendoAppConfig`; no credential is hard-coded here).
    public static func configured(clientID: String = JamendoAppConfig.clientID,
                                  session: URLSession = .shared,
                                  baseURL: URL = JamendoAppConfig.baseURL,
                                  maxTransientAttempts: Int = 3) -> JamendoLocatorResolver {
        let api = JamendoAPI(clientID: clientID, session: session, baseURL: baseURL)
        return JamendoLocatorResolver(maxTransientAttempts: maxTransientAttempts, refresh: { trackID in
            let tracks = try await api.tracks(ids: [trackID])
            guard let audio = tracks.first(where: { $0.id == trackID })?.audio, let url = URL(string: audio),
                  url.scheme?.hasPrefix("http") == true else { throw JamendoGenreError.catalogue("no stream for \(trackID)") }
            return (url, nil)   // Jamendo states no expiry: a 401/403/404/410 on open drives the refresh
        })
    }
}
