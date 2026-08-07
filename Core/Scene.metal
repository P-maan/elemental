//  Scene.metal — Elemental mosaic engine
//
//  Direct transcription of the dot-mosaic renderer in roomstand.py's PAGE
//  template (drawScene, _skyRGB, _skyBr, _sunTint, _cloudTint, litSide,
//  subdivideByMap, moonSample). That JS is a double loop over grid cells where
//  each cell computes a colour from analytic fields — i.e. a fragment shader
//  written in JavaScript. Here it is as one.
//
//  Pass A  cellPass     -> COLS x ROWS texture, one fragment per mosaic cell
//  Pass B  presentPass  -> full res; shape (square|dot) x finish (glass|flat)
//  Pass C  folded into B: moon terminator subdivision + grid-snapped stars
//
//  Reference cell maths lives at roomstand.py:2395-2598. Keep them in sync.

#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------- uniforms
// All scalars, 4-byte aligned, no vector types — so Swift's struct layout
// matches without any packing rules to reason about. Mirrored in SceneState.swift.
struct Uniforms {
    float cols, rows;          // grid dimensions
    float pixW, pixH;          // presentation target size in pixels
    float cellSP;              // cell edge in pixels
    float time;                // seconds, absolute wall clock derived
    float sunAlt, sunAz;
    float moonAlt, moonAz, moonIllum, moonPhase;
    float facingAz;
    float covF;                // cloud cover 0..1
    float aqiF, smokeF;
    float uv, wind, windDir, rain, snow, vis, humid;
    float scAQI;
    int   code;                // WMO weather code
    int   kind;                // 0 sun 1 partly 2 cloud 3 rain 4 snow 5 thunder
    float flashAmp;            // lightning flash 0..1
    float shootActive, shootX, shootY, shootT0;
    int   starCount;
    int   boltCount;
    int   shape;               // 0 square, 1 dot
    int   finish;              // 0 glass, 1 flat
    float posterQ;
    float nightBoost;
    float cbase;
    float skyBrAmt;
    float lowfx;               // 1 = skip detail passes
    float glassWet;            // residual sheen on the pane, 0..1
    float grime;               // dirt settled out of the air, 0..1
    float steam;               // condensation fogging the pane, 0..1
    float cloudLow, cloudMid, cloudHigh;   // cover by altitude, 0..1
    float fogOn;               // observed fog, not inferred from the code
    // ---- relief block (see PASS B). Mirrored field-for-field in SceneState.swift.
    float depthAmt;            // block height scale, 0..1
    float emphAmt;             // 0..1; how much height follows FEATURES over tone
    float lightInt;            // 0..1
    float refractAmt;          // 0..1, glass only
    float dispersAmt;          // 0..1, glass only
    float frostAmt;            // 0..1, glass only
    float splayAmt;            // 0..1
    // ---- what is falling, and how dark it has got. These two took over the
    // pair of tail pad floats, so the struct is still 56 fields / 224 bytes.
    float pform;               // PrecipForm: 0 none 1 drizzle 2 rain 3 freezing
                               // 4 ice pellets 5 snow 6 snow grains 7 graupel 8 hail
    float gloomF;              // 0..1, light the deck is taking out
    // ---- a second block of four, taking the struct from 224 to 240 bytes.
    float dropMM;              // SurfaceWeather.dropDiameter, mm. Inverted from
                               // the MEASURED fall speed, so it is what says
                               // whether a sunlit shower gives a vivid spectral
                               // bow or a broad white fogbow.
    float edrHead;             // display headroom actually available right now.
                               // 1 = plain SDR; above that is how far past white
                               // this frame may go. Read from NSScreen every
                               // frame, never assumed — see WallpaperSurface.
    float pad0, pad1;
};

// Rain is rasterised at this multiple of the cell grid in each axis.
// Mirrored in Simulation.streakSub — change both together.
constant float STREAK_SUB = 3.0f;

struct Breather { float ax, ay, R, per, s1, s2, ph, ph2; };
struct Star     { float alt, az, br; float _p; };   // raw horizontal coords
struct Streak   { float c, y, len, v; };           // c = column index
struct BoltPt   { float x, y; };

// ---------------------------------------------------------------- helpers
// fexp: the reference's fast approximate exp (t=1+x/32, t^32). Reproduced
// exactly rather than swapped for exp() — at x=-3 the two differ ~15%, which
// is visible in the sun/moon glow falloffs.
inline float fexp(float x) { return x < -6.0f ? 0.0f : powr(1.0f + x / 32.0f, 32.0f); }

inline float skl(float a, float b, float t) { return a + (b - a) * saturate(t); }

// Stable per-cell phase, standing in for the JS dotPh[] random array.
inline float cellPhase(uint idx) {
    uint h = idx * 747796405u + 2891336453u;
    h = ((h >> ((h >> 28) + 4u)) ^ h) * 277803737u;
    h = (h >> 22) ^ h;
    return float(h & 0xFFFFFFu) / float(0xFFFFFF) * 6.28318f;
}

// Sky ambient brightness 0->1 (roomstand.py:2237)
inline float skyBr(float sAlt) {
    if (sAlt <= -18.0f) return 0.04f;
    if (sAlt <=  -6.0f) return skl(0.04f, 0.18f, (sAlt + 18.0f) / 12.0f);
    if (sAlt <=   0.0f) return skl(0.18f, 0.46f, (sAlt +  6.0f) /  6.0f);
    if (sAlt <=   6.0f) return skl(0.46f, 0.82f,  sAlt / 6.0f);
    if (sAlt <=  22.0f) return skl(0.82f, 1.00f, (sAlt -  6.0f) / 16.0f);
    return 1.0f;
}

// ================================================================ SKY COLOUR
//
// What replaced the table, and why.
//
// Everything below used to be a stack of hand-picked RGB triples interpolated
// by sun altitude — ported from roomstand.py and nudged by eye ever since. Every
// colour bug this project has had came out of it: an inverted gradient exponent,
// a civil-twilight ramp with green below both red and blue at every point (that
// is magenta, and the sky is never any part of magenta), a cover blend capped at
// 28% so a raining sky stayed bright blue. Those were each fixed in place, which
// is the problem — a table has no way to be right, only ways to be less wrong.
//
// So the clear sky is now COMPUTED. Single-scattering airlight, per sRGB
// primary, from published optical depths:
//
//   Rayleigh   tau_R(lam) = 0.008569 lam^-4 (1 + 0.0113 lam^-2 + 0.00013 lam^-4)
//              -> (0.0683, 0.0973, 0.2213) at 600/550/450nm, sea level.
//   Aerosol    Angstrom tau_a(lam) = beta lam^-alpha.
//   Airmass    Kasten & Young (1989): 1 at the zenith, 37.9 at the horizon.
//
// Those three give nearly all of it for free, and each is a MEASUREMENT rather
// than a preference:
//
//   * the zenith is blue because tau_B is 3.2x tau_R and the path is short, so
//     the scattering stays selective;
//   * the horizon is pale because the path is ~38 airmasses, every channel
//     saturates at (1 - e^-tau*m) -> 1, and what is left is white. This is why
//     an overcast is grey rather than a dimmer blue, and it is the distinction
//     the old table could not express at all;
//   * a low sun goes orange because the beam LIGHTING the air has crossed the
//     same 38 airmasses and lost its blue before it ever scatters;
//   * haze whitens because aerosol at alpha~1.3 is barely selective
//     (0.89/1.00/1.30 across RGB against Rayleigh's 0.70/1.00/2.27), and thick
//     mist whitens completely because droplets in the geometric regime scatter
//     every wavelength alike (alpha -> 0).
//
// Cross-checked against measured daylight. Converting the model's blue/red ratio
// to a correlated colour temperature through the CIE daylight locus
// (x_D cubic in 1/T; y_D = -3.000 x^2 + 2.870 x - 0.275) gives:
//
//   noon zenith        8500 K      45 deg up, noon      12000 K
//   noon horizon       7300 K      sun 15 deg, horizon   4400 K
//   sun 5 deg, zenith 11400 K      sun 5 deg, horizon    3000 K
//   V = 2km mist       5700 K      V = 5km haze          6100 K
//
// Published clear-sky skylight runs 5400-33000 K (Hernandez-Andres et al.,
// JOSA A 18, 1325, Granada, 2600 spectra), so every one of those sits inside the
// measured band, and the ORDERING is right: zenith cool, horizon warm, warm band
// low while the zenith stays blue at golden hour, haze pulling everything toward
// neutral. That last check is the one the table failed.
//
// Twilight follows Lynch, Dearborn & Lock, "Antitwilight I: structure and
// optics", Appl. Opt. 56(19) G156 (2017) — see the twilight block below.
// Overcast chromaticity is 6415 K (Chain, Dumontier & Fontoynont; mean of Lee &
// Hernandez-Andres' 9100 spectra is 6358 K) — near-neutral, very slightly blue,
// and uniform over the hemisphere.

// Rayleigh optical depth of the whole sea-level atmosphere at the sRGB primaries.
constant float3 TAU_RAYLEIGH = float3(0.0683f, 0.0973f, 0.2213f);
// Linear-light luminance weights (Rec.709 / sRGB).
constant float3 LUMW = float3(0.2126f, 0.7152f, 0.0722f);

// Relative optical airmass, Kasten & Young (1989). 1.0 at the zenith, 37.9 at
// the horizon — the plain 1/cos(z) it replaces diverges there, which is exactly
// where all the interesting colour is.
inline float airmassKY(float zenithDeg) {
    float z = min(zenithDeg, 91.5f);
    return 1.0f / (cos(z * (M_PI_F / 180.0f))
                   + 0.50572f * powr(96.07995f - z, -1.6364f));
}

// Clear-sky airlight, linear, per sRGB primary. Not normalised: the caller takes
// the chroma from it and sets the exposure separately, so the verified
// brightness ramp is left alone.
//
//   viewAlt   degrees above the horizon for this cell
//   cosGamma  cosine of the angle between the view ray and the sun
//   tauA      aerosol optical depth at 550nm, vertical
// Returns the three airlight channels in .rgb, and in .w the fraction of the
// scattering in this direction that was RAYLEIGH rather than aerosol. That
// fraction is the whole clear-versus-overcast distinction in one number:
// wavelength-dependent scattering makes blue, wavelength-independent scattering
// makes grey, and it is what decides how much purity to restore below.
inline float4 airlight(float sunAlt, float viewAlt, float cosGamma, float tauA) {
    // Angstrom exponent falls as the aerosol coarsens: ~1.3 for dry continental
    // haze, ~0 for fog and cloud droplets, which are large enough to be in the
    // geometric regime and scatter every wavelength alike. Ramping it with the
    // load is why 2km-visibility mist comes out white here instead of the warm
    // brown a fixed exponent gave.
    float alpha = 1.3f / (1.0f + 2.2f * tauA);
    float3 rel  = powr(float3(0.600f, 0.550f, 0.450f), -alpha);
    float3 tA   = tauA * (rel / rel.y);
    float3 tau  = TAU_RAYLEIGH + tA;

    float mV = airmassKY(90.0f - viewAlt);
    float mS = airmassKY(90.0f - max(sunAlt, 0.0f));
    // How much ATMOSPHERE the beam crossed before it reached the height this
    // view ray mostly scatters from — not merely how slanted it was.
    //
    // This was `1 + (mS-1)*f`, which only discounts the SLANT and still charges
    // every scattering point the full vertical column. That is a real error and
    // it lands almost entirely on blue, whose optical depth is three times red's:
    // a zenith ray was losing 30% of its blue to a beam that in truth had crossed
    // about a third of the column. It is most of why a clear midday sky came out
    // warm grey. A zenith view scatters around one scale height up, with roughly
    // two thirds of the mass already below it; a horizon view scatters low down,
    // where the beam really has crossed everything.
    float f   = 0.35f + 0.65f * powr(1.0f - saturate(viewAlt / 90.0f), 2.0f);
    float mSe = max(0.25f, mS * f);

    // Phase functions: Rayleigh is symmetric and mild, aerosol is sharply
    // forward. The aureole round a low sun, and the warm band that goes with
    // it, is the Mie term — which is also why that band is on the SUN's side of
    // the frame and not smeared round the whole horizon.
    float pR = 0.75f * (1.0f + cosGamma * cosGamma);
    const float g = 0.76f;
    // Cornette-Shanks rather than plain Henyey-Greenstein: same asymmetry, but a
    // sharper forward peak and markedly less scattering at 60-120 degrees, which
    // is where HG is known to over-predict. That mid-angle excess was neutral
    // Mie light landing exactly where the sky should be at its bluest.
    float den = powr(max(1.0f + g * g - 2.0f * g * cosGamma, 1e-4f), -1.5f);
    float pM  = min(1.5f * (1.0f - g * g) / (2.0f + g * g)
                    * (1.0f + cosGamma * cosGamma) * den, 6.0f);

    float3 beam     = exp(-tau * mSe);                  // sun, reddened by its own path
    float3 phase    = (TAU_RAYLEIGH * pR + tA * pM) / tau;
    float3 saturate_ = 1.0f - exp(-tau * mV);           // -> neutral at the horizon
    float rayFrac = TAU_RAYLEIGH.g * pR
                  / max(TAU_RAYLEIGH.g * pR + tA.g * pM, 1e-6f);
    return float4(max(beam * phase * saturate_, 1e-6f), rayFrac);
}

