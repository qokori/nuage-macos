//
//  AccountsView.swift
//  Nuage
//
//  The Accounts pane of the settings window: sign in to and out of each music
//  service. Services without a provider yet are listed as "coming soon".
//

import SwiftUI
import Combine
import YandexMusic

let soundCloudLoginWindowID = "soundcloud-login"

struct AccountsView: View {

    @ObservedObject private var registry = ProviderRegistry.shared
    @Environment(\.openWindow) private var openWindow
    @State private var showingYandexMusicSignIn = false

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
                        if let notice = registry.provider(for: id)?.accountNotice {
                            Text(notice)
                                .font(.caption)
                                .foregroundColor(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                    button(for: id)
                }
                .padding(.vertical, 4)
            }
        }
        .padding(20)
        .frame(width: 420)
        .sheet(isPresented: $showingYandexMusicSignIn) {
            YandexMusicSignInSheet()
        }
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
            switch registry.authStates[id] ?? .signedOut {
            case .signedIn:
                Button("Sign Out", action: provider.signOut)
            case .expired:
                // Forget the rejected session or replace it
                Button("Sign Out", action: provider.signOut)
                Button("Sign In") { signIn(to: id) }
            case .signedOut:
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
        case .yandexMusic: showingYandexMusicSignIn = true
        case .spotify: break
        }
    }

}

/// Opens Settings → Accounts, for signing in to services other than SoundCloud.
struct OtherAccountsLink: View {

    private let title = "Sign in to Yandex Music instead…"

    var body: some View {
        if #available(macOS 14, *) {
            SettingsLink { Text(title) }
        }
        else {
            Button(title) {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
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

/// Yandex has no sign-in for third-party apps, so the user pastes an OAuth token.
/// It is checked with Yandex first and saved (in the Keychain) only if accepted.
struct YandexMusicSignInSheet: View {

    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var isChecking = false
    @State private var errorMessage: String?
    @State private var subscription: AnyCancellable?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign In to Yandex Music")
                .font(.headline)
            Text("Paste the OAuth token of your Yandex account. Nuage checks it with Yandex and keeps it only in your Keychain. The token gives full access to your Yandex account: do not share it.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("OAuth token", text: $token)
                .textFieldStyle(.roundedBorder)
                .onSubmit(signIn)
            if let errorMessage = errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Without Yandex Plus, tracks play as 30-second previews.")
                .font(.caption)
                .foregroundColor(.secondary)
            HStack {
                if isChecking {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button("Cancel") {
                    subscription?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Sign In", action: signIn)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isChecking || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
        // A check still running after the sheet is gone must not sign in
        .onDisappear { subscription?.cancel() }
    }

    private func signIn() {
        guard !isChecking else { return }

        isChecking = true
        errorMessage = nil
        subscription = ProviderRegistry.shared.yandexMusic.signIn(token: token)
            .receive(on: RunLoop.main)
            .sink(receiveCompletion: { completion in
                isChecking = false
                if case let .failure(error) = completion {
                    errorMessage = message(for: error)
                }
            }, receiveValue: {
                token = ""
                dismiss()
            })
    }

    private func message(for error: Error) -> String {
        if (error as? YandexMusicError) == .unauthorized {
            return "Yandex Music rejected this token. Check that you copied all of it and that it has not been revoked."
        }
        return error.localizedDescription
    }

}
