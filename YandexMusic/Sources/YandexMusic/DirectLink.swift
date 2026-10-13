//
//  DirectLink.swift
//  YandexMusic
//
//  `downloadInfoUrl` points to a small XML document (host, path, ts, s).
//  The file URL is https://{host}/get-mp3/{sign}/{ts}{path}, where sign is the
//  MD5 hex digest of a fixed salt, the path without its leading slash and s.
//

import Foundation
import CryptoKit

/// The salt the official clients sign file URLs with.
private let signSalt = "XGRlBW9FXlekgbPrRHuSiA"

struct DirectLinkParts: Equatable {

    var host: String
    var path: String
    var ts: String
    var s: String

    /// Parses the download-info XML; `nil` when a part is missing.
    init?(xml: Data) {
        let parser = XMLParser(data: xml)
        let collector = ElementCollector(names: ["host", "path", "ts", "s"])
        parser.delegate = collector
        guard parser.parse(),
              let host = collector.values["host"], !host.isEmpty,
              let path = collector.values["path"], !path.isEmpty,
              let ts = collector.values["ts"],
              let s = collector.values["s"] else { return nil }

        self.init(host: host, path: path, ts: ts, s: s)
    }

    init(host: String, path: String, ts: String, s: String) {
        self.host = host
        self.path = path
        self.ts = ts
        self.s = s
    }

    var sign: String {
        let pathWithoutSlash = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let digest = Insecure.MD5.hash(data: Data((signSalt + pathWithoutSlash + s).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    var url: URL? {
        let path = self.path.hasPrefix("/") ? self.path : "/" + self.path
        return URL(string: "https://\(host)/get-mp3/\(sign)/\(ts)\(path)")
    }

}

/// Collects the text of a few top-level elements.
private final class ElementCollector: NSObject, XMLParserDelegate {

    let names: Set<String>
    private(set) var values = [String: String]()
    private var current: String?

    init(names: Set<String>) {
        self.names = names
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        current = names.contains(elementName) ? elementName : nil
        if let current = current {
            values[current] = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard let current = current else { return }
        values[current, default: ""] += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        if let current = current {
            values[current] = values[current]?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        current = nil
    }

}

extension Array where Element == DownloadInfo {

    /// The variant to play: full tracks before previews, MP3 before AAC
    /// (AVPlayer plays both), then the highest bitrate.
    func preferred() -> DownloadInfo? {
        let playable = filter { ["mp3", "aac"].contains($0.codec.lowercased()) }
        return playable.max { $0.rank < $1.rank }
    }

}

private extension DownloadInfo {

    var rank: (Int, Int, Int) {
        return (isPreview ? 0 : 1, codec.lowercased() == "mp3" ? 1 : 0, bitrateInKbps)
    }

}
