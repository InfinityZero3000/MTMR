//
//  SpotifyBarItem.swift
//  MTMR
//
//  Spotify widget: synced lyrics (LRCLIB, no auth) + smooth animated sine wave.
//  Reads track/position via ScriptingBridge (same Automation permission as `music`).
//  Lyrics logic lives in LyricsProvider.swift.
//

import Cocoa
import ScriptingBridge

// MARK: - Lyric text view (Core Animation: GPU-driven crossfade + pixel-smooth scrolling)

/// Shows one line of text. A new line crossfades in while sliding up; a line wider than the view scrolls
/// by pixels (position animation, no per-frame layout). Edges fade out so scrolling text never hard-clips.
final class LyricTextView: NSView {
    private var font = NSFont.systemFont(ofSize: 15, weight: .regular)
    private var current: CALayer?
    private var currentKey = ""
    private let edgeMask = CAGradientLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        edgeMask.startPoint = CGPoint(x: 0, y: 0.5)
        edgeMask.endPoint = CGPoint(x: 1, y: 0.5)
        edgeMask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        layer?.mask = edgeMask
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        edgeMask.frame = bounds
        let f = NSNumber(value: Double(min(0.25, 14 / max(bounds.width, 1))))
        edgeMask.locations = [0, f, NSNumber(value: 1 - f.doubleValue), 1]
        CATransaction.commit()
    }

    /// Quick nudge of the current line in the swipe direction, as feedback that the swipe was recognized.
    func flick(dx: CGFloat) {
        guard let l = current else { return }
        let move = CAKeyframeAnimation(keyPath: "transform.translation.x")
        move.values = [0, dx, 0]
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1, 0.3, 1]
        for a in [move, fade] { a.keyTimes = [0, 0.4, 1] }
        let group = CAAnimationGroup()
        group.animations = [move, fade]
        group.duration = 0.4
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        l.add(group, forKey: "flick")
    }

    func setFontSize(_ size: CGFloat) {
        guard abs(size - font.pointSize) > 0.01 else { return }
        font = NSFont.systemFont(ofSize: size, weight: .regular)
        reset()
    }

    /// Forces the next `show` to rebuild the line (after the available width changed).
    func reset() { currentKey = "" }

    /// `scrollDuration`: seconds for one pass across an overflowing line (nil = ping-pong at a reading pace).
    /// `symbol`: optional SF Symbol drawn before the text (or alone when `text` is empty).
    func show(_ text: String, symbol: String? = nil, animated: Bool = false, color: NSColor, scrollDuration: TimeInterval?) {
        guard bounds.width > 0 else { return } // not laid out yet; the next tick retries
        let key = "\(text)|\(symbol ?? "")|\(animated)|\(color.hashValue)"
        guard key != currentKey else { return }
        currentKey = key

        let old = current
        current = nil
        if !text.isEmpty || symbol != nil { current = makeLayer(text, symbol: symbol, animated: animated, color: color, scrollDuration: scrollDuration) }

        let move: CFTimeInterval = 0.35
        let ease = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1) // expo-out
        if let new = current {
            layer?.addSublayer(new)
            if old != nil { // slide up + fade in; first appearance just fades
                fade(new, from: 0, to: 1, dy: -7, duration: move, timing: ease)
            } else {
                fade(new, from: 0, to: 1, dy: 0, duration: 0.25, timing: ease)
            }
        }
        if let old = old {
            old.removeAllAnimations()
            CATransaction.begin()
            CATransaction.setCompletionBlock { old.removeFromSuperlayer() }
            fade(old, from: 1, to: 0, dy: 7, duration: move * 0.7, timing: ease, keep: true)
            CATransaction.commit()
        }
    }

    private func fade(_ l: CALayer, from: Float, to: Float, dy: CGFloat, duration: CFTimeInterval, timing: CAMediaTimingFunction, keep: Bool = false) {
        let o = CABasicAnimation(keyPath: "opacity")
        o.fromValue = from; o.toValue = to
        let y = CABasicAnimation(keyPath: "transform.translation.y")
        y.fromValue = dy; y.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [o, y]
        group.duration = duration
        group.timingFunction = timing
        group.fillMode = .both
        group.isRemovedOnCompletion = !keep
        l.opacity = to
        l.add(group, forKey: "enter")
    }

    private func makeLayer(_ text: String, symbol: String?, animated: Bool, color: NSColor, scrollDuration: TimeInterval?) -> CALayer {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let height = ceil(font.ascender - font.descender) + 2
        let textWidth = text.isEmpty ? 0 : ceil((text as NSString).size(withAttributes: [.font: font]).width) + 2
        let icon = symbol.flatMap { NSImage.touchBarSymbol($0, pointSize: 16, color: color) }
        // Icon alone while the music plays = "instrumental": show 1, 2, 3 notes in turn so it visibly lives.
        let noteCount = (icon != nil && text.isEmpty && animated) ? 3 : 1
        let noteGap: CGFloat = 3
        let singleWidth = icon?.size.width ?? 0
        let iconWidth = singleWidth * CGFloat(noteCount) + noteGap * CGFloat(noteCount - 1)
        let gap: CGFloat = (icon != nil && textWidth > 0) ? 6 : 0
        let width = iconWidth + gap + textWidth
        let available = bounds.width

        // One container per line, so the icon and the text move, fade and scroll together.
        let l = CALayer()
        l.anchorPoint = CGPoint(x: 0, y: 0.5)
        l.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        if let icon = icon, let cg = icon.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let start = CACurrentMediaTime()
            let cycle: CFTimeInterval = 2.6
            for k in 0 ..< noteCount {
                let i = CALayer()
                i.contents = cg
                i.contentsScale = scale
                i.frame = CGRect(x: CGFloat(k) * (singleWidth + noteGap), y: (height - icon.size.height) / 2, width: icon.size.width, height: icon.size.height)
                l.addSublayer(i)
                guard animated else { continue }

                if noteCount > 1 {
                    // 1st, 2nd, 3rd note pop in, hold together, fade out, short pause, repeat.
                    let appear = 0.08 + 0.17 * Double(k)
                    let seq = CAKeyframeAnimation(keyPath: "opacity")
                    seq.values = [0, 0, 1, 1, 0, 0]
                    seq.keyTimes = [0, appear, appear + 0.06, 0.80, 0.90, 1.0].map { NSNumber(value: $0) }
                    seq.duration = cycle
                    seq.repeatCount = .infinity
                    seq.beginTime = start
                    i.opacity = 0
                    i.add(seq, forKey: "sequence")
                } else {
                    let pulse = CAKeyframeAnimation(keyPath: "opacity")
                    pulse.values = [1, 0.45, 1]
                    pulse.duration = 1.6
                    pulse.repeatCount = .infinity
                    pulse.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .easeInEaseOut)]
                    i.add(pulse, forKey: "pulse")
                }
                // Gentle bob, each note a little later than the previous one.
                let bob = CAKeyframeAnimation(keyPath: "transform.translation.y")
                bob.values = [0, 3, 0]
                bob.duration = 0.9
                bob.repeatCount = .infinity
                bob.beginTime = start + Double(k) * 0.12
                bob.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .easeInEaseOut)]
                i.add(bob, forKey: "bob")
            }
        }
        if textWidth > 0 {
            let t = CATextLayer()
            t.string = text
            t.font = font
            t.fontSize = font.pointSize
            t.foregroundColor = color.cgColor
            t.alignmentMode = .left
            t.truncationMode = .none
            t.isWrapped = false
            t.contentsScale = scale
            t.frame = CGRect(x: iconWidth + gap, y: 0, width: textWidth, height: height)
            l.addSublayer(t)
        }
        let overflow = width - available
        let startX = overflow > 0 ? 0 : (available - width) / 2 // centered when it fits
        l.position = CGPoint(x: startX, y: bounds.midY + 1)

        if overflow > 0 {
            let a = CABasicAnimation(keyPath: "position.x")
            a.fromValue = startX
            a.toValue = startX - overflow
            a.fillMode = .both
            a.isRemovedOnCompletion = false
            if let d = scrollDuration {
                a.duration = max(1.2, d)
                a.beginTime = CACurrentMediaTime() + 0.5 // let the eye land on the line first
                a.timingFunction = CAMediaTimingFunction(name: .linear)
            } else {
                a.duration = Double(overflow) / 28
                a.beginTime = CACurrentMediaTime() + 1.2
                a.autoreverses = true
                a.repeatCount = .infinity
                a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            }
            l.add(a, forKey: "scroll")
        }
        return l
    }
}

