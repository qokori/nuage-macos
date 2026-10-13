//
//  RequestBuildingTests.swift
//  YandexMusicTests
//

import XCTest
@testable import YandexMusic

final class RequestBuildingTests: XCTestCase {

    private let client = YandexMusicClient(token: "test-token")

    func testHeadersCarryTokenAndClient() {
        let request = client.urlRequest(for: .accountStatus())

        XCTAssertEqual(request.url?.absoluteString, "https://api.music.yandex.net/account/status")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "OAuth test-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Yandex-Music-Client"), "YandexMusicAndroid/24023621")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Language"), "ru")
        XCTAssertNil(request.httpBody)
    }

    func testNoAuthorizationWithoutToken() {
        let request = YandexMusicClient().urlRequest(for: .accountStatus())

        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testLibraryPaths() {
        XCTAssertEqual(client.urlRequest(for: .likedTracks(uid: 7)).url?.path, "/users/7/likes/tracks")
        XCTAssertEqual(client.urlRequest(for: .playlists(uid: 7)).url?.path, "/users/7/playlists/list")
        XCTAssertEqual(client.urlRequest(for: .likedPlaylists(uid: 7)).url?.path, "/users/7/likes/playlists")
        XCTAssertEqual(client.urlRequest(for: .playlist(uid: 7, kind: 1003)).url?.path, "/users/7/playlists/1003")
        XCTAssertEqual(client.urlRequest(for: .downloadInfo(trackID: "10994777")).url?.path, "/tracks/10994777/download-info")
    }

    func testSearchQueryIsFullyEscaped() throws {
        let request = client.urlRequest(for: .search("AC/DC & Кино+1"))
        let url = try XCTUnwrap(request.url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(url.path, "/search")
        // "+" and "&" must not leak into the query as separators or spaces
        XCTAssertTrue(components.percentEncodedQuery?.hasPrefix("text=AC%2FDC%20%26%20%D0%9A%D0%B8%D0%BD%D0%BE%2B1&") ?? false,
                      components.percentEncodedQuery ?? "")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["text"], "AC/DC & Кино+1")
        XCTAssertEqual(items["type"], "all")
        XCTAssertEqual(items["page"], "0")
        XCTAssertEqual(items["nocorrect"], "false")
        XCTAssertEqual(items["playlist-in-best"], "true")
    }

    func testLikeTracksIsAFormPost() {
        let like = client.urlRequest(for: .setLiked(true, trackIDs: ["10994777:1193829", "33311009"], uid: 7))

        XCTAssertEqual(like.httpMethod, "POST")
        XCTAssertEqual(like.url?.path, "/users/7/likes/tracks/add-multiple")
        XCTAssertEqual(like.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertEqual(like.httpBody.map { String(decoding: $0, as: UTF8.self) }, "track-ids=10994777%3A1193829%2C33311009")

        let unlike = client.urlRequest(for: .setLiked(false, trackIDs: ["1"], uid: 7))
        XCTAssertEqual(unlike.url?.path, "/users/7/likes/tracks/remove")
    }

    func testLikePlaylistsIsAFormPost() {
        let like = client.urlRequest(for: .setLiked(true, playlistIDs: ["503646255:2160"], uid: 7))
        XCTAssertEqual(like.url?.path, "/users/7/likes/playlists/add-multiple")
        XCTAssertEqual(like.httpBody.map { String(decoding: $0, as: UTF8.self) }, "playlist-ids=503646255%3A2160")

        let unlike = client.urlRequest(for: .setLiked(false, playlistIDs: ["503646255:2160"], uid: 7))
        XCTAssertEqual(unlike.url?.path, "/users/7/likes/playlists/remove")
    }

    func testTracksIsAFormPost() {
        let request = client.urlRequest(for: .tracks(ids: ["1:2", "3"]))

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/tracks")
        XCTAssertEqual(request.httpBody.map { String(decoding: $0, as: UTF8.self) }, "track-ids=1%3A2%2C3&with-positions=false")
    }

    func testTokenFromPastedText() {
        XCTAssertEqual(YandexMusicClient.token(fromPasted: "  y0_AgAAAAFixture\n"), "y0_AgAAAAFixture")
        XCTAssertEqual(YandexMusicClient.token(fromPasted: "OAuth y0_AgAAAAFixture"), "y0_AgAAAAFixture")
        XCTAssertEqual(YandexMusicClient.token(fromPasted: "https://music.yandex.ru/#access_token=y0_AgAAAAFixture&token_type=bearer&expires_in=31535645"),
                       "y0_AgAAAAFixture")
        XCTAssertNil(YandexMusicClient.token(fromPasted: "   "))
        XCTAssertNil(YandexMusicClient.token(fromPasted: "two words"))
    }

}
