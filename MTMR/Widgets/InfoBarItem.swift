//
//  InfoBarItem.swift
//  MTMR
//
//  "info" widget: clock, battery, weather and CPU & RAM in turn (same sources as the Spotify widget's
//  idle display), as a standalone item. Tap = next item.
//

import Cocoa

final class InfoBarItem: CustomButtonTouchBarItem {
    private let lyricView = LyricTextView(frame: .zero)
    private let show: [String]
    private let interval: TimeInterval
    private var timer: Timer?
    private var index = 0
    private var since = Date()

    init(identifier: NSTouchBarItem.Identifier, show: [String], interval: TimeInterval) {
        self.show = show
        self.interval = max(2, interval)
        super.init(identifier: identifier, attributedTitle: NSAttributedString())
        isBordered = false
        actions = [ItemAction(trigger: .singleTap) { [weak self] in self?.advance() }]
        finishViewConfiguration = { [weak self] in self?.attach() } // the button is rebuilt when e.g. "bordered" is applied
        attach()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        timer?.tolerance = 0.1
    }

    required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { timer?.invalidate() }

    private func attach() {
        guard lyricView.superview !== view else { return }
        lyricView.removeFromSuperview()
        lyricView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(lyricView)
        // Default size when the preset gives no "width" (an explicit width constraint outranks this one).
        let defaultWidth = view.widthAnchor.constraint(equalToConstant: 220)
        defaultWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            defaultWidth,
            lyricView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
            lyricView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
            lyricView.topAnchor.constraint(equalTo: view.topAnchor),
            lyricView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        attributedTitle = NSAttributedString()
        lyricView.reset()
    }

    private func advance() {
        index += 1
        since = Date()
        tick()
    }

    private func tick() {
        let lines = IdleInfoProvider.shared.lines(for: show)
        guard !lines.isEmpty else {
            lyricView.show("", color: .white, scrollDuration: nil)
            return
        }
        if lines.count > 1, Date().timeIntervalSince(since) >= interval {
            index += 1
            since = Date()
        }
        let line = lines[index % lines.count]
        lyricView.show(line.text, symbol: line.symbol, animated: false, color: .white, scrollDuration: nil)
    }
}
