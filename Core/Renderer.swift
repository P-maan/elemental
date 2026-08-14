//  Renderer.swift — Metal host for the mosaic engine.
//
//  Three properties this has to hold, because they are what the wallpaper is
//  judged on:
//
//    1. Allocate once. Textures, pipelines and buffers are built on resize and
//       never on a frame. The wallpaper runs for weeks.
//    2. Idling is free and waking is instant. Nothing is torn down when the
//       desktop is covered — we simply stop asking for frames. The scene is a
//       function of wall-clock time, so the first frame after waking is already
//       correct.
//    3. No file or network I/O at runtime. The shader source is compiled into
//       the binary, which is what lets the same renderer run inside the
//       screensaver's sandbox.

import Metal
import QuartzCore
import simd

final class ElementalRenderer {

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private var cellPS: MTLRenderPipelineState!
    private var heightPS: MTLRenderPipelineState!
    /// `heightPS` with blending on, so a new height eases into the old one
    /// instead of replacing it. See `buildPipelines`.
    private var heightRisePS: MTLRenderPipelineState!
    private var presentPS: MTLRenderPipelineState!
    private var glassPS: MTLRenderPipelineState!

    /// Pass A target: one texel per mosaic cell.
    private var cellTex: MTLTexture?
    /// Pass H target: the relief height of each cell, same grid as cellTex.
    /// Its own pass because the raycast reads a height ten times per pixel and
    /// a good height needs to see a cell's neighbourhood — see PASS H.
    private var heightTex: MTLTexture?
    /// Pass A's second target: how much of what is behind the cloud still gets
    /// through, per cell. The full-res pass knows where the moon is but not what
    /// is in front of it; this is what tells it.
    private var auxTex: MTLTexture?
    /// Per-cell water lookup for the presentation pass.
    private var glassTex: MTLTexture?
    /// Rain rasterised per cell, so streaks can lean with the wind.
    private var streakTex: MTLTexture?
    private var streakFineTex: MTLTexture?

    private let sim = SceneSimulation()

    /// Simulation counters, for the offscreen harness.
    ///
    /// `SceneSimulation.debugCounts` existed and was reachable from nowhere, so
    /// "is the water actually running?" could only be answered by staring at a
    /// PNG and guessing. Splash counts, film coverage and surface state are all
    /// in there; exposing it is what turns a visual hunch into a measurement.
    public var waterDebug: String { sim.debugCounts }

    /// Things on screen for water to land on. The wallpaper sets the dock and
    /// menu bar; the saver sets the lock screen's clock.
    var surfaces: [Surface] {
        get { sim.surfaces }
        set { sim.surfaces = newValue }
    }

    // MARK: Scene state, and the weather transition layer
    //
    // `state` looks like a plain stored property and deliberately still reads
    // like one at every call site — hosts assign `renderer.state.weather = w`,
    // `renderer.state.astro = a` or a whole `SceneState` and nothing about that
    // changed. What it does now is separate the two halves of a weather update:
    //
    //   the READING, which is where the sky is going, and
    //   the SCENE, which is where it has got to.
    //
    // A fetch sets the first. The second chases it, once per frame, at a rate
    // that depends on which quantity it is — see `WeatherEaser`. Doing it here
    // rather than in each host means every surface gets it for free: desktop,
    // lock still, screen saver and the previews all go through this renderer.
    private var _state = SceneState()
    private var easer = WeatherEaser()

    var state: SceneState {
        get { _state }
        set {
            let incoming = newValue.weather
            _state = newValue
            if easesTransitions {
                // Only a genuinely NEW reading retargets, and the two things
                // that are not one are both routine:
                //
                //   `state.astro = a`, once a minute, carries the weather it
                //   read a line earlier straight back in; and
                //
                //   every host applies settings by reading the whole state,
                //   changing the appearance fields and writing it back — which
                //   hands us the value we are part-way THROUGH easing to. Taken
                //   as a reading, that pins the target to wherever the sky had
                //   got to and the transition stops dead, so touching any
                //   slider in Settings would freeze the weather mid-move.
                //
                // So a write is a reading only when it matches neither what we
                // are showing nor what we are already heading for.
                if incoming != easer.target && incoming != easer.shown {
                    // A move to a different place adopts its sky outright — see
                    // `locationChanged()`. The flag is consumed here rather than
                    // at the move itself because this is the first moment the
                    // NEW place's weather actually exists.
                    if snapNextReading {
                        snapNextReading = false
                        easer.snap(to: incoming)
                    } else {
                        easer.retarget(incoming)
                    }
                }
                _state.weather = easer.shown
            } else {
                easer.snap(to: incoming)
            }
        }
    }

    /// Force the transition layer on or off. `nil` — the default — means
    /// automatic: eased on a live surface, snapped in the offscreen stills
    /// exporter, which sets `fixedTimeStep` and whose whole contract is that
    /// one call renders one settled frame rather than the start of a movement.
    ///
    /// Governs the relief rise as well as the weather, because they are the
    /// same question: is this a scene that is running, or a picture of one.
    var easeTransitions: Bool?

    private var easesTransitions: Bool { easeTransitions ?? (fixedTimeStep == nil) }

    /// What the last fetch actually said, as opposed to what is being drawn.
    var weatherTarget: WeatherState { easer.target }

    // Persistent buffers. Sized generously on resize, never reallocated per frame.
    private var uniformBuf: MTLBuffer!
    private var breatherBuf: MTLBuffer!
    private var starBuf: MTLBuffer!
    private var streakBuf: MTLBuffer!
    private var colIndexBuf: MTLBuffer!
    private var boltBuf: MTLBuffer!
    private var edgeBuf: MTLBuffer!

