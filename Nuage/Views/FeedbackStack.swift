//
//  FeedbackStack.swift
//  Nuage
//
//  Created by Laurin Brandner on 24.07.23.
//

import SwiftUI

/// Like and repost buttons for a track or a playlist. Each button appears only
/// when the item's provider supports it.
struct FeedbackStack: View {
    
    private enum Item {
        case track(MediaTrack)
        case playlist(MediaPlaylist)
    }
    
    private var item: Item?
    private var provider: ProviderID?
    private var horizontal: Bool
    
    @EnvironmentObject private var library: Library
    
    private var capabilities: ProviderCapabilities {
        return provider.map(ProviderRegistry.shared.capabilities(of:)) ?? []
    }
    
    private var isLiked: Bool {
        switch item {
        case .track(let track): return library.isLiked(track)
        case .playlist(let playlist): return library.isLiked(playlist)
        case nil: return false
        }
    }
    
    /// `nil` when the item cannot be reposted.
    private var isRepost: Bool? {
        guard capabilities.contains(.reposts) else { return nil }
        
        switch item {
        case .track(let track): return library.isReposted(track.id)
        case .playlist(let playlist): return playlist.isSystem ? nil : library.isReposted(playlist.id)
        case nil: return false
        }
    }
    
    var body: some View {
        if horizontal {
            HStack(content: content)
        }
        else {
            VStack(content: content)
        }
    }
    
    @ViewBuilder private func content() -> some View {
        if provider == nil || capabilities.contains(.toggleLike) {
            Button(action: toggleLike) {
                let name = isLiked ? "heart.fill" : "heart"
                Image(systemName: name)
            }
            .disabled(item == nil)
            .buttonStyle(.borderless)
        }

        if let isRepost = isRepost {
            Button(action: toggleRepost) {
                let name = isRepost ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.triangle.2.circlepath.circle"
                Image(systemName: name)
            }
            .disabled(item == nil)
            .buttonStyle(.borderless)
        }
    }
    
    private func toggleLike() {
        switch item {
        case .track(let track): library.toggleLike(track)
        case .playlist(let playlist): library.toggleLike(playlist)
        case nil: break
        }
    }
    
    private func toggleRepost() {
        switch item {
        case .track(let track): library.toggleRepost(track)
        case .playlist(let playlist): library.toggleRepost(playlist)
        case nil: break
        }
    }
    
    init(for playlist: MediaPlaylist, horizontal: Bool = true) {
        self.item = .playlist(playlist)
        self.provider = playlist.provider
        self.horizontal = horizontal
    }
    
    init(for track: MediaTrack?, horizontal: Bool = true) {
        self.item = track.map { .track($0) }
        self.provider = track?.provider
        self.horizontal = horizontal
    }
    
}
