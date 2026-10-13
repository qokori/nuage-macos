# multi-source branch

Work in progress: one Nuage for SoundCloud, Spotify and Yandex Music.

**Status: stage 1, not built.** The app was type-checked with Command Line Tools (`Tools/typecheck.sh`:
`swiftc -typecheck`, macOS 26.5 SDK, dependencies built with SwiftPM) with no
errors, but it has not been linked, built in Xcode or run.

## Stage 1 (this branch)

- `Nuage/Providers/MusicProvider.swift`: the `MusicProvider` protocol and the
  neutral `MediaTrack` / `MediaArtist` / `MediaPlaylist` models every source maps to.
- `Nuage/Providers/SoundCloudProvider.swift`: SoundCloud behind the protocol, a thin
  adapter over the existing `SoundCloud` package (same endpoints, same saved session).
- `Nuage/Providers/ProviderRegistry.swift`: the list of sources (SoundCloud only for now).
- Sign-in, session restore, stream resolution and play history go through the provider.

## Next

2. Player queue on `MediaTrack`, playback engine chosen per track.
3. Source-aware sidebar, combined search, accounts window.
4. Yandex Music provider (unofficial API, token in Keychain).
5. Spotify provider (Web API + controlling the Spotify app).

Nuage stays under GPL-3.0.
