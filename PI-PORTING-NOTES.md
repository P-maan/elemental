# Porting notes: Elemental → `roomstand.py`

Everything Elemental does that the Pi engine doesn't, written so you can port it
back into the JS in `PAGE`. Ordered by value-for-effort. Line numbers refer to
`standby-patches/roomstand.py` as of this session.

Three categories:

- **BUG** — the Pi is doing something demonstrably wrong
- **NEW** — a mechanism Elemental has that the Pi doesn't
- **TUNE** — same idea, better constants

---

## 1. BUG — azimuth is 180° out of phase with `FACING_AZ`

**Where:** `sunPos` / `moonPos` (`roomstand.py:1594`, `:1610`) vs `FACING_AZ` (`:1550`).

`sunPos` returns azimuth measured **from south**:

```js
const az=(Math.atan2(-Math.sin(haR), Math.tan(decR)*Math.cos(latR)-Math.sin(latR)*Math.cos(haR))*_R2D+180)%360;
```

At solar noon this yields `0`. But `FACING_AZ` is documented `// 0=N 90=E 180=S 270=W`.

The scene still looks right, because only the *difference* `az - FACING_AZ` is
ever used and the two errors cancel. What is actually wrong is the **on-screen
label**: `_facingName()` (`:1474`) reports a bearing 180° from reality, so
"FACING E" is really west.

**Fix** — use the standard from-north form:

```js
const az=(Math.atan2(Math.sin(haR), Math.cos(haR)*Math.sin(latR)-Math.tan(decR)*Math.cos(latR))*_R2D+180+360)%360;
```

Then set `FACING_AZ` to a true bearing (180 = south). Verified: Amherst solar
noon gives 182°, sunset 291.7° WNW — correct for late July at 42°N.

---

## 2. BUG — the sun disc ignores cloud cover

**Where:** `drawScene`, solar disc block (`roomstand.py:2446`).

```js
L=Math.max(L,150+diskI*120);          // no sunDim anywhere
```

`sunDim` is applied to the glow and the ripple but **not** to the disc, so a
full-brightness sun punches through 100% overcast while it is raining. This is
very visible: it makes a rainy day look sunny.

**Fix** — dim the disc, harder than elsewhere, because a disc reads as "sunny"
even at low weight:

```js
const discDim = 1 - covF*0.92;
L = Math.max(L, (150+diskI*120)*discDim);
const ww3 = diskI*0.82*sunV*discDim;
```

---

## 3. BUG — rain falls dead vertical regardless of wind

**Where:** streak spawn and integration (`roomstand.py:2288-2310`).

Streaks are bucketed **per column** (`colMap[s.c]`), so a streak can only ever
occupy one column. The `drift` field nudges `s.c` by whole columns, which reads
as a vertical fall that occasionally teleports sideways — "like a magnet is
pulling them down".

**Fix** — give each streak a slope and rasterise it, rather than bucketing:

```js
// slope = horizontal cells per vertical cell
const fall = Math.max(baseSpeed, 0.05);
const push = driftSign * (scWind/22);
s.slope = Math.max(-2.5, Math.min(2.5, push/fall));
```

Then walk the streak from its head when drawing:

```js
for(let k=0;k<s.len;k+=0.5){
  const row=s.y-k, col=s.c-s.slope*k;     // trail lags along the slope
  ...
}
```

Because the slope is `wind ÷ fall speed`, fast rain in light wind stays near
vertical while slow snow in a gale goes almost sideways — which is correct, and
falls out for free.

---

## 4. NEW — one adaptive detail mechanism, used by everything

**Replaces:** `subdivideByMap` / `subdivideDetail` (`roomstand.py:2840`, `:2894`).

The Pi has two similar-but-different subdivision functions, and the moon path
hardcodes `ctx.arc()` — so a subdivided cell is drawn as a **dot even in glass
style**, breaking the theme.

Elemental has a single primitive:

```js
function detailDepth(contrast, thresh, SP, minSubPx, hardMax){
  if(contrast < thresh) return 1;                    // flat: leave it whole
  const affordable = Math.floor(SP/minSubPx);        // still visible
  if(affordable < 2) return 1;
  const wanted = 1 + Math.round(contrast*5);         // scales with detail
  return Math.max(2, Math.min(wanted, Math.min(affordable, hardMax)));
}
```

Two rules that matter:

1. **A refined cell is still a mosaic cell.** It goes through the *same*
   styling function as every other cell, so glass stays bevelled squares and
   dots stay dots, all the way down. Do not hardcode `arc()`.
