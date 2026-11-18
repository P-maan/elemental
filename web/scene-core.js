/* Elemental scene core: sky, sun/moon/stars/planets, clouds, mosaic. Ported from the wall page. */
const scene=$("scene"), sctx=scene.getContext("2d");
const waveCanvas=null, wctx=null;
let scKind="", scDay=1, scCover=50, scCode=0, scUV=6, lastScene=0;
let scWind=0, scPrecip=0, scRain=0, scSnow=0, scVis=10000, scHumid=50;
let scTempC=null;
let scWindDir=180, scPressure=1013, scPrecipProb=0, scAQI=0, scSmoke=0;
// Aerosol optical depth. Measured, fetched all along, and until now thrown
// away after the smoke test. It is the honest input for skyglow: the same
// streetlights make a far brighter dome through dirty air than clean.
let scAOD=0;
/* ===== Ported from Elemental (24 Sep) ==========================================
   Cloud by altitude, depth-correct compositing, scattering through cloud, the
   lunar eclipse, and the physically based clear sky. Formulas are Elemental's
   (Core/Scene.metal, Core/Astro.swift); see that repo for the derivations. */
let scCldLo=null, scCldMid=null, scCldHi=null;      // cover by altitude, %, from Open-Meteo
function _c01(v){ return v<0?0:(v>1?1:v); }
// Astro.lunarEclipseDepth: FULL moon AND near a node; 0 none .. 1 total.
function _lunarEclipse(ms, moonAlt){
  if(!(moonAlt>-2)) return 0;
  const d=ms/86400000+2440587.5-2451545.0;
  const D=((297.8501921+12.19074911*d)%360+360)%360;
  const F=((93.2720950+13.22935024*d)%360+360)%360;
  let fromFull=Math.abs((((D-180)%360)+540)%360-180); fromFull=Math.min(fromFull,360-fromFull);
  if(fromFull>=2.4) return 0;
  const beta=Math.abs(5.1454*Math.sin(F*Math.PI/180)); if(beta>=1.7) return 0;
  return _c01((1.7-beta)/1.1)*_c01((2.4-fromFull)/1.6);
}
// Kasten & Young (1989) relative airmass.
function _airmassKY(zd){ const z=Math.min(zd,91.5); return 1/(Math.cos(z*Math.PI/180)+0.50572*Math.pow(96.07995-z,-1.6364)); }
const _TAUR=[0.0683,0.0973,0.2213], _LUMW=[0.2126,0.7152,0.0722];
// Single-scattering airlight per sRGB primary; [r,g,b,rayleighFraction].
function _airlight(sunAlt,viewAlt,cosG,tauA){
  const alpha=1.3/(1+2.2*tauA);
  const r0=Math.pow(0.600,-alpha), r1=Math.pow(0.550,-alpha), r2=Math.pow(0.450,-alpha);
  const tA=[tauA*r0/r1, tauA, tauA*r2/r1];
  const mV=_airmassKY(90-viewAlt), mS=_airmassKY(90-Math.max(sunAlt,0));
  const f=0.35+0.65*Math.pow(1-_c01(viewAlt/90),2), mSe=Math.max(0.25,mS*f);
  const pR=0.75*(1+cosG*cosG), g=0.76;
  const den=Math.pow(Math.max(1+g*g-2*g*cosG,1e-4),-1.5);
  const pM=Math.min(1.5*(1-g*g)/(2+g*g)*(1+cosG*cosG)*den,6);
  const o=[0,0,0,0];
  for(let i=0;i<3;i++){ const tau=_TAUR[i]+tA[i];
    o[i]=Math.max(Math.exp(-tau*mSe)*((_TAUR[i]*pR+tA[i]*pM)/tau)*(1-Math.exp(-tau*mV)),1e-6); }
  o[3]=_TAUR[1]*pR/Math.max(_TAUR[1]*pR+tA[1]*pM,1e-6);
  return o;
}
// Elemental skyRGB: scattering chroma x the verified brightness ramp, then
// night floor, twilight bands (Lynch et al. 2017), smoke/AQI, the deck, skyglow.
// Hybrid sky (24 Sep): the display's calibrated table for the base colour, with
// Elemental's physically derived STRUCTURE on top - the parts the table could
// not express because it only knew height, not direction.
/* ==== Elemental's sky, ported 1 Oct (Scene.metal skyRGB + airlight) =========
   He wants the wall to look like HIS Elemental. Dormstand still coloured the
   sky from roomstand's old table (fixed zenith/horizon colours per sun angle,
   an overcast blended in linearly) with a few Elemental effects on top; on a
   low sun under a mid deck that came out flat grey and DARKER toward the
   horizon, where Elemental goes bright and gold. This is Elemental's model:
   single-scattering airlight (Rayleigh + aerosol, Kasten-Young air mass,
   Henyey-Greenstein forward lobe), its chroma purification, twilight terms,
   and the SUPERLINEAR deck blend - drawn^2.2 - so blue survives in the gaps.
   Same inputs as _skyPhys; _skyPhys stays in the file as the fallback. */
const _ETAUR=[0.0683,0.0973,0.2213], _ELUMW=[0.2126,0.7152,0.0722];
function _eSkBr(a){ if(a<=-18)return 0.04; if(a<=-6)return 0.04+0.14*(a+18)/12; if(a<=0)return 0.18+0.28*(a+6)/6;
  if(a<=6)return 0.46+0.36*a/6; if(a<=22)return 0.82+0.18*(a-6)/16; return 1; }
function _eAmKY(z){ z=Math.min(z,91.5); return 1/(Math.cos(z*Math.PI/180)+0.50572*Math.pow(96.07995-z,-1.6364)); }
function _skyE(sAlt,yFrac,dAz,aqiF,deckF,smokeF,gloomF,tauA){
  const D=Math.PI/180, sat=x=>x<0?0:x>1?1:x;
  const viewAlt=85*(1-sat(yFrac)), sa=sAlt*D, va=viewAlt*D;
  const cosG=Math.max(-1,Math.min(1,Math.sin(va)*Math.sin(sa)+Math.cos(va)*Math.cos(sa)*Math.cos(dAz*D)));
  // airlight
  const alpha=1.3/(1+2.2*tauA), rel=[Math.pow(0.6,-alpha),Math.pow(0.55,-alpha),Math.pow(0.45,-alpha)];
  const tA=[tauA*rel[0]/rel[1], tauA, tauA*rel[2]/rel[1]], tau=[_ETAUR[0]+tA[0],_ETAUR[1]+tA[1],_ETAUR[2]+tA[2]];
  const mV=_eAmKY(90-viewAlt), mS=_eAmKY(90-Math.max(sAlt,0)), f=0.35+0.65*Math.pow(1-sat(viewAlt/90),2), mSe=Math.max(0.25,mS*f);
  const pR=0.75*(1+cosG*cosG), g=0.76;
  const den=Math.pow(Math.max(1+g*g-2*g*cosG,1e-4),-1.5);
  const pM=Math.min(1.5*(1-g*g)/(2+g*g)*(1+cosG*cosG)*den,6);
  let al=[0,0,0];
  for(let k=0;k<3;k++){ const beam=Math.exp(-tau[k]*mSe), ph=(_ETAUR[k]*pR+tA[k]*pM)/tau[k], sv=1-Math.exp(-tau[k]*mV); al[k]=Math.max(beam*ph*sv,1e-6); }
  const rayFrac=_ETAUR[1]*pR/Math.max(_ETAUR[1]*pR+tA[1]*pM,1e-6);
  const lum=c=>c[0]*_ELUMW[0]+c[1]*_ELUMW[1]+c[2]*_ELUMW[2];
  let Lal=Math.max(lum(al),1e-6), ch=[al[0]/Lal,al[1]/Lal,al[2]/Lal];
  const upper=sat(viewAlt/35), antiSide=sat(-Math.cos(dAz*D)), lowLit=(1-upper)*(1-antiSide);
  const below=sat((1.5-sAlt)/5.5)*(1-0.72*lowLit);
  const bl=[0.798,1.012,1.478]; for(let k=0;k<3;k++) ch[k]=ch[k]+(bl[k]-ch[k])*below;
  const pureK=1+2.2*Math.max(Math.max(rayFrac,0.35),below*0.95);
  for(let k=0;k<3;k++) ch[k]=Math.pow(Math.max(ch[k],1e-4),pureK);
  let Lc=Math.max(lum(ch),1e-6); ch=ch.map(v=>v/Lc);
  ch[1]=Math.min(ch[1],Math.max(ch[0],ch[2])); Lc=Math.max(lum(ch),1e-6); ch=ch.map(v=>v/Lc);
  const lit=_eSkBr(sAlt), hk=yFrac*yFrac*(3-2*yFrac);
  const Lz=6+112*lit, Lh=9+196*Math.pow(lit,0.78), L=Lz+(Lh-Lz)*hk;
  let c=[ch[0]*L,ch[1]*L,ch[2]*L];
  const mix=(a,b,t)=>{ for(let k=0;k<3;k++) a[k]=a[k]+(b[k]-a[k])*t; };
  const night=sat((-12-sAlt)/6);
  if(night>0) mix(c,[3+4*hk,5+4*hk,14+6*hk],night);
  if(sAlt<4){
    const tw=sat((4-sAlt)/10)*sat((sAlt+16)/8), side=Math.cos(dAz*D), anti=sat(-side), solar=sat(side);
    const shadowTop=Math.max(0,Math.min(70,-8*sAlt)), dB=(viewAlt-shadowTop)/15;
    const belt=Math.min(1,1.6*Math.exp(-dB*dB*(dB>0?1:2.2))*anti*tw*sat((sAlt+6)/4));
    mix(c,[1.00*L*1.12,0.74*L*1.12,0.78*L*1.12],belt);
    const dark=sat((shadowTop-viewAlt)/Math.max(shadowTop,8))*anti*tw*sat((sAlt+11)/7);
    mix(c,[0.68*L*0.62,0.77*L*0.62,1.00*L*0.62],dark*0.60);
    const low=sat(1-viewAlt/28), glow=solar*tw*low*low*sat((sAlt+9)/7), wt=sat((sAlt+6)/8);
    mix(c,[1.00*L*1.15,(0.34+0.28*wt)*L*1.15,(0.16+0.14*wt)*L*1.15],glow*0.82);
  }
  if(smokeF>0){ const sm=sat(smokeF*(0.35+0.65*hk)); c[0]*=1+0.12*sm; c[1]*=1-0.28*sm; c[2]*=1-0.58*sm; }
  if(aqiF>0){ const ds=aqiF*0.16*(1-smokeF), avg=(c[0]+c[1]+c[2])/3; mix(c,[avg*1.05,avg,avg*0.92],ds); }
  // the deck: superlinear over what the cloud pass draws, full weight for what only the gloom knows
  const opaque=Math.max(deckF,sat((gloomF-0.06)/0.30));
  if(opaque>0.06){
    const t=sat((opaque-0.06)/0.94), drawn=sat((Math.min(deckF,opaque)-0.06)/0.94), unseen=Math.max(0,t-drawn);
    const ck=sat(Math.pow(drawn,2.2)*0.97+unseen*0.97), thick=t*t;
    const day=[216+(148-216)*thick,217+(150-217)*thick,220+(157-220)*thick];
    const n2=[30+(19-30)*thick,28+(18-28)*thick,34+(23-34)*thick];
    const tg=[n2[0]+(day[0]-n2[0])*lit,n2[1]+(day[1]-n2[1])*lit,n2[2]+(day[2]-n2[2])*lit];
    const m=(1-0.22*gloomF)*(1.05-0.17*hk); mix(c,[tg[0]*m,tg[1]*m,tg[2]*m],ck);
  }
  if(sAlt<2 && yFrac>0.78){
    const reach=sat((yFrac-0.78)/0.22), lp=sat((2-sAlt)/22)*reach*reach*0.34*(0.65+0.90*opaque);
    mix(c,[88,54,30],lp);
  }
  return {r:Math.max(0,Math.min(255,c[0]))|0, g:Math.max(0,Math.min(255,c[1]))|0, b:Math.max(0,Math.min(255,c[2]))|0};
}
function _skyPhys(sAlt,yFrac,dAz,aqiF,deckF,smokeF,gloomF,tauA){
  const base=_skyRGB(sAlt,yFrac,aqiF,deckF,smokeF);
  let r=base.r, g=base.g, b=base.b;
  const L=Math.max(1,0.299*r+0.587*g+0.114*b), D2R=Math.PI/180;
  const viewAlt=85*(1-_c01(yFrac)), side=Math.cos(dAz*D2R), anti=_c01(-side), solar=_c01(side);
  const hk=yFrac*yFrac*(3-2*yFrac);
  // 1. The warm horizon belongs to the SUN'S side. The table painted golden
  //    hour all the way round; opposite the sun the low sky is cool and pale
  //    (single scattering there has no reddened beam to scatter).
  if(sAlt>-6 && sAlt<16){
    const warm=_c01((16-sAlt)/14)*_c01((sAlt+6)/4)*_c01((yFrac-0.35)/0.65);
    const k=warm*anti*0.75;
    r+=(L*0.90-r)*k; g+=(L*0.98-g)*k; b+=(L*1.16-b)*k;
  }
  // 2. Twilight bands (Lynch, Dearborn & Lock 2017, via Elemental).
  if(sAlt<4){
    const tw=_c01((4-sAlt)/10)*_c01((sAlt+16)/8);
    const shadowTop=Math.max(0,Math.min(70,-8*sAlt)), dBelt=(viewAlt-shadowTop)/15;
    // Belt of Venus: pale PINK (red > blue > green), just above the shadow.
    const belt=Math.min(1,1.6*Math.exp(-dBelt*dBelt*(dBelt>0?1:2.2))*anti*tw*_c01((sAlt+6)/4))*0.55;
    r+=(1.00*L*1.25-r)*belt; g+=(0.74*L*1.25-g)*belt; b+=(0.80*L*1.25-b)*belt;
    // The earth's shadow on the air: bluish-grey, darker than around it.
    const dark=_c01((shadowTop-viewAlt)/Math.max(shadowTop,8))*anti*tw*_c01((sAlt+11)/7)*0.45;
    r+=(0.70*L*0.72-r)*dark; g+=(0.78*L*0.72-g)*dark; b+=(1.00*L*0.72-b)*dark;
    // Sun-side afterglow: deepest at the horizon, reddening as the sun sinks.
    const low=_c01(1-viewAlt/28), glow=solar*tw*low*low*_c01((sAlt+9)/7)*0.80, wk=_c01((sAlt+6)/8);
    const gl=Math.max(L,70);
    r+=(1.00*gl*1.2-r)*glow; g+=((0.34+0.28*wk)*gl*1.2-g)*glow; b+=((0.16+0.14*wk)*gl*1.2-b)*glow;
  }
  // 3. Haze whitens the horizon: aerosol scattering is barely selective, and
  //    the long low path saturates every channel (measured AOD, not a guess).
  const hz=_c01((tauA-0.08)/0.5)*hk*0.45*_c01((sAlt+4)/10);
  if(hz>0){ const wv=Math.max(r,g,b); r+=(wv*0.97-r)*hz; g+=(wv*0.98-g)*hz; b+=(wv-b)*hz; }
  return {r:Math.max(0,Math.min(255,r))|0, g:Math.max(0,Math.min(255,g))|0, b:Math.max(0,Math.min(255,b))|0};
}
let _skyCR=null,_skyCG=null,_skyCB=null,_skyLL=null, _stA=null; const _skyTmp={cR:1,cG:1,cB:1,L:4};   // _stA: per-cell seeThrough, for the detail passes
// Pi facing direction: 0=North, 90=East, 180=South, 270=West
let FACING_AZ=90;  // 0=N 90=E 180=S 270=W
let astroNow={sunAlt:45,sunAz:180,moonAlt:30,moonAz:90,moonIllum:50,moonPhaseN:"",moonAge:0};
let SP=12, COLS=0, ROWS=0, dotPh=null, breathers=[];
let GRID_ROWS=(typeof window.__ELWS.gridRows==="number"&&window.__ELWS.gridRows>=12)?Math.round(window.__ELWS.gridRows):54;                       // his grid; was 36
let GRID_K=GRID_ROWS/36;                // rows-per-36, for anything tuned in the old rows
// The mosaic is ambient - weather, sun, moon - and nothing in it moves fast
// enough to need 60Hz. The clock, the countdown and the scrolling text do.
// They used to share one gate, so the cheapest thing on screen ran at the
// speed of the most expensive. Now the scene keeps its own slower clock and
// everything else gets every frame.
const SCENE_DT = 1/24;
let _sceneAcc = 0;
/* Whether the circuit is drawn at the size that makes a car legible. The big
   box is 1.6x the per-frame fine-cell work (see buildTrackFine, which also
   records why an fps figure for it could NOT be pinned down on the Pi), so it
   is held only while there are cars on it to read. Declared up here with the
   other circuit state because buildTrackFine() reads it. */
// How much of the sky's own brightness lights the mosaic, at full daylight.
// Tuned to hold the pre-change daytime level (mean luma ~96 at 13:00, 30%
// cover) while leaving the night to the chroma path.
const SKY_LIGHT=0.62;
let f1BigTrack=false;
let f1weekActive=false, f1TrackRaw=null, trackScreen=null, trackField=null, trackElev=null, trackT=null, trackShadow=null;
let trackC0=0, trackC1=0, trackR0=0, trackR1=0;
let _f1sig="";
let fCanvas=null, fCtx=null, fImg=null, fGlow=null, fElev=null, fParam=null, fShadow=null, fBed=null, fBevel=null, fFade=null, fLevel=null, fCols=0, fRows=0, fN=8, fCX0=0, fCY0=0, fCX1=0, fCY1=0, _fineAcc=0;
let _mSky=[120,132,158], _mSkyTs=-9999;
function _readSky(){ return; /* _mSky is kept current by drawScene now */ try{ const v=getComputedStyle(document.documentElement).getPropertyValue('--sky-bot'); const m=v&&v.match(/(\d+)\D+(\d+)\D+(\d+)/); if(m) _mSky=[+m[1],+m[2],+m[3]]; }catch(_){}} 
const trackBox={x0:0.26, y0:0.07, x1:0.66, y1:0.56};
let RES=0.5; // tuned on the Pi (Pi 4B, ASUS 2560x1440 panel). The stock 0.5
          // assumed a 1080p panel; this display is larger, so the mosaic
          // costs more per frame than the original tuning expected.
          // assumed a 1080p panel; this display is larger, so the mosaic
          // costs more per frame than the original tuning expected.
          // assumed a 1080p panel; this display is larger, so the mosaic
          // costs more per frame than the original tuning expected.
let POSTER=16; // mosaic colour-step (higher=chunkier blocks)
let streaks=[], bolt=null, flashT=-9, nextBolt=0;
let shootT=1e9, shoot=null, _skyBgTs=0;

/* The wall's settings, written into the page by the server (/v1/config, the the host Hub). Missing = default. */
const WS=window.__ELWS;
let STYLE=(WS.style==="dots")?"dots":"glass";
let bevel=null, cell=null, cctx=null, cimg=null, edgeArr=null, sceneCol=null;
// album art grid + waveform state
let artGrid=null, hasArtGrid=false;
let curBars=new Float32Array(96), tgtBars=new Float32Array(96), barLen=0, lastBarMsg=0, esRef=null;
let prevFrame=0;
const HR=new Uint8ClampedArray(256),HG=new Uint8ClampedArray(256),HB=new Uint8ClampedArray(256);
(function(){
  const st=[[0,6,6,12],[0.35,95,95,110],[0.60,175,175,192],[0.82,235,235,247],[1,255,255,255]];
  for(let i=0;i<256;i++){const t=i/255;let a=st[0],b=st[st.length-1];
    for(let k=0;k<st.length-1;k++){if(t>=st[k][0]&&t<=st[k+1][0]){a=st[k];b=st[k+1];break;}}
    const u=(t-a[0])/((b[0]-a[0])||1);
    HR[i]=a[1]+(b[1]-a[1])*u; HG[i]=a[2]+(b[2]-a[2])*u; HB[i]=a[3]+(b[3]-a[3])*u;}
})();
// pre-computed sin/cos tables for fast lookups
const SIN_TAB=new Float32Array(4096), COS_TAB=new Float32Array(4096);
for(let i=0;i<4096;i++){const a=i/4096*6.2831853; SIN_TAB[i]=Math.sin(a); COS_TAB[i]=Math.cos(a);}
/* ==== Elemental 0.4-0.6.1, ported 27 Sep ===================================
   Cloud STRUCTURE (Elemental 0.5.1, "an overcast that does not repeat"): every
   cloud layer's texture was a sum of two or three sines, and a sum of sines is
   periodic - on a closed sky it tiled into a camouflage print of identical
   blobs. Now value-noise fBm with a domain warp, sampled on the cloud BASE (a
   horizontal plane seen from under it, in the frame's own 85 x 190 degree
   mapping): broad overhead, receding into flat streaks toward the horizon,
   stretched along the wind and carried by it. Hoskins' hash12 in its full
   three-component form - the 2-D shortcut draws diagonal stripes. */
