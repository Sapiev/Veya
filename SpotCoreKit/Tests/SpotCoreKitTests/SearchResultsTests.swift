@testable import SpotCoreKit
import Testing

struct SearchResultsTests {
    private func hit(_ name: String, _ subtitle: String = "") -> SearchHit {
        SearchHit(uri: "spotify:x:\(name)", name: name, subtitle: subtitle, artwork: [], explicit: false)
    }

    private func group(_ kind: SearchKind, _ names: [String], total: UInt32? = nil) -> SearchGroup {
        SearchGroup(kind: kind, total: total ?? UInt32(names.count), offset: 0, hits: names.map { hit($0) })
    }

    @Test func songsWithAMatchingTitleComeFirstInTheirOriginalOrder() {
        let results = SearchResults(
            groups: [group(.track, ["SKINNY", "Kill Bill", "LUNCH", "Billions"])],
            query: "bil"
        )

        #expect(results.hits(.track).map(\.name) == ["Kill Bill", "Billions", "SKINNY", "LUNCH"])
    }

    @Test func matchingIgnoresCaseDiacriticsAndSurroundingSpace() {
        let results = SearchResults(groups: [group(.artist, ["Beyoncé"])], query: "  BEYONCE ")

        #expect(results.top?.hit.name == "Beyoncé")
    }

    @Test func aMatchingArtistIsTheTopResultOverMatchingSongsAndAlbums() {
        let results = SearchResults(
            groups: [
                group(.track, ["Kill Bill"]),
                group(.album, ["Bill's Album"]),
                group(.artist, ["SZA", "Billie Eilish"]),
            ],
            query: "bil"
        )

        #expect(results.top == SearchTop(kind: .artist, hit: hit("Billie Eilish")))
    }

    @Test func withoutAMatchingArtistAMatchingAlbumThenSongWins() {
        let album = SearchResults(
            groups: [group(.track, ["Kill Bill"]), group(.album, ["Billboard"]), group(.artist, ["SZA"])],
            query: "bil"
        )
        let song = SearchResults(
            groups: [group(.track, ["Other", "Kill Bill"]), group(.album, ["SOS"]), group(.artist, ["SZA"])],
            query: "bil"
        )

        #expect(album.top?.hit.name == "Billboard")
        #expect(song.top == SearchTop(kind: .track, hit: hit("Kill Bill")))
    }

    @Test func withNoNameMatchTheFirstArtistAlbumOrPlaylistWins() {
        let artist = SearchResults(groups: [group(.artist, ["SZA"]), group(.album, ["SOS"])], query: "zz")
        let album = SearchResults(groups: [group(.album, ["SOS"]), group(.track, ["Kill Bill"])], query: "zz")
        let playlist = SearchResults(
            groups: [group(.artist, ["SZA"]), group(.playlist, ["Mix"]), group(.track, ["A"])],
            query: "zz"
        )
        let episode = SearchResults(groups: [group(.episode, ["Ep 1"])], query: "zz")

        #expect(artist.top?.kind == .artist)
        #expect(album.top?.kind == .album)
        #expect(playlist.top?.kind == .playlist)
        #expect(episode.top?.kind == .episode)
    }

    @Test func groupsFollowThePageOrderAndEmptyOnesAreDropped() {
        let results = SearchResults(
            groups: [group(.show, ["Pod"]), group(.album, ["A"]), group(.playlist, []), group(.track, ["T"])],
            query: "a"
        )

        #expect(results.groups.map(\.kind) == [.track, .album, .show])
        #expect(!results.isEmpty)
        #expect(SearchResults(groups: [group(.track, [])], query: "hj").isEmpty)
    }

    @Test func countsComeFromServerTotalsAndAnEmptyFilterFallsBackToAll() {
        let results = SearchResults(groups: [group(.track, ["T"], total: 11), group(.artist, ["A"])], query: "t")

        #expect(results.count(.track) == 11)
        #expect(results.count(.playlist) == 0)
        #expect(results.shown(.songs) == .songs)
        #expect(results.shown(.playlists) == .all)
        #expect(results.shown(.all) == .all)
    }
}
