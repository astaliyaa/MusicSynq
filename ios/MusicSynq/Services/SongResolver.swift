import MusicKit
import MusicSynqKit

/**
 * Finds the host's song in this device's Apple Music catalog. Friends in
 * different countries have different catalogs, so we try, in order: the same
 * catalog ID, the recording's ISRC, and finally a title/artist search.
 */
enum SongResolver {
    static func song(for track: TrackInfo) async -> Song? {
        if let id = track.catalogId, !id.isEmpty {
            let request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(id))
            if let song = try? await request.response().items.first {
                return song
            }
        }

        if let isrc = track.isrc, !isrc.isEmpty {
            let request = MusicCatalogResourceRequest<Song>(matching: \.isrc, equalTo: isrc)
            if let songs = try? await request.response().items, !songs.isEmpty {
                // One recording can appear on several albums; prefer the closest match.
                let candidates = songs.map { TrackMatcher.Candidate(title: $0.title, artist: $0.artistName, duration: $0.duration) }
                let index = TrackMatcher.bestMatch(for: track, in: candidates) ?? 0
                return songs[index]
            }
        }

        var search = MusicCatalogSearchRequest(term: TrackMatcher.searchTerm(for: track), types: [Song.self])
        search.limit = 15
        guard let songs = try? await search.response().songs, !songs.isEmpty else { return nil }
        let candidates = songs.map { TrackMatcher.Candidate(title: $0.title, artist: $0.artistName, duration: $0.duration) }
        guard let index = TrackMatcher.bestMatch(for: track, in: candidates) else { return nil }
        return songs[index]
    }

    /** Extra details the host shares for its current song: the ISRC and an artwork link. */
    static func details(forCatalogID id: String) async -> (isrc: String?, artworkURL: String?)? {
        let request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(id))
        guard let song = try? await request.response().items.first else { return nil }
        let artwork = song.artwork?.url(width: 600, height: 600)?.absoluteString
        // Only web links are useful to friends; library artwork uses a private URL scheme.
        return (song.isrc, artwork?.hasPrefix("https://") == true ? artwork : nil)
    }
}