function _dHash(x,y){
  let a=x*0.1031, b=y*0.1031, c=a; a-=Math.floor(a); b-=Math.floor(b); c-=Math.floor(c);
  const d=a*(b+33.33)+b*(c+33.33)+c*(a+33.33); a+=d; b+=d; c+=d;
  const v=(a+b)*c; return v-Math.floor(v);
}
function _dNoise(x,y){
  const ix=Math.floor(x), iy=Math.floor(y); let fx=x-ix, fy=y-iy;
  fx=fx*fx*(3-2*fx); fy=fy*fy*(3-2*fy);
  const a=_dHash(ix,iy), b=_dHash(ix+1,iy), c=_dHash(ix,iy+1), d=_dHash(ix+1,iy+1);
  return a+(b-a)*fx+(c-a)*fy+(a-b-c+d)*fx*fy;
}
/* Four octaves, rotated between octaves so no grid axis survives. ~-0.5..0.5. */
function _dFBM(x,y){
  let s=0, a=0.5, n=0;
  for(let i=0;i<4;i++){
    s+=a*(_dNoise(x,y)-0.5); n+=a;
    const nx=(0.80*x-0.60*y)*2.03+17.1, ny=(0.60*x+0.80*y)*2.03+9.2; x=nx; y=ny; a*=0.5;
  }
  return s/n*1.6;
}
/* Cloud structure at a screen position on a layer `base` high; `scale` is the
   feature size on that layer, `stretch` how much longer along the wind. */
function _deckField(x,y,W,H,base,scale,stretch,windDir,wind,sec){
  const DEG=0.01745329;
  const alt=(1-y/Math.max(H,1))*85, az=(FACING_AZ+(x/Math.max(W,1)-0.5)*190)*DEG;
  const d=base/Math.tan(Math.max(alt,2.5)*DEG);
  let px=d*Math.sin(az), py=d*Math.cos(az);
  const wd=(windDir+180)*DEG, dx=Math.sin(wd), dy=Math.cos(wd);    // carried downwind
  const drift=sec*0.00015*Math.max(wind,3)*base; px-=dx*drift; py-=dy*drift;
  const qx=(px*dx+py*dy)/stretch/scale, qy=(px*dy-py*dx)/scale;
  const wx=_dFBM(qx*0.5+3.1,qy*0.5+3.1), wy=_dFBM(qx*0.5+7.7,qy*0.5+7.7);
  const sm=Math.max(0,Math.min(1,(alt-2)/14));
  return _dFBM(qx+1.1*wx,qy+1.1*wy)*sm*sm*(3-2*sm);
}
/* ONE wind for everything (Elemental 0.6): km/h ACROSS the screen, positive to
   the right. Wind is reported as where it comes FROM, so it carries things
   toward windDir+180, and the sky's azimuth increases to the right. The rain's
   slant had this backwards here too, and the water on the glass always ran
   right whatever the wind did. */
function crossWindKmh(){ return (scWind||0)*Math.sin(((scWindDir||0)+180-FACING_AZ)*0.01745329); }
/* Twilight light on a cloud (Elemental): high ice sees the sun for ~8.5 deg
   after the ground loses it, a low deck ~3.3. x = lit, y = reddened. */
function _twLit(sAlt,highness){
  const linger=1.5+7*Math.max(0,Math.min(1,highness));
  return [Math.max(0,Math.min(1,(sAlt+linger)/(linger+2))), Math.max(0,Math.min(1,1-(sAlt+2)/12))];
}
/* The colour low sunlight has by the time it reaches a cloud: orange while the
   sun is up, salmon at the horizon, magenta below it. */
function _twColour(sAlt){
  const k=Math.max(0,Math.min(1,1-(sAlt+2)/12)), m=Math.max(0,Math.min(1,-sAlt/6));
  const r=255, g=214+(146-214)*k, b=170+(138-170)*k;
  return {r:r+(206-r)*m, g:g+(116-g)*m, b:b+(152-b)*m};
}
/* Cloud fields cached per cell and refreshed a slice of rows per scene: the
   clouds drift over minutes, so every cell every scene would be wasted work on
   the Pi. */
let _dfHi=null, _dfMid=null, _dfLo=null, _dfRow=0;
function _deckRefresh(W,H,sec,hi,mid,lo){
  const N=COLS*ROWS;
  if(!_dfHi||_dfHi.length!==N){ _dfHi=new Float32Array(N); _dfMid=new Float32Array(N); _dfLo=new Float32Array(N); _dfRow=0; }
  const rows=_dfRow===0&&!_deckRefresh._warm ? ROWS : Math.max(1,Math.ceil(ROWS/6));
  _deckRefresh._warm=true;
  for(let k=0;k<rows;k++){
    const iy=_dfRow; _dfRow=(_dfRow+1)%ROWS;
    const y=(iy+0.5)*SP;
    for(let ix=0;ix<COLS;ix++){
      const x=(ix+0.5)*SP, i=iy*COLS+ix;
      _dfHi[i]=hi?_deckField(x,y,W,H,8.0,2.6,4.5,scWindDir,Math.max(scWind,12),sec+900):0;
      _dfMid[i]=mid?_deckField(x,y,W,H,3.0,1.3,2.4,scWindDir,scWind,sec+400):0;
      _dfLo[i]=lo?_deckField(x,y,W,H,1.0,0.55,1.7,scWindDir,scWind,sec):0;
    }
  }
}
/* Degree-hour melt (Elemental 0.6, "snow that stays"): lying snow was going
   ~100x too fast - a full cap in a minute. Cells of depth lost per second. */
function _snowLoss(tC,uv,wind,evap,raining){
  let melt=Math.max(0,tC)*0.000055*(1+Math.min(1.5,wind/30))+Math.max(0,uv-1)*0.00005*(tC>-2?1:0);
  if(raining&&tC>0) melt*=2.2;
  return melt+0.000012*(0.3+evap*2);
}
function fsin(x){const i=((x%6.2831853+6.2831853)%6.2831853)*651.8986|0; return SIN_TAB[i&4095];}
function fcos(x){const i=((x%6.2831853+6.2831853)%6.2831853)*651.8986|0; return COS_TAB[i&4095];}
// fast approximate exp for values in [-8,0] range
function fexp(x){if(x<-6)return 0; const t=1+x/32; return t*t*t*t*t*t*t*t*t*t*t*t*t*t*t*t*t*t*t*t*t*t*t*t*t*t*t*t*t*t*t*t;}
/* moonPhase() lived here: a mean-synodic approximation off Date.now(), and a
   second phase model that disagreed with the astronomical engine. Deleted
   rather than left lying around, because its last remaining caller (litSide)
   was rendering the moon as a dark hole. astroNow.moonIllum / .moonAge are the
   only phase numbers in this file now. */
// ---- astronomical engine ----
const _D2R=Math.PI/180, _R2D=180/Math.PI;
function _jd(date){ return date.getTime()/86400000+2440587.5; }
function sunPos(lat,lon,date){
  const n=_jd(date)-2451545.0;
  const L=(280.460+0.9856474*n)%360;
  const g=(357.528+0.9856003*n)%360;
  const lam=L+1.915*Math.sin(g*_D2R)+0.020*Math.sin(2*g*_D2R);
  const eps=23.439-0.0000004*n;
  const sinL=Math.sin(lam*_D2R),cosL=Math.cos(lam*_D2R);
  const ra=Math.atan2(sinL*Math.cos(eps*_D2R),cosL)*_R2D;
  const dec=Math.asin(sinL*Math.sin(eps*_D2R))*_R2D;
  const gmst=(280.46061837+360.98564736629*n)%360;
  const ha=((gmst+lon-ra)%360+360)%360;
  const haR=ha*_D2R,latR=lat*_D2R,decR=dec*_D2R;
  const alt=Math.asin(Math.sin(latR)*Math.sin(decR)+Math.cos(latR)*Math.cos(decR)*Math.cos(haR))*_R2D;
  const az=(Math.atan2(Math.sin(haR),Math.cos(haR)*Math.sin(latR)-Math.tan(decR)*Math.cos(latR))*_R2D+180+360)%360;
  return {alt,az};
}
function moonPos(lat,lon,date){
  const jd=_jd(date); const T=(jd-2451545.0)/36525;
  const Lm=(218.3164477+481267.88123421*T)%360;
  const M=(357.5291092+35999.0502909*T)%360;
  const Mm=(134.9633964+477198.8675055*T)%360;
  const D=(297.8501921+445267.1114034*T)%360;
  const F=(93.2720950+483202.0175233*T)%360;
  const lam=Lm+6.289*Math.sin(Mm*_D2R)-1.274*Math.sin((2*D-Mm)*_D2R)+0.658*Math.sin(2*D*_D2R)-0.186*Math.sin(M*_D2R);
  const bet=5.128*Math.sin(F*_D2R)+0.281*Math.sin((Mm+F)*_D2R)-0.280*Math.sin((Mm-F)*_D2R)-0.173*Math.sin((2*D-F)*_D2R);
  const pie=0.9508+0.0518*Math.cos(Mm*_D2R);
  const eps=23.439-0.013*T;
  const ra=Math.atan2(Math.sin(lam*_D2R)*Math.cos(eps*_D2R)-Math.tan(bet*_D2R)*Math.sin(eps*_D2R),Math.cos(lam*_D2R))*_R2D;
  const dec=Math.asin(Math.sin(bet*_D2R)*Math.cos(eps*_D2R)+Math.cos(bet*_D2R)*Math.sin(eps*_D2R)*Math.sin(lam*_D2R))*_R2D;
  const n=jd-2451545.0;
  const gmst=(280.46061837+360.98564736629*n)%360;
  const ha=((gmst+lon-ra)%360+360)%360;
  const haR=ha*_D2R,latR=lat*_D2R,decR=dec*_D2R;
  const alt=Math.asin(Math.sin(latR)*Math.sin(decR)+Math.cos(latR)*Math.cos(decR)*Math.cos(haR))*_R2D;
  const az=(Math.atan2(Math.sin(haR),Math.cos(haR)*Math.sin(latR)-Math.tan(decR)*Math.cos(latR))*_R2D+180+360)%360;
  const synodic=29.530588853;
  const ref=Date.UTC(2000,0,6,18,14)/86400000;
  const age=((jd-2440587.5-ref)%synodic+synodic)%synodic;
  const illum=(1-Math.cos(age/synodic*2*Math.PI))/2*100;
  const phases=["New Moon","Waxing Crescent","First Quarter","Waxing Gibbous","Full Moon","Waning Gibbous","Last Quarter","Waning Crescent"];
  const phase=phases[Math.round(age/synodic*8)%8];
  return {alt,az,illum,phase,age};
}
// compact bright star catalog: [RA_hours, Dec_deg, Vmag]
const STARS=[
  [6.752,-16.716,-1.46],[6.399,-52.695,-0.72],[14.660,-60.835,-0.27],
  [14.261,19.182,-0.04],[18.616,38.782,0.03],[5.278,45.998,0.08],
  [5.242,-8.202,0.12],[7.655,5.225,0.34],[1.629,-57.237,0.46],
  [5.919,7.407,0.50],[14.064,-60.373,0.61],[19.846,8.868,0.77],
  [12.443,-63.099,0.77],[4.599,16.509,0.85],[16.490,-26.432,0.96],
  [13.420,-11.161,0.97],[7.755,28.026,1.14],[22.961,-29.622,1.16],
  [20.690,45.280,1.25],[12.796,-59.689,1.25],[10.139,11.967,1.35],
  [6.977,-28.972,1.50],[7.577,31.889,1.57],[12.519,-57.113,1.59],
  [17.560,-37.103,1.62],[5.419,6.350,1.64],[5.438,28.608,1.65],
  [9.220,-69.717,1.67],[5.603,-1.202,1.69],[22.137,-46.961,1.73],
  [5.679,-1.943,1.74],[3.406,49.861,1.79],[11.062,61.751,1.79],
  [7.140,-26.393,1.82],[17.622,-42.998,1.86],[18.403,-34.385,1.85],
  [8.375,-59.510,1.86],[13.793,49.314,1.86],[2.530,89.264,2.02],
  [14.111,-36.370,2.06],[7.401,-29.303,2.00],[8.745,6.420,2.23],
  [21.526,5.571,2.44],[20.370,40.257,2.23],[15.035,40.391,2.37],
  [9.461,-8.658,2.45],[16.051,-19.461,2.30],[10.332,-70.037,2.25],
  [7.046,-15.633,2.43],[6.833,-32.508,2.45],[10.897,41.500,2.34],
  [7.576,-14.826,2.37],[21.310,-16.834,2.39],[1.161,35.621,2.01],
  [5.994,37.213,2.16],[23.054,28.082,2.49],[2.097,42.330,2.26],
  [0.140,29.091,2.06],[17.943,51.489,2.24],[22.690,-46.885,2.17],
  [4.299,-3.352,3.00],[6.063,5.607,2.96],[8.044,-40.003,1.95],
  [3.791,24.106,2.87],[16.836,-34.293,2.29],[7.287,-26.777,2.46],
  [1.911,35.621,2.06],[17.530,-37.295,2.39],[15.578,-26.115,2.56],
  [6.251,22.513,2.53],[4.731,-8.202,2.77],[21.463,5.571,2.39],
  [6.381,-17.956,2.00],[7.139,-26.393,2.43],[9.134,26.005,2.87],
];
// star screen positions — recomputed each minute
let starPx=null; // array of {x01,y01,br[,pk]} normalised 0-1 (pk: a planet)
/* The four planets you can see without trying. Geometry only, nothing fetched: JPL's "Approximate
   Positions of the Planets" (1800-2050), the planet and the earth solved and differenced. Checked against
   JPL Horizons, 13 Nov 2026: within 0.08 degrees. [name, kind, elements at J2000, rates per century] with
   a AU, e, I, L, long. of perihelion, long. of node. */
const _PL=[["Venus",1,[0.72333566,0.00677672,3.39467605,181.97909950,131.60246718,76.67984255],[0.00000390,-0.00004107,-0.00078890,58517.81538729,0.00268329,-0.27769418]],
  ["Mars",2,[1.52371034,0.09339410,1.84969142,-4.55343205,-23.94362959,49.55953891],[0.00001847,0.00007882,-0.00813131,19140.30268499,0.44441088,-0.29257343]],
  ["Jupiter",3,[5.20288700,0.04838624,1.30439695,34.39644051,14.72847983,100.47390909],[-0.00011607,-0.00013253,-0.00183714,3034.74612775,0.21252668,0.20469106]],
  ["Saturn",4,[9.53667594,0.05386179,2.48599187,49.95424423,92.59887831,113.66242448],[-0.00125060,-0.00050991,0.00193609,1222.49362201,-0.41897216,-0.28867794]]];
const _PLE=[[1.00000261,0.01671123,-0.00001531,100.46457166,102.93768193,0],[0.00000562,-0.00004392,-0.01294668,35999.37244981,0.32327364,0]];
function _helio(el,rt,T){
  const D=Math.PI/180, a=el[0]+rt[0]*T, e=el[1]+rt[1]*T, I=(el[2]+rt[2]*T)*D, L=el[3]+rt[3]*T, wb=el[4]+rt[4]*T, Om=el[5]+rt[5]*T;
  const w=(wb-Om)*D, O=Om*D; let M=(((L-wb)%360)+540)%360-180; M*=D;
  let E=M+e*Math.sin(M); for(let i=0;i<8;i++) E+=(M-(E-e*Math.sin(E)))/(1-e*Math.cos(E));
  const xp=a*(Math.cos(E)-e), yp=a*Math.sqrt(1-e*e)*Math.sin(E), cw=Math.cos(w), sw=Math.sin(w), cO=Math.cos(O), sO=Math.sin(O), cI=Math.cos(I), sI=Math.sin(I);
  return [(cw*cO-sw*sO*cI)*xp+(-sw*cO-cw*sO*cI)*yp, (cw*sO+sw*cO*cI)*xp+(-sw*sO+cw*cO*cI)*yp, sw*sI*xp+cw*sI*yp];
}
function planetsNow(jd){
  const D=Math.PI/180, T=(jd-2451545.0)/36525, e=_helio(_PLE[0],_PLE[1],T), R=Math.hypot(e[0],e[1],e[2]), eps=23.43928*D;
  return _PL.map(([name,kind,el,rt])=>{
    const p=_helio(el,rt,T), x=p[0]-e[0], y=p[1]-e[1], z=p[2]-e[2], d=Math.hypot(x,y,z), r=Math.hypot(p[0],p[1],p[2]);
    const ye=y*Math.cos(eps)-z*Math.sin(eps), ze=y*Math.sin(eps)+z*Math.cos(eps);
    const ra=(Math.atan2(ye,x)/D+360)%360, dec=Math.asin(ze/d)/D;
    const al=Math.acos(Math.max(-1,Math.min(1,(r*r+d*d-R*R)/(2*r*d))))/D, lg=5*Math.log10(r*d);
    let mag;
    if(kind===1) mag=-4.47+lg+0.0103*al+0.000057*al*al+0.00000013*al*al*al;
    else if(kind===2) mag=-1.52+lg+0.016*al;
    else if(kind===3) mag=-9.40+lg+0.005*al;
    else { const lam=Math.atan2(y,x), bet=Math.asin(z/d), i=28.06*D, nd=169.51*D;       // Saturn: how open the rings stand
           const B=Math.asin(Math.sin(i)*Math.cos(bet)*Math.sin(lam-nd)-Math.cos(i)*Math.sin(bet));
           mag=-8.88+lg+0.044*al-2.6*Math.abs(Math.sin(B))+1.25*Math.sin(B)*Math.sin(B); }
    return {name,kind,ra,dec,mag};
  });
}
/* A planet comes out in twilight, before any star - Venus minutes after sunset. By brightness. */
let _STARK=(typeof WS.starBrightness==="number") ? WS.starBrightness*2 : 1;       // Hub: 0.5 = as designed
function _plTwi(sAlt,br){ const thr=5-4.5*Math.max(0,Math.min(1,(br-0.9)/0.7)); return Math.max(0,Math.min(1,(-sAlt-thr)/4)); }
/* ---- DYNAMIC HEADING (ported from Elemental, SceneState.headingTarget) -----
   FACING_AZ used to be a fixed bearing kept in localStorage, defaulting to 90.
   A fixed bearing has to have a VALUE, and any value is an assumption: 180
   means south, which is where the sun is from a clean-air town or northern India and the one
   direction it never is from Sydney. Get it wrong and the sky is empty.

   Dynamic has no such bias. The view points at whatever is actually up - the
   sun while it is above civil twilight, otherwise the moon if it has risen,
   and otherwise still the sun so dawn arrives already centred rather than
   swinging into place. It is correct at 42N and 34S without either being a
   special case, and it means nobody has to measure which way the screen faces.

   Eased by shortest angle so the sun/moon handover drifts rather than jumps. */
