//
//  TrackRow.swift
//  Nuage
//
//  Created by Laurin Brandner on 25.12.20.
//

import SwiftUI

struct TrackRow: View {
    
    var track: MediaTrack
    
    @Environment(\.onPlay) private var onPlay: () -> ()
    @Environment(\.showsProviderBadge) private var showsProviderBadge: Bool
    
    var body: some View {
        let duration = format(time: track.duration)
        
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading) {
                Artwork(url: track.artworkURL, onPlay: onPlay)
                    .frame(width: 100, height: 100)
                FeedbackStack(for: track)
            }
            .padding(.bottom, 8)
            
            VStack(alignment: .leading) {
                PlaybackNavigationLink(value: track) {
                    Text(track.title)
                        .font(.title3)
                        .bold()
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                NavigationLink(track.artist.name, value: track.artist)
                    .buttonStyle(.plain)
                
                if let stats = track.stats {
                    StatsStack(for: stats)
                        .foregroundColor(.secondary)
                }
                HStack(spacing: 6) {
                    if showsProviderBadge {
                        ProviderBadge(provider: track.provider)
                    }
                    Text(duration)
                }
                .foregroundColor(.secondary)
                
                Spacer()
                    .frame(height: 8)

                if let description = track.description {
                    let text = description
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "\n", with: " ")
                        .withAttributedLinks()
                        
                    Text(text)
                        .lineLimit(3)
                }
            }
        }
    }

}

/// The icon of the service a row comes from.
struct ProviderBadge: View {
    
    var provider: ProviderID
    
    var body: some View {
        Image(systemName: provider.iconName)
            .help(provider.displayName)
            .accessibilityLabel(provider.displayName)
    }
    
}

private struct ShowsProviderBadgeKey: EnvironmentKey {
    
    static let defaultValue = false
    
}

extension EnvironmentValues {
    
    /// Rows show their service's icon where sources mix (combined search).
    var showsProviderBadge: Bool {
        get { self[ShowsProviderBadgeKey.self] }
        set { self[ShowsProviderBadgeKey.self] = newValue }
    }
    
}
