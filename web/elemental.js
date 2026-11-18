/* Elemental web: weather, time, settings and the frame loop around the scene core. */
const EL={ timeOff:0, paused:false, maxFps:30, raf:0, last:0, wx:null, wxTimer:0, forceWx:null };
(function(){
  const Q=new URLSearchParams(location.search);
  const t=Q.get("t"); if(t){ const ms=Date.parse(t); if(isFinite(ms)) EL.timeOff=ms-Date.now(); }
  EL.forceWx=Q.get("wx");
})();
function elNow(){ return Date.now()+EL.timeOff; }

/* ---------------- weather ---------------- */
async function elFetchWx(lat,lon){
  const url=`https://api.open-meteo.com/v1/forecast?latitude=${lat.toFixed(3)}&longitude=${lon.toFixed(3)}`
    +`&current=temperature_2m,weather_code,is_day,cloud_cover,cloud_cover_low,cloud_cover_mid,cloud_cover_high,wind_speed_10m,wind_direction_10m,precipitation,rain,snowfall,visibility,relative_humidity_2m,surface_pressure,precipitation_probability,uv_index`
    +`&minutely_15=precipitation,rain,snowfall,weather_code`
    +`&hourly=cloud_cover_low,cloud_cover_mid,cloud_cover_high,precipitation,weather_code,wind_speed_10m,visibility&forecast_hours=6`
    +`&timezone=auto&forecast_days=1`;
  const d=await (await fetch(url,{cache:"no-store"})).json();
  const c=d.current; if(!c) throw new Error("no current");
  let mp=null,mr=null,ms=null,mc=null; const mn=d.minutely_15;
  if(mn&&mn.time&&c.time){ let bi=-1; for(let i=0;i<mn.time.length;i++){ if(mn.time[i]<=c.time) bi=i; else break; }
    if(bi>=0){ mp=mn.precipitation?.[bi]; mr=mn.rain?.[bi]; ms=mn.snowfall?.[bi]; mc=mn.weather_code?.[bi]; } }
  const code=(mc!=null?mc:c.weather_code);
  return { code, tC:c.temperature_2m, cover:c.cloud_cover, cLo:c.cloud_cover_low, cMid:c.cloud_cover_mid, cHi:c.cloud_cover_high,
    uv:c.uv_index||0, wind:c.wind_speed_10m||0, windDir:(c.wind_direction_10m!=null?c.wind_direction_10m:180),
    pressure:c.surface_pressure||1013, precipProb:c.precipitation_probability||0,
    precip:(mp!=null?mp:(c.precipitation||0)), rain:(mr!=null?mr:(c.rain||0)), snow:(ms!=null?ms:(c.snowfall||0)),
    vis:(c.visibility!=null?c.visibility:10000), humid:(c.relative_humidity_2m!=null?c.relative_humidity_2m:50), hourly:d.hourly||null };
}
async function elFetchAQI(lat,lon){
  try{
    const d=await (await fetch(`https://air-quality-api.open-meteo.com/v1/air-quality?latitude=${lat.toFixed(3)}&longitude=${lon.toFixed(3)}&current=us_aqi,pm2_5,pm10,aerosol_optical_depth`,{cache:"no-store"})).json();
    const c=d.current||{}; const aqi=c.us_aqi||0, pm25=c.pm2_5||0, pm10=c.pm10||0, aod=c.aerosol_optical_depth||0;
    const aodF=Math.max(0,Math.min(1,(aod-0.45)/0.95)), fine=Math.max(0,Math.min(1,(pm25/Math.max(1,pm25+pm10)-0.52)/0.30));
    return {aqi, smoke:aodF*fine, aod};
  }catch(_){ return null; }
}
// METAR straight from aviationweather.gov. It does not send CORS headers today, so in a
// browser this normally fails and is skipped; a host may also pass settings.metar (raw text).
async function elFetchMetar(lat,lon){
  const raw=__ELSET.metar; if(typeof raw==="string"&&raw) return {raw, km:0};
  if(!__ELSET.metarFetch) return null;   // opt-in: blocked by CORS in a page today
  try{
    const b=[(lat-0.6).toFixed(2),(lon-0.8).toFixed(2),(lat+0.6).toFixed(2),(lon+0.8).toFixed(2)].join(",");
    const r=await fetch(`https://aviationweather.gov/api/data/metar?bbox=${b}&format=json`,{cache:"no-store"});
    const a=await r.json(); if(!Array.isArray(a)||!a.length) return null;
    let best=null, bd=1e9;
    for(const m of a){ const dk=Math.hypot((m.lat-lat)*111,(m.lon-lon)*111*Math.cos(lat*Math.PI/180));
      const age=(Date.now()/1000-(m.obsTime||0))/60; if(age<150&&dk<bd){ bd=dk; best=m; } }
    return best?{raw:best.rawOb||"", km:bd}:null;
  }catch(_){ return null; }
}
function metarBands(raw){
  if(!raw) return null;
  const P={FEW:19,SCT:44,BKN:75,OVC:100,VV:100};
  let lo=0, mid=0, hi=0, any=false; const re=/(FEW|SCT|BKN|OVC|VV)([0-9]{3})/g; let m;
  while((m=re.exec(raw))){ any=true; const p=P[m[1]], ft=parseInt(m[2],10)*100;
    if(ft<6500) lo=Math.max(lo,p); else if(ft<20000) mid=Math.max(mid,p); else hi=Math.max(hi,p); }
  if(!any) return /(CLR|SKC|NCD|NSC|CAVOK)/.test(raw)?{lo:0,mid:0,hi:0}:null;
  return {lo, mid:Math.max(0,mid-lo), hi:Math.max(0,hi-Math.max(lo,mid))};
}
const FORCED={ clear:{code:0,cover:2,cLo:0,cMid:0,cHi:2}, partly:{code:2,cover:45,cLo:25,cMid:20,cHi:30},
  cloud:{code:3,cover:95,cLo:90,cMid:50,cHi:30}, fog:{code:45,cover:100,cLo:100,cMid:0,cHi:0,vis:300},
  rain:{code:63,cover:100,cLo:100,cMid:80,cHi:40,precip:3,rain:3}, snow:{code:73,cover:100,cLo:100,cMid:70,cHi:30,snow:1.5,precip:1.5,tC:-3},
  thunder:{code:95,cover:100,cLo:100,cMid:90,cHi:60,precip:8,rain:8,wind:30} };