let HEADING_DYNAMIC = true;
if(WS.headingDynamic===false){ HEADING_DYNAMIC=false; if(typeof WS.facing==="number") FACING_AZ=((WS.facing%360)+360)%360; }   // Hub
function headingTarget(){
  const a = astroNow;
  if(!a) return FACING_AZ;
  if(a.sunAlt > -6)  return a.sunAz;
  if(a.moonAlt > 0)  return a.moonAz;
  return a.sunAz;
}
function stepHeading(){
  if(!HEADING_DYNAMIC) return;
  const want = headingTarget();
  if(typeof want !== 'number' || !isFinite(want)) return;
  let d = ((want - FACING_AZ + 540) % 360) - 180;   // shortest way round
  if(Math.abs(d) < 0.05){ FACING_AZ = want; return; }
  // 8% per call, with updateAstro running once a MINUTE, meant half an
  // hour to swing round - indistinguishable from broken. The sun only
  // moves 0.25 deg/min, so once converged this still tracks smoothly.
  FACING_AZ = ((FACING_AZ + d * 0.45) % 360 + 360) % 360;
}
function updateAstro(__a,__b,__c){ __stamp('astro'); return __updateAstro(__a,__b,__c); }
function __updateAstro(atMs){
  // atMs lets the wake replay walk the sky back through the interval it missed
  const now=atMs?new Date(atMs):new Date();
  const lat=CURRENT.lat, lon=CURRENT.lon;
  const s=sunPos(lat,lon,now);
  const m=moonPos(lat,lon,now);
  astroNow.sunAlt=s.alt; astroNow.sunAz=s.az;
  astroNow.moonAlt=m.alt; astroNow.moonAz=m.az;
  astroNow.moonIllum=m.illum; astroNow.moonPhaseN=m.phase; astroNow.moonAge=m.age;
  // compute star positions
  stepHeading();   // the view follows whatever is up
  const jd=_jd(now); const n=jd-2451545.0;
  const gmst=(280.46061837+360.98564736629*n)%360;
  const latR=lat*_D2R;
  const newPx=[];
  // 15 Nov: the PLANETS, where they really are (Elemental's Astro.planets, same numbers). First in the
  // list; pk = 1 Venus, 2 Mars, 3 Jupiter, 4 Saturn. Brightness on the stars' scale but allowed past 1.
  { const pls=(WS.planets===false)?[]:planetsNow(jd), seen=[];
    for(const pl of pls){
      const ha=((gmst+lon-pl.ra)%360+360)%360, haR=ha*_D2R, decR=pl.dec*_D2R;
      const alt=Math.asin(Math.sin(latR)*Math.sin(decR)+Math.cos(latR)*Math.cos(decR)*Math.cos(haR))*_R2D;
      if(alt<2) continue;
      const az=(Math.atan2(Math.sin(haR),Math.cos(haR)*Math.sin(latR)-Math.tan(decR)*Math.cos(latR))*_R2D+180+360)%360;
      seen.push(pl.name+" alt "+alt.toFixed(0)+" az "+az.toFixed(0)+" mag "+pl.mag.toFixed(1));
      const relAz=((az-FACING_AZ+180+360)%360)-180; if(Math.abs(relAz)>95) continue;
      newPx.push({x01:0.5+relAz/190, y01:1-(alt/85), br:Math.max(0.35,Math.min(1.7,(3.2-pl.mag)/4.7)), pk:pl.kind});
    }
    window.__planets=seen.join(", ")||"none up"; }
  for(let i=0;i<STARS.length;i++){
    const [rh,dec,mag]=STARS[i];
    const ra=rh*15; // hours -> degrees
    const ha=((gmst+lon-ra)%360+360)%360;
    const haR=ha*_D2R, decR=dec*_D2R;
    const alt=Math.asin(Math.sin(latR)*Math.sin(decR)+Math.cos(latR)*Math.cos(decR)*Math.cos(haR))*_R2D;
    if(alt<2) continue; // below horizon
    const az=(Math.atan2(Math.sin(haR),Math.cos(haR)*Math.sin(latR)-Math.tan(decR)*Math.cos(latR))*_R2D+180+360)%360;
    // map az relative to FACING_AZ: -90° to +90° fills screen width
    const relAz=((az-FACING_AZ+180+360)%360)-180; // -180..180
    if(Math.abs(relAz)>95) continue; // outside view
    const x01=0.5+relAz/190; // 0..1
    const y01=1-(alt/85); // high alt = near top
    // brightness: magnitude -1.5 to 3 -> 1 to 0
    const br=Math.max(0,Math.min(1,(3.2-mag)/4.7));
    newPx.push({x01,y01,br});
  }
  starPx=newPx;
}
let _f1TrackSig="";
const ELB_BLOCKS=false;
let _cellW=0;   // this cell's cloud/body weight (weather branch), so the sky blend leaves cloud alone
const ELB_DEPTH=true;   // Elemental depth-as-colour on the plain pixels
const ELB_SKY=true;   // Elemental sky model (see _skyE); false = the old roomstand table
const ELB={tf0:0.90, tf1:0.05, skyLight:1.10, halftone:0.6, emph:1.0, depth:1.0, depthMap:1.0, light:0.3, every:3000};
let elbI=0.2;
let elbCv=null, elbX=null, elbBk=null, elbBX=null, elbH=null, elbL=null;
let elbRow=-1, elbT0=0, elbOk=false, elbW=0, elbHt=0, elbTile=null, elbImg=null;
function elbSetup(){
  const W=COLS*SP, H=ROWS*SP, n=COLS*ROWS;
  if(elbCv && elbW===W && elbHt===H && elbH && elbH.length===n) return;
  elbW=W; elbHt=H;
  elbCv=document.createElement("canvas"); elbCv.width=W; elbCv.height=H; elbX=elbCv.getContext("2d");
  elbBk=document.createElement("canvas"); elbBk.width=W; elbBk.height=H; elbBX=elbBk.getContext("2d");
  elbH=new Float32Array(n); elbL=new Float32Array(n); elbRow=-1; elbOk=false;
  elbImg=cctx.createImageData(COLS,ROWS);
  // occlusion falloff, one per side: darkest on the shared edge, gone 0.6 cell in
  elbTile=[];
  for(let k=0;k<4;k++){
    const c=document.createElement("canvas"); c.width=SP; c.height=SP; const x=c.getContext("2d");
    const g=k===0?x.createLinearGradient(0,0,SP*0.6,0):k===1?x.createLinearGradient(SP,0,SP*0.4,0)
           :k===2?x.createLinearGradient(0,0,0,SP*0.6):x.createLinearGradient(0,SP,0,SP*0.4);
    g.addColorStop(0,"rgba(0,0,0,1)"); g.addColorStop(1,"rgba(0,0,0,0)");
    x.fillStyle=g; x.fillRect(0,0,SP,SP); elbTile.push(c);
  }
}
function elbSmooth(a,b,x){ const t=Math.max(0,Math.min(1,(x-a)/(b-a))); return t*t*(3-2*t); }
// Heightfield, as Elemental's heightPass: a block stands proud by how much
// brighter it is than its neighbourhood (rings at 1.6 and 4.5 cells), with
// points damped so a lone star does not become a tower.
function elbHeights(){
  const d=cimg.data, n=COLS*ROWS;
  for(let i=0;i<n;i++){ const o=i*4; elbL[i]=(0.2126*d[o]+0.7152*d[o+1]+0.0722*d[o+2])/255; }
  const R1=[[2,0],[-2,0],[0,2],[0,-2],[1,1],[-1,1],[1,-1],[-1,-1]];
  const R2=[[5,0],[-4,0],[0,5],[0,-4],[3,3],[-3,3],[3,-3],[-3,-3]];
  const at=(x,y)=>elbL[Math.max(0,Math.min(ROWS-1,y))*COLS+Math.max(0,Math.min(COLS-1,x))];
  for(let y=0;y<ROWS;y++) for(let x=0;x<COLS;x++){
    const i=y*COLS+x, l=elbL[i]; let m1=0,m2=0;
    for(let k=0;k<8;k++){ m1+=at(x+R1[k][0],y+R1[k][1]); m2+=at(x+R2[k][0],y+R2[k][1]); }
    m1*=0.125; m2*=0.125;
    const e=Math.max(0,Math.max(l-m1,l-m2,0)-0.03), prom=e/(e+0.12);
    let em=prom*(0.10+0.90*elbSmooth(0.05,0.32,l));
    const fine=Math.max(l-m1,0), broad=Math.max(l-m2,0);
    em*=1-0.82*Math.max(0,Math.min(1,(fine-broad*0.55)/0.16));
    const flat=Math.pow(l,0.65)*(1-0.58*ELB.emph);
    elbH[i]=Math.max(0,Math.min(1,flat+(1-flat)*em*ELB.emph));
  }
}
// One slice of the overlay into the back canvas; swap when the last row lands.
function elbStep(nowMs){
  elbSetup();
  if(elbRow<0){ if(nowMs-elbT0<ELB.every && elbOk) return; elbT0=nowMs; elbHeights(); elbBX.clearRect(0,0,elbW,elbHt); elbRow=0;
    const src=Math.max(0,Math.min(1,(window.__sky!=null?window.__sky:1)*1.2)), cov=Math.max(0,Math.min(1,(typeof scCover==="number"?scCover:0)/100));
    elbI=ELB.light*(0.45+0.55*src)*(1-cov*0.35); }
  const per=Math.max(3,Math.ceil(ROWS/12)), y1=Math.min(ROWS,elbRow+per), bx=elbBX;
  const grout=0.08*(1-0.72*ELB.depth);                 // matte grout band, cell fraction
  const groutA=(1-(0.42+0.24*ELB.depth)).toFixed(3);   // col *= mix(.42,.66,depth)
  for(let cy=elbRow; cy<y1; cy++) for(let cx=0; cx<COLS; cx++){
    const i=cy*COLS+cx, x=cx*SP, y=cy*SP, h=elbH[i];
    // relief: shade the edge a taller neighbour stands over (presentPass occ)
    const nb=[[cx-1,cy,0],[cx+1,cy,1],[cx,cy-1,2],[cx,cy+1,3]];
    for(let k=0;k<4;k++){ const nx=nb[k][0], ny=nb[k][1];
      if(nx<0||ny<0||nx>=COLS||ny>=ROWS) continue;
      const dh=elbH[ny*COLS+nx]-h; if(dh<=0) continue;
      bx.globalAlpha=Math.min(1,dh/0.45)*0.55; bx.drawImage(elbTile[nb[k][2]],x,y); }
    bx.globalAlpha=1;
    // Side faces. Elemental views the wall from a camera 0.62 screen-widths
    // back, so a raised block's top leans outward from the centre and the face
    // turned TOWARD the centre shows - under blocks near the top, beside blocks
    // near the edges, nothing in the middle. Width = lean x height; shade is
    // its flank lighting, 1 + I(0.55 n.L - 0.42), light from above: the
    // down-facing faces up top go darker, the up-facing ones below go lighter.
    const H=h*2*ELB.depth;                               // RELIEF_MAX = 2 cell pitches
    if(H>0.02){
      const gx=cx+0.5, gy=cy+0.5, cam=Math.max(COLS,ROWS)*0.62;
      const lx=(gx-COLS*0.5)/cam*elbSmooth(1,2.6,Math.min(gx,COLS-gx));
      const ly=(gy-ROWS*0.5)/cam*elbSmooth(1,2.6,Math.min(gy,ROWS-gy));
      const wx=Math.min(0.5,Math.abs(lx)*H)*SP, wy=Math.min(0.5,Math.abs(ly)*H)*SP;
      if(wy>0.25){ const ny=ly<0?1:-1, sh=1+elbI*(0.55*(-ny)-0.42)*(1-0.15);
        bx.fillStyle=sh<1?`rgba(0,0,0,${(1-sh).toFixed(3)})`:`rgba(255,255,255,${(sh-1).toFixed(3)})`;
        bx.fillRect(x, ly<0?y+SP-wy:y, SP, wy); }
      if(wx>0.25){ const sh=1+elbI*(-0.42)*(1-0.15);
        bx.fillStyle=`rgba(0,0,0,${(1-sh).toFixed(3)})`;
        bx.fillRect(lx<0?x+SP-wx:x, y, wx, SP); }
    }
    // halftone: the face shrinks with tone (dotRadius, sqrt of luminance)
    const l=elbL[i], fill=0.5*(1-ELB.halftone)+(0.05+0.75*Math.sqrt(l))*ELB.halftone;
    if(fill<0.5){
      const g=(0.5-fill)*SP; bx.fillStyle="#000";
      bx.fillRect(x,y,SP,g); bx.fillRect(x,y+SP-g,SP,g); bx.fillRect(x,y+g,g,SP-2*g); bx.fillRect(x+SP-g,y+g,g,SP-2*g);
    }
    if(fill>0.5-grout){                                  // a full face keeps its grout line
      const w=Math.max(0.35,grout*SP*0.5); bx.fillStyle=`rgba(0,0,0,${groutA})`;
      bx.fillRect(x,y,SP,w); bx.fillRect(x,y+SP-w,SP,w); bx.fillRect(x,y+w,w,SP-2*w); bx.fillRect(x+SP-w,y+w,w,SP-2*w);
    }
  }
  elbRow=y1;
  if(elbRow>=ROWS){ const t=elbCv; elbCv=elbBk; elbBk=t; const tx=elbX; elbX=elbBX; elbBX=tx; elbRow=-1; elbOk=true; }
}
// Depth as colour WITHOUT the block overlay (his "depth as colour" = 1 is a
// look, not a pixel style): heights every few seconds, no overlay drawn.
let elbHok=false;
function elbDepth(nowMs){
  elbSetup();
  if(elbHok && nowMs-elbT0<ELB.every) return;
  elbT0=nowMs; elbHeights(); elbHok=true;
}
// Depth as colour (styleCell): flush blocks drawn toward the haze - less
// saturated, cooler, flatter; proud ones keep their colour and warm slightly.
function elbColour(){
  const s=cimg.data, d=elbImg.data, n=COLS*ROWS, dm=ELB.depthMap;
  for(let i=0;i<n;i++){
    const o=i*4, dd=elbH[i]*2-1;
    let r=s[o], g=s[o+1], b=s[o+2]; const Y=0.2126*r+0.7152*g+0.0722*b;
    const sat=Math.max(0,Math.min(1,1+0.40*dm*dd));
    r=Y+(r-Y)*sat; g=Y+(g-Y)*sat; b=Y+(b-Y)*sat;
    r*=1+0.07*dm*dd; g*=1+0.01*dm*dd; b*=1-0.06*dm*dd;
    const con=Math.max(0,Math.min(1,1+0.18*dm*dd));
    d[o]=Y+(r-Y)*con; d[o+1]=Y+(g-Y)*con; d[o+2]=Y+(b-Y)*con; d[o+3]=255;
  }
  return elbImg;
}
/* TILE MATERIALS (15 Nov 2026), the wall's version of what Elemental 0.8 does in its shader. The tiles'
   look is ONE image laid over the scene - light where a tile catches the light, dark where it turns away -
   so a material costs nothing per frame: it is drawn once here, when the grid is made.
   A tile is a flat face with a bevel, lit from the upper left, and each one leans a hair differently:
     glass    lit and shaded bevels, a glint on the cut edge, a line of light inside the far edge, and a
              sheen across only the panes that lean toward the light
     metal    the room in it - lighter above, darker below - a brushed grain and a band of light
     plastic  a soft moulded pillow with one wide highlight
     matte    a flat tile and its grout, nothing else
   Returns false for "classic", which keeps the ruled lines. */
function tileMaterial(bx){
  const M=(typeof WS.material==="number") ? WS.material : 1;
  if(M===0 || SP<5) return false;
  const K=((typeof WS.tileRelief==="number") ? WS.tileRelief : 0.5)*2;
  const Wd=COLS*SP, Hd=ROWS*SP, img=bx.createImageData(Wd,Hd), d=img.data;
  const sm=(a,b,x)=>{ const t=Math.max(0,Math.min(1,(x-a)/(b-a))); return t*t*(3-2*t); };
  const hsh=(a,b)=>{ const x=Math.sin(a*127.1+b*311.7)*43758.5453; return x-Math.floor(x); };
  const bw = M===2 ? 0.14 : (M===3 ? 0.40 : 0.20);                 // bevel, as a share of the half tile
  const LX=-0.7071, LY=-0.7071;                                    // the light: upper left
  // one tile's pattern depends only on (x, y in the tile) and its lean, so do the geometry once
  const E=new Float32Array(SP*SP), LIT=new Float32Array(SP*SP);
  for(let y=0;y<SP;y++) for(let x=0;x<SP;x++){
    const u=(x+0.5)/SP, v=(y+0.5)/SP, dx=Math.abs(u-0.5), dy=Math.abs(v-0.5);
    E[y*SP+x]=1-Math.max(dx,dy)*2;                                 // 0 on the rim, 1 at the centre
    const ox=dx>=dy?(u<0.5?-1:1):0, oy=dx>=dy?0:(v<0.5?-1:1);      // which edge this point belongs to
    LIT[y*SP+x]=ox*LX+oy*LY;                                       // +0.7 facing the light, -0.7 away
  }
  for(let ty=0;ty<ROWS;ty++) for(let tx=0;tx<COLS;tx++){
    const lean=hsh(tx+1.3,ty+7.1)*2-1, lean2=hsh(tx+9.7,ty+2.9)*2-1;
    for(let y=0;y<SP;y++){ const v=(y+0.5)/SP; let o=((ty*SP+y)*Wd+tx*SP)*4;
      for(let x=0;x<SP;x++, o+=4){
        const u=(x+0.5)/SP, e=E[y*SP+x], lit=LIT[y*SP+x]/0.7071;
        const bev=1-sm(0,bw,e), face=1-bev;
        const crest=sm(0.10,0.45,bev)*(1-sm(0.60,1.0,bev));
        let val=0;
        if(M===1){                                                  // glass
          val = face*(0.03+0.07*lean) + face*(0.5-v)*0.07
              + bev*(0.36*lit-0.10) + crest*Math.max(lit,0)*0.26
              + sm(bw,bw*1.3,e)*(1-sm(bw*1.3,bw*2.4,e))*Math.max(-lit,0)*0.14;
          const along=((u-0.5)*LX+(v-0.5)*LY), w=Math.max(0,Math.min(1,lean*1.5-0.25));
          val += Math.exp(-Math.pow((along-lean*0.30)/0.17,2))*face*w*0.10;
        } else if(M===2){                                           // metal
          const grain=hsh(tx*3.1+Math.floor(y*1.0)*0.37, ty*5.3+y*1.7);
          val = face*(0.16*(1-v)-0.13) + face*(grain-0.5)*0.07
              + Math.exp(-Math.pow(((v-0.5)-0.14-lean*0.22)/0.16,2))*face*0.17*(0.75+0.5*grain)
              + bev*(0.55*lit-0.20) + crest*Math.max(lit,0)*0.38 + face*0.05*lean2;
        } else if(M===3){                                           // plastic
          const hx=u-0.32-0.05*lean, hy=v-0.30-0.05*lean2;
          val = bev*(0.26*lit-0.11) + Math.exp(-(hx*hx+hy*hy)/0.045)*0.15 - 0.03;
        } else {                                                    // matte: its grout and nothing else
          val = -0.22*(1-sm(0, 1.6/SP*2, e));
        }
        val*=K;
        if(val>=0){ d[o]=255; d[o+1]=255; d[o+2]=255; d[o+3]=Math.min(150,val*255)|0; }
        else      { d[o]=0;   d[o+1]=0;   d[o+2]=0;   d[o+3]=Math.min(165,-val*1.25*255)|0; }
      }
    }
  }
  bx.putImageData(img,0,0);
  return true;
}
function resizeScene(){
  scene.height=Math.floor(innerHeight*RES);
  SP=Math.max(6,Math.round(scene.height/GRID_ROWS));   // 36 -> 54 on 28 Sep: "smaller pixels, more detail"
  ROWS=Math.max(1,Math.round(scene.height/SP)); scene.height=ROWS*SP;      // whole tiles top-to-bottom
  COLS=Math.max(1,Math.round(Math.floor(innerWidth*RES)/SP)); scene.width=COLS*SP;  // whole tiles left-to-right
  dotPh=new Float32Array(COLS*ROWS);
  for(let i=0;i<dotPh.length;i++) dotPh[i]=Math.random()*6.28;
  edgeArr=new Float32Array(COLS);
  bevel=document.createElement("canvas"); bevel.width=COLS*SP; bevel.height=ROWS*SP;
  const bx=bevel.getContext("2d");
  if(!tileMaterial(bx)){                       // classic: the plain ruled lines
  for(let by=0;by<ROWS;by++){ for(let bxx=0;bxx<COLS;bxx++){
    const px=bxx*SP, py=by*SP;
    bx.fillStyle="rgba(255,255,255,.11)"; bx.fillRect(px,py,SP,1); bx.fillRect(px,py,1,SP);
    bx.fillStyle="rgba(0,0,0,.28)"; bx.fillRect(px,py+SP-1,SP,1); bx.fillRect(px+SP-1,py,1,SP);
  }}
  }
  cell=document.createElement("canvas"); cell.width=COLS; cell.height=ROWS;
  cctx=cell.getContext("2d"); cimg=cctx.createImageData(COLS,ROWS);
  sceneCol=new Uint8ClampedArray(COLS*ROWS*3);
  breathers=[];
  for(let i=0;i<3;i++) breathers.push({ax:Math.random()*scene.width, ay:Math.random()*scene.height,
    R:scene.height*(0.22+0.18*Math.random()), per:16+Math.random()*24,
    s1:0.018+Math.random()*0.022, s2:0.014+Math.random()*0.02,
    ph:Math.random()*6.28, ph2:Math.random()*6.28});
  hasArtGrid=false;
  pwReset();                 // wetness grid is per-cell, so it dies with the grid
  seedScene();
}
function setScene(kind,day,cover,code,uv,wind,precip,rain,snow,vis,humid,windDir,pressure,precipProb){
  const cv=(cover==null)?(kind==="cloud"?85:kind==="partly"?45:kind==="sun"?5:70):cover;
  if(code!==undefined&&code!==null) scCode=code;
  if(uv!=null) scUV=uv;
  if(wind!=null) scWind=wind;
  if(windDir!=null) scWindDir=windDir;
  if(pressure!=null) scPressure=pressure;
  if(precipProb!=null) scPrecipProb=precipProb;
  if(precip!=null) scPrecip=precip;
  if(rain!=null) scRain=rain;
  if(snow!=null) scSnow=snow;
  if(vis!=null) scVis=vis;
  if(humid!=null){ scHumid=humid;
    document.body.classList.toggle("humid", humid>78); }
  if(kind===scKind && (day?1:0)===scDay && Math.abs(cv-scCover)<12) return;
  scKind=kind; scDay=day?1:0; scCover=cv; seedScene();
  // the forecast has just spoken; let the observation correct it
  if(typeof applyMetar==='function') applyMetar();
}
function seedScene(){
  const W=scene.width; if(!W)return;
  streaks=[]; bolt=null; flashT=-9;
  nextBolt=performance.now()/1000+9+Math.random()*14;
  shootT=performance.now()/1000+60+Math.random()*180; shoot=null;
}
/* Which part of the moon is in sunlight.

   This used to run off moonPhase(), a mean-synodic approximation reading
   Date.now() directly - a SECOND, independent phase model that disagreed with
   the astronomical engine driving everything else about the moon, and ignored
   the scene clock so it could not be replayed. Measured 2026-09-09: at a moment
   the engine put at 93% illuminated and waxing, this returned "4% and waning",
   so litSide() was false across the ENTIRE disc and the moon rendered as a dark
   hole with a bright rim. It also drew today's crescent on the wrong limb.

   astroNow is the single source of truth: illumination for how much is lit,
   age for which side it is on. The terminator on a disc is an ellipse whose
   semi-minor axis is r*(1-2k) for illuminated fraction k, which is all the
   geometry needed.

   Returned as a SIGNED-DISTANCE fraction, not a boolean, because the detail
   pass works at a fraction of a cell: at 98% illumination the unlit sliver is
   thinner than one sub-cell, and a boolean renders it as a single black square
   hanging off the limb, which reads as a dead pixel. */
