//
//  LyricsProvider.swift
//  MTMR
//
//  LRC parsing + LRCLIB client (https://lrclib.net, no auth).
//

import Foundation

// MARK: - Lyrics (LRC parsing + LRCLIB client)

struct LyricLine: Equatable {
    let time: TimeInterval
    let text: String
}

enum LRCParser {
    /// Parses "[mm:ss.xx] text" lines. Supports multiple stamps per line, skips metadata tags.
    static func parse(_ lrc: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        var offset: TimeInterval = 0 // "[offset:+500]": positive = lyrics appear sooner
        for raw in lrc.split(whereSeparator: \.isNewline) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if trimmed.hasPrefix("[offset:"), let close = trimmed.firstIndex(of: "]"),
               let ms = Double(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 8) ..< close].trimmingCharacters(in: .whitespaces)) {
                offset = ms / 1000
                continue
            }
            var rest = Substring(raw)
            var stamps: [TimeInterval] = []
            while rest.first == "[", let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex) ..< close]
                rest = rest[rest.index(after: close)...]
                let parts = tag.split(separator: ":")
                if parts.count == 2, let m = Double(parts[0]), let s = Double(parts[1]) {
                    stamps.append(m * 60 + s)
                }
            }
            let text = rest.trimmingCharacters(in: .whitespaces)
            for t in stamps { lines.append(LyricLine(time: t, text: text)) }
        }
        return lines.map { LyricLine(time: max(0, $0.time - offset), text: $0.text) }.sorted { $0.time < $1.time }
    }

    /// Index of the line being sung at `position` (nil before the first line).
    static func index(in lines: [LyricLine], at position: TimeInterval) -> Int? {
        var lo = 0, hi = lines.count - 1, found: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].time <= position { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return found
    }
}

final class LyricsProvider {
    static let shared = LyricsProvider()

    private var cache: [String: [LyricLine]] = [:] // empty array = known miss
    private var inFlight = Set<String>()
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        cfg.httpAdditionalHeaders = ["User-Agent": "MTMR (https://github.com/Toxblh/MTMR)"]
        return URLSession(configuration: cfg)
    }()

    private func key(_ artist: String, _ title: String) -> String { "\(artist)\u{1}\(title)".lowercased() }

    /// Cached result: nil = not fetched yet, [] = no synced lyrics available.
    func cached(artist: String, title: String) -> [LyricLine]? { cache[key(artist, title)] }

    func fetch(artist: String, title: String, album: String, duration: TimeInterval, completion: @escaping () -> Void) {
        let k = key(artist, title)
        guard cache[k] == nil, !inFlight.contains(k) else { return }
        inFlight.insert(k)

        var comps = URLComponents(string: "https://lrclib.net/api/get")!
        comps.queryItems = [
            .init(name: "artist_name", value: artist),
            .init(name: "track_name", value: title),
            .init(name: "album_name", value: album),
            .init(name: "duration", value: String(Int(duration.rounded()))),
        ]
        request(comps.url!) { [weak self] results in
            if let lrc = Self.bestLyrics(results, duration: duration, tolerance: 3) { return self?.finish(k, lrc, completion) ?? () }
            // Exact match failed (album/duration mismatch): search, then pick the version whose length matches the track,
            // because a different edit/remaster has different timestamps.
            var s = URLComponents(string: "https://lrclib.net/api/search")!
            s.queryItems = [.init(name: "track_name", value: title), .init(name: "artist_name", value: artist)]
            self?.request(s.url!) { results in
                self?.finish(k, Self.bestLyrics(results, duration: duration, tolerance: 6) ?? "", completion)
            }
        }
    }

    private func finish(_ k: String, _ lrc: String, _ completion: @escaping () -> Void) {
        let lines = LRCParser.parse(lrc)
        DispatchQueue.main.async {
            self.cache[k] = lines
            self.inFlight.remove(k)
            completion()
        }
    }

    /// Synced lyrics of the result whose duration is closest to `duration` (within `tolerance` seconds when known).
    static func bestLyrics(_ results: [[String: Any]], duration: TimeInterval, tolerance: TimeInterval) -> String? {
        let candidates = results.compactMap { r -> (lrc: String, diff: Double)? in
            guard let lrc = r["syncedLyrics"] as? String, !lrc.isEmpty else { return nil }
            let d = (r["duration"] as? Double) ?? duration
            return (lrc, duration > 0 ? abs(d - duration) : 0)
        }
        guard let best = candidates.min(by: { $0.diff < $1.diff }), best.diff <= tolerance else { return nil }
        return best.lrc
    }

    private func request(_ url: URL, _ done: @escaping ([[String: Any]]) -> Void) {
        session.dataTask(with: url) { data, response, _ in
            guard let data = data, (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) else { return done([]) }
            done((json as? [[String: Any]]) ?? [json as? [String: Any]].compactMap { $0 })
        }.resume()
    }
}
