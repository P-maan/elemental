//  SystemAudioMeter.swift — the wall moves with what the Mac is playing.
//
//  Asked for 26 Oct 2026: "the elemental music visualizer is still working but
//  only when plugged in and use system audio for it". It was a microphone
//  listener inside Zo for Mac; he did not want it there or on the mic, and it
//  crashed Zo — the audio tap closure inherited @MainActor isolation from its
//  class and hit dispatch_assert_queue on the audio thread.
//
//  So it lives here, and reads SYSTEM audio — what the Mac is playing — through
//  a Core Audio process tap (macOS 14.2+): a private, global, unmuted tap on all
//  output, wrapped in a private aggregate device that exists only for this
//  process. Nothing is recorded or kept. Each buffer is reduced to one number —
//  how hard the bass is hitting — and thrown away.
//
//  ---- What it measures
//
//  Bass, because that is what a room feels: a one-pole low-pass at ~150 Hz, its
//  RMS per buffer, an envelope that rises in ~10 ms and falls in ~150 ms, and a
//  slow peak (decaying over about a minute) to normalise against, so a quiet
//  track and a loud one both use the whole range. That level feeds
//  `Pulse.shared` about thirty times a second.
//
//  A DROP is the bass coming back after a build: under 35% of the slow peak for
//  three seconds or more, then back over 75% of it. It plays `Pulse.drop`, at
//  most once every forty seconds.
//
//  ---- When it runs
//
//  Only on AC power, only while the setting is on, never asleep. On battery
//  there is no tap at all — not a paused one. The host calls `update(...)`
//  whenever any of that changes.
//
//  ---- Threading
//
//  This class is NOT on the main actor, deliberately — see the crash above. The
//  IO block runs on `queue`, a private serial queue, and every bit of analysis
//  state is touched only there. The only thing that crosses to main is the
//  level, posted to Pulse (which is lock-protected anyway) and the host's
//  frame-rate nudge.
//
//  Permission: macOS asks once for "system audio recording"
//  (NSAudioCaptureUsageDescription). Elemental is signed ad hoc, so a rebuild
//  is a new identity and may ask again (HANDOFF trap 9).

import Foundation
import CoreAudio
import AudioToolbox

final class SystemAudioMeter: @unchecked Sendable {

    /// Called on the main queue whenever a level is posted, so the host can
    /// lift the frame rate while music plays.
    var onLevel: (() -> Void)?

    private let queue = DispatchQueue(label: "com.elemental.systemaudio", qos: .userInitiated)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private(set) var running = false
    private(set) var lastError: String?

    // ---- analysis state: touched only on `queue`
    private var sampleRate: Double = 48_000
    private var lp: Float = 0
    private var env: Float = 0
    private var peak: Float = 1e-4
    private var quietSince: CFAbsoluteTime?
    private var lastDrop: CFAbsoluteTime = 0
    private var lastPost: CFAbsoluteTime = 0
    private var latest: Double = 0

    /// The most recent level, 0..1. For status only.
    var level: Double { queue.sync { latest } }

    // MARK: Lifecycle

    /// Start or stop to match what the host says should be happening.
    func update(shouldRun: Bool) {
        if shouldRun && !running { start() }
        else if !shouldRun && running { stop() }
    }

    private func start() {
        guard #available(macOS 14.2, *) else {
            lastError = "needs macOS 14.2 or later"
            return
        }
        lastError = nil
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.name = "Elemental music"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(desc, &tap)
        guard err == noErr, tap != kAudioObjectUnknown else {
            lastError = "could not create the audio tap (\(err)) — is system audio recording allowed?"
            return
        }
        tapID = tap

