# Elemental

A live wallpaper for macOS that draws the sky that is actually outside.

Not a loop, not a time-of-day preset, not a picture of weather. The sun and moon
are placed by ephemeris from your coordinates and the current minute. The sky's
colour is computed from Rayleigh and Mie scattering against published optical
depths. Cloud comes in by altitude from a forecast, is reconciled against the
nearest aerodrome's METAR, and radar decides whether it is raining **on you** or
merely nearby. Rain lands on your dock and your widgets and runs off them.

It renders on three surfaces: the desktop, the lock screen, and as a screen
saver.

---

## Why it looks like that

The scene is a mosaic of glass blocks. Every one is extruded toward you by its
own brightness, lit from wherever the sun or moon actually is on screen, and seen
at a slight angle so the ones off-centre show their sides. It is deliberately
coarse: the grid is the point, and detail is spent only where something needs it
— the moon's disc, a star, a splash droplet — through a subdivision pass that
refines a cell only when the source varies across it.

## What it reads

| Source | What it gives |
| --- | --- |
| Ephemeris | Sun and moon altitude, azimuth, phase, lunar eclipse |
| Open-Meteo | Cloud by altitude, precipitation, wind, UV, visibility, air quality |
| METAR | Ground truth from the nearest aerodrome — ceiling, obscuration, present weather |
| RainViewer radar | Whether precipitation is overhead, and where it is |
| Geostationary infrared | Where the cloud is, and how cold its tops are |

Everything degrades. No network gives you a correct sky for your location and
time of day; no location permission falls back to a longitude estimated from
your timezone; no radar leaves the precipitation model exactly as it was; no
satellite leaves the cloud deck exactly as it was.

### Where the cloud is

A forecast gives three percentages for a grid box tens of kilometres wide and
says nothing about how the cloud inside it is arranged, so the deck used to be
noise shaped to hit that average — the amount right, the arrangement invented.
Infrared fixes the arrangement, and because a thermal channel measures how cold
each column's top is, it also says which deck the cloud belongs to.

No single free keyless service covers the planet, so it takes two publishers:

| Satellite | Longitude | Via | Covers |
| --- | --- | --- | --- |
| GOES-West | 137.0°W | NASA GIBS | Pacific, western North America |
| GOES-East | 75.2°W | NASA GIBS | the Americas, western Atlantic |
| Meteosat | 0.0° | EUMETSAT | Europe, Africa, eastern Atlantic |
| Meteosat IODC | 45.5°E | EUMETSAT | Middle East, India, Indian Ocean |
| Himawari | 140.7°E | NASA GIBS | east Asia, Australia, west Pacific |

GIBS carries no Meteosat at all, which alone would leave Europe, Africa and
western India with nothing.

The nearest satellite is chosen by true viewing angle — a great-circle distance
from the point it hangs over, not latitude and longitude tested separately,
because those do not trade off independently. How far off nadir a place sits
then decides how much its image is believed: full weight out to 45°, fading to
none by 70°, and nothing at all beyond that. A satellite looking at your sky
edge-on smears cloud well away from where it really is, and a reading like that
has no business overruling a forecast.

The satellite **redistributes** cloud without rescaling it: the profile is
divided by its own mean before it is applied, so it moves the deck from where
there is a gap to where there is a mass and leaves the total to the model. It is
allowed to change the amount only for the low deck, and only when the tops are
warm enough to be that deck rather than cirrus sitting over the top of it.

**Central principle: measurement beats classification.** Behaviour is gated on
something measured rather than on a weather-code bucket, and every term degrades
gracefully when its input is missing.

## Building

No Xcode project, no Metal toolchain. The shader is embedded into the binary as
a string and compiled by the Metal runtime at launch, which is what lets the same
renderer run inside the screen saver's sandbox.

```bash
./build.sh            # render tool, app, and saver
./build.sh app        # just the app
```

Check for real errors with this pattern and nothing looser — `grep -c error`
matches Swift 6 warning prose:

```bash
./build.sh 2>&1 | grep -E "\.swift:[0-9]+:[0-9]+: error:"
```

Install:

```bash
cp -R build/Elemental.saver ~/Library/Screen\ Savers/
open -g build/Elemental.app
```

### Installing on another Mac, without an Apple Developer account

The default build is ad-hoc signed. An ad-hoc bundle runs perfectly well on any
Mac — what it cannot survive is the **quarantine** attribute, which macOS
attaches to anything arriving through a browser download or AirDrop. Ad hoc plus
quarantine produces:

> "Elemental is damaged and can't be opened. You should move it to the Trash."

which is untrue. Nothing is damaged; Gatekeeper cannot find a Developer ID or a
notarization ticket for a quarantined bundle and reports that in the least
helpful way available.

Two ways around it:

**Copy it without quarantine.** A USB stick, `scp`, `rsync` or a network share
does not set the attribute at all, and the app just works. Best for a machine
you can physically reach.

```bash
scp -r build/Elemental.app other-mac:/Applications/
```

**Or strip the quarantine after downloading**, which is what `install.sh` does —
it copies the app and the saver into place, clears the attribute recursively
(per file, not just the bundle root, or the executable inside stays quarantined)
and verifies it actually went:

```bash
./install.sh
```

Neither is a security bypass in any meaningful sense: you are telling your own
Mac that you trust software you deliberately fetched — the same judgement
Gatekeeper asks you to make in System Settings, made at the command line.

A **free** Apple ID does not solve this. It can issue an "Apple Development"
certificate, but not the "Developer ID Application" certificate that
distribution requires, and development certificates cannot be notarized. The
paid Developer Program is the only route to an app that opens by double-click
for someone who has never heard of `xattr`.

