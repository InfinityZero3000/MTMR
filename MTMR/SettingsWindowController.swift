//
//  SettingsWindowController.swift
//  MTMR
//
//  "Settings…" window: Spotify widget look & behaviour, plus the Touch Bar on/off switch.
//  Changes apply immediately.
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject var spotify = SpotifySettings.shared
    @State private var touchBarOn = AppSettings.touchBarEnabled
    @State private var controlStrip = AppSettings.showControlStripState
    @State private var haptics = AppSettings.hapticFeedbackState

    private func row<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .center) {
            Text(title).frame(width: 150, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func idleToggle(_ title: String, _ id: String) -> some View {
        Toggle(title, isOn: Binding(
            get: { spotify.idleItems.contains(id) },
            set: { on in
                var items = spotify.idleItems.filter { $0 != id }
                if on { items.append(id) }
                spotify.idleItems = items
            }
        ))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox(label: Text("Touch Bar").font(.headline)) {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Show MTMR on the Touch Bar", isOn: $touchBarOn)
                            .onChange(of: touchBarOn) { TouchBarController.shared.setEnabled($0) }
                        Toggle("Keep the system Control Strip visible", isOn: $controlStrip)
                            .onChange(of: controlStrip) { AppSettings.showControlStripState = $0; TouchBarController.shared.resetControlStrip() }
                        Toggle("Haptic feedback", isOn: $haptics)
                            .onChange(of: haptics) { AppSettings.hapticFeedbackState = $0 }
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox(label: Text("Spotify widget").font(.headline)) {
                    VStack(alignment: .leading, spacing: 12) {
                        row("Display") {
                            Picker("", selection: Binding(get: { spotify.mode }, set: { spotify.mode = $0 })) {
                                Text("Lyrics + wave").tag("both")
                                Text("Lyrics").tag("lyrics")
                                Text("Wave").tag("wave")
                            }.pickerStyle(.segmented).labelsHidden()
                        }
                        row("Wave follows audio") {
                            Toggle("", isOn: Binding(get: { spotify.reactive }, set: { spotify.reactive = $0 })).labelsHidden()
                            Text("needs System Audio permission").font(.caption).foregroundColor(.secondary)
                        }
                        row("Show Spotify icon") {
                            Toggle("", isOn: Binding(get: { spotify.showIcon }, set: { spotify.showIcon = $0 })).labelsHidden()
                        }
                        row("Album cover as icon") {
                            Toggle("", isOn: Binding(get: { spotify.showArtwork }, set: { spotify.showArtwork = $0 })).labelsHidden()
                            Text("instead of the Spotify logo").font(.caption).foregroundColor(.secondary)
                        }
                        row("Lyrics timing") {
                            Slider(value: Binding(get: { spotify.lyricsOffset }, set: { spotify.lyricsOffset = $0 }), in: -2 ... 2, step: 0.05)
                            Text(String(format: "%+.2f s", spotify.lyricsOffset)).monospacedDigit().frame(width: 62, alignment: .trailing)
                        }
                        Text("Positive = lyrics appear earlier. Use it to fine-tune sync, e.g. for Bluetooth speakers.")
                            .font(.caption).foregroundColor(.secondary).padding(.leading, 150)
                        row("Text size") {
                            Slider(value: Binding(get: { spotify.textSize }, set: { spotify.textSize = $0 }), in: 12 ... 19, step: 1)
                            Text("\(Int(spotify.textSize)) pt").monospacedDigit().frame(width: 62, alignment: .trailing)
                        }
                        row("Swipe distance") {
                            Slider(value: Binding(get: { spotify.swipeDistance }, set: { spotify.swipeDistance = $0 }), in: 20 ... 140, step: 4)
                            Text("\(Int(spotify.swipeDistance)) pt").monospacedDigit().frame(width: 62, alignment: .trailing)
                        }
                        Text("Swipe left on the widget = next track, swipe right = previous. A shorter distance is more sensitive.")
                            .font(.caption).foregroundColor(.secondary).padding(.leading, 150)
                        Divider()
                        Text("When Spotify is closed").font(.subheadline).bold()
                        row("Show") {
                            idleToggle("Clock", "clock")
                            idleToggle("Battery", "battery")
                            idleToggle("Weather", "weather")
                            idleToggle("CPU & RAM", "system")
                        }
                        row("Switch every") {
                            Slider(value: Binding(get: { spotify.idleInterval }, set: { spotify.idleInterval = $0 }), in: 3 ... 15, step: 1)
                            Text("\(Int(spotify.idleInterval)) s").monospacedDigit().frame(width: 62, alignment: .trailing)
                        }
                        Text("Items slide in turn; tap the widget to skip ahead. Weather uses your location (Open-Meteo, no account) and stays hidden without permission.")
                            .font(.caption).foregroundColor(.secondary).padding(.leading, 150)
                        Divider()
                        row("Wave color") {
                            ColorPicker("", selection: Binding(get: { Color(nsColor: spotify.waveColor) },
                                                               set: { spotify.waveColorHex = NSColor($0).hexRGB }), supportsOpacity: false).labelsHidden()
                        }
                        row("Lyrics color") {
                            ColorPicker("", selection: Binding(get: { Color(nsColor: spotify.lyricColor) },
                                                               set: { spotify.lyricColorHex = NSColor($0).hexRGB }), supportsOpacity: false).labelsHidden()
                        }
                        HStack {
                            Spacer()
                            Button("Reset to preset") { spotify.reset() }
                        }
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack {
                    Button("Customize Touch Bar…") { CustomizerWindowController.shared.show() }
                    Button("Reveal preset file") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: standardConfigPath)])
                    }
                    Spacer()
                }
            }.padding(20)
        }
        .frame(minWidth: 520, minHeight: 540)
    }
}

final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.title = "MTMR Settings"
        window.contentViewController = NSHostingController(rootView: SettingsView())
        window.center()
        window.setFrameAutosaveName("SettingsWindow")
        window.isReleasedWhenClosed = false
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    /// MTMR is an LSUIElement agent, so the window must activate the app explicitly.
    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
    }
}
