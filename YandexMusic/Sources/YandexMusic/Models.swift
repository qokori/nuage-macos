//
//  Models.swift
//  YandexMusic
//
//  The parts of the API's JSON that Nuage uses. Every field the app can live
//  without is optional: the API is unofficial and changes without notice.
//

import Foundation

/// Ids come as numbers in some responses and as strings in others
/// (user-uploaded tracks have UUID-like string ids), so they are kept as strings.
public struct FlexibleID: Decodable, Hashable, CustomStringConvertible {

    public var value: String

    public init(_ value: String) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int.self) {
            value = String(int)
        }
        else {
            value = try container.decode(String.self)
        }
    }

    public var description: String { value }

}

/// Turns an image template such as `avatars.yandex.net/get-music-content/…/%%`
/// into a URL of the given size.
func imageURL(template: String?, size: Int) -> URL? {
    guard var template = template, !template.isEmpty else { return nil }

    template = template.replacingOccurrences(of: "%%", with: "\(size)x\(size)")
    if !template.hasPrefix("http://") && !template.hasPrefix("https://") {
        template = "https://" + template
    }
    return URL(string: template)
}

let webBaseURL = URL(string: "https://music.yandex.ru")!

// MARK: - Account

public struct AccountStatus: Decodable {

    public struct Account: Decodable {
        /// Missing when the request was not authorized.
        public var uid: Int?
        public var login: String?
        public var displayName: String?
        public var fullName: String?
    }

    public struct Plus: Decodable {
        public var hasPlus: Bool?
    }

    public var account: Account
    public var plus: Plus?

    public var hasPlus: Bool { plus?.hasPlus ?? false }

    /// The name to show for the account, best first.
    public var displayName: String? {
        return [account.displayName, account.fullName, account.login]
            .compactMap { $0 }
            .first { !$0.isEmpty }
    }

}

// MARK: - Catalog

public struct Cover: Decodable {

    /// `pic` for one picture, `mosaic` for a grid of album covers.
    public var type: String?
    public var uri: String?
    public var itemsUri: [String]?

    public func url(size: Int) -> URL? {
        return imageURL(template: uri ?? itemsUri?.first, size: size)
    }

}

public struct Artist: Decodable {

    public var id: FlexibleID
    public var name: String
    public var cover: Cover?
    public var ogImage: String?

    public func imageURL(size: Int) -> URL? {
        return cover?.url(size: size) ?? YandexMusic.imageURL(template: ogImage, size: size)
    }

    public var webURL: URL {
        return webBaseURL.appendingPathComponent("artist/\(id)")
    }

}

public struct Album: Decodable {

    public var id: FlexibleID
    public var title: String?
    public var coverUri: String?

}

public struct Track: Decodable {

    public var id: FlexibleID
    public var title: String?
    /// "Remastered", "Radio Edit"…; shown after the title.
    public var version: String?
    public var durationMs: Int?
    public var coverUri: String?
    public var ogImage: String?
    public var artists: [Artist]?
    public var albums: [Album]?
    public var available: Bool?

    public var displayTitle: String {
        let title = self.title ?? ""
        guard let version = version, !version.isEmpty else { return title }
        return "\(title) (\(version))"
    }

    /// "Artist A, Artist B".
    public var artistNames: String {
        return (artists ?? []).map { $0.name }.joined(separator: ", ")
    }

    public var duration: TimeInterval {
        return TimeInterval(durationMs ?? 0) / 1000
    }

    public func coverURL(size: Int) -> URL? {
        let template = coverUri ?? albums?.first?.coverUri ?? ogImage
        return imageURL(template: template, size: size)
    }

    public var webURL: URL {
        if let album = albums?.first {
            return webBaseURL.appendingPathComponent("album/\(album.id)/track/\(id)")
        }
        return webBaseURL.appendingPathComponent("track/\(id)")
    }

}

/// A track reference in likes and playlists; `track` is filled only in "rich" responses.
public struct TrackShort: Decodable {

    public var id: FlexibleID
    public var albumId: FlexibleID?
    public var timestamp: String?
    public var track: Track?

    /// `trackId:albumId`, the form `/tracks` resolves fastest.
    public var fullID: String {
        guard let album = albumId else { return id.value }
        return "\(id):\(album)"
    }

}

struct LikesResult: Decodable {

    struct Library: Decodable {
        var uid: Int?
        var revision: Int?
        var tracks: [TrackShort]?
    }

    var library: Library

}

public struct Playlist: Decodable {

    public struct Owner: Decodable {
        public var uid: Int
        public var login: String?
        public var name: String?
    }

    /// The owner's uid.
    public var uid: Int
    public var kind: Int
    public var title: String
    public var owner: Owner?
    public var trackCount: Int?
    public var description: String?
    public var cover: Cover?
    public var ogImage: String?
    public var tracks: [TrackShort]?

    /// `ownerUid:kind`, the id the likes endpoints take.
    public var playlistID: String { "\(uid):\(kind)" }

    public func coverURL(size: Int) -> URL? {
        return cover?.url(size: size) ?? imageURL(template: ogImage, size: size)
    }

    public var webURL: URL {
        let user = owner?.login ?? String(uid)
        return webBaseURL.appendingPathComponent("users/\(user)/playlists/\(kind)")
    }

}

/// An entry of `/users/{uid}/likes/playlists`.
struct LikedPlaylist: Decodable {

    var playlist: Playlist?

}

public struct SearchResult: Decodable {

    public struct Section<Element: Decodable>: Decodable {
        public var total: Int?
        public var results: [Element]
    }

    public var text: String?
    public var tracks: Section<Track>?
    public var artists: Section<Artist>?
    public var playlists: Section<Playlist>?

}

// MARK: - Download

/// One downloadable variant of a track, as listed by `/tracks/{id}/download-info`.
public struct DownloadInfo: Decodable, Equatable {

    public var codec: String
    public var bitrateInKbps: Int
    public var gain: Bool?
    /// `true` for the 30-second previews accounts without Yandex Plus get.
    public var preview: Bool?
    /// An XML document with the parts of the signed file URL.
    public var downloadInfoUrl: URL

    public var isPreview: Bool { preview ?? false }

}

/// A playable file URL for a track.
public struct StreamLink: Equatable {

    public var url: URL
    public var codec: String
    public var bitrateInKbps: Int
    /// Only 30 seconds of the track: the account has no Yandex Plus.
    public var isPreview: Bool

}
