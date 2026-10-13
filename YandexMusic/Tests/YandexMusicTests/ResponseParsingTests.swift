//
//  ResponseParsingTests.swift
//  YandexMusicTests
//
//  Calls go through `MockURLProtocol` and the hand-written fixtures.
//

import XCTest
@testable import YandexMusic

final class ResponseParsingTests: MockedTestCase {

    // MARK: - Account

    func testAccountStatus() throws {
        route("GET", api + "account/status", fixture: "account-status.json")

        let status = try wait(client.accountStatus())

        XCTAssertEqual(status.account.uid, 1130000001)
        XCTAssertEqual(status.displayName, "fixture-listener")
        XCTAssertTrue(status.hasPlus)
        XCTAssertEqual(MockURLProtocol.requests.first?.value(forHTTPHeaderField: "Authorization"), "OAuth test-token")
    }

    func testCandidateTokenIsUsedForOneRequestOnly() throws {
        route("GET", api + "account/status", fixture: "account-status.json")

        _ = try wait(client.accountStatus(candidate: "candidate-token"))

        XCTAssertEqual(MockURLProtocol.requests.first?.value(forHTTPHeaderField: "Authorization"), "OAuth candidate-token")
        XCTAssertEqual(client.token, "test-token")
    }

    func testAccountWithoutPlus() throws {
        route("GET", api + "account/status", fixture: "account-status-no-plus.json")

        let status = try wait(client.accountStatus())

        XCTAssertFalse(status.hasPlus)
        XCTAssertEqual(status.displayName, "free.fixture")
    }

    func testAnonymousAccountIsUnauthorized() {
        route("GET", api + "account/status", fixture: "account-status-anonymous.json")

        XCTAssertEqual(waitForError(client.accountStatus()) as? YandexMusicError, .unauthorized)
    }

    func testHTTP401IsUnauthorized() {
        route("GET", api + "account/status", status: 401, fixture: "error-unauthorized.json")

        XCTAssertEqual(waitForError(client.accountStatus()) as? YandexMusicError, .unauthorized)
    }

    func testHTTPErrorKeepsTheServiceMessage() {
        route("GET", api + "search", status: 400, fixture: "error-validate.json")

        XCTAssertEqual(waitForError(client.search("x")) as? YandexMusicError, .http(status: 400, message: "validate"))
    }

    func testErrorBodyWithoutResult() {
        route("GET", api + "account/status", fixture: "error-unauthorized.json")

        XCTAssertEqual(waitForError(client.accountStatus()) as? YandexMusicError,
                       .api(name: "session-expired", message: "Your OAuth token is expired"))
    }

    // MARK: - Tracks

    func testLikedTracksKeepLikeOrder() throws {
        route("GET", api + "users/1130000001/likes/tracks", fixture: "likes-tracks.json")
        route("POST", api + "tracks", fixture: "tracks.json")

        let tracks = try wait(client.likedTracks(uid: 1130000001))

        XCTAssertEqual(tracks.map { $0.id.value }, ["10994777", "33311009", "8f2c1e9a-uuid-ugc"])
        let tracksRequest = try XCTUnwrap(MockURLProtocol.requests.last)
        XCTAssertEqual(body(of: tracksRequest), "track-ids=10994777%3A1193829%2C33311009%3A4766%2C8f2c1e9a-uuid-ugc&with-positions=false")

        let first = tracks[0]
        XCTAssertEqual(first.displayTitle, "First Song (Remastered 2011)")
        XCTAssertEqual(first.artistNames, "Artist One, Guest")
        XCTAssertEqual(first.artists?.first?.id.value, "41075")
        XCTAssertEqual(first.duration, 182.5)
        XCTAssertEqual(first.coverURL(size: 200)?.absoluteString, "https://avatars.yandex.net/get-music-content/333/og/200x200")
        XCTAssertEqual(first.webURL.absoluteString, "https://music.yandex.ru/album/1193829/track/10994777")

        let second = tracks[1]
        XCTAssertEqual(second.displayTitle, "Second Song")
        XCTAssertEqual(second.coverURL(size: 400)?.absoluteString, "https://avatars.yandex.net/get-music-content/111/abc.a.4766-1/400x400")
        XCTAssertEqual(second.artists?.first?.imageURL(size: 100)?.absoluteString,
                       "https://avatars.yandex.net/get-music-content/222/artist2/100x100")
        XCTAssertEqual(second.artists?.first?.webURL.absoluteString, "https://music.yandex.ru/artist/9262")

        let upload = tracks[2]
        XCTAssertNil(upload.coverURL(size: 200))
        XCTAssertEqual(upload.artistNames, "")
        XCTAssertEqual(upload.webURL.absoluteString, "https://music.yandex.ru/track/8f2c1e9a-uuid-ugc")
    }

