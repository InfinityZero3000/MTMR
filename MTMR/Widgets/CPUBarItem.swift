//
//  CPUBarItem.swift
//  MTMR
//
//  Created by bobrosoft on 17/08/2021.
//  Copyright © 2018 Anton Palgunov. All rights reserved.
//

import Foundation

class CPUBarItem: CustomButtonTouchBarItem {
    private let refreshInterval: TimeInterval
    private var refreshQueue: DispatchQueue? = DispatchQueue(label: "mtmr.cpu")
    private var highlighted = false
    private var baseBackground: NSColor? // the preset's own background, restored when the warning highlight ends
    private let defaultSingleTapScript: NSAppleScript! = "activate application \"Activity Monitor\"\rtell application \"System Events\"\r\ttell process \"Activity Monitor\"\r\t\ttell radio button \"CPU\" of radio group 1 of group 2 of toolbar 1 of window 1 to perform action \"AXPress\"\r\tend tell\rend tell".appleScript

    init(identifier: NSTouchBarItem.Identifier, refreshInterval: TimeInterval) {
        self.refreshInterval = refreshInterval
        super.init(identifier: identifier, attributedTitle: .loading)
                
        // Set default image
        if self.image == nil {
            self.image = #imageLiteral(resourceName: "cpu").resize(maxSize: NSSize(width: 24, height: 24));
        }
        
        // Set default action
        if actions.filter({ $0.trigger == .singleTap }).isEmpty {
            actions.append(ItemAction(
                trigger: .singleTap,
                defaultTapAction
            ))
        }
        
        refreshAndSchedule()
    }

    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func refreshAndSchedule() {
        DispatchQueue.main.async {
            // Get CPU load
            let usage = 100 - CPU.systemUsage().idle
            guard usage.isFinite else {
                return
            }
            
            // Choose color based on CPU load
            var color: NSColor? = nil
            var bgColor: NSColor? = nil
            if usage > 70 {
                color = .black
                bgColor = .yellow
            } else if usage > 30 {
                color = .yellow
            }
            
            // Update layout
            let attrTitle = NSMutableAttributedString.init(attributedString: String(format: "%.1f%%", usage).defaultTouchbarAttributedString)
            if let color = color {
                attrTitle.addAttributes([.foregroundColor: color], range: NSRange(location: 0, length: attrTitle.length))
            }
            self.attributedTitle = attrTitle
            if let bgColor = bgColor {
                if !self.highlighted { self.baseBackground = self.backgroundColor; self.highlighted = true }
                self.backgroundColor = bgColor
            } else if self.highlighted {
                self.highlighted = false
                self.backgroundColor = self.baseBackground
            }
        }
        
        refreshQueue?.asyncAfter(deadline: .now() + refreshInterval) { [weak self] in
            self?.refreshAndSchedule()
        }
    }

    func defaultTapAction() {
        refreshQueue?.async { [weak self] in
            self?.defaultSingleTapScript.executeAndReturnError(nil)
        }
    }
    
    deinit {
        refreshQueue?.suspend()
        refreshQueue = nil
    }
}

/// Memory in use, as Activity Monitor counts it: app memory + wired + compressed.
enum SystemStats {
    static func memoryUsedPercent() -> Double? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard status == KERN_SUCCESS else { return nil }
        let pages = Double(stats.internal_page_count) - Double(stats.purgeable_count) + Double(stats.wire_count) + Double(stats.compressor_page_count)
        let used = max(0, pages) * Double(vm_kernel_page_size)
        return min(100, used / Double(ProcessInfo.processInfo.physicalMemory) * 100)
    }
}

/// Memory usage read straight from the kernel (no shell script), same look and behaviour as the CPU widget.
class RAMBarItem: CustomButtonTouchBarItem {
    private let refreshInterval: TimeInterval
    private var refreshQueue: DispatchQueue? = DispatchQueue(label: "mtmr.ram")
    private var highlighted = false
    private var baseBackground: NSColor?
    private let defaultSingleTapScript: NSAppleScript! = "activate application \"Activity Monitor\"\rtell application \"System Events\"\r\ttell process \"Activity Monitor\"\r\t\ttell radio button \"Memory\" of radio group 1 of group 2 of toolbar 1 of window 1 to perform action \"AXPress\"\r\tend tell\rend tell".appleScript

    init(identifier: NSTouchBarItem.Identifier, refreshInterval: TimeInterval) {
        self.refreshInterval = refreshInterval
        super.init(identifier: identifier, attributedTitle: .loading)
        if image == nil {
            image = NSImage(systemSymbolName: "memorychip", accessibilityDescription: nil)?.resize(maxSize: NSSize(width: 24, height: 24))
        }
        if actions.filter({ $0.trigger == .singleTap }).isEmpty {
            actions.append(ItemAction(trigger: .singleTap, defaultTapAction))
        }
        refreshAndSchedule()
    }

    required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refreshAndSchedule() {
        DispatchQueue.main.async {
            guard let usage = SystemStats.memoryUsedPercent() else { return }
            var color: NSColor?
            var bgColor: NSColor?
            if usage > 85 { color = .black; bgColor = .yellow } else if usage > 70 { color = .yellow }
            let title = NSMutableAttributedString(attributedString: String(format: "%.1f%%", usage).defaultTouchbarAttributedString)
            if let color = color { title.addAttributes([.foregroundColor: color], range: NSRange(location: 0, length: title.length)) }
            self.attributedTitle = title
            if let bgColor = bgColor {
                if !self.highlighted { self.baseBackground = self.backgroundColor; self.highlighted = true }
                self.backgroundColor = bgColor
            } else if self.highlighted {
                self.highlighted = false
                self.backgroundColor = self.baseBackground
            }
        }
        refreshQueue?.asyncAfter(deadline: .now() + refreshInterval) { [weak self] in self?.refreshAndSchedule() }
    }

    func defaultTapAction() {
        refreshQueue?.async { [weak self] in self?.defaultSingleTapScript.executeAndReturnError(nil) }
    }

    deinit {
        refreshQueue?.suspend()
        refreshQueue = nil
    }
}
