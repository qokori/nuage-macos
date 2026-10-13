//
//  SoundCloudProvider.swift
//  Nuage
//
//  SoundCloud behind the `MusicProvider` seam. A thin adapter over the existing
//  `SoundCloud` package client: same endpoints, same UserDefaults keys, so
//  sessions saved by upstream Nuage keep working after the update.
//

import Foundation
import AVFoundation
import Combine
import SoundCloud

private let accessTokenKey = "accessToken"
private let accessTokenExpiryDateKey = "accessTokenExpiryDate"
/// `/tracks?ids=` takes a limited number of ids per call; the UI pages by 50 as well.
private let trackBatchSize = 50

struct TrackNotFoundError: Error {

    var id: MediaID

}

final class SoundCloudProvider: MusicProvider {

    let id = ProviderID.soundCloud
    let capabilities: ProviderCapabilities = [.search, .likes, .toggleLike, .playlists, .editPlaylists,
                                              .feed, .history, .waveform, .comments, .reposts]

    private let client: SoundCloud
    private let defaults: UserDefaults
    private let authSubject: CurrentValueSubject<AuthState, Never>
    private var subscriptions = Set<AnyCancellable>()
    private var queuedTracks = [String: Track]()

    init(client: SoundCloud = SoundCloud.shared, defaults: UserDefaults = .standard) {
        self.client = client
        self.defaults = defaults

        let initialState: AuthState = (client.accessToken == nil) ? .signedOut : .signedIn(displayName: client.user?.username)
        authSubject = CurrentValueSubject(initialState)

        // `/me` arrives after the token is set; refresh the display name then.
        client.$user
            .sink { [weak self] user in
                guard let self = self, self.client.accessToken != nil else { return }
                self.authSubject.send(.signedIn(displayName: user?.username))
            }
            .store(in: &subscriptions)
    }

    // MARK: - Auth

    var authState: AuthState { authSubject.value }

    var authStatePublisher: AnyPublisher<AuthState, Never> {
        return authSubject.removeDuplicates().eraseToAnyPublisher()
    }

    /// Called once the SoundCloud web login hands over the `oauth_token` cookie.
    func signIn(accessToken: String, expiryDate: Date?) {
        defaults.set(accessToken, forKey: accessTokenKey)
        defaults.set(expiryDate, forKey: accessTokenExpiryDateKey)
        client.accessToken = accessToken
        authSubject.send(.signedIn(displayName: client.user?.username))
    }

    @discardableResult func restoreSession() -> Bool {
        guard let token = defaults.object(forKey: accessTokenKey) as? String else {
            authSubject.send(.signedOut)
            return false
        }

        if let expiryDate = defaults.object(forKey: accessTokenExpiryDateKey) as? Date, expiryDate < Date() {
            defaults.set(nil, forKey: accessTokenKey)
            defaults.set(nil, forKey: accessTokenExpiryDateKey)
            authSubject.send(.expired)
            return false
        }

        client.accessToken = token
        authSubject.send(.signedIn(displayName: client.user?.username))
        return true
    }

    /// Forgets the saved session. The in-memory token stays until relaunch:
    /// `SoundCloud.accessToken` cannot be set to `nil` (its `didSet` force-unwraps it).
    func signOut() {
        defaults.set(nil, forKey: accessTokenKey)
        defaults.set(nil, forKey: accessTokenExpiryDateKey)
        client.user = nil
        authSubject.send(.signedOut)
    }

    // MARK: - Catalog and library

    func search(_ query: String, limit: Int = 20) -> AnyPublisher<SearchResults, Error> {
        let ownerID = client.user?.id

        return client.get(.search(query), limit: limit)
            .map { page in
                var results = SearchResults()
                for item in page.collection {
                    switch item {
                    case .track(let track): results.tracks.append(MediaTrack(track))
                    case .user(let user): results.artists.append(MediaArtist(user))
                    case .userPlaylist(let playlist): results.playlists.append(MediaPlaylist(.user(playlist), ownerID: ownerID))
                    case .systemPlaylist(let playlist): results.playlists.append(MediaPlaylist(.system(playlist), ownerID: ownerID))
                    }
                }
                return results
            }
            .eraseToAnyPublisher()
    }

    func likedTracks(limit: Int = 50) -> AnyPublisher<[MediaTrack], Error> {
        return currentUser()
            .flatMap { self.client.get(.trackLikes(of: $0), count: limit) }
            .map { page in page.collection.map { MediaTrack($0.item) } }
            .eraseToAnyPublisher()
    }

    func setLiked(_ liked: Bool, track: MediaTrack) -> AnyPublisher<Void, Error> {
        return soundCloudTrack(for: track)
            .flatMap { track -> AnyPublisher<(), Error> in
                let request: APIRequest<String> = liked ? .like(track) : .unlike(track)
                return self.client.perform(request)
            }
            .eraseToAnyPublisher()
    }

    func playlists() -> AnyPublisher<[MediaPlaylist], Error> {
        let ownerID = client.user?.id

        return client.get(all: .library())
            .map { likes in likes.map { MediaPlaylist($0.item, ownerID: ownerID) } }
            .eraseToAnyPublisher()
    }

    func tracks(in playlist: MediaPlaylist) -> AnyPublisher<[MediaTrack], Error> {
        let ids: AnyPublisher<[String], Error>
        if playlist.isSystem {
            ids = client.get(.systemPlaylist(playlist.id.rawID))
                .map { $0.trackIDs ?? [] }
                .eraseToAnyPublisher()
        }
        else {
            ids = client.get(.userPlaylist(playlist.id.rawID))
                .map { $0.trackIDs ?? [] }
                .eraseToAnyPublisher()
        }

        return ids
            .flatMap { self.tracks(withIDs: $0) }
            .map { $0.map(MediaTrack.init) }
            .eraseToAnyPublisher()
    }

