//
//  StatsStack.swift
//  Nuage
//
//  Created by Laurin Brandner on 01.08.23.
//

import SwiftUI

/// Play, like and repost counters; a counter the service does not send is left out.
struct StatsStack: View {
    
    private var stats: MediaStats
    
    var body: some View {
        HStack(spacing: 4) {
            counter(stats.plays, imageName: "play.fill")
            counter(stats.likes, imageName: "heart.fill")
            counter(stats.reposts, imageName: "arrow.triangle.2.circlepath")
        }
    }
    
    @ViewBuilder private func counter(_ count: Int?, imageName: String) -> some View {
        if let count = count {
            Image(systemName: imageName)
            Text(format(count: count))
            
            Spacer().frame(width: 2)
        }
    }
    
    init(for stats: MediaStats) {
        self.stats = stats
    }
    
}