/// Spotify app icon, then the wave, then lyric text filling the remaining width.
/// Never intercepts touches (the button underneath does).
final class SpotifyContentView: NSView {
    static let iconSize: CGFloat = 22
    /// The album cover fills the whole Touch Bar height, like the Dock icons.
    static let artworkSize: CGFloat = 30
    private var hasArtwork = false
    private var iconHeight: NSLayoutConstraint!
    private var currentIconSize: CGFloat { hasArtwork ? Self.artworkSize : Self.iconSize }
    static let waveWidth: CGFloat = 44
    private static let gap: CGFloat = 6
    let iconView = NSImageView()
    let waveView = NSImageView()
    let lyricView = LyricTextView(frame: .zero)
    private var lyricLeading: NSLayoutConstraint!
    private var iconWidth: NSLayoutConstraint!
    private var waveLeading: NSLayoutConstraint!
    private var iconVisible = true
    /// Shown when there is no album cover (or covers are turned off).
    var fallbackIcon: NSImage?
    private var waveVisible = true
    private var idle = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        waveView.imageScaling = .scaleNone
        iconView.imageScaling = .scaleProportionallyUpOrDown
        fallbackIcon = Self.spotifyIcon()
        iconView.image = fallbackIcon
        iconView.wantsLayer = true
        iconView.layer?.masksToBounds = true
        for v in [iconView, waveView, lyricView] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        lyricLeading = lyricView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8)
        iconWidth = iconView.widthAnchor.constraint(equalToConstant: Self.iconSize)
        iconHeight = iconView.heightAnchor.constraint(equalToConstant: Self.iconSize)
        waveLeading = waveView.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: Self.gap)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconWidth,
            iconHeight,
            waveLeading,
            waveView.centerYAnchor.constraint(equalTo: centerYAnchor),
            waveView.widthAnchor.constraint(equalToConstant: Self.waveWidth),
            waveView.heightAnchor.constraint(equalToConstant: 22),
            lyricLeading,
            lyricView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            lyricView.topAnchor.constraint(equalTo: topAnchor),
            lyricView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The Spotify app icon (like the other Dock-style widgets), or a music note if Spotify is not installed.
    private static func spotifyIcon() -> NSImage? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)
    }

    /// Album cover with softly rounded corners instead of the app icon; nil restores the app icon.
    func setArtwork(_ image: NSImage?) {
        let had = hasArtwork
        hasArtwork = image != nil
        iconView.layer?.cornerRadius = hasArtwork ? 5 : 0
        if had != hasArtwork { relayout() }
        let new = image ?? fallbackIcon
        guard iconView.image !== new else { return }
        let fade = CATransition(); fade.type = .fade; fade.duration = 0.3
        iconView.layer?.add(fade, forKey: "artwork")
        iconView.image = new
    }

    func setWaveVisible(_ visible: Bool) { waveVisible = visible; relayout() }
    func setIconVisible(_ visible: Bool) { iconVisible = visible; relayout() }
    /// Spotify is not running: no Spotify icon, no wave, the text area takes the whole width.
    func setIdle(_ value: Bool) {
        guard value != idle else { return }
        idle = value
        relayout()
    }

    private func relayout() {
        let showIcon = iconVisible && !idle
        let showWave = waveVisible && !idle
        waveView.isHidden = !showWave
        iconView.isHidden = !showIcon
        iconWidth.constant = showIcon ? currentIconSize : 0
        iconHeight.constant = currentIconSize
        waveLeading.constant = showIcon ? Self.gap : 0
        let iconEnd = 4 + (showIcon ? currentIconSize + Self.gap : 0)
        lyricLeading.constant = showWave ? iconEnd + Self.waveWidth + 8 : (idle ? 8 : iconEnd + 2)
        layoutSubtreeIfNeeded()
        lyricView.reset() // the available width changed
    }
}

