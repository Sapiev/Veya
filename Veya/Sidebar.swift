import SpotCoreKit
import SwiftUI

/// Home and Search, then playlists, followed artists, saved albums and followed podcasts.
struct Sidebar: View {
    @Binding var selection: Route?
    let playlists: PlaylistModel
    let library: LibraryModel
    let player: PlayerModel?
    let newPlaylist: () -> Void
    let newFolder: () -> Void
    /// Expanded folder URIs, one per line.
    @SceneStorage("expandedFolders") private var expandedFolders = ""
    @State private var renaming: String?
    @State private var newName = ""
    @State private var deleting: String?
    @Environment(\.palette) private var palette

    /// Rows per library section; its header opens the full page.
    private static let sectionLimit = 8

    var body: some View {
        VStack(spacing: 0) {
            list
                // Clears the traffic lights, which sit inside the panel.
                .padding(.top, 40)
            Divider()
            Button(action: newPlaylist) {
                Label("New Playlist", systemImage: "plus")
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Theme.s4)
            .padding(.vertical, Theme.s2)
        }
    }

    private var list: some View {
        List(selection: $selection) {
            row(Text("Home"), .home) { symbol("house") }
            row(Text("Search"), .search) { symbol("magnifyingglass") }
            Section {
                row(Text("Liked Songs"), .likedSongs) {
                    SymbolTile(systemImage: "heart.fill", fill: Color(palette.tint), ink: Color(palette.tintInk))
                }
                PlaylistRows(nodes: playlists.tree, expanded: expanded, playlists: playlists, selection: selection, nowPlaying: nowPlaying)
                if playlists.rootlist.isEmpty {
                    switch playlists.state {
                    case .loaded:
                        Text("No Playlists")
                            .foregroundStyle(.secondary)
                    case .failed:
                        Text("Couldn't Load Playlists")
                            .foregroundStyle(.secondary)
                        Button("Try Again") { playlists.load() }
                            .buttonStyle(.borderless)
                    case .loading, nil:
                        EmptyView()
                    }
                }
            } header: {
                HStack {
                    SidebarHeader(title: Text("Playlists"))
                    Spacer()
                    Button("New Playlist", systemImage: "plus", action: newPlaylist)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("New Playlist")
                }
            }
            librarySection(.artists, title: Text("Artists"), route: .artists)
            librarySection(.albums, title: Text("Albums"), route: .albums)
            librarySection(.shows, title: Text("Podcasts"), route: .podcasts)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: Route.self) { routes in
            menu(routes)
        }
        .alert("Rename Playlist", isPresented: isPresent($renaming)) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let uri = renaming { Task { await playlists.rename(uri, to: trimmedName) } }
            }
            .disabled(trimmedName.isEmpty)
            Button("Cancel", role: .cancel) {}
        }
        .alert(Text("Delete “\(deleting.map(name) ?? "")”?"), isPresented: isPresent($deleting)) {
            Button("Delete", role: .destructive) {
                guard let uri = deleting else { return }
                if selection == .playlist(uri: uri) { selection = .home }
                Task { await playlists.delete(uri) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The playlist is removed from your library.")
        }
        .task {
            for kind in [LibraryKind.albums, .artists, .shows] {
                library.load(kind)
            }
        }
        .task(id: visibleLibraryURIs) { library.resolve(visibleLibraryURIs) }
        .task(id: playlists.rootlist) {
            await playlists.loadArtwork(playlists.rootlist.compactMap {
                if case let .playlist(uri, _, _, _, _, _, _) = $0 { uri } else { nil }
            })
        }
    }

    /// Edits for one editable playlist, then the create commands.
    @ViewBuilder private func menu(_ routes: Set<Route>) -> some View {
        if routes.count == 1, case let .playlist(uri)? = routes.first, playlists.isEditable(uri) {
            Button("Rename…") {
                newName = name(uri)
                renaming = uri
            }
            let isPublic = playlists.isPublic(uri)
            Button(isPublic ? "Make Private" : "Make Public") {
                Task { await playlists.setPublic(uri, !isPublic) }
            }
            Button("Delete Playlist", role: .destructive) { deleting = uri }
            Divider()
        }
        Button("New Playlist", action: newPlaylist)
        Button("New Folder", action: newFolder)
    }

    private var trimmedName: String {
        newName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func name(_ uri: String) -> String {
        playlists.editablePlaylists.first { $0.id == uri }?.name ?? ""
    }

    private func isPresent(_ uri: Binding<String?>) -> Binding<Bool> {
        Binding(get: { uri.wrappedValue != nil }, set: { if !$0 { uri.wrappedValue = nil } })
    }

    private var nowPlaying: String? {
        player?.isPlaying == true ? player?.context : nil
    }

    private var visibleLibraryURIs: [String] {
        [LibraryKind.albums, .artists, .shows].flatMap { (library.items[$0] ?? []).prefix(Self.sectionLimit).map(\.uri) }
    }

    private func librarySection(_ kind: LibraryKind, title: Text, route: Route) -> some View {
        Section {
            ForEach((library.items[kind] ?? []).prefix(Self.sectionLimit), id: \.uri) { item in
                row(Text(library.sidebarName(item.uri)), kind.route(item.uri)) {
                    let art = ArtworkView(artwork: library.sidebarArtwork(item.uri), side: 24)
                    if kind == .artists { art.clipShape(Circle()) } else { art.clipShape(RoundedRectangle(cornerRadius: 4)) }
                }
            }
        } header: {
            Button { selection = route } label: {
                SidebarHeader(title: title, selected: selection == route)
            }
            .buttonStyle(.plain)
        }
    }

    private func row(_ title: Text, _ route: Route, @ViewBuilder thumb: () -> some View) -> some View {
        SidebarRow(title: title, selected: selection == route, playing: route.uri.map { $0 == nowPlaying } ?? false, thumb: thumb())
            .tag(route)
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .foregroundStyle(Color(palette.tintText))
            .accessibilityHidden(true)
    }

    private var expanded: Binding<Set<String>> {
        Binding(
            get: { Set(expandedFolders.split(separator: "\n").map(String.init)) },
            set: { expandedFolders = $0.sorted().joined(separator: "\n") }
        )
    }
}

/// Folders as disclosure groups, collapsed until opened; playlists select their page.
private struct PlaylistRows: View {
    let nodes: [RootlistNode]
    @Binding var expanded: Set<String>
    let playlists: PlaylistModel
    let selection: Route?
    let nowPlaying: String?

    var body: some View {
        ForEach(nodes) { node in
            if let children = node.children {
                DisclosureGroup(isExpanded: isExpanded(node.id)) {
                    PlaylistRows(nodes: children, expanded: $expanded, playlists: playlists, selection: selection, nowPlaying: nowPlaying)
                } label: {
                    SidebarRow(title: Text(node.name), selected: false, playing: false, thumb: SymbolTile(systemImage: "folder"))
                }
            } else {
                let route = Route.playlist(uri: node.id)
                SidebarRow(
                    title: Text(node.name), selected: selection == route, playing: node.id == nowPlaying, thumb: thumb(node.id),
                    isPrivate: playlists.isEditable(node.id) && !playlists.isPublic(node.id)
                )
                    .tag(route)
            }
        }
    }

    @ViewBuilder private func thumb(_ uri: String) -> some View {
        let artwork = playlists.artwork[uri] ?? []
        if artwork.isEmpty {
            SymbolTile(systemImage: "music.note")
        } else {
            ArtworkView(artwork: artwork, side: 24).clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    private func isExpanded(_ folder: String) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(folder) },
            set: { expanded = $0 ? expanded.union([folder]) : expanded.subtracting([folder]) }
        )
    }
}

