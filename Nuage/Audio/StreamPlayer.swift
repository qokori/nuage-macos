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
    /// Why the current track does not play, or plays only in part (a 30-second preview).
    @Published private(set) var playbackNotice: String?
    
    /// The radio that fills the queue while it plays (`play(_ radio:)`).
    @Published private(set) var radio: (any RadioSession)?
    /// Why the radio stopped or could not start.
    @Published private(set) var radioNotice: String?
    @Published private(set) var isLoadingRadio = false
    /// The tracks the radio queued: only they get radio feedback and the dislike button.
    private var radioTrackIDs = Set<MediaID>()
    private var radioLoad: AnyCancellable?
    /// Tells a batch from a radio load that was replaced or cancelled.
    private var radioLoadID = 0
    /// Play the first new track when the next batch comes: the radio just started, or its queue ran out.
    private var resumesWithNextBatch = false
    /// The radio track whose start was reported and whose end is still due.
    private var reportedRadioTrack: MediaTrack?
    
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
            playbackNotice = nil
            // The listener picked a track; a late batch must not jump past it
            resumesWithNextBatch = false
            guard let provider = providers.provider(for: track) else {
                print("Failed to stream track: no provider for \(track.provider.displayName)")
                return
            }
            
            provider.playbackSource(for: track)
                .receive(on: RunLoop.main)
                .sink(receiveCompletion: { [weak self] completion in
                    if case let .failure(error) = completion  {
                        print("Failed to stream track: \(error)")
                        guard let self = self, self.currentStream == track else { return }
                        self.playbackNotice = "Can't play: \(error.localizedDescription)"
                    }
                }, receiveValue: { [weak self] source in
                    guard let self = self, self.currentStream == track else { return }
                    self.playbackNotice = provider.accountNotice
                    self.start(source, for: track)
                    self.reportRadioStart(of: track)
                }).store(in: &subscriptions)
            
            prefetchRadioIfNeeded()
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
            
            NotificationCenter.default.addObserver(self, selector: #selector(currentTrackDidFinish), name: Notification.Name.AVPlayerItemDidPlayToEndTime, object: item)
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
            .sink { [weak self] in self?.currentTrackDidFinish() }
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
        
        endRadio()
        pause()
        queue = tracks
        
        // If we're in shuffle mode, we first have to unravel `idx`
        // Otherwise we start playing a random track
        let start = shuffleQueue ? queueOrder.firstIndex(of: idx) : idx
        resume(from: start)
    }
    
    /// The next track, at the listener's request: a skip for the radio.
    func advanceForward() {
        reportRadioTrackEnd(finished: false)
        moveForward()
    }
    
    /// The current track played to its end.
    @objc private func currentTrackDidFinish() {
        reportRadioTrackEnd(finished: true)
        moveForward()
    }
    
    private func moveForward() {
        guard let idx = currentStreamIndex else { return }
        player.replaceCurrentItem(with: nil)
        if queue.count > idx + 1 {
            resume(from: idx + 1)
        }
        else if radio != nil {
            // The next batch is late: it starts playing when it comes
            pause()
            resumesWithNextBatch = true
            loadRadioBatch()
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
            reportRadioTrackEnd(finished: false)
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
    
    /// Plays a track that is in the queue already, keeping the queue and the radio.
    func jump(to track: MediaTrack) {
        guard let position = queue.firstIndex(of: track),
              let idx = queueOrder.firstIndex(of: position) else { return }
        guard idx != currentStreamIndex else {
            restartPlayback()
            return
        }
        
        reportRadioTrackEnd(finished: false)
        player.replaceCurrentItem(with: nil)
        resume(from: idx)
    }
    
    func reset() {
        endRadio()
        pause()
        player.replaceCurrentItem(with: nil)
        detachRemote()
        queue = []
        currentStreamIndex = nil
    }
    
    func enqueue(_ streams: [MediaTrack], playNext: Bool = false) {
        guard streams.count > 0 else { return }
        
        if playNext, radio != nil, let idx = currentStreamIndex {
            // A radio plays in queue order, so "next" is right after the current track
            queue.insert(contentsOf: streams, at: idx + 1)
        }
        else if playNext {
            queue = streams + queue
        }
        else {
            queue = queue + streams
        }
    }
    
    private func reloadQueueOrder() {
        queueOrder = Array(0..<queue.count)
        // A radio's queue grows at the end and plays in order
        if shuffleQueue && radio == nil {
            queueOrder = queueOrder.shuffled()
        }
    }
    
    // MARK: - Radio
    
    /// Plays an endless radio: its first batch becomes the queue, and the next batch
    /// is fetched before the queue runs out. Playing anything else ends the radio.
    func play(_ radio: any RadioSession) {
        reset()
        self.radio = radio
        resumesWithNextBatch = true
        loadRadioBatch()
    }
    
    /// Starts a new session of the provider's radio; does nothing while the provider has none.
    func playRadio(of provider: ProviderID) {
        guard let radio = providers.provider(for: provider)?.radio() else { return }
        play(radio)
    }
    
    /// The current track came from the radio, so the radio can be told it is not wanted.
    var canDislikeCurrentTrack: Bool {
        guard let radio = radio, radio.isActive, let track = currentStream else { return false }
        return radioTrackIDs.contains(track.id)
    }
    
    /// Tells the radio the listener does not want the current track, and moves on.
    func dislikeCurrentTrack() {
        guard canDislikeCurrentTrack, let radio = radio, let track = currentStream else { return }
        
        // The dislike counts as the skip
        if reportedRadioTrack == track {
            reportedRadioTrack = nil
        }
        radio.dislike(track, playedSeconds: currentTime)
        moveForward()
    }
    
    private func endRadio() {
        reportRadioTrackEnd(finished: false)
        radio = nil
        radioNotice = nil
        isLoadingRadio = false
        radioLoad = nil
        radioLoadID += 1
        radioTrackIDs = []
        resumesWithNextBatch = false
    }
    
    /// Fetches the next batch once two tracks or fewer are left.
    private func prefetchRadioIfNeeded() {
        guard radio != nil, let idx = currentStreamIndex, queue.count - idx <= 2 else { return }
        loadRadioBatch()
    }
    
    private func loadRadioBatch() {
        guard let radio = radio, radioLoad == nil else { return }
        
        radioLoadID += 1
        let loadID = radioLoadID
        let last = queue.last { radioTrackIDs.contains($0.id) }
        isLoadingRadio = true
        
        radioLoad = radio.nextBatch(after: last)
            .receive(on: RunLoop.main)
            .sink(receiveCompletion: { [weak self] completion in
                guard let self = self, self.radioLoadID == loadID else { return }
                self.radioLoad = nil
                self.isLoadingRadio = false
                if case let .failure(error) = completion {
                    print("Failed to load \(radio.title): \(error)")
                    // Next or Start Over tries again
                    self.resumesWithNextBatch = false
                    if error is RadioEndedError {
                        // The queued tracks play on, without the radio
                        self.endRadio()
                    }
                    self.radioNotice = "\(radio.title) stopped: \(error.localizedDescription)"
                }
            }, receiveValue: { [weak self] tracks in
                guard let self = self, self.radioLoadID == loadID else { return }
                // Done before the tracks go in, so starting one can ask for the batch after
                self.radioLoad = nil
                self.radioLoadID += 1
                self.isLoadingRadio = false
                self.appendRadioTracks(tracks, from: radio)
            })
    }
    
    private func appendRadioTracks(_ tracks: [MediaTrack], from radio: any RadioSession) {
        var seen = Set(queue.map { $0.id })
        let fresh = tracks.filter { seen.insert($0.id).inserted }
        
        guard !fresh.isEmpty else {
            if resumesWithNextBatch {
                resumesWithNextBatch = false
                radioNotice = "\(radio.title) sent no new tracks. Try again later."
            }
            return
        }
        
        radioNotice = nil
        radioTrackIDs.formUnion(fresh.map { $0.id })
        let next = currentStreamIndex.map { $0 + 1 } ?? 0
        queue += fresh
        
        if resumesWithNextBatch {
            resumesWithNextBatch = false
            resume(from: next)
        }
    }
    
    private func reportRadioStart(of track: MediaTrack) {
        guard let radio = radio, radioTrackIDs.contains(track.id) else { return }
        
        if reportedRadioTrack != nil {
            reportRadioTrackEnd(finished: false)
        }
        radio.didStart(track)
        reportedRadioTrack = track
    }
    
    /// Tells the radio how its track ended, once per start.
    private func reportRadioTrackEnd(finished: Bool) {
        guard let radio = radio, let track = reportedRadioTrack else { return }
        reportedRadioTrack = nil
        
        let played = currentTime
        if finished {
            radio.didFinish(track, playedSeconds: played.isFinite ? played : track.duration)
        }
        else {
            radio.didSkip(track, playedSeconds: played)
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