// MARK: - Bar item

final class SpotifyBarItem: CustomButtonTouchBarItem {
    enum Mode: String { case both, lyrics, wave
        var next: Mode { switch self { case .both: return .lyrics; case .lyrics: return .wave; case .wave: return .both } }
    }

    private static let bundleId = "com.spotify.client"
    private static let waveSize = NSSize(width: 44, height: 22)

    private var mode: Mode
    private let fps = 30.0
    private var timer: Timer?
    private var tickCount = 0
    private var phase = 0.0
    private var bandAmp = [0.0, 0.0, 0.0] // eased bass/mid/high energy, so the layers swell and settle instead of snapping
    private var audioTap: AudioLevelSource?
    private var settingsObserver: NSObjectProtocol?
    private var tapFailures = 0
    private enum Automation { case unknown, granted, denied }
    private var automation = Automation.unknown
    private var askingAutomation = false
    private var swipeFired = false
    private var suppressTapsUntil = Date.distantPast
    private var lastAutomationCheck = Date.distantPast
    private var lastReported = -1.0
    /// Lines are shown slightly early: the crossfade takes ~0.35 s to settle and reading needs a moment.
    private static let displayLead: TimeInterval = 0.25
    private var running = false
    private let content = SpotifyContentView()

    private var artist = "", name = "", album = "", duration: TimeInterval = 0
    private var playing = false
    private var syncedPosition: TimeInterval = 0
    private var syncedAt = Date()
    private var lines: [LyricLine] = []
    private var artworkURL = ""
    private var artworkImage: NSImage?
    private static var artworkCache: [String: NSImage] = [:]