const _MOON_SYN=29.530588853;
/* Luminance of the fully lit face, and of the shaded face, before cloud.

   Deliberately NOT proportional to the illuminated fraction: a half moon's lit
   half is as bright per unit area as a full moon's - phase changes how much of
   it there is, not how bright it is. Some dependence is kept because the real
   Moon does surge toward opposition. Earthshine is very nearly constant and
   slightly BRIGHTER at crescent, which is why the old moon in the new moon's
   arms is a crescent phenomenon. */
function _moonLitRef(illum,dim){ return (180*(0.55+0.45*Math.max(0,Math.min(1,(illum||0)/100)))+20)*dim; }
function _moonEarthRef(illum,dim){ return (28+12*(1-Math.max(0,Math.min(1,(illum||0)/100))))*dim; }
/* The terminator is a HARD step, and that is a decision, not an oversight.

   Feathering it across a cell gives a smooth curve, which is what a photograph
   looks like and not what this wall is. The mosaic is the point: the edge steps
   from cell to cell. It does not read as ragged because the subdivision pass
   splits every cell the terminator crosses, so the staircase is drawn at
   sub-cell resolution - fine steps, still unmistakably steps, never a curve. */
function moonLitFrac(dx,dy,r){
  const k=Math.max(0,Math.min(1,(astroNow.moonIllum||0)/100));
  const waxing=((astroNow.moonAge||0)%_MOON_SYN)<_MOON_SYN*0.5;
  const chord=Math.sqrt(Math.max(0,1-(dy*dy)/(r*r)));
  const xt=r*(1-2*k)*chord;
  return (waxing ? (dx>xt) : (dx<-xt)) ? 1 : 0;
}
function litSide(dx,dy,r){ return moonLitFrac(dx,dy,r)>0.5; }
/* ---- waveform on separate canvas (above blur, below UI) ---- */
// uses the SAME grid as scene — same SP, COLS, ROWS — only draws bottom 28% rows
// ========================================================
// SKY COLOUR + ATMOSPHERE ENGINE
// ========================================================
function _skl(a,b,t){ return a+(b-a)*Math.max(0,Math.min(1,t)); }
// Compute sky gradient RGB for a given screen-space y fraction
// sAlt: real sun altitude (degrees), yFrac: 0=top 1=horizon
// aqiF: 0=clean, 1=max pollution.  covF: cloud cover 0-1
function _skyRGB(sAlt,yFrac,aqiF,covF,smokeF){
  const a=Math.max(-20,Math.min(90,sAlt));
  const h=Math.min(1,Math.pow(yFrac,0.72)); // nonlinear horizon weight
  let tr,tg,tb,hr,hg,hb; // zenith and horizon anchor colours
  if(a<=-18){tr=3;tg=5;tb=14;hr=7;hg=9;hb=20;}
  else if(a<=-12){const f=(a+18)/6;
    tr=_skl(3,8,f);tg=_skl(5,12,f);tb=_skl(14,26,f);
    hr=_skl(7,18,f);hg=_skl(9,16,f);hb=_skl(20,38,f);}
  else if(a<=-6){const f=(a+12)/6;
    tr=_skl(8,16,f);tg=_skl(12,22,f);tb=_skl(26,50,f);
    hr=_skl(18,38,f);hg=_skl(16,25,f);hb=_skl(38,62,f);}
  else if(a<=-0.83){const f=(a+6)/5.17;
    // civil twilight / blue hour: deep blue → indigo, warm horizon
    tr=_skl(16,38,f);tg=_skl(22,48,f);tb=_skl(50,105,f);
    hr=_skl(55,195,f);hg=_skl(32,95,f);hb=_skl(68,118,f);}
  else if(a<=5){const f=a/5;
    // golden hour: palette shifts warm orange-pink
    tr=_skl(38,70,f);tg=_skl(48,85,f);tb=_skl(105,165,f);
    hr=_skl(255,255,f);hg=_skl(155,205,f);hb=_skl(80,125,f);}
  else if(a<=14){const f=(a-5)/9;
    // morning/evening ramp
    tr=_skl(70,48,f);tg=_skl(85,115,f);tb=_skl(165,220,f);
    hr=_skl(255,215,f);hg=_skl(205,215,f);hb=_skl(125,238,f);}
  else if(a<=42){const f=(a-14)/28;
    tr=_skl(48,20,f);tg=_skl(115,130,f);tb=_skl(220,238,f);
    hr=_skl(215,172,f);hg=_skl(215,208,f);hb=_skl(238,242,f);}
  else{tr=20;tg=130;tb=238;hr=172;hg=208;hb=242;}
  const hk=h*h*(3-2*h); // smoothstep
  let r=tr+(hr-tr)*hk, g=tg+(hg-tg)*hk, b=tb+(hb-tb)*hk;
  // Aerosol haze: mild brown pollution, DRAMATIC red-orange with wildfire smoke; smoke also raises haze strength & spreads it up-sky
  const sm=smokeF||0;
  if(aqiF>0||sm>0){
    const hz=(aqiF*0.28+sm*0.40)*Math.pow(yFrac,1.3-sm*0.55)*_skyBr(sAlt);
    const hzR=150+aqiF*78+sm*52, hzG=120+aqiF*6-sm*34, hzB=82-aqiF*24-sm*40;
    r=r+(hzR-r)*hz; g=g+(hzG-g)*hz; b=b+(hzB-b)*hz;
    const avg=(r+g+b)/3, ds=aqiF*0.07*(1-sm);
    r=r+(avg-r)*ds; g=g+(avg-g)*ds; b=b+(avg-b)*ds;
  }
  // ---- skyglow, from what is actually over THIS location -------------------
  //
  // The old numbers here were read off a window in a dusty city: a flat
  // sodium-orange (95,58,28) at a fixed 0.75, and an overcast blanch of
  // (198,198,200) at every hour. Both are true of a Bortle 8 megacity under
  // heavy aerosol and neither is true of a clean-air town, so they are now derived:
  //
  //   how much light the ground throws up   -> CURRENT.skyglow, per site
  //   how much scatters back down to the eye -> AEROSOL, measured (scAOD)
  //
  // The aerosol term is the physical one and it is why the same streetlights
  // give a black sky on a clean night and a brown lid on a dirty one. It also
  // reddens the glow as it thickens, which is Mie scattering doing what it
  // does - so the dusty city comes out orange and a clean-air town comes out a faint warm grey
  // from the same two lines.
  const aodN=Math.max(0,Math.min(1,scAOD/0.85));
  const glowAmt=Math.max(0,Math.min(1,(CURRENT.skyglow||0.3)*(0.55+0.85*aodN)));
  const glowR=78+34*aodN, glowG=68+2*aodN, glowB=58-26*aodN;
  // Cloud cover: softens and blanches the sky. The target follows the hour,
  // because an overcast midnight is dark - a flat daylight grey put a bright
  // ceiling over a dark world. What light a night deck does have is the
  // skyglow bouncing off its base, so that is what tints it.
  if(covF>0.08){
    const ck=(covF-0.08)*1.09*0.28, sb=_skyBr(sAlt);
    const nR=9+glowR*glowAmt*0.90, nG=8+glowG*glowAmt*0.82, nB=12+glowB*glowAmt*0.74;
    const tR=nR+(198-nR)*sb, tG=nG+(198-nG)*sb, tB=nB+(200-nB)*sb;
    r=r+(tR-r)*ck; g=g+(tG-g)*ck; b=b+(tB-b)*ck;
  }
  // Urban glow at the horizon through night and twilight. Cover cuts BOTH ways:
  // a deck hides the stars but also catches the city light from underneath, so
  // it is only partly subtracted.
  if(a<2&&yFrac>0.55){
    const lp=Math.max(0,(2-a)/20)*Math.pow((yFrac-0.55)/0.45,2)*glowAmt*0.85*(1-covF*0.5);
    r=r+(glowR-r)*lp; g=g+(glowG-g)*lp; b=b+(glowB-b)*lp;
  }
  return {r:Math.round(r)|0,g:Math.round(g)|0,b:Math.round(b)|0};
}
// Sky ambient brightness 0→1 used to scale cloud shade, light pockets etc.
function _skyBr(sAlt){
  if(sAlt<=-18) return 0.04;
  if(sAlt<=-6)  return _skl(0.04,0.18,(sAlt+18)/12);
  if(sAlt<=0)   return _skl(0.18,0.46,(sAlt+6)/6);
  if(sAlt<=6)   return _skl(0.46,0.82,sAlt/6);
  if(sAlt<=22)  return _skl(0.82,1.0,(sAlt-6)/16);
  return 1.0;
}
// Sun disc tint: deep red at horizon → warm yellow → white
function _sunTint(sAlt,aqiF){
  const f=Math.max(0,Math.min(1,sAlt/18))*Math.max(0,1-aqiF*0.45);
  return {r:255,g:Math.round(_skl(120,250,f)),b:Math.round(_skl(35,195,f))};
}
// Cloud face tint: warm orange-pink at golden hour, cool blue-gray at night
function _cloudTint(sAlt,light,shade){
  // Daylight cloud is very nearly neutral (Elemental: a daytime overcast is
  // ~6400 K against sRGB's 6504 K) - the old +16 blue put lavender on it.
  if(sAlt>14){const v=shade; return {r:Math.max(0,v-6),g:Math.max(0,v-2),b:Math.min(255,v+8)};}
  if(sAlt>-1){
    const gf=(1-Math.min(1,sAlt/14))*light;
    const v=shade;
    return {r:Math.min(255,v+gf*88),g:Math.max(0,v+gf*14-8),b:Math.max(0,v-gf*45)};
  }
  // Below the horizon the deck used to go straight to cold grey - a cliff at
  // -1 deg, so every sunset died the moment the sun touched the horizon. The
  // cold value is still where it ENDS UP, reached over the few degrees the
  // light actually takes to leave (Elemental).
  const v=shade*0.72, cold={r:Math.max(0,v-8),g:Math.max(0,v+2),b:Math.min(255,v+20)};
  const tw=_twLit(sAlt,0.25); if(tw[0]<=0.001) return cold;
  const wc=_twColour(sAlt), f=0.35+0.55*(shade/235), k=tw[0]*tw[1]*light;
  return {r:cold.r+(Math.min(255,wc.r*f)-cold.r)*k, g:cold.g+(Math.min(255,wc.g*f)-cold.g)*k, b:cold.b+(Math.min(255,wc.b*f)-cold.b)*k};
}
/* Where a shower goes, from radar rather than from a coin toss.
   RADAR_PROFILE is echo intensity west-to-east across ~900km, normalised. The
   screen shows a ~190-degree sweep centred on whatever the display faces, so a
   west-east strip maps cleanly to left-right facing north, and mirrored facing
   south. Facing east or west the strip is coming toward him rather than across
   and the horizontal spread means less - but radar still beats uniform noise,
   so it is used either way rather than pretending we know nothing. Falls back
   to the old random pick whenever radar is absent. */
function radarColumn(COLS){
  const prof = (typeof RADAR_PROFILE !== 'undefined') ? RADAR_PROFILE : null;
  if(!prof || !prof.length) return (Math.random()*COLS)|0;
  const facing = (typeof FACING_AZ === 'number') ? FACING_AZ : 90;
  const mirror = (facing > 90 && facing < 270);
  for(let t=0;t<8;t++){
    const c = (Math.random()*COLS)|0;
    let f = c / Math.max(1, COLS);
    if(mirror) f = 1 - f;
    // A window sees a slice of the radar window, not the synoptic chart.
    f = (f - 0.5) * 0.42 + 0.5;
    const w = Math.min(1, (prof[Math.min(prof.length-1, (f*prof.length)|0)] || 0) / 0.22);
    // Elemental 0.6.1: if it is raining here it is raining across the view -
    // the radar shapes where it falls harder, it may not leave a column dry.
    if(Math.random() < Math.max(0.25, w)) return c;
  }
  return (Math.random()*COLS)|0;
}
/* SLICED SCENE (23 Sep). Measured on the Pi: computing the tile colours took
   ~26 ms per update, 24 times a second, on the same thread that must hand the
   compositor a frame every 16.7 ms - so every update cost one or two frames and
   the wall sat at ~22-27 fps. The GPU was never the bottleneck. The scene is now
   a generator that pauses at row boundaries, and the frame loop runs one slice
   per frame, sized to stay under ~6 ms. Nothing is shown until a whole scene is
   done (the blit is at the end), so it cannot tear or half-draw. */
