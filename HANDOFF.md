# Elemental — handoff

Read this first. It is the state of the project, the traps that have cost real
time, and what is left. Written 2026-08-08 at the end of a long session.

## What this is

A macOS live wallpaper that draws an ambient dot-mosaic sky reflecting the real
weather and sky at a chosen location. It renders on three surfaces:

- the **desktop**, as a persistent window at `CGWindowLevelForKey(.desktopWindow)`
- the **lock screen**, via a still exported once a minute and installed as the
  desktop picture (a third-party window cannot draw at the lock screen)
- the **screen saver**, `Elemental.saver`, loaded into `legacyScreenSaver.appex`

It is a port of a Raspberry Pi project, `roomstand.py`, which remains the
**colour benchmark**. The user considers the Pi's colour reproduction better and
the instruction is to *level up from it*, not diverge.

## Hard constraints

- **Never edit, run, or modify anything under `/Users/prakritmaan/Programs/standby-patches/`.**
  A separate session owns the Pi. Read `roomstand.py` as a visual reference only;
  the colour work is in the `PAGE` template's JavaScript — `_skyRGB`, `_skyBr`,
  `_sunTint`, `_cloudTint`, around lines 2186-2400.
- **Never edit `Core/ShaderSource.swift`.** It is generated from
  `Core/Scene.metal` by `build.sh`.
- Ask before installing into `~/Library/Screen Savers/` or changing wallpaper
  settings on a fresh machine.

## Build, deploy, verify

```
cd /Users/prakritmaan/Programs/elemental     # ALWAYS absolute; cwd resets between calls
./build.sh                                    # one invocation per command
```

Check for real errors with this pattern and nothing looser:

```
./build.sh 2>&1 | grep -E "\.swift:[0-9]+:[0-9]+: error:"
```

Deploy:

```
pkill -f "Elemental.app/Contents/MacOS"; sleep 1
rm -rf ~/Library/Screen\ Savers/Elemental.saver && cp -R build/Elemental.saver ~/Library/Screen\ Savers/
open -g build/Elemental.app
```

## Traps that have actually cost time

1. **`timeout` does not exist on this machine.** Any command wrapped in it fails
   silently and whatever follows in the pipeline still prints. A build check
   written as `timeout 240 ./build.sh 2>&1 | grep ...` verifies *nothing* and
   looks clean. This caused at least one deploy on a hollow check.
2. **zsh does not word-split unquoted variables.** `$FLAGS` passed to a command
   arrives as ONE argument, so `elemental-render $FLAGS` silently renders
   defaults. Two agents and the main session each drew false conclusions from
   this. Write flags out in full, or use `${=FLAGS}`.
3. **A failed build leaves the previous binary in place**, so you will test stale
   code and conclude your change worked, or did nothing. Always check the build
   before believing a render.
4. **`--hour` IS NOT A FLAG.** `elemental-render --hour 10` silently renders at
   the current wall clock and prints a reassuring summary. Every frame labelled
   with an hour that way was rendered at whatever time it happened to be. Use
   `--at 2026-08-11T19:45 --tz Asia/Kolkata`. `--sheet --from --to` is fine.
5. **The Bash cwd persists between calls, and `./build.sh` follows it.** One
   `cd` into the main checkout earlier in a session means later `./build.sh`
   calls build the WRONG TREE while the renders come from the right one — you
   then conclude a correct edit had no effect. Cost an hour on the twilight
   band. Put the `cd` in every build command.
6. **A row mean hides anything localised.** `--probe` averages across the frame,
   so a saturated band on one side is diluted by dark cells on the other, and a
   real fix reads as "no change". Read the PNG.
