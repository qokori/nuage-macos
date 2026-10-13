//
//  SearchList.swift
//  Nuage
//
//  Created by Laurin Brandner on 25.12.20.
//

import SwiftUI
import Combine

/// Searches every signed-in provider at once and groups the results by provider.
struct SearchList: View {
    
    var query: String
    
    @ObservedObject private var registry = ProviderRegistry.shared
    
    @State private var results = [ProviderID: SearchResults]()
    @State private var pending = Set<ProviderID>()
    @State private var subscriptions = Set<AnyCancellable>()
    
    private var hasResults: Bool {
        return results.values.contains { !$0.isEmpty }
    }
    
    var body: some View {
        Group {
            if hasResults {
                ScrollView {
                    LazyVStack(alignment: .leading) {
                        ForEach(ProviderID.allCases) { id in
                            if let results = results[id], !results.isEmpty {
                                section(for: id, results: results)
                            }
                        }
                    }
                    .padding()
                }
            }
            else if pending.isEmpty {
                Text("No results for “\(query)”")
                    .foregroundColor(.secondary)
            }
            else {
                ProgressView()
                    .progressViewStyle(.circular)
            }
        }
        .navigationTitle("Search")
        .onAppear(perform: search)
    }
    
    @ViewBuilder private func section(for id: ProviderID, results: SearchResults) -> some View {
        HStack {
            ProviderBadge(provider: id)
            Text(id.displayName)
        }
        .font(.largeTitle)
        
        if !results.artists.isEmpty {
            header("Artists")
            ScrollView(.horizontal) {
                HStack(alignment: .top) {
                    ForEach(results.artists) { artist in
                        NavigationLink(value: artist) {
                            UserItem(artist: artist)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        if !results.tracks.isEmpty {
            header("Tracks")
            VStack(alignment: .leading) {
                ForEach(results.tracks) { track in
                    TrackRow(track: track)
                        .playbackStart(at: track)
                        .trackContextMenu(with: track)
                }
            }
            .playbackContext(results.tracks)
        }
        if !results.playlists.isEmpty {
            header("Playlists")
            VStack(alignment: .leading) {
                ForEach(results.playlists) { playlist in
                    PlaylistRow(playlist: playlist)
                }
            }
        }
        footer()
    }
    
    @ViewBuilder private func header(_ title: String) -> some View {
        Text(title)
            .font(.title)
    }
    
    @ViewBuilder private func footer() -> some View {
        Spacer(minLength: 20)
        Divider()
        Spacer(minLength: 20)
    }
    
    private func search() {
        guard pending.isEmpty, results.isEmpty else { return }
        
        let providers = registry.signedInProviders.filter { $0.capabilities.contains(.search) }
        pending = Set(providers.map { $0.id })
        
        for provider in providers {
            let id = provider.id
            provider.search(query, limit: 20)
                .receive(on: RunLoop.main)
                .sink(receiveCompletion: { completion in
                    if case let .failure(error) = completion {
                        print("Failed to search \(id.displayName): \(error)")
                    }
                    pending.remove(id)
                }, receiveValue: { value in
                    results[id] = value
                })
                .store(in: &subscriptions)
        }
    }
    
}
