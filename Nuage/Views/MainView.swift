//
//  MainView.swift
//  Nuage
//
//  Created by Laurin Brandner on 26.12.19.
//  Copyright © 2019 Laurin Brandner. All rights reserved.
//

import SwiftUI
import Combine
import SoundCloud

struct MainView: View {
    
    @ObservedObject private var soundCloud = SoundCloud.shared
    @ObservedObject private var registry = ProviderRegistry.shared
    
    @AppStorage("sidebarSelection") private var sidebarSelection: SidebarItem = .stream(.soundCloud)
    @State private var navigationPath = NavigationPath()
    @State private var blockingNavigationPath: NavigationPath?
    
    @State private var searchQuery = ""
    @State private var subscriptions = Set<AnyCancellable>()
    
    @EnvironmentObject private var player: StreamPlayer
    @EnvironmentObject private var library: Library
    
    @Environment(\.showLikedPlaylists) private var showLikedPlaylists: Bool
    @Environment(\.showCreatedPlaylists) private var showCreatedPlaylists: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView(sidebar: sidebar) {
                NavigationStack(path: $navigationPath) {
                    let presentSearch: Binding<Bool> = Binding(
                        get: { searchQuery.count > 0 },
                        set: { if !$0 { searchQuery = "" } }
                    )
                    
                    root(for: sidebarSelection)
                        .navigationDestinationWithPlaybackContext(for: MediaTrack.self) { TrackDetail(track: $0) }
                        .navigationDestination(for: MediaArtist.self) { ArtistDetail(artist: $0) }
                        .navigationDestination(for: User.self) { UserDetail(user: $0) }
                        .navigationDestination(for: URL.self) { URLDetail(url: $0) }
                        .navigationDestination(for: MediaPlaylist.self) { playlist in
                            PlaylistTrackList(playlist: playlist)
                                .navigationTitle(playlist.title)
                        }
                        .navigationDestination(for: Station.self) { station in
                            switch station {
                            case .track(let track):
                                let ids = registry.soundCloud.stationTrackIDs(basedOn: track)
                                TrackList(for: ids) { SoundCloud.shared.get(.tracks($0)) }
                            case .artist(let user):
                                TrackList(request: .artistStation(basedOn: user))
                            }
                        }
                        .navigationDestination(isPresented: presentSearch) {
                            SearchList(query: searchQuery)
                                .id(searchQuery)
                        }
                }
            }
            if player.queue.count > 0 {
                Divider()
                PlayerView {
                    if let track = player.currentStream, navigationPath != blockingNavigationPath {
                        navigationPath.append(track, with: player.queue, startPlaybackAt: track, player: player)
                        blockingNavigationPath = navigationPath
                    }
                }
            }
        }
        .toolbarRole(.editor)
        .toolbar(content: toolbar)
        .touchBar { TouchBar() }
        .onChange(of: sidebarSelection) { _ in
            navigationPath = NavigationPath()
            blockingNavigationPath = nil
        }
        .onOpenURL { url in
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return }
            
            components.scheme = "https"
            guard let newURL = components.url else { return }
            navigationPath.append(newURL)
        }
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
    }
    
    /// One section per signed-in provider: its library entries, then its playlists.
    @ViewBuilder private func sidebar() -> some View {
        List(selection: $sidebarSelection) {
            ForEach(registry.signedInProviders, id: \.id) { provider in
                Section(header: Text(provider.displayName)) {
                    ForEach(SidebarItem.sections(of: provider.id)) { item in
                        if provider.capabilities.contains(item.requiredCapability) {
                            sidebarMenu(for: item)
                        }
                    }
                    ForEach(sidebarPlaylists(of: provider.id)) { playlist in
                        sidebarMenu(for: .playlist(PlaylistReference(playlist)))
                    }
                }
            }
        }
    }
    
    private func sidebarPlaylists(of provider: ProviderID) -> [MediaPlaylist] {
        return library.playlists(of: provider).filter { playlist in
            playlist.isOwned ? showCreatedPlaylists : showLikedPlaylists
        }
    }
    
    @ViewBuilder private func sidebarMenu(for detail: SidebarItem) -> some View {
        NavigationLink(value: detail) {
            HStack {
                if let imageName = detail.imageName {
                    Image(systemName: imageName)
                        .frame(width: 20, alignment: .center)
                }
                Text(detail.title)
            }
        }
    }
    
    @ViewBuilder private func root(for item: SidebarItem) -> some View {
        Group {
            if let provider = registry.provider(for: item.provider), provider.isSignedIn,
               provider.capabilities.contains(item.requiredCapability) {
                switch item {
                case .playlist(let playlist):
                    PlaylistTrackList(reference: playlist)
                default:
                    if item.provider == .soundCloud {
                        soundCloudRoot(for: item)
                    }
                    else {
                        libraryRoot(for: item, of: provider)
                    }
                }
            }
            else {
                Text("Choose a section in the sidebar.")
                    .foregroundColor(.secondary)
            }
        }
            .navigationTitle(item.title)
            .id(item.id) // Set id so that SwiftUI knows when to render new view
    }
    
    /// SoundCloud pages its sections through its own API.
    @ViewBuilder private func soundCloudRoot(for item: SidebarItem) -> some View {
        switch item {
        case .discover:
            DiscoverView()
        case .stream:
            let stream = SoundCloud.shared.get(.stream(), count: 50)
            PostList(for: stream)
        case .likes:
            let likes = SoundCloud.shared.$user.filter { $0 != nil}
                .flatMap { SoundCloud.shared.get(.trackLikes(of: $0!), count: 50) }
                .eraseToAnyPublisher()
            TrackList(for: likes)
        case .history:
            let history = SoundCloud.shared.get(.history(), count: 50)
            TrackList(for: history)
        case .following:
            let following = SoundCloud.shared.$user.filter { $0 != nil }
                .flatMap { SoundCloud.shared.get(.followings(of: $0!), count: 50) }
                .eraseToAnyPublisher()
            UserGrid(for: following)
        case .playlist:
            EmptyView()
        }
    }
    
    /// Other providers only have what the shared protocol offers.
    @ViewBuilder private func libraryRoot(for item: SidebarItem, of provider: any MusicProvider) -> some View {
        switch item {
        case .likes:
            TrackList(for: provider.likedTracks())
        default:
            EmptyView()
        }
    }
    
    @ToolbarContentBuilder private func toolbar() -> some ToolbarContent {
        ToolbarItem(placement: .principal) {
            TextField("Search", text: $searchQuery)
                .textFieldStyle(.roundedBorder)
                .frame(width: 250)
        }
        ToolbarItemGroup {
            Spacer()
            if registry.soundCloud.isSignedIn {
                Button {
                    if let user = soundCloud.user {
                        navigationPath.append(user)
                    }
                } label: {
                    RemoteImage(url: SoundCloud.shared.user?.avatarURL, cornerRadius: 15)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
            }
        }
    }
    
}

struct MainView_Previews: PreviewProvider {
    
    static var previews: some View {
        let player: StreamPlayer = {
            let player = StreamPlayer()
            player.enqueue(Preview.tracks.map(MediaTrack.init))
            return player
        }()
        
        MainView()
            .environmentObject(player)
            .environmentObject(Library())
    }
    
}
