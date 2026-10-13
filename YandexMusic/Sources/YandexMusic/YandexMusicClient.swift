//
//  YandexMusicClient.swift
//  YandexMusic
//
//  A small Combine client for the unofficial api.music.yandex.net.
//  Requests carry `Authorization: OAuth <token>`; responses wrap the payload
//  in `{"result": …}` or report `{"error": …}`.
//

import Foundation
import Combine

public enum YandexMusicError: Error, Equatable, LocalizedError {
    /// HTTP 401/403, or an account status without a uid: the token is wrong or revoked.
    case unauthorized
    case http(status: Int, message: String?)
    case api(name: String?, message: String?)
    case invalidResponse
    /// Neither MP3 nor AAC is offered for the track.
    case noPlayableFile
    case badDownloadInfo

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Yandex Music rejected the token. Paste a fresh OAuth token in Settings → Accounts."
        case .http(let status, let message):
            return "Yandex Music answered with HTTP \(status)" + (message.map { ": \($0)" } ?? ".")
        case .api(let name, let message):
            return "Yandex Music error: \(message ?? name ?? "unknown")."
        case .invalidResponse:
            return "Unexpected response from Yandex Music."
        case .noPlayableFile:
            return "Yandex Music offers no MP3 or AAC file for this track."
        case .badDownloadInfo:
            return "Could not read the file location from Yandex Music."
        }
    }
}

/// One API call: method, path, query and, for POST, a form body.
public struct Endpoint: Equatable {

    public enum Method: String {
        case get = "GET"
        case post = "POST"
    }

    public var method: Method
    public var path: String
    public var query = [URLQueryItem]()
    public var form: [URLQueryItem]? = nil

    public static func accountStatus() -> Endpoint {
        return Endpoint(method: .get, path: "account/status")
    }

    public static func likedTracks(uid: Int) -> Endpoint {
        return Endpoint(method: .get, path: "users/\(uid)/likes/tracks")
    }

    public static func setLiked(_ liked: Bool, trackIDs: [String], uid: Int) -> Endpoint {
        let action = liked ? "add-multiple" : "remove"
        return Endpoint(method: .post, path: "users/\(uid)/likes/tracks/\(action)",
                        form: [URLQueryItem(name: "track-ids", value: trackIDs.joined(separator: ","))])
    }

    public static func tracks(ids: [String]) -> Endpoint {
        return Endpoint(method: .post, path: "tracks",
                        form: [URLQueryItem(name: "track-ids", value: ids.joined(separator: ",")),
                               URLQueryItem(name: "with-positions", value: "false")])
    }

    public static func playlists(uid: Int) -> Endpoint {
        return Endpoint(method: .get, path: "users/\(uid)/playlists/list")
    }

    public static func likedPlaylists(uid: Int) -> Endpoint {
        return Endpoint(method: .get, path: "users/\(uid)/likes/playlists")
    }

    /// `playlistIDs` are `ownerUid:kind`.
    public static func setLiked(_ liked: Bool, playlistIDs: [String], uid: Int) -> Endpoint {
        let action = liked ? "add-multiple" : "remove"
        return Endpoint(method: .post, path: "users/\(uid)/likes/playlists/\(action)",
                        form: [URLQueryItem(name: "playlist-ids", value: playlistIDs.joined(separator: ","))])
    }

    /// A playlist with its tracks.
    public static func playlist(uid: Int, kind: Int) -> Endpoint {
        return Endpoint(method: .get, path: "users/\(uid)/playlists/\(kind)")
    }

    public static func search(_ text: String, type: String = "all", page: Int = 0) -> Endpoint {
        return Endpoint(method: .get, path: "search",
                        query: [URLQueryItem(name: "text", value: text),
                                URLQueryItem(name: "nocorrect", value: "false"),
                                URLQueryItem(name: "type", value: type),
                                URLQueryItem(name: "page", value: String(page)),
                                URLQueryItem(name: "playlist-in-best", value: "true")])
    }

    public static func downloadInfo(trackID: String) -> Endpoint {
        return Endpoint(method: .get, path: "tracks/\(trackID)/download-info")
    }

}

public final class YandexMusicClient {

    public static let defaultBaseURL = URL(string: "https://api.music.yandex.net")!
    /// The client header of the official Android app; some endpoints answer only with it.
    static let clientHeader = "YandexMusicAndroid/24023621"
    /// `/tracks` takes a list of ids; long lists go in batches of this size.
    static let trackBatchSize = 100

    /// The OAuth token. `nil` sends requests without authorization.
    /// Batched requests read it on the session's queue, hence the lock.
    public var token: String? {
        get {
            tokenLock.lock()
            defer { tokenLock.unlock() }
            return storedToken
        }
        set {
            tokenLock.lock()
            defer { tokenLock.unlock() }
            storedToken = newValue
        }
    }
    public let baseURL: URL
    private let session: URLSession
    private let tokenLock = NSLock()
    private var storedToken: String?

