//
//  Navigation.swift
//  Nuage
//
//  Created by Laurin Brandner on 28.07.23.
//

import Foundation
import SoundCloud

private let userPlaylistSeparator = "@@USERPLAYLIST@@"
private let systemPlaylistSeparator = "@@SYSTEMPLAYLIST@@"
private let playlistPrefix = "playlist:"

/// A sidebar entry. Every section belongs to a provider and is shown only when
/// the provider has the matching capability. SoundCloud sections keep upstream's
/// raw values, so the selection saved by older versions still restores.
enum SidebarItem {
    case discover(ProviderID)
    case stream(ProviderID)
    case likes(ProviderID)
    case history(ProviderID)
    case following(ProviderID)
    case playlist(PlaylistReference)

    /// The library sections of a provider, in sidebar order.
    static func sections(of provider: ProviderID) -> [SidebarItem] {
        return [.discover(provider), .stream(provider), .likes(provider), .history(provider), .following(provider)]
    }

    var provider: ProviderID {
        switch self {
        case .discover(let provider), .stream(let provider), .likes(let provider),
             .history(let provider), .following(let provider):
            return provider
        case .playlist(let playlist):
            return playlist.id.provider
        }
    }

    /// What the provider must support for the entry to appear.
    var requiredCapability: ProviderCapabilities {
        switch self {
        case .discover: return .discover
        case .stream: return .feed
        case .likes: return .likes
        case .history: return .history
        case .following: return .following
        case .playlist: return .playlists
        }
    }

    var title: String {
        switch self {
        case .discover: return "Discover"
        case .stream: return "Stream"
        case .likes: return "Likes"
        case .history: return "History"
        case .following: return "Following"
        case .playlist(let playlist): return playlist.title
        }
    }

    var imageName: String? {
        switch self {
        case .discover: return "sparkles"
        case .stream: return "bolt.horizontal.fill"
        case .likes: return "heart.fill"
        case .history: return "clock.fill"
        case .following: return "person.2.fill"
        case .playlist: return nil
        }
    }

    private var sectionName: String? {
        switch self {
        case .discover: return "discover"
        case .stream: return "stream"
        case .likes: return "likes"
        case .history: return "history"
        case .following: return "following"
        case .playlist: return nil
        }
    }

}

extension SidebarItem: RawRepresentable {

    init?(rawValue: String) {
        if rawValue.hasPrefix(playlistPrefix) {
            let json = Data(rawValue.dropFirst(playlistPrefix.count).utf8)
            guard let playlist = try? JSONDecoder().decode(PlaylistReference.self, from: json) else { return nil }
            self = .playlist(playlist)
            return
        }

        // Saved by upstream Nuage: "<title>@@USERPLAYLIST@@<id>" and "<title>@@SYSTEMPLAYLIST@@<urn>"
        for (separator, isSystem) in [(userPlaylistSeparator, false), (systemPlaylistSeparator, true)] where rawValue.contains(separator) {
            let components = rawValue.components(separatedBy: separator)
            guard components.count == 2 else { return nil }

            let id = MediaID(provider: .soundCloud, rawID: components[1])
            self = .playlist(PlaylistReference(id: id, title: components[0], isSystem: isSystem))
            return
        }

        // "<section>" for SoundCloud, "<provider>/<section>" for the others
        let components = rawValue.split(separator: "/", maxSplits: 1).map(String.init)
        let provider: ProviderID
        let section: String
        if components.count == 2 {
            guard let id = ProviderID(rawValue: components[0]) else { return nil }
            provider = id
            section = components[1]
        }
        else {
            provider = .soundCloud
            section = rawValue
        }

        guard let item = SidebarItem.sections(of: provider).first(where: { $0.sectionName == section }) else { return nil }
        self = item
    }

    var rawValue: String {
        if case .playlist(let playlist) = self {
            let json = (try? JSONEncoder().encode(playlist)) ?? Data()
            return playlistPrefix + String(decoding: json, as: UTF8.self)
        }

        let section = sectionName ?? ""
        return (provider == .soundCloud) ? section : "\(provider.rawValue)/\(section)"
    }

}

extension SidebarItem: Hashable, Identifiable {

    /// Playlists are identified by id alone, so a reloaded or renamed playlist stays selected.
    var id: String {
        if case .playlist(let playlist) = self {
            return playlistPrefix + playlist.id.description
        }
        return rawValue
    }

    static func == (lhs: SidebarItem, rhs: SidebarItem) -> Bool {
        return lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

}

/// Enough of a playlist to list it in the sidebar and open it.
struct PlaylistReference: Codable {

    var id: MediaID
    var title: String
    var isSystem: Bool

}

extension PlaylistReference {

    init(_ playlist: MediaPlaylist) {
        self.init(id: playlist.id, title: playlist.title, isSystem: playlist.isSystem)
    }

}

/// Stations are a SoundCloud feature (`ProviderCapabilities.stations`).
enum Station: Hashable {
    case track(MediaTrack)
    case artist(User)
}
