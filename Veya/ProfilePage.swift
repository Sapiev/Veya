import SpotCoreKit
import SwiftUI

/// A user's public playlists and the people and artists they follow; nil `username` is the signed-in user.
struct ProfilePage: View {
    let username: String?
    let playlists: PlaylistModel
    let history: NavigationHistory

    var body: some View {
        let profile = playlists.profiles[username ?? ""]
        LoadStateView(
            state: playlists.profileState[username ?? ""],
            isEmpty: profile == nil,
            empty: EmptyState(title: "Profile Unavailable", systemImage: "person.crop.circle", message: "Spotify can't show this profile."),
            failureTitle: "Couldn't Load Profile",
            retry: { Task { await playlists.loadProfile(username) } }
        ) {
            if let profile {
                content(profile)
            }
        }
        .navigationTitle(profile?.name ?? String(localized: "Profile"))
        .task(id: username) { await playlists.loadProfile(username) }
    }

    private func content(_ profile: UserProfile) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHero(kind: "Profile", title: profile.name, artwork: profile.artwork, round: true, topPadding: Theme.s5) {
                    Text("\(profile.playlists.count) public playlists · \(profile.followers) followers")
                }
                VStack(alignment: .leading, spacing: 28) {
                    grid("Public Playlists", profile.playlists) { item in
                        Card(title: item.name, artwork: item.artwork.isEmpty ? playlists.artwork[item.uri] ?? [] : item.artwork) {
                            history.navigate(to: .playlist(uri: item.uri))
                        }
                    }
                    grid("Following (profile section)", profile.following) { item in
                        Card(title: item.name, artwork: item.artwork, round: true) {
                            history.navigate(to: Self.route(item.uri))
                        }
                    }
                    if profile.playlists.isEmpty, profile.following.isEmpty {
                        Text("No public playlists or follows.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(Theme.s8)
            }
        }
        .task(id: profile.playlists) {
            await playlists.loadArtwork(profile.playlists.filter(\.artwork.isEmpty).map(\.uri))
        }
    }

    @ViewBuilder private func grid(_ title: LocalizedStringKey, _ items: [ProfileItem], card: @escaping (ProfileItem) -> Card) -> some View {
        if !items.isEmpty {
            PageSection(title: title) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .top)], alignment: .leading, spacing: 16) {
                    ForEach(items, id: \.uri, content: card)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text(title))
            }
        }
    }

    /// The core only lists users and artists here.
    private static func route(_ uri: String) -> Route {
        let user = "spotify:user:"
        return uri.hasPrefix(user) ? .profile(username: String(uri.dropFirst(user.count))) : .artist(uri: uri)
    }
}
