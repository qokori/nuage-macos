//
//  PlaylistRow.swift
//  Nuage
//
//  Created by Laurin Brandner on 25.12.20.
//

import SwiftUI

struct PlaylistRow: View {
    
    var playlist: MediaPlaylist
    @Environment(\.onPlay) private var onPlay: () -> ()
    @Environment(\.showsProviderBadge) private var showsProviderBadge: Bool
    
    var body: some View {
        let artworkURL = playlist.artworkURL ?? playlist.previewTracks?.first?.artworkURL
        
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading) {
                Artwork(url: artworkURL, onPlay: onPlay)
                    .frame(width: 100, height: 100)
                FeedbackStack(for: playlist)
            }
            .padding(.bottom, 16)
            
            VStack(alignment: .leading) {
                NavigationLink(value: playlist) {
                    Text(playlist.title)
                        .font(.title3)
                        .bold()
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                HStack(spacing: 6) {
                    if showsProviderBadge {
                        ProviderBadge(provider: playlist.provider)
                            .foregroundColor(.secondary)
                    }
                    if let owner = playlist.owner {
                        NavigationLink(owner.name, value: owner)
                            .buttonStyle(.plain)
                    }
                }
                Spacer()
                    .frame(height: 8)

                if let description = playlist.description {
                    let text = description
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "\n", with: " ")
                        .withAttributedLinks()
                    
                    Text(text).lineLimit(3)
                }
                
                if let tracks = playlist.previewTracks {
                    ForEach(tracks) { track in
                        Divider()
                        HStack {
                            Text(track.title)
                            if let stats = track.stats {
                                StatsStack(for: stats)
                            }
                        }
                    }
                    .foregroundColor(.secondary)
                }
                
                Spacer()
                    .frame(height: 8)
            }
        }
    }

}
