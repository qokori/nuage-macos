//
//  ProviderRegistry.swift
//  Nuage
//
//  The music services the app knows about. Stage 1 registers SoundCloud only;
//  Spotify and Yandex Music join here when their providers exist.
//

import Foundation
import Combine

final class ProviderRegistry: ObservableObject {

    static let shared = ProviderRegistry()

    let soundCloud: SoundCloudProvider
    @Published private(set) var providers: [any MusicProvider]

    init(soundCloud: SoundCloudProvider = SoundCloudProvider()) {
        self.soundCloud = soundCloud
        self.providers = [soundCloud]
    }

    func provider(for id: ProviderID) -> (any MusicProvider)? {
        return providers.first { $0.id == id }
    }

    func provider(for track: MediaTrack) -> (any MusicProvider)? {
        return provider(for: track.provider)
    }

    var signedInProviders: [any MusicProvider] {
        return providers.filter { $0.isSignedIn }
    }

}