// Sky colour for one cell.
//
//   yFrac      0 at the top of the frame, 1 at the bottom
//   dAzDeg     azimuth of this cell relative to the SUN, degrees
//   tauA       aerosol optical depth, from visibility via Koschmieder
//   deckF      how much of the sky is behind something opaque, 0..1
//   gloomF     how much light the deck is taking out, 0..1
inline float3 skyRGB(float sAlt, float yFrac, float dAzDeg,
                     float aqiF, float deckF, float smokeF,
                     float gloomF, float tauA) {
    // Screen -> sky geometry. astroXY maps altitude 85..0 onto y 0..1, so this
    // is its exact inverse; the sky the cell shows and the sun drawn over it now
    // agree about where they are.
    float viewAlt = 85.0f * (1.0f - clamp(yFrac, 0.0f, 1.0f));
    float sa = sAlt * (M_PI_F / 180.0f), va = viewAlt * (M_PI_F / 180.0f);
    float cosGamma = clamp(sin(va) * sin(sa)
                         + cos(va) * cos(sa) * cos(dAzDeg * (M_PI_F / 180.0f)),
                           -1.0f, 1.0f);

    // ---- clear-sky chroma, from the scattering model
    float4 alF  = airlight(sAlt, viewAlt, cosGamma, tauA);
    float3 al   = alF.rgb;
    float rayFrac = alF.w;
    float3 chroma = al / max(dot(al, LUMW), 1e-6f);      // unit luminance

    // Below the horizon the single-scatter model runs out of validity: there is
    // no direct beam left in the layers we can see, and pinning the sun's
    // airmass at the horizon value — which is all it can do — paints the ENTIRE
    // sky the colour of the setting sun. Measured twilight does close to the
    // opposite. Lynch et al. find the upper sky still blue through civil
    // twilight, reaching neutral only around -2 degrees and going blue again
    // after; the orange is confined to a band on the sun's side. So the base
    // hands over to a pale blue upper sky and the structured bands below paint
    // the afterglow and the Belt onto it, rather than the whole frame inheriting
    // a sunset colour it should never have had.
    //
    // 11000 K on the CIE daylight locus, at unit luminance: the blue end of the
    // measured clear-sky range, which is what the upper sky reads as when the
    // reddened low path has dropped out of it.
    //
    // Weighted by WHERE we are looking, not applied flat. The model's reddening
    // is right in exactly one place — low down, on the sun's side, where the
    // line of sight really does run through air that is still lit and still
    // reddening what it scatters. Everywhere else it is wrong, and for opposite
    // reasons: a zenith view is lit from far above the terminator where the beam
    // has crossed almost nothing, and an ANTISOLAR low view is looking into the
    // earth's own shadow, where there is no direct beam at all. Single scattering
    // knows about neither, so it painted both of them sunset-orange — which is
    // what left the eastern horizon glowing like the western one.
    float upper    = saturate(viewAlt / 35.0f);
    float antiSide = saturate(-cos(dAzDeg * (M_PI_F / 180.0f)));
    float lowLit   = (1.0f - upper) * (1.0f - antiSide);
    float below = saturate((1.5f - sAlt) / 5.5f) * (1.0f - 0.72f * lowLit);
    chroma = mix(chroma, float3(0.798f, 1.012f, 1.478f), below);

    // ---- purity restored where the colour came from RAYLEIGH
    //
    // The one place this departs from straight colorimetry, and it is a
    // correction for the renderer downstream, not for the sky.
    //
    // The mosaic normalises this result to unit luminance and re-lights it at
    // the CELL's brightness (see the skyChroma block in PASS A). That is
    // deliberate — it is what stops a night scene going grey — but it throws
    // away the sky's own luminance, and being dark relative to the scene is half
    // of why a real blue sky reads as blue. Re-lit at the brightness of a white
    // wall, a colorimetrically exact zenith is a pale wash. So the chromatic
    // content is restored in proportion to how much of the scattering here was
    // Rayleigh — which is precisely the light whose colour is wavelength
    // selective, and precisely the light whose purity the eye is judging.
    //
    // Three properties make this safe rather than a fudge:
    //   * neutral stays neutral. A ratio of 1 is 1 at any exponent, so the
    //     overcast and rain path is untouched — 6415 K grey in, 6415 K grey out.
    //   * haze self-limits. Aerosol scattering drives rayFrac down, so a hazy
    //     sky gets less of it and stays paler than a clean one.
    //   * the warm horizon is protected. Its colour comes from beam extinction
    //     in the Mie-dominated direction straight at the sun, where rayFrac is
    //     low, so a sunset does not get pushed to an impossible saturation.
    // Applied as an exponent on the ratios rather than a linear stretch, so no
    // channel can be driven negative.
    // Floored at 0.35. Close to the sun a single forward-scattering lobe hands
    // essentially all the scattering to the aerosol, which zeroes the gain and
    // leaves the circumsolar sky as flat grey. The aureole is real but it is a
    // BRIGHTNESS effect: the molecular sky is still there behind it, and at a
    // noon sun every azimuth in the top of this frame is within 25 degrees of it,
    // so without a floor the whole upper frame loses its blue.
    float pureK = 1.0f + 2.2f * max(max(rayFrac, 0.35f), below * 0.95f);
    chroma = powr(max(chroma, 1e-4f), pureK);
    chroma /= max(dot(chroma, LUMW), 1e-6f);

    // ---- no sky is GREEN.
    //
    // The exponent above is a purity restoration: it takes whatever direction
    // the chroma already points and pushes it further. That is right when the
    // chroma runs blue-to-warm, which is the only axis a sky actually lives on.
    // But at a low sun there is a band, part way up, where the beam's reddening
    // (which favours red) and the view path's accumulation (which favours blue)
    // very nearly cancel — and what is left standing is GREEN, by a percent or
    // two. The exponent then faithfully amplifies that into a khaki cast, which
    // is what put an olive band across the sky at sunrise and sunset.
    //
    // Green may sit anywhere BETWEEN red and blue — that is an ordinary warm or
    // cool sky — but it may never be the largest of the three, because no sky
    // is green. Capping only the upper side leaves the magenta-leaning deep
    // twilight, where green legitimately falls below both, completely alone.
    chroma.g = min(chroma.g, max(chroma.r, chroma.b));
    chroma /= max(dot(chroma, LUMW), 1e-6f);

    // ---- exposure
    //
    // Kept as it was. `skyBr` is the verified time-of-day ramp and the scene is
    // tuned against it, so the model supplies HUE and the ramp supplies value;
    // rebuilding both at once would have made a regression impossible to
    // attribute. The horizon-brighter-than-zenith shape is the CIE clear sky's
    // and is what stops a frame reading as a flat wall.
    float lit  = skyBr(sAlt);
    float hk   = yFrac * yFrac * (3.0f - 2.0f * yFrac);
    float Lz   = 6.0f + 112.0f * lit;                   // zenith
    float Lh   = 9.0f + 196.0f * powr(lit, 0.78f);      // horizon
    float L    = mix(Lz, Lh, hk);
    float3 col = chroma * L;

    // ---- night floor
    //
    // Below astronomical twilight there is no sunlight in the column at all and
    // the scattering model has nothing to work on. What is left is airglow and
    // scattered starlight: very dark, and slightly blue to the adapted eye.
    // Blended in rather than switched to, so there is no seam at -18.
    float night = saturate((-12.0f - sAlt) / 6.0f);
    if (night > 0.0f) {
        float3 nightCol = mix(float3(3.0f, 5.0f, 14.0f), float3(7.0f, 9.0f, 20.0f), hk);
        col = mix(col, nightCol, night);
    }

    // ---- twilight
    //
    // Lynch, Dearborn & Lock, Appl. Opt. 56(19) G156 (2017) measured the
    // antisolar twilight as four bands and gave their motion with solar
    // altitude. Three of their findings drive this block:
    //
    //   * the Belt of Venus appears around -6 deg, is the brightest part of the
    //     antisolar sky by -2 deg, and is PINK, not orange — the sun-side
    //     afterglow is the orange one, and having both on the same 1-D ramp is
    //     why the old table could produce neither;
    //   * the boundary between the Belt and the earth's shadow beneath it rises
    //     about 8x as fast as the sun falls (their Fig. 16);
    //   * the colours are pale. Lee showed a vertical scan through civil
    //     twilight spans only a small region near the achromatic point in CIE
    //     u'v'. The old ramp's saturated magenta was not a mistuning of a real
    //     colour, it was a colour twilight does not contain.
    if (sAlt < 4.0f) {
        float tw = saturate((4.0f - sAlt) / 10.0f) * saturate((sAlt + 16.0f) / 8.0f);
        // Which side of the sky this cell is on. +1 straight at the sun.
        float side = cos(dAzDeg * (M_PI_F / 180.0f));
        float anti = saturate(-side);
        float solar = saturate(side);

        // Earth's shadow climbing the antisolar sky. The boundary between the
        // Belt and the shadow beneath it rises about 8x as fast as the sun
        // falls, so it sweeps the whole frame during civil twilight — which is
        // why the Belt is a fast-moving band and not a fixed glow.
        float shadowTop = clamp(-8.0f * sAlt, 0.0f, 70.0f);
        // The Belt sits just above the shadow line, 10-20 degrees thick, and is
        // always brighter in its lower part.
        float dBelt = (viewAlt - shadowTop) / 15.0f;
        // Weighted to reach full strength rather than tint: by -2 degrees the
        // Belt is the BRIGHTEST part of the antisolar sky (Lynch, Sec. 4C), so
        // a band that merely tinges the blue behind it is under-reading the
        // measurement, not over-reading it.
        float belt  = min(1.0f, 1.6f * exp(-dBelt * dBelt * (dBelt > 0.0f ? 1.0f : 2.2f))
                    * anti * tw * saturate((sAlt + 6.0f) / 4.0f));
        // Pale pink: red brightest, blue a shade ABOVE green. That ordering is
        // the whole difference between the Belt and an orange afterglow, and it
        // is why this cannot be a point on the same 1-D ramp as the sun side.
        col = mix(col, float3(1.00f, 0.74f, 0.78f) * L * 1.12f, belt);

        // The dark segment below it — the earth's shadow cast on the air,
        // bluish-grey and distinctly darker than everything around it.
        float dark = saturate((shadowTop - viewAlt) / max(shadowTop, 8.0f))
                   * anti * tw * saturate((sAlt + 11.0f) / 7.0f);
        col = mix(col, float3(0.68f, 0.77f, 1.00f) * L * 0.62f, dark * 0.60f);

        // Sun-side afterglow. Deepest right at the horizon and reddening as the
        // sun sinks, gone by nautical twilight.
        float low  = saturate(1.0f - viewAlt / 28.0f);
        float glow = solar * tw * low * low * saturate((sAlt + 9.0f) / 7.0f);
        float3 warm = mix(float3(1.00f, 0.34f, 0.16f), float3(1.00f, 0.62f, 0.30f),
                          saturate((sAlt + 6.0f) / 8.0f));
        col = mix(col, warm * L * 1.15f, glow * 0.82f);
    }

    // ---- wildfire smoke
    //
    // Smoke is the one aerosol that is not just a whitener: it ABSORBS in the
    // blue, so it reddens rather than greys. Its optical depth is already in
    // `tauA`; this is only the absorption that Angstrom scattering does not
    // describe.
    if (smokeF > 0.0f) {
        float sm = smokeF * (0.35f + 0.65f * hk);
        col *= mix(float3(1.0f), float3(1.12f, 0.72f, 0.42f), saturate(sm));
    }
    // Photochemical pollution: a weak brown, and a general loss of purity that
    // the aerosol term alone understates for an absorbing urban haze.
    if (aqiF > 0.0f) {
        float ds = aqiF * 0.16f * (1.0f - smokeF);
        float avg = dot(col, float3(1.0f / 3.0f));
        col = mix(col, float3(avg) * float3(1.05f, 1.00f, 0.92f), ds);
    }

    // ---- the deck
    //
    // You are not looking at the sky at all — you are looking at the bottom of a
    // cloud, and the only question is how bright it is.
    //
    // Chromaticity of a daytime overcast is 6415 +/- 133 K, uniform over the
    // hemisphere (Chain, Dumontier & Fontoynont); Lee & Hernandez-Andres put the
    // mean of 9100 spectra at 6358 K. sRGB's white point is D65 = 6504 K, so an
    // overcast is very slightly BLUER than neutral, not warmer — and thicker
    // decks are bluer still, because multiple scattering inside an optically
    // thick cloud enhances the droplets' own selective absorption (Lee &
    // Hernandez-Andres, Appl. Opt. 44, 5712). Hence day = (216,217,220) thin ->
    // (148,150,157) thick: neutral, darkening and very slightly cooling. Those
    // two were already right by eye and the measurements agree with them, so
    // they stay; what was wrong was never the target but the WEIGHT.
    //
    // The weight: `deckF` comes from the per-altitude cloud split, which is the
    // least reliable number in the whole forecast — the calibration layer exists
    // precisely because the model files low cloud as high. When that split is
    // wrong BOTH the cloud sprites and this blend under-fire, from the same bad
    // input, so the error doubles instead of cancelling and you get a bright
    // blue sky in the rain. `gloomF` and the falling precipitation are measured
    // independently of the split, so they set a FLOOR: this can be pushed
    // greyer by evidence, never bluer.
    float opaque = max(deckF, saturate((gloomF - 0.06f) / 0.30f));
    if (opaque > 0.06f) {
        float t  = saturate((opaque - 0.06f) / 0.94f);
        // Superlinear over the part the cloud pass will draw sprites for — blue
        // belongs in the gaps — but the part that only the gloom knows about has
        // nothing coming to cover it, so it blanches at full weight.
        float drawn  = saturate((min(deckF, opaque) - 0.06f) / 0.94f);
        float unseen = max(0.0f, t - drawn);
        float ck = saturate(powr(drawn, 2.2f) * 0.97f + unseen * 0.97f);
        float thick = t * t;
        float3 day   = mix(float3(216.0f, 217.0f, 220.0f), float3(148.0f, 150.0f, 157.0f), thick);
        float3 night2 = mix(float3(30.0f, 28.0f, 34.0f), float3(19.0f, 18.0f, 23.0f), thick);
        float3 tgt = mix(night2, day, lit);
        // Gloom is the light the deck is actually taking out, and it leads the
        // rain by up to two hours. Reaching the sky COLOUR and not only the
        // cloud tone is what makes the frame darken BEFORE the first drop —
        // which is the order the sky does it in.
        // 0.45 double-counted. `day` above ALREADY darkens with deck thickness
        // (216 down to 148), so multiplying by another 0.55 landed a daytime
        // overcast near 81 — dusk brightness at five in the afternoon. An
        // overcast day is dim, not dark; you can still read outside under one.
        // This is a modulation on top of a target that has already been dimmed,
        // so it has to be gentle or the two compound.
        tgt *= 1.0f - 0.22f * gloomF;
        // Not dead flat: an overcast is brightest overhead, where the sight line
        // through the deck is shortest, and greys down toward the horizon.
        tgt *= 1.05f - 0.17f * hk;
        col = mix(col, tgt, ck);
    }

    // ---- urban skyglow, at the horizon, through night and twilight
    //
    // Real skyglow is a horizon phenomenon, effectively gone more than ten or
    // fifteen degrees up. Cloud AMPLIFIES it rather than hiding it: a low deck
    // over a city catches the light going up and throws it back down, which is
    // why the orange nights are the overcast ones.
    if (sAlt < 2.0f && yFrac > 0.78f) {
        float reach = saturate((yFrac - 0.78f) / 0.22f);
        float lp = saturate((2.0f - sAlt) / 22.0f) * reach * reach
                 * 0.34f * (0.65f + 0.90f * opaque);
        col += (float3(88.0f, 54.0f, 30.0f) - col) * lp;
    }
    return max(col, 0.0f);
}

// Sun disc tint: deep red at the horizon -> warm yellow -> white
inline float3 sunTint(float sAlt, float aqiF) {
    float f = saturate(sAlt / 18.0f) * max(0.0f, 1.0f - aqiF * 0.45f);
    return float3(255.0f, skl(120.0f, 250.0f, f), skl(35.0f, 195.0f, f));
}

// Cloud face tint: warm at golden hour, cool blue-grey at night
inline float3 cloudTint(float sAlt, float light, float shade) {
    if (sAlt > 14.0f) return float3(max(0.0f, shade - 12.0f), max(0.0f, shade - 4.0f), min(255.0f, shade + 16.0f));
    if (sAlt > -1.0f) {
        float gf = (1.0f - min(1.0f, sAlt / 14.0f)) * light;
        return float3(min(255.0f, shade + gf * 88.0f),
                      max(0.0f,  shade + gf * 14.0f - 8.0f),
                      max(0.0f,  shade - gf * 45.0f));
    }
    float v = shade * 0.72f;
    return float3(max(0.0f, v - 8.0f), max(0.0f, v + 2.0f), min(255.0f, v + 20.0f));
}

// The luminance ramp LUT (HR/HG/HB in roomstand.py:1572), evaluated directly.
inline float3 rampLUT(float i255) {
    const float4 st[5] = {
        float4(0.00f,   6.0f,   6.0f,  12.0f),
        float4(0.35f,  95.0f,  95.0f, 110.0f),
        float4(0.60f, 175.0f, 175.0f, 192.0f),
        float4(0.82f, 235.0f, 235.0f, 247.0f),
        float4(1.00f, 255.0f, 255.0f, 255.0f)
    };
    float t = clamp(i255, 0.0f, 255.0f) / 255.0f;
    float4 a = st[0], b = st[4];
    for (int k = 0; k < 4; ++k) {
        if (t >= st[k].x && t <= st[k+1].x) { a = st[k]; b = st[k+1]; break; }
    }
    float u = (t - a.x) / max(b.x - a.x, 1e-6f);
    return float3(a.y + (b.y - a.y) * u, a.z + (b.z - a.z) * u, a.w + (b.w - a.w) * u);
}

// Which side of the terminator a point falls on (roomstand.py:2069)
inline bool litSide(float dx, float dy, float r, float phase) {
    float f = (1.0f - cos(2.0f * M_PI_F * phase)) * 0.5f;
    bool waxing = phase < 0.5f;
    float chord = sqrt(max(0.0f, 1.0f - (dy * dy) / (r * r)));
    float xt = r * cos(M_PI_F * f) * chord;
    return waxing ? (dx > xt) : (dx < -xt);
}

// Signed distance past the terminator, in pixels; positive on the lit side.
// litSide's boolean is right for deciding a whole cell, but the detail pass
// works at a fraction of a cell, and at 98% illumination the unlit sliver is
// thinner than one sub-cell — so a hard boolean turned it into a single black
// square hanging off the limb, which reads as a dead pixel rather than as a
// terminator. This gives the detail pass something it can fade across.
//
// It is a PERPENDICULAR distance, not a horizontal one. The terminator is the
// half-ellipse x = r*cos(pi*f)*sqrt(1 - y^2/r^2), so it runs nearly vertically
// across the middle of the disc and nearly horizontally at the cusps where it
// meets the limb. Measuring straight along x therefore overstates the distance
// by 1/cos(angle), and near the cusps that factor runs to thirty or more: the
// coverage fraction below saturates a whole cell early, the edge stops bending
// and the terminator ends as two straight vertical smears with the curve
// missing from between them. Dividing by the gradient magnitude turns it back
// into a true distance, so one law describes the edge all the way around and
// the crescent keeps its points.
inline float litDist(float dx, float dy, float r, float phase) {
    float f = (1.0f - cos(2.0f * M_PI_F * phase)) * 0.5f;
    float c = cos(M_PI_F * f);
    // Floored, because the gradient is 1/chord and the cusps are chord = 0.
    float chord = sqrt(max(1.0e-3f, 1.0f - (dy * dy) / (r * r)));
    float xt = r * c * chord;
    float s  = (phase < 0.5f) ? (dx - xt) : (-xt - dx);
    float gy = c * dy / (r * chord);              // d(terminator)/dy
    return s * rsqrt(1.0f + gy * gy);
}

// ---- moon albedo map. The near side is tidally locked so the maria sit in
// the same place every night: fixed, never random (roomstand.py:2675).
constant float3 MARIA[8] = {
    float3(-0.55f, -0.10f, 0.38f),   // Oceanus Procellarum
    float3(-0.30f, -0.42f, 0.28f),   // Mare Imbrium
    float3( 0.06f, -0.35f, 0.18f),   // Mare Serenitatis
    float3( 0.24f, -0.16f, 0.20f),   // Mare Tranquillitatis
    float3( 0.34f,  0.10f, 0.15f),   // Mare Fecunditatis
    float3( 0.52f, -0.44f, 0.11f),   // Mare Crisium
    float3(-0.10f,  0.30f, 0.16f),   // Mare Nubium
    float3(-0.42f,  0.30f, 0.18f)    // Mare Humorum
};

inline float moonSample(float nx, float ny) {
    float rr = nx * nx + ny * ny;
    if (rr > 1.0f) return 0.0f;
    float v = 0.95f;                                   // bright highlands
    for (int i = 0; i < 8; ++i) {
        float ex = nx - MARIA[i].x, ey = ny - MARIA[i].y;
        float d = sqrt(ex * ex + ey * ey) / MARIA[i].z;
        if (d < 1.0f) v = min(v, 0.58f + 0.16f * d);   // seas, softened at the edge
    }
    return v * (0.60f + 0.40f * sqrt(sqrt(max(0.0f, 1.0f - rr))));  // limb darkening
}

// ---- Relative tone of one point on the moon's face, in units of "fully lit at
// albedo 1". The lit face is the albedo; the shaded face is earthshine, which is
// FLAT — it is Earth-light bounced onto ground the sun is not reaching, so the
// maria do not show in it. That distinction is the whole reason this is one
// function rather than an albedo term times a phase term: multiplying them
// applies the albedo to the earthshine as well and drives the shaded limb to
// black, which is a hole in the disc rather than the far side of a sphere.
//
// `earthRel` is earthshine over full-lit, which is not a constant: at a thin
// crescent the lit face is dim and earthshine is nearly as bright, which is
// exactly when you can see it in the sky.
inline float moonTone(float v, float litF, float earthRel) {
    return mix(earthRel, v, litF);
}

/// Luminance of the fully lit face at albedo 1, before cloud.
///
/// NOT proportional to the illuminated fraction, which is what it was. A half
/// moon's lit half is as bright per unit area as a full moon's — what changes
/// with phase is how MUCH of it there is, not how bright it is. Scaling the
/// face by illum/100 made a crescent's lit sliver four times dimmer than a full
/// moon's, which dropped it to within a few levels of earthshine and erased the
/// terminator at exactly the phases where the terminator is the entire shape:
/// a half moon came out as a uniformly bright disc with no phase visible at all.
/// Some dependence is kept, because the real Moon does surge toward opposition.
inline float moonLitRef(float illum, float moonDim) {
    return (180.0f * (0.55f + 0.45f * saturate(illum / 100.0f)) + 20.0f) * moonDim;
}

/// Earthshine — sunlight off the Earth onto the moon's night side. Very nearly
/// constant, and slightly BRIGHTER at crescent: Earth's phase seen from the
/// Moon is the complement of the Moon's seen from here, which is why the old
/// moon in the new moon's arms is a crescent phenomenon.
inline float moonEarthRef(float illum, float moonDim) {
    return (28.0f + 12.0f * (1.0f - saturate(illum / 100.0f))) * moonDim;
}

/// The two levels cellPass draws the moon at, as a ratio. Both passes derive it
/// the same way from the same uniforms, so the detail pass is refining the
/// coarse cell rather than guessing at it. Cloud transmission scales both and
/// therefore cancels.
inline float moonEarthRel(float illum, float covF) {
    float dim = 1.0f - covF * 0.15f;
    return moonEarthRef(illum, dim) / max(moonLitRef(illum, dim), 1e-3f);
}

// Map alt/az to screen using facing azimuth (roomstand.py:2352)
inline float2 astroXY(float alt, float az, float facing, float W, float H) {
    float relAz = fmod(az - facing + 180.0f + 360.0f, 360.0f) - 180.0f;
    return float2((0.5f + relAz / 190.0f) * W, (1.0f - alt / 85.0f) * H);
}

// How much of the dome sits behind something you cannot see the sun through.
//
// Lives here rather than inline in cellPass because the rainbow needs the same
// number in the presentation pass, and a duplicated copy of this weighting is
// exactly the kind of law that drifts out of step and then disagrees with
// itself across two passes.
inline float deckOpaque(constant Uniforms &U) {
    return 1.0f - (1.0f - U.cloudLow)
                * (1.0f - U.cloudMid  * 0.80f)
                * (1.0f - U.cloudHigh * 0.22f);
}

// ================================================================ RAINBOW
//
// Strictly geometric, so it is GATED rather than faked. Three conditions, and
// not one of them is a preference:
//
//   SUNLIT RAIN     liquid drops falling AND the direct beam reaching them.
//                   Broken cloud, in other words — an overcast has no beam and
//                   a clear sky has no drops, so the bow lives in the narrow
//                   band between the two where a shower is lit from the side.
//   SUN BEHIND YOU  the figure is centred on the ANTISOLAR point, the direction
//                   exactly opposite the sun, so it is in frame only when the
//                   sun is at your back. Projected with astroXY like every
//                   other body, which is what makes it track the heading.
//   SUN BELOW 42    the primary arc sits 42 degrees from that centre, and the
//                   centre is at altitude -sunAlt. Past a sun altitude of 42 the
//                   whole ring is under the horizon. NOTHING enforces this: the
//                   frame stops at alt 0 and a midday bow simply has no cells to
//                   land on. It is why a rainbow is a morning and late-afternoon
//                   thing and never a midday-in-June one.
//
// Radii are the measured Descartes angles for water spheres, per wavelength.
// One internal reflection gives the primary at 40.5 (400nm) to 42.4 (700nm),
// RED OUTSIDE. Two give the secondary at 50.4 (700nm) to 53.9 (400nm) — the
// order back to front, and about a tenth of the light, because the second
// reflection is lossy and the same flux is spread over a wider ring. Between
// them lies Alexander's dark band: not a painted shadow but the range of
// deviations no ray can leave a sphere at, so the sky there really is darker
// than the sky on either side of it.

// Wavelength (nm) to RGB — Bruton's piecewise fit, with the eye's roll-off at
// both ends so 400nm reads as a dim violet rather than a bright one. Nothing
// else in the scene is spectral; this exists only for the bow.
inline float3 spectrumRGB(float nm) {
    float3 c;
    if      (nm < 440.0f) c = float3(-(nm - 440.0f) / 60.0f, 0.0f, 1.0f);
    else if (nm < 490.0f) c = float3(0.0f, (nm - 440.0f) / 50.0f, 1.0f);
    else if (nm < 510.0f) c = float3(0.0f, 1.0f, -(nm - 510.0f) / 20.0f);
    else if (nm < 580.0f) c = float3((nm - 510.0f) / 70.0f, 1.0f, 0.0f);
    else if (nm < 645.0f) c = float3(1.0f, -(nm - 645.0f) / 65.0f, 0.0f);
    else                  c = float3(1.0f, 0.0f, 0.0f);
    float f = 1.0f;
    if      (nm < 420.0f) f = 0.30f + 0.70f * (nm - 380.0f) / 40.0f;
    else if (nm > 700.0f) f = 0.30f + 0.70f * (780.0f - nm) / 80.0f;
    return saturate(c) * clamp(f, 0.0f, 1.0f);
}

// Angular distance from the ANTISOLAR point to the sky direction one screen
// point looks at.
//
// astroXY is an equirectangular map — 190 degrees of azimuth across the width,
// 85 of altitude down the height — so screen distance is NOT angle, and
// measuring the ring there would squash it into an ellipse a third too flat.
// So: astroXY places the centre, because that is what carries the heading, and
// the separation itself comes from the spherical law of cosines on the two
// coordinates read back out. The azimuth difference needs no wrapping, cosine
// being periodic in it.
inline float bowTheta(float2 p, constant Uniforms &U) {
    const float DEG = M_PI_F / 180.0f;
    float2 antiP = astroXY(-U.sunAlt, U.sunAz + 180.0f, U.facingAz, U.pixW, U.pixH);
    float dAz  = (p.x - antiP.x) / max(U.pixW, 1.0f) * 190.0f;
    float cAlt = (1.0f - p.y / max(U.pixH, 1.0f)) * 85.0f;
    float ca = cos(cAlt * DEG), sa = sin(cAlt * DEG);
    float cb = cos(-U.sunAlt * DEG), sb = sin(-U.sunAlt * DEG);
    return acos(clamp(sa * sb + ca * cb * cos(dAz * DEG), -1.0f, 1.0f)) / DEG;
}

