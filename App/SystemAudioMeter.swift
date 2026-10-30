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
import Accelerate

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
    private var env: Float = 0
    private var peak: Float = 1e-4
    private var bassAvg: Float = 0      // ~0.4 s average, the baseline a beat rises from
    private var lastBeat: CFAbsoluteTime = 0
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
            self.env = 0; self.bassAvg = 0; self.quietSince = nil; self.latest = 0
            self.bandEnv = [Float](repeating: 0, count: Self.bandCount)
            self.ring = [Float](repeating: 0, count: 1024); self.fresh = 0
        }
    }

    deinit { teardown() }

    // MARK: Analysis — on `queue` only

    // ---- spectrum: touched only on `queue`
    static let bandCount = 24
    private let fftN = 1024
    private lazy var fftSetup: FFTSetup = vDSP_create_fftsetup(10, FFTRadix(kFFTRadix2))!
    private lazy var hann: [Float] = {
        var w = [Float](repeating: 0, count: fftN)
        vDSP_hann_window(&w, vDSP_Length(fftN), Int32(vDSP_HANN_NORM))
        return w
    }()
    private var ring = [Float](repeating: 0, count: 1024)
    private var ringPos = 0
    private var fresh = 0
    private var bandEnv = [Float](repeating: 0, count: SystemAudioMeter.bandCount)
    private var bandPeak = [Float](repeating: 1e-6, count: SystemAudioMeter.bandCount)

    /// ALL OF IT, not only the bass. The first version split the signal into
    /// three bands with two one-pole filters, and the wall answered mostly the
    /// kick. Now every hop (~10 ms of new audio) runs a 1024-point FFT with a
    /// Hann window and folds it into 24 bands spaced logarithmically from 40 Hz
    /// to 16 kHz — the way an ear hears pitch — each with its own envelope and
    /// its own slow peak, so the hats and the voice move as much as the kick
    /// instead of being drowned by it. Bass, mids and highs and the beat are
    /// derived from the same bands.
    private func analyse(_ list: UnsafePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        // Mono, into the ring: interleaved buffers are averaged across their
        // channels; non-interleaved ones arrive as one buffer per channel and
        // are each added at half weight, which is a mono mix in either case.
        let bufs = abl.count
        for buf in abl {
            guard let data = buf.mData else { continue }
            let ch = max(1, Int(buf.mNumberChannels))
            let frames = Int(buf.mDataByteSize) / MemoryLayout<Float>.size / ch
            let p = data.assumingMemoryBound(to: Float.self)
            let w = 1 / Float(ch * max(1, bufs))
            for f in 0..<frames {
                var m: Float = 0
                for c in 0..<ch { m += p[f * ch + c] }
                if bufs > 1 && buf.mData != abl[0].mData {
                    // a later channel buffer: add onto the samples just written
                    let at = (ringPos - frames + f + fftN * 2) % fftN
                    ring[at] += m * w
                } else {
                    ring[ringPos] = m * w
                    ringPos = (ringPos + 1) % fftN
                    fresh += 1
                }
            }
        }
        guard fresh >= 512 else { return }
        fresh = 0
        spectrumHop()
    }

    private func spectrumHop() {
        let n = fftN, half = n / 2
        // Oldest-first copy of the ring, windowed.
        var x = [Float](repeating: 0, count: n)
        for i in 0..<n { x[i] = ring[(ringPos + i) % n] * hann[i] }
        var re = [Float](repeating: 0, count: half), im = [Float](repeating: 0, count: half)
        var power = [Float](repeating: 0, count: half)
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                x.withUnsafeBufferPointer { xp in
                    xp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, 10, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(half))
            }
        }

        // Fold into log-spaced bands, 40 Hz to 16 kHz.
        let B = Self.bandCount
        let binHz = Float(sampleRate) / Float(n)
        var bands = [Float](repeating: 0, count: B)
        for k in 0..<B {
            let f0 = 40 * pow(400, Float(k) / Float(B))
            let f1 = 40 * pow(400, Float(k + 1) / Float(B))
            let i0 = max(1, Int(f0 / binHz)), i1 = max(i0 + 1, min(half, Int(f1 / binHz) + 1))
            var acc: Float = 0
            for i in i0..<i1 { acc += power[i] }
            bands[k] = (acc / Float(i1 - i0)).squareRoot()
        }

        // Envelope and normalisation per band: quick rise, ~150 ms fall
        // (faster up top, where sounds are short), each against its own
        // decaying peak — but never against less than a fraction of the
        // loudest band, or a silent band would amplify its own noise.
        let loudest = bandPeak.max() ?? 1e-6
        var spec = [Float](repeating: 0, count: B)
        for k in 0..<B {
            let v = bands[k]
            let fall: Float = k < 8 ? 0.12 : (k < 16 ? 0.18 : 0.26)
            bandEnv[k] += (v > bandEnv[k] ? 0.6 : fall) * (v - bandEnv[k])
            bandPeak[k] = max(bandEnv[k], bandPeak[k] * 0.9993, 1e-6)
            spec[k] = min(1, bandEnv[k] / max(bandPeak[k], loudest * 0.08))
        }

        func mean(_ r: Range<Int>) -> Float { r.reduce(0) { $0 + spec[$1] } / Float(r.count) }
        let bass = Double(mean(0..<6)), mid = Double(mean(6..<15)), high = Double(mean(15..<B))
        let bassEnv = (bandEnv[0] + bandEnv[1] + bandEnv[2] + bandEnv[3] + bandEnv[4] + bandEnv[5]) / 6
        env = bassEnv
        peak = max(env, peak * 0.9993, 1e-6)

        let now = CFAbsoluteTimeGetCurrent()
        latest = bass

        // A BEAT: the bass jumping well above its half-second average.
        bassAvg += 0.05 * (env - bassAvg)
        var beat = false
        if env > bassAvg * 1.35 && env > peak * 0.30 && now - lastBeat > 0.18 {
            beat = true
            lastBeat = now
        }

        // A drop: quiet for three seconds, then back above three quarters.
        var drop = false
        if env < peak * 0.35 && peak > 1e-4 {
            if quietSince == nil { quietSince = now }
        } else if env > peak * 0.75 {
            if let q = quietSince, now - q >= 3, now - lastDrop >= 40 {
                drop = true
                lastDrop = now
            }
            quietSince = nil
        }

        // Nothing playing: say nothing, so the wall settles.
        let total = bands.reduce(0, +)
        guard total > 1e-4 || drop else { return }
        guard drop || beat || now - lastPost >= 1.0 / 30 else { return }
        lastPost = now
        let out = spec
        DispatchQueue.main.async { [weak self] in
            if drop { Pulse.shared.play(.drop) }
            Pulse.shared.feedSpectrum(out, bass: bass, mid: mid, high: high, beat: beat)
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
