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
    let capabilities: ProviderCapabilities = [.search, .likes, .toggleLike, .playlists]

    private let client: YandexMusicClient
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
    private var generation = 0

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
    private func checked<T>(_ publisher: AnyPublisher<T, Error>) -> AnyPublisher<T, Error> {
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

    private func currentUID() -> AnyPublisher<Int, Error> {
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

    /// The file URL has no extension, so the MIME type is given where the OS allows it.
    private static func asset(for link: StreamLink) -> AVURLAsset {
        var options = [String: Any]()
        if #available(macOS 14, *) {
            options[AVURLAssetOverrideMIMETypeKey] = (link.codec.lowercased() == "aac") ? "audio/aac" : "audio/mpeg"
        }
        return AVURLAsset(url: link.url, options: options)
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
