/* Elemental web: settings + the few globals the scene core expects from its old host page.
   Loaded first. Settings come from window.ELEMENTAL_SETTINGS (injected by the host), then the URL query. */
(function(){
  const Q=new URLSearchParams(location.search);
  const S=Object.assign({}, window.ELEMENTAL_SETTINGS||{});
  const num=k=>{ const v=Q.get(k); return (v!=null&&v!==""&&isFinite(+v))?+v:undefined; };
  if(S.lat==null&&num("lat")!=null) S.lat=num("lat");
  if(S.lon==null&&num("lon")!=null) S.lon=num("lon");
  for(const k of ["style","material"]) if(S[k]==null&&Q.get(k)) S[k]=Q.get(k);
  for(const k of ["gridRows","starBrightness","maxFps","tileRelief","resolution"]) if(S[k]==null&&num(k)!=null) S[k]=num(k);
  for(const k of ["planets","leaves","festivals","paused"]) if(S[k]==null&&Q.get(k)!=null) S[k]=!/^(0|false|off|no)$/i.test(Q.get(k));
  window.__ELWS={};            // what the scene core reads as WS
  window.__ELSET=S;
})();
const MATERIALS={classic:0,glass:1,metal:2,plastic:3,matte:4};
function _elMapSettings(S, WS){
  WS.style = (S.style==="dots")?"dots":"glass";
  WS.material = (typeof S.material==="number") ? S.material : (MATERIALS[String(S.material||"glass").toLowerCase()] ?? 1);
  if(typeof S.tileRelief==="number") WS.tileRelief=S.tileRelief;
  if(typeof S.gridRows==="number") WS.gridRows=S.gridRows;
  WS.planets = S.planets!==false;
  WS.leaves = S.leaves!==false;
  WS.festivals = S.festivals!==false;
  WS.starBrightness = (typeof S.starBrightness==="number") ? S.starBrightness : 0.5;
}
_elMapSettings(window.__ELSET, window.__ELWS);

const $ = id => document.getElementById(id);
// Where we are. tz is the browser's own zone unless the host says otherwise; skyglow 0..1 (light pollution).
const CURRENT = { lat:(typeof __ELSET.lat==="number")?__ELSET.lat:51.4779, lon:(typeof __ELSET.lon==="number")?__ELSET.lon:-0.0015,
  tz:__ELSET.tz||(Intl.DateTimeFormat().resolvedOptions().timeZone), skyglow:(typeof __ELSET.skyglow==="number")?__ELSET.skyglow:0.3 };

// --- inert stand-ins for the old page's music / F1 / radar / diagnostics ---
function __stamp(){}
const __dsT={n:0,all:0,cells:0,blit:0,water:0,bevel:0,max:0}, __jk={n:0,max:0,t:{}}, __lastT={};
let mode="clock", cur={paused:true,lyrics:[],duration:0}, basePos=0, baseClock=0;
let artSoft=null, vizPulse=null, vizFps=30, SAT=null, RADAR=null, RADAR_PROFILE=null, METAR=null;
function vizNow(){ return 0.2; }
function setF1Track(){} function buildTrackFine(){} function renderTrackFine(){} function buildTrackField(){}
function drawF1Overlay(){} let f1OverActive=false, f1Cars=[], f1GridRows=null;
function applyAqiTint(){} function resizeAqiFx(){}
let _lowFx=false, peekIdx=-1, peekSunAlt=45;
const GC={st:new Map(),box:null};
function wxCat(c){ if(c===0||c===1)return"sun"; if(c===2)return"partly";
  if(c===3||c===45||c===48)return"cloud"; if((c>=51&&c<=67)||(c>=80&&c<=82))return"rain";
  if((c>=71&&c<=77)||c===85||c===86)return"snow"; if(c>=95)return"thunder"; return"cloud"; }