window.__dsT={all:0,cells:0,blit:0,water:0,bevel:0,n:0,max:0};
let __ROWCHUNK=0, _sceneGen=null, _sceneGenMs=0;
function drawScene(t,dt){            // synchronous callers (resize, seed): run it whole
  const keep=__ROWCHUNK; __ROWCHUNK=0;
  try{ const g=__drawSceneGen(t,dt); while(!g.next().done){} } finally { __ROWCHUNK=keep; }
}
function* __drawSceneGen(t,dt){
  window.__dsCellT0=performance.now();
  const W=scene.width,H=scene.height; if(!W)return;
  const sec=t/1000;
  const sAlt=astroNow.sunAlt;
  const skySAlt=(peekIdx>=0?peekSunAlt:astroNow.sunAlt); // sky gradient from peeked loc
  const aqiF=Math.max(0,Math.min(1,Math.max(0,scAQI-30)/320));
  const smokeF=Math.max(0,Math.min(1,scSmoke)); // wildfire-smoke score (fine-particle + heavy aerosol)
  const skyBrAmt=_skyBr(skySAlt);
  window.__sky=skyBrAmt;
  const posterQ=Math.max(3,Math.round(POSTER*(0.3+0.7*skyBrAmt)));
  const inMusic=(mode==="music");
  const f1track=false; // track is the fine background mini-mosaic (#f1Cv), not the coarse full-screen field
  const trkHead=(sec*0.085)%1;
  const covF=Math.max(0,Math.min(1,scCover/100));
  // how much direct sun is on the scene: clear sky x a sun well up
  window.__sunny=Math.max(0,1-covF)*Math.max(0,Math.min(1,(astroNow.sunAlt||0)/40))*(scKind==="rain"||scKind==="thunder"?0.2:1);
  const wet=(scKind==="rain"||scKind==="thunder"||scKind==="snow");
  const depth=H*(0.10+0.38*covF);
  const cloudSpd=0.003+Math.min(0.02, scWind*0.0004);
  const humidF=Math.max(0,Math.min(1,(scHumid-50)/50));
  // cloud edge (weather mode only)
  if(!inMusic){
    for(let c=0;c<COLS;c++){
      const cx2=c*SP;
      const n=0.5+0.28*fsin(cx2*0.012+sec*cloudSpd)+0.18*fsin(cx2*0.027-sec*cloudSpd*1.4+2.1)+0.12*fsin(cx2*0.051+sec*cloudSpd*0.7+4.0);
      const prof=n+(covF-0.55)*1.6;
      // Soft knee, not min(1,prof). A hard clamp meant that under heavy cover
      // the profile spent long stretches pinned at exactly 1, so the deck's
      // edge came out as flat-topped rectangles with cliffs where it came off
      // the clamp - blocks, not cloud. This approaches 1 asymptotically, so the
      // shape stays wavy all the way up.
      const _kn=0.62;
      const _p=prof<=_kn?prof:1-(1-_kn)*fexp(-(prof-_kn)/(1-_kn));
      edgeArr[c]=prof<=0?0:depth*(0.25+0.75*_p);
    }
    // Put the deck where the satellite says the cloud IS (Elemental). It
    // REDISTRIBUTES - the profile over its own mean - so the amount stays the
    // model's and only the arrangement comes from the picture. Same mapping as
    // radar: the frame is a 0.42 slice of the 900 km window, mirrored when he
    // faces south-ish so west stays on the correct side.
    if(SAT && SAT.profile && Date.now()/1000-SAT.at<3600){
      const pr=SAT.profile, mean=pr.reduce((a,b)=>a+b,0)/pr.length;
      if(mean>0.02){
        const mirror=(FACING_AZ>90&&FACING_AZ<270), k=0.45*(SAT.confidence||0);
        for(let c=0;c<COLS;c++){
          let t=(c/Math.max(1,COLS-1)-0.5)*0.42+0.5; if(mirror) t=1-t;
          const fi=t*(pr.length-1), i0=Math.max(0,Math.min(pr.length-1,fi|0)), i1=Math.min(pr.length-1,i0+1), f=fi-i0;
          const rel=(pr[i0]*(1-f)+pr[i1]*f)/mean;
          edgeArr[c]*=Math.max(0.25,Math.min(2.2,1+(rel-1)*k));
        }
      }
    }
  }
  // rain/snow streaks
  // Rain falls in music mode too (28 Sep: "the falling rain is not visible" -
  // music plays most of the day and it used to switch the weather off).
  if(wet){
    const rainIntensity=scKind==="snow"?Math.min(1,scSnow/4):(scKind==="thunder"?Math.min(1,0.5+scRain/8):Math.min(1,scRain/6));
    const rate=Math.max(0.08, Math.min(0.95, rainIntensity*0.9 + covF*0.15));
    const maxStreaks=Math.round(30+rainIntensity*90);
    const baseSpeed=scKind==="snow"?(0.15+rainIntensity*0.25):(0.6+rainIntensity*1.2+scWind*0.02);
    if(Math.random()<rate && streaks.length<maxStreaks){
      for(let tries=0;tries<6;tries++){
        const c=radarColumn(COLS);
        if(inMusic||edgeArr[c]>0){
          // One cross-screen wind (Elemental 0.6). This had the slant reversed.
          const _cw=crossWindKmh();
          // slope = horizontal cells travelled per vertical cell. Because it is
          // wind / fall-speed, fast rain in light air stays near vertical while
          // slow snow in a gale goes almost sideways - that falls out for free.
          const fall=Math.max(baseSpeed,0.05);
          const push=_cw/22;
          const slope=Math.max(-2.5,Math.min(2.5,push/fall));
          streaks.push({c:c, y:(inMusic?0:edgeArr[c]/SP),
            len:GRID_K*(scKind==="snow"?(2+Math.random()*2):(3+rainIntensity*5+Math.random()*3)),
            v:GRID_K*baseSpeed*(0.7+Math.random()*0.6), slope:slope});
          break;
        }
      }
    }
    // the head moves along the slope as it falls; the trail lags behind it
    for(let i=streaks.length-1;i>=0;i--){ const s=streaks[i]; s.y+=s.v; s.c+=s.v*s.slope;
      if(s.y-s.len>ROWS || s.c<-3 || s.c>COLS+3) streaks.splice(i,1); }
  }
  // a slanted streak spans several columns, so register it in each one it crosses
  const colMap=new Array(COLS);
  for(const s of streaks){
    const cHead=s.c, cTail=s.c-s.slope*s.len;
    let lo=Math.floor(Math.min(cHead,cTail)-0.6), hi=Math.ceil(Math.max(cHead,cTail)+0.6);
    if(lo<0)lo=0; if(hi>COLS-1)hi=COLS-1;
    for(let cc=lo;cc<=hi;cc++) (colMap[cc]||(colMap[cc]=[])).push(s);
  }
  // thunder
  if(!inMusic && scKind==="thunder"&&sec>nextBolt&&!bolt){
    for(let tries=0;tries<8;tries++){
      const c=(Math.random()*COLS)|0;
      if(edgeArr[c]>0){
        const pts=[]; let bx2=c*SP, by2=edgeArr[c]*0.5;
        while(by2<H*0.96){ pts.push([bx2,by2]); by2+=SP*1.6; bx2+=(Math.random()-0.5)*SP*2.4; }
        bolt={pts:pts,t0:sec}; break;
      }
    }
    if(!bolt) nextBolt=sec+6;
  }
  if(bolt&&sec-bolt.t0>0.22){ flashT=sec; bolt=null; nextBolt=sec+16+Math.random()*24; }
  const ft=sec-flashT;
  const flashAmp=(!inMusic&&ft>=0&&ft<0.7)?Math.max(0,fexp(-ft*5.5)*(0.55+0.45*fsin(ft*46))):0;
  // shooting star
  if(!inMusic&&sAlt<-4&&(scKind==="sun"||scKind==="partly")){
    if(sec>shootT&&!shoot){ shoot={x:W*(0.1+0.5*Math.random()),y:H*(0.06+0.18*Math.random()),t0:sec};
      shootT=sec+120+Math.random()*240; }
    if(shoot&&sec-shoot.t0>0.8) shoot=null;
  }
  // UV-driven light pockets (pre-compute once per frame)
  const uvNorm=Math.max(0,Math.min(1,scUV/11));
  const visNorm=Math.max(0.1,Math.min(1,scVis/10000));
  const lightAmt=uvNorm*visNorm*(1-covF*0.7)*skyBrAmt;
  const bp=[];
  if(!inMusic){
    for(let bi=0;bi<breathers.length;bi++){
      const B=breathers[bi];
      if(bi>1 && lightAmt<0.3) continue;
      if(bi>3 && lightAmt<0.6) continue;
      const bpx=B.ax+fsin(sec*B.s1+B.ph)*W*0.08;
      const bpy=B.ay+fcos(sec*B.s2+B.ph*1.3)*H*0.06;
      const bpr=B.R*(0.6+lightAmt*0.6);
      const bpp=Math.pow(0.5+0.5*fsin(sec*6.2832/B.per+B.ph2),2.2)*lightAmt*0.8;
      bp.push({x:bpx,y:bpy,R:bpr,invR:1/bpr,p:bpp});
    }
  }
  const moonR=Math.min(W,H)*0.10;
  const sunDiscR=Math.min(W,H)*0.05;
  // map alt/az to screen using FACING_AZ (alt 0=horizon,90=zenith; az relative to facing)
  function _astroXY(alt,az){
    const relAz=((az-FACING_AZ+180+360)%360)-180;
    const x=(0.5+relAz/190)*W;
    const y=(1-alt/85)*H;
    return {x,y};
  }
  const _sun=_astroXY(astroNow.sunAlt,astroNow.sunAz);
  const sunX=_sun.x, sunY=_sun.y;
  const _moon=_astroXY(astroNow.moonAlt,astroNow.moonAz);
  const moonX=_moon.x, moonY=_moon.y;
  const moonAbove=astroNow.moonAlt>0;
  const uvAmp=0.15+Math.min(1,scUV/11)*0.85*visNorm;
  // Cloud by altitude. If the layer split is missing, all cover goes to the
  // LOW deck: an unoccluded moon blazing through overcast is the wrong failure.
  let _cLo, _cMid, _cHi;
  if(scCldLo==null && scCldMid==null && scCldHi==null){ _cLo=covF; _cMid=0; _cHi=0; }
  else { _cLo=_c01((scCldLo||0)/100); _cMid=_c01((scCldMid||0)/100); _cHi=_c01((scCldHi||0)/100);
    const _comb=1-(1-_cLo)*(1-_cMid)*(1-_cHi);
    // Only when the bands are the MODEL's: once METAR has given them by altitude
    // (metarBands), its total is not evidence of a missing low deck - layers
    // are cumulative, so the bands never add up to the total (Elemental).
    if(!window.__metarBandsOn && covF>_comb+0.10) _cLo=_c01(_cLo+(covF-_comb));
    // The satellite is a photograph of the sky over the roof; the model is a
    // box average. Where they disagree about what is overhead the photograph
    // wins - but only for the LOW deck, and only when the tops are warm: a cold
    // top is cirrus and says nothing about what is under it (Elemental).
    if(SAT && Date.now()/1000-SAT.at<3600){
      const warm=1-_c01((SAT.topness-0.35)/0.35), share=0.5*warm*(SAT.confidence||0);
      _cLo=_c01(_cLo*(1-share)+(SAT.here||0)*share);
    }
  }
  // The existing deck's extent follows total cover; its OPACITY now follows the
  // low/mid share, so a sky of pure cirrus no longer paints a solid lid.
  const _lowShare=_c01(Math.max(_cLo,_cMid*0.5)/Math.max(0.05,covF));
  if(!inMusic) _deckRefresh(W,H,sec,_cHi>0.02,_cMid>0.02,true);
  // An overcast IS flat: as cover closes the deck's holes close with it.
  const _loClose=_c01((_cLo-0.72)/0.28);
  const _twH=_twLit(sAlt,1);
  // (try: the first scene can run before the furniture state below is declared)
  let _snowD=null, _furnM=null;
  try{ _snowD=inMusic?null:_snowGrid(); _furnM=(!inMusic&&wet)?_furnMask():null; }catch(_){}
  let _leafD=null; try{ _leafD=inMusic?null:_leafGrid(); }catch(_){}
  let _festD=null; try{ _festD=inMusic?null:_festGrid(); }catch(_){}
  const _refK=1080/H, _uvNorm=Math.min(1,scUV/11);
  if(!_stA||_stA.length!==COLS*ROWS) _stA=new Float32Array(COLS*ROWS);
  const _ecl=_lunarEclipse(Date.now(), astroNow?astroNow.moonAlt:-90);
  const _mIll=Math.max(0,Math.min(1,((astroNow&&astroNow.moonIllum)||0)/100));
  // Blanket dimming by the cover NUMBER double-counts once real occlusion is in.
  const sunDim=1-covF*0.25;
  const moonDim=1-covF*0.15;
  // nightCloudDim computed above in sky engine block
  const fog=(scCode===45||scCode===48);
  const glass=(STYLE==="glass");
  const data=glass?cimg.data:null;
  // 16 Nov, his: in dots "the screen keeps refreshing for no reason". This pass is sliced over several
  // frames, and dots were drawn straight onto the visible canvas after wiping it - so every pass showed
  // an empty wall filling in from the top. Dots are now painted off-screen and shown whole, as glass is.
  let dctx=null;
  if(!glass){
    if(!window.__dotCv || __dotCv.width!==scene.width || __dotCv.height!==scene.height){
      window.__dotCv=document.createElement("canvas"); __dotCv.width=scene.width; __dotCv.height=scene.height;
      window.__dotCx=__dotCv.getContext("2d");
    }
    dctx=window.__dotCx; dctx.setTransform(sctx.getTransform()); dctx.clearRect(0,0,W,H);
  }
  // real sun altitude drives everything
  // pre-compute sky colour per row (O(ROWS) not O(ROWS*COLS))
  const _SKX=16, _sunAzD=(astroNow&&astroNow.sunAz!=null)?astroNow.sunAz:180;
  const _tauA=Math.max(0.02,Math.min(2,scAOD>0?scAOD:0.12));
  const _deckF=ELB_SKY?_c01(1-(1-_cLo)*(1-_cMid*0.80)*(1-_cHi*0.22)):_c01(Math.max(_cLo,_cMid*0.7)), _gloomF=_c01((scPrecip||0)/2.5);   // Elemental deckOpaque
  if(!_skyCR||_skyCR.length!==COLS*ROWS){ _skyCR=new Float32Array(COLS*ROWS); _skyCG=new Float32Array(COLS*ROWS); _skyCB=new Float32Array(COLS*ROWS); _skyLL=new Float32Array(COLS*ROWS); }
  if(!window.__skyGT || performance.now()-window.__skyGT>1500 || window.__skyGN!==COLS*ROWS){ window.__skyGT=performance.now(); window.__skyGN=COLS*ROWS;
    const g=new Float32Array((_SKX+1)*3);
    for(let _iy=0;_iy<ROWS;_iy++){
      for(let j=0;j<=_SKX;j++){
        const cellAz=FACING_AZ+(j/_SKX-0.5)*190, dAz=((cellAz-_sunAzD)%360+540)%360-180;
        const q=(ELB_SKY?_skyE:_skyPhys)(skySAlt,_iy/ROWS,dAz,aqiF,_deckF,smokeF,_gloomF,_tauA);
        g[j*3]=q.r; g[j*3+1]=q.g; g[j*3+2]=q.b;
      }
      for(let _ix=0;_ix<COLS;_ix++){
        const u=(COLS>1?_ix/(COLS-1):0.5)*_SKX, j0=Math.min(_SKX-1,u|0), fr=u-j0;
        const r=g[j0*3]+(g[j0*3+3]-g[j0*3])*fr, gg2=g[j0*3+1]+(g[j0*3+4]-g[j0*3+1])*fr, b=g[j0*3+2]+(g[j0*3+5]-g[j0*3+2])*fr;
        const sl=Math.max(4,r*0.299+gg2*0.587+b*0.114), k=_iy*COLS+_ix;
        _skyCR[k]=1+(r/sl-1)*0.82; _skyCG[k]=1+(gg2/sl-1)*0.82; _skyCB[k]=1+(b/sl-1)*0.82; _skyLL[k]=sl;
      }
    }
  }
  const skyRows=[];
  for(let _iy=0;_iy<ROWS;_iy++){
    // Row value (screen centre) for the music-mode back wall.
    const _s=_skyPhys(skySAlt,_iy/ROWS,((FACING_AZ-_sunAzD)%360+540)%360-180,aqiF,_deckF,smokeF,_gloomF,_tauA);
    // The sky's CHROMA, normalised to unit luminance, cached per row.
    //
    // The tint blend below used to be weighted by the sky's own BRIGHTNESS
    // (`* lumaOf(sky)/210`). At night, when the sky is at its most colourful in
    // relative terms, that factor falls to about 2% - so the hue never arrives
    // and the whole wall renders as neutral grey tiles. It is the single
    // biggest reason a night scene reads flat: with no hue anywhere, nothing
    // separates from anything.
    //
    // Take the hue and re-light it at the CELL's own brightness instead, so a
    // dark sky tints just as strongly as a bright one. 0.82 keeps a little of
    // the neutral so saturated skies do not go lurid.
    const _sl=Math.max(4,_s.r*0.299+_s.g*0.587+_s.b*0.114);
    _s.cR=1+(_s.r/_sl-1)*0.82; _s.cG=1+(_s.g/_sl-1)*0.82; _s.cB=1+(_s.b/_sl-1)*0.82;
    _s.L=_sl;
    skyRows.push(_s);
  }
  // update body sky gradient (throttled — cheap CSS var change)
  if(t-_skyBgTs>1800){
    _skyBgTs=t;
    { const _ah=$("aqiHaze"); if(_ah){ const bf=Math.max(0,Math.min(1,(scAQI-50)/200)); const _o=bf*skyBrAmt; _ah.style.opacity=_o.toFixed(3); _ah.style.display=(_o>0.004)?'':'none'; } }
    const skZ=skyRows[0],skH=skyRows[ROWS-1];
    // NOT root custom properties any more (24 Sep). Writing --sky-* on :root
    // made WebKit restyle every element on the page every 1.8 s - a ~300 ms
    // stall on the Pi, the jitter he kept seeing. The only visual user is the
    // body gradient, which the opaque mosaic covers except in music mode, so:
    // keep the colour in JS, and repaint the body only in music, only on change.
    _mSky=[skH.r|0, skH.g|0, skH.b|0];
    if(document.body.classList.contains("music")){
      const _k=`${skZ.r|0},${skZ.g|0},${skZ.b|0}|${skH.r|0},${skH.g|0},${skH.b|0}`;
      if(_k!==window.__skyBodyKey){ window.__skyBodyKey=_k;
        document.body.style.background=`linear-gradient(180deg,rgb(${skZ.r|0},${skZ.g|0},${skZ.b|0}) 0%,rgb(${skH.r|0},${skH.g|0},${skH.b|0}) 100%)`; }
    }
  }
  // night floor boost: raise dark cells so grid is visible against sky background
  const nightBoost=Math.round(Math.max(0,0.92-skyBrAmt)*(9+(moonAbove?astroNow.moonIllum*0.17:0))); // dark by default, moonlight lifts it
  let cbase;
  if(scKind==="thunder") cbase=82; else if(scKind==="rain") cbase=110;
  else if(scKind==="snow") cbase=205; else if(scKind==="cloud") cbase=170; else cbase=218;
  cbase*=skyBrAmt; // continuous day/night scaling — replaces binary *=0.55
  // night clouds: dimmed continuously by sky brightness
  const nightCloudDim=0.38+skyBrAmt*0.62;
  // pre-compute sun/moon inverse distances
  const invSunR=1/(H*0.45), invSunRip=1/(W*0.75), invMoonGlow=1/(moonR*0.8);
  const invH=1/H;
  // water is a property of the cells, so the pane has to be stepped BEFORE they
  // are shaded, not painted over them afterwards
  stepPaneWater(dt,W,H,SP);
  const pwKind=(scKind==="snow")?0.75:1;      // snow wets the pane less than rain
  const pwGrimeOn=pwGrimeAmt>0.004, pwSteamOn=pwSteam>0.004;
  const pwOn=(pwAmbient>0.004)||pwGrimeOn||pwSteamOn||!!wetGrid;
  // Stars bucketed by tile once per scene: a star lights only tiles within
  // 1.4 cells of it, but every tile used to test every star in the sky.
  let _starB=null;
  if(starPx && starPx.length){
    _starB=new Array(COLS*ROWS);
    for(let si=0;si<starPx.length;si++){
      const st=starPx[si], cx=Math.floor(st.x01*W/SP), cy=Math.floor(st.y01*H/SP);
      for(let oy=-2;oy<=2;oy++) for(let ox=-2;ox<=2;ox++){
        const X=cx+ox, Y=cy+oy; if(X<0||Y<0||X>=COLS||Y>=ROWS) continue;
        const k=Y*COLS+X; (_starB[k]||(_starB[k]=[])).push(st);
      }
    }
  }
  const _vp=inMusic?vizNow(sec):0;
  for(let iy=0;iy<ROWS;iy++){
    const y=iy*SP;
    for(let ix=0;ix<COLS;ix++){
      const x=ix*SP, idx=iy*COLS+ix;
      let R0,G0,B0,lum;
      if(inMusic){
        if(hasArtGrid){
          // LIVING ART (26 Sep, replaces the bars): the cover's own colours
          // flow like liquid - a slow domain warp over the softened art - and
          // the song's beat swells the swirl and the light on every kick.
          const u=ix/COLS, v=iy/ROWS, amp=0.010+0.016*_vp;      // a drift, not a warp
          let su=u+amp*fsin(v*3.1+sec*0.21+1.3)+0.006*fsin((u+v)*4.3-sec*0.14);
          let sv=v+amp*fsin(u*2.7-sec*0.18+4.1)+0.006*fsin((u-v)*3.7+sec*0.11);
          su=((su%2)+2)%2; if(su>1) su=2-su;              // mirror at the edges
          sv=((sv%2)+2)%2; if(sv>1) sv=2-sv;
          const ai=(Math.min(ROWS-1,Math.floor(sv*ROWS))*COLS+Math.min(COLS-1,Math.floor(su*COLS)))*4;
          const src=artGrid;                                   // sharp: the cover, in tiles
          const lift=(0.92+0.30*_vp)*(0.96+0.04*fsin(sec*0.8+dotPh[idx]*2));   // the cover at full strength, swelling on the beat
          R0=Math.min(255,Math.max(6,src[ai]*lift));
          G0=Math.min(255,Math.max(8,src[ai+1]*lift));
          B0=Math.min(255,Math.max(12,src[ai+2]*lift));
        } else {
          R0=12; G0=14; B0=18;
        }
        const _cs=wet?colMap[ix]:null;
        if(_cs){
          for(let si=0;si<_cs.length;si++){
            const s=_cs[si], dy2=s.y-iy;
            if(dy2<0||dy2>=s.len) continue;
            const hcov=1-Math.abs(s.c-s.slope*dy2-ix)/(0.5+0.5*Math.min(2.5,Math.abs(s.slope)));
            if(hcov<=0) continue;
            const k=(1-dy2/s.len)*hcov*0.55;
            const tr=scKind==="snow"?245:190, tg=scKind==="snow"?248:215, tb=255;
            R0+=(tr-R0)*k; G0+=(tg-G0)*k; B0+=(tb-B0)*k;
          }
        }
        lum=(R0+G0+B0)*0.333;
      } else {
        // weather mode
        let L=13+9*fsin(x*0.013+y*0.006+dotPh[idx]*0.3);
        // subtle sweep
        const sw2=x+y*0.55-((sec*10)%(W*1.7))+W*0.2;
        const swn=sw2/(W*0.16);
        L+=14*fexp(-swn*swn);
        // humidity haze
        if(humidF>0.2) L+=humidF*18*fsin(x*0.008+y*0.01+sec*0.05);
        let cr=0,cg=0,cb=0, w=0;
        // DEPTH (Elemental): cloud opacity per layer FIRST, so what is behind
        // it - sun, moon, stars - is dimmed by exactly what is in the way.
        const _yF=y/H, _px=x*_refK, _py=y*_refK;
        let highAmt=0, midAmt=0, lowThick=0;
        if(_cHi>0.02){ const veil=_c01(1.4-_yF*1.3);
          const fib=0.5+1.2*_dfHi[idx];
          highAmt=_c01(fib*_cHi*veil*1.25-0.18); }
        if(_cMid>0.02){ const band=_c01(1.15-Math.abs(_yF-0.28)*2.2);
          const midN=0.5+1.1*_dfMid[idx];
          midAmt=_c01(midN*_cMid*band*1.35-0.22); }
        // The low deck's own structure, recentred on 1 so it VARIES the deck
        // rather than thinning it; closes up as cover goes total.
        const _lowF=_dfLo[idx], _lowDen=(v=>v+(1-v)*_loClose)(Math.max(0.38,Math.min(1.32,1+1.25*_lowF)));
        { const eY0=edgeArr[ix]; if(eY0>0&&y<eY0){ const d0=1-y/eY0; lowThick=d0*d0*(3-2*d0)*Math.min(1,0.35+_cLo)*_lowShare*_lowDen; } }
        const seeThrough=1-_c01(1-(1-highAmt*0.22)*(1-midAmt*0.78)*(1-lowThick*0.97));
        const scatterC=highAmt*0.85+midAmt*0.35+lowThick*nightCloudDim*0.06;
        _stA[idx]=seeThrough;
        // breather light pockets
        for(let bi=0;bi<bp.length;bi++){
          const B=bp[bi]; const gx=x-B.x, gy=y-B.y;
          const gd2=gx*gx+gy*gy;
          const thresh=B.R*2.2;
          if(gd2<thresh*thresh){
            const gd=Math.sqrt(gd2);
            const g2=fexp(-gd*B.invR)*B.p;
            L+=g2*(skyBrAmt>0.5?120:100);
            const ww2=Math.min(0.6,g2*0.8);
            if(ww2>w){w=ww2; cr=248;cg=250;cb=255;}
          }
        }
        // sun — visible when above (or just below) horizon
        if(sAlt>-1.5){
          const sunV=Math.max(0,Math.min(1,(sAlt+1.5)/3)); // fade near horizon
          const dx=x-sunX, dy=y-sunY, d=Math.sqrt(dx*dx+dy*dy);
          const punch=Math.pow(seeThrough,2.2)*(1+_uvNorm*1.4*seeThrough);
          const glow=fexp(-d*invSunR)*uvAmp*sunDim*sunV*punch;
          const ripSpeed=0.15+Math.min(1,scUV/11)*0.25;
          const rip=fsin(d*0.03-sec*ripSpeed)*fexp(-d*invSunRip)*uvAmp*sunDim*sunV*_c01((seeThrough-0.18)/0.32);
          L+=glow*130+(rip>0?rip*46:0);
          const sunC=_sunTint(sAlt,aqiF);
          const ww=Math.min(1,(glow*1.6+(rip>0?rip*0.5:0))*sunDim);
          if(ww>w){w=ww; cr=sunC.r;cg=sunC.g;cb=sunC.b;}
          // solar disc: round core, soft radial falloff; weight kept < thick-cloud max so clouds pass in front
          if(d<sunDiscR*1.7){
            const _c=Math.max(0,1-d/(sunDiscR*1.7)), diskI=_c*_c;
            if(diskI>0.03){
              // the disc reads as "sunny" even at low weight, so dim it harder
              // than the glow does - a full overcast must not punch a sun through
              const discDim=1-covF*0.30;
              L=Math.max(L,(150+diskI*120)*discDim*seeThrough);
              const ww3=diskI*0.82*sunV*discDim*seeThrough;
              if(ww3>w){ w=ww3; cr=sunC.r; cg=Math.min(255,sunC.g+16); cb=Math.min(255,sunC.b+30); }
            }
          }
        }
        // stars + moon: become visible from civil twilight onward
        if(sAlt<0){
          // stars: fully visible in astronomical night (sAlt<-18), fade in from -6
          const starBase=seeThrough*seeThrough*(1-aqiF*0.55);
          const starVis=starBase*Math.max(0,(-sAlt-6)/14);
          if(starBase>0.02 && starPx){            // starBase opens it: a planet is up in twilight, before any star
            const _sl=_starB?_starB[idx]:starPx;
            if(_sl) for(let si=0;si<_sl.length;si++){
              const st=_sl[si];
              const sv1=st.pk ? Math.max(starVis, starBase*_plTwi(sAlt,st.br)) : starVis;
              if(sv1<=0.02) continue;
              const sx=st.x01*W, sy=st.y01*H;
              const ddx=(x-sx)/SP, ddy=(y-sy)/SP;
              if(Math.abs(ddx)<1.4&&Math.abs(ddy)<1.4){
                const twinkle=st.pk ? 1 : 1+0.07*fsin(sec*1.5+dotPh[idx]*3.14);   // a planet holds steady
                L+=sv1*st.br*55*_STARK*twinkle*seeThrough*Math.max(0,1-Math.sqrt(ddx*ddx+ddy*ddy));
              }
            }
          }
          // moon - address the cell by its CENTRE. Using the top-left corner puts
          // the coarse disc half a cell right and down of the detail pass, which
          // shows up as bright squares hanging off the lower-right limb.
          const mx=x+SP*0.5-moonX, my=y+SP*0.5-moonY;
          const md2=mx*mx+my*my;
          if(md2<moonR*moonR && moonAbove){
            // The phase is SUBTRACTED from the face, it does not cut a hole in
            // it. The whole disc is drawn, every cell inside the limb; the
            // terminator only decides how each cell is lit. Asserting a near
            // black at full weight for the shaded side made the moon read as a
            // hole punched in the sky, and a gibbous read as a bright column
            // rather than a sphere - the round limb has to be complete for the
            // eye to pick the shape up at all.
            const litF=litSide(mx,my,moonR)?1:0;   // hard step: the edge stays blocky
            const v=moonSample(mx/moonR,my/moonR);
            // Lit-face brightness is NOT proportional to the illuminated
            // fraction. A half moon's lit half is as bright per unit area as a
            // full moon's - what phase changes is how MUCH of it there is. The
            // old max(0.15,illum/100) made a crescent's sliver four times too
            // dim, dropping it to within a few levels of earthshine and erasing
            // the terminator at exactly the phases where it IS the shape.
            const k=Math.min(1,_moonLitRef(astroNow.moonIllum,moonDim)*v/255);
            // Earthshine is FLAT - Earth-light on ground the sun is not
            // reaching, so the maria do not show in it. Multiplying it by the
            // albedo is what drove the shaded limb to black.
            const eL=_moonEarthRef(astroNow.moonIllum,moonDim);
            if(litF){ w=1; cr=236*k; cg=240*k; cb=252*k; }
            else{
              // The shaded face is the earthshine COLOUR at the earthshine
              // LUMINANCE. (106,112,136) carries a luma of 113, so it is scaled
              // to land on eL - otherwise the dark side renders at about a
              // third of white, close enough to the lit face's maria that the
              // terminator stops reading as an edge at all (measured: shaded 78
              // against maria at 100, on a face peaking at 202).
              const eS=eL/113;
              w=1; cr=106*eS; cg=112*eS; cb=136*eS;
            }
            // Eclipse: not a black bite - the umbra is lit copper by every
            // sunrise and sunset on earth at once (Elemental).
            if(_ecl>0.01){ const cp=0.55+0.45*litF;
              cr+=(152*cp-cr)*_ecl; cg+=(58*cp-cg)*_ecl; cb+=(34*cp-cb)*_ecl; }
          } else if(moonAbove && md2<moonR*moonR*(2.6+scatterC*3.2)*(2.6+scatterC*3.2)){
            // Reach now grows with the cloud the light is scattering in (Elemental).
            // Halo, and a contrast socket just outside it. A flat 26 reaching
            // 1.8 radii is invisible against a lifted night sky, so it scales
            // with illumination, reaches 2.6 radii, and falls off inverse
            // rather than linear - bright near ring, long tail. The socket
            // pulls the sky DOWN past the glow: nothing in the sky actually
            // darkens near the moon, but the eye adapts to the bright source
            // and reads the surround as darker. Reproducing that is the
            // difference between an object sitting IN the sky and one pasted ON
            // it.
            const illum=_mIll*(1-_ecl*0.9), reach=2.6+scatterC*3.2;
            const tt=(Math.sqrt(md2)-moonR)/(moonR*(reach-1));
            if(tt<1){
              const amp=(16+62*illum)*moonDim*Math.max(seeThrough,scatterC);
              L+=amp*Math.max(0,1/(1+tt*20)-1/21);
              const ring=1-Math.abs(tt-0.72)/0.28;
              if(ring>0) L-=ring*ring*9*illum*seeThrough;
            }
          }
          // Light that gets through cloud scatters IN it (Elemental, two laws):
          // translucent ice diffuses it (glow rises with amount); an opaque deck
          // only lets its ragged fringe glow - the silver lining.
          if(moonAbove){ const prox=fexp(-Math.sqrt(md2)/(moonR*2.1))*_mIll*(1-_ecl*0.9)*(1-skyBrAmt*0.65);
            if(prox>0.004) L+=((highAmt+midAmt*0.5)*60+4*lowThick*(1-lowThick)*70)*prox; }
        }
        // cloud deck (dimmed at night via nightCloudDim)
        // High cirrus, then mid, composited OVER (not winner-takes-all), so a
        // cloud can pass in front of the moon instead of being pasted under it.
        if(highAmt>0.004){ let hc=_cloudTint(sAlt,1,Math.min(235,cbase*1.08)), a=highAmt*0.55;
          // Cirrus is ten km up: it keeps the sun for degrees after the ground
          // has lost it and goes salmon -> pink -> mauve while the sky behind it
          // is already deep blue. Its colour is its own light, not a coverage.
          const _glow=_twH[0]*_twH[1];
          if(_glow>0.001){ const tc=_twColour(sAlt), gk=Math.min(1,_glow*0.96);
            hc={r:hc.r+(tc.r-hc.r)*gk, g:hc.g+(tc.g-hc.g)*gk, b:hc.b+(tc.b-hc.b)*gk};
            a=Math.max(a,Math.min(1,highAmt*_glow*1.6)); L+=highAmt*_glow*96; }
          const nw=w+(1-w)*a, k2=nw>1e-4?a/nw:0; cr+=(hc.r-cr)*k2; cg+=(hc.g-cg)*k2; cb+=(hc.b-cb)*k2; w=nw;
          L+=highAmt*(skyBrAmt>0.5?26:6); }
        if(midAmt>0.004){ const mc=_cloudTint(sAlt,0.8,Math.min(235,cbase*0.92)), a=midAmt*0.80*nightCloudDim;
          const nw=w+(1-w)*a, k2=nw>1e-4?a/nw:0; cr+=(mc.r-cr)*k2; cg+=(mc.g-cg)*k2; cb+=(mc.b-cb)*k2; w=nw;
          L+=midAmt*(skyBrAmt>0.5?30:8)*nightCloudDim; }
        const eY=edgeArr[ix];
        if(eY>0&&y<eY){
          const d2=1-y/eY;
          const kk=d2*d2*(3-2*d2)*Math.min(1,0.35+_cLo)*nightCloudDim*_lowShare*Math.min(1,_lowDen);
          const lx=x-sunX, ly=y-sunY;
          const light=fexp(-Math.sqrt(lx*lx+ly*ly)/(H*0.5));
          // The thick parts hang darker, the thin parts glow: the same field as
          // the density, so a closed sky has relief instead of a smooth wash.
          let shade=cbase*(0.55+0.45*(1-d2))*(0.75+0.55*light)*(1-0.30*_lowF);
          if(shade>235)shade=235;
          const cloudC=_cloudTint(sAlt,light,shade);
          const ww=kk*0.95;
          { const nw=w+(1-w)*ww, k2=nw>1e-4?ww/nw:0; cr+=(cloudC.r-cr)*k2; cg+=(cloudC.g-cg)*k2; cb+=(cloudC.b-cb)*k2; w=nw; }
          L+=kk*(skyBrAmt>0.5?55:12);
        }
        // rain/snow
        const cs2=(_furnM&&_furnM[idx])?null:colMap[ix];
        if(cs2){
          for(let si=0;si<cs2.length;si++){
            const s=cs2[si]; const dy2=s.y-iy;
            if(dy2>=0&&dy2<s.len){
              // where the trail sits in this row, and how much of this cell it covers
              const scol=s.c-s.slope*dy2;
              const hw=0.5+0.5*Math.min(2.5,Math.abs(s.slope));
              const hcov=1-Math.abs(scol-ix)/hw;
              if(hcov>0){
                const kx=(1-dy2/s.len)*hcov;
                L+=kx*(scKind==="snow"?70:85);
                const a=kx*0.8, nw=w+(1-w)*a, k2=nw>1e-4?a/nw:0;
                const rr=scKind==="snow"?240:165, rg=scKind==="snow"?246:208, rb=255;
                cr+=(rr-cr)*k2; cg+=(rg-cg)*k2; cb+=(rb-cb)*k2; w=nw;
              }
            }
          }
        }
        // fog
        if(fog){ const fogD=Math.max(0.3,1-scVis/5000); L+=fogD*(40*fsin(y*0.02+sec*0.15)+46);
          const fw=fogD*0.7; if(fw>w){w=fw; cr=170;cg=175;cb=185;} }
        // bolt + flash
        if(bolt){
          for(const p2 of bolt.pts){ const qx=x-p2[0],qy=y-p2[1];
            if(qx*qx+qy*qy<SP*SP*2.6){ w=1;cr=245;cg=240;cb=255;L=230; break; } }
        }
        if(flashAmp>0) L+=flashAmp*130;
        // shooting star
        if(shoot){
          const a2=(sec-shoot.t0)/0.8, hx=shoot.x+a2*W*0.26, hy=shoot.y+a2*W*0.26*0.35;
          const qx=x-hx,qy=y-hy; if(qx*qx+qy*qy<SP*SP*2) L+=150*fsin(Math.PI*a2);
        }
        if(f1track&&ix>=trackC0&&ix<=trackC1&&iy>=trackR0&&iy<=trackR1){
          const sh2=trackShadow[idx];
          if(sh2>0.01) L-=sh2*30;                          // soft grounding shadow
          const g=trackField[idx];
          if(g>0.14){
            if(g<0.36){ L-=(0.36-g)*24; }                  // soft moat, blends into mosaic
            else{
              let gg=(g-0.34)/0.55; if(gg>1)gg=1; const core=gg*gg*(3-2*gg);
              let dph=trkHead-trackT[idx]; if(dph<0)dph=-dph; if(dph>0.5)dph=1-dph;
              const pulse=fexp(-dph*dph*90);
              const el=trackElev[idx];
              L += core*(44+el*52) + pulse*core*72;         // gentle brightening, not a glaring ribbon
              const tw=Math.min(0.5, core*0.6 + pulse*core*0.5);   // low weight -> keeps the mosaic colour underneath
              if(tw>w){ w=tw; const edge=1-core;
                cr=234; cg=226-edge*22; cb=206-edge*44; }   // warm off-white, integrated
            }
          }
        }
        R0=L; G0=L+4; B0=L+11;
        if(w>0){ R0=R0+(cr-R0)*w; G0=G0+(cg-G0)*w; B0=B0+(cb-B0)*w; }
        R0=Math.min(255,Math.max(6,R0)); G0=Math.min(255,Math.max(8,G0)); B0=Math.min(255,Math.max(12,B0));
        lum=(R0+G0+B0)*0.333; _cellW=w;          // the cloud/body weight, for the sky blend below
      }
      if(glass){
        let gr,gg,gb;
        if(inMusic){ gr=R0; gg=G0; gb=B0; }
        else{
          // original LUT as base → full contrast grid pattern preserved
          const sky=_skyTmp; sky.cR=_skyCR[idx]; sky.cG=_skyCG[idx]; sky.cB=_skyCB[idx]; sky.L=_skyLL[idx];
          const li=Math.min(1,Math.max(0,lum/210));
          const bi=Math.min(255,Math.max(0,(lum|0)+nightBoost));
          gr=HR[bi]; gg=HG[bi]; gb=HB[bi];
          // sky ambient tint: shadows pick up sky hue, brights stay neutral
          // Sky hue, re-lit. Taking the cell's OWN brightness alone is what the
          // night needed, but applied at noon it also threw away the sky's real
          // contribution: daylight measured 38% darker (mean luma 96 -> 59).
          // The sky genuinely lights the scene by day and barely at all by
          // night, so let its luminance in proportionally to how bright it is.
          const tf=ELB_SKY?Math.min(0.97,ELB.tf0+Math.max(0,1-li)*ELB.tf1):0.34+Math.max(0,1-li)*0.42;
          const gl=gr*0.299+gg*0.587+gb*0.114;
          const tl=gl+(sky.L-gl)*(ELB_SKY?ELB.skyLight:SKY_LIGHT)*skyBrAmt;
          gr=gr+(sky.cR*tl-gr)*tf; gg=gg+(sky.cG*tl-gg)*tf; gb=gb+(sky.cB*tl-gb)*tf;
          // blend weather tint (sun/cloud/rain colour)
          if(R0!==G0||G0!==B0){
            const sat=Math.max(R0,G0,B0)-Math.min(R0,G0,B0);
            const sw=Math.min(0.97,sat/70)*Math.max(0.25,li);
            gr+=(R0-gr)*sw; gg+=(G0-gg)*sw; gb+=(B0-gb)*sw;
          }
        }
        if(flashAmp>0){ const fa=flashAmp*0.8; gr+=(255-gr)*fa; gg+=(255-gg)*fa; gb+=(255-gb)*fa; }
        if(_leafD){ const _lo=idx*4, _la=_leafD[_lo+3]; if(_la>0){ const sv=0.30+0.70*skyBrAmt;
          gr+=(_leafD[_lo]*sv-gr)*_la; gg+=(_leafD[_lo+1]*sv-gg)*_la; gb+=(_leafD[_lo+2]*sv-gb)*_la; } }
        if(_snowD&&_snowD[idx]>0){ const sk=_snowD[idx], sv=0.30+0.70*skyBrAmt;
          gr+=(236*sv-gr)*sk; gg+=(242*sv-gg)*sk; gb+=(252*sv-gb)*sk; }
        if(_festD){ const _fo=idx*5, _fa=_festD[_fo+3]; if(_fa>0){ const fr=_festD[_fo], fg=_festD[_fo+1], fb=_festD[_fo+2];
          if(_festD[_fo+4]>0){ gr+=(fr-gr)*_fa*0.8+fr*_fa*0.3; gg+=(fg-gg)*_fa*0.8+fg*_fa*0.3; gb+=(fb-gb)*_fa*0.8+fb*_fa*0.3; }
          else { const sv=0.30+0.70*skyBrAmt; gr+=(fr*sv-gr)*_fa*0.9; gg+=(fg*sv-gg)*_fa*0.9; gb+=(fb*sv-gb)*_fa*0.9; } } }
        if(pwOn&&!inMusic){
          const wk=Math.min((pwAmbient+(wetGrid?wetGrid[idx]:0))*pwKind,0.55);
          const gk=pwGrimeOn?Math.min(1,pwGrimeAmt*(0.6+0.8*dotPh[idx])):0;
          if(wk>0.004||gk>0.004||pwSteamOn){
            applyPaneMaterial(wk,gk,pwSteam,gr,gg,gb);
            gr=_wsR; gg=_wsG; gb=_wsB;
          }
        }
        gr=Math.round(gr/posterQ)*posterQ; gg=Math.round(gg/posterQ)*posterQ; gb=Math.round(gb/posterQ)*posterQ;
        const off=idx*4;
        data[off]=gr>255?255:(gr<0?0:gr|0); data[off+1]=gg>255?255:(gg<0?0:gg|0); data[off+2]=gb>255?255:(gb<0?0:gb|0); data[off+3]=255;
        if(sceneCol){const _sc=idx*3; sceneCol[_sc]=data[off]; sceneCol[_sc+1]=data[off+1]; sceneCol[_sc+2]=data[off+2];}
      } else {
        const sky=_skyTmp; sky.cR=_skyCR[idx]; sky.cG=_skyCG[idx]; sky.cB=_skyCB[idx]; sky.L=_skyLL[idx];
        const li=Math.min(1,Math.max(0,lum/210));
        const bi=Math.min(255,Math.max(0,(lum|0)+nightBoost));
        let gr=HR[bi], gg=HG[bi], gb=HB[bi];
        const tf=ELB_SKY?Math.min(0.97,ELB.tf0+Math.max(0,1-li)*ELB.tf1):0.34+Math.max(0,1-li)*0.42;
        const gl=gr*0.299+gg*0.587+gb*0.114;
        const tl=gl+(sky.L-gl)*(ELB_SKY?ELB.skyLight:SKY_LIGHT)*skyBrAmt;
        gr=gr+(sky.cR*tl-gr)*tf; gg=gg+(sky.cG*tl-gg)*tf; gb=gb+(sky.cB*tl-gb)*tf;
        if(R0!==G0||G0!==B0){
          const sat=Math.max(R0,G0,B0)-Math.min(R0,G0,B0);
          const sw=Math.min(0.97,sat/70)*Math.max(0.25,li);
          gr+=(R0-gr)*sw; gg+=(G0-gg)*sw; gb+=(B0-gb)*sw;
        }
        if(_leafD){ const _lo=idx*4, _la=_leafD[_lo+3]; if(_la>0){ const sv=0.30+0.70*skyBrAmt;
          gr+=(_leafD[_lo]*sv-gr)*_la; gg+=(_leafD[_lo+1]*sv-gg)*_la; gb+=(_leafD[_lo+2]*sv-gb)*_la; } }
        if(_snowD&&_snowD[idx]>0){ const sk=_snowD[idx], sv=0.30+0.70*skyBrAmt;
          gr+=(236*sv-gr)*sk; gg+=(242*sv-gg)*sk; gb+=(252*sv-gb)*sk; }
        if(_festD){ const _fo=idx*5, _fa=_festD[_fo+3]; if(_fa>0){ const fr=_festD[_fo], fg=_festD[_fo+1], fb=_festD[_fo+2];
          if(_festD[_fo+4]>0){ gr+=(fr-gr)*_fa*0.8+fr*_fa*0.3; gg+=(fg-gg)*_fa*0.8+fg*_fa*0.3; gb+=(fb-gb)*_fa*0.8+fb*_fa*0.3; }
          else { const sv=0.30+0.70*skyBrAmt; gr+=(fr*sv-gr)*_fa*0.9; gg+=(fg*sv-gg)*_fa*0.9; gb+=(fb*sv-gb)*_fa*0.9; } } }
        const lumN=lum/255; const ln=lumN>1?1:(lumN<0?0:lumN);
        let dotR=SP*(0.24+ln*0.46)*(0.90+0.10*fsin(sec*0.9+dotPh[idx]*6.28));
        if(f1track&&ix>=trackC0&&ix<=trackC1&&iy>=trackR0&&iy<=trackR1){ const g=trackField[idx];
          if(g>0.55){ let dph=trkHead-trackT[idx]; if(dph<0)dph=-dph; if(dph>0.5)dph=1-dph;
            dotR=SP*(0.12+0.07*fexp(-dph*dph*150)); }
          else if(g>0.14){ const gr=SP*(0.30+g*0.30); if(gr>dotR) dotR=gr; } }
        if(pwOn&&!inMusic){
          const wk=Math.min((pwAmbient+(wetGrid?wetGrid[idx]:0))*pwKind,0.55);
          const gk=pwGrimeOn?Math.min(1,pwGrimeAmt*(0.6+0.8*dotPh[idx])):0;
          if(wk>0.004||gk>0.004||pwSteamOn){
            applyPaneMaterial(wk,gk,pwSteam,gr,gg,gb);
            gr=_wsR; gg=_wsG; gb=_wsB;
          }
        }
        gr=Math.round(gr/posterQ)*posterQ; gg=Math.round(gg/posterQ)*posterQ; gb=Math.round(gb/posterQ)*posterQ;
        if(sceneCol){const _sc=idx*3; sceneCol[_sc]=gr|0; sceneCol[_sc+1]=gg|0; sceneCol[_sc+2]=gb|0;}
        dctx.fillStyle=`rgb(${gr|0},${gg|0},${gb|0})`;
        dctx.beginPath(); dctx.arc(x+SP*0.5,y+SP*0.5,dotR,0,6.29); dctx.fill();
      }
    }
    if(__ROWCHUNK>0 && (iy+1)%__ROWCHUNK===0 && iy+1<ROWS) yield;
  }
  __dsT.cells+=performance.now()-(window.__dsCellT0||performance.now());
  const __tb=performance.now();
  if(!glass){ sctx.save(); sctx.setTransform(1,0,0,1,0,0); sctx.clearRect(0,0,scene.width,scene.height);
    sctx.drawImage(window.__dotCv,0,0); sctx.restore(); }
  if(glass){
    const __elb=ELB_BLOCKS && (mode!=="music");
    if(__elb){ elbStep(performance.now()); cctx.putImageData(elbOk?elbColour():cimg,0,0); }
    else if(ELB_DEPTH && mode!=="music"){ elbDepth(performance.now()); cctx.putImageData(elbHok?elbColour():cimg,0,0); }
    else cctx.putImageData(cimg,0,0);
    sctx.imageSmoothingEnabled=false;
    sctx.drawImage(cell,0,0,COLS,ROWS,0,0,COLS*SP,ROWS*SP);
    if(__elb && elbOk) sctx.drawImage(elbCv,0,0);       // his Elemental blocks (see ELB)
    // The bevel was blitted here EVERY FRAME. It is a static grid that only
    // changes on resize, and it covers the whole surface - so this was a
    // second full-surface CPU blit per frame for an image that never
    // changed. It lives on its own canvas above this one now, painted
    // once, and the compositor keeps it there for free.
  }
  if(f1weekActive && fGlow && !inMusic && peekIdx<0){
    _fineAcc+=dt;
    if(_fineAcc>=0.8){ _fineAcc=0; renderTrackFine(t); }    // 14 Oct: ~1/s, not 12/s - 12k fine cells a pass took the wall to 21 fps
    if(fCanvas){ sctx.imageSmoothingEnabled=false;
      const _rx=fCX0*SP,_ry=fCY0*SP,_rw=(fCX1-fCX0)*SP,_rh=(fCY1-fCY0)*SP;
      if(STYLE!=="glass") sctx.clearRect(_rx,_ry,_rw,_rh);
      sctx.drawImage(fCanvas,0,0,fCols,fRows,_rx,_ry,_rw,_rh);
      if(STYLE==="glass" && fBevel) sctx.drawImage(fBevel,_rx,_ry);
    }
  }
  // Detail passes. Kept deliberately short - a thing earns one only if it
  // carries information the coarse grid destroys. Right now that's the moon
  // terminator and nothing else.
  if(!document.body.classList.contains("lowfx")){
    if(moonAbove && astroNow.sunAlt<0){
      const baseL=_moonLitRef(astroNow.moonIllum,moonDim);   // same ref as the coarse pass
      const wax=((astroNow.moonAge||0)%_MOON_SYN)<_MOON_SYN*0.5;   // same source as moonLitFrac
      const lvx=wax?1:-1, lvy=-0.42;          // sunward direction across the disc
      // 27 Sep, "the moon looks like an eye sore": the fine squares were painted
      // in a flat grey of their own (236,240,252) that never went through the
      // mosaic's ramp, sky tint or posterise - so they matched nothing around
      // them. Now every sub-cell takes the colour the MOSAIC gave the moon: the
      // rendered colour of the brightest fully-lit coarse cell on the disc, then
      // varied only by the albedo map's detail relative to that cell. Same
      // palette, same quantisation - finer tiles of the same wall.
      let _moonRefC=null, _moonRefV=1, _mBest=-1;
      if(sceneCol){
        const c0=Math.max(0,Math.floor((moonX-moonR)/SP)), c1=Math.min(COLS-1,Math.floor((moonX+moonR)/SP));
        const r0=Math.max(0,Math.floor((moonY-moonR)/SP)), r1=Math.min(ROWS-1,Math.floor((moonY+moonR)/SP));
        for(let yy=r0;yy<=r1;yy++) for(let xx=c0;xx<=c1;xx++){
          const dx=(xx+0.5)*SP-moonX, dy=(yy+0.5)*SP-moonY;
          if(dx*dx+dy*dy>moonR*moonR*0.8||!litSide(dx,dy,moonR)) continue;
          if((_stA?_stA[yy*COLS+xx]:1)<0.8) continue;              // not a cloud-covered cell
          const si=(yy*COLS+xx)*3, lm=sceneCol[si]*0.299+sceneCol[si+1]*0.587+sceneCol[si+2]*0.114;
          if(lm>_mBest){ _mBest=lm; _moonRefC=[sceneCol[si],sceneCol[si+1],sceneCol[si+2]]; _moonRefV=moonSample(dx/moonR,dy/moonR); }
        }
      }
      // Detail comes from SAMPLING A SOURCE MAP, not from hand-written zones.
      // For each coarse cell we sample the moon's albedo at its corners; where
      // local contrast clears a low threshold there is real detail there, so
      // that cell subdivides and its sub-pixels are filled from the map.
      // Swap moonMap() for a real photograph and nothing else changes.
      subdivideByMap(sctx, moonX, moonY, moonR, SP, W, H,
        (nx,ny)=>moonSample(nx,ny),                 // the source
        0.05,                                       // low threshold: catch detail
        (nx,ny,v,vCell)=>{
          const dx=nx*moonR, dy=ny*moonR;
          // Outside the disc there is no moon to draw. The terminator test is
          // meaningless there (chord goes to 0), but so is the ALBEDO: the map
          // reads 0 beyond the limb, so these sub-cells were being drawn at
          // luminance 0 - solid black squares hanging off the limb, which is
          // what made the moon look bitten into. Skip them; the coarse pass
          // already stopped at the limb.
          // 27 Sep: the lit side's EDGE - terminator and limb - follows the same
          // squares as the rest of the wall; subdivision is only the detail
          // inside them. So the coarse square decides lit/unlit and on/off the
          // disc (exactly the test the coarse pass used), never the sub-cell:
          // a fine staircase along the edge read as a different grid from the
          // background.
          { const ccx=(Math.floor((moonX+dx)/SP)+0.5)*SP-moonX, ccy=(Math.floor((moonY+dy)/SP)+0.5)*SP-moonY;
            if(ccx*ccx+ccy*ccy>=moonR*moonR) return null;
            if(!litSide(ccx,ccy,moonR)) return null; }  // shaded square: coarse earthshine stands
          // detail relative to what the coarse cell already used -> no seam
          const ratio=v/Math.max(vCell,0.05);
          // The detail pass paints over the coarse cells, so it must obey what
          // is in front of the moon too - or cloud and the eclipse only ever
          // showed at the limb (24 Sep). Mostly hidden: leave the coarse,
          // cloud-blended cell. Partly: dim. Eclipse: copper, and dark.
          const _cx=Math.floor((moonX+dx)/SP), _cy=Math.floor((moonY+dy)/SP);
          const _st=(_cx>=0&&_cy>=0&&_cx<COLS&&_cy<ROWS)?_stA[_cy*COLS+_cx]:1;
          if(_st<0.35) return null;
          const _ci=(_cx>=0&&_cy>=0&&_cx<COLS&&_cy<ROWS&&sceneCol)?(_cy*COLS+_cx)*3:-1;
          if(_moonRefC&&_ci>=0){
            // the mosaic's own lit-moon colour, carrying this spot's albedo
            const k=Math.max(0.55,Math.min(1.25,v/Math.max(_moonRefV,0.05)));
            let r=_moonRefC[0]*k, g=_moonRefC[1]*k, b=_moonRefC[2]*k;
            if(_ecl>0.01){ const e=1-0.55*_ecl; r+=(152*e*k-r)*_ecl; g+=(58*e*k-g)*_ecl; b+=(34*e*k-b)*_ecl; }
            // Cloud in front: fade into the coarse cell the cloud already made,
            // never down to black - that was the "holes" in an overcast moon.
            const a=Math.max(0,Math.min(1,(_st-0.35)/0.65));
            r=sceneCol[_ci]+(r-sceneCol[_ci])*a; g=sceneCol[_ci+1]+(g-sceneCol[_ci+1])*a; b=sceneCol[_ci+2]+(b-sceneCol[_ci+2])*a;
            r=Math.round(r/posterQ)*posterQ; g=Math.round(g/posterQ)*posterQ; b=Math.round(b/posterQ)*posterQ;
            return {r:Math.min(255,r), g:Math.min(255,g), b:Math.min(255,b), l:255, size:0.46};
          }
          let _l=baseL*vCell*ratio*_st, _r=236, _g=240, _b=252;
          if(_ecl>0.01){ _r+=(152-_r)*_ecl; _g+=(58-_g)*_ecl; _b+=(34-_b)*_ecl; _l*=1-0.55*_ecl; }
          return {r:_r,g:_g,b:_b, l:_l, size:0.46};
        }, 4,                                       // hardMax 4 (was 6): finer tiles, not graph paper
        null,                                       // the edge no longer splits: fixedDepth covers all
        3);                                         // every disc cell splits 3x3: one even finer grid
    }
    // Stars. One is far smaller than a mosaic cell, so a coarse dot renders it
    // as a blob. Here subdivision buys sharpness rather than size: snap to the
    // sub-grid and light a single sub-pixel. Only the brighter ones, only the
    // upper half - the rest stay as the soft coarse glow they already were.
    const sAltN=astroNow.sunAlt;
    if(sAltN<-0.5 && starPx && starPx.length){
      // Night sky answers to conditions the way the day sky does - cloud, haze,
      // fog and rain all thin the stars out. Floored, not zeroed: a fully
      // overcast night should look sparse, never dead.
      const _aqiF=Math.max(0,Math.min(1,((typeof scAQI!=="undefined"?scAQI:0)-50)/200));
      const _wx=(typeof scCode!=="undefined")?scCode:0;
      const _wet=(_wx>=51&&_wx<=99)?0.35:0, _fog=(_wx===45||_wx===48)?0.45:0;
      const _vb=Math.max(0,1-covF/0.7)*(1-_aqiF*0.45)*(1-_wet)*(1-_fog);
      const vis=_vb*Math.max(0,(-sAltN-6)/14);
      if(_vb>0.05){
        // A point source is maximum contrast, but capped tighter than the moon
        // so a star stays a point rather than spreading into a patch. Going
        // through detailDepth means it also respects the visibility floor -
        // a hardcoded SP/4 emitted sub-cells too small to see on a fine grid.
        const _sdep=detailDepth(1, 0.05, SP, MIN_SUB_PX, 4);
        const sp3=SP/Math.max(2,_sdep), halfH=H*0.5;
        for(let si=0;si<starPx.length;si++){
          const st=starPx[si];
          if(st.br<0.55 && !st.pk) continue;       // only ones worth the detail (a planet always is)
          const visS=st.pk ? Math.max(vis, _vb*_plTwi(sAltN,st.br)) : vis;
          if(visS<=0.05) continue;
          const sy=st.y01*H; if(sy>(st.pk?H*0.88:halfH)) continue;   // planets ride low at dusk and dawn
          const sx=st.x01*W;
          const gx=((sx/sp3)|0)*sp3+sp3*0.5;       // snap: stay on the grid
          const gy=((sy/sp3)|0)*sp3+sp3*0.5;
          const tw=st.pk ? 1 : 0.72+0.28*fsin(sec*1.7+si*2.4);     // a planet does not twinkle
          const l=Math.min(255, 255*visS*Math.max(st.br,st.pk?0.8:0)*tw*Math.min(1.6,_STARK));
          // Mars is red and Saturn a shade warm; Venus, Jupiter and the stars are white.
          const _tr=1, _tg=st.pk===2?0.74:st.pk===4?0.95:1, _tb=st.pk===2?0.58:st.pk===4?0.84:1.06;
          // same styling path as every other cell, so glass stays glass here too
          paintMosaicCell(sctx, gx-sp3*0.5, gy-sp3*0.5, sp3, (l*_tr)|0, (l*_tg)|0, Math.min(255,l*_tb)|0, 0.44);
        }
      }
    }
  }
  __dsT.blit+=performance.now()-__tb;
  // The pane itself is the nearest surface to the viewer, so its water goes last.
  const __tw=performance.now(); drawPaneWater(sctx,W,H,SP); __dsT.water+=performance.now()-__tw;
  const __tv=performance.now();
  // The tile bevel used to be its own fullscreen canvas stacked above #scene.
  // It never changed between resizes, yet the compositor re-blended a full
  // output-resolution layer for it every frame - measured at ~2.5fps on the Pi.
  // Drawn here instead it costs one blit at the scene's own (smaller) size,
  // and lands in exactly the same place in the stack, so nothing looks different.
  // ...and its strength follows the scene, because the bevel is a FIXED alpha
  // over cells whose brightness is not. The highlight is white at .11: over a
  // daylight cell around 150 that adds about 12 and reads as a tile edge, but
  // over a night cell around 40 it adds 24 - a 60% lift - so at night the
  // lattice stopped being the edges of tiles and became bright graph paper
  // ruled over the sky. Scaling it keeps the mosaic's structure (the grid is
  // the whole aesthetic, it just must not out-shout what it is made of) while
  // letting the night go quiet. Album art is its own light source, so music
  // mode keeps the full bevel.
  if(bevel && (inMusic || !elbOk)){                  // the blocks overlay replaces it on the sky
    const bevA=inMusic?1:(0.30+0.70*skyBrAmt);
    if(bevA>=0.999){ sctx.drawImage(bevel,0,0); }
    else { const _pa=sctx.globalAlpha; sctx.globalAlpha=bevA; sctx.drawImage(bevel,0,0); sctx.globalAlpha=_pa; }
  }
  __dsT.bevel+=performance.now()-__tv;
}
/* The near side is tidally locked, so the maria are in the same place every
   night - fixed, never random. Normalised (x, y, r) on the disc with north up,
   matching the real near-side layout: Procellarum west, Imbrium upper left,
   Crisium as the detached oval upper right. An approximation, not a survey,
   but the arrangement is right so the face reads as THE moon. */
