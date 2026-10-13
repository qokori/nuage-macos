//
//  Stream.swift
//  Nuage
//
//  Created by Laurin Brandner on 26.12.19.
//  Copyright © 2019 Laurin Brandner. All rights reserved.
//

import AVFoundation
import Combine
import SoundCloud

extension Track: Streamable {
    
    func prepare() -> AnyPublisher<AVURLAsset, Error> {
        return ProviderRegistry.shared.soundCloud.asset(for: self)
    }
    
}
