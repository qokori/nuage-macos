//
//  Library.swift
//  Nuage
//
//  The signed-in user's library across providers: liked tracks, playlists and,
//  on SoundCloud, reposts. Rows read like and repost state from here and toggle
//  through it; the sidebar lists the playlists. A provider's part is loaded when
//  it signs in and dropped when it signs out.
//

import Foundation
import Combine

/// Playlists are saved, so the sidebar is filled before the first reload finishes.
private let playlistsKey = "libraryPlaylists"

final class Library: ObservableObject {

    @Published private(set) var likedTrackIDs = Set<MediaID>()
    /// Created, liked and followed playlists of every signed-in provider.
    @Published private(set) var playlists = [MediaPlaylist]()
    @Published private(set) var repostedIDs = Set<MediaID>()

    private let registry: ProviderRegistry
    private var loads = [ProviderID: Set<AnyCancellable>]()
    private var subscriptions = Set<AnyCancellable>()

    init(registry: ProviderRegistry = .shared, defaults: UserDefaults = .standard) {
        self.registry = registry

        if let data = defaults.data(forKey: playlistsKey),
           let saved = try? JSONDecoder().decode([MediaPlaylist].self, from: data) {
            playlists = saved.filter { registry.provider(for: $0.provider)?.isSignedIn ?? false }
        }

        $playlists
            .dropFirst()
            .sink { playlists in
                let stripped = playlists.map { playlist -> MediaPlaylist in
                    var playlist = playlist
                    playlist.previewTracks = nil
                    return playlist
                }
                defaults.set(try? JSONEncoder().encode(stripped), forKey: playlistsKey)
            }
            .store(in: &subscriptions)

        for provider in registry.providers {
            let id = provider.id
            provider.authStatePublisher
                .map { state -> Bool in
                    if case .signedIn = state { return true }
                    return false
                }
                .removeDuplicates()
                .receive(on: RunLoop.main)
                .sink { [weak self] signedIn in
                    if signedIn {
                        self?.reload(id)
                    }
                    else {
                        self?.forget(id)
                    }
                }
                .store(in: &subscriptions)
        }
    }

    // MARK: - Loading

    /// Reloads one provider's part. On failure the previous state stays.
    func reload(_ id: ProviderID) {
        guard let provider = registry.provider(for: id) else { return }

        var load = Set<AnyCancellable>()

        if provider.capabilities.contains(.likes) {
            provider.likedTracks()
                .map { Set($0.map { $0.id }) }
                .receive(on: RunLoop.main)
                .sink(receiveCompletion: logFailure("load liked tracks of \(id.displayName)"),
                      receiveValue: { [weak self] ids in
                    guard let self = self else { return }
                    self.likedTrackIDs = self.likedTrackIDs.filter { $0.provider != id }.union(ids)
                })
                .store(in: &load)
        }

        if provider.capabilities.contains(.playlists) {
            provider.playlists()
                .receive(on: RunLoop.main)
                .sink(receiveCompletion: logFailure("load playlists of \(id.displayName)"),
                      receiveValue: { [weak self] playlists in
                    guard let self = self else { return }
                    self.playlists = self.playlists.filter { $0.provider != id } + playlists
                })
                .store(in: &load)
        }

        if provider.capabilities.contains(.reposts), id == .soundCloud {
            registry.soundCloud.repostedIDs()
                .receive(on: RunLoop.main)
                .sink(receiveCompletion: logFailure("load reposts"),
                      receiveValue: { [weak self] ids in
                    guard let self = self else { return }
                    self.repostedIDs = self.repostedIDs.filter { $0.provider != id }.union(ids)
                })
                .store(in: &load)
        }

        loads[id] = load
    }

    private func forget(_ id: ProviderID) {
        loads[id] = nil
        likedTrackIDs = likedTrackIDs.filter { $0.provider != id }
        playlists.removeAll { $0.provider == id }
        repostedIDs = repostedIDs.filter { $0.provider != id }
    }

    // MARK: - Queries

    func playlists(of id: ProviderID) -> [MediaPlaylist] {
        return playlists.filter { $0.provider == id }
    }

    /// Playlists the user can add tracks to.
    func editablePlaylists(of id: ProviderID) -> [MediaPlaylist] {
        guard registry.capabilities(of: id).contains(.editPlaylists) else { return [] }
        return playlists.filter { $0.provider == id && $0.isOwned && !$0.isSystem }
    }

    func isLiked(_ track: MediaTrack) -> Bool {
        return likedTrackIDs.contains(track.id)
    }

    /// A playlist counts as liked while it is in the library, as on SoundCloud.
    func isLiked(_ playlist: MediaPlaylist) -> Bool {
        return playlists.contains { $0.id == playlist.id }
    }

    func isReposted(_ id: MediaID) -> Bool {
        return repostedIDs.contains(id)
    }

    // MARK: - Actions

    func toggleLike(_ track: MediaTrack) {
        guard let provider = registry.provider(for: track.provider) else { return }

        let like = !isLiked(track)
        perform(provider.setLiked(like, track: track), "like track") { [weak self] in
            if like {
                self?.likedTrackIDs.insert(track.id)
            }
            else {
                self?.likedTrackIDs.remove(track.id)
            }
        }
    }

    func toggleLike(_ playlist: MediaPlaylist) {
        guard let provider = registry.provider(for: playlist.provider) else { return }

        let like = !isLiked(playlist)
        perform(provider.setLiked(like, playlist: playlist), "like playlist") { [weak self] in
            if like {
                self?.playlists.append(playlist)
            }
            else {
                self?.playlists.removeAll { $0.id == playlist.id }
            }
        }
    }

    func toggleRepost(_ track: MediaTrack) {
        guard track.provider == .soundCloud else { return }

        let repost = !isReposted(track.id)
        perform(registry.soundCloud.setReposted(repost, track: track), "repost track") { [weak self] in
            self?.setReposted(repost, id: track.id)
        }
    }

    func toggleRepost(_ playlist: MediaPlaylist) {
        guard playlist.provider == .soundCloud, !playlist.isSystem else { return }

        let repost = !isReposted(playlist.id)
        perform(registry.soundCloud.setReposted(repost, playlist: playlist), "repost playlist") { [weak self] in
            self?.setReposted(repost, id: playlist.id)
        }
    }

    func add(_ track: MediaTrack, to playlist: MediaPlaylist) {
        guard let provider = registry.provider(for: playlist.provider) else { return }

        perform(provider.add(track, to: playlist), "add track to playlist") {}
    }

    // MARK: - Helpers

    private func setReposted(_ reposted: Bool, id: MediaID) {
        if reposted {
            repostedIDs.insert(id)
        }
        else {
            repostedIDs.remove(id)
        }
    }

    private func perform(_ action: AnyPublisher<Void, Error>, _ description: String, onSuccess: @escaping () -> ()) {
        action
            .receive(on: RunLoop.main)
            .sink(receiveCompletion: logFailure(description), receiveValue: { _ in onSuccess() })
            .store(in: &subscriptions)
    }

    private func logFailure(_ description: String) -> (Subscribers.Completion<Error>) -> () {
        return { completion in
            if case let .failure(error) = completion {
                print("Failed to \(description): \(error)")
            }
        }
    }

}