### Distributing a .pkg

`./package.sh` builds `build/Elemental-<version>.pkg`, which is the best
distribution available without an Apple Developer account — and the right one
even with it.

Both a `.pkg` and a zipped `.app` get quarantined when downloaded. The
difference is what happens next:

| | downloaded `.app` | downloaded `.pkg` |
| --- | --- | --- |
| Dialog | "is damaged and can't be opened" | "from an unidentified developer" |
| Way forward | none offered — Terminal only | right-click → Open, or Privacy & Security → Open Anyway |
| After install | quarantined again on every download | **installed app is not quarantined at all** |

That last row is the point. Files laid down by an installer do not inherit
quarantine, so the user clears it once for the installer and the app in
`/Applications` opens by double-click from then on.

The screen saver is not in the payload — it belongs in `~/Library/Screen Savers`,
which is per-user, and a payload installs as root into absolute paths. It is
carried as a resource and copied by the postinstall script, which resolves the
console user properly (`$USER` is `root` at that point, so it is no help).

With an account, both dialogs disappear:

```bash
export ELEMENTAL_INSTALLER_ID="Developer ID Installer: Your Name (TEAMID)"
export ELEMENTAL_NOTARY_PROFILE="elemental"
./package.sh
```

Note that signing an *installer* needs a different certificate from signing an
*app* — `Developer ID Installer` vs `Developer ID Application`. Being issued one
does not give you the other.

### Releasing

```bash
gh release create v0.1 build/Elemental-0.1.pkg --title "Elemental 0.1" --notes "..."
```

### A stable code identity, without an Apple account

`./make-signing-cert.sh` — run once per machine.

This does **not** get past Gatekeeper. Nothing does, without a paid Developer ID
and notarization: that is Apple's signature, and any "workaround" claiming
otherwise is really asking the *user* to override Gatekeeper rather than the
developer to satisfy it. Downloaded builds still need the one-time
right-click → Open.

What it fixes is different, and it has been costing time every single build:

```
ad hoc       designated => cdhash H"9642..."
self-signed  designated => identifier "com.prakritmaan.elemental"
                           and certificate root = H"0ccc..."
```

An ad-hoc signature's designated requirement **is the code hash**, and `swiftc`
mints a new one on every compile. macOS keys TCC grants on that requirement, so
every rebuild looks like a different application and Location has to be granted
again — which is why a development build keeps falling back to the stored place
with nothing in the log to explain it. A self-signed certificate makes the
requirement "this bundle id, signed by this certificate". Both halves are
stable, so the grant survives. Verified: the requirement is byte-identical
across separate builds.

`security find-identity -v -p codesigning` will still report **0 valid
identities**. That is about *trust*, not about signing — the certificate is
self-signed so nothing vouches for it, and `codesign` uses it regardless.

### Signing

The default build is ad-hoc signed, which works on the machine that built it and
nowhere else — Gatekeeper refuses an ad-hoc bundle elsewhere. For distribution:

```bash
export ELEMENTAL_SIGN_ID="Developer ID Application: Your Name (TEAMID)"
export ELEMENTAL_NOTARY_PROFILE="elemental"
./build.sh
```

That switches on the Hardened Runtime, a secure timestamp, the entitlements in
`App/Elemental.entitlements`, notarization and stapling. With neither variable
set the build is unchanged, so nothing is gated on having an Apple account.

## Verifying

`build/elemental-render` renders fully offscreen and is how nearly every visual
claim here was checked.

```bash
# A whole day on one page — the single most effective tool in this project.
# Most real colour bugs were discontinuities invisible in any one frame.
./build/elemental-render --sheet 6 --from 5 --to 20 --out /tmp/day.png

# Sky colour as numbers, by row
./build/elemental-render --probe

# Model vs METAR, and what the engine decided
./build/elemental-render --check --lat 51.5 --lon -0.12

# What the radar sees: coverage, whether it is overhead, and a west-to-east bar
./build/elemental-render --radar --lat 51.5 --lon -0.12

# What the satellite sees, against what the model predicted. The number that
# matters is the disagreement — that is where the sky used to be drawn wrong.
./build/elemental-render --satellite --lat 51.5 --lon -0.12

# Water simulation counters — splashes, films, droplets
./build/elemental-render --kind rain --rain 8 --dock --widget --warmup 900 --water

# Why the screen saver is wrong, named specifically
./build/elemental-render --saverhealth
```

Time is `--at 2026-08-11T19:45 --tz Asia/Kolkata`. There is no `--hour`.

## Layout

```
Core/Scene.metal        the engine — cell pass, height field, presentation
Core/SceneState.swift   GPU uniform mirror, WeatherState and its derived layer
Core/Simulation.swift   the stateful half: streaks, droplets, films, lightning
Core/SkyImagery.swift   radar and satellite: where the weather actually is
Core/Weather.swift      Open-Meteo    Core/Observation.swift  METAR
Core/Astro.swift        ephemeris, lunar eclipse
Core/Renderer.swift     Metal host, scene clock, wake replay, weather easing
App/                    menu bar app, Settings, onboarding, placement overlay
Saver/                  the screen saver bundle
```

`Core/ShaderSource.swift` is generated from `Core/Scene.metal` by `build.sh`.
Never edit it.

If you are going to work on this, read `HANDOFF.md` first. It documents the
traps that have each cost real time — the Metal shader compiles at *runtime*, so
a syntax error passes `build.sh` completely clean and only appears as "no Metal
device / pipeline build failed" when something renders.

## Licence

MIT. See [LICENSE](LICENSE).