const MARIA=[
  [-0.55,-0.10,0.38],   // Oceanus Procellarum - the big western plain
  [-0.30,-0.42,0.28],   // Mare Imbrium        - upper left
  [ 0.06,-0.35,0.18],   // Mare Serenitatis
  [ 0.24,-0.16,0.20],   // Mare Tranquillitatis
  [ 0.60,-0.28,0.13],   // Mare Crisium        - the detached oval, upper right
  [ 0.42, 0.10,0.16],   // Mare Fecunditatis
  [ 0.28, 0.22,0.11],   // Mare Nectaris
  [-0.22, 0.32,0.17],   // Mare Nubium
  [-0.42, 0.30,0.12]    // Mare Humorum
];
function _inMare(dx,dy,R){
  const nx=dx/R, ny=dy/R;
  for(let i=0;i<MARIA.length;i++){
    const m=MARIA[i], ex=nx-m[0], ey=ny-m[1];
    if(ex*ex+ey*ey < m[2]*m[2]) return 1;
  }
  return 0;
}

/* ---- PANE WATER -----------------------------------------------------------
   Water changes the MATERIAL of a cell; it does not sit on top of it. Alpha
   circles stamped over the grid read as bright confetti, because they add light
   and ignore the current style. Instead every cell carries a wetness, and a wet
   cell is the same cell in the same theme, only wetter: darker and more
   saturated. Beads are then built out of whole cells, so they stay mosaic.

   Long-lived state of the pane lives here too - grime that settles out of dirty
   air and washes off in rain, steam that fogs it when humid, and a pool that
   grows along the bottom edge the longer it has been raining. */