        let aggUID = "com.prakritmaan.elemental.music.\(UUID().uuidString)"
        var dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Elemental music",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: desc.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        if let out = Self.defaultOutputUID() {
            dict[kAudioAggregateDeviceMainSubDeviceKey] = out
            dict[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: out]]
        }
        var agg = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &agg)
        guard err == noErr, agg != kAudioObjectUnknown else {
            lastError = "could not create the aggregate device (\(err))"
            teardown()
            return
        }
        aggID = agg

        if let sr = Self.tapSampleRate(tap) { queue.sync { sampleRate = sr } }

        var proc: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, queue) {
            [weak self] _, inData, _, _, _ in
            self?.analyse(inData)
        }
        guard err == noErr, let proc else {
            lastError = "could not attach to the audio (\(err))"
            teardown()
            return
        }
        procID = proc
        err = AudioDeviceStart(agg, proc)
        guard err == noErr else {
            lastError = "could not start the audio (\(err))"
            teardown()
            return
        }
        running = true
        NSLog("Elemental: music visualizer listening to system audio")
    }

    private func stop() {
        teardown()
        NSLog("Elemental: music visualizer stopped")
    }

    private func teardown() {
        if aggID != kAudioObjectUnknown, let p = procID {
            AudioDeviceStop(aggID, p)
            AudioDeviceDestroyIOProcID(aggID, p)
        }
        procID = nil
        if aggID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggID)
            aggID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            if #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tapID) }
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        running = false
        queue.async { [weak self] in
            guard let self else { return }
            self.env = 0; self.lp = 0; self.quietSince = nil; self.latest = 0
        }
    }

    deinit { teardown() }

    // MARK: Analysis — on `queue` only

    private func analyse(_ list: UnsafePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        let a = Float(1 - exp(-2 * Double.pi * 150 / sampleRate))
        var sum: Float = 0
        var n = 0
        // Float32 samples, interleaved or not: every channel of every buffer
        // goes through the same low-pass, which is a mono bass sum in effect.
        for buf in abl {
            guard let data = buf.mData else { continue }
            let count = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
            let p = data.assumingMemoryBound(to: Float.self)
            for i in 0..<count {
                lp += a * (p[i] - lp)
                sum += lp * lp
            }
            n += count
        }
        guard n > 0 else { return }
        let rms = (sum / Float(n)).squareRoot()

        // Envelope: quick to rise, slower to fall, per buffer (~10 ms each).
        let rise: Float = 0.6, fall: Float = 0.07
        env += (rms > env ? rise : fall) * (rms - env)

        // Slow peak to normalise against: decays over about a minute, so a
        // loud track does not leave a quiet one with nothing to show.
        peak = max(env, peak * 0.99985, 1e-4)
        let lv = Double(min(1, env / peak))

        let now = CFAbsoluteTimeGetCurrent()
        latest = lv

        // A drop: quiet for three seconds, then back above three quarters.
        var drop = false
        if env < peak * 0.35 && peak > 0.002 {
            if quietSince == nil { quietSince = now }
        } else if env > peak * 0.75 {
            if let q = quietSince, now - q >= 3, now - lastDrop >= 40 {
                drop = true
                lastDrop = now
            }
            quietSince = nil
        }

        // Nothing playing: say nothing, so the wall settles instead of being
        // fed a stream of zeros that keeps the frame rate up.
        guard env > 0.0004 || drop else { return }
        guard drop || now - lastPost >= 1.0 / 30 else { return }
        lastPost = now
        DispatchQueue.main.async { [weak self] in
            if drop { Pulse.shared.play(.drop) }
            Pulse.shared.feed(lv)
            self?.onLevel?()
        }
    }

    // MARK: Helpers

    private static func defaultOutputUID() -> String? {
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                         &size, &dev) == noErr else { return nil }
        var uid: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        addr.mSelector = kAudioDevicePropertyDeviceUID
        let err = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, $0)
        }
        return err == noErr ? uid as String : nil
    }

    private static func tapSampleRate(_ tap: AudioObjectID) -> Double? {
        guard #available(macOS 14.2, *) else { return nil }
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &asbd) == noErr,
              asbd.mSampleRate > 0 else { return nil }
        return asbd.mSampleRate
    }
}