    // MARK: - Playback

    func playbackSource(for track: MediaTrack) -> AnyPublisher<PlaybackSource, Error> {
        let locator: AnyPublisher<URL, Error>
        if let url = track.streamLocator {
            locator = Just(url)
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }
        else {
            locator = soundCloudTrack(for: track)
                .tryMap { track -> URL in
                    guard let url = track.streamURL else { throw NoStreamError() }
                    return url
                }
                .eraseToAnyPublisher()
        }

        return locator
            .flatMap { self.client.get(.audioFile($0)) }
            .map { PlaybackSource.asset(AVURLAsset(url: $0)) }
            .eraseToAnyPublisher()
    }

    func didStartPlayback(of track: MediaTrack) {
        soundCloudTrack(for: track)
            .sink(receiveCompletion: { completion in
                if case let .failure(error) = completion {
                    print("Failed to add track to history: \(error)")
                }
            }, receiveValue: { [weak self] track in
                self?.addToHistory(track)
            })
            .store(in: &subscriptions)
    }

    // MARK: - Bridge to SoundCloud screens
    // Track detail, likes and reposts are SoundCloud screens that work on `Track`,
    // while the player queues `MediaTrack`s. The provider remembers the `Track`
    // behind every track handed to the player, so those screens and the play
    // history get the original back without another request.

    /// Converts a track for the player and remembers the original.
    func mediaTrack(for track: Track) -> MediaTrack {
        queuedTracks[track.id] = track
        return MediaTrack(track)
    }

    /// The SoundCloud track behind a queued track, if it came from SoundCloud.
    func track(for track: MediaTrack) -> Track? {
        guard track.provider == id else { return nil }
        return queuedTracks[track.id.rawID]
    }

    /// Adds the track to the SoundCloud play history. Errors are logged, never shown.
    private func addToHistory(_ track: Track) {
        client.perform(.addToHistory(track))
            .sink(receiveCompletion: { completion in
                if case let .failure(error) = completion {
                    print("Failed to add track to history: \(error)")
                }
            }, receiveValue: { _ in })
            .store(in: &subscriptions)
    }

    // MARK: - Helpers

    /// Waits for `/me` after sign-in, like the existing views do.
    private func currentUser() -> AnyPublisher<User, Error> {
        return client.$user
            .compactMap { $0 }
            .first()
            .setFailureType(to: Error.self)
            .eraseToAnyPublisher()
    }

    private func soundCloudTrack(for track: MediaTrack) -> AnyPublisher<Track, Error> {
        if let track = self.track(for: track) {
            return Just(track)
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }

        let id = track.id

        return client.get(.tracks([id.rawID]))
            .tryMap { tracks -> Track in
                guard let track = tracks.first else { throw TrackNotFoundError(id: id) }
                return track
            }
            .eraseToAnyPublisher()
    }

    /// Fetches full tracks in batches and keeps the order of `ids`
    /// (`/tracks?ids=` does not guarantee it).
    private func tracks(withIDs ids: [String]) -> AnyPublisher<[Track], Error> {
        guard !ids.isEmpty else {
            return Just([])
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }

        let batches = stride(from: 0, to: ids.count, by: trackBatchSize).map {
            Array(ids[$0..<min($0 + trackBatchSize, ids.count)])
        }

        return batches.publisher
            .setFailureType(to: Error.self)
            .flatMap(maxPublishers: .max(1)) { batch -> AnyPublisher<[Track], Error> in
                return self.client.get(.tracks(batch))
            }
            .reduce([Track]()) { $0 + $1 }
            .map { tracks in
                let byID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                return ids.compactMap { byID[$0] }
            }
            .eraseToAnyPublisher()
    }

}

// MARK: - Model conversion

extension MediaArtist {

    init(_ user: User) {
        self.init(id: MediaID(provider: .soundCloud, rawID: user.id),
                  name: user.username,
                  avatarURL: user.avatarURL,
                  permalinkURL: nil)
    }

}

extension MediaTrack {

    init(_ track: Track) {
        self.init(id: MediaID(provider: .soundCloud, rawID: track.id),
                  title: track.title,
                  artist: MediaArtist(track.user),
                  artworkURL: track.artworkURL ?? track.user.avatarURL,
                  duration: TimeInterval(track.duration),
                  permalinkURL: track.permalinkURL,
                  waveformURL: track.waveformURL,
                  streamLocator: track.streamURL)
    }

}

extension MediaPlaylist {

    /// System playlists are addressed by URN, user playlists by numeric id.
    init(_ playlist: AnyPlaylist, ownerID: String?) {
        let rawID: String
        let isSystem: Bool
        switch playlist {
        case .user(let userPlaylist):
            rawID = userPlaylist.id
            isSystem = false
        case .system(let systemPlaylist):
            rawID = systemPlaylist.urn
            isSystem = true
        }

        self.init(id: MediaID(provider: .soundCloud, rawID: rawID),
                  title: playlist.title,
                  owner: MediaArtist(playlist.user),
                  artworkURL: playlist.artworkURL,
                  trackCount: playlist.trackIDs?.count,
                  isOwned: !isSystem && playlist.user.id == ownerID,
                  isSystem: isSystem)
    }

}
