# multi-source branch

Work in progress: one Nuage for SoundCloud, Spotify and Yandex Music.

**Status: stages 1–4 done, builds with Xcode 27.0.** Release build, ad-hoc
signed (`CODE_SIGN_IDENTITY=-`, no team). Sources: SoundCloud and Yandex Music; both
play through `AVPlayer`, so the remote-engine path (`.remote`) has no user yet.

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

## Stage 4

- `YandexMusic/`: a local Swift package, the client for the unofficial
  `api.music.yandex.net` (account status, liked tracks, playlists, search, likes,
  `download-info` → signed MP3/AAC URL). Endpoints and the URL signing follow
  MarshalX/yandex-music-api (LGPL-3.0) as a reference; no code is copied from it or
  from p0rterB/YM-API (also LGPL-3.0).
- `Nuage/Providers/YandexMusicProvider.swift`: Yandex Music behind `MusicProvider`
  with search, likes, like/unlike and playlists (created and liked). No lossless:
  FLAC is encrypted and needs another endpoint.
- Settings → Accounts → Yandex Music → Sign In: paste an OAuth token. Nuage checks it
  with `/account/status` and saves it only if Yandex accepts it, in the login Keychain
  (`Nuage/Providers/Keychain.swift`), never in UserDefaults or logs. The client uses an
  ephemeral URL session (no disk cache) and sends the token only to `api.music.yandex.net`.
- A rejected token turns the session into "expired" with a note in Accounts. Without
  Yandex Plus the service sends 30-second previews; Accounts and the player say so.
  The player bar shows why a track does not play.
- The first-launch login screen links to Settings → Accounts for Yandex-only users.
- Tests: `swift test --package-path YandexMusic` (32 tests: request building, response
  parsing, URL signing, errors). Requests go to a `URLProtocol` mock with hand-written
  fixtures; nothing reaches Yandex.

## «Моя волна» (Yandex Music radio)

- `YandexMusic/Sources/YandexMusic/Rotor.swift`: the rotor API.
  `GET /rotor/station/user:onyourwave/tracks?settings2=true[&queue=<last track id>:<its album id>]`
  returns a batch with a `batchId`; `POST /rotor/station/user:onyourwave/feedback?batch-id=…`
  takes JSON `radioStarted` / `trackStarted` / `trackFinished` / `skip` (with
  `totalPlayedSeconds`); `POST /users/{uid}/dislikes/tracks/add-multiple` dislikes a track.
  MarshalX/yandex-music-api is the reference; no code is copied.
- `RadioSession` (in `MusicProvider.swift`) is the provider-neutral seam; Yandex's
  `YandexWave` belongs to the sign-in session that started it and goes quiet after a
  sign-out or an account switch; the player then ends the radio at the next batch
  and hides the dislike button.
- Sidebar → Яндекс Музыка → «Моя волна» (only while signed in). Choosing it starts the
  radio; the screen lists the queued tracks and has Play / Start Over / Stop.
  `StreamPlayer` asks for the next batch when two tracks or fewer are left, and
  waits for it if the queue runs out. Next / media keys count as a skip, playing to the
  end as `trackFinished`. Playing anything else ends the radio. Shuffle is ignored
  while the radio plays.
- Player bar: the heart likes a wave track as usual; the thumbs-down (radio tracks only)
  sends a skip, adds the track to the account's dislikes and moves on.
- Tests: 12 more in `RotorTests.swift` (request building, JSON bodies, parsing,
  errors), 44 in total, on the same `URLProtocol` mock with hand-written fixtures.

## Next

5. Spotify provider (Web API + controlling the Spotify app).

Nuage stays under GPL-3.0.