2. **Subdivision never changes an object's shape.** Which cells belong to a
   feature is decided at coarse resolution; refinement only redistributes
   detail *inside* them. The moon's limb must stay chunky.

Used by: moon face, bright stars, water beads. Each passes its own `hardMax`
(moon 6, stars 4).

---

## 5. NEW — the moon has one owner, and detail is a ratio

**Where:** moon block (`roomstand.py:2473`) + `subdivideByMap`.

Two problems on the Pi:

- The coarse cell sets `w=1`, and at `w=1` the blend `R0 += (cr-R0)*w` is a
  straight assignment — **the luminance `L` is discarded entirely**. Every
  coarse moon cell comes out the same flat `rgb(236,240,252)`.
- The subdivided pass shades properly from `moonSample`, so cells it declines to
  subdivide read as blown-out white squares against refined neighbours.

**Fix** — scale the *tint*, not `L`, and express detail as a ratio:

```js
// coarse pass
const v = moonSample(mx/moonR, my/moonR);
const k = Math.min(1,(180*moonLit+20)*moonDim*v/255);
w=1; cr=236*k; cg=240*k; cb=252*k;

// detail pass — relative to what the coarse cell already used
const ratio = vSub / Math.max(vCell, 0.05);
```

Because a split cell averages back to what was there, **there is no seam** with
an unsplit neighbour, by construction.

Two more moon fixes:

- **Use cell centres for radial tests.** The Pi addresses cells by top-left
  corner, so the coarse disc sits half a cell right and down of the detail pass
  — visible as bright squares hanging off the lower-right limb.
- **Sub-cells outside the disc must skip the terminator test.** Outside the
  disc `chord → 0`, so every such sub-cell reads as unlit and the limb turns
  black.
- The unlit side at `(52,58,76)` (`:2479`) lands *above* the night sky after the
  ramp LUT and night boost, so a crescent drags a grey ghost of its dark side
  around. `(26,30,42)` sits just above sky level — roughly earthshine.

---

## 6. NEW — water changes material, it does not sit on top

**Replaces:** `drawGlass` (`roomstand.py:2710`).

The Pi draws droplets as alpha-blended circles with white highlights. Because
they **add light**, they read as bright confetti scattered over a calm grid, and
they ignore the current style entirely.

Elemental stamps water into a per-cell grid as **wetness**, and a wet cell is
the same cell in the same theme, only wetter:

```js
const k = Math.min(wetness * kindWeight, 0.55);       // hard ceiling
col = mix(col, col*0.80, k);                          // wet darkens
col = mix(col, lum + (col-lum)*1.35, k*0.7);          // and saturates
```

Only **mature** drops (past ~72% of their critical radius, or already running)
also get a bead on top — built from whole cells, with a lens gather from behind,
rim *darkening* where it meets the glass, and one restrained glint. Darkening
the rim rather than brightening is what stops beads reading as confetti.

Scale the whole field by real rainfall — `rainIntensity = rain/5 + snow/4` — so
0.1mm drizzle is barely perceptible and 6mm visibly soaks the pane.

---

## 7. NEW — droplet physics instead of a countdown

**Where:** `drawGlass` droplet loop (`roomstand.py:2732`).

The Pi releases a drop when a random `hold` timer expires. Replace with:

- **Condensation** — a clinging drop keeps gathering: `r += dt*SP*0.09*inten`
- **Surface tension** — it detaches when `r >= rCrit`, where `rCrit` is
  per-drop (`SP*(0.34+rand*0.30)`), so some spots hold a fatter bead
- **Terminal velocity** — `vTerm = 260*sqrt(r/SP)`, so bigger drops fall faster:
  `v += gravity*(1 - v/vTerm)*dt`
- **Coalescence** — a falling drop absorbs clinging ones it catches; volumes
  add, so radii add as cube roots and momentum carries over

Coalescence is what produces a few heavy fast runs instead of a uniform field of
identical beads — the thing that makes real rain-on-glass look right.

---

## 8. NEW — the bottom edge is not a wall

The Pi deletes a drop at `y > H`. Instead:

- Track `rainDuration`, accumulating while wet and draining ~3× faster when dry
- Grow a **pool** at the bottom edge from that duration, so hours of rain look
  different from a shower (a flood watch should look like one)
- ~22% of drops carry enough momentum to **run off the lip**; the rest merge
  into the pool and feed it

Render the pool mostly as a **mirror** taking the sky from above, not as a dark
band — darkening it heavily reads as a black stripe across the screen.

