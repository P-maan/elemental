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
    private var presentPS: MTLRenderPipelineState!
    private var glassPS: MTLRenderPipelineState!

    /// Pass A target: one texel per mosaic cell.
    private var cellTex: MTLTexture?
    /// Per-cell water lookup for the presentation pass.
    private var glassTex: MTLTexture?
    /// Rain rasterised per cell, so streaks can lean with the wind.
    private var streakTex: MTLTexture?
    private var streakFineTex: MTLTexture?

    private let sim = SceneSimulation()

    /// Things on screen for water to land on. The wallpaper sets the dock and
    /// menu bar; the saver sets the lock screen's clock.
    var surfaces: [Surface] {
        get { sim.surfaces }
        set { sim.surfaces = newValue }
    }
    var state = SceneState()

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
        cellPS = try device.makeRenderPipelineState(descriptor: cellDesc)

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
        if !haveClock { lastFrameHost = now; haveClock = true }
        let elapsed = max(0, now - lastFrameHost)
        lastFrameHost = now

        // Coming back from an idle: rebase the origin so the Float we hand the
        // shader stays small and exact. Invisible, because nothing was drawing.
        if elapsed > 1.0 { sceneTime = 0 }
        // Real elapsed time still governs the idle gap and the wake replay;
        // only the scene's own clock is scaled.
        let scaled = elapsed * motionSpeed
        sceneTime += scaled
        return (Float(sceneTime), Float(min(0.1, scaled)), Float(elapsed))
    }

    /// Call when the renderer stops being asked for frames, so the next frame
    /// knows how long the gap was.
    func markIdle() { haveClock = false }

    /// The scene is now somewhere else. Drops anything still falling from the
    /// old sky, and leaves the water already on the glass alone.
    func locationChanged() { sim.locationChanged(now: Float(sceneTime)) }

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
              gap >= Self.playbackMinGap else { return }
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

        // Step the integrators, catching up if we have just woken.
        if clock.wasIdle > 1.0 && playback == nil {
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

    // MARK: - Upload

    private func uploadUniforms(sec: Float, clock: (sec: Float, dt: Float, wasIdle: Float)) {
        // ---- heading
        let target = state.headingTarget
        if smoothedFacing.isNaN {
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
        u.vis = w.visibility; u.humid = w.humidity
        u.scAQI = w.aqi
        u.code = Int32(w.code)
        u.kind = w.effectiveKind.rawValue

        u.flashAmp = sim.flashAmp(sec: sec, kind: w.kind)
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
        u.glassAmp = max(0, min(1, state.glassAmplify))
        // Fog is observed, not read off the WMO code: model visibility is a
        // grid-box average and fog is famously not.
        u.fogOn = w.isFoggy ? 1 : 0

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