/// Half the angular footprint of one cell at this altitude, in degrees. The
/// azimuth pitch narrows toward the zenith on a sphere even though the
/// projection's does not, hence the cosine.
inline float bowFootprint(float2 p, constant Uniforms &U, float pitchScale) {
    float cAlt = (1.0f - p.y / max(U.pixH, 1.0f)) * 85.0f;
    float ca = cos(cAlt * (M_PI_F / 180.0f));
    return 0.25f * pitchScale * (190.0f / max(U.cols, 1.0f) * max(ca, 0.30f)
                               + 85.0f / max(U.rows, 1.0f));
}

// How much of one CELL's angular footprint falls inside an annulus.
//
// This is most of what drawing a rainbow into a mosaic actually is. The primary
// bow is a couple of degrees wide; a cell at production density spans nearly
// three, so the bow is THINNER THAN THE SAMPLING GRID, and point-testing the
// cell centre against it gives a dashed line of whichever cells happened to
// land on the band — confetti, not an arc. So the cell is integrated over
// instead: it takes the band in proportion to how much of it the band really
// covers. Raise the grid density, or split the cell in the detail pass, and it
// sharpens on its own.
inline float bandCover(float theta, float halfW, float lo, float hi) {
    float a = max(lo, theta - halfW), b = min(hi, theta + halfW);
    return max(0.0f, b - a) / max(2.0f * halfW, 1e-3f);
}

/// Is what is falling LIQUID? Ice has no Descartes angle in the visible — a
/// sunlit snow shower gives haloes around the SUN, which is a different
/// phenomenon in the opposite half of the sky. Forms 1/2/3 are drizzle, rain
/// and freezing rain; 4 and up are all frozen.
inline bool bowLiquid(constant Uniforms &U) {
    return U.pform > 0.5f && U.pform < 3.5f;
}

/// Drop size decides which KIND of bow. `dropMM` is inverted from the measured
/// fall speed, so this follows the observation rather than the label on the hour.
inline float bowVivid(constant Uniforms &U) {
    return saturate((U.dropMM - 0.30f) / 1.20f);
}

/// How sunlit the rain is, and how much of that reaches the eye.
///
/// The beam is the whole gate: `deckF` is how much of the dome sits behind
/// something you cannot see the sun through, so what is left is the chance the
/// beam is coming through a gap. Zero under a closed overcast — which is the
/// "raining hard, no bow" case anyone has watched out of a window — and one in
/// a clear-sky sunshower. Broken cloud is plenty, hence the low knee.
inline float bowLit(constant Uniforms &U, float deckF, float sunDim, float seeThrough) {
    float beam = smoothstep(0.02f, 0.45f, 1.0f - deckF)
               * sunDim * saturate(U.sunAlt / 2.0f);
    // Already past the liquid gate, so it IS raining: `pform` only leaves
    // .none once 0.05mm is actually falling. The floor covers showers, which
    // the model files under a different field than `rain`.
    float rainF = clamp(U.rain / 1.2f, 0.35f, 1.0f);
    return beam * rainF * seeThrough;
}

/// What the bow does to one cell: a colour to blend toward, how strongly, how
/// much light it adds, and what it does to the sky behind it.
struct Bow {
    float3 col;
    float  amt;    // blend weight, 0..1
    float  lum;    // luminance added, in the pass's 0..255 units
    float  gain;   // multiplier on the sky behind — above 1 inside the primary,
                   // below 1 through Alexander's band
};

/// theta   angular distance from the antisolar point, degrees
/// halfW   half the angular footprint being integrated over
/// vivid   0 drizzle .. 1 large drops
/// lit     how sunlit the rain is, and how much of it reaches the eye
inline Bow bowAt(float theta, float halfW, float vivid, float lit) {
    Bow b; b.col = float3(1.0f); b.amt = 0.0f; b.lum = 0.0f; b.gain = 1.0f;

    // Large drops refract cleanly and land on the textbook radii. Below about
    // half a millimetre diffraction across the drop is comparable to the
    // deviation itself, the orders smear together, and what is left is a
    // fogbow: broader, sitting inward of 42, and white.
    float p0 = mix(34.5f, 40.2f, vivid), p1 = mix(42.0f, 42.4f, vivid);
    float s0 = mix(47.5f, 50.4f, vivid), s1 = mix(56.0f, 53.9f, vivid);

    // Alexander's band, and the brighter disc inside the primary. Both are real
    // and both are relative to the surrounding sky, so they are a MULTIPLIER:
    // that way the band is darker than its surroundings at any exposure and
    // cannot bottom a dim sky out.
    b.gain = 1.0f + saturate((p0 - theta) / 7.0f) * lit * 0.11f
                  - bandCover(theta, halfW, p1, s0) * lit * 0.26f;

    // A fogbow is not merely a colourless rainbow, it is a FAINTER one: the
    // diffraction that smears the orders together also spreads the same flux
    // over three times the angular width, so what any one direction returns is
    // well down on a large-drop bow.
    lit *= 0.45f + 0.55f * vivid;

    // Chroma is deliberately short of the full spectrum. A rainbow is a pale
    // thing — a few per cent of contrast against a bright sky — and the weather
    // tint downstream multiplies whatever saturation arrives here by up to 0.97,
    // so a fully saturated band comes out of the far end as pure primaries laid
    // in squares. Pastel in, correct out.
    float chroma = 0.58f * (0.14f + 0.86f * vivid);

    float pCov = bandCover(theta, halfW, p0, p1);
    if (pCov > 0.004f) {
        // The hue at the MIDPOINT of the overlap, not at the cell centre
        // clamped into the band. Clamping snaps every cell that straddles an
        // edge to pure violet or pure red, so neighbouring cells along the arc
        // flip between the two ends of the spectrum and the band reads as noise.
        // The midpoint moves smoothly and monotonically with theta, which is
        // what puts violet on the inside, green in the middle and red on the
        // outside in that order.
        float mid = 0.5f * (max(p0, theta - halfW) + min(p1, theta + halfW));
        float t   = saturate((mid - p0) / max(p1 - p0, 1e-3f));
        b.col = mix(float3(1.0f), spectrumRGB(mix(400.0f, 700.0f, t)), chroma);
        b.amt = min(0.72f, pCov * lit * 1.30f);
        b.lum = pCov * lit * 74.0f;
    }

    // Secondary: the same figure with one more internal reflection, so the
    // order is REVERSED — red on the inside now — and it is roughly a tenth as
    // bright. Scaled by vivid as well, because a fogbow has barely any.
    float sCov = bandCover(theta, halfW, s0, s1) * (0.18f + 0.82f * vivid);
    if (sCov > 0.004f) {
        float mid = 0.5f * (max(s0, theta - halfW) + min(s1, theta + halfW));
        float t   = saturate((mid - s0) / max(s1 - s0, 1e-3f));
        float3 sc = mix(float3(1.0f), spectrumRGB(mix(700.0f, 400.0f, t)), chroma * 0.8f);
        float a   = min(0.20f, sCov * lit * 0.26f);
        // Laid over whatever the primary left, so the two never fight for one
        // winning weight. They do not overlap in theta, so in practice only one
        // of them is ever non-zero.
        b.col = mix(b.col, sc, a / max(a + b.amt, 1e-3f));
        b.amt = b.amt + (1.0f - b.amt) * a;
        // A twelfth of the primary's, which is the order the second reflection
        // and the wider ring between them leave.
        b.lum += sCov * lit * 6.0f;
    }
    return b;
}

// Stars are projected here rather than on the CPU, because with a moving
// heading the view can swing at any time and reprojecting the catalog per frame
// on the CPU would be both wasteful and a frame behind. Returns false when the
// star falls outside the +/-95 degree view.
inline bool starXY(constant Star &st, float facing, float W, float H, thread float2 &out) {
    float relAz = fmod(st.az - facing + 180.0f + 360.0f, 360.0f) - 180.0f;
    if (abs(relAz) > 95.0f) return false;
    out = float2((0.5f + relAz / 190.0f) * W, (1.0f - st.alt / 85.0f) * H);
    return true;
}

// ================================================================ PASS A
// One fragment per mosaic cell. Output is the cell's colour, pre-presentation.

struct VOut { float4 pos [[position]]; float2 uv; };

vertex VOut fullscreenVS(uint vid [[vertex_id]]) {
    // oversized triangle covering the viewport
    float2 p = float2((vid << 1) & 2, vid & 2);
    VOut o;
    o.pos = float4(p * 2.0f - 1.0f, 0.0f, 1.0f);
    o.uv  = float2(p.x, 1.0f - p.y);
    return o;
}

// Two targets. The colour is the mosaic; `aux` is how much of what is BEHIND
// the cloud at this cell still reaches the eye — the same `seeThrough` the
// bodies are attenuated by here.
//
// It has to be carried forward rather than recomputed, because presentPass runs
// at full resolution and knows only geometry: where the moon is, not what is in
// front of it. Without this the detail pass subdivides and re-shades a moon
// sitting behind a solid overcast deck, punching a finely-tiled disc straight
// through the cloud that is supposed to be covering it. Recomputing the three
// cloud opacities there instead would be thirty lines of duplicated law that
// has to stay in step with this pass forever; one channel of a 56x36 texture
// costs nothing and cannot drift.
struct CellOut {
    float4 colour [[color(0)]];
    float  aux    [[color(1)]];
};