    func testTracksAreFetchedInBatches() throws {
        route("POST", api + "tracks", body: "{\"result\": []}")
        let ids = (1...250).map(String.init)

        let tracks = try wait(client.tracks(ids: ids))

        XCTAssertTrue(tracks.isEmpty)
        XCTAssertEqual(MockURLProtocol.requests.count, 3)
        let sizes = MockURLProtocol.requests.map { request -> Int in
            let value = body(of: request).components(separatedBy: "&")[0].dropFirst("track-ids=".count)
            return value.components(separatedBy: "%2C").count
        }
        XCTAssertEqual(sizes, [100, 100, 50])
    }

    func testNoTracksNoRequest() throws {
        XCTAssertTrue(try wait(client.tracks(ids: [])).isEmpty)
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }

    func testSetLiked() throws {
        route("POST", api + "users/7/likes/tracks/add-multiple", fixture: "like-result.json")

        XCTAssertNoThrow(try wait(client.setLiked(true, trackIDs: ["10994777"], uid: 7)))
    }

    // MARK: - Playlists

    func testPlaylists() throws {
        route("GET", api + "users/1130000001/playlists/list", fixture: "playlists-list.json")

        let playlists = try wait(client.playlists(uid: 1130000001))

        XCTAssertEqual(playlists.count, 2)
        let roadTrip = playlists[0]
        XCTAssertEqual(roadTrip.playlistID, "1130000001:1003")
        XCTAssertEqual(roadTrip.title, "Road Trip")
        XCTAssertEqual(roadTrip.trackCount, 2)
        XCTAssertEqual(roadTrip.owner?.uid, 1130000001)
        XCTAssertEqual(roadTrip.coverURL(size: 200)?.absoluteString, "https://avatars.yandex.net/get-music-content/444/m1/200x200")
        XCTAssertEqual(roadTrip.webURL.absoluteString, "https://music.yandex.ru/users/nuage.fixture/playlists/1003")
        XCTAssertEqual(playlists[1].coverURL(size: 200)?.absoluteString,
                       "https://avatars.yandex.net/get-music-user-playlist/555/pic/200x200")
    }

    func testLikedPlaylistsSkipEntriesWithoutPlaylist() throws {
        route("GET", api + "users/1130000001/likes/playlists", fixture: "likes-playlists.json")

        let playlists = try wait(client.likedPlaylists(uid: 1130000001))

        XCTAssertEqual(playlists.map { $0.playlistID }, ["503646255:2160"])
        XCTAssertEqual(playlists[0].owner?.login, "music-blog")
        XCTAssertEqual(playlists[0].coverURL(size: 200)?.absoluteString,
                       "https://avatars.yandex.net/get-music-user-playlist/666/og/200x200")
    }

    func testPlaylistTracksFetchOnlyTheMissingOnes() throws {
        route("GET", api + "users/1130000001/playlists/1003", fixture: "playlist-with-tracks.json")
        route("POST", api + "tracks", fixture: "tracks-one.json")

        let tracks = try wait(client.tracks(inPlaylistOf: 1130000001, kind: 1003))

        XCTAssertEqual(tracks.map { $0.displayTitle }, ["First Song", "Second Song"])
        XCTAssertEqual(MockURLProtocol.requests.count, 2)
        XCTAssertEqual(body(of: MockURLProtocol.requests[1]), "track-ids=33311009%3A4766&with-positions=false")
    }

    // MARK: - Search

    func testSearch() throws {
        route("GET", api + "search", fixture: "search.json")

        let result = try wait(client.search("kino"))

        XCTAssertEqual(result.tracks?.results.map { $0.displayTitle }, ["Gruppa krovi"])
        XCTAssertEqual(result.tracks?.results.first?.coverURL(size: 200)?.absoluteString,
                       "https://avatars.yandex.net/get-music-content/777/k/200x200")
        XCTAssertEqual(result.artists?.results.map { $0.name }, ["Kino"])
        XCTAssertEqual(result.playlists?.results.map { $0.playlistID }, ["42:1000"])
    }

    func testEmptySearch() throws {
        route("GET", api + "search", fixture: "search-empty.json")

        let result = try wait(client.search("zzzzqqq"))

        XCTAssertNil(result.tracks)
        XCTAssertNil(result.artists)
        XCTAssertNil(result.playlists)
    }

}