    /// A preset "image" replaces the default Spotify app icon; the button itself stays image-free.
    override var image: NSImage? {
        didSet {
            guard let custom = image else { return }
            content.fallbackIcon = custom
            if artworkImage == nil { content.iconView.image = custom }
            super.image = nil // through the base setter, so the button really drops it
        }
    }

    init(identifier: NSTouchBarItem.Identifier, mode: Mode, reactive: Bool = true, lyricsOffset: TimeInterval = 0, style: SpotifyStyle = SpotifyStyle()) {
        self.mode = mode
        SpotifySettings.shared.registerPreset(mode: mode.rawValue, reactive: reactive, offset: lyricsOffset, style: style)
        super.init(identifier: identifier, attributedTitle: .symbolText("music.note"))
        isBordered = false
        actions = [
            ItemAction(trigger: .singleTap) { [weak self] in
                guard let self = self, Date() > self.suppressTapsUntil else { return }
                if !self.running { self.advanceIdle(); return } // Spotify closed: tap = next info
                guard !self.openSettingsIfDenied() else { return }
                self.app()?.playpause?()
            },
            ItemAction(trigger: .doubleTap) { [weak self] in
                guard let self = self, Date() > self.suppressTapsUntil else { return }
                self.cycleMode()
            },
            ItemAction(trigger: .longTap) { [weak self] in
                guard let self = self, Date() > self.suppressTapsUntil, !self.openSettingsIfDenied() else { return }
                self.skip(forward: true)
            },
        ]
        finishViewConfiguration = { [weak self] in self?.attachContent() } // the button is rebuilt when e.g. "bordered" is applied
        attachContent()
        applySettings()
        settingsObserver = NotificationCenter.default.addObserver(forName: .spotifySettingsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.applySettings()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1 / fps, repeats: true) { [weak self] _ in self?.onTick() }
        timer?.tolerance = 0.005
        poll()
    }

