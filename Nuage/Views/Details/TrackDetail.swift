//
//  TrackDetail.swift
//  Nuage
//
//  Created by Laurin Brandner on 18.11.20.
//  Copyright © 2020 Laurin Brandner. All rights reserved.
//

import SwiftUI
import Combine
import SoundCloud

/// A track from any provider. The waveform, comments and the station button
/// appear only when the track's provider has them.
struct TrackDetail: View {
    
    var track: MediaTrack
    
    @State private var subscriptions = Set<AnyCancellable>()
    
    @Environment(\.onPlay) private var onPlay: () -> ()
    
    private var capabilities: ProviderCapabilities {
        return ProviderRegistry.shared.capabilities(of: track.provider)
    }
    
    var body: some View {
        let duration = format(time: track.duration)
        
        VStack(alignment: .leading) {
            Text(track.title)
                .font(.title)
                .lineLimit(2)
            
            Spacer()
                .frame(height: 2)
            
            HStack {
                NavigationLink(value: track.artist) {
                    Text(track.artist.name)
                        .foregroundColor(.secondary)
                        .font(.title2)
                }
                .buttonStyle(.plain)
                
                Spacer()
                    .frame(width: 16)
                
                if let stats = track.stats {
                    StatsStack(for: stats)
                        .foregroundColor(.secondary)
                }
            }
            
            HStack(alignment: .center, spacing: 10) {
                Artwork(url: track.artworkURL, onPlay: onPlay)
                    .frame(width: 100, height: 100)
                
                if capabilities.contains(.waveform), let waveformURL = track.waveformURL {
                    WaveformView(url: waveformURL)
                        .foregroundColor(.secondary)
                        .frame(height: 80)
                }
            }
            
            FeedbackStack(for: track)
            
            Text(duration)
                .foregroundColor(Color(NSColor.secondaryLabelColor))
            Spacer()
                .frame(height: 8)
            
            Divider()
            
            if capabilities.contains(.comments) {
                CommentList(for: ProviderRegistry.shared.soundCloud.comments(of: track))
                    .header { description() }
            }
            else {
                ScrollView {
                    description()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .toolbar {
            if capabilities.contains(.stations) {
                ToolbarItem(placement: .secondaryAction) {
                    NavigationLink(value: Station.track(track)) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                    }
                }
            }
        }
        .padding(16)
        .navigationTitle(track.title)
    }
    
    @ViewBuilder private func description() -> some View {
        if let description = track.description {
            Text(description.withAttributedLinks())
        }
    }
    
}

struct TrackDetail_Previews: PreviewProvider {
    
    static var previews: some View {
        let player: StreamPlayer = {
            let player = StreamPlayer()
            player.enqueue(Preview.tracks.map(MediaTrack.init))
            
            return player
        }()
        
        TrackDetail(track: MediaTrack(Preview.tracks.first!))
            .environmentObject(player)
            .environmentObject(CommandSubject())
    }
    
}