    private static let maxStars = 128
    private static let maxStreaks = 256
    private static let maxBolt = 128
    private static let maxGlassQuads = 2048
    private var glassBuf: MTLBuffer!

    // Scene clock. Kept in Double on the CPU and handed to the shader as a
    // Float, which stays exact for a few thousand seconds. The origin is
    // rebased whenever we wake from an idle — i.e. at a moment when nothing was
    // on screen, so the rebase is invisible. A machine that sits on an
    // uncovered desktop for days without ever idling will slowly lose sub-frame
    // precision in the drift terms; nothing else.
    /// The heading actually in use, eased toward the target. In fixed mode the
    /// target is a constant so this settles instantly; in moving mode it tracks
    /// the sun, and the easing is what turns the sun-to-moon handover at dusk
    /// into a slow pan rather than a jump cut.
    private var smoothedFacing: Float = .nan

    private var sceneTime: Double = 0
    private var lastFrameHost: CFTimeInterval = 0
    private var haveClock = false

    /// Set by `markIdle()` and cleared by the frame that follows it. This is
    /// the ONLY thing that makes a gap count as an idle.
    ///
    /// It used to be inferred from the length of the gap — anything over a
    /// second was treated as a wake — and that inference is what turned every
    /// hiccup into the stall-and-jump this file exists to avoid. A busy run
    /// loop produces gaps of exactly the same size as a short occlusion, so
    /// the two are indistinguishable by duration and have to be told apart by
    /// someone who knows: the host that stopped asking for frames.
    private var idleAnnounced = false

    /// Longest interval one frame may advance the scene by.
    ///
    /// The procedural clock has no external referent — nothing outside this
    /// renderer knows what `sceneTime` reads — so dropping a stalled interval
    /// is invisible, while replaying it inside a single frame is precisely the
    /// jump. Astronomy is not on this clock: the sun and moon come from
    /// `state.astro`, which is wall-clock and stays correct across any gap.
    private static let maxFrameStep: Double = 0.1

    /// Scene seconds after which `Float(sceneTime)` is coarse enough to show.
    /// The fastest term in the shader runs at 1.7 rad/s; at 2^18 seconds a
    /// Float step is 1/32 s, i.e. 0.05 rad, which is still well under a frame.
    /// Past that it grows, so the clock is rebased at the next idle.
    private static let clockRebaseAfter: Double = 262_144

    /// Supplies astronomy for an arbitrary instant. Set by whichever host owns
    /// this renderer. Required for wake playback — without it the renderer has
    /// no way to know what the sky looked like during the gap.
    var astroProvider: ((Date) -> AstroState)?

    /// Replay the time that passed while we were not drawing, instead of
    /// cutting straight to now. See `beginPlaybackIfNeeded`.
    var playbackOnWake = true

    /// Longest a wake replay may run, in real seconds. Longer gaps still earn
    /// longer replays, but never more than this.
    var playbackMaxSeconds: Double = 5

    private struct Playback {
        let gap: Double         // real seconds skipped
        let duration: Double    // how long the replay runs, in real seconds
        var elapsed: Double = 0
    }
    private var playback: Playback?

    /// Gaps shorter than this resume instantly. Swiping to a fullscreen app and
    /// back is a few seconds, and replaying that would be slower and worse than
    /// simply carrying on — the whole point of the wall-clock scene is that a
    /// short gap costs nothing.
    private static let playbackMinGap: Double = 600      // 10 minutes

    /// True while a wake replay is running.
    private(set) var isPlayingBack = false

    /// When set, frames advance by this fixed step instead of by real elapsed
    /// time. Only the offscreen still exporter uses it: it renders in a tight
    /// loop where real dt is near zero, so the integrators would never move and
    /// rain would never appear. The live paths leave this nil.
    var fixedTimeStep: Float?

    /// Multiplier on how fast the scene itself moves, independent of frame
    /// rate. Frame rate is how often it is drawn; this is how fast the world
    /// runs. Below 1 the clouds drift, the light breathes and the rain falls
    /// more slowly, which reads as calmer without costing any less to draw.
    var motionSpeed: Double = 1.0

    /// Display headroom to render the emissive sources into: 1 is plain SDR and
    /// anything above is how far past white this frame may go.
    ///
    /// Set by whoever owns the surface, from
    /// `NSScreen.maximumExtendedDynamicRangeColorComponentValue`, EVERY FRAME —
    /// it is not a property of the panel. It moves with the brightness slider,
    /// with Low Power Mode and with thermal state, and it collapses to 1 the
    /// moment the compositor stops granting EDR. Left at 1 the shader's EDR
    /// path is inert and the render is bit-identical to the SDR one.
    ///
    /// Note that the WALLPAPER can never raise this above 1: macOS does not
    /// grant EDR to windows below the normal window level. Measured, not
    /// assumed — see `WallpaperSurface.refreshHeadroom`.
    var edrHeadroom: Float = 1

    private(set) var pixelWidth: Int = 0
    private(set) var pixelHeight: Int = 0
    /// Grid pitch the current textures were built for. Tracked separately from
    /// the pixel size because changing the row count changes the cell grid
    /// without the display resizing at all.
    private var builtGridRows: Int = 0

