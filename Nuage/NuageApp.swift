//
//  NuageApp.swift
//  Nuage
//
//  Created by Laurin Brandner on 06.12.20.
//

import SwiftUI
import Combine
import SoundCloud

private let userKey = "user"
/// Library caches of upstream Nuage; the `Library` keeps its own now.
private let legacyLibraryKeys = ["playlists", "likes", "posts"]

private struct ShowCreatedPlaylistsKey: EnvironmentKey {
    
    static let defaultValue = true
    
}

private struct ShowLikedPlaylistsKey: EnvironmentKey {
    
    static let defaultValue = true
    
}

extension EnvironmentValues {
    
    var showCreatedPlaylists: Bool {
        get { self[ShowCreatedPlaylistsKey.self] }
        set { self[ShowCreatedPlaylistsKey.self] = newValue }
    }
    
    var showLikedPlaylists: Bool {
        get { self[ShowLikedPlaylistsKey.self] }
        set { self[ShowLikedPlaylistsKey.self] = newValue }
    }
    
}


class CommandSubject: ObservableObject {
    
    var filter = PassthroughSubject<(), Never>()
    var search = PassthroughSubject<(), Never>()
    
}

@main
struct NuageApp: App {
    
    @StateObject private var player = StreamPlayer()
    @StateObject private var registry = ProviderRegistry.shared
    @StateObject private var library = Library()
    private var commandSubjects = CommandSubject()
    
    @State private var showCreatedPlaylists = true
    @State private var showLikedPlaylists = true
    
    @State private var subscriptions = Set<AnyCancellable>()
    
    var body: some Scene {
        WindowGroup {
            if registry.isAnySignedIn {
                MainView()
                    .frame(minWidth: 600, minHeight: 400)
                    .environmentObject(player)
                    .environmentObject(library)
                    .environmentObject(commandSubjects)
                    .environment(\.showCreatedPlaylists, showCreatedPlaylists)
                    .environment(\.showLikedPlaylists, showLikedPlaylists)
                    .onAppear {
                        // Whenever the current stream changes, tell its provider
                        // (SoundCloud adds it to the play history)
                        player.$currentStream
                            .compactMap { $0 }
                            .sink { track in
                                ProviderRegistry.shared.provider(for: track)?.didStartPlayback(of: track)
                            }
                            .store(in: &subscriptions)
                    }
            }
            else {
                // Nothing to show without an account: SoundCloud's web login,
                // with a way to the other services in Settings → Accounts.
                LoginView { accessToken, expiryDate in
                    ProviderRegistry.shared.soundCloud.signIn(accessToken: accessToken, expiryDate: expiryDate)
                }
                .safeAreaInset(edge: .bottom) {
                    OtherAccountsLink()
                        .padding(8)
                }
            }
        }
        .defaultSize(width: 800, height: 400)
        .commands(content: commands)
        
        Window("Sign In to SoundCloud", id: soundCloudLoginWindowID) {
            SoundCloudLoginWindow()
        }
        
        Settings {
            TabView {
                AccountsView()
                    .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
            }
        }
    }
    
    @CommandsBuilder private func commands() -> some Commands {
        CommandGroup(after: .textEditing) {
            Button("Filter") {
                commandSubjects.filter.send()
            }.keyboardShortcut("f", modifiers: .command)
            Button("Search") {
                commandSubjects.search.send()
            }.keyboardShortcut("l", modifiers: .command)
        }
        CommandGroup(before: .toolbar) {
            Menu("Playlists") {
                Toggle("Show Created", isOn: $showCreatedPlaylists)
                Toggle("Show Liked", isOn: $showLikedPlaylists)
            }
        }
        playbackMenu()
    }
    
    @CommandsBuilder private func playbackMenu() -> some Commands {
        CommandMenu("Playback") {
            let playbackToggleTitle = player.isPlaying ? "Pause" : "Play"
            Button(playbackToggleTitle, action: player.togglePlayback)
            
            Divider()
            
            playbackControls()
            
            Divider()
            
            Toggle("Shuffle", isOn: $player.shuffleQueue)
                .keyboardShortcut("s", modifiers: [.command])

            Toggle("Repeat", isOn: $player.repeatQueue)
                .keyboardShortcut("r", modifiers: [.command])
            
            Divider()
            
            Button("Volume Up") {
                player.volume += 0.05
            }
            .keyboardShortcut(.upArrow, modifiers: [.command])

            Button("Volume Down") {
                player.volume -= 0.05
            }
            .keyboardShortcut(.downArrow, modifiers: [.command])
        }
    }
    
    @ViewBuilder private func playbackControls() -> some View {
        Button("Next", action: player.advanceForward)
            .keyboardShortcut(.rightArrow, modifiers: .command)
        
        Button("Previous", action: player.advanceBackward)
            .keyboardShortcut(.leftArrow, modifiers: .command)
        
        Button("Seek Forward", action: player.seekForward)
            .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
        
        Button("Seek Backward", action: player.seekBackward)
            .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
    }
    
    init() {
        let MB = 1024*1024
        URLCache.shared = URLCache(memoryCapacity: 10*MB, diskCapacity: 20*MB)
        URLSession.shared.configuration.requestCachePolicy = .returnCacheDataElseLoad
        
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: userKey) {
            do {
                SoundCloud.shared.user = try JSONDecoder().decode(User.self, from: data)
            }
            catch {
                defaults.removeObject(forKey: userKey)
                print("Failed to load user from UserDefaults: \(error)")
            }
        }
        ProviderRegistry.shared.restoreSessions()
        
        for key in legacyLibraryKeys {
            defaults.removeObject(forKey: key)
        }
        
        SoundCloud.shared.$user.sink { user in
            if let user = user {
                let data = try! JSONEncoder().encode(user)
                defaults.set(data, forKey: userKey)
            }
            else {
                defaults.set(nil, forKey: userKey)
            }
        }
        .store(in: &subscriptions)
    }
    
}
