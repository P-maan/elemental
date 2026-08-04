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
    float lightAngle;          // degrees; light direction in the screen plane
    float lightInt;            // 0..1
    float refractAmt;          // 0..1, glass only
    float dispersAmt;          // 0..1, glass only
    float frostAmt;            // 0..1, glass only
    float splayAmt;            // 0..1
    float _pad0, _pad1;        // keep the struct a multiple of 16 bytes (224)
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

// Sky gradient for a screen-space y fraction (roomstand.py:2186)
inline float3 skyRGB(float sAlt, float yFrac, float aqiF, float covF, float smokeF) {
    float a = clamp(sAlt, -20.0f, 90.0f);
    // How far down the frame the HORIZON colour reaches.
    //
    // This was 0.72, which is the wrong way round: an exponent below one pulls
    // the horizon colour UP the frame, so at mid-height — 42 degrees of
    // altitude, where the sky is still deep blue — the gradient was already
    // two thirds of the way to the pale horizon tint. That is the single
    // reason the bottom half of a daytime frame reads as flat grey-lavender
    // instead of blue, and at twilight it is what smeared the warm horizon
    // band over the entire sky.
    //
    // Above one, the horizon tint stays where it belongs: a band low down,
    // with blue holding all the way to the zenith.
    float h = min(1.0f, powr(max(yFrac, 0.0f), 1.6f));
    float tr, tg, tb, hr, hg, hb;
    if (a <= -18.0f)      { tr=3;  tg=5;  tb=14; hr=7;  hg=9;  hb=20; }
    else if (a <= -12.0f) { float f=(a+18.0f)/6.0f;
        tr=skl(3,8,f);    tg=skl(5,12,f);   tb=skl(14,26,f);
        hr=skl(7,18,f);   hg=skl(9,16,f);   hb=skl(20,38,f); }
    else if (a <= -6.0f)  { float f=(a+12.0f)/6.0f;
        tr=skl(8,20,f);   tg=skl(12,30,f);  tb=skl(26,62,f);
        hr=skl(18,44,f);  hg=skl(16,40,f);  hb=skl(38,58,f); }
    // Civil twilight / blue hour.
    //
    // The horizon ran skl(55,195) / skl(32,95) / skl(68,118) — green BELOW
    // both red and blue at every point on the ramp. That is magenta, and it is
    // not a colour the sky is ever any part of; combined with the gradient
    // exponent above spreading it over the whole frame it is exactly the
    // uniform purple-maroon that -5 degrees came out as.
    //
    // The far end was also discontinuous with the golden-hour branch that
    // follows it: (195,95,118) pink here against (255,155,80) orange there,
    // switching at a = -0.83. On a timeline that is a visible jump between two
    // consecutive frames. It now lands on the same orange it hands over to.
    else if (a <= -0.83f) { float f=(a+6.0f)/5.17f;
        tr=skl(20,38,f);  tg=skl(30,48,f);  tb=skl(62,105,f);
        hr=skl(44,250,f); hg=skl(40,152,f); hb=skl(58,84,f); }
    else if (a <= 5.0f)   { float f=a/5.0f;              // golden hour
        tr=skl(38,70,f);  tg=skl(48,85,f);  tb=skl(105,165,f);
        hr=skl(255,255,f);hg=skl(155,205,f);hb=skl(80,125,f); }
    else if (a <= 14.0f)  { float f=(a-5.0f)/9.0f;       // morning/evening ramp
        tr=skl(70,48,f);  tg=skl(85,115,f); tb=skl(165,220,f);
        hr=skl(255,215,f);hg=skl(205,215,f);hb=skl(125,238,f); }
    else if (a <= 42.0f)  { float f=(a-14.0f)/28.0f;
        tr=skl(48,20,f);  tg=skl(115,130,f);tb=skl(220,238,f);
        hr=skl(215,172,f);hg=skl(215,208,f);hb=skl(238,242,f); }
    else                  { tr=20; tg=130; tb=238; hr=172; hg=208; hb=242; }

    float hk = h * h * (3.0f - 2.0f * h);
    float r = tr + (hr - tr) * hk, g = tg + (hg - tg) * hk, b = tb + (hb - tb) * hk;

    // aerosol haze: mild brown from pollution, red-orange from wildfire smoke
    float sm = smokeF;
    if (aqiF > 0.0f || sm > 0.0f) {
        float hz = (aqiF * 0.28f + sm * 0.40f) * powr(max(yFrac, 0.0f), 1.3f - sm * 0.55f) * skyBr(sAlt);
        float hzR = 150.0f + aqiF * 78.0f + sm * 52.0f;
        float hzG = 120.0f + aqiF *  6.0f - sm * 34.0f;
        float hzB =  82.0f - aqiF * 24.0f - sm * 40.0f;
        r += (hzR - r) * hz; g += (hzG - g) * hz; b += (hzB - b) * hz;
        float avg = (r + g + b) / 3.0f, ds = aqiF * 0.07f * (1.0f - sm);
        r += (avg - r) * ds; g += (avg - g) * ds; b += (avg - b) * ds;
    }
    // Cloud cover softens and blanches — toward a light overcast grey by day.
    // The target used to be a flat 198 at every hour, so an overcast midnight
    // sky was washed to the same pale grey as an overcast noon, and every trace
    // of hue went with it. Overcast at night is dark, and what light it does
    // have is the orange the city throws up at it.
    if (covF > 0.08f) {
        float ck = (covF - 0.08f) * 1.09f * 0.28f;
        float lit = skyBr(sAlt);
        float3 tgt = mix(float3(26.0f, 24.0f, 30.0f), float3(198.0f, 198.0f, 200.0f), lit);
        r += (tgt.r - r) * ck; g += (tgt.g - g) * ck; b += (tgt.b - b) * ck;
    }
    // Urban skyglow, at the horizon, through night and twilight.
    //
    // Two things were wrong with this and both showed. It began at 55% of the
    // frame height and ran to the bottom, so it painted nearly half the sky
    // orange — real skyglow is a horizon phenomenon, effectively gone more than
    // ten or fifteen degrees up, and spreading it that far is most of why a
    // clear midnight read as a sunset. And the altitude term was unclamped, so
    // deep night pushed the blend weight past 1 and overshot the target colour.
    //
    // Cloud AMPLIFIES skyglow rather than hiding it, which the old `1 - cov`
    // had exactly backwards. A low deck over a city is a reflector: it catches
    // the light going up and throws it back down. That is why the orange nights
    // are the overcast ones and a clear night over the same city is not.
    if (a < 2.0f && yFrac > 0.78f) {
        float reach = saturate((yFrac - 0.78f) / 0.22f);
        float lp = saturate((2.0f - a) / 22.0f) * reach * reach
                 * 0.34f * (0.65f + 0.90f * covF);
        r += (88.0f - r) * lp; g += (54.0f - g) * lp; b += (30.0f - b) * lp;
    }
    return float3(r, g, b);
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
inline float litDist(float dx, float dy, float r, float phase) {
    float f = (1.0f - cos(2.0f * M_PI_F * phase)) * 0.5f;
    float chord = sqrt(max(0.0f, 1.0f - (dy * dy) / (r * r)));
    float xt = r * cos(M_PI_F * f) * chord;
    return (phase < 0.5f) ? (dx - xt) : (-xt - dx);
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

// Map alt/az to screen using facing azimuth (roomstand.py:2352)
inline float2 astroXY(float alt, float az, float facing, float W, float H) {
    float relAz = fmod(az - facing + 180.0f + 360.0f, 360.0f) - 180.0f;
    return float2((0.5f + relAz / 190.0f) * W, (1.0f - alt / 85.0f) * H);
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

fragment float4 cellPass(VOut in [[stage_in]],
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
    if (ix >= COLS || iy >= ROWS) return float4(0);

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
            if (ww2 > w) { w = ww2; cr = 248.0f; cg = 250.0f; cb = 255.0f; }
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
    float lowAmt = 0.0f, lowD2 = 0.0f, lowK = 0.0f;
    float eY = edgeArr[ix];
    float lowFeather = max(H * 0.07f, SPv.y * 3.0f);
    if (eY > 0.0f) {
        lowK = saturate(0.5f + (eY - cyp) / (2.0f * lowFeather));
        lowK = lowK * lowK * (3.0f - 2.0f * lowK);
        // Depth into the deck, 1 at the solid top and falling through the
        // fringe. Drives the shading below, so the deck still lightens toward
        // its edge rather than being a slab of one tone.
        lowD2 = saturate(1.0f - cyp / max(eY + lowFeather, 1.0f));
        lowAmt = lowK * (0.45f + 0.55f * lowD2)
               * min(1.0f, 0.35f + covF) * nightCloudDim;
    }

    // How much of a body behind the cloud survives. Ice is thin and lets most
    // light through; a low deck is opaque and does not. This is what makes the
    // moon dim as cloud crosses it instead of punching through.
    float occlusion = saturate(1.0f - (1.0f - highAmt * 0.22f)
                                    * (1.0f - midAmt  * 0.78f)
                                    * (1.0f - lowAmt  * 0.97f));
    float seeThrough = 1.0f - occlusion;

    // Light that DOES get through scatters inside the cloud rather than
    // vanishing — the halo you see when the moon is behind thin cloud. Strong
    // through cirrus, almost nothing through a thick deck.
    float scatter = highAmt * 0.85f + midAmt * 0.35f + lowAmt * 0.06f;

    // sun — visible while above, or just below, the horizon
    if (sAlt > -1.5f) {
        float sunV = saturate((sAlt + 1.5f) / 3.0f);
        float dx = cxp - sunP.x, dy = cyp - sunP.y, d = sqrt(dx * dx + dy * dy);
        float glow = fexp(-d * invSunR) * uvAmp * sunDim * sunV * seeThrough;
        float ripSpeed = 0.15f + saturate(U.uv / 11.0f) * 0.25f;
        // The solar ripple — concentric arcs radiating from the sun. Wanted,
        // and deliberately at this wavelength: it is the shimmer, not the
        // banding. (I flattened it once looking for the vertical striping and
        // it was the wrong term entirely; that one is the mid-cloud sheet.)
        float rip = sin(d * 0.03f - sec * ripSpeed) * fexp(-d * invSunRip)
                  * uvAmp * sunDim * sunV * seeThrough;
        L += glow * 58.0f + (rip > 0.0f ? rip * 46.0f : 0.0f);
        float3 sc = sunTint(sAlt, aqiF);
        float ww = min(1.0f, (glow * 1.6f + (rip > 0.0f ? rip * 0.5f : 0.0f)) * sunDim);
        if (ww > w) { w = ww; cr = sc.r; cg = sc.g; cb = sc.b; }
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
            float moonLit = max(0.15f, U.moonIllum / 100.0f) * seeThrough;
            float v = moonSample(mx / moonR, my / moonR);
            float k = saturate((180.0f * moonLit + 20.0f) * moonDim * v / 255.0f);

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
            float earth = (14.0f + 16.0f * moonDim) * seeThrough;

            w  = mix(0.30f, 1.0f, litF);
            cr = mix( 96.0f, 236.0f * k, litF);
            cg = mix(102.0f, 240.0f * k, litF);
            cb = mix(124.0f, 252.0f * k, litF);
            L  = mix(earth, 255.0f * k, litF);
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
        float shade = min(210.0f, U.cbase * (0.78f + 0.30f * midN) + rim * 90.0f);
        float3 mc = cloudTint(sAlt, 0.55f + rim * 0.45f, shade);
        L += midAmt * (skyBrAmt > 0.5f ? 26.0f : 6.0f) + rim * 62.0f;
        float a = midAmt * 0.72f;
        cr += (mc.r - cr) * a; cg += (mc.g - cg) * a; cb += (mc.b - cb) * a;
        w = w + (1.0f - w) * a;
    }

    // Low: the dense deck hanging from the top.
    if (lowAmt > 0.0f) {
        float light = fexp(-sqrt(sgx * sgx + sgy * sgy) / (H * 0.5f));
        // The deck is thick, so only its ragged lower fringe transmits.
        float rim = 4.0f * lowAmt * (1.0f - lowAmt) * bodyLight * 0.55f;  // fringe law
        float shade = min(235.0f, U.cbase * (0.55f + 0.45f * (1.0f - lowD2))
                                * (0.75f + 0.55f * light) + rim * 70.0f);
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
        L *= 1.0f - under * under * 0.20f * U.cloudLow;
        // Scaled WITH `under`, which is 1 at the deck's edge and falls to 0
        // away from it. It was `(26 + 30 * (1 - under))` — maximal where
        // `under` is zero, so the further a cell sat from the deck the more
        // light the deck threw on it. That inverted falloff flooded the whole
        // lower frame with a flat achromatic lift and is what turned the bottom
        // two thirds of a daytime sky into featureless grey.
        L += U.cloudLow * skyBrAmt * 34.0f * under;
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
            L += kx * (U.kind == 4 ? 70.0f : 85.0f) * lit;
            float3 rc = (U.kind == 4) ? float3(240.0f, 246.0f, 255.0f)
                                      : float3(150.0f, 200.0f, 255.0f);
            rc = mix(rc, float3(252.0f, 250.0f, 245.0f), saturate(bodyLight * 0.8f));
            float a = kx * 0.75f;
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
    R0 = clamp(R0, 6.0f, 255.0f); G0 = clamp(G0, 8.0f, 255.0f); B0 = clamp(B0, 12.0f, 255.0f);
    float lum = (R0 + G0 + B0) * 0.333f;

    // ---- LUT base, sky ambient tint, weather tint, posterize
    float3 sky = skyRGB(U.sunAlt, float(iy) / U.rows, aqiF, covF, smokeF);
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

    return float4(clamp(g / 255.0f, 0.0f, 1.0f), lum / 255.0f);
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
//   flanks      the side faces are shaded from a single light direction, so one
//               side of every proud block is bright and the opposite side dark.
//   contact     where a block sits below its neighbour the crevice between them
//               darkens. That is occlusion, not a darker fill.
//
// It is solved by RAYCASTING the height field rather than approximating it.
// Blocks are constant-height columns on a unit grid, so the exact intersection
// is a 2D DDA: one step per cell boundary the ray crosses. The camera sits
// RELIEF_CAMD screen-widths away, which caps the lean at ~0.8 cells per unit
// height, so the ray crosses at most two boundaries and the loop is bounded at
// RELIEF_STEPS = 5 — typically breaking on the first or second. Every quantity
// below is in CELL PITCHES, in both axes and in height.

constant float RELIEF_MAX   = 0.85f;   // tallest block, in cell pitches
constant float RELIEF_CAMD  = 0.62f;   // camera distance, in screen widths
constant int   RELIEF_STEPS = 5;

/// Stable per-cell noise in -0.5..0.5. Used for splay; must not vary with time
/// or the whole wall shimmers.
inline float cellJit(float2 ci, float salt) {
    return fract(sin(dot(ci, float2(12.9898f, 78.233f)) + salt) * 43758.5453f) - 0.5f;
}

/// Height of one block, in cell pitches. Bright stands proud.
///
/// The 0.65 exponent lifts the bottom of the range: a night sky is nearly
/// black, and a straight luminance mapping would flatten the wall to nothing
/// the moment the sun set. Relief is the look; it should survive the dark.
inline float cellHeight(texture2d<float> cells, sampler s, float2 ci,
                        float cols, float rows, float hmax, float splay)
{
    float2 cc = clamp(ci, float2(0.0f), float2(cols - 1.0f, rows - 1.0f));
    float  h  = powr(saturate(cells.sample(s, cc + 0.5f).a), 0.65f) * hmax;
    // Splay unsettles the courses so the blocks are not a perfectly graded set.
    if (splay > 0.001f) h *= 1.0f + cellJit(cc, 0.0f) * splay * 0.55f;
    return max(h, 0.0f);
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

inline Relief castRelief(texture2d<float> cells, sampler s, float2 g,
                         float cols, float rows, float hmax, float splay)
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
        float H  = cellHeight(cells, s, ci, cols, rows, hmax, splay);
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
                        bool flank, float2 lightDir, float rot, float splay)
{
    if (rot != 0.0f) {
        float cs = cos(rot), sn = sin(rot);
        float2 d = cuv - 0.5f;
        cuv = 0.5f + float2(d.x * cs - d.y * sn, d.x * sn + d.y * cs);
    }
    if (shape == 1) {
        // ---- dots: SDF circle, radius from cell luminance (roomstand.py:2587)
        float ln = saturate(lum);
        float dotR = (0.24f + ln * 0.46f) * (0.90f + 0.10f * sin(time * 0.9f + phase * 6.28f));
        float d = length(cuv - 0.5f);
        float aa = 0.5f / cellPx;                 // half-pixel feather, no aliasing
        float m = 1.0f - smoothstep(dotR - aa, dotR + aa, d);
        col *= m;
        if (finish == 0) {                        // glass dots pick up a lens highlight
            float hl = saturate(1.0f - length(cuv - float2(0.38f, 0.36f)) / 0.30f);
            col += hl * hl * 0.16f * m;
        }
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
            // Flat: grout gaps, no rim. The relief supplies the depth.
            if (m > in0 - 0.08f) col *= 0.42f;
        }
    }
    return col;
}

fragment float4 presentPass(VOut in [[stage_in]],
                            constant Uniforms &U     [[buffer(0)]],
                            constant Star     *stars [[buffer(2)]],
                            texture2d<float>   cells [[texture(0)]],
                            texture2d<float>   glass [[texture(1)]],
                            texture2d<float>   streakFine [[texture(2)]])
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
    Relief rel  = castRelief(cells, nearestS, px / SPv, U.cols, U.rows, hmax, U.splayAmt);

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
        float2 base = float2(cid) + 0.5f + rel.lean * (U.refractAmt * rel.h * 3.0f);
        float2 lim  = float2(U.cols, U.rows) - 0.5f;
        float3 t;
        if (U.dispersAmt > 0.005f) {
            // Split along the view lean itself, so the fringe vanishes at the
            // frame centre — where there is no angle, there is no dispersion.
            float2 dv = normalize(rel.lean + 1e-6f) * (U.dispersAmt * 1.6f);
            t = float3(cells.sample(nearestS, clamp(base + dv, 0.5f, lim)).r,
                       cells.sample(nearestS, clamp(base,      0.5f, lim)).g,
                       cells.sample(nearestS, clamp(base - dv, 0.5f, lim)).b);
        } else {
            t = cells.sample(nearestS, clamp(base, 0.5f, lim)).rgb;
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
        // Which cells are moon at all was settled by the coarse pass, so the
        // limb stays as chunky as the rest of the grid. Here we only ask, per
        // cell: does the surface vary across it? Flat highlands stay one chunk.
        // A mare edge or the terminator running through a cell breaks it down,
        // as far as that particular cell needs and no further.
        if (U.moonAlt > 0.0f && U.sunAlt < 0.0f) {
            float2 dcen = (cid + 0.5f) * SPv - moonP;
            if (dot(dcen, dcen) < moonR * moonR && litSide(dcen.x, dcen.y, moonR, U.moonPhase)) {
                float vCell = max(moonSample(dcen.x / moonR, dcen.y / moonR), 0.05f);

                // Sample the source at the cell's corners. Corners outside the
                // disc fall back to the centre value, so the limb does not
                // register false contrast and split for no reason.
                float lo = vCell, hi = vCell;
                bool litAll = true, litAny = false;
                for (int k = 0; k < 4; ++k) {
                    float2 cp = (cid + float2(float(k & 1), float((k >> 1) & 1))) * SPv - moonP;
                    float v = (dot(cp, cp) <= moonR * moonR)
                            ? moonSample(cp.x / moonR, cp.y / moonR) : vCell;
                    lo = min(lo, v); hi = max(hi, v);
                    bool l = litSide(cp.x, cp.y, moonR, U.moonPhase);
                    litAll = litAll && l; litAny = litAny || l;
                }
                // A terminator crossing the cell is maximum contrast: that edge
                // carries the entire phase, so it always earns a breakdown.
                float contrast = (litAny && !litAll) ? 1.0f : (hi - lo);

                int depth = detailDepth(contrast, 0.05f, SP, 4.0f, 6);
                if (depth > 1) {
                    dc = splitCell(px, SPv, depth);
                    float2 ds = (dc.id + 0.5f) * dc.sizev - moonP;
                    // Sub-cells outside the disc inherit the parent wholesale, so
                    // a limb cell stays one full square and the outline gains no
                    // resolution. They must also skip the terminator test below:
                    // outside the disc the chord collapses to zero, every such
                    // sub-cell reads as unlit, and the limb turns black.
                    bool subInside = dot(ds, ds) <= moonR * moonR;
                    float vSub = subInside ? moonSample(ds.x / moonR, ds.y / moonR) : vCell;
                    // Brightness as a RATIO against what the coarse cell already
                    // used, so a split cell averages back to what was there. That
                    // is what leaves no seam against an unsplit neighbour.
                    float ratio = vSub / vCell;
                    if (subInside) {
                        // The coarse cell already carries a coverage-blended
                        // terminator, so this has to be the RATIO of the
                        // sub-cell's coverage to the cell's — not an absolute
                        // darkening, which would apply the phase twice. Being a
                        // ratio is also what makes a split cell average back to
                        // the unsplit one, so there is no seam against a
                        // neighbour that did not subdivide.
                        //
                        // This is the "bit by bit" part: the cell says roughly
                        // how much of it is in shadow, and the subdivision says
                        // where inside it the edge actually runs.
                        float litSub = saturate(
                            0.5f + litDist(ds.x, ds.y, moonR, U.moonPhase)
                                 / max(dc.size, 1.0f));
                        float litCell = saturate(
                            0.5f + litDist(dcen.x, dcen.y, moonR, U.moonPhase)
                                 / max(SP, 1.0f));
                        ratio *= mix(0.16f, 1.0f, litSub)
                               / max(mix(0.16f, 1.0f, litCell), 1e-3f);
                    }
                    if (false) {
                        // Darken by how much dark side is actually THERE, not by
                        // which side of the line the centre fell on.
                        //
                        // The dark crescent is bounded by two curves, the
                        // terminator and the limb, and near a gibbous phase they
                        // run together — the crescent is a hairline. Testing
                        // against the terminator alone means every sub-cell along
                        // the limb registers as "past the line" and gets the full
                        // treatment, which is the speckled ring: a 0.1%-wide
                        // feature rendered three pixels thick.
                        //
                        // Distance past the terminator AND distance inside the
                        // limb, whichever is smaller, is the local width of the
                        // crescent. Measured against the sub-cell, that is the
                        // fraction of it that is genuinely unlit.
                        float sd = litDist(ds.x, ds.y, moonR, U.moonPhase);
                        float ld = moonR - length(ds);
                        float dark = saturate(min(-sd, ld) / max(dc.size, 1.0f));
                        ratio *= mix(1.0f, 0.16f, dark);
                    }
                    col *= ratio;
                    lum *= ratio;
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

    // ---- One light for the whole field.
    //
    // Screen axes, +y down. The angle is where the light comes FROM, measured
    // the way a design tool's angle dial reads it: 0 from the right, positive
    // turning anticlockwise, so the -45 the reference panel showed puts it up
    // and to the left and lights the top-left flank of every proud block.
    float la = U.lightAngle * (3.14159265f / 180.0f);
    float2 L = float2(-cos(la), sin(la));
    float  I = U.lightInt;

    // On a flank, drop the across-axis coordinate to the middle of the face.
    // A dot then extrudes as a cylinder rather than as a sliver of its own rim.
    float2 suv = dc.uv;
    if (rel.flank) { if (rel.axis == 0) suv.x = 0.5f; else suv.y = 0.5f; }

    float rot = U.splayAmt * cellJit(rel.cell, 4.7f) * 0.22f;
    col = styleCell(col, suv, dc.size, lum, phase, U.time, U.shape, U.finish,
                    rel.flank, L, rot, U.splayAmt);

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
                float hn = cellHeight(cells, nearestS, rel.cell + o,
                                      U.cols, U.rows, hmax, U.splayAmt);
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