fragment CellOut cellPass(VOut in [[stage_in]],
                         constant Uniforms  &U        [[buffer(0)]],
                         constant Breather  *breathers[[buffer(1)]],
                         constant Star      *stars    [[buffer(2)]],
                         constant Streak    *streaks  [[buffer(3)]],
                         constant int2      *colIndex [[buffer(4)]],  // per column: (start, count)
                         constant BoltPt    *bolt     [[buffer(5)]],
                         constant float     *edgeArr  [[buffer(6)]],
                         texture2d<float>    streaks2 [[texture(0)]])
{
    int ix = int(in.pos.x), iy = int(in.pos.y);
    int COLS = int(U.cols), ROWS = int(U.rows);
    if (ix >= COLS || iy >= ROWS) return CellOut{ float4(0), 1.0f };

    uint  idx   = uint(iy * COLS + ix);
    // Same per-axis pitch presentPass uses — see the note there. This pass has
    // to agree with it exactly, or the coarse sun/moon discs land on different
    // cells than the full-res detail pass refines.
    float2 SPv  = float2(U.pixW / max(U.cols, 1.0f), U.pixH / max(U.rows, 1.0f));
    float SP    = min(SPv.x, SPv.y);
    float x     = float(ix) * SPv.x, y = float(iy) * SPv.y;
    // Cell centre. The reference addresses cells by their top-left corner,
    // which leaves the coarse sun/moon discs sitting half a cell right and
    // down from the full-res detail pass — visible as bright squares hanging
    // off the moon's lower-right limb. Radial tests use the centre instead.
    float cxp   = x + SPv.x * 0.5, cyp = y + SPv.y * 0.5;
    float W     = U.pixW,  H = U.pixH;
    float sec   = U.time;
    float sAlt  = U.sunAlt;
    float dotPh = cellPhase(idx);

    float covF     = U.covF;
    // Opaque cover: how much of the sky is behind something you cannot see blue
    // through. The three layers are not interchangeable — a stratus lid is a
    // ceiling, altostratus is a translucent sheet, cirrus is a veil you read the
    // sun straight through — so they are weighted by what they actually block,
    // and they overlap multiplicatively rather than summing past one.
    float deckF = deckOpaque(U);
    float humidF   = saturate((U.humid - 50.0f) / 50.0f);
    float aqiF     = U.aqiF, smokeF = U.smokeF;
    float skyBrAmt = U.skyBrAmt;

    float2 sunP  = astroXY(U.sunAlt,  U.sunAz,  U.facingAz, W, H);
    float2 moonP = astroXY(U.moonAlt, U.moonAz, U.facingAz, W, H);
    float  moonR = min(W, H) * 0.10f;
    float  sunDiscR = min(W, H) * 0.05f;
    bool   moonAbove = U.moonAlt > 0.0f;

    float uvNorm  = saturate(U.uv / 11.0f);
    float visNorm = clamp(U.vis / 10000.0f, 0.1f, 1.0f);
    float lightAmt = uvNorm * visNorm * (1.0f - covF * 0.7f) * skyBrAmt;
    float uvAmp   = 0.15f + saturate(U.uv / 11.0f) * 0.85f * visNorm;
    // Total cover used to be a blanket dimmer on every body: moonDim killed
    // half the moon at 100% cover, and did it again in the disc, and again in
    // starVis. Now that each layer occludes geometrically — you lose the moon
    // because a cloud is drawn across it, not because a number says so — that
    // blanket is double-counting, and it was strong enough on its own to erase
    // the moon at 55% cover with no cloud rendered anywhere near it. What is
    // left here is only the haze a covered sky genuinely adds.
    float sunDim  = 1.0f - covF * 0.25f;
    float moonDim = 1.0f - covF * 0.15f;
    float nightCloudDim = 0.38f + skyBrAmt * 0.62f;
    bool  fog = U.fogOn > 0.5f;

    // Tightened from 0.45. The glow used to BE the daylight — nothing else
    // lifted the sky — so it had to reach across half the frame at high
    // amplitude. Now that there is a real ambient term it is doing that job
    // twice, and the two together saturate: a midday sky came out as one huge
    // white wash with a thin strip of unblown blue above the sun. This is a
    // local brightening around the sun again, which is what it should be.
    float invSunR    = 1.0f / (H * 0.26f);
    float invSunRip  = 1.0f / (W * 0.75f);
    float invMoonGlow= 1.0f / (moonR * 0.8f);

    // ---- accumulate luminance L and a weighted tint (cr,cg,cb,w)
    // The base texture. The x coefficient used to be twice the y one, which
    // tilts the iso-lines steep and adds its own faint vertical striping on top
    // of the sun's rings. Near-isotropic, so it reads as mottle rather than
    // direction.
    float L = 13.0f + 9.0f * sin(x * 0.0085f + y * 0.0095f + dotPh * 0.3f);

    // subtle sweep
    float sw2 = x + y * 0.55f - fmod(sec * 10.0f, W * 1.7f) + W * 0.2f;
    float swn = sw2 / (W * 0.16f);
    L += 14.0f * fexp(-swn * swn);

    // ---- Daylight.
    //
    // The single biggest reason a daytime scene never looked like daylight.
    //
    // The base texture is a dark mottle around 13, and the only thing that ever
    // lifted it was the sun's own glow — so the half of the sky away from the
    // sun stayed at its floor and came out as dark olive-grey at nine in the
    // morning. The sky is not lit by the sun the way an object is; it IS the
    // light source, scattering across its whole dome, and on a clear day it is
    // bright from horizon to zenith.
    //
    // Overcast barely dims it — an overcast noon is a bright white sky, just a
    // flat one — so cover takes very little out here. What cover does is remove
    // colour and structure, and that happens elsewhere.
    // Brighter toward the horizon, and by a lot. Looking up you see through the
    // least air; looking toward the horizon you see through the most, and every
    // extra kilometre of it scatters more light at you. That is why a clear
    // zenith is a deep saturated blue and the horizon is pale and bright.
    //
    // Getting this into the LUMINANCE, not only the hue, is what makes the
    // zenith read as deep blue at all: taking the sky's colour while keeping a
    // flat mosaic brightness turns a dark saturated blue into a pale bright
    // one, every time.
    //
    // The amplitude was 62 against a horizon factor spanning 0.60..1.40, which
    // put the whole sky between L=50 and L=100 — the flat, dim part of the
    // luminance ramp. A clear horizon measured DARKER than the zenith once the
    // sun's own glow was discounted, which is backwards. Raised, and the
    // gradient rebalanced so the floor stays where it was and the horizon end
    // climbs into the bright part of the ramp instead.
    L += skyBrAmt * 104.0f * (0.80f + 0.20f * visNorm) * (1.0f - covF * 0.14f)
       * (0.32f + 1.24f * (cyp / H));

    // humidity haze
    if (humidF > 0.2f) L += humidF * 18.0f * sin(x * 0.008f + y * 0.01f + sec * 0.05f);

    float cr = 0.0f, cg = 0.0f, cb = 0.0f, w = 0.0f;

    // breather light pockets
    for (int bi = 0; bi < 3; ++bi) {
        if (bi > 1 && lightAmt < 0.3f) continue;
        constant Breather &B = breathers[bi];
        float bpx = B.ax + sin(sec * B.s1 + B.ph)        * W * 0.08f;
        float bpy = B.ay + cos(sec * B.s2 + B.ph * 1.3f) * H * 0.06f;
        float bpr = B.R * (0.6f + lightAmt * 0.6f);
        float bpp = powr(0.5f + 0.5f * sin(sec * 6.2832f / B.per + B.ph2), 2.2f) * lightAmt * 0.8f;
        float gx = x - bpx, gy = y - bpy;
        float gd2 = gx * gx + gy * gy;
        float thresh = bpr * 2.2f;
        if (gd2 < thresh * thresh) {
            float g2 = fexp(-sqrt(gd2) / bpr) * bpp;
            L += g2 * (skyBrAmt > 0.5f ? 120.0f : 100.0f);
            float ww2 = min(0.6f, g2 * 0.8f);
            // `ww2 > w` alone is a gate that is always true: nothing has written
            // a colour yet, so w is exactly 0 and ANY pocket, however faint,
            // takes the cell outright — and it takes it at full strength,
            // because this is an assignment and not a blend. At night `lightAmt`
            // collapses to a fraction of a per cent, so these were painting
            // near-white (248,250,255) into cells at a weight of 0.003; the deck
            // then blended only 39% of the way back, leaving hard-edged white
            // discs — the pocket's own circular cutoff — hanging in an overcast
            // midnight sky. A pocket has to be worth something to be seen.
            if (ww2 > w && ww2 > 0.02f) { w = ww2; cr = 248.0f; cg = 250.0f; cb = 255.0f; }
        }
    }

    // ---- DEPTH.
    //
    // Everything in the sky sits at a real altitude, and what is nearer hides
    // what is further. The compositing used to be winner-takes-all — the
    // brightest contributor for a cell replaced everything else — and the moon
    // set the maximum weight, so nothing could ever be drawn in front of it.
    // That is why it looked pasted onto the sky rather than sitting in it.
    //
    // Cloud opacity is therefore computed FIRST, per layer, so the bodies
    // behind it can be attenuated by exactly what is in the way. Order, far to
    // near: stars, moon and sun -> high cirrus -> mid -> low deck -> falling
    // rain -> water on the pane.

    float yFrac = cyp / H;

    // High cirrus: thin ice, stretched along the wind.
    float highAmt = 0.0f;
    if (U.cloudHigh > 0.02f) {
        float veil = saturate(1.4f - yFrac * 1.3f);
        float fib = 0.5f
                  + 0.30f * sin(cyp * 0.0102f + cxp * 0.0016f + sec * 0.010f)
                  + 0.22f * sin(cyp * 0.0223f - cxp * 0.0011f + sec * 0.016f + 1.7f)
                  + 0.14f * sin(cyp * 0.0407f + cxp * 0.0024f - sec * 0.007f + 4.1f);
        highAmt = saturate(fib * U.cloudHigh * veil * 1.25f - 0.18f);
    }

    // Mid deck: banded, moderately opaque.
    float midAmt = 0.0f, midN = 0.5f;
    if (U.cloudMid > 0.02f) {
        float band = saturate(1.15f - abs(yFrac - 0.28f) * 2.2f);
        // Banded ALONG the wind, like the cirrus above it — mid-level cloud
        // forms in horizontal sheets and rolls, and the sheets lie flat.
        // These frequencies were the wrong way round, with x varying 1.6x
        // faster than y, which stands the bands on end: that is the vertical
        // striping across the sky, and it is why it shows on a cloudy day and
        // not a clear one.
        midN = 0.5f + 0.32f * sin(cyp * 0.0121f - cxp * 0.0048f + sec * 0.020f)
                    + 0.20f * sin(cyp * 0.0244f + cxp * 0.0032f + sec * 0.013f + 2.6f);
        midAmt = saturate(midN * U.cloudMid * band * 1.35f - 0.22f);
    }

    // Low deck: the dense lid hanging from the top.
    //
    // The underside of a deck is a ragged fringe several hundred metres deep,
    // not a plane. This used to fade with `1 - y/eY` and stop dead at `y < eY`,
    // which scales the whole transition by the deck's OWN depth: a column two
    // cells deep fell from full opacity to nothing inside one cell, while the
    // column beside it at ten cells faded over four. Neighbouring columns
    // therefore never lined up, and since the cut was also quantised to whole
    // cells the boundary came out as the hard cell-stepped line across every
    // daylight frame.
    //
    // Now the fade is a FIXED band centred on the nominal edge — three cells or
    // 7% of the frame, whichever is larger — so every column feathers over the
    // same distance and adjacent transitions overlap into a soft fringe. It is
    // also allowed to continue BELOW eY, which is what removes the cut.
    float lowAmt = 0.0f, lowD2 = 0.0f, lowK = 0.0f, lowThick = 0.0f;
    float eY = edgeArr[ix];
    float lowFeather = max(H * 0.07f, SPv.y * 3.0f);
    if (eY > 0.0f) {
        lowK = saturate(0.5f + (eY - cyp) / (2.0f * lowFeather));
        lowK = lowK * lowK * (3.0f - 2.0f * lowK);
        // Depth into the deck, 1 at the solid top and falling through the
        // fringe. Drives the shading below, so the deck still lightens toward
        // its edge rather than being a slab of one tone.
        //
        // Measured over a FIXED distance above the edge, for the same reason
        // `lowK` is: `1 - cyp / (eY + feather)` normalised by the deck's OWN
        // extent, so it reported "thinning" purely because the frame ran out.
        // Under a closed deck — eY well past the bottom of the frame — it fell
        // from 1 at the top to about 0.25 at the bottom, which put a two-to-one
        // brightness ramp and a matching opacity ramp down a lid that should be
        // uniform. The posterizer then turned that smooth ramp into a hard
        // scalloped contour across the middle of the frame, so a total overcast
        // still looked like a deck that stopped halfway. A closed deck is now
        // flat, and only a real fringe thins.
        lowD2 = saturate((eY - cyp) / (4.0f * lowFeather));
        // How much cloud is THERE, and how brightly it is painted, are two
        // different quantities and only the second is a function of the hour.
        //
        // Density is the LOW layer's own, not total cover. Keyed off `covF` this
        // read a sky of pure cirrus as a solid deck — the layer split exists
        // precisely so those two do not look alike.
        lowThick = lowK * (0.45f + 0.55f * lowD2) * min(1.0f, 0.35f + U.cloudLow);
        lowAmt   = lowThick * nightCloudDim;
    }

    // How much of a body behind the cloud survives. Ice is thin and lets most
    // light through; a low deck is opaque and does not. This is what makes the
    // moon dim as cloud crosses it instead of punching through.
    //
    // The deck enters by its THICKNESS, not by the dimmed amount it is painted
    // with. `nightCloudDim` takes a night deck down to 38% — correct for its
    // colour, since an unlit cloud is dark, and completely wrong for what it
    // hides: a cloud at midnight is exactly as opaque as the same cloud at
    // noon. Occluding by the dimmed value meant a hundred per cent overcast at
    // night still transmitted three quarters of the moon, so the wallpaper
    // showed a blazing fully-detailed disc in a solidly covered sky — the moon
    // asserting itself regardless of what was in front of it.
    float occlusion = saturate(1.0f - (1.0f - highAmt  * 0.22f)
                                    * (1.0f - midAmt   * 0.78f)
                                    * (1.0f - lowThick * 0.97f));
    float seeThrough = 1.0f - occlusion;

    // Light that DOES get through scatters inside the cloud rather than
    // vanishing — the halo you see when the moon is behind thin cloud. Strong
    // through cirrus, almost nothing through a thick deck.
    float scatter = highAmt * 0.85f + midAmt * 0.35f + lowAmt * 0.06f;

    // sun — visible while above, or just below, the horizon
    if (sAlt > -1.5f) {
        float sunV = saturate((sAlt + 1.5f) / 3.0f);
        float dx = cxp - sunP.x, dy = cyp - sunP.y, d = sqrt(dx * dx + dy * dy);
        // How much of the sun gets past what is in front of it.
        //
        // NOT linear in transmission, which is what this used to be and what
        // put a bright patch over a solid deck: at 30% transmission a linear
        // law still hands over 30% of a very bright glow, and 30% of very
        // bright against a dark overcast is a glowing hole in the cloud.
        //
        // Thin cloud does the opposite. A strong sun behind a broken low deck
        // genuinely does outshine it — the rays come through harder than the
        // cover alone suggests, which is why a bright day with scattered cloud
        // looks brilliant rather than merely averaged.
        //
        // So: a gamma that collapses the tail, plus a punch-through that grows
        // with how strong the sun actually is and with how much is getting
        // past. Dense cloud takes it to nothing; thin cloud lets it flare.
        float punch = powr(seeThrough, 2.2f) * (1.0f + uvNorm * 1.4f * seeThrough);
        float glow = fexp(-d * invSunR) * uvAmp * sunDim * sunV * punch;
        float ripSpeed = 0.15f + saturate(U.uv / 11.0f) * 0.25f;
        // The solar ripple — concentric arcs radiating from the sun. Wanted,
        // and deliberately at this wavelength: it is the shimmer, not the
        // banding. (I flattened it once looking for the vertical striping and
        // it was the wrong term entirely; that one is the mid-cloud sheet.)
        // The ripple has to reach exactly ZERO through a closed deck, not merely
        // become small. You can see where the sun is behind an overcast; you
        // cannot see it shimmer. Scaled by plain `seeThrough` it survived a 97%
        // occluding deck at about half a luminance unit — which sounds like
        // nothing, and is not, because `posterQ` is 16 by day and contouring is
        // scale-free: an arbitrarily faint periodic signal still decides which
        // side of a quantisation step each cell falls on, and draws its own
        // iso-surfaces as hard concentric arcs. In colour, too, since the three
        // channels cross their steps at different radii. That is the ringed
        // olive-and-teal target a flat overcast was wearing. Fading to zero at
        // a fifth transmission removes the signal instead of shrinking it.
        // Clear sky is untouched: seeThrough is 1 there and so is `ripVis`.
        float ripVis = saturate((seeThrough - 0.18f) / 0.32f);
        float rip = sin(d * 0.03f - sec * ripSpeed) * fexp(-d * invSunRip)
                  * uvAmp * sunDim * sunV * ripVis;
        L += glow * 58.0f + (rip > 0.0f ? rip * 46.0f : 0.0f);
        float3 sc = sunTint(sAlt, aqiF);
        float ww = min(1.0f, (glow * 1.6f + (rip > 0.0f ? rip * 0.5f : 0.0f)) * sunDim);
        // Same significance floor as the light pockets, and for the same reason:
        // `ww > w` is not a real test when nothing has written yet. Both `glow`
        // and `rip` already carry `seeThrough`, so under a closed deck they come
        // out around a per cent — but the ASSIGNMENT does not care, and it was
        // stamping full-strength sun tint (255, 250, 195) across the whole
        // ripple. Against a neutral overcast grey a one per cent hue shift is
        // the most visible thing in the frame, which is why a flat lid was
        // wearing concentric olive-and-teal arcs. The ripple still shows through
        // thin cloud, where it is real, and nothing changes on a clear sky.
        if (ww > w && ww > 0.02f) { w = ww; cr = sc.r; cg = sc.g; cb = sc.b; }
        // solar disc: round core, soft falloff, weight kept under thick-cloud
        // max so clouds still pass in front of it
        if (d < sunDiscR * 1.7f) {
            float c = max(0.0f, 1.0f - d / (sunDiscR * 1.7f));
            float diskI = c * c;
            if (diskI > 0.03f) {
                // Dim the disc by cloud, not just its glow. The reference
                // applies sunDim to the halo but leaves the disc at a flat
                // 150+ luminance, so a blazing sun punches through a hundred
                // per cent overcast while it is raining. Cover has to bite
                // harder here than elsewhere, because a disc reads as "sunny"
                // even at fairly low weight.
                // Cover dims it, and whatever cloud is actually in front of
                // this cell hides it. The disc is what reads as "sunny", so it
                // has to obey both.
                float discDim = 1.0f - U.covF * 0.30f;
                L = max(L, (150.0f + diskI * 120.0f) * discDim * seeThrough);
                float ww3 = diskI * 0.82f * sunV * discDim;
                if (ww3 > w) { w = ww3; cr = sc.r; cg = min(255.0f, sc.g + 16.0f); cb = min(255.0f, sc.b + 30.0f); }
            }
        }
    }

    // stars + moon, from civil twilight onward
    if (sAlt < 0.0f) {
        float starVis = seeThrough * seeThrough
                      * max(0.0f, (-sAlt - 6.0f) / 14.0f) * (1.0f - aqiF * 0.55f);
        if (starVis > 0.02f) {
            for (int si = 0; si < U.starCount; ++si) {
                float2 sp;
                if (!starXY(stars[si], U.facingAz, W, H, sp)) continue;
                float ddx = (cxp - sp.x) / SP, ddy = (cyp - sp.y) / SP;
                if (abs(ddx) < 1.4f && abs(ddy) < 1.4f) {
                    float twinkle = 1.0f + 0.07f * sin(sec * 1.5f + dotPh * 3.14f);
                    L += starVis * stars[si].br * 55.0f * twinkle * seeThrough
                       * max(0.0f, 1.0f - sqrt(ddx * ddx + ddy * ddy));
                }
            }
        }
        float mx = cxp - moonP.x, my = cyp - moonP.y;
        float md2 = mx * mx + my * my;
        if (md2 < moonR * moonR && moonAbove) {
            // The coarse cells own the moon's SHAPE — this is what gives it a
            // chunky mosaic limb rather than a smooth circle. The detail pass
            // never extends past what is drawn here; it only refines inside it.
            //
            // Albedo is sampled at the cell centre so the cell already carries
            // the right average brightness. Note the tint has to be scaled
            // here, not L: at w = 1 the blend below is a straight assignment
            // and would throw any luminance away, which is what made every
            // moon cell come out the same flat white.
            float v = moonSample(mx / moonR, my / moonR);
            float k = saturate(moonLitRef(U.moonIllum, moonDim) * v / 255.0f);

            // ---- The phase is SUBTRACTED from the face, not cut out of it.
            //
            // This used to be a hard per-cell boolean: lit cells got the moon,
            // unlit cells got (26,30,42) at w = 1. Two things went wrong with
            // that, and both are visible at a glance.
            //
            // A near-black colour asserted at FULL weight over a lavender night
            // sky does not read as the shaded part of a sphere — it reads as a
            // hole punched through the disc. The moon stopped being one object.
            //
            // And a boolean quantises the terminator to whole cells. A circle
            // quantised to cells still reads as round, because it is convex and
            // every step is small; a near-straight terminator quantised the
            // same way is a ragged staircase. So the limb looked deliberate and
            // the terminator looked broken, in the same shape.
            //
            // Instead: the outer boundary is left exactly alone — the full disc,
            // every cell inside it — and the phase is a coverage fraction
            // subtracted across it. `litF` is how much of THIS cell falls on the
            // lit side, so the terminator crosses a cell rather than landing
            // between two, and the unlit side keeps a low weight so it stays a
            // shaded part of the moon instead of a gap in it.
            float sdCell = litDist(mx, my, moonR, U.moonPhase);
            float litF = saturate(0.5f + sdCell / max(SP, 1.0f));

            // Earthshine: sunlight off the Earth onto the moon's dark side. Real,
            // and faint — visible as a dim complete disc, never as black.
            //
            // Raised from (14 + 16*dim). At 14 the shaded third of a gibbous
            // moon landed within a couple of levels of the night sky around it,
            // so it disappeared into it and what was left was the lit part
            // alone: a tall sliver bounded by the terminator on one side and the
            // limb on the other, which is why the moon read as a column and not
            // as a disc. The disc has to be COMPLETE for the round limb to be
            // the outline the eye picks up; the phase then divides a shape that
            // is already there. Still a quarter of the lit face, so it reads as
            // the far side of a sphere rather than as a flat grey coin.
            float earth = moonEarthRef(U.moonIllum, moonDim);

            // ---- The moon is BEHIND the cloud, so it contributes a FRACTION of
            // this cell — it is not a full-strength disc that is dimmed and then
            // painted over as well.
            //
            // It used to be both. The disc was scaled by seeThrough here and the
            // cloud layers then composited over the result, and the two do not
            // compose: under a solid deck seeThrough drove the colour to (0,0,0)
            // while the weight stayed at 1, so the moon became a BLACK HOLE in
            // the shape of the moon, and since the night deck only paints at
            // about a third of an alpha, most of that hole survived it. The moon
            // was still winning — just in the opposite direction.
            //
            // Weighting instead means seeThrough = 0 leaves the cell exactly as
            // the sky drew it, and a deck hides the moon by covering nothing at
            // all. Between the two the disc fades out through the cloud, which
            // is what a moon behind thinning cloud actually does.
            float mw = mix(0.42f, 1.0f, litF) * seeThrough;
            float mL = mix(earth, 255.0f * k, litF);
            if (mw > w) {
                w  = mw;
                cr = mix(106.0f, 236.0f * k, litF);
                cg = mix(112.0f, 240.0f * k, litF);
                cb = mix(136.0f, 252.0f * k, litF);
            }
            L = mix(L, max(L, mL), seeThrough);
        } else if (moonAbove) {
            // Halo. Through clear air it is a tight ring about one radius wide.
            // Through cloud it is not a ring at all — the medium spreads it over
            // several radii, and how far depends on how much medium there is.
            // A fixed annulus is part of what made the moon read as a decal.
            float lit   = max(0.15f, U.moonIllum / 100.0f);
            float reach  = 2.6f + scatter * 3.2f;
            if (md2 < moonR * moonR * reach * reach) {
                float dm = sqrt(md2);
                float t  = (dm - moonR) / (moonR * (reach - 1.0f));   // 0 at limb, 1 at edge
                float fall = 1.0f / (1.0f + t * 5.0f * 4.0f) - 1.0f / 21.0f;   // inverse, zeroed at t=1
                fall = max(0.0f, fall) * 1.05f;
                float amp = (16.0f + 62.0f * lit) * moonDim;
                L += amp * fall * (seeThrough + scatter * 1.8f);

                // Contrast socket. Just past the glow the sky is pulled down a
                // little. Nothing in the sky actually darkens near the moon —
                // but the eye adapts to the bright source and reads the
                // surround as darker, and reproducing that is the difference
                // between an object sitting IN the sky and one pasted ON it.
                float ring = max(0.0f, 1.0f - abs(t - 0.72f) / 0.28f);
                L -= ring * ring * 9.0f * lit * seeThrough;
            }
        }
    }

    // ---- rainbow. The physics is in the block above spectrumRGB.
    //
    // Drawn HERE, after the bodies and before the cloud, because that is where
    // it is: the bow is painted on the rain curtain, which is nearer than the
    // sun that lights it and further than any cloud drifting across the front
    // of it. The layers below composite OVER it, so a deck hides it exactly as
    // it hides the moon, and `seeThrough` dims whatever is left.
    //
    // The whole figure is drawn in this pass, at cell resolution, so it is made
    // of the same quantised blocks as everything else and its height goes into
    // the relief field like any other bright feature. presentPass only refines
    // the hue INSIDE the cells this pass has already claimed.
    if (bowLiquid(U) && sAlt > 0.0f) {
        float lit   = bowLit(U, deckF, sunDim, seeThrough);
        float vivid = bowVivid(U);
        if (lit > 0.01f) {
            float2 cp = float2(cxp, cyp);
            Bow b = bowAt(bowTheta(cp, U), bowFootprint(cp, U, 1.0f), vivid, lit);
            L *= b.gain;
            if (b.amt > 0.004f) {
                L  += b.lum;
                cr += (b.col.r * 255.0f - cr) * b.amt;
                cg += (b.col.g * 255.0f - cg) * b.amt;
                cb += (b.col.b * 255.0f - cb) * b.amt;
                w = w + (1.0f - w) * b.amt;
            }
        }
    }

    // ---- cloud, by altitude.
    //
    // A single cover number cannot tell 93% high cirrus from 93% low overcast,
    // and they look nothing alike — the first is a bright luminous veil, the
    // second a dark lid.
    //
    // The opacities were computed up top, before the bodies, so the bodies
    // could be dimmed by them. Here they are painted, and each layer is laid
    // OVER what is already accumulated rather than competing with it for a
    // single winning weight. That is the whole difference: a max() picks one
    // contributor and throws the rest away, so a moon at weight 1.0 could never
    // be covered no matter what was in front of it. `over` lets near things
    // hide far ones by exactly their own opacity, which is what depth is.

    // How close this cell is to each body, used for the light a cloud picks up
    // from something shining through it from behind.
    float mgx = cxp - moonP.x, mgy = cyp - moonP.y;
    float moonProx = moonAbove
        ? fexp(-sqrt(mgx * mgx + mgy * mgy) / (moonR * 2.1f))
          * max(0.15f, U.moonIllum / 100.0f) * (1.0f - skyBrAmt * 0.65f)
        : 0.0f;
    float sgx = cxp - sunP.x, sgy = cyp - sunP.y;
    float sunProx = (sAlt > -5.0f)
        ? fexp(-sqrt(sgx * sgx + sgy * sgy) / (H * 0.34f)) * sunDim
        : 0.0f;

    // How much light a body behind the cloud puts INTO it. Two different laws,
    // because two different kinds of cloud:
    //
    //   translucent (ice, thin water) — the sheet is a diffuser. More cloud
    //       means more medium to scatter in, so the glow rises with opacity.
    //       This is the wide soft blob a moon makes behind cirrus.
    //   opaque (the deck) — light only gets through the ragged fringe, so the
    //       glow peaks at half cover and dies in the solid core. This is the
    //       silver lining.
    //
    // Using the fringe law for everything is what made the moon vanish behind
    // cirrus: the cloud directly over it was at full opacity, so it got no
    // glow at all.
    float bodyLight = moonProx * 1.0f + sunProx * 1.25f;

    // High: thin, bright, fibrous. Adds light rather than removing it, and
    // stretches into streaks because that is what ice cloud does in shear.
    if (highAmt > 0.0f) {
        // Cirrus is lit from within: it brightens and mildly desaturates the
        // sky, never darkens it.
        float rim = highAmt * bodyLight;                            // diffuser law
        L += highAmt * (28.0f + 34.0f * skyBrAmt) + rim * 96.0f;
        float3 hc = mix(float3(186.0f, 198.0f, 220.0f),
                        float3(236.0f, 242.0f, 252.0f), saturate(skyBrAmt + rim));
        float a = highAmt * 0.42f;
        cr += (hc.r - cr) * a; cg += (hc.g - cg) * a; cb += (hc.b - cb) * a;
        w = w + (1.0f - w) * a;
    }

    // Mid: banded, moderate opacity, structure without a hard edge.
    if (midAmt > 0.0f) {
        float rim = midAmt * (1.0f - midAmt * 0.55f) * bodyLight;   // part way between
        // Recentred on 1.0 for the same reason as the low deck below: a mottle
        // whose mean is 0.93 is a 7% dimming wearing a texture's clothes.
        float shade = min(210.0f, U.cbase * (0.85f + 0.30f * midN) + rim * 90.0f);
        float3 mc = cloudTint(sAlt, 0.55f + rim * 0.45f, shade);
        L += midAmt * (skyBrAmt > 0.5f ? 26.0f : 6.0f) + rim * 62.0f;
        float a = midAmt * 0.72f;
        cr += (mc.r - cr) * a; cg += (mc.g - cg) * a; cb += (mc.b - cb) * a;
        w = w + (1.0f - w) * a;
    }

    // Low: the dense deck hanging from the top.
    if (lowAmt > 0.0f) {
        // Where the SUN is putting light on the deck. This had no altitude gate
        // at all — unlike `sunProx` eight lines up, which stops at -5 degrees —
        // so at midnight, with the sun forty degrees under the floor, its screen
        // position still sat just off the frame and lit a broad patch of cloud
        // from below it. Under a closed deck that patch is the whole difference
        // between a lit corner and a dark one, and the posterizer turns it into
        // a hard-edged lobe. A deck at night is lit by the moon and the city, and
        // by nothing else.
        float light = fexp(-sqrt(sgx * sgx + sgy * sgy) / (H * 0.5f))
                    * saturate((sAlt + 7.0f) / 11.0f);
        // The deck is thick, so only its ragged lower fringe transmits.
        float rim = 4.0f * lowAmt * (1.0f - lowAmt) * bodyLight * 0.55f;  // fringe law
        // Body tone of the deck. The solid part used to sit at 0.55 of `cbase`
        // and only the fringe reached 1.0, which was survivable while the deck
        // was a shallow strip along the top but is not once it can close: a
        // hundred per cent overcast at noon came out as a dark slate ceiling,
        // when `cbase` is exactly the quantity that already encodes how much
        // light is getting through the deck at this hour. So the solid tone now
        // sits near `cbase` itself and the fringe is a modest lift on top.
        //
        // The deck also needs a mottle of its own. Every other layer has one —
        // `midN` for the mid sheet, `fib` for the cirrus — and the low deck had
        // none at all: it was `cbase` times two smooth radial falloffs, i.e.
        // paint. That went unnoticed while the deck was a strip along the top of
        // a blue sky. Once it can close, the whole frame is that one smooth
        // field, and the posterizer quantises a smooth field into contour rings
        // — concentric arcs around the sun, with coloured fringes where the
        // three channels cross their steps at different radii. Overcast IS flat,
        // but it is not featureless at this scale, and the little that is there
        // is what breaks the contours up.
        float lowN = 0.5f + 0.30f * sin(cxp * 0.0061f + cyp * 0.0113f + sec * 0.011f)
                          + 0.20f * sin(cxp * 0.0134f - cyp * 0.0072f - sec * 0.008f + 2.3f);
        // THE SAME DOUBLE-COUNT AGAIN, and this one was worth 25% of the whole
        // frame. `(0.75 + 0.55 * light)` is inherited verbatim from
        // roomstand.py:2643, where it was correct: there the deck was a STRIP
        // along the top of the frame, `light` was the sun's lobe on it, and 0.75
        // was the shaded floor of a band with open sky underneath. Here the deck
        // can CLOSE over the whole picture, and then `light` is ~0 across nearly
        // all of it — so the floor stopped being the shading of a band and
        // became a flat 25% dimming of everything, applied on top of `cbase`,
        // which is already exactly "how much light is getting through the deck
        // at this hour". The attenuation was counted twice and a hundred per
        // cent overcast at noon painted at 0.70 x cbase: 119 against a cbase of
        // 170, i.e. below mid grey at midday.
        //
        // So the sun's term is a LIFT rather than a floor — unity away from it,
        // brighter toward it, which is the shape the Pi actually wanted — and
        // both mottles are recentred on 1.0 instead of 0.93, since a texture is
        // meant to vary the tone, not to quietly lower it.
        float shade = min(235.0f, U.cbase * (0.85f + 0.30f * (1.0f - lowD2))
                                * (1.0f + 0.42f * light)
                                * (0.85f + 0.30f * lowN) + rim * 70.0f);
        float3 cc = cloudTint(sAlt, light + rim, shade);
        L += lowAmt * (skyBrAmt > 0.5f ? 55.0f : 12.0f) + rim * 26.0f;
        float a = lowAmt * 0.97f;
        cr += (cc.r - cr) * a; cg += (cc.g - cg) * a; cb += (cc.b - cb) * a;
        w = w + (1.0f - w) * a;
    }

    // Under the deck: shadow, and the diffuse light the deck itself throws down.
    //
    // Both are needed and neither works alone. Shadow alone, subtractive, drove
    // a fully overcast three-in-the-afternoon to solid black — nothing else
    // contributes below the deck edge on a covered day, so L sat near its floor
    // of 13 and a flat -30 buried it. Multiplying instead makes the shadow
    // proportional to whatever light is actually there, so it can darken but
    // never bottom out.
    //
    // The lift is the other half: a daytime deck is a huge diffuse source, and
    // the space beneath it is bright grey, not dark. That light has to come from
    // somewhere, and the deck is what it comes from.
    if (eY > 0.0f && cyp > eY - lowFeather && U.cloudLow > 0.15f) {
        // Ramps in as the deck ramps out (1 - lowK), instead of switching on at
        // the old hard `y >= eY` cut — which was the same staircase seen from
        // the other side, as a step in the light thrown down.
        float under = saturate(1.0f - (cyp - eY) / (H * 0.30f)) * (1.0f - lowK);
        // Deepened, and the lift below cut back, by how much light the deck is
        // actually taking out. `gloomF` rises before the first drop falls and
        // lingers after the last, and it rises again for a MEASURED low cloud
        // base — so the space under a 200m ceiling goes properly dim while the
        // same cover at 3km stays the bright grey it should be. Bounded on
        // purpose: `cbase` remains the authority on the deck's own tone.
        L *= 1.0f - under * under * (0.20f + 0.26f * U.gloomF) * U.cloudLow;
        // Scaled WITH `under`, which is 1 at the deck's edge and falls to 0
        // away from it. It was `(26 + 30 * (1 - under))` — maximal where
        // `under` is zero, so the further a cell sat from the deck the more
        // light the deck threw on it. That inverted falloff flooded the whole
        // lower frame with a flat achromatic lift and is what turned the bottom
        // two thirds of a daytime sky into featureless grey.
        L += U.cloudLow * skyBrAmt * 34.0f * under * (1.0f - 0.50f * U.gloomF);
    }

    // rain / snow, sampled from the rasterised grid. Streaks lean with the
    // wind, so this cannot be a per-column lookup any more.
    //
    // Falling water is the nearest thing in the sky — nearer than any cloud —
    // so it composites over everything above, and it catches the light of a
    // body behind it the same way cloud does. A streak crossing the moon is a
    // bright thread; the same streak away from it is a dim one.
    {
        constexpr sampler ns(coord::pixel, filter::nearest, address::clamp_to_edge);
        float kx = streaks2.sample(ns, float2(float(ix) + 0.5f, float(iy) + 0.5f)).r;
        if (kx > 0.01f) {
            float lit = 1.0f + bodyLight * 1.6f;

            // What is falling, not what category the hour is in. `U.kind == 4`
            // could only ever say snow-or-not, so drizzle, freezing rain, ice
            // pellets, graupel and hail were all drawn as the same blue-grey
            // line at the same brightness — five different substances wearing
            // one costume. Drizzle in particular has to be nearly invisible
            // individually and read as a haze in aggregate, which is what a
            // low stratus deck actually delivers.
            float pf = U.pform;
            float bright = 85.0f;                        // rain
            float3 rc = float3(150.0f, 200.0f, 255.0f);
            float alpha = 0.75f;
            if (pf > 0.5f && pf < 1.5f) {                // drizzle: fine, floating
                bright = 32.0f; rc = float3(176.0f, 194.0f, 214.0f); alpha = 0.38f;
            } else if (pf > 2.5f && pf < 3.5f) {         // freezing rain: glassy
                bright = 96.0f; rc = float3(198.0f, 222.0f, 255.0f); alpha = 0.80f;
            } else if (pf > 3.5f && pf < 4.5f) {         // ice pellets: hard, compact
                bright = 105.0f; rc = float3(226.0f, 238.0f, 252.0f); alpha = 0.86f;
            } else if (pf > 4.5f && pf < 6.5f) {         // snow / snow grains
                bright = 70.0f; rc = float3(240.0f, 246.0f, 255.0f); alpha = 0.80f;
            } else if (pf > 6.5f && pf < 7.5f) {         // graupel: opaque pellets
                bright = 92.0f; rc = float3(244.0f, 248.0f, 255.0f); alpha = 0.88f;
            } else if (pf > 7.5f) {                      // hail: hard and very bright
                bright = 130.0f; rc = float3(250.0f, 252.0f, 255.0f); alpha = 0.95f;
            }

            L += kx * bright * lit;
            rc = mix(rc, float3(252.0f, 250.0f, 245.0f), saturate(bodyLight * 0.8f));
            float a = kx * alpha;
            cr += (rc.r - cr) * a; cg += (rc.g - cg) * a; cb += (rc.b - cb) * a;
            w = w + (1.0f - w) * a;
        }
    }

    // fog
    if (fog) {
        float fogD = max(0.3f, 1.0f - U.vis / 5000.0f);
        L += fogD * (40.0f * sin(y * 0.02f + sec * 0.15f) + 46.0f);
        float fw = fogD * 0.7f;
        if (fw > w) { w = fw; cr = 170.0f; cg = 175.0f; cb = 185.0f; }
    }

    // lightning bolt + flash
    for (int bi = 0; bi < U.boltCount; ++bi) {
        float qx = cxp - bolt[bi].x, qy = cyp - bolt[bi].y;
        if (qx * qx + qy * qy < SP * SP * 2.6f) { w = 1.0f; cr = 245.0f; cg = 240.0f; cb = 255.0f; L = 230.0f; break; }
    }
    if (U.flashAmp > 0.0f) L += U.flashAmp * 130.0f;

    // shooting star
    if (U.shootActive > 0.5f) {
        float a2 = (sec - U.shootT0) / 0.8f;
        float hx = U.shootX + a2 * W * 0.26f, hy = U.shootY + a2 * W * 0.26f * 0.35f;
        float qx = cxp - hx, qy = cyp - hy;
        if (qx * qx + qy * qy < SP * SP * 2.0f) L += 150.0f * sin(M_PI_F * a2);
    }

    float R0 = L, G0 = L + 4.0f, B0 = L + 11.0f;
    if (w > 0.0f) { R0 += (cr - R0) * w; G0 += (cg - G0) * w; B0 += (cb - B0) * w; }
    // How far the genuinely EMISSIVE sources pushed this cell past display
    // white, measured before the clamp throws it away. Everything that has
    // added to L above is either the sky (which lives well inside the range) or
    // one of the four things that are actually brighter than white — the solar
    // disc, the moon, a lightning flash and a shooting star. On an SDR display
    // this excess is clipped, exactly as it always was; it is spent at the end
    // of the pass, and only up to the headroom the display is granting this
    // instant. See the return.
    float overWhite = max(0.0f, max(R0, max(G0, B0)) - 255.0f);

    R0 = clamp(R0, 6.0f, 255.0f); G0 = clamp(G0, 8.0f, 255.0f); B0 = clamp(B0, 12.0f, 255.0f);
    float lum = (R0 + G0 + B0) * 0.333f;

    // ---- LUT base, sky ambient tint, weather tint, posterize
    //
    // Azimuth of this cell relative to the sun. astroXY spreads +/-95 degrees of
    // azimuth across the frame, so inverting it gives the cell's bearing, and
    // the sun's own relative bearing subtracts out. This is what lets the sky
    // put the warm band on the side the sun is actually on and the Belt of
    // Venus opposite it, instead of ringing the whole horizon with both.
    float cellRelAz = (cxp / max(W, 1.0f) - 0.5f) * 190.0f;
    float sunRelAz  = fmod(U.sunAz - U.facingAz + 540.0f, 360.0f) - 180.0f;
    float dAzSun    = cellRelAz - sunRelAz;

    // Aerosol optical depth from MEASURED visibility, via Koschmieder's law:
    // V = 3.912 / sigma_ext gives the SURFACE extinction coefficient, per km.
    //
    // Two corrections turn that into a vertical optical depth, and without them
    // this term was the single biggest reason a clear day rendered as a grey
    // wall — a noon zenith came out (74,79,93), a blue-minus-red of 19, where
    // it should be several times that.
    //
    // ---- 1. Aerosol does not fill the column.
    //
    // This used to divide by a 1 km scale height, i.e. charge the whole column
    // the surface concentration. Aerosol lives in the boundary layer and the
    // effective depth is nearer 0.6 km, so every reading was roughly double
    // what it should have been.
    //
    // ---- 2. Reported visibility is CENSORED at the top of its range.
    //
    // This is the one that actually did the damage. A METAR reports visibility
    // in statute miles and tops out at 10 — "10SM" means "ten or more", not
    // "ten" (see Observation.swift, which converts it). Model visibility fields
    // saturate a few tens of km up. So the clearest day of the year arrives
    // here as 16 km and the old formula read that saturated sensor value as a
    // measurement of haze, asserting a hazy sky whatever the air was actually
    // doing. Above the reporting ceiling the number carries almost no aerosol
    // information, so the derived load rolls off toward clean air instead of
    // continuing to scale.
    //
    // Sanity, against the range aerosol optical depth is really measured over
    // (clean continental 0.05, average clear 0.10-0.15, hazy 0.3-0.4, heavy
    // smoke 0.6+):
    //     45 km -> 0.023    24 km -> 0.044    16 km -> 0.10
    //     10 km -> 0.22      5 km -> 0.47      2 km -> 1.17
    float visKm  = clamp(U.vis, 200.0f, 60000.0f) / 1000.0f;
    float sigma  = 3.912f / visKm;                       // surface, per km
    float censored = saturate((visKm - 8.0f) / 14.0f);   // into the "or more" range
    float tauVis = clamp(sigma * 0.60f * mix(1.0f, 0.45f, censored), 0.015f, 1.3f);
    // Pollution and smoke add load of their own on top of what visibility sees.
    float tauA   = min(1.3f, tauVis + aqiF * 0.25f + smokeF * 0.9f);

    float3 sky = skyRGB(U.sunAlt, float(iy) / U.rows, dAzSun,
                        aqiF, deckF, smokeF, U.gloomF, tauA);
    float li = saturate(lum / 210.0f);
    float3 g = rampLUT(lum + U.nightBoost);

    // Shadows pick up the sky hue, brights stay neutral.
    //
    // This used to blend toward the sky COLOUR, weighted by the sky's own
    // brightness — which meant that at night, when the sky is at its most
    // colourful in relative terms, the weight collapsed to about 2% and the
    // whole scene came out as a wall of neutral grey tiles. It is the single
    // biggest reason a night scene reads as flat: with no hue anywhere, nothing
    // can separate from anything.
    //
    // So take the sky's CHROMA, not its value: normalise it to unit luminance
    // and re-light it at the cell's own brightness. The mosaic keeps its tonal
    // ramp, the sky supplies the hue, and a midnight sky is deep blue at every
    // exposure rather than blue only when it happens to be bright.
    const float3 LW = float3(0.299f, 0.587f, 0.114f);
    float skyL = max(4.0f, dot(sky, LW));
    float3 skyChroma = mix(float3(1.0f), sky / skyL, 0.96f);   // damped toward neutral
    float gl = dot(g, LW);
    // Base weight raised from 0.34: at 0.34 a bright daylight cell kept two
    // thirds of the ramp's neutral grey and only a third of the sky's hue,
    // which is why a clear noon read as pale grey-blue rather than blue.
    float tf = 0.62f + max(0.0f, 1.0f - li) * 0.30f;
    g += (skyChroma * gl - g) * tf;

    // Blend the weather tint — the colour of whatever element won this cell.
    //
    // Gated on there actually BEING an element. The old test was
    // `R0 != G0 || G0 != B0`, which is true for every cell in the scene: the
    // base is (L, L+4, L+11), never neutral, so this always fired and always
    // pulled the cell back toward that near-grey. On a clear sky, where there
    // is no element at all, it was quietly desaturating the entire frame —
    // mid-sky came out 193/207/219 when it should be a good deal bluer than
    // that. Nothing drawn means nothing to blend.
    if (w > 0.02f) {
        float sat = max(max(R0, G0), B0) - min(min(R0, G0), B0);
        float sw = min(0.97f, sat / 70.0f) * max(0.25f, li) * saturate(w * 1.6f);
        g += (float3(R0, G0, B0) - g) * sw;
    }
    if (U.flashAmp > 0.0f) {
        float fa = U.flashAmp * 0.8f;
        g += (255.0f - g) * fa;
    }
    g = round(g / U.posterQ) * U.posterQ;

    // ---- EDR. Give the clipped emissive excess back, up to the headroom the
    // display is ACTUALLY offering right now (U.edrHead, read from NSScreen
    // every frame — it moves with the brightness slider, Low Power Mode and
    // thermal state, so it cannot be assumed).
    //
    // Strictly gated on edrHead > 1. At headroom 1.0 not one instruction here
    // changes the result, so an SDR display — and the desktop wallpaper, which
    // macOS never grants EDR to at all — renders bit-identically to before.
    //
    // `lum` is deliberately NOT lifted: it is the alpha channel, and both the
    // height field and presentPass read it as a 0..1 tonal value. Relief and
    // styling must not change just because the sun is allowed to be brighter.
    float3 gOut = g;
    if (U.edrHead > 1.0f) {
        gOut += min(overWhite, 255.0f * (U.edrHead - 1.0f));
    }
    return CellOut{ float4(clamp(gOut / 255.0f, 0.0f, max(1.0f, U.edrHead)),
                           lum / 255.0f), seeThrough };
}

