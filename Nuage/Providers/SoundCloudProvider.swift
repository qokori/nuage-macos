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
                                              .feed, .history, .waveform, .comments, .reposts,
                                              .discover, .stations, .following]

    private let client: SoundCloud
    private let defaults: UserDefaults
    private let authSubject: CurrentValueSubject<AuthState, Never>
    private var subscriptions = Set<AnyCancellable>()

    init(client: SoundCloud = SoundCloud.shared, defaults: UserDefaults = .standard) {
        self.client = client
        self.defaults = defaults

        let initialState: AuthState = (client.accessToken == nil) ? .signedOut : .signedIn(displayName: client.user?.username)
        authSubject = CurrentValueSubject(initialState)

        // `/me` arrives after the token is set; refresh the display name then.
        // The saved token, not the client's, tells whether the user is signed in:
        // the client keeps its token in memory after a sign-out.
        client.$user
            .sink { [weak self] user in
                guard let self = self, self.defaults.string(forKey: accessTokenKey) != nil else { return }
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

    func likedTracks() -> AnyPublisher<[MediaTrack], Error> {
        return currentUser()
            .flatMap { self.client.get(all: .trackLikes(of: $0)) }
            .map { likes in likes.map { MediaTrack($0.item) } }
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

    /// Waits for `/me` so that `isOwned` is right on the first load after sign-in.
    func playlists() -> AnyPublisher<[MediaPlaylist], Error> {
        return currentUser()
            .flatMap { user -> AnyPublisher<[MediaPlaylist], Error> in
                self.client.get(all: .library())
                    .map { likes in likes.map { MediaPlaylist($0.item, ownerID: user.id) } }
                    .eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
    }

    func setLiked(_ liked: Bool, playlist: MediaPlaylist) -> AnyPublisher<Void, Error> {
        return soundCloudPlaylist(for: playlist)
            .flatMap { playlist -> AnyPublisher<(), Error> in
                let request: APIRequest<String> = liked ? .like(playlist) : .unlike(playlist)
                return self.client.perform(request)
            }
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

    /// Appends the track to one of the user's own playlists.
    func add(_ track: MediaTrack, to playlist: MediaPlaylist) -> AnyPublisher<Void, Error> {
        guard track.provider == id, !playlist.isSystem, let trackID = Int(track.id.rawID) else {
            return unsupported("adding this track to this playlist")
        }

        return client.get(.userPlaylist(playlist.id.rawID))
            .flatMap { playlist -> AnyPublisher<UserPlaylist, Error> in
                let trackIDs = (playlist.trackIDs ?? []).compactMap { Int($0) } + [trackID]
                return self.client.get(.set(playlist, trackIDs: trackIDs))
            }
            .map { _ in () }
            .eraseToAnyPublisher()
    }

    // MARK: - SoundCloud only
    // Reposts, comments, stations and artist pages exist only on SoundCloud.
    // The UI reaches them through the capabilities, never for other providers.

    /// Ids of the tracks and playlists the user reposted.
    func repostedIDs() -> AnyPublisher<Set<MediaID>, Error> {
        return currentUser()
            .flatMap { self.client.get(all: .stream(of: $0)) }
            .map { posts in
                let ids = posts.filter { $0.isRepost }.map { post -> MediaID in
                    switch post.item {
                    case .track(let track): return MediaID(provider: .soundCloud, rawID: track.id)
                    case .playlist(let playlist): return MediaID(provider: .soundCloud, rawID: playlist.id)
                    }
                }
                return Set(ids)
            }
            .eraseToAnyPublisher()
    }

    func setReposted(_ reposted: Bool, track: MediaTrack) -> AnyPublisher<Void, Error> {
        return soundCloudTrack(for: track)
            .flatMap { track -> AnyPublisher<(), Error> in
                let request: APIRequest<String> = reposted ? .repost(track) : .unrepost(track)
                return self.client.perform(request)
            }
            .eraseToAnyPublisher()
    }

    /// Only user playlists can be reposted.
    func setReposted(_ reposted: Bool, playlist: MediaPlaylist) -> AnyPublisher<Void, Error> {
        return soundCloudPlaylist(for: playlist)
            .tryMap { playlist -> UserPlaylist in
                guard let playlist = playlist.userPlaylist else {
                    throw ProviderUnsupportedError(provider: .soundCloud, capability: "reposting a system playlist")
                }
                return playlist
            }
            .flatMap { playlist -> AnyPublisher<(), Error> in
                let request: APIRequest<String> = reposted ? .repost(playlist) : .unrepost(playlist)
                return self.client.perform(request)
            }
            .eraseToAnyPublisher()
    }

    func comments(of track: MediaTrack) -> AnyPublisher<Page<Comment>, Error> {
        return soundCloudTrack(for: track)
            .flatMap { track -> AnyPublisher<Page<Comment>, Error> in
                return self.client.get(.comments(of: track))
            }
            .eraseToAnyPublisher()
    }

    /// Track ids of the station generated from `track`.
    func stationTrackIDs(basedOn track: MediaTrack) -> AnyPublisher<[String], Error> {
        return soundCloudTrack(for: track)
            .flatMap { self.client.get(.trackStation(basedOn: $0)) }
            .map { $0.trackIDs ?? [] }
            .eraseToAnyPublisher()
    }

    /// A `User` to open the SoundCloud artist page with. `UserDetail` loads the
    /// full profile itself, so the id, name and avatar are enough.
    func user(for artist: MediaArtist) -> User? {
        guard artist.provider == id, let avatarURL = artist.avatarURL else { return nil }

        var user = User(id: artist.id.rawID, username: artist.name, firstName: "", lastName: "", avatarURL: avatarURL)
        user.followerCount = artist.followerCount
        user.trackCount = artist.trackCount
        return user
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
        if let track = SoundCloudCache.tracks.object(forKey: track.id.rawID as NSString)?.value {
            return Just(track)
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }

        let id = track.id

        return client.get(.tracks([id.rawID]))
            .tryMap { tracks -> Track in
                guard let track = tracks.first else { throw TrackNotFoundError(id: id) }
                SoundCloudCache.remember(track)
                return track
            }
            .eraseToAnyPublisher()
    }

    private func soundCloudPlaylist(for playlist: MediaPlaylist) -> AnyPublisher<AnyPlaylist, Error> {
        if let playlist = SoundCloudCache.playlists.object(forKey: playlist.id.rawID as NSString)?.value {
            return Just(playlist)
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }

        let rawID = playlist.id.rawID
        let fetched: AnyPublisher<AnyPlaylist, Error>
        if playlist.isSystem {
            fetched = client.get(.systemPlaylist(rawID))
                .map { AnyPlaylist.system($0) }
                .eraseToAnyPublisher()
        }
        else {
            fetched = client.get(.userPlaylist(rawID))
                .map { AnyPlaylist.user($0) }
                .eraseToAnyPublisher()
        }

        return fetched
            .handleEvents(receiveOutput: { SoundCloudCache.remember($0) })
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

// MARK: - Payload cache

/// The SoundCloud payloads behind the neutral models handed to the UI. The
/// package's request builders take a whole `Track` or playlist although they
/// only read its id, and `Track` has no public initializer. Remembering the
/// payload saves a lookup per like, repost or history entry; a miss (evicted,
/// or a track restored from elsewhere) falls back to fetching by id.
private enum SoundCloudCache {

    final class Box<Value> {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

    static let tracks: NSCache<NSString, Box<Track>> = {
        let cache = NSCache<NSString, Box<Track>>()
        cache.countLimit = 5000
        return cache
    }()

    static let playlists: NSCache<NSString, Box<AnyPlaylist>> = {
        let cache = NSCache<NSString, Box<AnyPlaylist>>()
        cache.countLimit = 1000
        return cache
    }()

    static func remember(_ track: Track) {
        tracks.setObject(Box(track), forKey: track.id as NSString)
    }

    /// Keyed like `MediaPlaylist.id.rawID`: URN for system playlists, id for user playlists.
    static func remember(_ playlist: AnyPlaylist) {
        let key: String
        switch playlist {
        case .user(let userPlaylist): key = userPlaylist.id
        case .system(let systemPlaylist): key = systemPlaylist.urn
        }
        playlists.setObject(Box(playlist), forKey: key as NSString)
    }

}

// MARK: - Model conversion

extension MediaArtist {

    init(_ user: User) {
        self.init(id: MediaID(provider: .soundCloud, rawID: user.id),
                  name: user.username,
                  avatarURL: user.avatarURL,
                  permalinkURL: nil,
                  followerCount: user.followerCount,
                  trackCount: user.trackCount)
    }

}

extension MediaTrack {

    init(_ track: Track) {
        SoundCloudCache.remember(track)
        self.init(id: MediaID(provider: .soundCloud, rawID: track.id),
                  title: track.title,
                  artist: MediaArtist(track.user),
                  artworkURL: track.artworkURL ?? track.user.avatarURL,
                  duration: TimeInterval(track.duration),
                  permalinkURL: track.permalinkURL,
                  waveformURL: track.waveformURL,
                  streamLocator: track.streamURL,
                  description: track.description,
                  stats: MediaStats(plays: track.playbackCount, likes: track.likeCount, reposts: track.repostCount))
    }

}

extension MediaPlaylist {

    /// SoundCloud screens (feed, Discover, search) own no provider; the signed-in
    /// user comes from the shared client.
    init(_ playlist: AnyPlaylist) {
        self.init(playlist, ownerID: SoundCloud.shared.user?.id)
    }

    /// System playlists are addressed by URN, user playlists by numeric id.
    init(_ playlist: AnyPlaylist, ownerID: String?) {
        SoundCloudCache.remember(playlist)
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
                  isSystem: isSystem,
                  description: playlist.description,
                  permalinkURL: playlist.permalinkURL,
                  previewTracks: playlist.tracks?.map(MediaTrack.init))
    }

}
