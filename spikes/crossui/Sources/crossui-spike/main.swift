import DefaultBackend
import Foundation
import SwiftCrossUI

struct Track: Identifiable {
    let id: Int
    let title: String
    let artist: String
    let album: String
    let seconds: Int

    var duration: String { "\(seconds / 60):" + String(format: "%02d", seconds % 60) }
}

let tracks = (0..<10_000).map {
    Track(id: $0, title: "Track \($0)", artist: "Artist \($0 % 97)", album: "Album \($0 % 311)", seconds: 120 + $0 % 240)
}

let sidebarItems = ["Home", "Search", "Library", "Chill Mix", "Road Trip", "Focus"]

@main
struct CrossUISpike: App {
    @State var section: String? = "Library"
    @State var selectedTrack: Int? = 0
    @State var query = ""
    @State var playing = false
    @State var position = 0.0
    @State var volume = 0.7

    var body: some Scene {
        WindowGroup("crossui-spike") {
            VStack(spacing: 0) {
                NavigationSplitView {
                    List(sidebarItems, id: \.self, selection: $section)
                        .frame(minWidth: 180)
                } detail: {
                    VStack(alignment: .leading) {
                        Text(section ?? "").font(.title)
                        TextField("Search", text: $query)
                        List(visibleTracks, selection: $selectedTrack) { track in
                            HStack {
                                Text(track.title).frame(minWidth: 160)
                                Text(track.artist).frame(minWidth: 140)
                                Text(track.album).frame(minWidth: 140)
                                Spacer()
                                Text(track.duration)
                                // No contextMenu modifier in 0.10.0; Menu is the closest per-row substitute.
                                Menu("...") {
                                    Button("Play") { selectedTrack = track.id; playing = true }
                                    Button("Add to queue") {}
                                }
                            }
                        }
                    }
                    .padding()
                }
                nowPlayingBar
            }
        }
        .defaultSize(width: 1000, height: 700)
    }

    var visibleTracks: [Track] {
        query.isEmpty ? tracks : tracks.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    var nowPlayingBar: some View {
        HStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.blue)
                .frame(width: 48, height: 48)
            VStack(alignment: .leading) {
                Text(selectedTrack.map { tracks[$0].title } ?? "Nothing playing")
                Text(selectedTrack.map { tracks[$0].artist } ?? "")
            }
            Button(playing ? "Pause" : "Play") { playing.toggle() }
            Slider(value: $position, in: 0...1).frame(minWidth: 300)
            Text("Vol")
            Slider(value: $volume, in: 0...1).frame(width: 100)
        }
        .padding()
    }
}