    required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        timer?.invalidate()
        audioTap?.stop()
        if let o = settingsObserver { NotificationCenter.default.removeObserver(o) }
    }

    /// Applies the values from the Settings window (or the preset) to the running widget.
    private func applySettings() {
        let s = SpotifySettings.shared
        mode = Mode(rawValue: s.mode) ?? .both
        content.setWaveVisible(mode != .lyrics)
        content.setIconVisible(s.showIcon)
        if !artworkURL.isEmpty || artworkImage != nil { loadArtwork(artworkURL) } // artwork toggled
        content.lyricView.setFontSize(CGFloat(s.textSize))
        if s.reactive {
            if audioTap == nil { audioTap = makeSpotifyAudioTap(); tapFailures = 0 }
        } else {
            audioTap?.stop()
            audioTap = nil
        }
        content.layoutSubtreeIfNeeded()
        content.lyricView.reset()
    }

    private func attachContent() {
        guard content.superview !== view else { return }
        content.removeFromSuperview()
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        // Default size when the preset gives no "width" (an explicit width constraint outranks this one).
        let defaultWidth = view.widthAnchor.constraint(equalToConstant: 420)
        defaultWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            defaultWidth,
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.topAnchor.constraint(equalTo: view.topAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        attributedTitle = NSAttributedString() // text is drawn by `content`, the button only handles touches
        image = nil
        content.setWaveVisible(mode != .lyrics)

        let pan = NSPanGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
        pan.allowedTouchTypes = .direct
        failureExemptRecognizers.append(pan)
        view.addGestureRecognizer(pan)
    }

    /// Swipe left = next track, swipe right = previous track. Fires as soon as the finger has moved far enough.
    @objc private func handleSwipe(_ g: NSPanGestureRecognizer) {
        switch g.state {
        case .began:
            swipeFired = false
        case .changed:
            guard !swipeFired else { return }
            let dx = g.translation(in: g.view).x
            guard abs(dx) > CGFloat(SpotifySettings.shared.swipeDistance) else { return }
            swipeFired = true
            suppressTapsUntil = Date().addingTimeInterval(0.6) // the touch must not also count as a tap
            if openSettingsIfDenied() { return }
            content.lyricView.flick(dx: dx < 0 ? -28 : 28)
            skip(forward: dx < 0)
        default:
            break
        }
    }

    private func skip(forward: Bool) {
        guard let a = app() else { return }
        if forward {
            a.nextTrack?()
        } else {
            // Spotify's "previous" only restarts the track after the first few seconds; press twice to really go back.
            let late = (a.playerPosition ?? 0) > 3
            a.previousTrack?()
            if late {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.app()?.previousTrack?() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.poll() }
    }

    /// Apple Events to Spotify need the Automation permission. Without it every call silently returns nothing,
    /// so ask explicitly (once) and keep checking quietly in case the user enables it in System Settings later.
    private func checkAutomation() {
        guard automation != .granted, !askingAutomation, Date().timeIntervalSince(lastAutomationCheck) > 3 else { return }
        askingAutomation = true
        lastAutomationCheck = Date()
        let prompt = automation == .unknown
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let target = NSAppleEventDescriptor(bundleIdentifier: Self.bundleId)
            var status = OSStatus(procNotFound)
            if let desc = target.aeDesc {
                status = AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, prompt)
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.askingAutomation = false
                switch status {
                case noErr: self.automation = .granted
                case OSStatus(errAEEventNotPermitted): self.automation = .denied
                case OSStatus(errAEEventWouldRequireUserConsent): break // not asked yet; the next check prompts
                default: break // e.g. Spotify not running: try again later
                }
            }
        }
    }

    /// Returns true (and opens System Settings) when the permission is missing, so taps do something useful.
    private func openSettingsIfDenied() -> Bool {
        guard running, automation == .denied else { return false }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
        return true
    }

    private func app() -> (SpotifyApplication & SpotifyPlayback)? {
        guard let a = SBApplication(bundleIdentifier: Self.bundleId), a.isRunning else { return nil }
        a.timeout = 60 // a stuck Spotify must not block the Touch Bar for the default two minutes
        return a
    }

    /// Double tap: temporary switch (until the next launch or Settings change). It is not saved on purpose, so an
    /// accidental double tap can never leave the widget stuck in wave-only mode without lyrics.
    private func cycleMode() {
        mode = mode.next
        content.setWaveVisible(mode != .lyrics)
        content.lyricView.reset()
    }

    private func onTick() {
        tickCount += 1
        if tickCount % Int(fps / 2) == 0 { poll() } // resync with Spotify twice per second, extrapolate in between
        render()
    }

    private struct Snapshot {
        var artist = "", name = "", album = "", artworkUrl = ""
        var duration = 0 // ms
        var state = 0
        var position: TimeInterval = 0
        var sampledAt = Date()
    }

    /// Spotify is read on a background queue with a short Apple Event timeout: a busy, hung or quitting Spotify
    /// must never freeze the Touch Bar (a synchronous Apple Event can block for minutes).
    private let pollQueue = DispatchQueue(label: "mtmr.spotify.poll", qos: .userInitiated)
    private var polling = false
    private var readerApp: (SpotifyApplication & SpotifyPlayback)? // pollQueue only

    private func readSnapshot() -> Snapshot? {
        if readerApp == nil, let sb = SBApplication(bundleIdentifier: Self.bundleId) {
            sb.timeout = 60 // ticks = 1 s
            readerApp = sb
        }
        guard let a = readerApp else { return nil }
        let before = Date()
        var snap = Snapshot()
        let track = a.currentTrack
        snap.artist = track?.artist ?? ""
        snap.name = track?.name ?? ""
        let extra = track as? SpotifyTrackDetails
        snap.album = extra?.album ?? ""
        snap.duration = extra?.duration ?? 0
        snap.artworkUrl = extra?.artworkUrl ?? ""
        snap.state = a.playerState ?? 0
        snap.position = a.playerPosition ?? 0
        // The answer describes the moment halfway through the (blocking) Apple Event round trip.
        snap.sampledAt = Date(timeIntervalSince1970: (before.timeIntervalSince1970 + Date().timeIntervalSince1970) / 2)
        return snap
    }

    private func poll() {
        // Quit detection does not need Apple Events: ask the system directly, so it is instant and never blocks.
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleId).isEmpty else {
            running = false; playing = false; name = ""; artist = ""; lines = []; audioTap?.stop()
            return
        }
        running = true
        checkAutomation()
        if automation == .denied { return } // nothing readable; render() explains how to fix it
        guard !polling else { return }
        polling = true
        pollQueue.async { [weak self] in
            let snap = self?.readSnapshot()
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.polling = false
                if let snap = snap, self.running { self.apply(snap) }
            }
        }
    }

    private func apply(_ snap: Snapshot) {
        let newArtist = snap.artist, newName = snap.name
        let nowPlaying = snap.state == 0x6b505350 // 'kPSP'
        syncClock(reported: snap.position, at: snap.sampledAt, nowPlaying: nowPlaying)
        playing = nowPlaying

        updateAudioTap()

        if newArtist != artist || newName != name {
            artist = newArtist; name = newName
            tapFailures = 0
            album = snap.album
            loadArtwork(snap.artworkUrl)
            duration = Double(snap.duration) / 1000
            lines = LyricsProvider.shared.cached(artist: artist, title: name) ?? []
            if !name.isEmpty {
                LyricsProvider.shared.fetch(artist: artist, title: name, album: album, duration: duration) { [weak self] in
                    guard let self = self else { return }
                    self.lines = LyricsProvider.shared.cached(artist: self.artist, title: self.name) ?? []
                }
            }
        }
    }

    /// Album cover from the track's public artwork URL, cached per URL; falls back to the app icon on any failure.
    private func loadArtwork(_ urlString: String) {
        artworkURL = urlString
        guard SpotifySettings.shared.showArtwork, !urlString.isEmpty, let url = URL(string: urlString) else {
            artworkImage = nil; content.setArtwork(nil); return
        }
        if let cached = Self.artworkCache[urlString] { artworkImage = cached; content.setArtwork(cached); return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            let image = data.flatMap { NSImage(data: $0) }
            DispatchQueue.main.async {
                guard let self = self, self.artworkURL == urlString, let image = image else { return }
                if Self.artworkCache.count > 30 { Self.artworkCache.removeAll() }
                Self.artworkCache[urlString] = image
                self.artworkImage = image
                self.content.setArtwork(image)
            }
        }.resume()
    }

    /// Listen to Spotify's audio only while it is playing; give up quietly after a few failed attempts.
    private func updateAudioTap() {
        guard let tap = audioTap else { return }
        if playing {
            if !tap.isRunning, tapFailures < 5, !tap.start() { tapFailures += 1 }
        } else if tap.isRunning {
            tap.stop()
        }
    }

    /// Target energy (0...1) for the three wave layers: real audio when available, otherwise a gentle simulation.
    private func waveTargets() -> [Double] {
        guard playing else { return [0, 0, 0] }
        if let tap = audioTap, tap.isRunning, Date().timeIntervalSince(tap.lastSignal) < 4 {
            let l = tap.levels
            return [Double(l.bass), Double(l.mid), Double(l.high)].map { 0.1 + 0.9 * $0 } // never fully flat while playing
        }
        return [1, 0.7 + 0.3 * sin(phase * 0.5), 0.5 + 0.3 * sin(phase * 0.8)]
    }

    /// Keeps a steady local clock and only nudges it toward Spotify's value. Spotify's `player position` is
    /// often stale by up to ~1 s, so snapping to every sample made the lyrics jump back and forth.
    private func syncClock(reported: TimeInterval, at t: Date, nowPlaying: Bool) {
        defer { lastReported = reported }
        guard nowPlaying, playing else { syncedPosition = reported; syncedAt = t; return } // paused, or just resumed
        let expected = syncedPosition + t.timeIntervalSince(syncedAt)
        let diff = reported - expected
        if abs(diff) > 1.0 { // seek or track change: jump
            syncedPosition = reported; syncedAt = t
        } else if reported != lastReported, abs(diff) > 0.03 { // fresh value: move a third of the way
            syncedPosition = expected + diff * 0.35; syncedAt = t
        }
        // reported == lastReported means Spotify returned a stale value: keep our own clock.
    }

    /// Playback position used to pick the lyric line.
    private var position: TimeInterval {
        (playing ? syncedPosition + Date().timeIntervalSince(syncedAt) : syncedPosition) + SpotifySettings.shared.lyricsOffset + Self.displayLead
    }

    // MARK: rendering

    /// Layered sine waves with a tapered envelope (flat at both ends), drawn vector so it stays crisp on Retina.
    private func waveImage() -> NSImage {
        let amps = bandAmp, ph = phase, waveColor = SpotifySettings.shared.waveColor
        return NSImage(size: Self.waveSize, flipped: false) { rect in
            let mid = rect.midY, maxA = rect.height / 2 - 1.5
            let layers: [(freq: Double, speed: Double, gain: Double, alpha: CGFloat, width: CGFloat)] = [
                (1.6, 1.0, 1.00, 1.00, 2.0),
                (2.4, -1.4, 0.65, 0.55, 1.5),
                (3.3, 0.7, 0.40, 0.30, 1.2),
            ]
            for (i, l) in layers.enumerated() {
                let amp = amps[i]
                let path = NSBezierPath()
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                var x = 1.0
                while x <= rect.width - 1 {
                    let u = x / rect.width
                    let envelope = sin(.pi * u) // 0 at the edges, 1 in the middle
                    let y = mid + sin(u * .pi * 2 * l.freq + ph * l.speed) * maxA * l.gain * envelope * amp
                    x == 1.0 ? path.move(to: NSPoint(x: x, y: y)) : path.line(to: NSPoint(x: x, y: y))
                    x += 1
                }
                path.lineWidth = l.width
                waveColor.withAlphaComponent(l.alpha).setStroke()
                path.stroke()
            }
            return true
        }
    }

    /// The text to show now, plus how long a long line should take to scroll (nil = no timing info).
    private func displayLine() -> (text: String, symbol: String?, scroll: TimeInterval?) {
        if mode == .wave { return (name, nil, nil) }
        // No synced lyrics for this track: note icon + "Artist — Title".
        guard !lines.isEmpty else { return ("\(artist) — \(name)", "music.note", nil) }
        // Before the first line, or an empty line (instrumental break): just the note icon.
        guard let i = LRCParser.index(in: lines, at: position), !lines[i].text.isEmpty else { return ("", "music.note", nil) }
        let end = i + 1 < lines.count ? lines[i + 1].time : lines[i].time + 4
        return (lines[i].text, nil, (end - lines[i].time) * 0.85 - 0.5)
    }

    // MARK: idle info (Spotify not running)

    private var idleIndex = 0
    private var idleSince = Date()
    private var wasIdle = false

    private func advanceIdle() {
        idleIndex += 1
        idleSince = Date()
    }

    private func render() {
        content.setIdle(!running)
        if !running {
            content.waveView.image = nil
            let now = Date()
            if !wasIdle { wasIdle = true; idleIndex = 0; idleSince = now }
            let lines = IdleInfoProvider.shared.lines(for: SpotifySettings.shared.idleItems)
            if lines.count > 1, now.timeIntervalSince(idleSince) >= SpotifySettings.shared.idleInterval { advanceIdle() }
            let base = SpotifySettings.shared.lyricColor
            if lines.isEmpty {
                content.lyricView.show("", color: base, scrollDuration: nil)
            } else {
                let line = lines[idleIndex % lines.count]
                content.lyricView.show(line.text, symbol: line.symbol, animated: false, color: base, scrollDuration: nil)
            }
            return
        }
        wasIdle = false
        if automation == .denied {
            content.waveView.image = nil
            content.lyricView.show("Tap to allow MTMR to control Spotify", color: NSColor.systemYellow, scrollDuration: nil)
            return
        }
        guard running, !name.isEmpty else {
            content.waveView.image = nil
            content.lyricView.show("", color: .white, scrollDuration: nil)
            return
        }

        // Wave: ease amplitude toward target, advance phase only while playing.
        let targets = waveTargets()
        let wasMoving = bandAmp.contains { $0 > 0.005 }
        for i in 0 ..< bandAmp.count {
            let k = targets[i] > bandAmp[i] ? 0.5 : 0.12 // fast attack, slower release: reads as a beat
            bandAmp[i] += (targets[i] - bandAmp[i]) * k
            if bandAmp[i] < 0.005 { bandAmp[i] = 0 }
        }
        let energy = bandAmp.reduce(0, +) / Double(bandAmp.count)
        if playing { phase += 0.10 + 0.22 * energy } // faster flow on loud passages
        if mode != .lyrics, wasMoving || energy > 0 || content.waveView.image == nil {
            content.waveView.image = waveImage()
        }

        // Text: no-op unless the line changed, so the animation is driven by Core Animation, not by this timer.
        let d = displayLine()
        let base = SpotifySettings.shared.lyricColor
        let color = mode == .wave ? base.withAlphaComponent(0.7) : base
        content.lyricView.show(d.text, symbol: d.symbol, animated: playing, color: color, scrollDuration: d.scroll)
    }
}

// MARK: - ScriptingBridge protocols

@objc protocol SpotifyPlayback {
    @objc optional var playerPosition: Double { get }
    @objc optional var playerState: Int { get }
}

extension SBApplication: SpotifyPlayback {}

@objc protocol SpotifyTrackDetails {
    @objc optional var album: String { get }
    @objc optional var duration: Int { get } // milliseconds
    @objc optional var artworkUrl: String { get }
}

extension SBObject: SpotifyTrackDetails {}
