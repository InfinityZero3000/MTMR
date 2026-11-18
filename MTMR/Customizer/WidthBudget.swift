//
//  WidthBudget.swift
//  MTMR
//
//  Measures how much of the Touch Bar a preset uses and warns before it overflows.
//  The bar lays everything out in one row (BasicView): items in order, 8 pt between them, inside a visible
//  region of 1004 pt. What does not fit is clipped at the left edge, so the first items disappear.
//

import SwiftUI

enum WidthBudget {
    /// Visible width of the bar (BasicView's container).
    static let limit: Double = 1004
    /// Spacing between neighbouring items (BasicView's stack).
    static let gap: Double = 8

    /// Width of one item: its "width" if set, otherwise a typical size for its type (items that fit their content are estimates).
    static func width(of item: PresetItem) -> Double {
        if let w = item.json["width"]?.doubleValue, w > 0 { return w }
        switch item.type {
        case "escape": return 64
        case "exitTouchbar", "close": return 30
        case "previous", "play", "next", "mute", "volumeUp", "volumeDown", "brightnessUp", "brightnessDown",
             "illuminationUp", "illuminationDown", "delete", "sleep", "displaySleep", "dnd", "nightShift", "darkMode": return 38
        case "battery": return 72
        case "timeButton": return 64
        case "cpu", "weather", "yandexWeather", "currency": return 84
        case "network": return 90
        case "pomodoro": return 72
        case "inputsource": return 60
        case "music": return 150
        case "spotify": return 420
        case "info": return 220
        case "upnext": return 200
        case "dock": return 120
        case "volume", "brightness": return 150
        case "group": return 60
        case "spacer": return 16
        case "appleScriptTitledButton", "shellScriptTitledButton": return 90
        case "staticButton":
            let title = item.json["title"]?.stringValue ?? ""
            return title.isEmpty ? 40 : max(40, 24 + Double(title.count) * 9)
        default: return 60
        }
    }

    /// Total width the bar needs: left items, the centre scroll area, right items, with the gaps between them.
    static func total(of items: [PresetItem]) -> Double {
        let visual = items.filter { !$0.isGesture }
        func sum(_ align: PresetAlign) -> (width: Double, count: Int) {
            let zone = visual.filter { $0.align == align }
            return (zone.reduce(0) { $0 + width(of: $1) } + Double(max(0, zone.count - 1)), zone.count) // centre stack spacing is 1
        }
        let left = visual.filter { $0.align == .left }
        let right = visual.filter { $0.align == .right }
        let center = sum(.center)
        let side = (left + right).reduce(0) { $0 + width(of: $1) }
        // elements: left items + centre area (always present, may be empty) + right items
        return side + center.width + gap * Double(left.count + right.count)
    }
}

extension PresetDocument {
    var widthTotal: Double { WidthBudget.total(of: items) }

    /// Shrinks the widest items that have an explicit width (dock, Spotify, …) until the bar fits. Returns true if it fits.
    @discardableResult
    func fitToBar() -> Bool {
        var overflow = widthTotal - WidthBudget.limit
        guard overflow > 0 else { return true }
        let flexible: Set<String> = ["dock", "spotify", "info", "upnext", "music", "appleScriptTitledButton", "shellScriptTitledButton", "group"]
        let candidates = items
            .filter { flexible.contains($0.type) && ($0.json["width"]?.doubleValue ?? 0) >= 120 }
            .sorted { ($0.json["width"]?.doubleValue ?? 0) > ($1.json["width"]?.doubleValue ?? 0) }
        for var item in candidates where overflow > 0 {
            let current = item.json["width"]?.doubleValue ?? 0
            let reduction = min(overflow.rounded(.up), current - 100)
            guard reduction > 0 else { continue }
            item.json["width"] = .int(Int64(current - reduction))
            update(item)
            overflow -= reduction
        }
        return widthTotal <= WidthBudget.limit
    }

    /// Whether the top-level visual item can move one place earlier (-1) or later (+1) inside its zone.
    func canMove(id: PresetItem.ID, by delta: Int) -> Bool {
        guard let item = items.first(where: { $0.id == id }), !item.isGesture,
              let index = items(in: item.align).firstIndex(where: { $0.id == id }) else { return false }
        let target = index + delta
        return target >= 0 && target < items(in: item.align).count
    }

    func moveItem(id: PresetItem.ID, by delta: Int) {
        guard canMove(id: id, by: delta), let item = items.first(where: { $0.id == id }),
              let index = items(in: item.align).firstIndex(where: { $0.id == id }) else { return }
        // List.onMove semantics: moving down by one means "before the element two places on".
        move(in: item.align, from: IndexSet(integer: index), to: delta > 0 ? index + 2 : index - 1)
    }
}

struct WidthBudgetView: View {
    @ObservedObject var document: PresetDocument

    var body: some View {
        let total = document.widthTotal
        let limit = WidthBudget.limit
        let over = total - limit
        let ratio = min(1, total / limit)
        let color: Color = over > 0 ? .red : (ratio > 0.94 ? .orange : .green)

        HStack(spacing: 10) {
            Image(systemName: over > 0 ? "exclamationmark.triangle.fill" : "ruler").foregroundColor(color)
            Text(String(format: "%.0f / %.0f pt", total, limit)).monospacedDigit().font(.system(size: 12, weight: .medium))
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule().fill(color).frame(width: proxy.size.width * CGFloat(ratio))
                }
            }
            .frame(height: 6)
            if over > 0 {
                Text(String(format: "Over by %.0f pt: the first items are cut off on the Touch Bar.", over))
                    .font(.system(size: 12)).foregroundColor(.red)
                Button("Fit") { document.fitToBar() }
                    .help("Shrink the widest items (dock, Spotify…) until everything fits")
            } else {
                Text(String(format: "%.0f pt free", -over)).font(.system(size: 12)).foregroundColor(.secondary)
            }
        }
        .help("Space used on the Touch Bar. Items without a fixed width are estimated; the system Control Strip, if shown, takes more.")
    }
}
