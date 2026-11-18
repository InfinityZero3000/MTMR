//
//  TemplateLibrary.swift
//  MTMR
//
//  Ready-made layouts (bundled) plus the user's own, kept in ~/Library/Application Support/MTMR/Templates.
//  Applying one replaces the items of the open preset; nothing is written until the user saves.
//

import AppKit
import SwiftUI

struct PresetTemplate: Identifiable {
    enum Source {
        case bundled(resource: String)
        case file(URL)
    }

    let id: String
    let name: String
    let summary: String
    let source: Source

    var isUser: Bool { if case .file = source { return true } else { return false } }

    func text() throws -> String {
        switch source {
        case let .bundled(resource):
            guard let url = Bundle.main.url(forResource: resource, withExtension: "json") else {
                throw PresetDocumentError.message("The template \"\(name)\" is missing from the app.")
            }
            return try String(contentsOf: url, encoding: .utf8)
        case let .file(url):
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    /// Items of the template, for the thumbnail chips and the width estimate.
    func parsedItems() -> [PresetItem] {
        guard let text = try? text() else { return [] }
        let doc = PresetDocument(fileURL: URL(fileURLWithPath: "/dev/null"))
        try? doc.replaceItems(fromText: text)
        return doc.items
    }
}

enum TemplateLibrary {
    static var userDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MTMR/Templates")
    }

    static let bundled: [PresetTemplate] = [
        PresetTemplate(id: "default", name: "MTMR default", summary: "The standard layout: Esc, brightness, Spotify and Music, weather, volume, battery, clock.", source: .bundled(resource: "defaultPreset")),
        PresetTemplate(id: "spotify-lyrics", name: "Spotify lyrics", summary: "Mascot-style exit button, scrollable Dock, Spotify with synced lyrics and a live wave, CPU, RAM and sleep.", source: .bundled(resource: "template-spotify-lyrics")),
        PresetTemplate(id: "spotify-minimal", name: "Spotify minimal", summary: "Light layout without custom images: Esc, Dock, Spotify, rotating info (clock, battery, weather), display sleep.", source: .bundled(resource: "template-spotify-minimal")),
        PresetTemplate(id: "classic", name: "Classic", summary: "The original MTMR demo layout with several widgets.", source: .bundled(resource: "template-classic")),
        PresetTemplate(id: "codex", name: "Codex usage", summary: "Codex token usage and quota widgets.", source: .bundled(resource: "template-codex")),
    ]

    static func userTemplates() -> [PresetTemplate] {
        let files = (try? FileManager.default.contentsOfDirectory(at: userDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { PresetTemplate(id: "user-" + $0.lastPathComponent, name: $0.deletingPathExtension().lastPathComponent, summary: "Saved by you.", source: .file($0)) }
    }

    static func all() -> [PresetTemplate] { bundled + userTemplates() }

    /// Saves `text` as a user template named `name` (invalid file-name characters are replaced). Returns the file.
    @discardableResult
    static func save(name: String, text: String) throws -> URL {
        let clean = name.components(separatedBy: CharacterSet(charactersIn: "/:\\\n")).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { throw PresetDocumentError.message("Give the template a name.") }
        try FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true)
        let url = userDirectory.appendingPathComponent(clean + ".json")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func delete(_ template: PresetTemplate) {
        if case let .file(url) = template.source { try? FileManager.default.removeItem(at: url) }
    }
}

struct TemplateLibraryView: View {
    @ObservedObject var document: PresetDocument
    @Binding var isPresented: Bool
    var onApplied: () -> Void

    @State private var templates = TemplateLibrary.all()
    @State private var newName = ""
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Layout Templates").font(.headline)
                Spacer()
                Button("Done") { isPresented = false }.keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(templates) { template in row(template) }
                }.padding(16)
            }

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if let message = message { Text(message).font(.caption).foregroundColor(.orange) }
                HStack {
                    TextField("Name for the current layout", text: $newName).textFieldStyle(.roundedBorder)
                    Button("Save Current as Template") { saveCurrent() }.disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || document.items.isEmpty)
                }
                HStack {
                    Button("Import File…") { importFile() }
                    Button("Export Current…") { exportCurrent() }.disabled(document.items.isEmpty)
                    Button("Show Folder") {
                        try? FileManager.default.createDirectory(at: TemplateLibrary.userDirectory, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(TemplateLibrary.userDirectory)
                    }
                    Spacer()
                    Text("Applying replaces the current layout. Revert undoes it until you save.").font(.caption).foregroundColor(.secondary)
                }
            }.padding(16)
        }
        .frame(width: 600, height: 560)
    }

    private func row(_ template: PresetTemplate) -> some View {
        let items = template.parsedItems()
        let total = WidthBudget.total(of: items)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(template.name).font(.system(size: 13, weight: .semibold))
                if template.isUser { Text("yours").font(.caption).foregroundColor(.secondary) }
                Spacer()
                if !items.isEmpty {
                    Text(String(format: "≈ %.0f pt", total)).font(.caption).monospacedDigit()
                        .foregroundColor(total > WidthBudget.limit ? .red : .secondary)
                }
                if template.isUser {
                    Button("Delete") { TemplateLibrary.delete(template); templates = TemplateLibrary.all() }
                }
                Button("Apply") { apply(template) }
            }
            Text(template.summary).font(.caption).foregroundColor(.secondary)
            // A tiny preview: one chip per visual item, in bar order.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(items.filter { !$0.isGesture }) { item in
                        Image(systemName: item.symbolName).font(.system(size: 11)).foregroundColor(.white)
                            .frame(width: 26, height: 20).background(RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.24)))
                            .help(item.typeDisplayName)
                    }
                }.padding(6)
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.black))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
    }

    private func apply(_ template: PresetTemplate) {
        do {
            try document.replaceItems(fromText: try template.text())
            message = nil
            onApplied()
            isPresented = false
        } catch {
            message = error.localizedDescription
        }
    }

    private func saveCurrent() {
        do {
            try TemplateLibrary.save(name: newName, text: document.serializedText())
            newName = ""
            message = nil
            templates = TemplateLibrary.all()
        } catch {
            message = error.localizedDescription
        }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            _ = try JSONValue.parse(text) // reject files that are not valid presets before keeping them
            try TemplateLibrary.save(name: url.deletingPathExtension().lastPathComponent, text: text)
            message = nil
            templates = TemplateLibrary.all()
        } catch {
            message = "Could not import: \(error.localizedDescription)"
        }
    }

    private func exportCurrent() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "touchbar-layout.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try document.serializedText().write(to: url, atomically: true, encoding: .utf8)
            message = nil
        } catch {
            message = "Could not export: \(error.localizedDescription)"
        }
    }
}
