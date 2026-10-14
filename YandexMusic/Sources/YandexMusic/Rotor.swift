//
//  Rotor.swift
//  YandexMusic
//
//  Radio stations (the "rotor" API), «Моя волна» among them. A station hands
//  out tracks in batches; the client reports what the listener does with each
//  track, and the next batch follows from that. Endpoints follow
//  MarshalX/yandex-music-api (LGPL-3.0) as a reference; no code is copied.
//

import Foundation
import Combine

/// A batch of tracks from `/rotor/station/{station}/tracks`.
public struct StationTracks: Decodable {

    public struct StationID: Decodable, Equatable {
        public var type: String
        public var tag: String
    }

    public struct Item: Decodable {
        /// "track" for every entry seen so far.
        public var type: String?
        public var track: Track?
        public var liked: Bool?
    }

    public var id: StationID?
    public var sequence: [Item]
    /// Goes back with the feedback on this batch's tracks.
    public var batchId: String
    public var pumpkin: Bool?

    public var tracks: [Track] {
        return sequence.compactMap { $0.track }
    }

}

/// What the listener did, for `/rotor/station/{station}/feedback`.
public struct StationFeedback: Equatable {

    public enum Kind: String {
        case radioStarted
        case trackStarted
        case trackFinished
        case skip
    }

    public var kind: Kind
    public var trackID: String?
    /// How long the track played; `trackFinished` and `skip` carry it.
    public var totalPlayedSeconds: TimeInterval?
    /// Where the radio was started from; only `radioStarted` carries it.
    public var from: String?
    public var timestamp: Date

    public static func radioStarted(from: String, at date: Date = Date()) -> StationFeedback {
        return StationFeedback(kind: .radioStarted, from: from, timestamp: date)
    }

    public static func trackStarted(_ trackID: String, at date: Date = Date()) -> StationFeedback {
        return StationFeedback(kind: .trackStarted, trackID: trackID, timestamp: date)
    }

    public static func trackFinished(_ trackID: String, playedSeconds: TimeInterval, at date: Date = Date()) -> StationFeedback {
        return StationFeedback(kind: .trackFinished, trackID: trackID, totalPlayedSeconds: playedSeconds, timestamp: date)
    }

    public static func skip(_ trackID: String, playedSeconds: TimeInterval, at date: Date = Date()) -> StationFeedback {
        return StationFeedback(kind: .skip, trackID: trackID, totalPlayedSeconds: playedSeconds, timestamp: date)
    }

    /// `{"type", "timestamp", "trackId"?, "from"?, "totalPlayedSeconds"?}`, keys sorted.
    /// The timestamp is ISO 8601 in UTC; played seconds are rounded to tenths and never
    /// negative or NaN (which JSON cannot carry).
    public var jsonBody: Data {
        let played = totalPlayedSeconds.map { seconds -> Double in
            guard seconds.isFinite, seconds > 0 else { return 0 }
            return (seconds * 10).rounded() / 10
        }
        let body = Body(type: kind.rawValue,
                        timestamp: Self.timestampFormatter.string(from: timestamp),
                        trackId: trackID,
                        from: from,
                        totalPlayedSeconds: played)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Only strings and finite numbers: encoding cannot fail
        return (try? encoder.encode(body)) ?? Data()
    }

    private struct Body: Encodable {
        var type: String
        var timestamp: String
        var trackId: String?
        var from: String?
        var totalPlayedSeconds: Double?
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

}

extension Track {

    /// `<id>:<album id>`, or the bare id for a track without an album: how a station
    /// is told which track to continue after.
    public var stationQueueID: String {
        guard let album = albums?.first else { return id.value }
        return "\(id.value):\(album.id.value)"
    }

}

extension Endpoint {

    /// The next batch of a station. `queue` names the last track queued so far
    /// (`Track.stationQueueID`), so the station continues after it; `nil` asks for
    /// the first batch.
    public static func stationTracks(_ station: String, queue: String? = nil) -> Endpoint {
        var query = [URLQueryItem(name: "settings2", value: "true")]
        if let queue = queue, !queue.isEmpty {
            query.append(URLQueryItem(name: "queue", value: queue))
        }
        return Endpoint(method: .get, path: "rotor/station/\(station)/tracks", query: query)
    }

    /// The feedback goes as JSON; the batch the track came from goes in the query.
    public static func stationFeedback(_ feedback: StationFeedback, station: String, batchID: String?) -> Endpoint {
        var query = [URLQueryItem]()
        if let batchID = batchID, !batchID.isEmpty {
            query.append(URLQueryItem(name: "batch-id", value: batchID))
        }
        return Endpoint(method: .post, path: "rotor/station/\(station)/feedback", query: query, json: feedback.jsonBody)
    }

    public static func setDisliked(_ disliked: Bool, trackIDs: [String], uid: Int) -> Endpoint {
        let action = disliked ? "add-multiple" : "remove"
        return Endpoint(method: .post, path: "users/\(uid)/dislikes/tracks/\(action)",
                        form: [URLQueryItem(name: "track-ids", value: trackIDs.joined(separator: ","))])
    }

}

extension YandexMusicClient {

    /// «Моя волна», the personal endless radio.
    public static let myWave = "user:onyourwave"
    /// The `from` sent with `radioStarted` for «Моя волна». An analytics label; the
    /// value follows the `type-tag` pattern of station ids and is not confirmed.
    public static let myWaveFrom = "user-onyourwave"

    public func stationTracks(_ station: String, queue: String? = nil) -> AnyPublisher<StationTracks, Error> {
        return perform(.stationTracks(station, queue: queue), as: StationTracks.self)
    }

    /// The service answers `"ok"`.
    public func sendFeedback(_ feedback: StationFeedback, station: String, batchID: String?) -> AnyPublisher<Void, Error> {
        return perform(.stationFeedback(feedback, station: station, batchID: batchID), as: AnyValue.self)
            .map { _ in () }
            .eraseToAnyPublisher()
    }

    /// A disliked track no longer comes up in radio and recommendations.
    public func setDisliked(_ disliked: Bool, trackIDs: [String], uid: Int) -> AnyPublisher<Void, Error> {
        return perform(.setDisliked(disliked, trackIDs: trackIDs, uid: uid), as: AnyValue.self)
            .map { _ in () }
            .eraseToAnyPublisher()
    }

}