---

## 9. NEW — long-lived states of the pane

- **Grime** settles out of dirty air above AQI 60 and **washes off in rain**, so
  a filthy week builds up visibly and one shower clears it. Desaturates and
  browns the cell.
- **Steam** fogs the pane when humidity is high; the sun burns it off. It lifts
  the blacks and kills contrast the way a fogged window does — it does not
  simply add white.

---

## 10. NEW — screen furniture as collision geometry

The wallpaper draws *behind* the dock, so anything rendered at its position is
hidden. Use that: treat furniture as things water **lands on**. Drops hit a
surface's top edge, burst into ballistic spray that arcs into the visible area,
and snow accumulates on top. Whatever lands behind is occluded by the furniture,
which is what real water does.

On the Pi the equivalent is any fixed UI you draw over the scene — the clock
block, the weather stack, the F1 card. Rain hitting the top edge of those and
spraying would work identically.

---

## 11. NEW — wake replay

After a gap over 10 minutes, replay the missed interval as a decelerating
time-lapse before settling into now, instead of the sun teleporting:

```js
const eased = 1 - Math.pow(1-t, 3);              // ease-out cubic
const behind = gap * (1 - eased);                // how far back we are showing
astro = astroAt(now - behind);
sceneSpeed = 1 + 59*Math.pow(1-t, 2);            // 60x -> 1x
```

Gaps under 10 minutes resume instantly — replaying a brief interruption is worse
than not.

---

## 12. TUNE — assorted

- **Sub-dot radius.** `size: 0.70` (`:2635`) covers all but a sub-cell's
  corners, so dots merge into a smooth blob. Under `0.5` the darker bed reads as
  grout and the face stays made of dots.
- **Uniform vs contrast-varying depth.** Varying subdivision depth by contrast
  gives different dot sizes in different patches of the same object. On the Pi
  it saves draw calls, so keep it — but consider clamping the range.
- **`fexp`.** The `t=1+x/32; t^32` approximation differs from `exp()` by ~15% at
  `x=-3`, which is visible in glow falloffs. Elemental reproduces it exactly for
  fidelity. If you ever want them to match a native renderer, that is the term.

---

## 13. BUG — winner-takes-all compositing, so nothing can pass in front

Both engines accumulate one weight per cell and keep the largest
(`if (ww > w) { w = ww; ... }`). The moon sets `w = 1`, the maximum, so no cloud
can ever be drawn over it — the moon is pasted onto the sky at every cover.

Composite `over` instead, far to near — stars, moon and sun, then high, mid,
low cloud, then falling rain:

```js
// tint = mix(tint, layerColour, a);  w = w + (1-w)*a
cr += (lc.r - cr)*a; cg += (lc.g - cg)*a; cb += (lc.b - cb)*a;
w   = w + (1 - w)*a;
```

Compute the three cloud opacities BEFORE the bodies, derive

```js
occlusion  = 1 - (1-high*0.22)*(1-mid*0.78)*(1-low*0.97);
seeThrough = 1 - occlusion;
```

and attenuate each body's **luminance** by `seeThrough`. Attenuate luminance
only — the `over` blend already handles the tint, and doing both fades the moon
twice as fast as the cloud is thick.

## 14. BUG — total cover used as a second, blanket occluder

`sunDim = 1 - cov*0.65`, `moonDim = 1 - cov*0.50`, the disc's
`1 - cov*0.92`, and `starVis = 1 - cov/0.7` all dim bodies by the cover
*number* regardless of where the cloud actually is. Stacked on real occlusion
that is double-counting, and on its own it is enough to **erase the moon at 55%
cover with no cloud drawn anywhere near it** — verified by rendering cover 55
with all three layer amounts at zero.

Once §13 is in, cut them right back — `0.25` / `0.15` / `0.30` — and make
`starVis` cell-local: `seeThrough²`, not a global cover test.

Guard the fallback: if the three layer values are all absent, put the total into
the **low** deck. Unoccluded is the wrong failure mode — a full moon blazing
through overcast.

## 15. NEW — two scattering laws, not one

Light from a body behind cloud has to end up *in* the cloud, or the body just
disappears. Two different laws, and using one for everything is what made the
moon vanish behind cirrus (the cloud over it was at full opacity, so an
edge-glow law gave it nothing):

- **Translucent** (ice, thin water) — the sheet is a diffuser, so glow rises
  with opacity: `glow = amt * bodyProx`. This is the wide soft blob a full moon
  makes behind cirrus.
