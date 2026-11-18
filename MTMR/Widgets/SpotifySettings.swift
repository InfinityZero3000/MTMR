//
//  SpotifySettings.swift
//  MTMR
//
//  Look & behaviour options of the Spotify widget, edited live from the Settings window.
//  A value the user has changed overrides the preset (items.json); "Reset" goes back to the preset.
//

import Cocoa

extension Notification.Name {
    static let spotifySettingsChanged = Notification.Name("com.toxblh.mtmr.spotify.settingsChanged")
}

extension NSColor {
    /// "#RRGGBB" in sRGB.
    var hexRGB: String {
        guard let c = usingColorSpace(.sRGB) else { return "#FFFFFF" }
        return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }
}

final class SpotifySettings: ObservableObject {
    static let shared = SpotifySettings()

    static let defaultWaveColor = "#1DB954"
    static let defaultLyricColor = "#FFFFFF"

    private let defaults = UserDefaults.standard
    private func key(_ name: String) -> String { "com.toxblh.mtmr.spotify.\(name)" }

    /// Values from the preset file, used until the user overrides them here.
    private(set) var presetMode = "both"
    private(set) var presetReactive = true
    private(set) var presetOffset = 0.0

    private(set) var presetStyle = SpotifyStyle()

    func registerPreset(mode: String, reactive: Bool, offset: Double, style: SpotifyStyle = SpotifyStyle()) {
        presetMode = mode; presetReactive = reactive; presetOffset = offset; presetStyle = style
        objectWillChange.send()
    }

    private func change(_ name: String, _ value: Any?) {
        objectWillChange.send()
        if let value = value { defaults.set(value, forKey: key(name)) } else { defaults.removeObject(forKey: key(name)) }
        NotificationCenter.default.post(name: .spotifySettingsChanged, object: nil)
    }

    /// "both" | "lyrics" | "wave"
    var mode: String {
        get { defaults.string(forKey: key("mode")) ?? presetMode }
        set { change("mode", newValue) }
    }
    /// Wave follows the real Spotify audio (needs the System Audio permission).
    var reactive: Bool {
        get { defaults.object(forKey: key("reactive")) as? Bool ?? presetReactive }
        set { change("reactive", newValue) }
    }
    /// Seconds; positive shows lyrics earlier.
    var lyricsOffset: Double {
        get { defaults.object(forKey: key("offset")) as? Double ?? presetOffset }
        set { change("offset", newValue) }
    }
    /// Finger travel (points) needed to count as a swipe.
    var swipeDistance: Double {
        get { defaults.object(forKey: key("swipe")) as? Double ?? presetStyle.swipeDistance ?? 48 }
        set { change("swipe", newValue) }
    }
    var textSize: Double {
        get { defaults.object(forKey: key("textSize")) as? Double ?? presetStyle.textSize ?? 15 }
        set { change("textSize", newValue) }
    }
    var showIcon: Bool {
        get { defaults.object(forKey: key("showIcon")) as? Bool ?? presetStyle.showIcon ?? true }
        set { change("showIcon", newValue) }
    }
    /// Album cover instead of the Spotify app icon.
    var showArtwork: Bool {
        get { defaults.object(forKey: key("artwork")) as? Bool ?? true }
        set { change("artwork", newValue) }
    }
    /// What the widget rotates through while Spotify is not running: any of IdleInfoProvider.allIds; empty = nothing.
    var idleItems: [String] {
        get { defaults.string(forKey: key("idleItems")).map { $0.split(separator: ",").map(String.init) } ?? presetStyle.idleItems ?? ["clock", "battery", "weather"] }
        set { change("idleItems", newValue.joined(separator: ",")) }
    }
    /// Seconds each item stays before sliding to the next.
    var idleInterval: Double {
        get { defaults.object(forKey: key("idleInterval")) as? Double ?? presetStyle.idleInterval ?? 6 }
        set { change("idleInterval", newValue) }
    }
    var waveColorHex: String {
        get { defaults.string(forKey: key("waveColor")) ?? presetStyle.waveColor ?? Self.defaultWaveColor }
        set { change("waveColor", newValue) }
    }
    var lyricColorHex: String {
        get { defaults.string(forKey: key("lyricColor")) ?? presetStyle.lyricColor ?? Self.defaultLyricColor }
        set { change("lyricColor", newValue) }
    }

    var waveColor: NSColor { waveColorHex.hexColor ?? NSColor(srgbRed: 0.114, green: 0.725, blue: 0.329, alpha: 1) }
    var lyricColor: NSColor { lyricColorHex.hexColor ?? .white }

    func reset() {
        objectWillChange.send()
        for name in ["mode", "reactive", "offset", "swipe", "textSize", "showIcon", "artwork", "waveColor", "lyricColor", "idleItems", "idleInterval"] {
            defaults.removeObject(forKey: key(name))
        }
        NotificationCenter.default.post(name: .spotifySettingsChanged, object: nil)
    }
}
