//
//  YandexMusicProvider.swift
//  Nuage
//
//  Yandex Music behind the `MusicProvider` seam, over the unofficial API
//  (the `YandexMusic` package). The user pastes an OAuth token in
//  Settings → Accounts; it is checked with `/account/status` and kept only in
//  the Keychain. Playback resolves `download-info` to a signed MP3/AAC URL
//  that `AVPlayer` plays. Lossless (encrypted FLAC) is not supported.
//

import Foundation
import AVFoundation
import Combine
import YandexMusic

/// Artwork size asked from Yandex's image service, in pixels.
private let artworkSize = 400

/// The pasted text holds no token.
struct InvalidTokenError: LocalizedError {

    var errorDescription: String? {
        return "This does not look like a token. Paste it without spaces or line breaks."
    }

}

struct InvalidPlaylistIDError: Error {

    var id: MediaID

}

final class YandexMusicProvider: MusicProvider {

    let id = ProviderID.yandexMusic
    let capabilities: ProviderCapabilities = [.search, .likes, .toggleLike, .playlists, .radio]

    fileprivate let client: YandexMusicClient
    private let tokenStore: SecretStore
    private let authSubject = CurrentValueSubject<AuthState, Never>(.signedOut)
    private var subscriptions = Set<AnyCancellable>()

    /// The signed-in account, from `/account/status`.
    private var uid: Int?
    /// `nil` until the account status or a stream tells.
    private var hasPlus: Bool?
    private var tokenRejected = false
    /// Bumped on every sign-in and sign-out. Answers to requests of an earlier
    /// session are dropped, so they cannot sign a signed-out user back in or
    /// expire a fresh session.
    fileprivate private(set) var generation = 0
    /// Requests nobody waits for (radio feedback, dislikes), kept until they finish,
    /// even when the radio that sent them is gone.
    private var pendingRequests = [UUID: AnyCancellable]()

    /// The client's session is ephemeral: no on-disk HTTP cache that could keep
    /// requests (and their `Authorization` header) or account data.
    init(client: YandexMusicClient = YandexMusicClient(session: URLSession(configuration: .ephemeral)),
         tokenStore: SecretStore = KeychainSecretStore(service: "ch.laurinbrandner.nuage.yandex-music",
                                                       account: "oauth-token",
                                                       label: "Nuage: Yandex Music token")) {
        self.client = client
        self.tokenStore = tokenStore
    }

    // MARK: - Auth

    var authState: AuthState { authSubject.value }

    var authStatePublisher: AnyPublisher<AuthState, Never> {
        return authSubject.removeDuplicates().eraseToAnyPublisher()
    }

    var accountNotice: String? {
        if tokenRejected {
            return "Yandex Music rejected the saved token. Sign in with a new one."
        }
        if hasPlus == false {
            return "No Yandex Plus: tracks play as 30-second previews."
        }
        return nil
    }

    /// Checks a pasted token with Yandex and, only if it is accepted, saves it in
    /// the Keychain and switches to it. Until then the current session is untouched.
    func signIn(token pasted: String) -> AnyPublisher<Void, Error> {
        guard let token = YandexMusicClient.token(fromPasted: pasted) else {
            return Fail(error: InvalidTokenError()).eraseToAnyPublisher()
        }

        return client.accountStatus(candidate: token)
            .receive(on: RunLoop.main)
            .tryMap { [weak self] status in
                guard let self = self else { return }
                try self.tokenStore.write(token)
                self.startSession(token: token)
                self.apply(status)
            }
            .eraseToAnyPublisher()
    }

    private func startSession(token: String?) {
        generation += 1
        subscriptions.removeAll()
        client.token = token
        uid = nil
        hasPlus = nil
        tokenRejected = false
    }

    /// Signs in with the saved token right away and checks it in the background;
    /// a rejected token turns the state into `.expired`.
    @discardableResult func restoreSession() -> Bool {
        guard let token = tokenStore.read() else {
            authSubject.send(.signedOut)
            return false
        }

        startSession(token: token)
        authSubject.send(.signedIn(displayName: nil))

        let generation = self.generation
        checked(client.accountStatus())
            .receive(on: RunLoop.main)
            .sink(receiveCompletion: { completion in
                if case let .failure(error) = completion {
                    print("Failed to load the Yandex Music account: \(error)")
                }
            }, receiveValue: { [weak self] status in
                guard let self = self, self.generation == generation else { return }
                self.apply(status)
            })
            .store(in: &subscriptions)

        return true
    }

