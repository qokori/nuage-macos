//
//  RotorTests.swift
//  YandexMusicTests
//
//  «Моя волна»: station tracks, feedback and dislikes, against the URLProtocol mock.
//

import XCTest
@testable import YandexMusic

final class RotorRequestTests: XCTestCase {

    private let client = YandexMusicClient(token: "test-token")
    /// 2026-10-14T06:39:13.631Z
    private let date = Date(timeIntervalSince1970: 1_791_959_953.631)

    func testFirstBatchAsksWithoutQueue() throws {
        let request = client.urlRequest(for: .stationTracks(YandexMusicClient.myWave))
        let url = try XCTUnwrap(request.url)

        XCTAssertEqual(request.httpMethod, "GET")
        // The colon of the station id stays as it is
        XCTAssertEqual(url.absoluteString, "https://api.music.yandex.net/rotor/station/user:onyourwave/tracks?settings2=true")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "OAuth test-token")
        XCTAssertNil(request.httpBody)
    }

    func testNextBatchContinuesAfterTheLastTrack() {
        let request = client.urlRequest(for: .stationTracks(YandexMusicClient.myWave, queue: "55500001"))

        XCTAssertEqual(request.url?.query, "settings2=true&queue=55500001")
        // Encoded like any query value (Python's `requests` does the same); the service decodes it
        XCTAssertEqual(client.urlRequest(for: .stationTracks(YandexMusicClient.myWave, queue: "10994777:1193829")).url?.query,
                       "settings2=true&queue=10994777%3A1193829")
        XCTAssertEqual(client.urlRequest(for: .stationTracks("user:onyourwave", queue: "")).url?.query, "settings2=true")
    }

    func testFeedbackIsJSONWithBatchInQuery() throws {
        let feedback = StationFeedback.trackFinished("10994777", playedSeconds: 200.96, at: date)
        let request = client.urlRequest(for: .stationFeedback(feedback, station: YandexMusicClient.myWave, batchID: "fixture-batch-1.abcd"))

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/rotor/station/user:onyourwave/feedback")
        XCTAssertEqual(request.url?.query, "batch-id=fixture-batch-1.abcd")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.httpBody.map { String(decoding: $0, as: UTF8.self) },
                       #"{"timestamp":"2026-10-14T06:39:13.631Z","totalPlayedSeconds":201,"trackId":"10994777","type":"trackFinished"}"#)
    }

    func testFeedbackBodies() throws {
        func body(_ feedback: StationFeedback) throws -> [String: AnyHashable] {
            let object = try JSONSerialization.jsonObject(with: feedback.jsonBody)
            return try XCTUnwrap(object as? [String: AnyHashable])
        }

        XCTAssertEqual(try body(.radioStarted(from: YandexMusicClient.myWaveFrom, at: date)),
                       ["type": "radioStarted", "from": "user-onyourwave", "timestamp": "2026-10-14T06:39:13.631Z"])
        XCTAssertEqual(try body(.trackStarted("33311009", at: date)),
                       ["type": "trackStarted", "trackId": "33311009", "timestamp": "2026-10-14T06:39:13.631Z"])
        XCTAssertEqual(try body(.skip("33311009", playedSeconds: 12.34, at: date)),
                       ["type": "skip", "trackId": "33311009", "totalPlayedSeconds": 12.3, "timestamp": "2026-10-14T06:39:13.631Z"])
        // An immediate skip still says 0; NaN (no player item) and negatives become 0
        XCTAssertEqual(try body(.skip("1", playedSeconds: 0, at: date))["totalPlayedSeconds"], 0)
        XCTAssertEqual(try body(.skip("1", playedSeconds: .nan, at: date))["totalPlayedSeconds"], 0)
        XCTAssertEqual(try body(.skip("1", playedSeconds: -3, at: date))["totalPlayedSeconds"], 0)
    }

    func testFeedbackWithoutBatchHasNoQuery() {
        let request = client.urlRequest(for: .stationFeedback(.radioStarted(from: "x", at: date), station: "user:onyourwave", batchID: nil))

        XCTAssertNil(request.url?.query)
    }

    func testDislikeIsAFormPost() {
        let dislike = client.urlRequest(for: .setDisliked(true, trackIDs: ["10994777"], uid: 7))
        XCTAssertEqual(dislike.httpMethod, "POST")
        XCTAssertEqual(dislike.url?.path, "/users/7/dislikes/tracks/add-multiple")
        XCTAssertEqual(dislike.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertEqual(dislike.httpBody.map { String(decoding: $0, as: UTF8.self) }, "track-ids=10994777")

        XCTAssertEqual(client.urlRequest(for: .setDisliked(false, trackIDs: ["1"], uid: 7)).url?.path, "/users/7/dislikes/tracks/remove")
    }

}

