# multi-source branch

Work in progress: one Nuage for SoundCloud, Spotify and Yandex Music.

**Status: stages 1–3 done, builds with Xcode 27.0.** Release build, ad-hoc
signed (`CODE_SIGN_IDENTITY=-`, no team). SoundCloud is still the only source, so the
remote-engine path (`.remote`) has no user yet.

## Stage 1

- `Nuage/Providers/MusicProvider.swift`: the `MusicProvider` protocol and the
  neutral `MediaTrack` / `MediaArtist` / `MediaPlaylist` models every source maps to.
- `Nuage/Providers/SoundCloudProvider.swift`: SoundCloud behind the protocol, a thin
  adapter over the existing `SoundCloud` package (same endpoints, same saved session).
- `Nuage/Providers/ProviderRegistry.swift`: the list of sources (SoundCloud only for now).
- Sign-in, session restore, stream resolution and play history go through the provider.

## Stage 2

- `StreamPlayer` queues `MediaTrack`s and asks the track's provider for a
  `PlaybackSource`: `.asset` plays in `AVPlayer`, `.remote` hands the track to
  another engine (`RemotePlaybackController`) and mirrors its progress and state.
- Now Playing, the player bar, the queue and the Touch Bar use only `MediaTrack` fields.
- The progress bar shows a waveform only when the track has a `waveformURL`.
- Removed the dead `StackNavigationView` package dependency and submodule entry.

Build: `xcodebuild -project Nuage.xcodeproj -scheme Nuage -configuration Release
-derivedDataPath build/DerivedData CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build`

## Stage 3

- Rows, track detail, the context menu and the like/repost buttons work on
  `MediaTrack` / `MediaPlaylist`. `Library` holds liked tracks, playlists and
  reposts of every signed-in source; rows toggle through it.
- Settings → Accounts: sign in and out per source. SoundCloud signs in through its
  web login in a separate window; Spotify and Yandex Music are listed as coming soon.
- The sidebar has a section per signed-in source; each entry shows only when the
  source supports it (Discover, Stream, History, Following are SoundCloud-only).
- The toolbar search queries every signed-in source and groups results by source.
- Waveform, comments, reposts and stations appear only for sources with those
  capabilities. The stage-2 `Track` ↔ `MediaTrack` bridge is gone; SoundCloud
  requests that need a full `Track` use a payload cache or fetch it by id.

## Next

4. Yandex Music provider (unofficial API, token in Keychain).
5. Spotify provider (Web API + controlling the Spotify app).

Nuage stays under GPL-3.0.