    /// Colour format of the presentation target. Defaults to rgba16Float so the
    /// engine can carry values above 1.0 into EDR on displays with the
    /// headroom; the offscreen still exporter asks for 8-bit instead.
    let colorFormat: MTLPixelFormat

    // MARK: - Setup

    init?(device: MTLDevice? = nil, colorFormat: MTLPixelFormat = .rgba16Float) {
        guard let dev = device ?? MTLCreateSystemDefaultDevice(),
              let q = dev.makeCommandQueue() else { return nil }
        self.device = dev
        self.queue = q
        self.colorFormat = colorFormat
        do { try buildPipelines() } catch {
            NSLog("Elemental: pipeline build failed: \(error)")
            return nil
        }
        buildBuffers()
    }

    private func buildPipelines() throws {
        // Compiled from source at runtime: no .metallib, no Metal toolchain
        // needed to build the project, and no file read at load time.
        let library = try device.makeLibrary(source: ShaderSource.metal, options: nil)

        let cellDesc = MTLRenderPipelineDescriptor()
        cellDesc.vertexFunction = library.makeFunction(name: "fullscreenVS")
        cellDesc.fragmentFunction = library.makeFunction(name: "cellPass")
        cellDesc.colorAttachments[0].pixelFormat = .rgba16Float
        // Attachment 1: per-cell cloud transmission, for the full-res pass. See
        // the CellOut note in Scene.metal.
        cellDesc.colorAttachments[1].pixelFormat = .r16Float
        cellPS = try device.makeRenderPipelineState(descriptor: cellDesc)

        let heightDesc = MTLRenderPipelineDescriptor()
        heightDesc.vertexFunction = library.makeFunction(name: "fullscreenVS")
        heightDesc.fragmentFunction = library.makeFunction(name: "heightPass")
        heightDesc.colorAttachments[0].pixelFormat = .r16Float
        heightPS = try device.makeRenderPipelineState(descriptor: heightDesc)

        // ---- the same pass, blended into the height already standing.
        //
        // The relief height is produced per cell by `heightPass` from that
        // cell's prominence, and was ASSIGNED: a block whose target height
        // changed was at the new height in the very next frame, which is the
        // snap the rise setting exists to remove. Easing it wants to happen
        // exactly where the height is fed, per cell, and the cheapest correct
        // place to do that is the blend unit: with
        //
        //     src * blendColor + dst * (1 - blendColor)
        //
        // and the previous frame's height loaded as the destination, one pass
        // over a few thousand texels IS the exponential approach, at no cost,
        // with no second texture and without touching the shader. `blendColor`
        // is set per frame from dt and the setting — see `riseAlpha`.
        let riseDesc = MTLRenderPipelineDescriptor()
        riseDesc.vertexFunction = library.makeFunction(name: "fullscreenVS")
        riseDesc.fragmentFunction = library.makeFunction(name: "heightPass")
        let ha = riseDesc.colorAttachments[0]!
        ha.pixelFormat = .r16Float
        ha.isBlendingEnabled = true
        ha.rgbBlendOperation = .add
        ha.alphaBlendOperation = .add
        ha.sourceRGBBlendFactor = .blendColor
        ha.destinationRGBBlendFactor = .oneMinusBlendColor
        ha.sourceAlphaBlendFactor = .blendAlpha
        ha.destinationAlphaBlendFactor = .oneMinusBlendAlpha
        heightRisePS = try device.makeRenderPipelineState(descriptor: riseDesc)

        let presentDesc = MTLRenderPipelineDescriptor()
        presentDesc.vertexFunction = library.makeFunction(name: "fullscreenVS")
        presentDesc.fragmentFunction = library.makeFunction(name: "presentPass")
        presentDesc.colorAttachments[0].pixelFormat = colorFormat
        presentPS = try device.makeRenderPipelineState(descriptor: presentDesc)

        // Glass overlay: instanced quads composited over the finished mosaic.
        let glassDesc = MTLRenderPipelineDescriptor()
        glassDesc.vertexFunction = library.makeFunction(name: "glassVS")
        glassDesc.fragmentFunction = library.makeFunction(name: "glassFS")
        let ca = glassDesc.colorAttachments[0]!
        ca.pixelFormat = colorFormat
        ca.isBlendingEnabled = true
        ca.rgbBlendOperation = .add
        ca.alphaBlendOperation = .add
        ca.sourceRGBBlendFactor = .one            // fragment returns premultiplied
        ca.sourceAlphaBlendFactor = .one
        ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
        ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        glassPS = try device.makeRenderPipelineState(descriptor: glassDesc)
    }

    private func buildBuffers() {
        let opt: MTLResourceOptions = .storageModeShared
        uniformBuf  = device.makeBuffer(length: MemoryLayout<Uniforms>.stride, options: opt)
        breatherBuf = device.makeBuffer(length: MemoryLayout<GPUBreather>.stride * 3, options: opt)
        starBuf     = device.makeBuffer(length: MemoryLayout<GPUStar>.stride * Self.maxStars, options: opt)
        streakBuf   = device.makeBuffer(length: MemoryLayout<GPUStreak>.stride * Self.maxStreaks, options: opt)
        boltBuf     = device.makeBuffer(length: MemoryLayout<GPUBoltPt>.stride * Self.maxBolt, options: opt)
        glassBuf    = device.makeBuffer(length: MemoryLayout<GlassQuad>.stride * Self.maxGlassQuads, options: opt)
    }

    // MARK: - Resize