// ================================================================ DETAIL
// The engine's one mechanism for showing detail the coarse grid would destroy.
// Anything that needs finer resolution goes through this — the moon today,
// anything added later on the same terms.
//
// The rule is that a chunk is only broken down where the source actually
// varies across it. A cell holding one flat colour stays one cell: subdividing
// it would cost work and change nothing, and the coarse mosaic IS the look.
// Where the source does vary, depth scales with how much it varies — enough
// for the feature to become recognisable — and stops at two bounds:
//
//   affordable  a sub-cell must stay big enough to read as part of the mosaic
//   hardMax     per-feature ceiling, so nothing ever refines without limit
//
// A refined cell is still a mosaic cell. It goes through the same styleCell()
// as every other one, so each theme keeps its own character all the way down.
// Crucially the split never changes an object's SHAPE — which cells belong to
// a feature is decided at coarse resolution; this only redistributes detail
// inside them.

struct DetailCell {
    float  size;    // representative edge length in pixels (for thresholds)
    float2 sizev;   // actual pitch per axis — the two differ by well under 1%
    float2 uv;      // 0..1 within the cell
    float2 id;      // integer grid id at this depth
    int    depth;   // 1 = untouched coarse cell
};

inline DetailCell coarseCell(float2 px, float2 cid, float2 SPv) {
    DetailCell d;
    d.sizev = SPv;
    d.size  = min(SPv.x, SPv.y);
    d.uv    = px / SPv - cid;
    d.id    = cid;
    d.depth = 1;
    return d;
}

inline DetailCell splitCell(float2 px, float2 SPv, int depth) {
    DetailCell d;
    d.sizev = SPv / float(depth);
    d.size  = min(d.sizev.x, d.sizev.y);
    d.id    = floor(px / d.sizev);
    d.uv    = px / d.sizev - d.id;
    d.depth = depth;
    return d;
}

/// How far to break a cell down, from how much the source varies across it.
/// Returns 1 to leave it whole.
inline int detailDepth(float contrast, float thresh, float SP, float minSubPx, int hardMax) {
    if (contrast < thresh) return 1;                       // flat: leave it alone
    int affordable = int(floor(SP / minSubPx));            // still visible
    if (affordable < 2) return 1;
    int wanted = 1 + int(round(contrast * 5.0f));          // scales with detail
    return clamp(wanted, 2, min(affordable, hardMax));
}

// ================================================================ RELIEF
// The mosaic is a WALL OF BLOCKS, not a grid of tinted squares.
//
// Every cell is a square column extruded toward the viewer by a height taken
// from its own luminance, so the scene's content — a cloud deck, the moon, a
// streak of rain — physically embosses the wall instead of merely colouring it.
// Three things make that read as geometry rather than as a bevel:
//
//   parallax    a cell off the frame centre is seen from an angle, so its base
//               is displaced from its top and you see its SIDE. The lean grows
//               with distance from centre, exactly as it does looking at a real
//               wall, and it is what stops the effect reading as a gradient.
//   flanks      the side faces are shaded from wherever the light actually is —
//               the sun, or the moon at night, at the screen position the scene
//               already draws it at — so one side of every proud block is
//               bright and the opposite side dark, and which side that is
//               sweeps around as the day goes by.
//   contact     where a block sits below its neighbour the crevice between them
//               darkens. That is occlusion, not a darker fill.
//
// It is solved by RAYCASTING the height field rather than approximating it.
// Blocks are constant-height columns on a unit grid, so the exact intersection
// is a 2D DDA: one step per cell boundary the ray crosses.
//
// The loop bound is not a guess. The camera sits RELIEF_CAMD screen-widths
// away and the lean is normalised by the LONGER axis, so at the frame corner
// |lean.x| + |lean.y| <= (cols + rows) / (2 * RELIEF_CAMD * max(cols, rows)),
// which is 1.61 for a square grid and ~1.31 for a 16:10 one. Multiplied by the
// deepest layer, RELIEF_MAX = 2 pitches, that is at most 3.2 boundary crossings
// — four cells visited — so RELIEF_STEPS = 6 covers the very worst pixel of the
// deepest setting with a step to spare. Every other pixel breaks far sooner:
// the whole middle of the frame barely leans at all and finishes on the first
// or second iteration. There is no unbounded march here.
//
// RELIEF_MAX is why the effect reads as blocks rather than as a bevel. A flank
// is only as wide as lean * (this block's height - its neighbour's), and the
// sky is a SMOOTH field: neighbouring cells differ by a few percent of the
// range, so a layer under a pitch deep put every side face below a pixel and
// the wall collapsed back into the tiles-with-a-rim look this replaces. At two
// pitches the default depth of 0.5 makes a block exactly as deep as it is wide
// — a cube — and the flanks are finally something you can see.
//
// Every quantity below is in CELL PITCHES, in both axes and in height.

