//
//  AccountsView.swift
//  Nuage
//
//  The Accounts pane of the settings window: sign in to and out of each music
//  service. Services without a provider yet are listed as "coming soon".
//

import SwiftUI

let soundCloudLoginWindowID = "soundcloud-login"

struct AccountsView: View {

    @ObservedObject private var registry = ProviderRegistry.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            ForEach(ProviderID.allCases) { id in
                HStack(spacing: 10) {
                    Image(systemName: id.iconName)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(id.displayName)
                            .bold()
                        Text(status(of: id))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    button(for: id)
                }
                .padding(.vertical, 4)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func status(of id: ProviderID) -> String {
        guard registry.provider(for: id) != nil else { return "Coming soon" }

        switch registry.authStates[id] ?? .signedOut {
        case .signedIn(let name?): return "Signed in as \(name)"
        case .signedIn(nil): return "Signed in"
        case .signedOut: return "Not signed in"
        case .expired: return "Session expired"
        }
    }

    @ViewBuilder private func button(for id: ProviderID) -> some View {
        if let provider = registry.provider(for: id) {
            if registry.authStates[id]?.isSignedIn ?? false {
                Button("Sign Out", action: provider.signOut)
            }
            else {
                Button("Sign In") { signIn(to: id) }
            }
        }
        else {
            Button("Sign In") {}
                .disabled(true)
        }
    }

    private func signIn(to id: ProviderID) {
        switch id {
        case .soundCloud: openWindow(id: soundCloudLoginWindowID)
        case .spotify, .yandexMusic: break
        }
    }

}

/// The SoundCloud web login in its own window; closes itself once signed in.
struct SoundCloudLoginWindow: View {

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        LoginView { accessToken, expiryDate in
            ProviderRegistry.shared.soundCloud.signIn(accessToken: accessToken, expiryDate: expiryDate)
            dismiss()
        }
    }

}
