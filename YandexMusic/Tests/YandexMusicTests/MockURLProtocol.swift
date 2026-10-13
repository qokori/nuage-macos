//
//  MockURLProtocol.swift
//  YandexMusicTests
//
//  Answers every request of a test session from a route table and records the
//  requests, so tests see exactly what the client sends. Nothing leaves the machine.
//

import Foundation
import Combine
import XCTest
@testable import YandexMusic

final class MockURLProtocol: URLProtocol {

    struct Response {
        var status = 200
        var body: Data
    }

    /// Keyed by "METHOD host/path", e.g. "GET api.music.yandex.net/account/status".
    static var routes = [String: Response]()
    /// Every request, with its body read back from the stream.
    static var requests = [URLRequest]()

    static func reset() {
        routes = [:]
        requests = []
    }

    static func key(for request: URLRequest) -> String {
        let url = request.url!
        return "\(request.httpMethod ?? "GET") \(url.host ?? "")\(url.path)"
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var recorded = request
        if recorded.httpBody == nil, let stream = request.httpBodyStream {
            recorded.httpBody = Data(reading: stream)
        }
        Self.requests.append(recorded)

        let key = Self.key(for: request)
        let response = Self.routes[key] ?? Response(status: 404, body: Data("{\"error\":\"no route for \(key)\"}".utf8))
        let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

}

private extension Data {

    init(reading stream: InputStream) {
        self.init()
        stream.open()
        defer { stream.close() }
        let size = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            guard read > 0 else { break }
            append(buffer, count: read)
        }
    }

}

/// Hand-written fixtures shaped like real API responses (no real account data).
func fixture(_ name: String) -> Data {
    let parts = name.split(separator: ".")
    let url = Bundle.module.url(forResource: String(parts[0]), withExtension: String(parts[1]), subdirectory: "Fixtures")!
    return try! Data(contentsOf: url)
}

class MockedTestCase: XCTestCase {

    let api = "api.music.yandex.net/"
    var client: YandexMusicClient!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        client = YandexMusicClient(token: "test-token", session: URLSession(configuration: configuration))
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    func route(_ method: String, _ path: String, status: Int = 200, fixture name: String) {
        MockURLProtocol.routes["\(method) \(path)"] = .init(status: status, body: fixture(name))
    }

    func route(_ method: String, _ path: String, status: Int = 200, body: String) {
        MockURLProtocol.routes["\(method) \(path)"] = .init(status: status, body: Data(body.utf8))
    }

    /// Waits for the publisher's single value or its error.
    func wait<T>(_ publisher: AnyPublisher<T, Error>, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        var result: Result<T, Error>?
        let done = expectation(description: "publisher finished")
        let subscription = publisher.sink(receiveCompletion: { completion in
            if case let .failure(error) = completion {
                result = .failure(error)
            }
            done.fulfill()
        }, receiveValue: { value in
            result = .success(value)
        })
        wait(for: [done], timeout: 5)
        subscription.cancel()
        return try XCTUnwrap(result, "publisher produced nothing", file: file, line: line).get()
    }

    func waitForError<T>(_ publisher: AnyPublisher<T, Error>, file: StaticString = #filePath, line: UInt = #line) -> Error? {
        do {
            _ = try wait(publisher, file: file, line: line)
            XCTFail("expected an error", file: file, line: line)
            return nil
        }
        catch {
            return error
        }
    }

    func body(of request: URLRequest) -> String {
        return String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    }

}