    func signOut() {
        tokenStore.delete()
        startSession(token: nil)
        authSubject.send(.signedOut)
    }

    private func apply(_ status: AccountStatus) {
        uid = status.account.uid
        hasPlus = status.hasPlus
        tokenRejected = false
        authSubject.send(.signedIn(displayName: status.displayName))
    }

    /// A request of the current session rejected for authorization marks it expired.
    /// Call on the main thread: the session is captured when the request is made.
    fileprivate func checked<T>(_ publisher: AnyPublisher<T, Error>) -> AnyPublisher<T, Error> {
        let generation = self.generation

        return publisher
            .handleEvents(receiveCompletion: { [weak self] completion in
                guard case let .failure(error) = completion,
                      error as? YandexMusicError == .unauthorized else { return }
                DispatchQueue.main.async {
                    guard let self = self, self.generation == generation, self.client.token != nil else { return }
                    self.tokenRejected = true
                    self.authSubject.send(.expired)
                }
            })
            .eraseToAnyPublisher()
    }

    fileprivate func currentUID() -> AnyPublisher<Int, Error> {
        if let uid = uid {
            return Just(uid).setFailureType(to: Error.self).eraseToAnyPublisher()
        }

        let generation = self.generation
        return checked(client.accountStatus())
            .receive(on: RunLoop.main)
            .map { [weak self] status -> Int in
                if let self = self, self.generation == generation, self.isSignedIn {
                    self.apply(status)
                }
                // `accountStatus()` fails without a uid
                return status.account.uid ?? 0
            }
            .eraseToAnyPublisher()
    }

    // MARK: - Catalog and library

    func search(_ query: String, limit: Int) -> AnyPublisher<SearchResults, Error> {
        let uid = self.uid

        return checked(client.search(query))
            .map { result in
                SearchResults(tracks: (result.tracks?.results ?? []).prefix(limit).map(MediaTrack.init),
                              artists: (result.artists?.results ?? []).prefix(limit).map(MediaArtist.init),
                              playlists: (result.playlists?.results ?? []).prefix(limit).map { MediaPlaylist($0, signedInUID: uid) })
            }
            .eraseToAnyPublisher()
    }

    func likedTracks() -> AnyPublisher<[MediaTrack], Error> {
        return currentUID()
            .flatMap { self.checked(self.client.likedTracks(uid: $0)) }
            .map { $0.map(MediaTrack.init) }
            .eraseToAnyPublisher()
    }

    func setLiked(_ liked: Bool, track: MediaTrack) -> AnyPublisher<Void, Error> {
        return currentUID()
            .flatMap { self.checked(self.client.setLiked(liked, trackIDs: [track.id.rawID], uid: $0)) }
            .eraseToAnyPublisher()
    }