function elApplyWx(w){
  EL.wx=w;
  const day=(astroNow.sunAlt>-0.833)?1:0;
  scCldLo=(w.cLo==null?null:w.cLo); scCldMid=(w.cMid==null?null:w.cMid); scCldHi=(w.cHi==null?null:w.cHi);
  if(w.tC!=null) scTempC=w.tC;
  setScene(wxCat(w.code), day, w.cover, w.code, w.uv||0, w.wind||0, w.precip||0, w.rain||0, w.snow||0,
           w.vis!=null?w.vis:20000, w.humid!=null?w.humid:55, w.windDir!=null?w.windDir:180, w.pressure||1013, w.precipProb||0);
  if(w.metar){ const mb=metarBands(w.metar.raw); if(mb && (w.metar.km==null||w.metar.km<=60)){ scCldLo=mb.lo; scCldMid=mb.mid; scCldHi=mb.hi; } }
}
async function elLoadWeather(){
  clearTimeout(EL.wxTimer);
  const lat=CURRENT.lat, lon=CURRENT.lon;
  if(EL.forceWx && FORCED[EL.forceWx]){ elApplyWx(Object.assign({uv:3,wind:8,windDir:240,humid:60,vis:20000},FORCED[EL.forceWx])); return; }
  let next=15*60*1000;
  try{
    const [w,aq,mt]=await Promise.all([elFetchWx(lat,lon), elFetchAQI(lat,lon), elFetchMetar(lat,lon)]);
    if(aq){ scAQI=aq.aqi; scSmoke=aq.smoke; scAOD=aq.aod; }
    w.metar=mt; elApplyWx(w);
  }catch(e){ next=2*60*1000; if(!EL.wx) elApplyWx(FORCED.partly); }   // offline: a plausible sky, retry soon
  EL.wxTimer=setTimeout(elLoadWeather,next);
}

