//
//  TrackList.swift
//  Nuage
//
//  Created by Laurin Brandner on 23.12.19.
//  Copyright © 2019 Laurin Brandner. All rights reserved.
//

import SwiftUI
import Combine
import SoundCloud

/// A list of tracks from any source. SoundCloud lists page through the API
/// (`Track`, likes, history); other sources hand over `MediaTrack`s.
struct TrackList<Element: Decodable&Identifiable&Filterable&Hashable>: View {
    
    private var publisher: InfinitePublisher<Element>
    private var transform: (Element) -> MediaTrack
    
    @EnvironmentObject private var player: StreamPlayer
    
    var body: some View {
        InfiniteList(publisher: publisher) { elem in
            let track = transform(elem)
            TrackRow(track: track)
                .playbackStart(at: elem) { [transform($0)] }
                .trackContextMenu(with: track)
        }
    }
    
}

extension TrackList where Element == MediaTrack {
    
    init(for publisher: AnyPublisher<[MediaTrack], Error>) {
        self.init(publisher: .all(publisher)) { $0 }
    }
    
}

extension TrackList where Element == Track {
    
    init(for publisher: AnyPublisher<Page<Track>, Error>) {
        self.init(publisher: .page(publisher), transform: MediaTrack.init)
    }
    
    init(for arrayPublisher: AnyPublisher<[String], Error>,
         page pagePublisher: @escaping ([String]) -> AnyPublisher<[Track], Error>) {
        self.init(publisher: .array(arrayPublisher, pagePublisher), transform: MediaTrack.init)
    }
    
    init<P: Playlist>(request: APIRequest<P>) {
        let ids = SoundCloud.shared.get(request)
            .map { $0.trackIDs ?? [] }
            .eraseToAnyPublisher()
        let page = { ids in
            return SoundCloud.shared.get(.tracks(ids))
        }
        self.init(for: ids, page: page)
    }

}

extension TrackList where Element == Like<Track> {
    
    init(for publisher: AnyPublisher<Page<Like<Track>>, Error>) {
        self.init(publisher: .page(publisher)) { MediaTrack($0.item) }
    }
    
}

extension TrackList where Element == HistoryItem {
    
    init(for publisher: AnyPublisher<Page<HistoryItem>, Error>) {
        self.init(publisher: .page(publisher)) { MediaTrack($0.track) }
    }
    
}

/// The tracks of a playlist. SoundCloud pages through the playlist's track ids;
/// other providers load the whole playlist through `MusicProvider.tracks(in:)`.
struct PlaylistTrackList: View {
    
    private var reference: PlaylistReference
    private var playlist: MediaPlaylist?
    
    @EnvironmentObject private var library: Library
    
    var body: some View {
        if reference.id.provider == .soundCloud {
            if reference.isSystem {
                TrackList(request: .systemPlaylist(reference.id.rawID))
            }
            else {
                TrackList(request: .userPlaylist(reference.id.rawID))
            }
        }
        else if let playlist = playlist ?? library.playlists.first(where: { $0.id == reference.id }),
                let provider = ProviderRegistry.shared.provider(for: playlist.provider) {
            TrackList(for: provider.tracks(in: playlist))
        }
        else {
            Text("This playlist is not available.")
                .foregroundColor(.secondary)
        }
    }
    
    init(playlist: MediaPlaylist) {
        self.reference = PlaylistReference(playlist)
        self.playlist = playlist
    }
    
    init(reference: PlaylistReference) {
        self.reference = reference
    }
    
}

//struct TrackList_Previews: PreviewProvider {
//    static var previews: some View {
//        TrackList(publisher: previewTrackPublisher.collect().eraseToAnyPublisher())
//    }
//}