constant float RELIEF_MAX   = 2.00f;   // tallest block, in cell pitches
constant float RELIEF_CAMD  = 0.62f;   // camera distance, in screen widths
constant int   RELIEF_STEPS = 6;

// ---- Edge fit.
//
// The mosaic is built to tile the display exactly: whole cells, flush against
// all four boundaries, no remainder anywhere (see the pitch note in PASS B).
// Parallax breaks that on its own. The lean is linear in the distance from the
// frame centre, so mapping a pixel to the block it actually sees is very nearly
// a ZOOM about that centre — magnifying by 1/(1 - z/D) — and a zoom pushes the
// outermost row and column off the edge of the frame. At eight rows that is
// most of a cell gone on every side: the outer ranks came out as slivers of a
// face, or as flank, which is exactly the fit the grid work was for.
//
// So the lean is damped to zero across the outermost cells and ramped back in
// behind them, per axis. Inside the flush band the ray is straight, so a pixel
// sees the block that is under it and the boundary at one cell in lands exactly
// one cell in — the edge rank is whole and flush again by construction, at any
// size and any row count.
//
// Damped rather than compensated by a counter-zoom, because a counter-zoom is
// only exact for one height: every block leans by its OWN height, so the edge
// would still be ragged wherever the outer cells happen to be tall (the moon at
// the frame edge, a lightning cell). Damping is exact for every height at once.
//
// Extending the height field a cell beyond the frame was the other candidate.
// It gives the outer blocks something to lean against, but it does not put them
// back inside the frame — the zoom still crops them — so it fixes the flank and
// not the fit. This does both: with no lean there is no flank to see.
//
// The ramp is wider than the band so the recovery is gradual; the derivative of
// the mapping stays positive everywhere (it is 1 - z*d(lean)/dg, and d(lean)/dg
// never exceeds 1/D, which is at most 0.4 at the coarsest usable grid), so the
// warp can never fold.
constant float RELIEF_EDGE  = 1.00f;   // cells held perfectly flush at each edge
constant float RELIEF_RAMP  = 1.60f;   // cells over which the lean comes back

/// Stable per-cell noise in -0.5..0.5. Used for splay; must not vary with time
/// or the whole wall shimmers.
inline float cellJit(float2 ci, float salt) {
    return fract(sin(dot(ci, float2(12.9898f, 78.233f)) + salt) * 43758.5453f) - 0.5f;
}

// ================================================================ PASS H
// The height field, one texel per cell, computed once per frame.
//
// It is its own pass for two reasons. The raycast asks for a height several
// times per pixel — up to six along the ray, four more for the contact
// occlusion — so anything more expensive than a single fetch is paid ten times
// over at full resolution. And a height worth having is not a function of one
// cell: it has to know what the cell's SURROUNDINGS are doing. At cols x rows
// that neighbourhood costs nothing at all (a 60x36 grid is 2160 fragments, four
// orders of magnitude less work than the frame it feeds).
//
// ---- What the height is FOR.
//
// Depth is emphasis, not texture. Straight luminance -> height gives every cell
// a mild extrusion proportional to how bright it happens to be, which at
// production density (36 rows) is a smooth field mapped to a smooth relief: a
// gentle swell over the whole wall and nothing that reads as an object. The sky
// IS smooth — that is what a sky is — so tone alone can never separate the moon
// from the air around it.
//
// What separates them is PROMINENCE: how far a cell stands above its own
// surroundings. A moon disc, the solar disc, a lightning cell, a lit rain
// streak are all bright AND compact — locally far above their neighbourhood. A
// sky gradient, however bright, is level with it everywhere. So the height is
// driven by the excess over the local mean, measured at two scales so that a
// feature is caught whether it is one cell across or eight:
//
//   near ring   ~1.6 cells — catches thin features and edges
//   far ring    ~4.5 cells — clears the moon disc entirely (its radius is 3.6
//               cells at any row count, since both it and the pitch scale with
//               the frame's short side), so the middle of the disc registers as
//               prominent rather than as level with itself
//
// The background keeps a reduced version of the old tonal height, so the wall
// is still a wall — bricks, not a plane — and `emphAmt` at 0 restores the old
// behaviour exactly.
constant float2 RING[8] = {
    float2( 1.0f,  0.0f), float2(-1.0f,  0.0f),
    float2( 0.0f,  1.0f), float2( 0.0f, -1.0f),
    float2( 0.707f, 0.707f), float2(-0.707f, 0.707f),
    float2( 0.707f,-0.707f), float2(-0.707f,-0.707f)
};

fragment float4 heightPass(VOut in [[stage_in]],
                           constant Uniforms &U     [[buffer(0)]],
                           texture2d<float>   cells [[texture(0)]])
{
    constexpr sampler ns(coord::pixel, filter::nearest, address::clamp_to_edge);
    float2 p = in.pos.xy;
    if (p.x >= U.cols || p.y >= U.rows) return float4(0);

    float l = saturate(cells.sample(ns, p).a);

    // Local surround at two scales.
    float m1 = 0.0f, m2 = 0.0f;
    for (int k = 0; k < 8; ++k) {
        m1 += cells.sample(ns, p + RING[k] * 1.6f).a;
        m2 += cells.sample(ns, p + RING[k] * 4.5f).a;
    }
    m1 *= 0.125f; m2 *= 0.125f;

    // How far this cell stands above its surroundings, at whichever scale sees
    // it best. Never below zero: a cell in a hollow is not pushed further in,
    // it simply has nothing to add.
    float excess = max(max(l - m1, l - m2), 0.0f);
    // 0.03 is under the cell-to-cell step of a smooth sky at 36 rows, so the sky
    // stays out of it; 0.30 is comfortably inside the moon-against-night and
    // disc-against-daylight contrasts, so those saturate.
    float prom = smoothstep(0.03f, 0.30f, excess);
    // Bright AND prominent is what should come forward. A dark speck against a
    // darker surround is prominent too, and it should not tower.
    //
    // But this must not be PROPORTIONAL to brightness, which is what it was.
    // A feature is one object at one distance, so its cells belong at one
    // height; scaling their lift by their own tone gave the moon a height map
    // of its own albedo, and at emphAsis 0.8 that is a quarter of a cell pitch
    // of step between the highlands and the maria. The disc came out of the wall
    // as a terraced heap of towers with walls between them, its silhouette
    // broken by every block leaning by a different amount — which is most of why
    // it stopped reading as a disc at all. The gate belongs at the BOTTOM of the
    // range, where the dark speck it exists to stop actually lives; above that
    // it should saturate and let the whole feature rise together.
    float emph = prom * (0.10f + 0.90f * smoothstep(0.05f, 0.32f, l));

    // The tonal height the wall had before any of this. The 0.65 exponent lifts
    // the bottom of the range: a night sky is nearly black, and a straight
    // luminance mapping would flatten the wall to nothing the moment the sun
    // set. Relief is the look; it should survive the dark.
    float base = powr(l, 0.65f);

    // Emphasis presses the background down and lets features climb the room it
    // frees. At emphAmt = 0 this is exactly `base`.
    float flat = base * mix(1.0f, 0.42f, U.emphAmt);
    float h    = flat + (1.0f - flat) * emph * U.emphAmt;

    // Splay unsettles the courses so the blocks are not a perfectly graded set.
    // It belongs here rather than at the point of use: the raycast has to see
    // ONE height per cell, and re-deriving a jitter at every fetch is both
    // wasted work and a chance for the DDA and the occlusion to disagree.
    if (U.splayAmt > 0.001f) h *= 1.0f + cellJit(floor(p), 0.0f) * U.splayAmt * 0.55f;

    return float4(saturate(h), 0.0f, 0.0f, 1.0f);
}

/// Height of one block, in cell pitches — a single fetch from PASS H.
inline float cellHeight(texture2d<float> heights, sampler s, float2 ci,
                        float cols, float rows, float hmax)
{
    float2 cc = clamp(ci, float2(0.0f), float2(cols - 1.0f, rows - 1.0f));
    return heights.sample(s, cc + 0.5f).r * hmax;
}

/// What the eye actually lands on at one pixel.
struct Relief {
    float2 g;        // grid position of the hit, in cell units
    float2 cell;     // integer id of the block that was hit
    float  h;        // that block's height
    float  z;        // height at which the ray struck it
    float2 lean;     // ray travel per unit height, outward from frame centre
    bool   flank;    // true = side face, false = top face
    int    axis;     // flank only: 0 = an x face, 1 = a y face
    float2 nrm;      // flank only: outward normal in screen axes
};

inline Relief castRelief(texture2d<float> heights, sampler s, float2 g,
                         float cols, float rows, float hmax)
{
    Relief r;
    r.g = g; r.cell = floor(g); r.h = 0.0f; r.z = 0.0f;
    r.lean = 0.0f; r.flank = false; r.axis = 0; r.nrm = 0.0f;
    if (hmax <= 0.0005f) return r;

    // The ray from the camera to this pixel's point on the back wall. At height
    // z it is at g - lean*z, so marching DOWN from the top of the block layer
    // walks outward from the frame centre. u = hmax - z is the march parameter.
    float2 ctr  = float2(cols, rows) * 0.5f;
    float2 lean = (g - ctr) / max(max(cols, rows) * RELIEF_CAMD, 1.0f);
    // Hold the frame's outermost ranks flush — see the RELIEF_EDGE note. Per
    // axis, so a cell on the left edge still leans vertically and one along the
    // top still leans sideways; only the component that would push a block out
    // of the frame is the one that is taken away.
    float2 dEdge = min(g, float2(cols, rows) - g);
    lean *= smoothstep(float2(RELIEF_EDGE), float2(RELIEF_EDGE + RELIEF_RAMP), dEdge);
    r.lean = lean;

    float2 p   = g - lean * hmax;          // where the ray enters the layer
    float2 ci  = floor(p);
    float2 stp = float2(lean.x >= 0.0f ? 1.0f : -1.0f, lean.y >= 0.0f ? 1.0f : -1.0f);
    float  ivx = (abs(lean.x) > 1e-6f) ? 1.0f / abs(lean.x) : 1e9f;
    float  ivy = (abs(lean.y) > 1e-6f) ? 1.0f / abs(lean.y) : 1e9f;
    // u at which the next boundary on each axis is reached
    float  ux  = abs((ci.x + max(stp.x, 0.0f)) - p.x) * ivx;
    float  uy  = abs((ci.y + max(stp.y, 0.0f)) - p.y) * ivy;

    float u = 0.0f, uHit = hmax, hHit = 0.0f;
    float2 cHit = ci;
    bool flank = false, done = false;
    int axis = 0;

    for (int i = 0; i < RELIEF_STEPS; ++i) {
        float z0 = hmax - u;
        float H  = cellHeight(heights, s, ci, cols, rows, hmax);
        // Entered this cell already below its top: we are looking at its side.
        // Never on the first cell — there the ray starts at the very top of the
        // layer, where the only possible contact is a full-height top face.
        if (i > 0 && H >= z0) {
            uHit = u; hHit = H; cHit = ci; flank = true; done = true; break;
        }
        float uNext = min(ux, uy);
        bool  xNext = ux <= uy;
        float uEnd  = min(uNext, hmax);
        if (H >= hmax - uEnd) {            // the ray descends onto its top face
            uHit = hmax - H; hHit = H; cHit = ci; flank = false; done = true; break;
        }
        if (uEnd >= hmax) {                // reached the back wall
            uHit = hmax; hHit = H; cHit = ci; flank = false; done = true; break;
        }
        u = uNext;
        if (xNext) { ci.x += stp.x; ux += ivx; axis = 0; }
        else       { ci.y += stp.y; uy += ivy; axis = 1; }
    }
    if (!done) { uHit = hmax; hHit = 0.0f; cHit = floor(g); flank = false; }

    r.g     = p + lean * uHit;
    r.cell  = cHit;
    r.h     = hHit;
    r.z     = hmax - uHit;
    r.flank = flank;
    r.axis  = axis;
    // The face you can see is the one pointing back toward the camera, i.e.
    // against the direction of travel.
    if (flank) r.nrm = (axis == 0) ? float2(-stp.x, 0.0f) : float2(0.0f, -stp.y);
    return r;
}

// ================================================================ PASS B
// Full-res presentation. Shape (square|dot) x finish (glass|flat), applied to
// whichever grid a pixel turns out to belong to.

/// Radius of a dot, in cell fractions. Shared by the mask and by the bead's
/// lens, which have to agree on where the glass actually is.
inline float dotRadius(float lum, float time, float phase) {
    return (0.24f + saturate(lum) * 0.46f)
         * (0.90f + 0.10f * sin(time * 0.9f + phase * 6.28f));
}

/// Draw the face of one mosaic block.
///
/// `flank` says we are on a side face rather than the front. A flank has no
/// grout, no bevel and no rim: it is the sheared wall of the block, and its
/// entire appearance comes from the relief lighting applied by the caller.
/// Drawing the front-face treatment there was what made an early version look
/// like a bevel again — the edges of the extrusion picked up their own edges.
///
/// `rot` is the splay angle for this block, in radians. It turns the face
/// outline inside the cell so a wall of blocks is not perfectly coursed.
inline float3 styleCell(float3 col, float2 cuv, float cellPx, float lum,
                        float phase, float time, int shape, int finish,
                        bool flank, float2 lightDir, float lightI, float rot,
                        float splay, float depth)
{
    if (rot != 0.0f) {
        float cs = cos(rot), sn = sin(rot);
        float2 d = cuv - 0.5f;
        cuv = 0.5f + float2(d.x * cs - d.y * sn, d.x * sn + d.y * cs);
    }
    if (shape == 1) {
        // ---- dots: SDF circle, radius from cell luminance (roomstand.py:2587)
        float ln = saturate(lum);
        float dotR = dotRadius(lum, time, phase);
        float d = length(cuv - 0.5f);
        float aa = 0.5f / cellPx;                 // half-pixel feather, no aliasing
        float m = 1.0f - smoothstep(dotR - aa, dotR + aa, d);

        if (finish == 0) {
            // ---- A glass dot is a BEAD, not a filled circle.
            //
            // It used to get a fixed highlight blob at (0.38, 0.36) and nothing
            // else — no curvature, no light direction, no transmission — while
            // the square got the whole glass treatment. That is why a dot read
            // as a flat disc with a sticker on it.
            //
            // Everything here comes off one quantity: the sphere normal. The
            // bead is a hemisphere of radius dotR standing on the cell, so at a
            // point q cells from its centre the surface normal is
            // (q, sqrt(1 - |q|^2)) — out of the screen at the crown, lying flat
            // at the rim. Refraction through it is done by the caller, which has
            // the cell texture; the rest is here.
            float2 q  = (cuv - 0.5f) / max(dotR, 1e-3f);
            float  rr = min(dot(q, q), 1.0f);
            float3 n  = float3(q, sqrt(max(0.0f, 1.0f - rr)));

            // The light is lifted out of the screen plane so the crown of a bead
            // is never fully dark when the source is low: a real light in front
            // of a wall still reaches the tops of what is on it.
            float3 l3 = normalize(float3(lightDir, 0.62f));

            // Curvature. One side of the bead faces the light and the other is
            // turned away — this is what makes it round.
            float diff = saturate(dot(n, l3));
            col *= 1.0f + lightI * (0.62f * diff - 0.24f);

            // The specular. Tight, and placed by the actual light direction, so
            // the highlights across the wall all point at the sun rather than
            // sitting in the same corner of every cell.
            float3 hv = normalize(l3 + float3(0.0f, 0.0f, 1.0f));
            float spec = powr(saturate(dot(n, hv)), 46.0f);
            col += spec * (0.16f + 0.34f * lightI);

            // Fresnel. Glass goes mirror-bright at grazing incidence, which is
            // the bright ring around the edge of a real bead and the single
            // cheapest cue that a thing is glass and not paint.
            float fres = powr(1.0f - n.z, 3.6f);
            col += fres * 0.13f * (0.35f + 0.65f * ln);
        }
        col *= m;
    } else {
        if (flank) return col;                 // side wall: no front-face detail

        // Distance from the block's edge, in the rotated frame. Squares are
        // tested this way rather than with four separate comparisons because it
        // is what lets splay rotate the outline as one shape.
        float2 d   = abs(cuv - 0.5f);
        float  m   = max(d.x, d.y);            // 0 centre, 0.5 edge
        float  in0 = 0.5f - 0.11f * splay;     // splayed blocks shrink slightly

        if (finish == 0) {
            // Glass: a one-pixel rim, lit on the side the light comes from and
            // shadowed opposite. The relief now carries the moulding, so this
            // is only the crisp arris along the top of the block.
            float e = clamp(1.2f / max(cellPx, 1.0f), 0.02f, 0.14f);
            if (m > in0 - e) {
                float2 s = sign(cuv - 0.5f);
                // Which edge are we on: the x one or the y one?
                float2 n = (d.x > d.y) ? float2(s.x, 0.0f) : float2(0.0f, s.y);
                col += dot(n, lightDir) * 0.16f;
            }
            if (m > in0) col *= 0.72f;         // the block does not fill the cell
        } else {
            // Flat: grout gaps, no rim.
            //
            // The grout YIELDS to the relief. A painted 0.08-cell dark band on
            // all four sides of every tile is a much louder edge than a real
            // crevice, and with depth up it was drawing a flat black lattice
            // over the top of the geometry — the blocks were there and you
            // could not see them for the grid. So the band narrows and lifts as
            // the blocks come out of the wall, because by then the separation
            // between them is being carried by their own side faces and the
            // occlusion in the gaps. At depth 0 this is exactly the old flat
            // tile, byte for byte.
            float w = 0.08f * (1.0f - 0.72f * depth);
            if (m > in0 - w) col *= mix(0.42f, 0.66f, depth);
        }
    }
    return col;
}

