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
//  While the setting is on, the Mac is awake and on AC power outside Low
//  Power, and only while another app is actually playing (`othersPlaying`,
//  polled by the host every two seconds). Silent for ten seconds and there is
//  no tap at all, not a paused one. On battery there is none either — a slow
//  version drawn at five frames a second looked awful; there only the album
//  cover's tinge remains (NowPlaying). The host calls `update(...)` whenever
//  any of that changes.
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
    func update(shouldRun: Bool, syncToEars: Bool = false) {
        if syncToEars != self.syncToEars {
            self.syncToEars = syncToEars
            if running { refreshHoldBack() }
        }
        if shouldRun && !running { start() }
        else if !shouldRun && running { stop() }
        else if running { refreshHoldBack() }
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
        let lag = Self.holdBack(syncToEars)
        queue.async { [weak self] in self?.syncDelay = lag; self?.heldBack = lag }
        NSLog("Elemental: music visualizer listening to system audio (in step %.0f ms later)", lag * 1000)
    }

    /// What the picture itself takes from sound to screen, seconds - measured
    /// stage by stage on 16 Nov 2026 (see the budget above `spectrumHop`).
    static let pictureDelay = 0.045

    /// How long to hold the levels back so they land with what is heard.
    private static func holdBack(_ on: Bool) -> Double { on ? max(0, outputLatency() - pictureDelay) : 0 }
    /// Opt-in (Config.musicSyncToEars): hold the picture back to match Bluetooth audio.
    private var syncToEars = false

    /// The output can change while music plays (AirPods in, AirPods out). The
    /// host calls `update` every two seconds; re-read the latency then, off
    /// the main thread - a HAL call can stall.
    private func refreshHoldBack() {
        let on = syncToEars
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let lag = Self.holdBack(on)
            self?.queue.async { self?.syncDelay = lag; self?.heldBack = lag }
        }
    }
    private var heldBack: Double = 0
    /// For status: milliseconds the levels are being held back right now.
    var holdBackMs: Int { queue.sync { Int((heldBack * 1000).rounded()) } }
    /// For status: analysis frames a second, and the audio buffer they come in.
    var analysisRate: Double { queue.sync { hopRate } }

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
    /// The analysis window. A plain Hann window is symmetric: it weighs the
    /// NEWEST audio at nearly nothing, so a kick only shows once it has moved
    /// to the middle of the 1024 samples - about 10 ms after it happened. This
    /// one rises like a Hann over the first 896 samples and falls over the last
    /// 128, so the newest sound is heard at full weight ~1.3 ms after it
    /// arrives, while the long rise keeps the low bands' frequency resolution.
    /// Scaled to the same energy as the normalised Hann it replaces, so levels
    /// are unchanged.
    private lazy var hann: [Float] = {
        let n = fftN, fall = 128, rise = n - fall
        var w = [Float](repeating: 0, count: n)
        for i in 0..<rise { w[i] = 0.5 - 0.5 * cos(Float.pi * Float(i) / Float(rise)) }
        for i in 0..<fall { w[rise + i] = 0.5 + 0.5 * cos(Float.pi * Float(i + 1) / Float(fall + 1)) }
        var ref = [Float](repeating: 0, count: n)
        vDSP_hann_window(&ref, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        let e0 = ref.reduce(0) { $0 + $1 * $1 }, e1 = w.reduce(0) { $0 + $1 * $1 }
        let k = (e0 / max(e1, 1e-9)).squareRoot()
        return w.map { $0 * k }
    }()
    /// Samples since the last analysis, and the analysis rate for status.
    private var hopSamples = 0
    private var hopRate: Double = 0
    private var ring = [Float](repeating: 0, count: 1024)
    /// 17 Nov: the two ears kept apart too, so the sky can show WHERE a sound sits.
    private var ringL = [Float](repeating: 0, count: 1024)
    private var ringR = [Float](repeating: 0, count: 1024)
    /// Seven listening bands (sub, bass, low-mid, mid, high-mid, presence, brilliance):
    /// passive level, active onset, pan (-1 left .. +1 right) and stereo width.
    static let bands7Hz: [Float] = [20, 60, 250, 500, 2000, 4000, 8000, 20000]
    private var b7Env = [Float](repeating: 0, count: 7)
    private var b7Peak = [Float](repeating: 1e-6, count: 7)
    private var b7Avg = [Float](repeating: 0, count: 7)
    private var b7Act = [Float](repeating: 0, count: 7)
    private var b7Pan = [Float](repeating: 0, count: 7)
    private var b7Wid = [Float](repeating: 0, count: 7)
    private var loudEnv: Float = 0
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
        // Left and right kept apart (17 Nov, "show from which direction in the
        // headphones the sound comes"); the mono ring is their average, exactly
        // the mix it always was. Interleaved: channel 0 and 1 of each frame.
        // Non-interleaved: buffer 0 is left, buffer 1 right. Mono: both the same.
        let bufs = abl.count
        guard bufs > 0, let d0 = abl[0].mData else { return }
        let ch0 = max(1, Int(abl[0].mNumberChannels))
        let frames = Int(abl[0].mDataByteSize) / MemoryLayout<Float>.size / ch0
        let p0 = d0.assumingMemoryBound(to: Float.self)
        var pR: UnsafeMutablePointer<Float>? = nil
        if bufs > 1, let d1 = abl[1].mData { pR = d1.assumingMemoryBound(to: Float.self) }
        let start = max(0, frames - fftN)              // only the last ring's worth can survive
        for f in start..<frames {
            let l: Float, r: Float
            if ch0 >= 2 { l = p0[f * ch0]; r = p0[f * ch0 + 1] }
            else if let pR { l = p0[f]; r = pR[f] }
            else { l = p0[f]; r = l }
            ring[ringPos] = 0.5 * (l + r)
            ringL[ringPos] = l; ringR[ringPos] = r
            ringPos = (ringPos + 1) % fftN
        }
        fresh += frames
        // Every buffer the device hands over is analysed as it arrives (it was
        // "every 512 samples", which with a 512-frame device is the same thing,
        // but with a smaller buffer waited for nothing).
        guard fresh >= 128 else { return }
        hopSamples = fresh
        fresh = 0
        spectrumHop()
    }

    //  ---- From sound to screen, in milliseconds (16 Nov 2026, "the music
    //  response is very delayed"; measured on AirPods Pro, 30 frames a second)
    //
    //                                        before            now
    //   audio buffer (512 frames)            5 avg, 11 worst   the same
    //   analysis window (newest sample)      ~10               ~1.3
    //   envelope attack                      ~8                ~2
    //   thirty-a-second throttle             17 avg, 33 worst  none
    //   main-queue hop + timer leeway        2, ±16 jitter     none
    //   wait for the next frame              17 avg, 33 worst  the same
    //   draw + present + compositor          ~25               the same
    //   ------------------------------------------------------------------
    //   the picture's own delay              ~85 avg, ~140     ~50 avg, ~75
    //
    //  The hold-back for the output device (AirPods report 171 ms) assumed the
    //  picture took 60 ms and added 50 ms "for Bluetooth" on top of what the
    //  device reports: 161 ms of waiting plus ~85 of picture = ~245 ms, against
    //  ~171 ms for the ear - about 75 ms LATE, wobbling by a frame or two. It
    //  now waits (reported latency - 45 ms) and nothing else.
    /// Seven bands with direction. One FFT per ear (two 1024-point FFTs, ~94 a second:
    /// well under a millisecond), then per band: the PASSIVE level (up at once, down
    /// over ~200 ms, against its own slow peak like the 24 bands), the ACTIVE onset
    /// (the band leaping above its own last ~250 ms, decaying over ~120 ms), the PAN
    /// from the two ears' energy and the WIDTH from how alike they are (identical =
    /// a centred mono sound, unrelated = wide). Returns 28 floats: 7 each.
    private func stereoBands(dt: Float, share: (Float) -> Float) -> [Float] {
        let n = fftN, half = n / 2
        func fft(_ src: [Float]) -> ([Float], [Float]) {
            var x = [Float](repeating: 0, count: n)
            for i in 0..<n { x[i] = src[(ringPos + i) % n] * hann[i] }
            var re = [Float](repeating: 0, count: half), im = [Float](repeating: 0, count: half)
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    x.withUnsafeBufferPointer { xp in
                        xp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(fftSetup, &split, 1, 10, FFTDirection(FFT_FORWARD))
                }
            }
            return (re, im)
        }
        let (lr, li) = fft(ringL), (rr, ri) = fft(ringR)
        let binHz = Float(sampleRate) / Float(n)
        var out = [Float](repeating: 0, count: 29)
        let peakDecay: Float = exp(-dt / 15.2)
        let loudest = b7Peak.max() ?? 1e-6
        for b in 0..<7 {
            let i0 = max(1, Int(Self.bands7Hz[b] / binHz)), i1 = max(i0 + 1, min(half, Int(Self.bands7Hz[b + 1] / binHz) + 1))
            var eL: Float = 0, eR: Float = 0, cr: Float = 0
            for i in i0..<i1 {
                eL += lr[i] * lr[i] + li[i] * li[i]
                eR += rr[i] * rr[i] + ri[i] * ri[i]
                cr += lr[i] * rr[i] + li[i] * ri[i]
            }
            let a = ((eL + eR) / Float(i1 - i0)).squareRoot()
            // passive
            b7Env[b] += (a > b7Env[b] ? share(0.003) : share(b < 3 ? 0.20 : 0.14)) * (a - b7Env[b])
            b7Peak[b] = max(b7Env[b], b7Peak[b] * peakDecay, 1e-6)
            let passive = min(1, b7Env[b] / max(b7Peak[b], loudest * 0.08))
            // active: a leap above its own recent average, judged on this hop's raw level
            let onset = b7Avg[b] > 1e-7 && a > b7Peak[b] * 0.2 ? max(0, min(1, (a / b7Avg[b] - 1.3) / 1.5)) : 0
            b7Avg[b] += share(0.25) * (a - b7Avg[b])
            b7Act[b] = max(onset, b7Act[b] * exp(-dt / 0.12))
            // direction: only where the band is actually sounding
            let e = eL + eR
            if e > 1e-9 && passive > 0.05 {
                let pan = max(-1, min(1, (eR - eL) / e))
                let coh = cr / max((eL * eR).squareRoot(), 1e-12)
                let wid = max(0, min(1, 1 - coh))
                b7Pan[b] += share(0.04) * (pan - b7Pan[b])
                b7Wid[b] += share(0.12) * (wid - b7Wid[b])
            } else {
                b7Pan[b] += share(0.6) * (0 - b7Pan[b])
            }
            out[b] = passive; out[7 + b] = b7Act[b]; out[14 + b] = b7Pan[b]; out[21 + b] = b7Wid[b]
        }
        // VOLUME (17 Nov, "add volume intensity support"): how loud it really is, not
        // against its own peak - every band above is normalised, so quiet and loud
        // music otherwise look alike. RMS of the newest ~10 ms in dBFS: -48 dB is 0,
        // -12 dB is 1. Up at once, down over ~300 ms.
        var rms: Float = 0
        let m = min(n, max(64, hopSamples))
        for i in 0..<m { let v = ring[(ringPos - 1 - i + n) % n]; rms += v * v }
        let db = 10 * log10(max(rms / Float(m), 1e-12))
        let loud = max(0, min(1, (db + 48) / 36))
        loudEnv += (loud > loudEnv ? share(0.003) : share(0.30)) * (loud - loudEnv)
        out[28] = loudEnv
        return out
    }

    private func spectrumHop() {
        let n = fftN, half = n / 2
        // Every rate below is per SECOND and turned into this hop's share, so
        // the feel is the same whatever buffer size the device uses.
        let dt = Float(max(64, hopSamples)) / Float(max(8000, sampleRate))
        hopRate = Double(1 / dt)
        func share(_ tau: Float) -> Float { 1 - exp(-dt / tau) }
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
        let peakDecay: Float = exp(-dt / 15.2)      // the slow peak forgets over ~15 s
        let loudest = bandPeak.max() ?? 1e-6
        var spec = [Float](repeating: 0, count: B)
        for k in 0..<B {
            let v = bands[k]
            // Up at once (3 ms), down as before (83 / 54 / 35 ms by band).
            let fall: Float = share(k < 8 ? 0.083 : (k < 16 ? 0.054 : 0.035))
            bandEnv[k] += (v > bandEnv[k] ? share(0.003) : fall) * (v - bandEnv[k])
            bandPeak[k] = max(bandEnv[k], bandPeak[k] * peakDecay, 1e-6)
            spec[k] = min(1, bandEnv[k] / max(bandPeak[k], loudest * 0.08))
        }

        let b7 = stereoBands(dt: dt, share: share)

        func mean(_ r: Range<Int>) -> Float { r.reduce(0) { $0 + spec[$1] } / Float(r.count) }
        let bass = Double(mean(0..<6)), mid = Double(mean(6..<15)), high = Double(mean(15..<B))
        let bassEnv = (bandEnv[0] + bandEnv[1] + bandEnv[2] + bandEnv[3] + bandEnv[4] + bandEnv[5]) / 6
        env = bassEnv
        peak = max(env, peak * peakDecay, 1e-6)

        let now = CFAbsoluteTimeGetCurrent()
        latest = bass

        // A BEAT: the bass jumping well above its recent average - judged on
        // the RAW bass of this buffer, not the envelope, so it fires on the
        // buffer the kick arrives in.
        let rawBass = (bands[0] + bands[1] + bands[2] + bands[3] + bands[4] + bands[5]) / 6
        bassAvg += share(0.208) * (rawBass - bassAvg)
        var beat = false
        if rawBass > bassAvg * 1.35 && rawBass > peak * 0.30 && now - lastBeat > 0.18 {
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
        // In step with what is HEARD, not with what is played: the tap hears
        // the sound before the output does (AirPods play it ~170 ms later). So
        // every frame goes to Pulse now, stamped with the moment it is due -
        // the output's latency less what the picture takes - and the renderer
        // picks it up on the frame that moment falls in.
        Pulse.shared.feedSpectrum(spec, bass: bass, mid: mid, high: high, beat: beat, after: syncDelay, bands7: b7)
        if drop {
            DispatchQueue.main.asyncAfter(deadline: .now() + syncDelay) { Pulse.shared.play(.drop) }
        }
        // The host only needs telling that music is on (it lifts the frame
        // rate); four times a second is plenty.
        if now - lastPost >= 0.25 {
            lastPost = now
            DispatchQueue.main.async { [weak self] in self?.onLevel?() }
        }
    }

    // MARK: Helpers

    /// Whether any OTHER process is sending audio to an output right now —
    /// the silence gate the host polls. Our own process is skipped: the
    /// aggregate device would otherwise keep the answer yes forever.
    static func othersPlaying() -> Bool {
        guard #available(macOS 14.2, *) else { return true }
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return false }
        let me = getpid()
        for id in ids {
            var pid: pid_t = 0
            var ps = UInt32(MemoryLayout<pid_t>.size)
            addr.mSelector = kAudioProcessPropertyPID
            if AudioObjectGetPropertyData(id, &addr, 0, nil, &ps, &pid) == noErr, pid == me { continue }
            var run: UInt32 = 0
            var rs = UInt32(MemoryLayout<UInt32>.size)
            addr.mSelector = kAudioProcessPropertyIsRunningOutput
            if AudioObjectGetPropertyData(id, &addr, 0, nil, &rs, &run) == noErr, run != 0 { return true }
        }
        return false
    }

    /// Seconds to hold the visuals back (see the post above). Read when the
    /// meter starts, i.e. whenever playback begins after silence.
    private var syncDelay: Double = 0

    /// How long the default output takes to play what it is handed, seconds:
    /// device latency, safety offset, its buffer and its stream's latency —
    /// plus what Bluetooth adds beyond what it reports.
    private static func outputLatency() -> Double {
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                         &size, &dev) == noErr else { return 0 }
        func u32(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> UInt32 {
            var v: UInt32 = 0, s = UInt32(4)
            var a = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            return AudioObjectGetPropertyData(dev, &a, 0, nil, &s, &v) == noErr ? v : 0
        }
        var rate: Float64 = 48_000
        var rs = UInt32(MemoryLayout<Float64>.size)
        addr.mSelector = kAudioDevicePropertyNominalSampleRate
        AudioObjectGetPropertyData(dev, &addr, 0, nil, &rs, &rate)
        var frames = u32(kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput)
            + u32(kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput)
            + u32(kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal)
        // The output stream's own latency.
        var ss = UInt32(0)
        addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                          mScope: kAudioObjectPropertyScopeOutput,
                                          mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &ss) == noErr, ss >= 4 {
            var streams = [AudioStreamID](repeating: 0, count: Int(ss) / 4)
            if AudioObjectGetPropertyData(dev, &addr, 0, nil, &ss, &streams) == noErr, let st = streams.first {
                var l: UInt32 = 0, ls = UInt32(4)
                var la = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyLatency,
                                                    mScope: kAudioObjectPropertyScopeGlobal,
                                                    mElement: kAudioObjectPropertyElementMain)
                if AudioObjectGetPropertyData(st, &la, 0, nil, &ls, &l) == noErr { frames += l }
            }
        }
        // What the device reports, and nothing added: a guessed extra 50 ms
        // "for Bluetooth" sat here and put the picture behind the ear. Early by
        // a few milliseconds reads as in time; late by the same does not.
        let secs = Double(frames) / max(rate, 8000)
        return min(0.5, secs)
    }

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