let wetGrid=null;                 // per-cell wetness left by drop trails
let pwDrops=[];                   // clinging + running drops
let pwAmbient=0;                  // pane-wide wetness (rain now, drying after)
let pwGrimeAmt=0;                 // dirt accumulated from bad air
let pwSteam=0;                    // fog on the inside of the pane
let pwPool=0;                     // 0..1 fullness of the pool at the lip
let pwRainDur=0;                  // how long this rain has been going
function pwReset(){ wetGrid=null; pwDrops=[]; }
function _stampWet(px,py,r,amt,SP){
  const c0=Math.max(0,((px-r)/SP)|0), c1=Math.min(COLS-1,((px+r)/SP)|0);
  const r0=Math.max(0,((py-r)/SP)|0), r1=Math.min(ROWS-1,((py+r)/SP)|0);
  for(let ry=r0;ry<=r1;ry++){
    const row=ry*COLS;
    for(let rx=c0;rx<=c1;rx++){
      const gi=row+rx;
      if(wetGrid[gi]<amt) wetGrid[gi]=amt;   // a drop makes a cell AT LEAST this wet
    }
  }
}
/* One step of the whole pane: rainfall in, physics, and the slow states. */
function stepPaneWater(dt,W,H,SP){
  if(!COLS||!ROWS) return;
  if(!wetGrid||wetGrid.length!==COLS*ROWS) wetGrid=new Float32Array(COLS*ROWS);
  dt=Math.min(0.05,dt||0.016);
  const lowfx=document.body.classList.contains("lowfx");
  // Scale the whole field by REAL rainfall, so 0.1mm drizzle is barely there
  // and 6mm visibly soaks the pane.
  const rainIntensity=Math.max(0,(scRain||0)/5+(scSnow||0)/4);
  const codeWet=(scCode>=51&&scCode<=67)||(scCode>=80&&scCode<=82);
  const wetNow=rainIntensity>0.004||codeWet;
  const inten=wetNow?Math.max(0.10,Math.min(1,rainIntensity)):0;
  const snowy=(scKind==="snow");

  // --- pane-wide wetness: soaks while raining, dries afterwards -------------
  if(wetNow) pwAmbient=Math.min(1,pwAmbient+dt*(0.05+inten*0.30));
  else{
    const sun=Math.max(0,Math.sin(Math.max(0,astroNow.sunAlt)*Math.PI/180));
    const dry=0.0015+sun*0.011+Math.max(0,scUV||0)*0.0011
            -Math.max(0,(scHumid||50)-60)*0.00004;
    pwAmbient=Math.max(0,pwAmbient-dt*Math.max(0.0003,dry));
  }
  // trails dry at the same rate the pane does, only faster
  if(wetGrid){
    const dec=wetNow?dt*0.05:dt*0.16;
    for(let i=0;i<wetGrid.length;i++){ const v=wetGrid[i]-dec; wetGrid[i]=v>0?v:0; }
  }

  // --- how long it has been raining -----------------------------------------
  // Hours of rain must look different from a shower, so a flood watch looks
  // like one. Drains ~3x faster than it fills.
  if(wetNow) pwRainDur=Math.min(1,pwRainDur+dt*(0.004+inten*0.016));
  else pwRainDur=Math.max(0,pwRainDur-dt*0.048);

  // --- grime: settles out of dirty air, washes off in rain -------------------
  if(!wetNow&&(scAQI||0)>60) pwGrimeAmt=Math.min(1,pwGrimeAmt+dt*0.0009*Math.min(3,(scAQI-60)/60));
  if(wetNow) pwGrimeAmt=Math.max(0,pwGrimeAmt-dt*0.02*inten);

  // --- steam: humidity fogs the pane, the sun burns it off -------------------
  const hf=Math.max(0,Math.min(1,((scHumid||50)-72)/28));
  const burn=Math.max(0,Math.sin(Math.max(0,astroNow.sunAlt)*Math.PI/180));
  const stTarget=hf*(1-burn*0.85);
  pwSteam+=(stTarget-pwSteam)*Math.min(1,dt*0.15);

  // --- pool at the lip ------------------------------------------------------
  const poolTarget=Math.min(1,pwRainDur*0.95);
  pwPool+=(poolTarget-pwPool)*Math.min(1,dt*(poolTarget>pwPool?0.08:0.20));

  if(lowfx){ if(pwDrops.length) pwDrops.length=0; return; }

  // --- droplet physics ------------------------------------------------------
  // Condensation gathers, surface tension lets go, terminal velocity sorts the
  // fast from the slow, and coalescence turns a uniform field into a few heavy
  // runs - which is the thing that makes rain on glass look real.
  const maxD=Math.round(14+inten*46);
  if(wetNow&&pwDrops.length<maxD&&Math.random()<0.35+inten*0.55){
    pwDrops.push({x:Math.random()*W, y:Math.random()*H*0.92,
      r:SP*(0.05+Math.random()*0.06), v:0, run:false,
      rCrit:SP*(0.20+Math.random()*0.22)});      // 28 Sep: beads were "too big" - most stay one cell
  }
  const gravity=SP*46, windPush=crossWindKmh()/90*SP*6;
  for(let i=pwDrops.length-1;i>=0;i--){
    const d=pwDrops[i];
    if(!d.run){
      if(wetNow){
        d.r+=dt*SP*0.09*inten;                   // condensation keeps gathering
        if(d.r>=d.rCrit) d.run=true;             // surface tension gives way
      }else{
        // nothing feeding them any more, so they evaporate instead of clinging
        // to a bone-dry pane for ever and holding its wetness up
        d.r-=dt*SP*0.05;
        if(d.r<SP*0.05){ pwDrops.splice(i,1); continue; }
      }
    }else{
      const vTerm=260*Math.sqrt(d.r/SP);         // bigger drops fall faster
      d.v+=gravity*(1-d.v/vTerm)*dt;
      d.y+=d.v*dt; d.x+=windPush*dt;
      // coalescence: a falling drop absorbs the clinging ones it catches
      for(let j=pwDrops.length-1;j>=0;j--){
        if(j===i) continue;
        const o=pwDrops[j];
        if(o.run) continue;
        const ddx=o.x-d.x, ddy=o.y-d.y, rr=d.r+o.r;
        if(ddx*ddx+ddy*ddy<rr*rr){
          // volumes add, so radii add as cube roots, and momentum carries over
          const m1=d.r*d.r*d.r, m2=o.r*o.r*o.r, mt=m1+m2;
          d.v=d.v*m1/mt;
          d.r=Math.cbrt(mt);
          pwDrops.splice(j,1);
          if(j<i) i--;
        }
      }
    }
    _stampWet(d.x,d.y,d.r,d.run?0.85:0.45,SP);
    if(d.x<-SP||d.x>W+SP){ pwDrops.splice(i,1); continue; }
    if(d.y-d.r>H){
      // The bottom edge is not a wall. Most drops merge into the pool and feed
      // it; a few carry enough momentum to run clean off the lip.
      if(Math.random()>=0.22) pwPool=Math.min(1,pwPool+(d.r/SP)*0.015);
      pwDrops.splice(i,1); continue;
    }
  }
  if(snowy&&pwDrops.length>maxD) pwDrops.length=maxD;
}
/* Per-cell material change. Scratch globals rather than a returned array,
   because this runs once per cell per frame and the Pi cannot afford garbage. */