/* ---------------- settings API ---------------- */
function elApplySettings(S, first){
  const prevLat=CURRENT.lat, prevLon=CURRENT.lon, prevRows=GRID_ROWS, prevMat=WS.material, prevStyle=STYLE, prevRes=RES;
  _elMapSettings(S, WS);
  if(typeof S.lat==="number") CURRENT.lat=S.lat;
  if(typeof S.lon==="number") CURRENT.lon=S.lon;
  if(S.tz) CURRENT.tz=S.tz;
  if(typeof S.skyglow==="number") CURRENT.skyglow=S.skyglow;
  STYLE=WS.style;
  _STARK=WS.starBrightness*2;
  EL.maxFps=Math.max(1,Math.min(144,(typeof S.maxFps==="number")?S.maxFps:30));
  const dpr=window.devicePixelRatio||1;
  RES=(typeof S.resolution==="number")?Math.max(0.2,Math.min(2,S.resolution)):Math.min(1,0.5*dpr);
  if(typeof WS.gridRows==="number"){ GRID_ROWS=Math.max(12,Math.min(200,Math.round(WS.gridRows))); GRID_K=GRID_ROWS/36; }
  if(!first){
    if(GRID_ROWS!==prevRows||WS.material!==prevMat||STYLE!==prevStyle||RES!==prevRes) resizeScene();
    if(CURRENT.lat!==prevLat||CURRENT.lon!==prevLon){ elSnapHeading(); elLoadWeather(); }
    else updateAstro(elNow());
  }
  elPause(!!S.paused);
}
window.elementalApply=function(obj){ Object.assign(__ELSET, obj||{}); elApplySettings(__ELSET,false); };
function elPause(p){
  p=!!p; __ELSET.paused=p; if(p===EL.paused) return; EL.paused=p;
  if(p){ cancelAnimationFrame(EL.raf); EL.raf=0; }
  else { prevFrame=performance.now(); EL.last=0; if(!EL.raf) EL.raf=requestAnimationFrame(elFrame); }
}
window.elementalPause=elPause;

/* ---------------- frame loop ---------------- */
function elFrame(tnow){
  EL.raf=0; if(EL.paused) return;
  EL.raf=requestAnimationFrame(elFrame);
  const iv=1000/EL.maxFps;
  if(EL.last && tnow-EL.last < iv-2) return;            // cap, with a little slack for vsync jitter
  EL.last = EL.last && tnow-EL.last<iv*2 ? EL.last+iv : tnow;
  const dt=Math.min(0.1,(tnow-prevFrame)/1000); prevFrame=tnow;
  _sceneAcc+=dt;
  if(!_sceneGen && _sceneAcc>=Math.min(SCENE_DT, 1/EL.maxFps)){
    _sceneGen=__drawSceneGen(tnow, _sceneAcc); _sceneAcc=0; _sceneGenMs=0;
  }
  if(_sceneGen){
    const c0=performance.now(); const r=_sceneGen.next(); _sceneGenMs+=performance.now()-c0;
    if(r.done){ _sceneGen=null; const sl=Math.max(1,Math.ceil(_sceneGenMs/6)); __ROWCHUNK = sl<=1?0:Math.max(2,Math.ceil(ROWS/sl)); }
  }
  _fgAcc+=dt; if(_fgAcc>=0.03){ try{ fgFxFrame(_fgAcc); }catch(_){} _fgAcc=0; }
}

/* ---------------- boot ---------------- */
function elSnapHeading(){ updateAstro(elNow()); if(HEADING_DYNAMIC){ FACING_AZ=headingTarget(); updateAstro(elNow()); } }
elApplySettings(__ELSET, true);
elSnapHeading();
resizeScene();
let _rzT=0; window.addEventListener("resize",()=>{ clearTimeout(_rzT); _rzT=setTimeout(resizeScene,120); });
setInterval(()=>{ if(!EL.paused){ updateAstro(elNow()); if(EL.wx){ const d=(astroNow.sunAlt>-0.833)?1:0; if(d!==scDay) elApplyWx(EL.wx); } } }, 60*1000);
initFgFx(); try{ _snowRestore(); _leafRestore(); }catch(_){}
elLoadWeather();
EL.paused=true; elPause(!!__ELSET.paused);
document.addEventListener("visibilitychange",()=>{ if(!document.hidden && !__ELSET.paused){ updateAstro(elNow()); } });
// WebView2 hosts may also post {type:"elemental-settings", settings} or {type:"elemental-pause", paused}.
try{ if(window.chrome&&window.chrome.webview) window.chrome.webview.addEventListener("message",e=>{ const d=e.data||{};
  if(d.type==="elemental-settings"&&d.settings) window.elementalApply(d.settings);
  else if(d.type==="elemental-pause") elPause(!!d.paused); }); }catch(_){}
