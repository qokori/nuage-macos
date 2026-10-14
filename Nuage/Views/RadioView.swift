//
//  RadioView.swift
//  Nuage
//
//  A provider's personal endless radio (Yandex Music's «Моя волна»): starts it,
//  lists what it queued and tells why it stopped.
//

import SwiftUI

struct RadioView: View {

    var provider: ProviderID

    @EnvironmentObject private var player: StreamPlayer

    /// This provider's radio fills the player's queue.
    private var isPlaying: Bool {
        return player.radio?.provider == provider
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header()
                .padding()
            Divider()
            if isPlaying {
                queue()
            }
            else {
                Spacer()
            }
        }
    }

    @ViewBuilder private func header() -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 40, height: 40)
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 6) {
                Text(provider.radioTitle)
                    .font(.title)
                    .bold()
                Text("Endless radio picked for you by \(provider.displayName). Skips, likes and dislikes tune what comes next.")
                    .foregroundColor(.secondary)

                HStack {
                    Button {
                        player.playRadio(of: provider)
                    } label: {
                        Label(isPlaying ? "Start Over" : "Play", systemImage: isPlaying ? "arrow.clockwise" : "play.fill")
                    }
                    if isPlaying {
                        Button {
                            player.reset()
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }
                    }
                    if isPlaying && player.isLoadingRadio {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .padding(.top, 4)

                // Also after the radio ended, until something else plays
                if let notice = player.radioNotice {
                    Text(notice)
                        .font(.callout)
                        .foregroundColor(.orange)
                }
            }
        }
    }

    @ViewBuilder private func queue() -> some View {
        ScrollViewReader { proxy in
            List {
                ForEach(Array(player.queue.enumerated()), id: \.offset) { idx, track in
                    row(for: track)
                        .id(idx)
                }
            }
            .onChange(of: player.currentStream) { track in
                if let idx = player.queue.firstIndex(where: { $0 == track }) {
                    withAnimation { proxy.scrollTo(idx, anchor: .center) }
                }
            }
        }
    }

    @ViewBuilder private func row(for track: MediaTrack) -> some View {
        let isCurrent = (track == player.currentStream)

        HStack(spacing: 10) {
            Artwork(url: track.artworkURL, onPlay: { player.jump(to: track) })
                .frame(width: 50, height: 50)
            VStack(alignment: .leading) {
                Text(track.title)
                    .bold()
                    .lineLimit(1)
                Text(track.artist.name)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if isCurrent {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundColor(.accentColor)
            }
            FeedbackStack(for: track)
            Text(format(time: track.duration))
                .font(.body.monospacedDigit())
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }

}