private struct SidebarRow<Thumb: View>: View {
    let title: Text
    let selected: Bool
    let playing: Bool
    let thumb: Thumb
    var isPrivate = false

    var body: some View {
        HStack(spacing: Theme.s2) {
            thumb.frame(width: 24, height: 24)
            title
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .lineLimit(1)
            if isPrivate {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("Private"))
            }
            Spacer(minLength: 0)
            if playing {
                Equalizer(animating: true)
            }
        }
        .frame(minHeight: 28)
    }
}

private struct SidebarHeader: View {
    let title: Text
    var selected = false

    var body: some View {
        title
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(selected ? .primary : .secondary)
    }
}

/// A 24 pt rounded tile behind a symbol, for rows without artwork.
private struct SymbolTile: View {
    let systemImage: String
    var fill: Color = .fillStrong
    var ink: Color = .secondary

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(fill)
            .overlay {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ink)
            }
            .accessibilityHidden(true)
    }
}

private extension Route {
    /// The playback context this destination plays, if any.
    var uri: String? {
        switch self {
        case let .playlist(uri), let .album(uri), let .artist(uri), let .show(uri): uri
        default: nil
        }
    }
}

private extension LibraryKind {
    func route(_ uri: String) -> Route {
        switch self {
        case .albums: .album(uri: uri)
        case .artists: .artist(uri: uri)
        default: .show(uri: uri)
        }
    }
}

private extension LibraryModel {
    func sidebarName(_ uri: String) -> String {
        switch metadata[uri] {
        case let .album(album): album.title
        case let .artist(artist): artist.name
        case let .show(show): show.name
        case .unavailable: String(localized: "Unavailable")
        default: String(localized: "Loading…")
        }
    }

    func sidebarArtwork(_ uri: String) -> [Artwork] {
        switch metadata[uri] {
        case let .album(album): album.artwork
        case let .artist(artist): artist.artwork
        case let .show(show): show.artwork
        default: []
        }
    }
}