final class RotorResponseTests: MockedTestCase {

    private var wavePath: String { api + "rotor/station/user:onyourwave/" }

    func testStationTracksParseAndSkipNonTracks() throws {
        route("GET", wavePath + "tracks", fixture: "rotor-tracks.json")

        let batch = try wait(client.stationTracks(YandexMusicClient.myWave))

        XCTAssertEqual(batch.batchId, "fixture-batch-1.abcd")
        XCTAssertEqual(batch.id, StationTracks.StationID(type: "user", tag: "onyourwave"))
        XCTAssertEqual(batch.pumpkin, false)
        XCTAssertEqual(batch.sequence.count, 4)
        // The entry without a track is dropped; numeric and string ids both read
        XCTAssertEqual(batch.tracks.map { $0.id.value }, ["10994777", "33311009", "55500001"])
        XCTAssertEqual(batch.tracks[1].displayTitle, "Wave Two (Radio Edit)")
        // The next batch is asked after "<id>:<album id>"
        XCTAssertEqual(batch.tracks.map { $0.stationQueueID }, ["10994777:1193829", "33311009:4766", "55500001"])
        XCTAssertEqual(batch.sequence[1].liked, true)
        XCTAssertEqual(batch.tracks[0].coverURL(size: 400)?.absoluteString,
                       "https://avatars.yandex.net/get-music-content/fixture/400x400")

        let request = try XCTUnwrap(MockURLProtocol.requests.first)
        XCTAssertEqual(request.url?.query, "settings2=true")
    }

    func testNextBatchSendsQueue() throws {
        route("GET", wavePath + "tracks", fixture: "rotor-tracks-next.json")

        let batch = try wait(client.stationTracks(YandexMusicClient.myWave, queue: "55500001"))

        XCTAssertEqual(batch.batchId, "fixture-batch-2.efgh")
        XCTAssertNil(batch.pumpkin)
        XCTAssertEqual(batch.tracks.map { $0.id.value }, ["66600001"])
        XCTAssertEqual(MockURLProtocol.requests.first?.url?.query, "settings2=true&queue=55500001")
    }

    func testFeedbackSucceedsOnOK() throws {
        route("POST", wavePath + "feedback", body: #"{"invocationInfo":{},"result":"ok"}"#)

        try wait(client.sendFeedback(.skip("10994777", playedSeconds: 3), station: YandexMusicClient.myWave, batchID: "b1"))

        let request = try XCTUnwrap(MockURLProtocol.requests.first)
        XCTAssertEqual(request.url?.query, "batch-id=b1")
        XCTAssertTrue(body(of: request).contains(#""type":"skip""#), body(of: request))
    }

    func testFeedbackRejectedTokenIsUnauthorized() {
        route("POST", wavePath + "feedback", status: 401, fixture: "error-unauthorized.json")

        let error = waitForError(client.sendFeedback(.trackStarted("1"), station: YandexMusicClient.myWave, batchID: "b1"))
        XCTAssertEqual(error as? YandexMusicError, .unauthorized)
    }

    func testStationTracksAPIError() {
        route("GET", wavePath + "tracks", status: 400, fixture: "error-validate.json")

        let error = waitForError(client.stationTracks(YandexMusicClient.myWave))
        guard case .http(status: 400, _)? = error as? YandexMusicError else {
            return XCTFail("unexpected \(String(describing: error))")
        }
    }

    func testDislikeSendsTrackIDs() throws {
        route("POST", api + "users/7/dislikes/tracks/add-multiple", body: #"{"result":{"revision":12}}"#)

        try wait(client.setDisliked(true, trackIDs: ["10994777"], uid: 7))

        XCTAssertEqual(MockURLProtocol.requests.first.map(body(of:)), "track-ids=10994777")
    }

}
