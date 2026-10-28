import Foundation

/**
 * Picks the right song out of catalog search results. Used when the host's
 * song has no catalog ID or ISRC we can look up directly (for example a song
 * the host uploaded to their library, or one that has a different ID in the
 * guest's country).
 */
public enum TrackMatcher {
    public struct Candidate: Sendable {
        public var title: String
        public var artist: String
        /** Seconds. */
        public var duration: Double?

        public init(title: String, artist: String, duration: Double?) {
            self.title = title
            self.artist = artist
            self.duration = duration
        }
    }

    /** The search text to send to the catalog for `track`. */
    public static func searchTerm(for track: Track) -> String {
        "\(normalize(track.title)) \(normalize(primaryArtist(track.artist)))"
    }

    /** Index of the best match in `candidates`, or nil if none is convincing. */
    public static func bestMatch(for track: Track, in candidates: [Candidate]) -> Int? {
        var best: (index: Int, score: Double)?
        for (index, candidate) in candidates.enumerated() {
            let score = score(track, candidate)
            if score > (best?.score ?? 0) { best = (index, score) }
        }
        guard let best, best.score >= 0.7 else { return nil }
        return best.index
    }

    /** 0...1. Title matters most, then artist, then a duration sanity check. */
    static func score(_ track: Track, _ candidate: Candidate) -> Double {
        let title = normalize(track.title)
        let candidateTitle = normalize(candidate.title)
        var score = 0.0

        if title == candidateTitle {
            score += 0.5
        } else if !title.isEmpty, !candidateTitle.isEmpty, candidateTitle.contains(title) || title.contains(candidateTitle) {
            score += 0.3
        } else {
            return 0
        }

        let artist = normalize(primaryArtist(track.artist))
        let candidateArtist = normalize(candidate.artist)
        if artist == normalize(primaryArtist(candidate.artist)) {
            score += 0.35
        } else if !artist.isEmpty, candidateArtist.contains(artist) || artist.contains(candidateArtist) {
            score += 0.25
        }

        if let a = track.duration, let b = candidate.duration {
            let diff = abs(a - b)
            if diff <= 3 { score += 0.15 } else if diff > 20 { score -= 0.3 }
        } else {
            score += 0.05
        }
        return score
    }

    /** "Song (feat. X) - 2011 Remaster" -> "song". Lowercased, no accents or punctuation. */
    public static func normalize(_ text: String) -> String {
        var value = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        value = value.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\s+-\s+.*$"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: "&", with: " and ")
        value = value.replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
        return value.split(separator: " ").joined(separator: " ")
    }

    /** "ABBA, X & Y" -> "ABBA". */
    static func primaryArtist(_ artist: String) -> String {
        let separators = [",", " & ", " feat. ", " ft. ", " featuring ", " x ", " with "]
        var value = artist
        for separator in separators {
            if let range = value.range(of: separator, options: .caseInsensitive) {
                value = String(value[..<range.lowerBound])
            }
        }
        return value
    }
}