let _wsR=0,_wsG=0,_wsB=0;
function applyPaneMaterial(k,gk,st,r,g,b){
  if(gk>0.004){
    // grime desaturates and browns
    const lum=r*0.299+g*0.587+b*0.114, d=gk*0.55;
    r+=(lum*1.06-r)*d; g+=(lum*0.98-g)*d; b+=(lum*0.82-b)*d;
  }
  if(k>0.004){
    r+=(r*0.80-r)*k; g+=(g*0.80-g)*k; b+=(b*0.80-b)*k;          // wet darkens
    const lum=r*0.299+g*0.587+b*0.114, s=k*0.7;
    r+=(lum+(r-lum)*1.35-r)*s; g+=(lum+(g-lum)*1.35-g)*s; b+=(lum+(b-lum)*1.35-b)*s;
  }
  if(st>0.004){
    // fog lifts the blacks and kills contrast; it does NOT simply add white
    const a=st*0.6, mid=(r+g+b)*0.3333;
    r+=(mid-r)*a; g+=(mid-g)*a; b+=(mid-b)*a;
    const lift=st*26; r+=lift; g+=lift; b+=lift*1.04;
  }
  _wsR=r; _wsG=g; _wsB=b;
}
/* Pool and beads, drawn after the mosaic is composited so they can gather the
   scene from behind. Everything here is built from whole cells. */
function drawPaneWater(ctx,W,H,SP){
  if(!sceneCol||!COLS||!ROWS) return;
  if(document.body.classList.contains("lowfx")) return;
  // --- pool: mostly a MIRROR taking the sky from above ----------------------
  // Darkening it heavily reads as a black stripe across the screen.
  if(pwPool>0.02){
    const ph=Math.max(1,Math.round(pwPool*ROWS*0.085));
    const top=ROWS-ph;
    for(let k=0;k<ph;k++){
      const ry=top+k;
      let src=top-k-1;                          // reflect about the water line
      if(src<0) src=0;
      const depth=(k+1)/ph;
      for(let rx=0;rx<COLS;rx++){
        const si=(src*COLS+rx)*3;
        let r=sceneCol[si], g=sceneCol[si+1], b=sceneCol[si+2];
        // slight cool tint and a gentle darkening with depth, nothing more
        const dk=1-depth*0.22;
        r=r*dk; g=g*dk*1.01; b=Math.min(255,b*dk*1.06);
        paintMosaicCell(ctx,rx*SP,ry*SP,SP,r|0,g|0,b|0,0.46);
      }
    }
  }
  // --- beads: only MATURE drops earn one ------------------------------------
  // Shallow by design: hardMax 2 and a stricter 6px floor than the moon's 4,
  // because a bead is small and over-refining it reads as noise, not water.
  const _wdep=detailDepth(1, 0.10, SP, 6, 2);
  for(let i=0;i<pwDrops.length;i++){
    const d=pwDrops[i];
    if(!d.run&&d.r<d.rCrit*0.72) continue;
    const cc=(d.x/SP)|0, cr2=(d.y/SP)|0;
    const rad=d.r>=SP*0.9?Math.round(d.r/SP):0;   // under ~a cell: a single-cell bead
    const inv=1/(rad+0.35);
    for(let ry=cr2-rad;ry<=cr2+rad;ry++){
      if(ry<0||ry>=ROWS) continue;
      for(let rx=cc-rad;rx<=cc+rad;rx++){
        if(rx<0||rx>=COLS) continue;
        const nx=(rx-cc)*inv, ny=(ry-cr2)*inv;
        const q=nx*nx+ny*ny;
        if(q>1) continue;
        // lens gather: pull the scene from behind, drawn inward as a lens does
        const sx=Math.max(0,Math.min(COLS-1,cc+Math.round(nx*rad*0.45)));
        const sy=Math.max(0,Math.min(ROWS-1,cr2+Math.round(ny*rad*0.45)));
        const si=(sy*COLS+sx)*3;
        const r0=sceneCol[si], g0=sceneCol[si+1], b0=sceneCol[si+2];
        // rim DARKENING where the bead meets the glass. Darkening rather than
        // brightening is what stops beads reading as confetti.
        if(_wdep<2){
          const dk=1-Math.max(0,(Math.sqrt(q)-0.55)/0.45)*0.42;
          paintMosaicCell(ctx,rx*SP,ry*SP,SP,(r0*dk)|0,(g0*dk)|0,(b0*dk)|0,0.46);
        }else{
          // Only the bead earns the finer grid, and only a shallow one. The rim
          // is the edge a coarse cell destroys; the interior is already flat, so
          // refining it buys nothing. Subdividing the surrounding wet film as
          // well turns the whole pane into scattered hash marks.
          const ss=SP/_wdep;
          for(let sj=0;sj<_wdep;sj++)for(let sk=0;sk<_wdep;sk++){
            const px=rx*SP+sk*ss, py=ry*SP+sj*ss;
            const snx=((px+ss*0.5)/SP-cc)*inv, sny=((py+ss*0.5)/SP-cr2)*inv;
            const sq=snx*snx+sny*sny;
            if(sq>1) continue;                     // outside the bead: leave it
            const sdk=1-Math.max(0,(Math.sqrt(sq)-0.55)/0.45)*0.42;
            paintMosaicCell(ctx,px,py,ss,(r0*sdk)|0,(g0*sdk)|0,(b0*sdk)|0,0.46);
          }
        }
      }
    }
    // one restrained glint, upper-left, a single cell
    if(rad>=2){
      const gx=cc-((rad*0.42)|0), gy=cr2-((rad*0.42)|0);
      if(gx>=0&&gy>=0&&gx<COLS&&gy<ROWS){
        const si=(gy*COLS+gx)*3;
        const r=Math.min(255,sceneCol[si]+70), g=Math.min(255,sceneCol[si+1]+74), b=Math.min(255,sceneCol[si+2]+80);
        paintMosaicCell(ctx,gx*SP,gy*SP,SP,r|0,g|0,b|0,0.46);
      }
    }
  }
}
/* ---- SOURCE MAP -----------------------------------------------------------
   The moon's near side as an albedo map. Everything about the crater detail is
   derived from sampling THIS - which is why the face comes out right instead of
   depending on me hand-placing shading. It is generated from the mare geometry
   today, but the contract is a plain 2D luminance sampler, so dropping in a real
   photograph later changes nothing downstream. */
const MOON_N=48;
let MOONMAP=null;
function buildMoonMap(){
  MOONMAP=new Float32Array(MOON_N*MOON_N);
  for(let y=0;y<MOON_N;y++)for(let x=0;x<MOON_N;x++){
    const nx=(x+0.5)/MOON_N*2-1, ny=(y+0.5)/MOON_N*2-1;
    const rr=nx*nx+ny*ny;
    let v=0;
    if(rr<=1){
      v=0.95;                                        // bright highlands
      for(let i=0;i<MARIA.length;i++){
        const m=MARIA[i], ex=nx-m[0], ey=ny-m[1];
        const d=Math.sqrt(ex*ex+ey*ey)/m[2];
        if(d<1) v=Math.min(v, 0.58+0.16*d);          // seas, softened at their edge
      }
      // Limb darkening. 0.86+0.14 is a 14% swing - under one quantisation
      // level after the ramp LUT and a posterize step of 16, so the disc came
      // out a flat plate with a cliff edge. Flatter than a real full moon,
      // but a mosaic of 18px cells needs the form exaggerated to survive
      // quantisation at all.
      v*=0.60+0.40*Math.sqrt(Math.sqrt(Math.max(0,1-rr)));   // limb darkening
    }
    MOONMAP[y*MOON_N+x]=v;
  }
}
function moonSample(nx,ny){
  if(!MOONMAP) buildMoonMap();
  const x=(nx+1)/2*MOON_N, y=(ny+1)/2*MOON_N;
  const xi=Math.max(0,Math.min(MOON_N-1,x|0)), yi=Math.max(0,Math.min(MOON_N-1,y|0));
  return MOONMAP[yi*MOON_N+xi];
}
/* Map-driven subdivision. Walk the coarse cells over a feature, sample the
   source at each cell's corners, and subdivide ONLY where local contrast says
   detail exists. Flat cells are left completely alone, so the mosaic survives.
   Depth scales with how much contrast the cell holds - more detail, finer grid -
   still bounded by what stays visible. */
/* How finely to split one cell. The whole adaptive-detail story lives here, so
   every feature - moon face, bright stars, water beads - asks the same question
   and only varies its own hardMax.

   Two things must be true for splitting to be worth doing at all:
     contrast   - there is real detail in this cell; a flat cell stays whole
     affordable - the resulting sub-cell is still big enough to actually see

   That second one is the trick. Below ~3px a sub-cell stops reading as detail
   and starts reading as the gap between sub-cells: you see the grid instead of
   the element. Bounding by size rather than cell count means this adapts to any
   resolution on its own - on a dense screen it simply switches itself off. */
const MIN_SUB_PX=3;
function detailDepth(contrast, thresh, cellSP, minSubPx, hardMax){
  if(contrast<thresh) return 1;                    // flat: leave it whole
  const affordable=Math.floor(cellSP/minSubPx);    // still visible
  if(affordable<2) return 1;
  const wanted=1+Math.round(contrast*5);           // scales with detail
  return Math.max(2, Math.min(wanted, Math.min(affordable, hardMax)));
}
/* The ONLY place a mosaic cell becomes pixels. A refined sub-cell goes through
   exactly the same styling a coarse one does, so glass stays bevelled squares
   and dots stay dots, all the way down. Never hardcode arc() past this point. */
function paintMosaicCell(ctx, px, py, size, r, g, b, dotScale){
  if(STYLE==="glass"){
    ctx.fillStyle=`rgb(${r},${g},${b})`;
    ctx.fillRect(px,py,size+0.5,size+0.5);
    // same bevel the coarse grid gets: light top-left, dark bottom-right
    // Scaled to the tile: a full-strength bevel on every sub-cell drew a dark
    // line every few pixels, which read as graph paper over the moon.
    const bk=Math.min(1,Math.sqrt(size/Math.max(SP,1)));
    ctx.fillStyle=`rgba(255,255,255,${(0.11*bk).toFixed(3)})`; ctx.fillRect(px,py,size,1); ctx.fillRect(px,py,1,size);
    ctx.fillStyle=`rgba(0,0,0,${(0.28*bk).toFixed(3)})`; ctx.fillRect(px,py+size-1,size,1); ctx.fillRect(px+size-1,py,1,size);
  } else {
    // dimmed bed first, or the gaps between dots let the sky through and the
    // refined area reads as harsh speckle instead of finer pixels
    ctx.fillStyle=`rgb(${(r*0.62)|0},${(g*0.62)|0},${(b*0.62)|0})`;
    ctx.fillRect(px,py,size+0.5,size+0.5);
    ctx.fillStyle=`rgb(${r},${g},${b})`;
    ctx.beginPath(); ctx.arc(px+size*0.5,py+size*0.5,size*dotScale,0,6.29); ctx.fill();
  }
}
function subdivideByMap(ctx, cx0, cy0, R, cellSP, W, H, sample, thresh, shade, hardMax, edgeFn, fixedDepth){
  if(!(R>0)||!sample||!shade||!(cellSP>0)) return;
  const R2=R*R;
  if(Math.floor(cellSP/MIN_SUB_PX)<2) return;
  hardMax=hardMax||4;
  const gx0=Math.max(0,Math.floor((cx0-R)/cellSP)*cellSP);
  const gy0=Math.max(0,Math.floor((cy0-R)/cellSP)*cellSP);
  for(let cy=gy0; cy<Math.min(H,cy0+R); cy+=cellSP){
    for(let cx=gx0; cx<Math.min(W,cx0+R); cx+=cellSP){
      // Qualify by the cell CENTRE, matching what the coarse pass drew. Testing
      // corners instead dropped every cell the limb touched, so the one ring of
      // cells that most needs refining was the only ring never refined.
      const ccx=cx+cellSP*0.5-cx0, ccy=cy+cellSP*0.5-cy0;
      if(ccx*ccx+ccy*ccy>R2) continue;
      // what the coarse pass used for this cell, so refinement can be expressed
      // as a RATIO against it: a split cell then averages back to what was
      // already there, and there is no seam with an unsplit neighbour
      const vCell=sample(ccx/R, ccy/R);
      let lo=vCell, hi=vCell, eAll=true, eAny=false, sawEdge=false;
      for(let k=0;k<4;k++){
        const px=cx+((k&1)?cellSP:0), py=cy+((k&2)?cellSP:0);
        const dx=px-cx0, dy=py-cy0;
        const inK=(dx*dx+dy*dy<=R2);
        // corners off the disc inherit the centre rather than voiding the cell,
        // so the limb registers no false contrast and splits only on real detail
        const v=inK?sample(dx/R, dy/R):vCell;
        if(v<lo) lo=v; if(v>hi) hi=v;
        if(edgeFn && inK){ const e=!!edgeFn(dx,dy,R); sawEdge=true; eAll=eAll&&e; eAny=eAny||e; }
      }
      // A boundary crossing the cell IS the detail - the terminator carries the
      // entire phase - so it always earns a full breakdown regardless of albedo.
      const contrast=(sawEdge && eAny && !eAll) ? 1 : (hi-lo);
      // fixedDepth: one tile size over the whole feature. Contrast-driven depth
      // mixed 2x, 3x and 4x splits side by side on the moon - a patchwork.
      const sub=fixedDepth?Math.max(1,Math.min(fixedDepth,Math.floor(cellSP/MIN_SUB_PX)))
                          :detailDepth(contrast, thresh, cellSP, MIN_SUB_PX, hardMax);
      if(sub<2) continue;                            // flat: leave the mosaic be
      const sp2=cellSP/sub;
      for(let yy=cy; yy<cy+cellSP; yy+=sp2){
        for(let xx=cx; xx<cx+cellSP; xx+=sp2){
          const dx=xx+sp2*0.5-cx0, dy=yy+sp2*0.5-cy0;
          // A sub-cell off the disc inherits the parent wholesale, so a limb
          // cell still reads as one full square and the outline gains no
          // resolution - refinement redistributes detail, it never reshapes.
          const inS=(dx*dx+dy*dy<=R2);
          const o=shade(dx/R, dy/R, inS?sample(dx/R, dy/R):vCell, vCell);
          if(!o) continue;
          const k2=Math.max(0,Math.min(1,(o.l||0)/255));
          const rr=Math.round((o.r||0)*k2), gg=Math.round((o.g||0)*k2), bb=Math.round((o.b||0)*k2);
          paintMosaicCell(ctx, xx, yy, sp2, rr, gg, bb, (o.size||0.46));
        }
      }
    }
  }
}
