//
//  SpotifyAudioTap.swift
//  MTMR
//
//  Real audio levels of the Spotify app only (Core Audio process tap, macOS 14.2+).
//  Needs the one-time "System Audio Recording" permission; callers fall back to a simulated wave without it.
//

import AudioToolbox
import CoreAudio
import Foundation

protocol AudioLevelSource: AnyObject {
    /// Normalized 0...1 energy of the low (<200 Hz), mid (200 Hz-2 kHz) and high (>2 kHz) bands.
    var levels: (bass: Float, mid: Float, high: Float) { get }
    var isRunning: Bool { get }
    /// Last time actual (non-silent) audio arrived; used to detect a denied permission.
    var lastSignal: Date { get }
    @discardableResult func start() -> Bool
    func stop()
}

func makeSpotifyAudioTap() -> AudioLevelSource? {
    if #available(macOS 14.2, *) { return SpotifyProcessTap() }
    return nil
}

@available(macOS 14.2, *)
final class SpotifyProcessTap: AudioLevelSource {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "mtmr.spotify.audiotap", qos: .userInteractive)

    private(set) var isRunning = false
    private(set) var lastSignal = Date.distantPast
    private var bass: Float = 0, mid: Float = 0, high: Float = 0 // written on the audio thread, read by the UI timer
    var levels: (bass: Float, mid: Float, high: Float) { (bass, mid, high) }

    // DSP state (audio thread only)
    private var sampleRate: Float = 48000
    private var lp1: Float = 0, lp2: Float = 0
    private var peakBass: Float = 0.02, peakMid: Float = 0.02, peakHigh: Float = 0.02

    deinit { stop() }

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        let processes = Self.spotifyProcessObjects()
        guard !processes.isEmpty else { return false }

        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.muteBehavior = .unmuted // only listen, never change what the user hears
        description.isPrivate = true
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr, let outputUID = Self.defaultOutputUID() else {
            NSLog("MTMR spotify tap: cannot create tap")
            stop(); return false
        }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MTMR Spotify Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID) == noErr else {
            NSLog("MTMR spotify tap: cannot create aggregate device")
            stop(); return false
        }

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format) == noErr, format.mSampleRate > 0 {
            sampleRate = Float(format.mSampleRate)
        }

        guard AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue, { [weak self] _, input, _, _, _ in
            self?.process(input)
        }) == noErr, AudioDeviceStart(aggregateID, procID) == noErr else {
            NSLog("MTMR spotify tap: cannot start IO")
            stop(); return false
        }
        lastSignal = Date() // grace period before a silent tap is treated as "permission denied"
        isRunning = true
        return true
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            if let procID = procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        isRunning = false
        bass = 0; mid = 0; high = 0
    }

    // MARK: audio thread

    private func process(_ input: UnsafePointer<AudioBufferList>) {
        let a1 = 1 - exp(-2 * Float.pi * 200 / sampleRate)
        let a2 = 1 - exp(-2 * Float.pi * 2000 / sampleRate)
        var sb: Float = 0, sm: Float = 0, sh: Float = 0
        var frameCount = 0

        for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let channels = max(1, Int(buffer.mNumberChannels))
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            for f in 0 ..< frames {
                var x: Float = 0
                for c in 0 ..< channels { x += data[f * channels + c] }
                x /= Float(channels)
                lp1 += a1 * (x - lp1)
                lp2 += a2 * (x - lp2)
                let b = lp1, m = lp2 - lp1, h = x - lp2
                sb += b * b; sm += m * m; sh += h * h
            }
            frameCount += frames
        }
        guard frameCount > 0 else { return }

        let n = Float(frameCount)
        let rb = (sb / n).squareRoot(), rm = (sm / n).squareRoot(), rh = (sh / n).squareRoot()
        if rb + rm + rh > 1e-5 { lastSignal = Date() }

        // Slow automatic gain: levels are relative to the recent peak, so the wave looks alive at any volume.
        peakBass = max(rb, peakBass * 0.998, 0.01)
        peakMid = max(rm, peakMid * 0.998, 0.01)
        peakHigh = max(rh, peakHigh * 0.998, 0.005)
        bass = min(1, pow(rb / peakBass, 1.6))
        mid = min(1, pow(rm / peakMid, 1.6))
        high = min(1, pow(rh / peakHigh, 1.6))
    }

    // MARK: helpers

    private static func spotifyProcessObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        // Spotify (Chromium based) plays through helper processes, all with a com.spotify.client* bundle id.
        return ids.filter { (stringProperty($0, kAudioProcessPropertyBundleID) ?? "").hasPrefix("com.spotify.client") }
    }

    private static func defaultOutputUID() -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }
        return stringProperty(device, kAudioDevicePropertyDeviceUID)
    }

    private static func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
