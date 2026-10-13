//
//  TrackContextMenu.swift
//  Nuage
//
//  Created by Laurin Brandner on 04.12.20.
//  Copyright © 2020 Laurin Brandner. All rights reserved.
//

import SwiftUI

/// Play, queue, like, repost, add to playlist and copy link. Entries the
/// track's provider does not support are left out.
private struct TrackContextMenu: ViewModifier {
    
    var track: MediaTrack
    
    @EnvironmentObject private var player: StreamPlayer
    @EnvironmentObject private var library: Library
    @Environment(\.onPlay) private var onPlay: () -> ()
    
    func body(content: Content) -> some View {
        let capabilities = ProviderRegistry.shared.capabilities(of: track.provider)
        
        content.contextMenu {
            Button("Play", action: onPlay)
            Button("Add to Queue") {
                player.enqueue([track])
            }
            Divider()
            if capabilities.contains(.toggleLike) {
                Button(library.isLiked(track) ? "Unlike" : "Like") {
                    library.toggleLike(track)
                }
            }
            if capabilities.contains(.reposts) {
                Button(library.isReposted(track.id) ? "Remove Repost" : "Repost") {
                    library.toggleRepost(track)
                }
            }
            
            let playlists = library.editablePlaylists(of: track.provider)
            if !playlists.isEmpty {
                Menu("Add to Playlist") {
                    ForEach(playlists) { playlist in
                        Button(playlist.title) {
                            library.add(track, to: playlist)
                        }
                    }
                }
            }
            if let url = track.permalinkURL {
                Divider()
                Button("Copy Link") {
                    NSPasteboard.general.declareTypes([.string], owner: nil)
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
            }
        }
    }

}

extension View {
    
    func trackContextMenu(with track: MediaTrack) -> some View {
        return modifier(TrackContextMenu(track: track))
    }
    
}