- **Opaque** (the low deck) — only the ragged fringe transmits, so glow peaks at
  half cover and dies in the solid core: `glow = 4*amt*(1-amt) * bodyProx`. This
  is the silver lining.

`bodyProx = fexp(-dist / (moonR*2.1)) * illum * (1 - skyBr*0.65)`, plus the same
for the sun. Apply it to falling rain too — a streak crossing the moon is a
bright thread, the same streak away from it is a dim one.

The deck also shades what hangs under it: below its edge, subtract
`under² * 30 * cloudLow * nightCloudDim` over about `0.30 * H`.

## 16. BUG — the sky tint weight collapses at night

```js
tf = (0.34 + (1-li)*0.42) * lumaOf(sky) / 210;   // <- the bug
```

Weighting the hue blend by the sky's own *brightness* means that at night, when
the sky is at its most colourful in relative terms, `tf` falls to about **2%**
and the whole scene renders as a wall of neutral grey tiles. It is the single
biggest reason a night scene reads flat: with no hue anywhere, nothing separates
from anything.

Take the sky's **chroma**, not its value — normalise to unit luminance and
re-light it at the cell's own brightness:

```js
const skyL   = Math.max(4, lumaOf(sky));
const chroma = mix([1,1,1], sky.map(v => v/skyL), 0.82);
const gl     = lumaOf(g);
tf = 0.34 + Math.max(0, 1-li)*0.42;
g  = g.map((v,i) => v + (chroma[i]*gl - v)*tf);
```

## 17. BUG — the cloud blanch is a daylight colour at every hour

`r += (198-r)*ck` washes an overcast **midnight** to the same pale grey as an
overcast noon. Overcast at night is dark, and what light it has is the orange
the city throws up at it. Make the target time-of-day dependent:

```js
const tgt = mix([26,24,30], [198,198,200], skyBr(sAlt));
```

This plus §16 is what turned Greater Noida at 23:39 from a flat grey-brown murk
into deep indigo with a warm horizon glow.

## 18. BUG — `min(1, prof)` turns the cloud deck into rectangles

Under heavy cover the deck profile (`:2280`) spends long stretches pinned at
exactly `1`, so the edge comes out as flat-topped rectangles with cliffs where
it comes off the clamp. Soft knee instead, asymptotic to 1:

```js
const knee = 0.62;
const p = prof <= knee ? prof
        : 1 - (1-knee) * Math.exp(-(prof-knee) / (1-knee));
```

## 19. TUNE — making the moon read as an object

Four things, all needed together; any one alone is not enough:

- **Limb darkening.** `0.86 + 0.14*sqrt(1-rr)` is a 14% swing — under one
  quantisation level after the ramp LUT and a posterize step of 16, so the disc
  is a flat plate with a cliff edge. Use `0.60 + 0.40*sqrt(sqrt(1-rr))`. Flatter
  than a real full moon, but a mosaic of 18px cells needs the form exaggerated
  to survive quantisation at all.
- **Halo.** A flat `26` reaching 1.8 radii is invisible against a lifted night
  sky. Scale with illumination, reach 2.6 radii, and fall off inverse rather
  than linear so the near ring is bright and the tail is long:
  `amp = (16 + 62*illum) * moonDim`, `fall = 1/(1+t*20) - 1/21` for
  `t = (d-R)/(R*1.6)`.
- **Contrast socket.** Just past the glow, pull the sky down:
  `L -= ring² * 9 * illum * seeThrough` with `ring = 1 - |t-0.72|/0.28`.
  Nothing in the sky actually darkens near the moon, but the eye adapts to the
  bright source and reads the surround as darker. Reproducing that is the
  difference between an object sitting **in** the sky and one pasted **on** it.
- **Terminator as a distance, not a boolean.** `litSide()` is right for deciding
  a whole cell, but the detail pass works at a fraction of a cell, and at 98%
  illumination the unlit sliver is thinner than one sub-cell — so the boolean
  renders it as a single black square hanging off the limb, which reads as a
  dead pixel. Return a signed distance and
  `smoothstep(-R*0.05, R*0.05, sd)` across it.

---

## Data notes

Elemental uses the same Open-Meteo endpoints, including the 15-minute nowcast
override. Worth confirming the Pi still does the wildfire-smoke discrimination
(`roomstand.py:1315`) — requiring **both** high aerosol optical depth **and**
fine-particle dominance is what stops Delhi's coarse dust turning the sky
orange. It is correct there; do not simplify it to an AQI threshold.
