//
//  PlaybackTests.swift
//  YandexMusicTests
//
//  download-info → XML → signed file URL.
//

import XCTest
@testable import YandexMusic

final class PlaybackTests: MockedTestCase {

    private let storage = "storage.mds.yandex.net/download-info/fixture/"
    /// md5("XGRlBW9FXlekgbPrRHuSiA" + "rmusic/U2FsdGVkX1_fixture/abc" + "4f1c9e2a7b"), computed with md5(1).
    private let expectedURL = "https://s123vla.storage.yandex.net/get-mp3/1b4525f634fa7307ea2ffe3138d87f24/0005f1e2d3c4b/rmusic/U2FsdGVkX1_fixture/abc"

    func testDownloadInfoParsing() throws {
        route("GET", api + "tracks/10994777/download-info", fixture: "download-info.json")

        let infos = try wait(client.downloadInfo(trackID: "10994777"))

        XCTAssertEqual(infos.count, 4)
        XCTAssertEqual(infos[0].codec, "aac")
        XCTAssertEqual(infos[0].bitrateInKbps, 192)
        XCTAssertFalse(infos[0].isPreview)
        XCTAssertEqual(infos[0].downloadInfoUrl.absoluteString, "https://storage.mds.yandex.net/download-info/fixture/aac-192?sign=fixture")
    }

    func testPreferredVariant() {
        let url = URL(string: "https://example.invalid")!
        let variants = [
            DownloadInfo(codec: "aac", bitrateInKbps: 256, downloadInfoUrl: url),
            DownloadInfo(codec: "mp3", bitrateInKbps: 192, downloadInfoUrl: url),
            DownloadInfo(codec: "mp3", bitrateInKbps: 320, preview: true, downloadInfoUrl: url),
            DownloadInfo(codec: "flac", bitrateInKbps: 1411, downloadInfoUrl: url),
        ]

        XCTAssertEqual(variants.preferred(), variants[1], "full MP3 beats a preview, AAC and FLAC")
        XCTAssertEqual(Array(variants[2...]).preferred(), variants[2], "a preview is better than nothing")
        XCTAssertEqual([variants[0]].preferred(), variants[0])
        XCTAssertNil([variants[3]].preferred(), "lossless is not supported")
    }

    func testDirectLinkSigning() throws {
        let parts = try XCTUnwrap(DirectLinkParts(xml: fixture("download-info.xml")))

        XCTAssertEqual(parts, DirectLinkParts(host: "s123vla.storage.yandex.net", path: "/rmusic/U2FsdGVkX1_fixture/abc",
                                              ts: "0005f1e2d3c4b", s: "4f1c9e2a7b"))
        XCTAssertEqual(parts.sign, "1b4525f634fa7307ea2ffe3138d87f24")
        XCTAssertEqual(parts.url?.absoluteString, expectedURL)
    }

    func testIncompleteXMLIsRejected() {
        let xml = Data("<download-info><host>h</host><path>/p</path><ts>1</ts></download-info>".utf8)

        XCTAssertNil(DirectLinkParts(xml: xml))
    }

    func testStreamLinkPicksBestFileAndSigns() throws {
        route("GET", api + "tracks/10994777/download-info", fixture: "download-info.json")
        route("GET", storage + "mp3-320", fixture: "download-info.xml")

        let link = try wait(client.streamLink(trackID: "10994777"))

        XCTAssertEqual(link, StreamLink(url: URL(string: expectedURL)!, codec: "mp3", bitrateInKbps: 320, isPreview: false))
        let xmlRequest = try XCTUnwrap(MockURLProtocol.requests.last)
        XCTAssertEqual(xmlRequest.url?.absoluteString, "https://storage.mds.yandex.net/download-info/fixture/mp3-320?sign=fixture")
        XCTAssertNil(xmlRequest.value(forHTTPHeaderField: "Authorization"), "the token stays on api.music.yandex.net")
    }

    func testStreamLinkMarksPreviews() throws {
        route("GET", api + "tracks/1/download-info", fixture: "download-info-preview.json")
        route("GET", storage + "preview-mp3", fixture: "download-info.xml")

        let link = try wait(client.streamLink(trackID: "1"))

        XCTAssertTrue(link.isPreview)
    }

    func testStreamLinkWithoutPlayableFile() {
        route("GET", api + "tracks/1/download-info",
              body: "{\"result\": [{\"codec\": \"flac\", \"bitrateInKbps\": 1411, \"downloadInfoUrl\": \"https://example.invalid/x\"}]}")

        XCTAssertEqual(waitForError(client.streamLink(trackID: "1")) as? YandexMusicError, .noPlayableFile)
    }

    func testBrokenXMLFails() {
        route("GET", api + "tracks/1/download-info", fixture: "download-info-preview.json")
        route("GET", storage + "preview-mp3", body: "<html>gone</html>")

        XCTAssertEqual(waitForError(client.streamLink(trackID: "1")) as? YandexMusicError, .badDownloadInfo)
    }

}
