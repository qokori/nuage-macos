//
//  StreamPlayer.swift
//  Nuage
//
//  Created by Laurin Brandner on 25.12.19.
//  Copyright © 2019 Laurin Brandner. All rights reserved.
//

import AppKit
import SwiftUI
import AVFoundation
import Combine
import MediaPlayer
import URLImage

private let volumeKey = "volume"
    
class StreamPlayer: ObservableObject {
    
    private var subscriptions = Set<AnyCancellable>()
    
    private let providers: ProviderRegistry
    private(set) var player: AVPlayer
    /// Set while another engine (e.g. the Spotify app) plays the current track;
    /// `nil` while `player` plays it.
    private var remote: (any RemotePlaybackController)?
    private var remoteSubscriptions = Set<AnyCancellable>()
    private(set) var queue = [MediaTrack]() {
        didSet {
            reloadQueueOrder()
        }
    }
    private var queueOrder = [Int]()
    private(set) var currentStreamIndex: Int? {
        didSet {
            currentStream = self.currentStreamIndex.map { queue[queueOrder[$0]] }
        }
    }
    
    @Published private(set) var currentStream: MediaTrack?
    
    @AppStorage("shuffleQueue") var shuffleQueue: Bool = false {
        didSet {
            // Here we have to unravel the index again
            // So that we end up in the same spot of the queue
            // This should not trigger $currentStream, since it's the same track
            let index = currentStreamIndex.map { queueOrder[$0] }
            
            reloadQueueOrder()
            
            if let index = index {
                currentStreamIndex = queueOrder.firstIndex(of: index)
            }
        }
    }
    @AppStorage("repeatQueue") var repeatQueue: Bool = false
    
    @Published var volume: Float = 0.5 {
        didSet {
            if volume > 1 { volume = 1 }
            else if volume < 0 { volume = 0 }
            
            player.volume = volume
            remote?.setVolume(volume)
            UserDefaults.standard.set(volume, forKey: volumeKey)
        }
    }
    
    private var shouldSeek = true
    @Published var progress: TimeInterval = 0.0 {
        didSet {
            if shouldSeek {
                let time = CMTime(seconds: progress, preferredTimescale: 1)
                if let remote = remote {
                    remote.seek(to: time.seconds)
                }
                else {
                    player.seek(to: time)
                }
                updateNowPlayingInfo(elapsed: time.seconds)
            }
        }
    }
    
    @Published private(set) var isPlaying = false
    
    /// Seconds into the current track, from whichever engine plays it.
    private var currentTime: TimeInterval {
        return (remote == nil) ? player.currentTime().seconds : progress
    }
    
    // MARK: - Initialization
    
    init(providers: ProviderRegistry = .shared) {
        self.providers = providers
        self.player = AVPlayer()
        self.player.allowsExternalPlayback = false
        
        let defaults = UserDefaults.standard
        if defaults.object(forKey: volumeKey) != nil {
            self.volume = defaults.float(forKey: volumeKey)
        }
        
        let interval = CMTime(value: 1, timescale: 1)
        player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            self.shouldSeek = false
            self.progress = time.seconds
            self.shouldSeek = true
        }
        
        // While a remote engine plays, `player` sits paused; its state must not win.
        player.publisher(for: \.timeControlStatus)
            .filter { [weak self] _ in self?.remote == nil }
            .map { $0 != .paused }
            .assign(to: \.isPlaying, on: self)
            .store(in: &subscriptions)
        
        player.publisher(for: \.timeControlStatus)
            .sink { _ in self.updateNowPlayingInfo() }
            .store(in: &subscriptions)
        
        addRemoteCommandTargets()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Playback
    
    func restartPlayback() {
        if let remote = remote {
            remote.seek(to: 0)
            remote.resume()
        }
        else {
            player.seek(to: .zero)
            player.play()
        }
    }
    
    func togglePlayback() {
        if isPlaying {
            pause()
        }
        else {
            resume()
        }
    }
    
    func resume(from startIndex: Int? = nil) {
        guard let idx = startIndex ?? currentStreamIndex, idx < queue.count else { return }
        
        let newStream = queue[queueOrder[idx]]
        if currentStream == newStream {
            if let remote = remote {
                remote.resume()
            }
            else {
                player.play()
            }
        }
        else {
            self.currentStreamIndex = idx
            self.shouldSeek = false
            self.progress = 0
            self.shouldSeek = true
            
            let track = currentStream!
            guard let provider = providers.provider(for: track) else {
                print("Failed to stream track: no provider for \(track.provider.displayName)")
                return
            }
            
            provider.playbackSource(for: track)
                .receive(on: RunLoop.main)
                .sink(receiveCompletion: { completion in
                    if case let .failure(error) = completion  {
                        print("Failed to stream track: \(error)")
                    }
                }, receiveValue: { [weak self] source in
                    guard let self = self, self.currentStream == track else { return }
                    self.start(source, for: track)
                }).store(in: &subscriptions)
        }
    }
    
