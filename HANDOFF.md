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
4. **`grep -c "error"` matches Swift 6 warning prose** ("this is an error in the
   Swift 6 language mode") and reports false failures.
5. **The `Uniforms` struct is mirrored BY HAND** in `Core/Scene.metal` and
   `Core/SceneState.swift`. Same fields, same order, total a multiple of 16
   bytes. A mismatch does not crash — it silently shifts every field after the
   seam. If you change it, render and LOOK.
6. **The app is signed ad hoc**, so every rebuild mints a new code hash and macOS
   forgets TCC grants — location especially. There is now a build-token check
   that detects this; do not reintroduce a one-way `hasAskedForLocation` gate.
7. **`Config.init(from:)` is hand-rolled** with a `lenient()` helper. A new field
   MUST be added there or it silently fails to load. Every stored property must
   be covered.

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
- Furniture tracelines read as hard-edged rectangles rather than water on a
  surface. The fix is in how the film RENDERS, not detection. An agent declined
  to do it blind because the film never accumulates in the offscreen harness —
  make it accumulate first, then fix.
- Furniture detection finds roughly half the widgets, two spurious, dock edge 23%
  short. The user's idea — difference the screenshot against our OWN rendered
  wallpaper, since Elemental IS the wallpaper — is right and largely unbuilt.
  Translucent furniture shows up as regions where our render has sharp cell edges
  and the screenshot does not.
- Settings reaching the saver on window close (the user's suggestion: lock in the
  update when the panel closes).

**Not started:** wind-shifted desktop icons at gale strength; widget wetness as
water running down a stacked pane of glass; per-element furniture knobs (blocked
— the engine reads only global options from `Core/Furniture.swift`).

**Known, unfixed:** a saturated red band at the bottom of night tiles (sun ≈
-10°); dead `liveWeather` and `SurfaceStyle.hasAskedForLocation` fields; blowing
snow computed but not drawn; `precipVisibility`/`obscurationDensity` unread.

**Reported but NOT reproducible** — swept 5 conditions × 4 densities × 3 preview
sizes and found nothing: scattered black cells at 54+ rows, a stray bright cell
at the bottom of overcast renders, a chromatic fringe on strong edges. If the
black cells are real they are in the live preview's readback, not the render.

**Unexplained:** toggling the lock/saver "mimic home screen" setting off and on
fixed it for the user. A real ordering bug was found and fixed in the lock-still
exporter, but it was broken from launch either way, so it does not explain the
workaround. Something else is there.

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