    /// Rebuild the grid and the Pass A texture. Called on a real size change
    /// only — never when waking from an idle.
    func resize(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        // Rebuild when the display size changes OR when the requested row count
        // does — the latter leaves the pixel dimensions identical, so testing
        // only those silently ignored every change to the mosaic pitch.
        guard width != pixelWidth || height != pixelHeight
                || state.gridRows != builtGridRows
        else { return }
        pixelWidth = width
        pixelHeight = height
        builtGridRows = state.gridRows
        sim.resize(pixelWidth: Float(width), pixelHeight: Float(height), gridRows: state.gridRows)

        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: sim.cols, height: sim.rows, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        cellTex = device.makeTexture(descriptor: d)

        let h = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Float, width: sim.cols, height: sim.rows, mipmapped: false)
        h.usage = [.renderTarget, .shaderRead]
        h.storageMode = .private
        heightTex = device.makeTexture(descriptor: h)
        // A fresh texture has undefined contents; nothing may blend against it
        // until one full write has landed.
        heightPrimed = false

        let ax = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Float, width: sim.cols, height: sim.rows, mipmapped: false)
        ax.usage = [.renderTarget, .shaderRead]
        ax.storageMode = .private
        auxTex = device.makeTexture(descriptor: ax)

        let g = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: sim.cols, height: sim.rows, mipmapped: false)
        g.usage = [.shaderRead]
        g.storageMode = .shared
        glassTex = device.makeTexture(descriptor: g)

        let st = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float, width: sim.cols, height: sim.rows, mipmapped: false)
        st.usage = [.shaderRead]
        st.storageMode = .shared
        streakTex = device.makeTexture(descriptor: st)

        let sf = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float,
            width: sim.cols * SceneSimulation.streakSub,
            height: sim.rows * SceneSimulation.streakSub, mipmapped: false)
        sf.usage = [.shaderRead]
        sf.storageMode = .shared
        streakFineTex = device.makeTexture(descriptor: sf)

        let opt: MTLResourceOptions = .storageModeShared
        colIndexBuf = device.makeBuffer(length: MemoryLayout<SIMD2<Int32>>.stride * max(1, sim.cols), options: opt)
        edgeBuf     = device.makeBuffer(length: MemoryLayout<Float>.stride * max(1, sim.cols), options: opt)
    }

    // MARK: - Clock

    /// Advance the scene clock. `elapsed` is real time since the last frame,
    /// however long we were idle for.
    private func advanceClock() -> (sec: Float, dt: Float, wasIdle: Float) {
        if let step = fixedTimeStep {
            sceneTime += Double(step)
            return (Float(sceneTime), step, 0)
        }
        let now = CACurrentMediaTime()
        if !haveClock {
            // First frame of this renderer's life. There is no previous frame
            // to measure against, so there is no gap and nothing to catch up.
            lastFrameHost = now
            haveClock = true
            idleAnnounced = false
        }
        // The true wall gap since the last frame we DREW. `markIdle` no longer
        // touches `lastFrameHost`, so this reads correctly whether we stopped
        // on purpose or the run loop simply took the time away from us.
        let gap = max(0, now - lastFrameHost)
        lastFrameHost = now

        let wasIdle = idleAnnounced
        idleAnnounced = false

        // Rebase the origin only across an announced idle — a moment when
        // nothing was on screen — and only once the Float handed to the shader
        // has actually gone coarse. Rebasing restarts every drift term in the
        // scene at once, so doing it while anyone is looking is a jump; doing
        // it on every hiccup, which is what this used to do, is the bug.
        //
        // The simulation holds absolute timestamps off this clock (the next
        // lightning strike, the next shooting star). Left alone across a
        // rebase they sit far in the future and simply stop firing until the
        // clock climbs back to meet them, which is hours. Re-seeding anchors
        // them to the new origin.
        if wasIdle && gap > 1.0 && sceneTime > Self.clockRebaseAfter {
            sceneTime = 0
            sim.seed(now: 0)
        }

        // One frame advances the scene by at most one frame's worth, however
        // long the frame took to arrive.
        let step = min(Self.maxFrameStep, gap * motionSpeed)
        sceneTime += step
        // A gap is only reported as an idle when a host said so. Everything
        // downstream that catches up — the wake replay and the integrator
        // fast-forward — keys off this, and neither should ever fire because
        // the main thread was busy.
        return (Float(sceneTime), Float(step), wasIdle ? Float(gap) : 0)
    }

    /// Call when the renderer stops being asked for frames, so the next frame
    /// knows the gap was deliberate rather than a stall.
    func markIdle() {
        idleAnnounced = true
        // A replay describes a gap that has now been superseded by a longer
        // one. Finishing it after the fact would replay the wrong interval,
        // and leaving it in flight pins `isPlayingBack` true — which makes the
        // host stop pushing astronomy, so the sky would stop for good.
        playback = nil
        isPlayingBack = false
    }

    /// The scene is now somewhere else. Drops anything still falling from the
    /// old sky, and leaves the water already on the glass alone.
    /// The scene is now drawing somewhere else.
    ///
    /// Clears the falling rain — that water belonged to the sky we just left —
    /// and, critically, ARMS THE EASER TO SNAP rather than ease.
    ///
    /// Easing exists for weather EVOLVING IN ONE PLACE: cloud thickening over
    /// half an hour, rain ramping in over minutes. A different city is not an
    /// evolution of the old one, it is a different sky, and easing between them
    /// means the old city's weather stays on screen while it crawls toward the
    /// new reading — precipitation over 45 to 300 seconds, cloud over 7 to 45
    /// minutes. Switch from a wet city to a dry one and it keeps raining for
    /// minutes, which reads as "location switching is broken" and is exactly
    /// what it looked like.
    ///
    /// A flag rather than a snap here, because the new reading has not arrived
    /// yet: the fetch is still in flight. Snapping now would only re-adopt the
    /// weather we are trying to leave. The next genuinely new reading takes
    /// effect immediately, and easing resumes after it.
    func locationChanged() {
        sim.locationChanged(now: Float(sceneTime))
        snapNextReading = true
    }

    /// Set by `locationChanged()`, consumed by the next reading. See above.
    private var snapNextReading = false

    /// Whatever meteor shower is running, pushed by the host.
    ///
    /// Set alongside astro, from `Astro.activeShower`, because it is the same
    /// kind of fact and needs the same inputs — where you are and when it is.
    /// The renderer projects the radiant rather than the host doing it, so the
    /// screen mapping stays in one place next to the shader's own.
    var meteorShower: (perHour: Float, alt: Float, az: Float)?

    /// The Swift twin of `astroXY` in Scene.metal.
    ///
    /// Mirrored deliberately and kept next to its only caller. The radiant has
    /// to land where the shader would put a star at the same coordinates, so
    /// this must agree exactly — 190 degrees of azimuth across the width, 85 of
    /// altitude down the height. If Scene.metal's astroXY ever changes, this
    /// changes with it.
    static func astroToScreen(alt: Float, az: Float, facing: Float,
                              w: Float, h: Float) -> (x: Float, y: Float) {
        let relAz = (az - facing + 180 + 360).truncatingRemainder(dividingBy: 360) - 180
        return ((0.5 + relAz / 190) * w, (1 - alt / 85) * h)
    }

    var debugCounts: String { sim.debugCounts }

    // MARK: - Wake playback
    //
    // Coming back from sleep, a closed lid, or a long stretch behind a
    // fullscreen app, cutting straight to the current sky is jarring: the sun
    // teleports. Instead the scene replays the interval it missed — sped up and
    // decelerating — so you watch the hours that passed go by and settle into
    // now. It lives here rather than in a host so every way of resuming gets it:
    // desktop wallpaper, screen saver, wake, unlock, un-occlude.

    private func beginPlaybackIfNeeded(gap: Double) {
        guard playbackOnWake, astroProvider != nil, playback == nil,
              gap.isFinite, gap >= Self.playbackMinGap else { return }
        // Longer gaps earn a longer replay, but sub-linearly — a night away
        // should not take four times as long to replay as an afternoon.
        let ceiling = max(0.8, playbackMaxSeconds)
        let d = min(ceiling, ceiling * 0.3 + log2(gap / Self.playbackMinGap) * (ceiling * 0.14))
        playback = Playback(gap: gap, duration: max(0.8, d))
        isPlayingBack = true
    }

    /// Drive one frame of the replay, returning a clock that runs on simulated
    /// time. Eases out, so it rushes at first and glides into real time rather
    /// than stopping dead.
    private func advancePlayback(dt: Float, clock: (sec: Float, dt: Float, wasIdle: Float))
        -> (sec: Float, dt: Float, wasIdle: Float)
    {
        guard var pb = playback else { return clock }
        pb.elapsed += Double(dt)
        let t = min(1, pb.elapsed / pb.duration)
        let eased = 1 - pow(1 - t, 3)                     // ease-out cubic

        // Where in the missed interval we are showing.
        let behind = pb.gap * (1 - eased)
        if let provider = astroProvider {
            state.astro = provider(Date().addingTimeInterval(-behind))
        }

        // The mosaic's own motion accelerates too, so clouds and light visibly
        // rush past rather than the sky simply changing colour underneath a
        // static scene.
        let speed = Double(1 + (59 * pow(1 - t, 2)))      // 60x -> 1x
        sceneTime += Double(dt) * speed

        if t >= 1 {
            playback = nil
            isPlayingBack = false
        } else {
            playback = pb
        }
        return (Float(sceneTime), dt * Float(min(speed, 8)), 0)
    }

    // MARK: - Frame

    /// `waitForCompletion` is for the offscreen still exporter, which has to
    /// read the texture back. The live paths never wait.
    ///
    /// `presenting` schedules the drawable on the same command buffer, so the
    /// live path costs one submission per frame.
    func render(to target: MTLTexture, waitForCompletion: Bool = false,
                presenting drawable: MTLDrawable? = nil) {
        guard let cellTex, pixelWidth > 0 else { return }

        var clock = advanceClock()
        beginPlaybackIfNeeded(gap: Double(clock.wasIdle))

        // A replay overrides the clock: the scene runs on simulated time until
        // it has caught up with the present.
        if playback != nil { clock = advancePlayback(dt: clock.dt, clock: clock) }
        let sec = clock.sec

        // ---- ease the sky toward the last reading.
        //
        // Before the simulation steps, because the rain, the glass and the
        // streaks are all driven from `state.weather` and must see the sky
        // that is about to be drawn rather than the one it is heading for.
        //
        // A wake hands the whole gap over in one call. That is not a fight
        // with the fast-forward below, it is the same move: exponential easing
        // composes exactly, so one 3600-second step lands precisely where an
        // hour of 60fps steps would have. A replay instead advances on the
        // replay's own accelerated dt, so the weather moves at the same speed
        // as everything else the user is watching rush past.
        let wokeUp = clock.wasIdle > 1.0 && playback == nil
        if easesTransitions {
            _state.weather = easer.advance(dt: wokeUp ? clock.wasIdle : clock.dt)
        }

        // Step the integrators, catching up if we have just woken.
        if wokeUp {
            sim.fastForward(to: sec, elapsed: clock.wasIdle, state: state)
        } else {
            sim.step(dt: clock.dt, sec: sec, state: state)
        }

        uploadUniforms(sec: sec, clock: clock)
        uploadBuffers()
        uploadGlassCells()
        uploadStreakCells()

        guard let cmd = queue.makeCommandBuffer() else { return }

        // ---- Pass A: one fragment per cell
        let aDesc = MTLRenderPassDescriptor()
        aDesc.colorAttachments[0].texture = cellTex
        aDesc.colorAttachments[0].loadAction = .dontCare
        aDesc.colorAttachments[0].storeAction = .store
        aDesc.colorAttachments[1].texture = auxTex
        aDesc.colorAttachments[1].loadAction = .dontCare
        aDesc.colorAttachments[1].storeAction = .store
        if let e = cmd.makeRenderCommandEncoder(descriptor: aDesc) {
            e.setRenderPipelineState(cellPS)
            e.setFragmentBuffer(uniformBuf,  offset: 0, index: 0)
            e.setFragmentBuffer(breatherBuf, offset: 0, index: 1)
            e.setFragmentBuffer(starBuf,     offset: 0, index: 2)
            e.setFragmentBuffer(streakBuf,   offset: 0, index: 3)
            e.setFragmentBuffer(colIndexBuf, offset: 0, index: 4)
            e.setFragmentBuffer(boltBuf,     offset: 0, index: 5)
            e.setFragmentBuffer(edgeBuf,     offset: 0, index: 6)
            e.setFragmentTexture(streakTex, index: 0)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            e.endEncoding()
        }

        // ---- Pass H: per-cell relief height. A handful of thousand fragments,
        // so the neighbourhood analysis behind the emphasis curve is free here
        // and would not be at full resolution.
        if let heightTex {
            // How much of the newly computed height to take this frame. 1 is
            // the old behaviour: assign it. Anything less blends it into the
            // height already standing, so the blocks rise and fall into place.
            //
            // The first frame after a rebuild — and the first after a wake,
            // when nothing was on screen to see a movement — must take the
            // whole thing through the UNBLENDED pipeline. A private texture's
            // contents before its first write are undefined, and a NaN in
            // there survives a blend of any weight (NaN * 0 is NaN) and would
            // stand as a permanently broken block for the life of the process.
            let a = (heightPrimed && !wokeUp) ? riseAlpha(dt: clock.dt) : 1
            let hDesc = MTLRenderPassDescriptor()
            hDesc.colorAttachments[0].texture = heightTex
            hDesc.colorAttachments[0].loadAction = a < 1 ? .load : .dontCare
            hDesc.colorAttachments[0].storeAction = .store
            if let e = cmd.makeRenderCommandEncoder(descriptor: hDesc) {
                e.setRenderPipelineState(a < 1 ? heightRisePS : heightPS)
                if a < 1 { e.setBlendColor(red: a, green: a, blue: a, alpha: a) }
                e.setFragmentBuffer(uniformBuf, offset: 0, index: 0)
                e.setFragmentTexture(cellTex, index: 0)
                e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                e.endEncoding()
                heightPrimed = true
            }
        }

        // ---- Pass B (+C): full-res presentation
        let bDesc = MTLRenderPassDescriptor()
        bDesc.colorAttachments[0].texture = target
        bDesc.colorAttachments[0].loadAction = .dontCare
        bDesc.colorAttachments[0].storeAction = .store
        if let e = cmd.makeRenderCommandEncoder(descriptor: bDesc) {
            e.setRenderPipelineState(presentPS)
            e.setFragmentBuffer(uniformBuf, offset: 0, index: 0)
            e.setFragmentBuffer(starBuf,    offset: 0, index: 2)
            e.setFragmentTexture(cellTex, index: 0)
            e.setFragmentTexture(glassTex, index: 1)
            e.setFragmentTexture(streakFineTex, index: 2)
            e.setFragmentTexture(heightTex, index: 3)
            e.setFragmentTexture(auxTex, index: 4)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

            // Superseded: water is now drawn inside presentPass, in-theme and
            // subdivided, rather than as smooth alpha-blended circles on top.
            let quads: [GlassQuad] = []
            if !quads.isEmpty {
                let n = min(quads.count, Self.maxGlassQuads)
                quads.withUnsafeBufferPointer { p in
                    glassBuf.contents().copyMemory(from: p.baseAddress!,
                                                   byteCount: n * MemoryLayout<GlassQuad>.stride)
                }
                e.setRenderPipelineState(glassPS)
                e.setVertexBuffer(glassBuf, offset: 0, index: 0)
                e.setVertexBuffer(uniformBuf, offset: 0, index: 1)
                e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: n)
            }
            e.endEncoding()
        }

        if let drawable { cmd.present(drawable) }
        cmd.commit()
        if waitForCompletion { cmd.waitUntilCompleted() }
    }

    // MARK: - Relief rise

    /// Whether `heightTex` holds a height from a previous frame that is safe
    /// to blend against. Cleared whenever the texture is rebuilt.
    private var heightPrimed = false

    /// Fraction of a cell's newly computed height to adopt this frame.
    ///
    /// `state.reliefRise` is a feel control, not a time: squared, so the low
    /// end of the slider stays useful, and mapped onto a time constant of a
    /// twelfth of a second at the bottom to about two and a half seconds at
    /// the top. Zero returns 1 — the height is assigned, exactly as it was
    /// before this existed, through the unblended pipeline.
    private func riseAlpha(dt: Float) -> Float {
        guard easesTransitions else { return 1 }
        let rise = max(0, min(1, state.reliefRise))
        guard rise > 0.005, dt > 0, dt.isFinite else { return 1 }
        let tau = 0.08 + rise * rise * 2.4
        return max(0.02, min(1, 1 - exp(-dt / tau)))
    }

    // MARK: - Upload

    private func uploadUniforms(sec: Float, clock: (sec: Float, dt: Float, wasIdle: Float)) {
        // ---- heading
        let target = state.headingTarget
        // A non-finite target would poison the easing permanently: NaN spreads
        // into `smoothedFacing`, and from there into every angle the shader
        // derives from it, with no way back. Hold the last good heading.
        if !target.isFinite {
            // nothing to ease toward
        } else if smoothedFacing.isNaN {
            smoothedFacing = target                    // first frame: no swing
        } else {
            // Shortest way round the compass, so 350 -> 10 goes forward through
            // north instead of sweeping backwards through south.
            var delta = (target - smoothedFacing).truncatingRemainder(dividingBy: 360)
            if delta > 180 { delta -= 360 } else if delta < -180 { delta += 360 }
            // ~20s time constant. The sun moves 15 degrees an hour, so tracking
            // it is imperceptible; this exists for the dusk handover, which can
            // be a hundred degrees at once.
            let k = 1 - exp(-clock.dt / 20)
            smoothedFacing += delta * k
            if smoothedFacing < 0 { smoothedFacing += 360 }
            if smoothedFacing >= 360 { smoothedFacing -= 360 }
        }

        var u = Uniforms()
        u.cols = Float(sim.cols); u.rows = Float(sim.rows)
        // The DISPLAY size, not the simulation's grid extent (cols*SP), which
        // overhangs the right edge by up to half a cell. The shader derives the
        // per-axis cell pitch as pixW/cols and pixH/rows, so it needs the size
        // of the thing it is actually filling. Feeding it the grid extent is
        // what left a clipped sliver of a column against the right edge.
        u.pixW = Float(pixelWidth); u.pixH = Float(pixelHeight)
        u.cellSP = sim.cellSize
        u.time = sec

        let a = state.astro
        u.sunAlt = a.sunAlt;   u.sunAz = a.sunAz
        u.moonAlt = a.moonAlt; u.moonAz = a.moonAz
        u.moonIllum = a.moonIllum
        u.moonPhase = a.moonPhaseN
        u.facingAz = smoothedFacing

        let w = state.weather
        u.covF = state.covF
        u.aqiF = state.aqiF
        u.smokeF = state.smokeF
        u.uv = w.uv; u.wind = w.wind; u.windDir = w.windDir
        u.rain = w.rain; u.snow = w.snow
        // Visibility THROUGH the precipitation, not the ambient figure.
        //
        // `precipVisibility` works out how far you can see through falling water
        // per hydrometeor form — dendrites scatter more than compact crystals,
        // drizzle is optically thick for how little water it carries, hail is
        // nearly transparent between stones — and it was computed correctly and
        // then read by nothing but the debug string. Meanwhile the shader derived
        // the whole aerosol optical depth from the ambient `visibility`, which on
        // a model-only fetch does not know rain is falling at all. So the air
        // inside a downpour was as optically clear as the air on a dry afternoon,
        // and the depth cue that makes heavy rain read as heavy went missing.
        //
        // Degrades safely: `precipVisibility` returns `visibility` unchanged
        // whenever nothing is falling, so a dry sky is bit-identical.
        u.vis = w.precipVisibility; u.humid = w.humidity
        u.scAQI = w.aqi
        u.code = Int32(w.code)
        u.kind = w.effectiveKind.rawValue

        // `effectiveKind`, not `kind`. The latter is the raw WMO classification
        // and is exactly the input the rest of the engine stopped trusting.
        u.flashAmp = sim.flashAmp(sec: sec, kind: w.effectiveKind)
        // Meteor shower, if one is running. Projected to screen HERE rather than
        // in the simulation, because `astroXY` — the mapping from altitude and
        // azimuth to pixels — is the shader's, and the radiant has to land in
        // the same place the stars around it do or the trails will not appear to
        // come from anywhere in particular.
        if let m = meteorShower, m.perHour > 0.5 {
            sim.meteorRatePerHour = m.perHour
            let p = Self.astroToScreen(alt: m.alt, az: m.az, facing: state.facingAz,
                                       w: Float(pixelWidth), h: Float(pixelHeight))
            sim.meteorRadiantX = p.x
            sim.meteorRadiantY = p.y
        } else {
            sim.meteorRatePerHour = 0
            sim.meteorRadiantX = -1
            sim.meteorRadiantY = -1
        }

        u.shootActive = sim.shootActive ? 1 : 0
        u.shootX = sim.shootX; u.shootY = sim.shootY; u.shootT0 = sim.shootT0

        u.starCount = Int32(min(Self.maxStars, a.stars.count))
        u.boltCount = Int32(min(Self.maxBolt, sim.boltPoints.count))
        u.shape = state.shape.rawValue
        u.finish = state.finish.rawValue
        u.posterQ = state.posterQ
        u.nightBoost = state.nightBoost
        u.cbase = state.cbase
        u.skyBrAmt = state.skyBrAmt
        u.lowfx = state.lowFX ? 1 : 0
        u.glassWet = sim.glassWet
        u.grime = sim.grime
        u.steam = sim.steam
        // The shader now occludes the sun and moon by whichever layer is
        // actually in front of them, so these three ARE the cover as far as the
        // sky is concerned. If a response arrives without them — an older cache,
        // a partial fetch — everything would be unoccluded and a full moon would
        // blaze through an overcast night. Fall back to putting the total into
        // the low deck, which is the safe reading: it hides the most.
        var lo = max(0, min(1, w.cloudLow  / 100))
        var md = max(0, min(1, w.cloudMid  / 100))
        var hi = max(0, min(1, w.cloudHigh / 100))
        if lo + md + hi < 0.02 && w.cover > 2 { lo = max(0, min(1, w.cover / 100)) }
        u.cloudLow = lo; u.cloudMid = md; u.cloudHigh = hi
        u.depthAmt   = max(0, min(1, state.reliefDepth))
        u.emphAmt    = max(0, min(1, state.reliefEmphasis))
        u.lightInt   = max(0, min(1, state.lightIntensity))
        u.refractAmt = max(0, min(1, state.refraction))
        u.dispersAmt = max(0, min(1, state.dispersion))
        u.frostAmt   = max(0, min(1, state.frost))
        u.splayAmt   = max(0, min(1, state.splay))
        // What is physically falling, so the streak pass can draw a hailstone
        // and a dendrite as the different objects they are. Derived in
        // WeatherState from observed present weather, the freezing level and a
        // measured rate — the shader never sees the WMO code for this.
        u.pform  = Float(w.precipForm.rawValue)
        // How much light the deck is taking out, 0..1. `cbase` already carries
        // the same quantity but is deliberately clamped into the band the scene
        // was tuned in; this is the unclamped signal, used only for bounded
        // shading under the deck.
        u.gloomF = max(0, min(1, w.gloom))
        // Median drop diameter, mm, from the measured fall speed. The rainbow is
        // the only thing that reads it: big drops give a saturated spectrum,
        // drizzle gives a broad white fogbow, and the difference between those
        // two is a measurement rather than a style.
        u.dropMM = max(0, min(8, sim.surfaceWeather.dropDiameter))
        // Fog is observed, not read off the WMO code: model visibility is a
        // grid-box average and fog is famously not.
        u.fogOn = w.isFoggy ? 1 : 0
        // Headroom the display is granting this instant. Floored at 1 so the
        // shader's EDR branch stays inert on SDR, and capped so a bogus reading
        // cannot ask for an absurd exposure.
        u.edrHead = max(1, min(16, edrHeadroom))
        // Rare events, from geometry — no feed, so this works offline and on
        // the exact minute. See Astro.lunarEclipseDepth.
        u.eclipse = max(0, min(1, state.astro.lunarEclipse))
        u.shimmer = max(0, min(1, state.shimmer))
        u.material = state.material.rawValue
        u.rounding = max(0, min(1, state.rounding))
        u.halftone = max(0, min(1, state.halftone))
        u.roughness = max(0, min(1, state.roughness))
        u.depthMap = max(0, min(1, state.depthMap))
        u.grout = max(0, min(1, state.grout))

        uniformBuf.contents().copyMemory(from: &u, byteCount: MemoryLayout<Uniforms>.stride)
    }

    private func uploadStreakCells() {
        if let ft = streakFineTex, !sim.streakFine.isEmpty {
            let N = SceneSimulation.streakSub
            sim.streakFine.withUnsafeBufferPointer { p in
                ft.replace(region: MTLRegionMake2D(0, 0, sim.cols * N, sim.rows * N),
                           mipmapLevel: 0, withBytes: p.baseAddress!,
                           bytesPerRow: sim.cols * N * MemoryLayout<Float>.size)
            }
        }
        guard let tex = streakTex, !sim.streakCells.isEmpty else { return }
        sim.streakCells.withUnsafeBufferPointer { p in
            tex.replace(region: MTLRegionMake2D(0, 0, sim.cols, sim.rows),
                        mipmapLevel: 0, withBytes: p.baseAddress!,
                        bytesPerRow: sim.cols * MemoryLayout<Float>.stride)
        }
    }

    private func uploadGlassCells() {
        guard let tex = glassTex, !sim.glassCells.isEmpty else { return }
        sim.glassCells.withUnsafeBufferPointer { p in
            tex.replace(region: MTLRegionMake2D(0, 0, sim.cols, sim.rows),
                        mipmapLevel: 0, withBytes: p.baseAddress!,
                        bytesPerRow: sim.cols * MemoryLayout<SIMD4<Float>>.stride)
        }
    }

    private func uploadBuffers() {
        func write<T>(_ arr: [T], to buf: MTLBuffer?, max: Int) {
            guard let buf, !arr.isEmpty else { return }
            let n = Swift.min(arr.count, max)
            arr.withUnsafeBufferPointer { p in
                buf.contents().copyMemory(from: p.baseAddress!, byteCount: n * MemoryLayout<T>.stride)
            }
        }
        write(sim.breathers,   to: breatherBuf, max: 3)
        write(state.astro.stars, to: starBuf,   max: Self.maxStars)
        write(sim.gpuStreaks,  to: streakBuf,   max: Self.maxStreaks)
        write(sim.colIndex,    to: colIndexBuf, max: sim.cols)
        write(sim.boltPoints,  to: boltBuf,     max: Self.maxBolt)
        write(sim.edgeArr,     to: edgeBuf,     max: sim.cols)
    }
}
