//
//  ProviderRegistry.swift
//  Nuage
//
//  The music services the app knows about. SoundCloud is the only one so far;
//  Spotify and Yandex Music join here when their providers exist. The Accounts
//  window lists those as "coming soon".
//

import Foundation
import Combine

final class ProviderRegistry: ObservableObject {

    static let shared = ProviderRegistry()

    let soundCloud: SoundCloudProvider
    let providers: [any MusicProvider]

    /// Mirrors every provider's auth state, so views that observe the registry
    /// follow sign-ins and sign-outs.
    @Published private(set) var authStates = [ProviderID: AuthState]()

    private var subscriptions = Set<AnyCancellable>()

    init(soundCloud: SoundCloudProvider = SoundCloudProvider()) {
        self.soundCloud = soundCloud
        self.providers = [soundCloud]

        for provider in providers {
            let id = provider.id
            authStates[id] = provider.authState
            provider.authStatePublisher
                .dropFirst()
                .receive(on: RunLoop.main)
                .sink { [weak self] state in self?.authStates[id] = state }
                .store(in: &subscriptions)
        }
    }

    func provider(for id: ProviderID) -> (any MusicProvider)? {
        return providers.first { $0.id == id }
    }

    func provider(for track: MediaTrack) -> (any MusicProvider)? {
        return provider(for: track.provider)
    }

    func capabilities(of id: ProviderID) -> ProviderCapabilities {
        return provider(for: id)?.capabilities ?? []
    }

    var signedInProviders: [any MusicProvider] {
        return providers.filter { $0.isSignedIn }
    }

    /// Follows `authStates`, so views observing the registry update with it.
    var isAnySignedIn: Bool {
        return authStates.values.contains { $0.isSignedIn }
    }

    /// Restores every saved session at launch.
    func restoreSessions() {
        for provider in providers {
            provider.restoreSession()
            // Synchronously, so the first window already knows who is signed in.
            authStates[provider.id] = provider.authState
        }
    }

}