    /// Created playlists, then liked ones. A failure to load the liked ones keeps the created ones.
    func playlists() -> AnyPublisher<[MediaPlaylist], Error> {
        return currentUID()
            .flatMap { uid -> AnyPublisher<[MediaPlaylist], Error> in
                let liked = self.client.likedPlaylists(uid: uid)
                    .catch { error -> Just<[YandexMusic.Playlist]> in
                        print("Failed to load liked Yandex Music playlists: \(error)")
                        return Just([])
                    }
                    .setFailureType(to: Error.self)

                return self.checked(self.client.playlists(uid: uid))
                    .zip(liked)
                    .map { owned, liked in
                        let ownedIDs = Set(owned.map { $0.playlistID })
                        let others = liked.filter { !ownedIDs.contains($0.playlistID) }
                        return (owned + others).map { MediaPlaylist($0, signedInUID: uid) }
                    }
                    .eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
    }

    func setLiked(_ liked: Bool, playlist: MediaPlaylist) -> AnyPublisher<Void, Error> {
        return currentUID()
            .flatMap { self.checked(self.client.setLiked(liked, playlistIDs: [playlist.id.rawID], uid: $0)) }
            .eraseToAnyPublisher()
    }

    func tracks(in playlist: MediaPlaylist) -> AnyPublisher<[MediaTrack], Error> {
        let parts = playlist.id.rawID.split(separator: ":")
        guard parts.count == 2, let owner = Int(parts[0]), let kind = Int(parts[1]) else {
            return Fail(error: InvalidPlaylistIDError(id: playlist.id)).eraseToAnyPublisher()
        }

        return checked(client.tracks(inPlaylistOf: owner, kind: kind))
            .map { $0.map(MediaTrack.init) }
            .eraseToAnyPublisher()
    }

    func add(_ track: MediaTrack, to playlist: MediaPlaylist) -> AnyPublisher<Void, Error> {
        return unsupported("editPlaylists")
    }

    // MARK: - Playback

    /// A preview-only answer means the account has no Yandex Plus; `accountNotice` says so.
    func playbackSource(for track: MediaTrack) -> AnyPublisher<PlaybackSource, Error> {
        return checked(client.streamLink(trackID: track.id.rawID))
            .receive(on: RunLoop.main)
            .map { [weak self] link -> PlaybackSource in
                if link.isPreview {
                    self?.hasPlus = false
                }
                return .asset(Self.asset(for: link))
            }
            .eraseToAnyPublisher()
    }

    // MARK: - «Моя волна»

    func radio() -> (any RadioSession)? {
        guard isSignedIn else { return nil }
        return YandexWave(owner: self, station: YandexMusicClient.myWave, from: YandexMusicClient.myWaveFrom)
    }

    /// Sends a request whose answer only matters for the log. Call on the main thread.
    fileprivate func fireAndForget(_ request: AnyPublisher<Void, Error>, _ description: String) {
        let id = UUID()
        // The answer comes on the next run loop pass at the earliest, after the cancellable is stored
        pendingRequests[id] = request
            .receive(on: RunLoop.main)
            .sink(receiveCompletion: { [weak self] completion in
                if case let .failure(error) = completion {
                    print("Failed to \(description): \(error)")
                }
                self?.pendingRequests[id] = nil
            }, receiveValue: { _ in })
    }

    /// The file URL has no extension, so the MIME type is given where the OS allows it.
    private static func asset(for link: StreamLink) -> AVURLAsset {
        var options = [String: Any]()
        if #available(macOS 14, *) {
            options[AVURLAssetOverrideMIMETypeKey] = (link.codec.lowercased() == "aac") ? "audio/aac" : "audio/mpeg"
        }
        return AVURLAsset(url: link.url, options: options)
    }

}

// MARK: - «Моя волна»

/// One listening session of «Моя волна» (the rotor station `user:onyourwave`).
/// It belongs to the provider session it was started in: after a sign-out or a
/// switch of accounts it loads nothing and reports nothing.
final class YandexWave: RadioSession {

    let provider = ProviderID.yandexMusic
    let title = ProviderID.yandexMusic.radioTitle

    private weak var owner: YandexMusicProvider?
    private let station: String
    private let from: String
    private let generation: Int
    /// The batch each track came in; its feedback names that batch.
    private var batchIDs = [String: String]()
    /// How the station names each track when asked for the batch after it.
    private var queueIDs = [String: String]()
    private var didReportRadioStart = false

    fileprivate init(owner: YandexMusicProvider, station: String, from: String) {
        self.owner = owner
        self.station = station
        self.from = from
        self.generation = owner.generation
    }

    var isActive: Bool {
        return liveOwner != nil
    }

    /// The provider still runs the session this radio was started in.
    private var liveOwner: YandexMusicProvider? {
        guard let owner = owner, owner.generation == generation, owner.isSignedIn else { return nil }
        return owner
    }