fragment float4 presentPass(VOut in [[stage_in]],
                            constant Uniforms &U     [[buffer(0)]],
                            constant Star     *stars [[buffer(2)]],
                            texture2d<float>   cells [[texture(0)]],
                            texture2d<float>   glass [[texture(1)]],
                            texture2d<float>   streakFine [[texture(2)]],
                            texture2d<float>   heights [[texture(3)]],
                            texture2d<float>   cellAux [[texture(4)]])
{
    constexpr sampler nearestS(coord::pixel, filter::nearest, address::clamp_to_edge);

    float2 px  = in.pos.xy;                 // pixel coords in the full-res target

    // The cell pitch is derived PER AXIS from the display size, so cols cells
    // span the width exactly and rows cells span the height exactly. There is
    // no remainder to hang off an edge and no origin to offset: every cell is
    // whole and the outermost ones sit flush against the display boundary.
    //
    // The two components are not equal, but they are within a fraction of a
    // percent of each other (cols = round(pixW / SP), so the width pitch is at
    // most half a cell out over the whole row, spread across every column).
    // Cells stay square to the eye; what they stop being is a whole number of
    // pixels, which is the same trade the vertical fit already makes.
    float2 SPv = float2(U.pixW / max(U.cols, 1.0f), U.pixH / max(U.rows, 1.0f));
    float  SP  = min(SPv.x, SPv.y);

    // ---- Relief. Find which block this pixel is actually looking at, and
    // where on it. Everything downstream — the cell colour, the detail passes,
    // the styling — then runs on the block the eye lands on rather than the one
    // that happens to sit under the pixel, which is the whole of the parallax.
    float  hmax = U.depthAmt * RELIEF_MAX;
    Relief rel  = castRelief(heights, nearestS, px / SPv, U.cols, U.rows, hmax);

    // A flank hit lands exactly ON a cell boundary, where floor() is a coin
    // toss and the grout test would fire. Push it a quarter-cell into the block
    // it belongs to, across the axis that was crossed, so the cell id, the
    // detail passes and the colour lookup all agree on which block this is.
    float2 gS = rel.g;
    if (rel.flank) {
        float e = 0.25f + 0.5f * float(rel.g[rel.axis] > rel.cell[rel.axis] + 0.5f);
        if (rel.axis == 0) gS.x = rel.cell.x + e; else gS.y = rel.cell.y + e;
    }
    px = clamp(gS, float2(0.0f), float2(U.cols, U.rows) - 1e-3f) * SPv;

    float2 cid = floor(px / SPv);

    float4 c   = cells.sample(nearestS, cid + 0.5f);
    float3 col = c.rgb;
    float  lum = c.a;

    // ---- Looking THROUGH the block (glass only).
    //
    // A solid glass block is a short light pipe: what you see on its face is
    // not the wall directly behind it but the wall a little way off along the
    // view, and the further you are from the frame centre the further off it
    // is. Refraction sets how far, dispersion splits that displacement per
    // channel so edges fringe, and frost averages the neighbourhood so the
    // transmitted image arrives scattered. All three are meaningless on a flat
    // tile, which is opaque, so they are skipped there entirely.
    if (U.finish == 0 && rel.h > 0.001f
        && (U.refractAmt > 0.005f || U.frostAmt > 0.005f)) {
        // How far along the view the transmitted image is taken from. Bounded,
        // because a block is a short light pipe and not a periscope: what you
        // see on its face is the wall JUST behind it. Unbounded, the lean at the
        // frame edge times a tall block times the dispersion split reached more
        // than a whole cell, so a block on the moon's limb took its red from the
        // disc and its blue from the night sky beyond it and came out as
        // saturated cyan. Half a dozen of those scattered over the moon, and it
        // is confetti rather than an object. 0.55 still crosses the boundary at
        // 0.5, so the block genuinely shows its neighbour — it just cannot skip
        // one. The two terms are scaled together, so the fringe keeps its
        // proportion to the displacement instead of surviving alone.
        float2 off   = rel.lean * (U.refractAmt * rel.h * 3.0f);
        float  disp  = (U.dispersAmt > 0.005f) ? U.dispersAmt * 1.6f : 0.0f;
        float  reach = length(off) + disp;
        float  kr    = (reach > 0.55f) ? 0.55f / reach : 1.0f;
        off *= kr; disp *= kr;

        float2 base = float2(cid) + 0.5f + off;
        float2 lim  = float2(U.cols, U.rows) - 0.5f;
        float3 t = cells.sample(nearestS, clamp(base, 0.5f, lim)).rgb;
        if (disp > 0.0f) {
            // Split along the view lean itself, so the fringe vanishes at the
            // frame centre — where there is no angle, there is no dispersion.
            //
            // Added as a bounded DIFFERENCE rather than taken as the channel
            // outright. Dispersion is a coloured edge a few percent wide; taking
            // whole channels from either side means that at a strong boundary —
            // the moon's limb against a night sky — a block gets its red from
            // the disc and its blue from the sky and comes out saturated cyan,
            // which is not a fringe, it is a wrong block.
            float2 dv = normalize(rel.lean + 1e-6f) * disp;
            float dr = cells.sample(nearestS, clamp(base + dv, 0.5f, lim)).r - t.r;
            float db = cells.sample(nearestS, clamp(base - dv, 0.5f, lim)).b - t.b;
            // In 0..1 colour, so 0.05 is thirteen levels: a visible edge tint and
            // nothing more. At 0.09 a coarse grid put a cyan band and a magenta
            // band straight across the moon, because at twenty rows the split
            // reaches out of the disc on one side and stays inside it on the
            // other and the clamp was wide enough to carry the whole difference.
            const float FR = 0.05f;
            t.r += clamp(dr, -FR, FR);
            t.b += clamp(db, -FR, FR);
        }
        if (U.frostAmt > 0.005f && U.lowfx < 0.5f) {
            float f = U.frostAmt * 1.7f;       // must clear a whole cell to blur
            float3 a = cells.sample(nearestS, clamp(base + float2( f, 0), 0.5f, lim)).rgb
                     + cells.sample(nearestS, clamp(base + float2(-f, 0), 0.5f, lim)).rgb
                     + cells.sample(nearestS, clamp(base + float2( 0, f), 0.5f, lim)).rgb
                     + cells.sample(nearestS, clamp(base + float2( 0,-f), 0.5f, lim)).rgb;
            t = mix(t, (t + a) * 0.2f, saturate(U.frostAmt * 1.3f));
        }
        col = t;
    }

    DetailCell dc = coarseCell(px, cid, SPv);
    float phase = cellPhase(uint(cid.y * U.cols + cid.x));

    if (U.lowfx < 0.5f) {
        float W = U.pixW, H = U.pixH;
        float2 moonP = astroXY(U.moonAlt, U.moonAz, U.facingAz, W, H);
        float  moonR = min(W, H) * 0.10f;

        // ---- The moon.
        //
        // Which cells are moon at all was settled by the coarse pass, so the
        // limb stays as chunky as the rest of the grid. This only redistributes
        // tone INSIDE those cells. Three rules, and each one was a visible bug:
        //
        //  ONE SUB-LATTICE FOR THE WHOLE DISC. Depth used to come from
        //  detailDepth() per cell, so with the affordable ceiling at four a
        //  gibbous moon came out as a patchwork of 2x2, 3x3 and 4x4 blocks
        //  according to how much albedo happened to vary in each. Mixed pitches
        //  read as noise, not as a finer mosaic — the disc stopped being one
        //  object. The moon is a single body and it gets a single grid.
        //
        //  THE DARK SIDE IS PART OF THE MOON. The old gate was
        //  `... && litSide(centre)`, so refinement stopped dead at the
        //  terminator: one side finely tiled, the other in whole coarse cells,
        //  with the seam between them running down the middle of the disc.
        //
        //  ONE TONE MODEL, NOT TWO MULTIPLIED FACTORS, AND COMPRESSED. See
        //  moonTone. The old code multiplied an albedo ratio by a terminator
        //  ratio whose floor was 0.16, in LINEAR luminance, applied to a colour
        //  that has already been through the tone ramp and blended with the sky.
        //  A sub-cell just past the terminator inside a cell whose centre was
        //  just before it came out at about a tenth of its neighbour: darker
        //  than the night sky. Those are the near-black specks, and a whole
        //  column of them where the terminator ran nearly vertically is the hard
        //  black strip down one side.
        if (U.moonAlt > 0.0f && U.sunAlt < 0.0f) {
            float2 dcen = (cid + 0.5f) * SPv - moonP;
            if (dot(dcen, dcen) < moonR * moonR) {
                // How much of the moon is reaching the eye through the cloud.
                // Two samples, and the difference between them matters:
                //
                //   at the disc's CENTRE, for how finely to subdivide. One
                //   object, one sub-lattice — reading it per cell puts 4x4
                //   blocks where the deck happens to be thin and 2x2 beside them
                //   where it is not, and a patchwork of pitches is the exact
                //   noise this pass is supposed to avoid.
                //
                //   at THIS cell, for how strongly to modulate. That is what
                //   lets the moon dissolve into the deck locally, a ragged edge
                //   of cloud eating into the disc rather than a switch thrown
                //   over the whole of it.
                float2 mcid  = clamp(floor(moonP / SPv), float2(0.0f),
                                     float2(U.cols, U.rows) - 1.0f);
                float  mVisC = saturate(cellAux.sample(nearestS, mcid + 0.5f).r);
                float  mVis  = saturate(cellAux.sample(nearestS, cid + 0.5f).r);
                float  detail = smoothstep(0.22f, 0.72f, mVis);

                // Blended, not switched. Depth falls back toward the coarse cell
                // as the cloud thickens, and the modulation is faded out with it
                // — so the moment a depth step changes the modulation either side
                // of it is already near zero and the change cannot be seen. Thin
                // cloud therefore gives a partly-detailed moon rather than a
                // detailed one that pops off when the cloud crosses a threshold.
                // The depth curve sits ABOVE the strength curve on purpose. A
                // split cell shows its sub-lattice through the styling whether
                // it is modulated or not, so the sub-grid has to be gone before
                // the modulation is — otherwise a moon hidden behind a deck
                // still prints a finer grain of tiles into the cloud, which is
                // the same "the moon is drawn regardless" bug wearing a
                // different hat.
                // 8 px, not the 4 the other features use. The glass rim is
                // 1.2 px wide and clamped at 0.14 of a cell, so below about 9 px
                // a sub-cell is MORE rim than face: the moon stops being tiles
                // and becomes graph paper, which is a large part of what "mixed
                // blocky cells" looks like on a smaller display.
                int affordable = min(4, int(floor(SP / 8.0f)));
                int depth = int(round(mix(1.0f, float(max(affordable, 1)),
                                          smoothstep(0.30f, 0.80f, mVisC))));
                depth = clamp(depth, 1, 4);

                if (depth > 1) {
                    float earthRel = moonEarthRel(U.moonIllum, U.covF);
                    float vCell   = max(moonSample(dcen.x / moonR, dcen.y / moonR), 0.05f);
                    float litCell = saturate(
                        0.5f + litDist(dcen.x, dcen.y, moonR, U.moonPhase) / max(SP, 1.0f));
                    float toneCell = moonTone(vCell, litCell, earthRel);

                    dc = splitCell(px, SPv, depth);
                    float2 ds = (dc.id + 0.5f) * dc.sizev - moonP;
                    // Sub-cells outside the disc inherit the parent wholesale, so
                    // a limb cell stays one full square and the outline gains no
                    // resolution: the limb keeps the coarse grid's chunkiness,
                    // which is the look.
                    if (dot(ds, ds) <= moonR * moonR) {
                        float vSub   = max(moonSample(ds.x / moonR, ds.y / moonR), 0.05f);
                        float litSub = saturate(
                            0.5f + litDist(ds.x, ds.y, moonR, U.moonPhase) / max(dc.size, 1.0f));
                        // A ratio, so a split cell averages back to the unsplit
                        // one and leaves no seam against a neighbour that did not
                        // split. The 0.55 power is the tone ramp's compression
                        // read backwards: `col` is not linear light, so a linear
                        // ratio applied to it overshoots — that is what turned a
                        // 3:1 tone step into a 10:1 pixel step.
                        float toneSub = moonTone(vSub, litSub, earthRel);
                        float ratio = powr(clamp(toneSub / max(toneCell, 1e-3f),
                                                 0.06f, 4.0f), 0.55f);
                        ratio = mix(1.0f, ratio, detail);
                        col *= ratio;
                        lum *= ratio;
                    }
                    phase = cellPhase(uint(dc.id.y * U.cols * float(depth) + dc.id.x));
                }
            }
        }

        // ---- The rainbow.
        //
        // Third use of the same primitive, and the bow needs it more than either
        // of the others. The primary spans about two degrees from violet to red
        // and a cell at production density spans nearly three, so at cell
        // resolution the ENTIRE spectrum fits inside one block: the coarse pass
        // integrates it and correctly hands back the average, which is a green
        // line. The colour order — the thing that makes it a rainbow rather than
        // a stripe — only exists below the cell.
        //
        // So the coarse pass owns WHICH cells are bow and how bright they are,
        // exactly as it owns the moon's limb, and this owns the hue inside them.
        // The sub-cell's own chroma is substituted at the cell's OWN luminance,
        // so a split cell averages back to the unsplit one and leaves no seam
        // against a neighbour that did not split.
        //
        // One lattice for the whole arc: depth is read from the scene-level lit
        // factor, not the per-cell one, because reading it per cell puts 4x4
        // blocks where the cloud happens to be thin and 2x2 beside them, and a
        // patchwork of pitches is the exact noise this pass exists to avoid.
        if (bowLiquid(U) && U.sunAlt > 0.0f) {
            float deckF = deckOpaque(U);
            float sunDim = 1.0f - U.covF * 0.25f;
            float vis = saturate(cellAux.sample(nearestS, cid + 0.5f).r);
            float litCell  = bowLit(U, deckF, sunDim, vis);
            float litScene = bowLit(U, deckF, sunDim, 1.0f);
            float2 ccen = (cid + 0.5f) * SPv;
            Bow bc = bowAt(bowTheta(ccen, U), bowFootprint(ccen, U, 1.0f),
                           bowVivid(U), litCell);
            if (bc.amt > 0.015f) {
                // 8 px for the same reason the moon uses 8: below that a
                // sub-cell is more glass rim than face and the arc turns into
                // graph paper.
                int affordable = min(4, int(floor(SP / 8.0f)));
                int depth = int(round(mix(1.0f, float(max(affordable, 1)),
                                          smoothstep(0.06f, 0.32f, litScene))));
                depth = clamp(depth, 1, 4);
                if (depth > 1) {
                    dc = splitCell(px, SPv, depth);
                    float2 scen = (dc.id + 0.5f) * dc.sizev;
                    Bow bf = bowAt(bowTheta(scen, U),
                                   bowFootprint(scen, U, 1.0f / float(depth)),
                                   bowVivid(U), litCell);
                    // Swap the chroma, keep the value. A sub-cell the finer
                    // band misses tends toward white here, which desaturates it
                    // back toward the sky it should have been — the coarse cell
                    // only carried a tint because PART of it was bow.
                    const float3 LW = float3(0.2126f, 0.7152f, 0.0722f);
                    float3 tint = mix(float3(1.0f), bf.col, saturate(bf.amt * 1.7f));
                    float3 want = tint * (dot(col, LW) / max(dot(tint, LW), 1e-3f));
                    col = mix(col, saturate(want),
                              0.85f * smoothstep(0.015f, 0.10f, bc.amt));
                    phase = cellPhase(uint(dc.id.y * U.cols * float(depth) + dc.id.x));
                }
            }
        }

        // ---- Falling rain and snow.
        //
        // Same primitive as the moon, applied to the other thing in the scene
        // that is finer than a cell. A streak is a few millimetres wide and a
        // cell is eighteen pixels, so at cell resolution every streak fattens
        // to a full square and the rain reads as falling bricks.
        //
        // The simulation rasterises the same streaks at STREAK_SUB times the
        // resolution. The coarse pass still decides WHICH cells are rain — it
        // took the maximum over each block, so a cell any streak passes through
        // is a rain cell at full strength — and this only says where inside the
        // cell the water is. Coarse owns the shape, detail refines within it.
        //
        // And it obeys the same rule about not splitting for nothing: a cell
        // the streak fills uniformly stays one chunk. Only a cell the streak
        // crosses has anything to show.
        {
            float kc = streakFine.sample(nearestS, (cid + 0.5f) * STREAK_SUB).r;   // any sub-cell
            float lo = 1.0f, hi = 0.0f;
            for (int j = 0; j < int(STREAK_SUB); ++j)
                for (int i = 0; i < int(STREAK_SUB); ++i) {
                    float v = streakFine.sample(nearestS,
                        cid * STREAK_SUB + float2(float(i) + 0.5f, float(j) + 0.5f)).r;
                    lo = min(lo, v); hi = max(hi, v);
                }
            (void)kc;
            // A streak's dying tail is barely there; subdividing for it just
            // scatters single lit sub-cells across the sky as specks.
            if (hi > 0.07f && hi - lo > 0.06f) {
                DetailCell sc = splitCell(px, SPv, int(STREAK_SUB));
                float v = streakFine.sample(nearestS, sc.id + 0.5f).r;

                // The coarse cell was drawn with the block maximum, so a
                // sub-cell the streak misses has to give that contribution
                // back. Scaling straight to zero would drive it to black
                // instead of back toward the sky it came from, so the floor is
                // what the cell was worth before the streak lit it — the rain's
                // share of a cell's brightness, roughly, and seam-free because
                // a uniform cell never reaches this code at all.
                float ratio = mix(1.0f - hi * 0.55f, 1.0f, saturate(v / max(hi, 1e-4f)));
                col *= ratio;
                lum *= ratio;
                dc = sc;
                phase = cellPhase(uint(sc.id.y * U.cols * STREAK_SUB + sc.id.x) + 977u);
            }
        }

        // ---- Water on the pane.
        //
        // Water changes the MATERIAL of the cells it touches; it is never an
        // object drawn on top of them. A wet cell is the same cell in the same
        // theme, only wetter: darker and more saturated, the way a wet surface
        // is, with a tighter, brighter specular edge because water is glossy.
        //
        // Drawing beads here instead — subdivided discs with highlights — made
        // the drops ADD light, so they read as bright confetti scattered over a
        // calm grid. Modulating the material keeps the mosaic intact and lets
        // the effect sit far enough back to be atmosphere rather than decoration.
        //
        // Strength comes from the simulation already scaled by real rainfall,
        // so drizzle is barely perceptible and a downpour visibly soaks the pane.
        float4 gcell = glass.sample(nearestS, cid + 0.5f);
        float wetness = gcell.x;
        if (wetness > 0.01f) {
            int kind = int(gcell.y + 0.5f);

            if (kind == 6) {
                // Snow lying on a surface. Bright, flat, and it kills the
                // detail underneath the way settled snow does.
                col = mix(col, float3(0.90f, 0.93f, 0.97f), wetness * 0.85f);
                lum = saturate(lum + wetness * 0.5f);
            } else if (kind == 5) {
                // Standing water pooled at the bottom edge. Deep water is dark
                // and reflective, so it takes the sky from above rather than
                // simply darkening.
                // Standing water is mostly a MIRROR, not a dark bar: it takes
                // the sky from above and only slightly deepens what is under
                // it. Darkening it heavily reads as a black stripe across the
                // bottom of the screen rather than as water.
                float2 mirror = float2(cid.x, max(0.0f, cid.y - (U.rows - cid.y) * 2.0f));
                float3 sky = cells.sample(nearestS, mirror + 0.5f).rgb;
                col = mix(col, mix(col * 0.86f, sky, 0.62f), wetness);
                lum = saturate(lum * 0.92f);
            } else if (kind >= 7) {
                // ---- WEATHER ON THE FURNITURE.
                //
                // The dock, the menu bar and the widgets draw over the
                // wallpaper, so none of this is inside their rects: it is the
                // band of cells immediately above a top edge, where the
                // meniscus stands, and below a bottom edge, where a film hangs.
                //
                // These are separate MATERIALS rather than one wetness at
                // several strengths, because that is the actual difference
                // between them — glaze is bright where water is dark, frost is
                // matte where ice is glossy, dirt is warm where all three are
                // cool. The pane's own water is deliberately understated so it
                // reads as atmosphere; a lip is a thing you are looking AT, so
                // these are allowed to be seen.
                float  k    = min(wetness, 1.0f);
                float  lumv = dot(col, float3(0.299f, 0.587f, 0.114f));

                // ---- THE PARTIAL EDGE CELL.
                //
                // What stopped these marks looking like water. Every deposit
                // used to occupy WHOLE cells, so the top of a wet band was a
                // ruled line lying exactly along a cell boundary and the marks
                // read as a rectangle drawn on the wallpaper rather than as
                // something lying on a surface. The simulation now sends how
                // much of this cell the deposit actually covers — `gcell.w` is
                // the bare fraction measured down from the cell's top — and the
                // deposit dissolves inside the cell instead of ending at its
                // edge. Furniture does not land on cell boundaries; this is the
                // half of that which the shader owns.
                //
                // Deliberately soft rather than a clean cut: a meniscus has a
                // gradient, not a border. A third of a cell of feather is ~16px
                // at production density, which is enough to read as material.
                // The bead (kind 12) is excluded — it spends z and w on where
                // the drop sits, and it is a discrete object anyway.
                if (kind != 12) {
                    float bare = gcell.w;
                    if (bare > 0.02f) {
                        // Cell-local v, recomputed rather than taken from `dc`:
                        // the moon and the streaks may already have subdivided
                        // that, and this has to be the COARSE cell's own uv.
                        float cv = px.y / SPv.y - cid.y;
                        k *= smoothstep(bare - 0.24f, bare + 0.14f, cv);
                    }
                }

                if (kind == 7) {
                    // Liquid water on a lip. Wet is DARKER and more saturated —
                    // the film kills the diffuse scatter that made the dry
                    // surface pale — and glossy, because what you lose in
                    // scatter comes back as a reflection of the sky above.
                    col = mix(col, col * 0.55f, k);
                    col = mix(col, lumv + (col - lumv) * 1.60f, k * 0.85f);
                    float3 sky = cells.sample(nearestS,
                                    float2(cid.x, max(0.0f, cid.y - 5.0f)) + 0.5f).rgb;
                    col = mix(col, sky, k * 0.26f);
                    lum = saturate(lum * (1.0f - k * 0.28f) + k * 0.10f);

                } else if (kind == 12) {
                    // A bead standing on that lip. Same sphere-of-water shading
                    // as a pane droplet, on a surround that is properly soaked.
                    col = mix(col, col * 0.58f, k);
                    col = mix(col, lumv + (col - lumv) * 1.55f, k * 0.80f);
                    int wdepth = detailDepth(wetness, 0.10f, SP, 6.0f, 2);
                    if (wdepth > 1) {
                        dc = splitCell(px, SPv, wdepth);
                        phase = cellPhase(uint(dc.id.y * U.cols * float(wdepth) + dc.id.x));
                    }
                    float2 rel = gcell.zw;
                    float  q   = min(length(rel) * 1.30f, 1.0f);
                    if (q < 1.0f) {
                        float2 src = clamp(cid - rel * (q * q * 2.6f), float2(0.0f),
                                           float2(U.cols - 1.0f, U.rows - 1.0f));
                        col = mix(col, cells.sample(nearestS, src + 0.5f).rgb, 0.60f * k);
                        col *= 1.0f - saturate((q - 0.50f) / 0.50f) * 0.32f * k;
                        float spec = saturate(1.0f - length(rel - float2(-0.30f, -0.30f)) / 0.42f);
                        col += spec * spec * 0.26f * k;
                    }
                    lum = saturate(lum * (1.0f - k * 0.20f) + k * 0.12f);

                } else if (kind == 8) {
                    // Clear ice. A glaze is the one deposit that BRIGHTENS what
                    // it covers: it is transparent, so the surface shows
                    // through, with a hard bright skin over the top of it. What
                    // makes it read as ice rather than as paint is that the
                    // skin is SPECULAR — a glaze is optically smooth, far
                    // smoother than the surface underneath, so it carries a
                    // hard highlight that frost at the same whiteness cannot.
                    col = mix(col, mix(col * 1.14f, float3(0.82f, 0.90f, 0.99f), 0.42f), k);
                    float gl = fract(sin(dot(cid, float2(31.7f, 11.3f))) * 24634.6345f);
                    col += k * (0.06f + 0.16f * pow(gl, 3.0f));
                    lum = saturate(lum + k * 0.26f);

                } else if (kind == 9) {
                    // Frost. Crystalline and MATTE — the opposite of glaze,
                    // which is why the two never look alike however cold it is.
                    // It scatters instead of reflecting, so it takes the colour
                    // out and puts nothing back but the occasional facet catching
                    // the light.
                    col = mix(col, mix(float3(lumv), float3(0.93f, 0.95f, 0.99f), 0.72f),
                              k * 0.88f);
                    float g = fract(sin(dot(cid, float2(12.9898f, 78.233f))) * 43758.5453f);
                    float tw = sin(U.time * 0.85f + g * 6.2832f);
                    col += pow(max(0.0f, tw), 14.0f) * k * 0.20f;
                    lum = saturate(lum + k * 0.28f);

                } else if (kind == 13) {
                    // CONDENSATION. A surface carrying micron-scale droplets is
                    // optically rough at the wavelength of light, so it
                    // SCATTERS: it goes pale and hazy and loses contrast. That
                    // is breath on a window, and it is the opposite of what
                    // rain does to the same surface, which is why fog and dew
                    // must not be drawn as weak versions of wet.
                    //
                    // It is also why they are visible at all. Dew forms on a
                    // clear night and a night sky is nearly black — there is
                    // nothing there to darken, and a darkening treatment made
                    // the one condition that only ever happens in the dark
                    // completely invisible.
                    float3 haze = mix(float3(lumv), float3(0.86f, 0.90f, 0.96f), 0.55f);
                    col = mix(col, haze, k * 0.62f);
                    // No specular anywhere: a scattering film has no mirror in
                    // it, which is exactly what separates it from a glaze.
                    lum = saturate(lum + k * 0.16f);

                } else if (kind == 10) {
                    // Dry deposition. Warm, dull and desaturating — dirt is the
                    // only thing here that is not made of water, and it should
                    // not read as any kind of wetness.
                    float d = k * 0.60f;
                    col = mix(col, mix(float3(lumv), float3(0.44f, 0.39f, 0.33f), 0.55f), d);
                    lum = saturate(lum * (1.0f - d * 0.30f));

                } else {
                    // kind 11 — a matte film: drizzle, dew, or rain whose drops
                    // are measurably too small to gather. Wet, and therefore
                    // darker, but with no bead anywhere on it to catch a
                    // highlight, so it darkens and FLATTENS instead of
                    // glossing. That flatness is the whole of what makes a
                    // drizzled surface look different from a rained-on one, so
                    // it has to be strong enough to actually see — at the
                    // wet-cell strengths the pane uses it was a 13% shift and
                    // vanished entirely against the mosaic.
                    float d = min(1.0f, k * 1.05f);
                    col = mix(col, col * 0.60f, d);
                    col = mix(col, float3(lumv), d * 0.34f);
                    lum = saturate(lum * (1.0f - d * 0.30f));
                }
            } else {
                // Wet cells: same cell, wetter. Darker and more saturated.
                float k = wetness * (kind == 2 ? 1.15f : (kind == 3 ? 0.5f : 1.0f));
                k = min(k, 0.55f);
                float lumv = dot(col, float3(0.299f, 0.587f, 0.114f));
                col = mix(col, col * 0.80f, k);
                col = mix(col, lumv + (col - lumv) * 1.35f, k * 0.7f);
                lum = saturate(lum * (1.0f - k * 0.18f));

                // Water that is still sitting on the pane earns a finer grid:
                // a bead and its wet surround carry an edge the coarse cell
                // destroys. Same detailDepth as everything else, so it stays
                // in-theme and bounded.
                // Only a bead earns the finer grid, and only a shallow one.
                // Subdividing the surrounding wet film too turned the whole
                // pane into scattered hash marks.
                if (kind == 1 && wetness > 0.28f) {
                    int wdepth = detailDepth(wetness, 0.10f, SP, 6.0f, 2);
                    if (wdepth > 1) {
                        dc = splitCell(px, SPv, wdepth);
                        phase = cellPhase(uint(dc.id.y * U.cols * float(wdepth) + dc.id.x));
                    }
                }

                if (kind == 1) {
                    float2 rel = gcell.zw;
                    float q = min(length(rel) * 1.35f, 1.0f);
                    if (q < 1.0f) {
                        float2 src = clamp(cid - rel * (q * q * 2.2f), float2(0.0f),
                                           float2(U.cols - 1.0f, U.rows - 1.0f));
                        float3 behind = cells.sample(nearestS, src + 0.5f).rgb;
                        col = mix(col, behind, 0.55f * wetness);
                        col *= 1.0f - saturate((q - 0.55f) / 0.45f) * 0.30f * wetness;
                        float spec = saturate(1.0f - length(rel - float2(-0.30f, -0.30f)) / 0.40f);
                        col += spec * spec * 0.13f * wetness;
                    }
                }
            }
        }

        // ---- Stars.
        // A star is far smaller than a cell, so a coarse cell renders it as a
        // blob. Same mechanism, different source: the one cell holding the star
        // breaks down, the star occupies a single sub-cell of it, and the grid
        // resumes at full size immediately either side. Only the brighter ones,
        // only the upper half (roomstand.py:2643).
        if (U.sunAlt < -6.0f && dc.depth == 1) {
            float wet  = (U.code >= 51 && U.code <= 99) ? 0.35f : 0.0f;
            float fogf = U.fogOn > 0.5f ? 0.45f : 0.0f;
            float aq   = saturate((U.scAQI - 50.0f) / 200.0f);
            float vis = max(0.0f, 1.0f - U.covF / 0.7f) * max(0.0f, (-U.sunAlt - 6.0f) / 14.0f)
                      * (1.0f - aq * 0.45f) * (1.0f - wet) * (1.0f - fogf);
            if (vis > 0.05f) {
                for (int si = 0; si < U.starCount; ++si) {
                    if (stars[si].br < 0.55f) continue;      // only ones worth the detail
                    float2 sp;
                    if (!starXY(stars[si], U.facingAz, W, H, sp)) continue;
                    if (sp.y > H * 0.5f) continue;
                    if (!all(floor(sp / SPv) == cid)) continue;  // not this cell: resume
                    // A point source is maximum contrast; capped tighter than
                    // the moon so a star stays a point rather than a patch.
                    int depth = detailDepth(1.0f, 0.05f, SP, 4.0f, 4);
                    if (depth < 2) break;
                    dc = splitCell(px, SPv, depth);
                    if (all(floor(sp / dc.sizev) == dc.id)) {
                        float tw = 0.72f + 0.28f * sin(U.time * 1.7f + float(si) * 2.4f);
                        float l = min(1.0f, vis * stars[si].br * tw);
                        col = float3(l, l, min(1.0f, l * 1.06f));
                        lum = l;
                    }
                    phase = cellPhase(uint(dc.id.y * U.cols * float(depth) + dc.id.x));
                    break;
                }
            }
        }
    }

    // ---- The light is the sky's own.
    //
    // There is no light-angle control any more, and there should never have been
    // one: the scene already contains its light sources, projected to screen
    // positions by the same astroXY the sun and moon discs are drawn with. A
    // slider can only ever disagree with them — set it to "up and to the left"
    // and the blocks are lit from the upper left at dawn, at noon and at
    // midnight, while the sun visibly crosses the frame the other way.
    //
    // So the direction is measured to the body itself. Screen axes, +y down, and
    // in this projection altitude runs UP the frame (y = (1 - alt/85) * H): a
    // body on the horizon sits at the bottom edge and one overhead at the top.
    // A block at dawn is therefore lit from below and from the side the sun has
    // risen on, and by noon from straight above — the shading sweeps around
    // through the day on its own, and it is the real sun's own arc that it
    // sweeps with.
    //
    // Taken to the BLOCK's centre, not the pixel's, so one face is lit as one
    // face. It is a point on the screen rather than a direction at infinity,
    // which is right for a projected dome: blocks near the sun turn their inner
    // flanks toward it, and the pattern radiates from where the sun actually is.
    //
    // A source is weighted by how high it stands and how bright it is, and the
    // two are BLENDED, never switched between — at twilight the light rolls
    // over from the sun to the moon across a few degrees of altitude instead of
    // jumping direction between two frames.
    float2 hereP = (rel.cell + 0.5f) * SPv;
    float2 sunSP  = astroXY(U.sunAlt,  U.sunAz,  U.facingAz, U.pixW, U.pixH);
    float2 moonSP = astroXY(U.moonAlt, U.moonAz, U.facingAz, U.pixW, U.pixH);
    float2 dS = sunSP - hereP, dM = moonSP - hereP;

    // From part way through civil twilight to a few degrees up. A smoothstep
    // rather than a ramp because it is the ENDS that matter: a linear weight
    // arrives at zero with its full slope, and a light that stops turning all at
    // once at a particular altitude is the hard switch this is meant to avoid.
    // The sun still owns the direction for a while after it has set — that is
    // what a sunset is — so the low end sits below the horizon.
    float wSun  = smoothstep(-8.0f, 4.0f, U.sunAlt);
    // The moon is a weak source and it only gets to light anything once the sun
    // has given up the sky. Illumination matters: a crescent lights very little.
    float wMoon = smoothstep(-1.0f, 8.0f, U.moonAlt)
                * (0.15f + 0.85f * saturate(U.moonIllum / 100.0f))
                * 0.85f * (1.0f - wSun);

    // Right ON a body the direction to it is undefined, and neighbouring blocks
    // would take wildly different ones — the disc would come out speckled. So a
    // source stops being directional for the two or three blocks it covers,
    // which is also the truth of it: you cannot be lit from the side by
    // something you are inside.
    float lenS = length(dS), lenM = length(dM);
    wSun  *= smoothstep(0.0f, 2.5f * SP, lenS);
    wMoon *= smoothstep(0.0f, 2.5f * SP, lenM);

    // A faint overhead bias, so a moonless night is lit from the zenith rather
    // than from an undefined direction — with no body up there is no direction
    // to measure, and a normalize() of nothing is a discontinuity.
    float2 Lv = dS / max(lenS, 1e-3f) * wSun
              + dM / max(lenM, 1e-3f) * wMoon
              + float2(0.0f, -1.0f) * 0.06f;
    float2 L  = Lv / max(length(Lv), 1e-4f);

    // Intensity stays a control. What the sky decides is how much of it is
    // DIRECTIONAL: with nothing up, and under thick cloud, the light arrives
    // from everywhere at once and the flanks separate less.
    float srcW = saturate(wSun + wMoon);
    float I    = U.lightInt * mix(0.45f, 1.0f, srcW) * (1.0f - U.covF * 0.35f);

    // On a flank, drop the across-axis coordinate to the middle of the face.
    // A dot then extrudes as a cylinder rather than as a sliver of its own rim.
    float2 suv = dc.uv;
    if (rel.flank) { if (rel.axis == 0) suv.x = 0.5f; else suv.y = 0.5f; }

    // ---- Looking THROUGH the bead (glass dots).
    //
    // The block-level transmission above displaces the whole cell by the view
    // lean, which is what a slab of glass does. A sphere does more than that:
    // its surface is curved, so the displacement varies ACROSS the bead — none
    // at the crown, where you look straight through, and swinging outward at the
    // rim, where the surface is steep. That varying displacement is what makes a
    // bead magnify and invert what is behind it instead of merely offsetting it,
    // and it is the difference between a glass ball and a tinted disc.
    //
    // Dispersion splits it per channel along the same normal, so the fringe
    // appears at the rim and vanishes at the crown, exactly where a real bead
    // puts it. Frost scatters what arrives. Both are skipped on a flat finish,
    // which has nothing to transmit, and outside the bead, which is empty cell.
    if (U.shape == 1 && U.finish == 0
        && (U.refractAmt > 0.005f || U.frostAmt > 0.005f)) {
        float  dr = dotRadius(lum, U.time, phase);
        float2 q  = (suv - 0.5f) / max(dr, 1e-3f);
        float  rr = dot(q, q);
        if (rr < 1.0f) {
            // Sphere normal, and the scale of the bead relative to a whole cell
            // — a subdivided bead is smaller and must bend light less.
            float2 n  = q * sqrt(saturate(1.0f - rr * 0.55f));
            float  sz = dc.size / max(SP, 1e-3f);
            float2 lim = float2(U.cols, U.rows) - 0.5f;
            float2 base = float2(cid) + 0.5f + n * (U.refractAmt * 2.1f * sz);
            float3 t;
            if (U.dispersAmt > 0.005f) {
                float2 dv = n * (U.dispersAmt * 1.1f * sz);
                t = float3(cells.sample(nearestS, clamp(base + dv, 0.5f, lim)).r,
                           cells.sample(nearestS, clamp(base,      0.5f, lim)).g,
                           cells.sample(nearestS, clamp(base - dv, 0.5f, lim)).b);
            } else {
                t = cells.sample(nearestS, clamp(base, 0.5f, lim)).rgb;
            }
            if (U.frostAmt > 0.005f && U.lowfx < 0.5f) {
                float f = U.frostAmt * 1.7f;
                float3 a = cells.sample(nearestS, clamp(base + float2( f, 0), 0.5f, lim)).rgb
                         + cells.sample(nearestS, clamp(base + float2(-f, 0), 0.5f, lim)).rgb
                         + cells.sample(nearestS, clamp(base + float2( 0, f), 0.5f, lim)).rgb
                         + cells.sample(nearestS, clamp(base + float2( 0,-f), 0.5f, lim)).rgb;
                t = mix(t, (t + a) * 0.2f, saturate(U.frostAmt * 1.3f));
            }
            // Weighted toward the rim: the crown of a bead shows what is directly
            // behind it, so forcing the transmitted colour there would only make
            // the cell disagree with itself.
            col = mix(col, t, saturate(0.35f + 0.65f * rr));
        }
    }

    float rot = U.splayAmt * cellJit(rel.cell, 4.7f) * 0.22f;
    col = styleCell(col, suv, dc.size, lum, phase, U.time, U.shape, U.finish,
                    rel.flank, L, I, rot, U.splayAmt, U.depthAmt);

    // ---- Relief shading. Front faces, side faces, and the crevices between.
    if (hmax > 0.0005f) {
        float shade = 1.0f;
        if (rel.flank) {
            // A side face is turned away from the viewer, so it is darker than
            // the front even when lit; how much darker depends on whether it
            // faces the light. This is the single strongest cue that these are
            // blocks and not a bevel, which is why it is a straight lambert on
            // the face normal rather than anything softened.
            shade = 1.0f + I * (0.55f * dot(rel.nrm, L) - 0.42f);
            // The bottom of a flank sits in the crevice and sees less sky.
            float f = saturate(rel.z / max(rel.h, 1e-3f));
            shade *= mix(1.0f - 0.45f * I, 1.0f, f * f);
        } else {
            // CONTACT OCCLUSION. A block lower than its neighbour is in a
            // trench: the light that reaches its front face is cut by whatever
            // stands over it. Darkening is proportional to how much higher the
            // neighbour is and how close to it we are, so a flat stretch of
            // wall gets none of it at all.
            float2 cuv = clamp(rel.g - rel.cell, 0.0f, 1.0f);
            float occ = 0.0f;
            for (int k = 0; k < 4; ++k) {
                float2 o = (k == 0) ? float2(-1, 0) : (k == 1) ? float2(1, 0)
                         : (k == 2) ? float2(0, -1) : float2(0, 1);
                float hn = cellHeight(heights, nearestS, rel.cell + o,
                                      U.cols, U.rows, hmax);
                float dh = hn - rel.h;
                if (dh <= 0.0f) continue;
                float2 e = 0.5f - o * (cuv - 0.5f);   // distance to that edge
                float  d = (k < 2) ? e.x : e.y;
                occ += saturate(dh / (hmax * 0.45f)) * (1.0f - smoothstep(0.0f, 0.6f, d));
            }
            shade *= 1.0f - saturate(occ) * 0.55f;
            // Splay also tips the front face, so a wall of blocks catches the
            // light unevenly instead of returning one flat value.
            float2 tilt = float2(cellJit(rel.cell, 11.3f), cellJit(rel.cell, 29.1f));
            shade *= 1.0f + I * dot(tilt, L) * U.splayAmt * 1.1f;
        }
        col *= max(shade, 0.0f);
    }

    // Residual sheen while the pane is still wet — a whole-screen wash, so it
    // belongs here rather than in the instanced droplet pass.
    float sheen = U.glassWet * 0.05f;
    if (sheen > 0.0f) col = mix(col, float3(150.0f, 190.0f, 235.0f) / 255.0f, sheen);

    return float4(col, 1.0f);
}