7. **`grep -c "error"` matches Swift 6 warning prose** ("this is an error in the
   Swift 6 language mode") and reports false failures.
8. **The `Uniforms` struct is mirrored BY HAND** in `Core/Scene.metal` and
   `Core/SceneState.swift`. Same fields, same order, total a multiple of 16
   bytes. A mismatch does not crash — it silently shifts every field after the
   seam. If you change it, render and LOOK.
9. **The app is signed ad hoc**, so every rebuild mints a new code hash and macOS
   forgets TCC grants — location especially. There is now a build-token check
   that detects this; do not reintroduce a one-way `hasAskedForLocation` gate.
10. **`Config.init(from:)` is hand-rolled** with a `lenient()` helper. A new field
   MUST be added there or it silently fails to load. Every stored property must
   be covered.

11. **`WeatherState` uses SYNTHESIZED `Codable`, which is strict.** Swift does
   *not* fall back to a property's default value when a key is missing — it
   throws `keyNotFound`. `WeatherState` is encoded whole into the ByHost
   preferences bridge the saver reads, so **adding a bare stored property breaks
   decoding of every payload written by the previous version**, and the saver
   answers with a default clear sky until the app happens to publish again.
   That is precisely the "saver is not following the weather" symptom, and it
   arrives one release *after* the change that caused it. Add new readings as a
   nested `Optional` struct (see `WeatherState.sat`) — Optionals decode through
   `decodeIfPresent`, so an older payload yields nil, which is already the right
   reading of "nobody looked". Verified both directions with a scratch binary;
   old code reading a new payload is fine, because unknown keys are ignored.

12. **Never block the main thread waiting on `WeatherService.fetch`.** It hops to
   the main actor to publish its reading, so a `DispatchSemaphore.wait` on main
   deadlocks it. The failure is deceptive: radar and satellite have already
   logged their success by then, so the probe prints a working satellite next to
   "model unavailable" and reads exactly like a fetch failure. Pump instead —
   `while !done { RunLoop.main.run(mode: .default, before: …) }`, which is what
   `--check` has always done. The semaphore pattern is only safe for plain async
   functions with no actor hop, like `SkyImagery.radar`.

13. **A build silently inherits the machine that made it — on TWO axes.** Both
   shipped in 0.2 and neither was visible from the build machine, because that
   is the one machine the result was guaranteed to run on.
   - **OS floor.** With no `-target`, swiftc takes its minimum from the host. On
     macOS 27 that stamped `minos 27.0` while `Info.plist` advertised
     `LSMinimumSystemVersion 14.0`, so the package installed happily on macOS 26
     and then would not open.
   - **Architecture.** `uname -m` left the arch as the host's, so the build was
     arm64-only (`lipo -info` → "Non-fat file: ... arm64") and no Intel Mac
     could launch it at any OS version.

   Both are now pinned in `build.sh` (`DEPLOY_MIN`, `ARCHES`) and, more
   importantly, **`package.sh` verifies rather than trusts** — it refuses to
   build an installer unless the binary carries both slices and its real `minos`
   matches what `Info.plist` promises. `ELEMENTAL_ARCHS=arm64` halves build time
   for iteration and cannot reach a `.pkg`.

   Check, never assume:
   `lipo -archs build/Elemental.app/Contents/MacOS/Elemental`
   `vtool -show-build build/Elemental.app/Contents/MacOS/Elemental`

14. **`build.sh` runs under BASH** (see the shebang) even though the interactive
   shell here is zsh. `read -A`, `${=var}` and 1-based array indexing are zsh
   and are all wrong in that file; bash arrays are 0-indexed and unquoted
   expansions word-split. The reverse trap (#2) still applies at the prompt.

## Recurring bug classes

Most real bugs found here were one of four shapes. Look for them first:

- **Inverted falloff** — a term strongest where it should be weakest. Found in
  the sky gradient exponent, the under-deck light, the deck thickness.
- **Always-true gate** — e.g. `if (R0 != G0 || G0 != B0)` on a base that is never
  neutral; `fogginess > 0.55` firing on the clear calm nights that make dew.
- **Computed but never read** — `PrecipPhase`, the per-surface film, widget
  rects, `Furniture.poll()`. Whole features ran correctly and invisibly.
- **An element asserting itself regardless of what is in front of it** — the moon
  at weight 1.0 that no cloud could cover; splash depositing liquid during a
  snowstorm; METAR's censored `10SM` visibility read as a real aerosol
  measurement, which made every clear day hazy.

## Verification tooling

`build/elemental-render` renders fully offscreen. Key flags:

- `--sheet N --from H --to H` — tiles N frames across a day into one image. **The
  single most effective debugging tool here.** Nearly every real colour bug was a
  discontinuity invisible in any single frame.
- `--probe` — row-mean RGB down the frame plus a vertical banding metric
- `--check --lat .. --lon ..` — model vs METAR side by side, and what the engine
  decided. Ground truth.
- `--calib` — on-device bias-correction state; `--calib --selftest` runs the
  solver self-tests
- `--edr` — display headroom
- `--rows N`, `--shape`, `--finish`, `--dock`, `--widget`, `--warmup N`,
  `--dryfor N`, plus synthetic weather flags

**Read rendered PNGs with the Read tool.** Do not report a visual fix you have
not looked at. Water and streak effects need hundreds of warm-up frames.

## Architecture

- `Core/Scene.metal` — the engine. `cellPass` (one fragment per mosaic cell),
  `heightPass` (relief height field), `presentPass` (full-res, shape × finish,
  subdivision), `glassVS`/`glassFS`.
- `Core/SceneState.swift` — GPU uniform mirror, `WeatherState` and its derived
  layer (`effectiveKind`, `PrecipMorphology`, `PrecipPhase`, `PrecipForm`,
  `SnowHabit`), `WeatherEaser`.
- `Core/Simulation.swift` — the stateful half: rain streaks, droplets, trails,
  lightning, per-surface films (`DepositForm`).
- `Core/Weather.swift` — Open-Meteo fetch. `Core/Observation.swift` — METAR.
  `Core/Calibration.swift` — on-device bias correction, per location.
- `Core/Renderer.swift` — Metal host, scene clock, wake replay, weather easing.
- `App/` — menu bar app, Settings (`SettingsKit`, `PreviewRenderer`,
  `ElementsPane`, `DesktopGrid`, `DensityGrip`), lock-still exporter.

**Central principle: measurement beats classification.** Trusting WMO codes and
raw CAPE drew thunder all afternoon over a merely cloudy sky. Every behaviour
should be gated on something measured and degrade gracefully when a variable is
missing.

## Done and verified

Weather derivation from measurement; METAR reconcile; on-device calibration;
depth-ordered cloud occlusion; moon phase and terminator; 3D relief with
parallax, flank shading and organic sun/moon lighting; rain morphology
(steady/showery/squally/drizzle); gradual weather transitions with per-quantity
timescales; grid fitting the display edge to edge; the animation stall (the
lock-still exporter was blocking the render thread for 337 ms/minute); Settings
redesign with live previews; density by drag/scroll with haptics; the Elements
panel with screenshot detection and a full-size editor; condition-gated rainbow;
sky colour rebuilt on Rayleigh/Mie with the Pi as reference.

**HDR: macOS does NOT grant EDR to a desktop-level window.** Measured across
window levels — the cutoff is exactly at level 0, and a wallpaper must sit below
the icon layer. The toggle ships and says so. The screen saver (level 1000) IS
granted headroom and is the one surface where it could work.

## Left to do

**Unfinished:**
- ~~Furniture tracelines as hard-edged rectangles~~ — FIXED. `lipF` is the
  furniture's top edge in cell units and only its INTEGER part was ever read, so
  a band's base snapped to the nearest cell boundary, up to ~40 backing pixels
  from the real edge, while its top feathered correctly. The sub-cell machinery
  was all there and nothing fed it.
- ~~Furniture detection by differencing~~ — BUILT AND WIRED. `DiffGrid` in
  App/FurnitureDetector.swift compares the screenshot against a live
  `DesktopReference.render` of the same scene; called from the placement overlay
  and the Elements pane, with a documented fallback to edge detection when the
  reference is not contemporaneous (an old screenshot against tonight's sky
  fragments into specks). This entry said "largely unbuilt" for a whole session
  after it was built, and was repeated to the user as outstanding work. CHECK
  THE CODE BEFORE TRUSTING THIS FILE.
- Settings reaching the saver on window close (the user's suggestion: lock in the
  update when the panel closes).

**Not started:** wind-shifted desktop icons at gale strength; widget wetness as
water running down a stacked pane of glass; per-element furniture knobs (blocked
— the engine reads only global options from `Core/Furniture.swift`).

**~~Known, unfixed: dead fields~~** — RESOLVED. `liveWeather` was a real feature
never wired; it now works and has a control. `SurfaceStyle.hasAskedForLocation`
described a mechanism that does not exist and was removed.

**~~The saver does not follow the weather~~** — FIXED. Two causes, both about a
mirroring surface being treated as independent: it adopted the desktop's
published reading only while its OWN fetch had never succeeded, so the moment
that landed it diverged; and it eased in from a default clear sky over
WeatherEaser's minutes-long timescales instead of snapping. See `SaverWeather`
and `adoptDesktopWeatherIfMirroring`. `--saverhealth` diagnoses it.

**Fixed since this file was written** (see git log for the reasoning):
- the saturated red band at the bottom of night tiles — green was collapsing to
  ~5% of red on the solar horizon; bounded against `max(r, b)` after the sky
  tint. Note the two false starts: a floor inside `skyRGB` binds on nothing, and
  a floor against `min(r, b)` binds on nothing. Row means hid both; the frame
  showed it at once. **Read the frame, not the probe, for anything localised.**
- `precipVisibility` is now read (it drives the sky's optical depth).
- `blowingSnow` and `obscurationDensity` were NEVER unread — this list was
  wrong. They are consumed at `Simulation.swift:1486` and `:1511`.

**Reported and now REPRODUCIBLE** — the earlier sweep looked at weather; these
are a function of relief and parallax over a luminance edge, so no weather sweep
could have found them. Both fixed in `7fbf6f5`:
- the "chromatic fringe on strong edges" was dispersion moving R and B
  independently, each clamped to ±0.05, so both saturated at any edge.
- the hard rectangular block around the sun was the solar disc's own 133-unit
  luminance cliff plus a `smoothstep` in `heightPass` that saturated at 1 and
  made every bright feature a plateau with a vertical rim.
Isolate relief artifacts with `--depth 0 --emph 0`, `--disperse 0`, `--finish 1`.

**Unexplained:** toggling the lock/saver "mimic home screen" setting off and on
fixed it for the user. A real ordering bug was found and fixed in the lock-still
exporter, but it was broken from launch either way, so it does not explain the
workaround. Something else is there.

## Session of 2026-08-11 — what changed

Twenty-four commits. The through-line: the scene was full of terms that looked
measured and were not, and the harness was agreeing with several of them.

**Observation replaced invention.** `Core/SkyImagery.swift` reads the global
RainViewer radar composite (free, no key). Radar now decides whether it is
raining ON YOU — a model's grid box is tens of km wide and "1 mm/h in that box"
is not evidence at your window — and places the rain via `precipField`.
Verified: model said WMO 51 / 1.0 mm while radar showed 0.00 overhead.
`elemental-render --radar` and `--useradar` exercise it offscreen.

**Classification removed.** `continuousCloudBase` clamped a measured
transmission into a band around a hand-tuned `SceneKind` table. Gone; table
deleted.

NOTE, checked 2026-08-12: `effectiveKind`, `morphology`, `precipForm` and
`snowHabit` are ALREADY measurement-first and were misdescribed here as the
"remaining classification". `effectiveKind` reads observed thunder, snow amount,
radar-gated precipitation and measured cover; the other three lead with the
observer's own classification and fall back to measured rate, gustiness,
temperature and frozen fraction. There is no WMO bucket driving behaviour.

**Colour path made to obey depth.** Sky hue is gated by per-cell `seeThrough`;
the element blend is driven by coverage, not saturation (a neutral overcast was
being erased for being the right colour); the posterizer quantises luminance
rather than R/G/B independently, which was shattering flat grey into confetti.

**Relief stopped extruding cliffs that were not there** — the sun disc's 133-unit
luminance step, a `smoothstep` that saturated into plateaus, dispersion moving R
and B independently. Sub-cell features no longer raise their whole block.

**Furniture.** Splashes were gated on pane water (0 vs 573 splashes measured);
drizzle spray could not clear its own lip (6 px rise); the dock had no underside
so it could never drip; each surface now has its own material.

**The saver** publishes/consumes the desktop's weather through the ByHost domain
and snaps rather than easing in. `SaverHealth` diagnoses it;
`elemental-render --saverhealth`.

**Left:** meteor showers (radiant + rate from a table — simulation shaped by real
data, not observation); satellite IR for cloud PLACEMENT (RainViewer returned
zero IR frames — needs another source); widget resize / dock precision /
autodetect sit unmerged and unverified in `agent-ac2b3677a56b6e262`.

## Working style that has held up

- One agent at a time. Four in parallel once produced a tree that would not
  build and cost ~20% of a budget to repair.
- Report per feature, not at the end. Ten agents were cut off mid-task by spend
  limits and watchdogs; incremental reporting is the only thing that reliably
  preserved work.
- Leave the tree compiling, always.
- Deploy and verify between changes rather than letting work pile up unshipped.
- The user's standard, stated many times: **it should look like looking out of
  the window.**
