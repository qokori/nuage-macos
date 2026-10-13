//
//  UserGrid.swift
//  Nuage
//
//  Created by Laurin Brandner on 27.12.19.
//  Copyright © 2019 Laurin Brandner. All rights reserved.
//

import SwiftUI
import Combine
import SoundCloud

struct UserGrid<Element: Decodable&Identifiable&Filterable&Hashable>: View {
    
    var publisher: InfinitePublisher<Element>
    private var transform: (Element) -> User
    
    var body: some View {
        InfiniteGrid(publisher: publisher) { users, idx in
            let user = transform(users[idx])
            NavigationLink(value: user) {
                UserItem(user: user)
            }
            .buttonStyle(.plain)
        }
    }
    
}

extension UserGrid where Element == User {
    
    init(for publisher: AnyPublisher<Page<User>, Error>) {
        self.init(publisher: .page(publisher)) { $0 }
    }
    
}

extension UserGrid where Element == Recommendation {
    
    init(for publisher: AnyPublisher<Page<Recommendation>, Error>) {
        self.init(publisher: .page(publisher)) { $0.user }
    }
    
}

/// An artist's avatar, name and counters; counters the service does not send show as 0.
struct UserItem: View {
    
    var artist: MediaArtist
    
    var body: some View {
        VStack(alignment: .center) {
            RemoteImage(url: artist.avatarURL, cornerRadius: 50)
                .frame(width: 100, height: 100)
            
            Text(artist.name)
                .bold()
                .lineLimit(1)
            
            HStack(spacing: 2) {
                Text(format(count: artist.followerCount ?? 0))
                Image(systemName: "person.2.fill")
                
                Spacer()
                    .frame(width: 8)
                
                Text(format(count: artist.trackCount ?? 0))
                Image(systemName: "waveform")
            }
            .foregroundColor(.secondary)
        }
    }
    
    init(artist: MediaArtist) {
        self.artist = artist
    }
    
    init(user: User) {
        self.artist = MediaArtist(user)
    }

}

//struct UserList_Previews: PreviewProvider {
//    static var previews: some View {
//        UserList()
//    }
//}