// ================================================================ GLASS LAYER
// Treats the screen as a pane you are looking THROUGH, so weather leaves a
// trace instead of only falling past it. Droplets cling, swell, then run,
// leaving a wet trail; the pane dries slowly afterwards, fast under sun; what
// evaporates leaves faint mineral spots that stay until the next rain washes
// them off; hard wind spins up vortices that drift downwind.
//
// The simulation is CPU-side (Simulation.swift) because it is a few hundred
// particles at most and it integrates. Here we just draw them — as instanced
// quads, already snapped to the dot grid by the sim so they read as part of
// the mosaic rather than smooth overlay art.

struct GlassQuad { float x, y, r, kind, alpha, p0, p1, p2; };

struct GOut {
    float4 pos   [[position]];
    float2 luv;
    float  kind  [[flat]];
    float  alpha [[flat]];
};

vertex GOut glassVS(uint vid [[vertex_id]], uint iid [[instance_id]],
                    constant GlassQuad *quads [[buffer(0)]],
                    constant Uniforms  &U     [[buffer(1)]])
{
    constant GlassQuad &q = quads[iid];
    // two triangles, corners (0,0)(1,0)(0,1)(1,0)(1,1)(0,1)
    const float2 corners[6] = { float2(0,0), float2(1,0), float2(0,1),
                                float2(1,0), float2(1,1), float2(0,1) };
    float2 c = corners[vid];
    // kind 2 is the run-down trail: a tall thin rect, not a disc.
    // (`half` is a reserved type name in MSL — do not use it as a variable.)
    float2 ext = (q.kind == 2.0f) ? float2(q.r, q.p0 * 0.5f) : float2(q.r, q.r);
    float2 p = float2(q.x, q.y) + (c * 2.0f - 1.0f) * ext;

    // The simulation works in grid space, whose width is cols*cellSP — up to
    // half a cell wider than the display. Scale into display space so the
    // droplets stay registered with the mosaic cells they were snapped to.
    float2 gridExtent = float2(U.cols, U.rows) * U.cellSP;
    p *= float2(U.pixW, U.pixH) / max(gridExtent, 1.0f);

    GOut o;
    o.pos   = float4(p.x / U.pixW * 2.0f - 1.0f, 1.0f - p.y / U.pixH * 2.0f, 0.0f, 1.0f);
    o.luv   = c;
    o.kind  = q.kind;
    o.alpha = q.alpha;
    return o;
}

fragment float4 glassFS(GOut in [[stage_in]]) {
    float3 tint;
    float  a = in.alpha;
    int    k = int(in.kind);

    if (k == 2) {                                   // trail
        tint = float3(190, 214, 242) / 255.0f;
    } else {
        float d = length(in.luv - 0.5f) * 2.0f;     // 0 at centre, 1 at edge
        if (k == 4) {                               // dried-spot ring
            if (abs(d - 0.8f) > 0.12f) discard_fragment();
            tint = float3(226, 240, 255) / 255.0f;
        } else {
            if (d > 1.0f) discard_fragment();
            switch (k) {
                case 0:  tint = float3(214, 232, 255) / 255.0f; break;  // droplet body
                case 1:  tint = float3(255, 255, 255) / 255.0f; break;  // highlight
                case 3:  tint = float3(206, 222, 244) / 255.0f; break;  // dried spot
                default: tint = float3(226, 238, 255) / 255.0f; break;  // vortex
            }
        }
    }
    return float4(tint * a, a);
}
