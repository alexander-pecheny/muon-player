import Foundation
import CryptoKit

/// Minimal Last.fm 2.0 API client: mobile-session auth + now-playing + scrobble.
/// All requests are signed (api_sig) and POSTed over HTTPS as the API requires.
///
/// The api key/secret identify the *app* and are embedded; the *user* logs in
/// with their own username/password, which we immediately exchange for a session
/// key (the password is never stored).
actor LastFMClient {
    struct Scrobble: Sendable {
        let artist: String
        let album: String?
        let title: String
        let timestamp: Int
        let duration: Int?
    }

    enum LastFMError: Error {
        case notConfigured
        case api(code: Int, message: String)
        case http(Int)
        case malformed
        /// Retriable failures (network down, rate limited, temporary outage).
        case transient
    }

    private let endpoint = URL(string: "https://ws.audioscrobbler.com/2.0/")!
    private let apiKey: String
    private let apiSecret: String
    private var sessionKey: String?

    init(apiKey: String, apiSecret: String, sessionKey: String? = nil) {
        self.apiKey = apiKey
        self.apiSecret = apiSecret
        self.sessionKey = sessionKey
    }

    var hasAppCredentials: Bool { !apiKey.isEmpty && !apiSecret.isEmpty }
    var isAuthenticated: Bool { sessionKey != nil }

    func setSessionKey(_ key: String?) { sessionKey = key }

    // MARK: - Auth

    /// Exchange username + password for a session key (auth.getMobileSession).
    /// Returns the session key and caches it for subsequent calls.
    @discardableResult
    func authenticate(username: String, password: String) async throws -> String {
        guard hasAppCredentials else { throw LastFMError.notConfigured }
        let params = [
            "method": "auth.getMobileSession",
            "username": username,
            "password": password,
            "api_key": apiKey,
        ]
        let json = try await post(signed(params))
        guard let session = json["session"] as? [String: Any],
              let key = session["key"] as? String else { throw LastFMError.malformed }
        sessionKey = key
        return key
    }

    private func requireSession() throws -> String {
        guard let sessionKey else { throw LastFMError.notConfigured }
        return sessionKey
    }

    // MARK: - Now playing

    func updateNowPlaying(_ s: Scrobble) async throws {
        let sk = try requireSession()
        var params = [
            "method": "track.updateNowPlaying",
            "artist": s.artist,
            "track": s.title,
            "api_key": apiKey,
            "sk": sk,
        ]
        if let album = s.album, !album.isEmpty { params["album"] = album }
        if let d = s.duration, d > 0 { params["duration"] = String(d) }
        _ = try await post(signed(params))
    }

    // MARK: - Scrobble

    /// Submit one scrobble. Throws `.transient` for retriable failures; clears
    /// the session on an invalid-session error so the caller can re-auth.
    func scrobble(_ s: Scrobble) async throws {
        let sk = try requireSession()
        var params = [
            "method": "track.scrobble",
            "artist": s.artist,
            "track": s.title,
            "timestamp": String(s.timestamp),
            "api_key": apiKey,
            "sk": sk,
        ]
        if let album = s.album, !album.isEmpty { params["album"] = album }
        if let d = s.duration, d > 0 { params["duration"] = String(d) }
        do {
            _ = try await post(signed(params))
        } catch let LastFMError.api(code, message) {
            if code == 9 { sessionKey = nil }         // invalid session → re-auth
            if code == 9 || code == 16 || code == 11 || code == 29 { throw LastFMError.transient }
            throw LastFMError.api(code: code, message: message)
        }
    }

    // MARK: - Request plumbing

    /// Add the api_sig signature and format=json.
    private func signed(_ params: [String: String]) -> [String: String] {
        let sigInput = params.keys.sorted()
            .map { $0 + params[$0]! }
            .joined() + apiSecret
        let sig = Insecure.MD5.hash(data: Data(sigInput.utf8))
            .map { String(format: "%02x", $0) }.joined()
        var out = params
        out["api_sig"] = sig
        out["format"] = "json"
        return out
    }

    private func post(_ params: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = params
            .map { "\(urlEncode($0.key))=\(urlEncode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw LastFMError.transient // offline / connection failure
        }
        guard let http = response as? HTTPURLResponse else { throw LastFMError.malformed }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let code = json["error"] as? Int {
            let message = json["message"] as? String ?? "unknown"
            if code == 16 || code == 11 || code == 29 { throw LastFMError.transient }
            throw LastFMError.api(code: code, message: message)
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode >= 500 { throw LastFMError.transient }
            throw LastFMError.http(http.statusCode)
        }
        return json
    }

    private func urlEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