    func nextBatch(after last: MediaTrack?) -> AnyPublisher<[MediaTrack], Error> {
        guard let owner = liveOwner else {
            return Fail(error: RadioEndedError()).eraseToAnyPublisher()
        }

        let queue = last.map { queueIDs[$0.id.rawID] ?? $0.id.rawID }
        return owner.checked(owner.client.stationTracks(station, queue: queue))
            .receive(on: RunLoop.main)
            .tryMap { [weak self] batch -> [MediaTrack] in
                guard let self = self, self.liveOwner != nil else { throw RadioEndedError() }

                let tracks = batch.tracks
                for track in tracks {
                    self.batchIDs[track.id.value] = batch.batchId
                    self.queueIDs[track.id.value] = track.stationQueueID
                }
                // Once per listening session, with the first batch
                if !self.didReportRadioStart {
                    self.didReportRadioStart = true
                    self.send(.radioStarted(from: self.from), batchID: batch.batchId)
                }
                return tracks.map(MediaTrack.init)
            }
            .eraseToAnyPublisher()
    }

    func didStart(_ track: MediaTrack) {
        send(.trackStarted(track.id.rawID), for: track)
    }

    func didFinish(_ track: MediaTrack, playedSeconds: TimeInterval) {
        send(.trackFinished(track.id.rawID, playedSeconds: playedSeconds), for: track)
    }

    func didSkip(_ track: MediaTrack, playedSeconds: TimeInterval) {
        send(.skip(track.id.rawID, playedSeconds: playedSeconds), for: track)
    }

    /// A skip for the station, and the track goes into the account's dislikes.
    func dislike(_ track: MediaTrack, playedSeconds: TimeInterval) {
        didSkip(track, playedSeconds: playedSeconds)

        guard let owner = liveOwner else { return }
        let request = owner.currentUID()
            .flatMap { [weak self] uid -> AnyPublisher<Void, Error> in
                // The uid may have been looked up while the session changed
                guard let owner = self?.liveOwner else { return Fail(error: RadioEndedError()).eraseToAnyPublisher() }
                return owner.checked(owner.client.setDisliked(true, trackIDs: [track.id.rawID], uid: uid))
            }
            .eraseToAnyPublisher()
        owner.fireAndForget(request, "dislike a track")
    }

    private func send(_ feedback: StationFeedback, for track: MediaTrack) {
        send(feedback, batchID: batchIDs[track.id.rawID])
    }

    private func send(_ feedback: StationFeedback, batchID: String?) {
        guard let owner = liveOwner else { return }
        owner.fireAndForget(owner.checked(owner.client.sendFeedback(feedback, station: station, batchID: batchID)),
                            "send «\(title)» feedback (\(feedback.kind.rawValue))")
    }

}

// MARK: - Neutral models

extension MediaTrack {

    init(_ track: YandexMusic.Track) {
        let artist = track.artists?.first
        self.init(id: MediaID(provider: .yandexMusic, rawID: track.id.value),
                  title: track.displayTitle,
                  artist: MediaArtist(id: MediaID(provider: .yandexMusic, rawID: artist?.id.value ?? ""),
                                      name: track.artistNames,
                                      avatarURL: artist?.imageURL(size: artworkSize),
                                      permalinkURL: artist?.webURL),
                  artworkURL: track.coverURL(size: artworkSize),
                  duration: track.duration,
                  permalinkURL: track.webURL,
                  waveformURL: nil,
                  streamLocator: nil)
    }

}

extension MediaArtist {

    init(_ artist: YandexMusic.Artist) {
        self.init(id: MediaID(provider: .yandexMusic, rawID: artist.id.value),
                  name: artist.name,
                  avatarURL: artist.imageURL(size: artworkSize),
                  permalinkURL: artist.webURL)
    }

}

extension MediaPlaylist {

    /// The raw id is `ownerUid:kind`.
    init(_ playlist: YandexMusic.Playlist, signedInUID: Int?) {
        let owner = playlist.owner.map { owner in
            MediaArtist(id: MediaID(provider: .yandexMusic, rawID: String(owner.uid)),
                        name: owner.name ?? owner.login ?? "",
                        avatarURL: nil,
                        permalinkURL: nil)
        }

        self.init(id: MediaID(provider: .yandexMusic, rawID: playlist.playlistID),
                  title: playlist.title,
                  owner: owner,
                  artworkURL: playlist.coverURL(size: artworkSize),
                  trackCount: playlist.trackCount,
                  isOwned: playlist.uid == signedInUID,
                  isSystem: false,
                  description: playlist.description,
                  permalinkURL: playlist.webURL)
    }

}