    /// Hands the track to the engine its provider chose.
    private func start(_ source: PlaybackSource, for track: MediaTrack) {
        switch source {
        case .asset(let asset):
            detachRemote()
            
            let item = AVPlayerItem(asset: asset)
            
            player.replaceCurrentItem(with: item)
            player.play()
            
            NotificationCenter.default.addObserver(self, selector: #selector(advanceForward), name: Notification.Name.AVPlayerItemDidPlayToEndTime, object: item)
        case .remote(let controller):
            player.replaceCurrentItem(with: nil)
            attach(controller)
            controller.setVolume(volume)
            controller.play(track)
        }
        
        updateNowPlayingInfo()
    }
    
    private func attach(_ controller: any RemotePlaybackController) {
        guard remote !== controller else { return }
        detachRemote()
        remote = controller
        
        controller.progressPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] seconds in
                guard let self = self else { return }
                self.shouldSeek = false
                self.progress = seconds
                self.shouldSeek = true
            }
            .store(in: &remoteSubscriptions)
        
        controller.isPlayingPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] isPlaying in
                self?.isPlaying = isPlaying
                self?.updateNowPlayingInfo()
            }
            .store(in: &remoteSubscriptions)
        
        controller.didFinishPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.advanceForward() }
            .store(in: &remoteSubscriptions)
    }
    
    private func detachRemote() {
        guard let remote = remote else { return }
        remoteSubscriptions.removeAll()
        self.remote = nil
        remote.pause()
    }
    
    func pause() {
        if let remote = remote {
            remote.pause()
        }
        else {
            player.pause()
        }
    }
    
    func play(_ tracks: [MediaTrack], from idx: Int) {
        guard !(currentStreamIndex == idx && queue == tracks) else {
            restartPlayback()
            return
        }
        
        pause()
        queue = tracks
        
        // If we're in shuffle mode, we first have to unravel `idx`
        // Otherwise we start playing a random track
        let start = shuffleQueue ? queueOrder.firstIndex(of: idx) : idx
        resume(from: start)
    }
    
    @objc func advanceForward() {
        guard let idx = currentStreamIndex else { return }
        player.replaceCurrentItem(with: nil)
        if queue.count > idx + 1 {
            resume(from: idx + 1)
        }
        else if repeatQueue {
            resume(from: 0)
        }
        else {
            queue = []
            pause()
        }
    }
    
    func advanceBackward() {
        guard let idx = currentStreamIndex else { return }
        
        if currentTime < 15 {
            player.replaceCurrentItem(with: nil)
            if idx > 0 {
                resume(from: idx - 1)
            }
            else {
                currentStreamIndex = nil
            }
        }
        else {
            restartPlayback()
        }
    }
    
    func seekForward() {
        progress += 15
    }
    
    func seekBackward() {
        progress -= 15
    }
    
    func reset() {
        pause()
        player.replaceCurrentItem(with: nil)
        detachRemote()
        queue = []
        currentStreamIndex = nil
    }
    
    func enqueue(_ streams: [MediaTrack], playNext: Bool = false) {
        guard streams.count > 0 else { return }
        
        if playNext {
            queue = streams + queue
        }
        else {
            queue = queue + streams
        }
    }
    
    private func reloadQueueOrder() {
        queueOrder = Array(0..<queue.count)
        if shuffleQueue {
            queueOrder = queueOrder.shuffled()
        }
    }
    
    // MARK: - MPNowPlayingInfoCenter
    
    private func addRemoteCommandTargets() {
        let center = MPRemoteCommandCenter.shared()
        center.togglePlayPauseCommand.addTarget { _ in
            self.togglePlayback()
            return .success
        }
        
        center.playCommand.addTarget { _ in
            self.resume()
            return .success
        }
        
        center.pauseCommand.addTarget { _ in
            self.pause()
            return .success
        }
        
        center.nextTrackCommand.addTarget { _ in
            self.advanceForward()
            return .success
        }
        
        center.previousTrackCommand.addTarget { _ in
            self.advanceBackward()
            return .success
        }
        
        center.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            self.progress = event.positionTime
            return .success
        }
    }
    
    private func updateNowPlayingInfo(elapsed: TimeInterval? = nil) {
        let center = MPNowPlayingInfoCenter.default()
        guard let currentStream = currentStream else {
            center.nowPlayingInfo = nil
            return
        }
        
        var info = center.nowPlayingInfo
        let currentID = info?[MPMediaItemPropertyPersistentID] as? String
        let streamID = currentStream.id.description
        let currentTime = elapsed ?? self.currentTime
        
        if currentID == streamID {
            info![MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        }
        else {
            info = [
                MPMediaItemPropertyPersistentID: streamID,
                MPMediaItemPropertyTitle: currentStream.title,
                MPMediaItemPropertyArtist: currentStream.artist.name,
                MPMediaItemPropertyPlaybackDuration: currentStream.duration,
                MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime
            ]
            if let url = currentStream.permalinkURL {
                info![MPMediaItemPropertyAssetURL] = url
            }
            
            if let url = currentStream.artworkURL {
                URLImageService.shared.remoteImagePublisher(url)
                    .sink(receiveCompletion: { _ in },
                          receiveValue: { imageInfo in
                        let image = NSImage(cgImage: imageInfo.cgImage, size: imageInfo.size)
                        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                        info![MPMediaItemPropertyArtwork] = artwork
                        
                        center.nowPlayingInfo = info
                    })
                    .store(in: &self.subscriptions)
            }
        }
        
        center.nowPlayingInfo = info
        
        if remote != nil {
            center.playbackState = isPlaying ? .playing : .paused
            return
        }
        
        switch player.timeControlStatus {
        case .paused: center.playbackState = .paused
        case .playing: center.playbackState = .playing
        case .waitingToPlayAtSpecifiedRate: center.playbackState = .interrupted
        default: center.playbackState = .unknown
        }
    }
    
}