    public init(token: String? = nil, baseURL: URL = defaultBaseURL, session: URLSession = .shared) {
        self.storedToken = token
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: - Requests

    public func urlRequest(for endpoint: Endpoint) -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent(endpoint.path), resolvingAgainstBaseURL: false)!
        if !endpoint.query.isEmpty {
            components.percentEncodedQuery = formEncoded(endpoint.query)
        }

        var request = URLRequest(url: components.url!)
        request.httpMethod = endpoint.method.rawValue
        request.setValue(Self.clientHeader, forHTTPHeaderField: "X-Yandex-Music-Client")
        request.setValue("ru", forHTTPHeaderField: "Accept-Language")
        if let token = token, !token.isEmpty {
            request.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
        }
        if let form = endpoint.form {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(formEncoded(form).utf8)
        }
        return request
    }

    /// Sends the request and unwraps `result`.
    public func perform<T: Decodable>(_ endpoint: Endpoint, as type: T.Type = T.self) -> AnyPublisher<T, Error> {
        return perform(urlRequest(for: endpoint), as: type)
    }

    private func perform<T: Decodable>(_ request: URLRequest, as type: T.Type) -> AnyPublisher<T, Error> {
        return session.dataTaskPublisher(for: request)
            .mapError { $0 as Error }
            .tryMap { data, response in try Self.decodeResult(T.self, data: data, response: response) }
            .eraseToAnyPublisher()
    }

    static func decodeResult<T: Decodable>(_ type: T.Type, data: Data, response: URLResponse) throws -> T {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)

        guard (200..<300).contains(status) else {
            if status == 401 || status == 403 {
                throw YandexMusicError.unauthorized
            }
            throw YandexMusicError.http(status: status, message: envelope?.error?.message ?? envelope?.error?.name)
        }

        let result: Envelope<T>
        do {
            result = try JSONDecoder().decode(Envelope<T>.self, from: data)
        }
        catch {
            if let apiError = envelope?.error {
                throw YandexMusicError.api(name: apiError.name, message: apiError.message)
            }
            throw error
        }

        if let value = result.result {
            return value
        }
        if let apiError = envelope?.error {
            throw YandexMusicError.api(name: apiError.name, message: apiError.message)
        }
        throw YandexMusicError.invalidResponse
    }

    // MARK: - Account

    /// Fails with `.unauthorized` when the token does not belong to an account.
    /// `candidate` checks a token for this one request, leaving `token` as it is.
    public func accountStatus(candidate: String? = nil) -> AnyPublisher<AccountStatus, Error> {
        var request = urlRequest(for: .accountStatus())
        if let candidate = candidate {
            request.setValue("OAuth \(candidate)", forHTTPHeaderField: "Authorization")
        }

        return perform(request, as: AccountStatus.self)
            .tryMap { status in
                guard status.account.uid != nil else { throw YandexMusicError.unauthorized }
                return status
            }
            .eraseToAnyPublisher()
    }

    // MARK: - Tracks

    /// Full tracks for `trackId` or `trackId:albumId` ids, in the order asked for.
    public func tracks(ids: [String]) -> AnyPublisher<[Track], Error> {
        guard !ids.isEmpty else {
            return Just([]).setFailureType(to: Error.self).eraseToAnyPublisher()
        }

        let batches = stride(from: 0, to: ids.count, by: Self.trackBatchSize).map {
            Array(ids[$0..<min($0 + Self.trackBatchSize, ids.count)])
        }

        return Publishers.Sequence<[[String]], Error>(sequence: batches)
            .flatMap(maxPublishers: .max(1)) { self.perform(.tracks(ids: $0), as: [Track].self) }
            .collect()
            .map { batches in
                let tracks = batches.flatMap { $0 }
                let byID = Dictionary(tracks.map { ($0.id.value, $0) }, uniquingKeysWith: { first, _ in first })
                return ids.compactMap { byID[String($0.split(separator: ":").first ?? "")] }
            }
            .eraseToAnyPublisher()
    }

    /// Liked tracks, in the order the service lists them (newest first).
    public func likedTracks(uid: Int) -> AnyPublisher<[Track], Error> {
        return perform(.likedTracks(uid: uid), as: LikesResult.self)
            .flatMap { self.resolve($0.library.tracks ?? []) }
            .eraseToAnyPublisher()
    }

    public func setLiked(_ liked: Bool, trackIDs: [String], uid: Int) -> AnyPublisher<Void, Error> {
        return perform(.setLiked(liked, trackIDs: trackIDs, uid: uid), as: AnyValue.self)
            .map { _ in () }
            .eraseToAnyPublisher()
    }

    /// Uses the tracks a response already carries and fetches the rest.
    private func resolve(_ shorts: [TrackShort]) -> AnyPublisher<[Track], Error> {
        let missing = shorts.filter { $0.track == nil }.map { $0.fullID }

        return tracks(ids: missing)
            .map { fetched in
                let byID = Dictionary(fetched.map { ($0.id.value, $0) }, uniquingKeysWith: { first, _ in first })
                return shorts.compactMap { $0.track ?? byID[$0.id.value] }
            }
            .eraseToAnyPublisher()
    }

    // MARK: - Playlists

    /// Playlists the user created.
    public func playlists(uid: Int) -> AnyPublisher<[Playlist], Error> {
        return perform(.playlists(uid: uid), as: [Playlist].self)
    }

    /// Playlists of others the user liked.
    public func likedPlaylists(uid: Int) -> AnyPublisher<[Playlist], Error> {
        return perform(.likedPlaylists(uid: uid), as: [LikedPlaylist].self)
            .map { $0.compactMap { $0.playlist } }
            .eraseToAnyPublisher()
    }

    public func setLiked(_ liked: Bool, playlistIDs: [String], uid: Int) -> AnyPublisher<Void, Error> {
        return perform(.setLiked(liked, playlistIDs: playlistIDs, uid: uid), as: AnyValue.self)
            .map { _ in () }
            .eraseToAnyPublisher()
    }

    public func tracks(inPlaylistOf uid: Int, kind: Int) -> AnyPublisher<[Track], Error> {
        return perform(.playlist(uid: uid, kind: kind), as: Playlist.self)
            .flatMap { self.resolve($0.tracks ?? []) }
            .eraseToAnyPublisher()
    }

    // MARK: - Search

    public func search(_ text: String, type: String = "all", page: Int = 0) -> AnyPublisher<SearchResult, Error> {
        return perform(.search(text, type: type, page: page), as: SearchResult.self)
    }

    // MARK: - Playback

    public func downloadInfo(trackID: String) -> AnyPublisher<[DownloadInfo], Error> {
        return perform(.downloadInfo(trackID: trackID), as: [DownloadInfo].self)
    }

    /// Fetches the XML behind `downloadInfoUrl` and signs the file URL.
    /// The XML URL is signed already, so it goes out without the OAuth token.
    public func directLink(for info: DownloadInfo) -> AnyPublisher<URL, Error> {
        return session.dataTaskPublisher(for: URLRequest(url: info.downloadInfoUrl))
            .mapError { $0 as Error }
            .tryMap { data, response in
                if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
                    throw YandexMusicError.http(status: status, message: nil)
                }
                guard let url = DirectLinkParts(xml: data)?.url else { throw YandexMusicError.badDownloadInfo }
                return url
            }
            .eraseToAnyPublisher()
    }

    /// The best playable file of a track: a signed MP3/AAC URL for `AVPlayer`.
    public func streamLink(trackID: String) -> AnyPublisher<StreamLink, Error> {
        return downloadInfo(trackID: trackID)
            .tryMap { infos -> DownloadInfo in
                guard let info = infos.preferred() else { throw YandexMusicError.noPlayableFile }
                return info
            }
            .flatMap { info in
                self.directLink(for: info)
                    .map { StreamLink(url: $0, codec: info.codec, bitrateInKbps: info.bitrateInKbps, isPreview: info.isPreview) }
            }
            .eraseToAnyPublisher()
    }

    // MARK: - Token

    /// The token in pasted text: a bare token, `OAuth <token>`, or a redirect URL
    /// with `access_token=` in its fragment. `nil` when nothing usable is left.
    public static func token(fromPasted text: String) -> String? {
        var token = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if let range = token.range(of: "access_token=") {
            token = String(token[range.upperBound...].prefix { $0 != "&" && $0 != "#" })
        }
        if token.lowercased().hasPrefix("oauth ") {
            token = String(token.dropFirst("oauth ".count)).trimmingCharacters(in: .whitespaces)
        }

        guard !token.isEmpty, !token.contains(where: { $0.isWhitespace }) else { return nil }
        return token
    }

}

// MARK: - Envelopes

private struct Envelope<T: Decodable>: Decodable {

    var result: T?

}

private struct ErrorEnvelope: Decodable {

    var error: APIError?

}

/// `"error"` is a string in some responses and `{"name", "message"}` in others.
private struct APIError: Decodable {

    var name: String?
    var message: String?

    private enum CodingKeys: String, CodingKey {
        case name, message
    }

    init(from decoder: Decoder) throws {
        if let string = try? decoder.singleValueContainer().decode(String.self) {
            name = string
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        message = try container.decodeIfPresent(String.self, forKey: .message)
    }

}

/// Any JSON value; for endpoints whose result Nuage does not need.
struct AnyValue: Decodable {

    init(from decoder: Decoder) throws {}

}

/// `application/x-www-form-urlencoded`: everything but unreserved characters is escaped,
/// including `+` and `&`, which `URLComponents` would leave as they are.
func formEncoded(_ items: [URLQueryItem]) -> String {
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    return items.map { item in
        let name = item.name.addingPercentEncoding(withAllowedCharacters: allowed) ?? item.name
        let value = (item.value ?? "").addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return "\(name)=\(value)"
    }.joined(separator: "&")
}
