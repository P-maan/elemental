/* Elemental foreground weather: rain/snow splashes, leaves, festivals. */
// ---- foreground weather FX: rain splashing off elements + running down glass ----
let fgfx=null, fgctx=null, fgSurf=[], fgSplash=[], fgDrip=[], fgActive=false, fgSurfTs=0, _fgAcc=0;
let fgPile=[];        // snow on each surface's top edge: {cx,cy,dep (cells),peak}
/* EVERYTHING ON THE GRID (Elemental 0.6): the smooth white strip drawn over the
   tiles is gone - lying snow is a cap of the mosaic's own cells above each
   tile's top edge, banked toward the downwind end, and it melts at the
   weather's pace instead of in twelve seconds. It is remembered across a
   restart (localStorage), aged for the time away. */
const SNOW_MAX=3.4;
function _surfKey(s){ return {cx:(s.x+s.w/2)/innerWidth, cy:(s.y+s.h/2)/innerHeight}; }
function _snowRestore(){
  try{
    const m=JSON.parse(localStorage.getItem("elSnow")||"null"); if(!m||!m.items) return;
    const away=Math.max(0,Math.min(14*86400,(Date.now()-m.saved)/1000));
    const loss=_snowLoss(m.t==null?0:m.t, away>3*3600?0:(m.uv||0), m.wind||0, 0.3, false);
    fgPile=m.items.map(it=>({cx:it.cx,cy:it.cy,dep:Math.max(0,it.dep-loss*away),peak:it.peak||it.dep})).filter(it=>it.dep>0.05);
  }catch(_){}
}
let _snowSaveT=0;
function _snowSave(force){
  const now=Date.now(); if(!force&&now-_snowSaveT<60000) return; _snowSaveT=now;
  try{ localStorage.setItem("elSnow",JSON.stringify({saved:now,t:scTempC,uv:scUV,wind:scWind,
    items:fgPile.filter(p=>p.dep>0.05)})); }catch(_){}
}
window.addEventListener("beforeunload",()=>_snowSave(true));
/* Which cells carry snow this scene: depth -> cap rows above each lip. */
let _snowArr=null;
function _snowGrid(){
  if(!fgPile.length||!fgSurf.length||!COLS) return null;
  if(!_snowArr||_snowArr.length!==COLS*ROWS) _snowArr=new Float32Array(COLS*ROWS);
  _snowArr.fill(0); let any=false;
  const lean=Math.max(-0.8,Math.min(0.8,crossWindKmh()/35));
  for(let si=0;si<fgSurf.length;si++){
    const s=fgSurf[si], k=_surfKey(s);
    if(!s.glass) continue;                       // an invisible layout box holds nothing (6 Nov 2026)
    const f=fgPile.find(p=>Math.abs(p.cx-k.cx)<0.06&&Math.abs(p.cy-k.cy)<0.06);
    if(!f||f.dep<0.12) continue;
    const c0=Math.max(0,Math.floor(s.x/innerWidth*COLS)), c1=Math.min(COLS-1,Math.floor((s.x+s.w)/innerWidth*COLS)-1);
    const lip=Math.round(s.y/innerHeight*ROWS)-1; if(lip<0||c1<c0) continue;
    const span=c1-c0+1, spanF=Math.max(0.15,Math.min(1,Math.sqrt(f.dep/Math.max(f.peak,0.01))));
    const half=span*0.5*spanF, mid=(c0+c1+1)*0.5+lean*(span*0.5-half)*0.5+lean*half*0.25;
    for(let cx=c0;cx<=c1;cx++){
      const off=Math.abs(cx+0.5-mid); if(off>half) continue;
      const t=half<=0.5?0:off/half, g=_dHash(cx*2.3,si*5.7);
      const deep=f.dep*Math.sqrt(Math.max(0,1-t*t))*(1-0.12*g);
      if(deep<=0.12) continue;
      for(let q=0;q<Math.ceil(deep);q++){ const cy=lip-q; if(cy<0) break;
        _snowArr[cy*COLS+cx]=0.35+0.60*Math.min(1,deep-q); any=true; }
    }
  }
  return any?_snowArr:null;
}
/* Rain is not drawn inside a tile, nor for a short ragged stretch under it -
   the rain shadow (Elemental 0.6). Rebuilt with the surfaces. */
let _furnArr=null, _furnTs=-1;
function _furnMask(){
  if(!COLS) return null;
  if(fgSurfTs===_furnTs&&_furnArr&&_furnArr.length===COLS*ROWS) return _furnArr;
  if(!fgSurf.length&&performance.now()-fgSurfTs>900){ fgSurfTs=performance.now(); refreshFgSurf(); }
  _furnTs=fgSurfTs; _furnArr=new Uint8Array(COLS*ROWS);
  for(const s of fgSurf){
    const c0=Math.max(0,Math.floor(s.x/innerWidth*COLS)), c1=Math.min(COLS-1,Math.ceil((s.x+s.w)/innerWidth*COLS)-1);
    const r0=Math.max(0,Math.round(s.y/innerHeight*ROWS)), r1=Math.min(ROWS-1,Math.ceil((s.y+s.h)/innerHeight*ROWS)-1);
    for(let cx=c0;cx<=c1;cx++){
      const sh=1+Math.floor(_dHash(cx*1.7,r1*3.1)*2.2);          // ragged shadow, 1-3 rows
      for(let cy=r0;cy<=Math.min(ROWS-1,r1+sh);cy++) _furnArr[cy*COLS+cx]=1;
    }
  }
  return _furnArr;
}
const FGRES=0.5;
function initFgFx(){ fgfx=$("fgfx"); if(!fgfx) return; sizeFgFx(); window.addEventListener("resize",sizeFgFx); }
function sizeFgFx(){ if(!fgfx) return; fgfx.width=Math.max(2,Math.round(innerWidth*FGRES)); fgfx.height=Math.max(2,Math.round(innerHeight*FGRES)); fgctx=fgfx.getContext("2d"); fgctx.setTransform(FGRES,0,0,FGRES,0,0); fgSurfTs=0; }
function refreshFgSurf(){
  fgSurf=[];
  const inMus=document.body.classList.contains("music");
  const sels=["#clockBlock",".card","#npCard"];
  if(f1weekActive && !inMus) sels.push("#f1Card .f1w-left","#f1Card .f1w-la","#f1Card .f1w-drawer","#f1Card .f1w-name");
  document.querySelectorAll(sels.join(",")).forEach(el=>{
    const cs=getComputedStyle(el); if(parseFloat(cs.opacity)<0.06||cs.visibility==="hidden") return;
    const b=el.getBoundingClientRect();
    if(b.width<24||b.height<12||b.bottom<0||b.top>innerHeight) return;
    const glass = el.classList.contains("card")||el.classList.contains("f1w-la")||el.classList.contains("f1w-drawer")||el.id==="npCard";
    fgSurf.push({x:b.left,y:b.top,w:b.width,h:b.height,glass});
  });
  if(f1weekActive && fGlow && COLS){ fgSurf.push({x:fCX0/COLS*innerWidth, y:fCY0/ROWS*innerHeight, w:(fCX1-fCX0)/COLS*innerWidth, h:(fCY1-fCY0)/ROWS*innerHeight, glass:false}); }
  _readSky();
}
/* Snow accumulates while it snows and then goes at the weather's pace - also
   when it has stopped, which is why this runs even on a dry frame. */
function _snowStep(dt, snowing, inten){
  if(snowing){
    for(const s of fgSurf){ const k=_surfKey(s);
      let f=fgPile.find(p=>Math.abs(p.cx-k.cx)<0.06&&Math.abs(p.cy-k.cy)<0.06);
      if(!f){ f={cx:k.cx,cy:k.cy,dep:0,peak:0}; fgPile.push(f); }
      f.dep=Math.min(SNOW_MAX,f.dep+dt*inten*0.0019); f.peak=Math.max(f.peak,f.dep); }
  } else if(fgPile.length){
    const t=scTempC==null?2:scTempC, evap=Math.max(0,Math.min(1,1-(scHumid||60)/100));
    const loss=_snowLoss(t, Math.max(0,astroNow.sunAlt)>0?(scUV||0):0, scWind||0, evap, (scRain||0)>0.05)*dt;
    for(const f of fgPile) f.dep=Math.max(0,f.dep-loss);
    fgPile=fgPile.filter(f=>f.dep>0.02);
  }
  _snowSave(false);
}
/* ---- LEAVES (Elemental 0.6.6, ported 6 Nov 2026; physics rebuilt same day) --
   "the leaves are like 5 miles away from the actual elements - they should fall
   on the actual trace of each element, actual physics, and as the time moves
   they drop down." So they no longer sit on the invisible box an element
   happens to have. The wall keeps a map of what is SOLID, cell by cell: the
   glass cards, and the big clock's own lit blocks, read from the clock as it is
   drawn - text and empty space are not solid, and leaves fall straight through.
   A leaf is a cell: it rests only while something solid or another leaf is
   directly under it, and the moment that goes - a digit changes as the minute
   turns, a card slides away - it drops. A heap slumps to its angle of repose;
   the wind walks dry ones along a top and they fall off the end; a gust lifts
   some. Only where there is an autumn (a clean-air town yes, a dusty city no), only in
   the wind, browning over two weeks, remembered across a restart. */
const LEAF={air:[], rest:new Map(), gustLeft:0, nextGust:8, clock:0, settle:0, saveT:0, solid:null, solidT:0};
function _leafSeason(){
  if(WS.leaves===false) return 0;
  const la=(typeof CURRENT!=="undefined"&&CURRENT)?CURRENT.lat:null; if(la==null) return 0;
  const a=Math.abs(la); if(a<=32||a>=64) return 0;          // a real autumn only: a clean-air town yes, a dusty city no
  const d0=new Date(), doy=(Date.UTC(d0.getFullYear(),d0.getMonth(),d0.getDate())-Date.UTC(d0.getFullYear(),0,0))/86400000;
  let d=doy; if(la<0) d=(d+182)%365;
  const x=(d-(296-(a-42)*2.2))/16;
  return Math.exp(-x*x)*Math.min(1,(a-32)/5)*Math.min(1,(64-a)/6);
}
function _leafRGB(h,age,wet){
  let r,g,b;
  if(h<0.5){ const t=h/0.5; r=168+46*t; g=38+60*t; b=30-4*t; } else { const t=(h-0.5)/0.5; r=214+8*t; g=98+70*t; b=26+14*t; }
  const k=Math.min(1,Math.max(0,age)/14); r+=(112-r)*k; g+=(74-g)*k; b+=(44-b)*k;
  if(wet){ r*=0.72; g*=0.72; b*=0.72; }
  return [r,g,b];
}
function _leafDry(){ return !((scRain||0)>0.05||(scSnow||0)>0.05||scKind==="rain"||scKind==="thunder"); }
/* The top row of a glass card that counts as solid: the first row it covers
   more than half of. A leaf rests in the row above it, on the card's edge. */
function _solidTopRow(s){ const ky=innerHeight/ROWS; return Math.ceil((s.y+0.55*ky)/ky)-1; }
/* What is solid, cell by cell: the glass cards, and the clock's lit blocks. */
function _leafSolid(){
  const n=COLS*ROWS; if(!LEAF.solid||LEAF.solid.length!==n) LEAF.solid=new Uint8Array(n);
  const S=LEAF.solid; S.fill(0);
  const kx=innerWidth/COLS, ky=innerHeight/ROWS;
  for(const s of fgSurf){ if(!s.glass) continue;
    const r0=Math.max(0,_solidTopRow(s)), r1=Math.min(ROWS-1,Math.floor((s.y+s.h-0.45*ky)/ky));
    const c0=Math.max(0,Math.ceil((s.x-0.5*kx)/kx)), c1=Math.min(COLS-1,Math.floor((s.x+s.w-0.5*kx)/kx));
    for(let y=r0;y<=r1;y++) for(let x=c0;x<=c1;x++) S[y*COLS+x]=1; }
  // The clock: its blocks are drawn on the mosaic's own grid, one canvas
  // cell to a wall cell, offset by the canvas's one-cell margin.
  try{ const cv=$("gridClock");
    if(cv&&GC&&GC.box&&parseFloat(cv.style.opacity||"1")>0.05&&typeof _gcShowClock==="function"&&_gcShowClock()){
      const c0=Math.round(parseFloat(cv.style.left)/kx)+1, r0=Math.round(parseFloat(cv.style.top)/ky)+1;
      for(const [k,st] of GC.st){ if(!(st.p>0.5)) continue; const [x,y]=k.split(",").map(Number);
        const X=c0+x, Y=r0+y; if(X>=0&&X<COLS&&Y>=0&&Y<ROWS) S[Y*COLS+X]=1; } } }catch(_){}
  return S;
}
const _lk=(x,y)=>y*4096+x;
function _leafFree(x,y){ return x>=0&&x<COLS&&y>=0&&y<ROWS&&!LEAF.solid[y*COLS+x]&&!LEAF.rest.has(_lk(x,y)); }
function _leafHeld(x,y){ return y+1>=ROWS||LEAF.solid[(y+1)*COLS+x]||LEAF.rest.has(_lk(x,y+1)); }
function _leafLaunch(x,y,lift,age,hue){
  if(LEAF.air.length>=60) return;
  LEAF.air.push({x,y,vx:(Math.random()-0.5)*60,vy:lift?-40-Math.random()*60:20,ph:Math.random()*6.28,hue:hue==null?Math.random():hue,age:age||0});
}
/* A falling leaf, as a leaf falls: a pendulum, gliding one way and back,
   slowest flat at the bottom of each swing, carried by the wind. It comes to
   rest in the first free cell that has something under it. */
function _leafFly(l,dt,cw,gusting){
  const W=innerWidth, H=innerHeight, SPp=H/ROWS;
  l.ph+=dt*(5.2+1.5*Math.sin(l.hue*9));
  const sw=Math.cos(l.ph), edge=Math.abs(Math.sin(l.ph));
  l.vx+=(cw*W*0.0016*(gusting?1.6:1)+sw*SPp*2.2-l.vx)*Math.min(1,dt*3);
  l.vy+=(H*0.04*(0.35+1.3*edge)-l.vy)*Math.min(1,dt*2.5);
  const ox=Math.floor(l.x/W*COLS), oy=Math.floor(l.y/H*ROWS);
  l.x+=l.vx*dt; l.y+=l.vy*dt;
  let cx=Math.floor(l.x/W*COLS), cy=Math.floor(l.y/H*ROWS);
  if(cx<-3||cx>COLS+2) return true;
  if(cx<0||cx>=COLS||cy<0) return false;
  if(cy>=ROWS) cy=ROWS-1;
  // Into something solid or a leaf: it stops on top of it, in the cell it came from.
  if(!_leafFree(cx,cy)){ if(oy<cy&&_leafFree(cx,cy-1)) cy=cy-1; else if(_leafFree(ox,oy)){ cx=ox; cy=oy; } else return false; }
  if(l.vy>0&&_leafHeld(cx,cy)){ LEAF.rest.set(_lk(cx,cy),{x:cx,y:cy,hue:l.hue,age:l.age}); return true; }
  return false;
}
/* A few times a second: anything with nothing under it drops; a heap slumps;
   the wind walks dry ones downwind, a cell at a time. Bottom-up, so a column
   falls as a column. */
function _leafSettle(cw,gusting,dry){
  _leafSolid();
  const list=[...LEAF.rest.values()].sort((a,b)=>b.y-a.y);
  const dir=cw>=0?1:-1, walk=dry&&Math.abs(cw)>10 ? Math.min(1,Math.abs(cw)/30)*(gusting?0.3:0.015) : 0;   // per quarter second: ~1 cell/s in a gust
  for(const l of list){
    const k=_lk(l.x,l.y);
    if(LEAF.solid[l.y*COLS+l.x]){ LEAF.rest.delete(k); if(l.y>0) _leafLaunch((l.x+0.5)/COLS*innerWidth,(l.y-0.5)/ROWS*innerHeight,true,l.age,l.hue); continue; }
    if(!_leafHeld(l.x,l.y)){                                 // what held it is gone: it drops
      LEAF.rest.delete(k); LEAF.air.push({x:(l.x+0.5)/COLS*innerWidth,y:(l.y+0.5)/ROWS*innerHeight,vx:0,vy:10,ph:Math.random()*6.28,hue:l.hue,age:l.age}); continue; }
    const onLeaf=l.y+1<ROWS&&LEAF.rest.has(_lk(l.x,l.y+1));
    let mx=0;
    if(onLeaf&&Math.random()<0.35){                          // angle of repose: off the side of a heap
      const s=Math.random()<0.5?-1:1;
      if(_leafFree(l.x+s,l.y)&&_leafFree(l.x+s,l.y+1)) mx=s; else if(_leafFree(l.x-s,l.y)&&_leafFree(l.x-s,l.y+1)) mx=-s; }
    if(!mx&&walk>0&&Math.random()<walk&&_leafFree(l.x+dir,l.y)) mx=dir;   // the wind walks it along
    if(mx){ LEAF.rest.delete(k); l.x+=mx;
      if(_leafHeld(l.x,l.y)) LEAF.rest.set(_lk(l.x,l.y),l);
      else LEAF.air.push({x:(l.x+0.5)/COLS*innerWidth,y:(l.y+0.5)/ROWS*innerHeight,vx:mx*20,vy:10,ph:Math.random()*6.28,hue:l.hue,age:l.age}); }
  }
}
function _leafStep(dt){
  if(!COLS||document.body.classList.contains("music")) return;
  if(!LEAF.solid||LEAF.solid.length!==COLS*ROWS) _leafSolid();
  const season=_leafSeason();
  if(season<0.02&&!LEAF.air.length&&!LEAF.rest.size) return;
  const now=performance.now();
  if(now-fgSurfTs>1000){ fgSurfTs=now; refreshFgSurf(); }
  const wind=Math.max(0,scWind||0), cw=crossWindKmh(), dry=_leafDry(), W=innerWidth, H=innerHeight;
  if(LEAF.gustLeft>0) LEAF.gustLeft-=dt; else { LEAF.nextGust-=dt;
    if(LEAF.nextGust<=0){ LEAF.gustLeft=1.5+Math.random()*3; LEAF.nextGust=(wind>25?6:wind>12?14:40)*(0.5+Math.random()); } }
  const gusting=LEAF.gustLeft>0&&wind>6, gust=gusting?Math.min(1,0.3+wind/35):0;
  if(season>0.02&&wind>6){
    const rate=season*(gusting?0.3+wind/40:(wind-6)/900);
    if(Math.random()<rate*dt){
      if(Math.abs(cw)>8&&Math.random()<0.7) _leafLaunch(cw>0?-H/ROWS:W+H/ROWS, H*(0.05+Math.random()*0.45));
      else _leafLaunch(Math.random()*W,-H/ROWS);
    }
  }
  // A gust lifts a dry one back off.
  if(gusting&&dry&&gust>0.3&&LEAF.rest.size&&Math.random()<gust*dt*0.6){
    const arr=[...LEAF.rest.values()], l=arr[(Math.random()*arr.length)|0];
    if(_leafFree(l.x,l.y-1)){ LEAF.rest.delete(_lk(l.x,l.y)); _leafLaunch((l.x+0.5)/COLS*W,(l.y-0.3)/ROWS*H,true,l.age,l.hue); } }
  for(let i=LEAF.air.length-1;i>=0;i--) if(_leafFly(LEAF.air[i],dt,cw,gusting)) LEAF.air.splice(i,1);
  LEAF.settle+=dt; if(LEAF.settle>=0.25){ LEAF.settle=0; _leafSettle(cw,gusting,dry); }
  LEAF.clock+=dt;
  if(LEAF.clock>=10){
    const day=LEAF.clock/86400; LEAF.clock=0;
    const p=(season>0.15?0.01:0.07)*day*1.6;                // per leaf: a pile thins over weeks once the trees are bare
    for(const [k,l] of LEAF.rest){ l.age+=day;
      const snowy=_snowArr&&_snowArr[l.y*COLS+l.x]>0;
      if(!snowy&&Math.random()<p) LEAF.rest.delete(k); }
    _leafSave(false);
  }
}
let _leafArr=null;
function _leafGrid(){
  if(!COLS||(!LEAF.air.length&&!LEAF.rest.size)) return null;
  if(!_leafArr||_leafArr.length!==COLS*ROWS*4) _leafArr=new Float32Array(COLS*ROWS*4);
  _leafArr.fill(0);
  const wet=!_leafDry(), A=_leafArr;
  const put=(cx,cy,a,rgb)=>{ if(cx<0||cy<0||cx>=COLS||cy>=ROWS) return; const o=(cy*COLS+cx)*4;
    if(a<=A[o+3]) return; A[o]=rgb[0]; A[o+1]=rgb[1]; A[o+2]=rgb[2]; A[o+3]=a; };
  for(const l of LEAF.rest.values()) put(l.x,l.y,0.86,_leafRGB(l.hue,l.age,wet));
  for(const l of LEAF.air) put(Math.floor(l.x/innerWidth*COLS),Math.floor(l.y/innerHeight*ROWS),0.9,_leafRGB(l.hue,l.age,false));
  return A;
}
function _leafSave(force){
  const now=Date.now(); if(!force&&now-LEAF.saveT<60000) return; LEAF.saveT=now;
  try{ localStorage.setItem("elLeaves",JSON.stringify({v:2,saved:now,
    rest:[...LEAF.rest.values()].map(l=>[+(l.x/COLS).toFixed(4),+(l.y/ROWS).toFixed(4),+l.hue.toFixed(3),+l.age.toFixed(3)])})); }catch(_){}
}
/* Back where they lay, older for the time away. Positions are fractions of
   the wall, so a different grid still finds them; anything that no longer has
   something under it simply falls on the first settle. (The first version's
   piles were on the wrong boxes; they come down from above their spot.) */
function _leafRestore(){
  try{ const m=JSON.parse(localStorage.getItem("elLeaves")||"null"); if(!m) return;
    const days=Math.max(0,Math.min(14,(Date.now()-m.saved)/86400000)), p=Math.min(1,(_leafSeason()>0.15?0.01:0.07)*days*1.6);
    const go=()=>{ if(!COLS){ setTimeout(go,500); return; }
      if(m.v===2){ for(const [fx,fy,h,a] of m.rest||[]){ if(Math.random()<p) continue;
          const x=Math.min(COLS-1,Math.floor(fx*COLS)), y=Math.min(ROWS-1,Math.floor(fy*ROWS));
          if(!LEAF.rest.has(_lk(x,y))) LEAF.rest.set(_lk(x,y),{x,y,hue:h,age:a+days}); } }
      else { for(const pl of m.piles||[]) for(const l of pl.l||[]) _leafLaunch(pl.cx*innerWidth+(l.u-0.5)*innerWidth*0.1,0,false,(l.age||0)+days,l.hue);
        const g=m.ground||[]; for(let c=0;c<COLS;c++){ const v=g[Math.min(g.length-1,Math.floor(c*g.length/COLS))]||0;
          if(v>0.06) LEAF.rest.set(_lk(c,ROWS-1),{x:c,y:ROWS-1,hue:Math.random(),age:((m.groundAge||[])[0]||0)+days}); } }
    };
    go();
  }catch(_){}
}
window.addEventListener("beforeunload",()=>_leafSave(true));

/* ---- FESTIVALS (Elemental 0.6.6, ported 6 Nov 2026) ----------------------
   "in America do the American things, in India the Indian things, in Europe
   the European things." Each place keeps its own, drawn with the mosaic's
   own cells - a festival light is a tile lit in its own colour:
     India   diyas Dhanteras..Bhai Dooj, fireworks building to Diwali night;
             bonfires at Lohri, Holika Dahan, Dussehra; kites at Makar
             Sankranti and 15 Aug; gulal at Holi; lights at Navratri, Christmas
     US      Fourth of July fireworks, Halloween lanterns, Christmas lights
     Europe  Christmas-market lights in December, Bonfire Night (UK), Bastille
             Day (France), Midsummer bonfires (the north)
     all     New Year fireworks at midnight
   Diyas are clay bowls with a flickering flame, one at each end of every card's
   top edge and the rest evenly between ("organised"). Lunar dates: New northern India
   panchang, 2026-2030. */
const FEST_T={diwali:{2026:[11,8],2027:[10,29],2028:[10,17],2029:[11,5],2030:[10,26]},
  dhanteras:{2026:[11,6],2027:[10,27],2028:[10,15],2029:[11,4],2030:[10,24]},
  bhaiDooj:{2026:[11,11],2027:[10,31],2028:[10,19],2029:[11,7],2030:[10,28]},
  holi:{2026:[3,4],2027:[3,23],2028:[3,11],2029:[3,1],2030:[3,20]},
  sankranti:{2026:[1,14],2027:[1,14],2028:[1,15],2029:[1,14],2030:[1,14]},
  navratri:{2026:[10,11],2027:[9,30],2028:[9,19],2029:[10,8],2030:[9,28]},
  dussehra:{2026:[10,20],2027:[10,9],2028:[9,27],2029:[10,16],2030:[10,6]},
  gurpurab:{2026:[11,24],2027:[11,14],2028:[11,2],2029:[11,21],2030:[11,10]}};
function _festRegion(lat,lon){
  if(lat>6&&lat<37.5&&lon>68&&lon<97.5) return "india";
  if(lat>24&&lat<50&&lon>-125&&lon<-66) return "us";
  if(lat>49.8&&lat<61&&lon>-10.8&&lon<1.9) return "uk";
  if(lat>54.5&&lat<71.5&&lon>4.5&&lon<32) return "nordic";
  if(lat>42.3&&lat<51.1&&lon>-4.9&&lon<8.3) return "france";
  if(lat>35&&lat<71&&lon>-10.5&&lon<40) return "europe";
  return "other";
}
/* The wall's own wall-clock time, in the time zone of where it is mounted
   (CURRENT.tz) - never the device's setting, which may be anything. */
function _festNow(){ try{ if(CURRENT&&CURRENT.tz) return new Date(new Date().toLocaleString("en-US",{timeZone:CURRENT.tz})); }catch(_){}
  return new Date(); }
function _festLook(now){
  const z={name:"",lamps:0,fireworks:0,strings:0,lanterns:0,bonfire:0,kites:0,colours:0};
  const night=Object.assign({},z), day=Object.assign({},z);
  if(WS.festivals===false) return {night,day};
  const C=(typeof CURRENT!=="undefined"&&CURRENT)?CURRENT:null; if(!C||C.lat==null) return {night,day};
  const reg=_festRegion(C.lat,C.lon), india=reg==="india", eu=["uk","france","nordic","europe"].includes(reg);
  const e=new Date(now.getTime()-(now.getHours()<4?86400000:0));          // an evening runs on till four
  const mid=d=>new Date(d.getFullYear(),d.getMonth(),d.getDate());
  const off=(d,k)=>{ const t=FEST_T[k][d.getFullYear()]; if(!t) return null; return Math.round((mid(d)-new Date(d.getFullYear(),t[0]-1,t[1]))/86400000); };
  const on=(d,m,dd)=>d.getMonth()+1===m&&d.getDate()===dd;
  if(india){
    if(on(e,1,13)){ night.name="Lohri"; night.bonfire=1; }
    if(off(e,"holi")===-1){ night.name="Holika Dahan"; night.bonfire=1; }
    const nv=off(e,"navratri"); if(nv!=null&&nv>=0&&nv<9){ night.name="Navratri"; night.strings=0.5; }
    if(off(e,"dussehra")===0){ night.name="Dussehra"; night.bonfire=1; night.fireworks=0.5; night.strings=0; }
    const d0=off(e,"dhanteras"), d1=off(e,"diwali"), d2=off(e,"bhaiDooj");
    if(d0!=null&&d2!=null&&d0>=0&&d2<=0){ night.name="Diwali";
      if(d1===0){ night.lamps=1; night.fireworks=1; } else if(d1===-1){ night.lamps=0.9; night.fireworks=0.5; }
      else if(d1===1){ night.lamps=0.8; night.fireworks=0.35; } else if(d1<-1){ night.lamps=0.75; night.fireworks=0.2; }
      else { night.lamps=0.6; night.fireworks=0.1; } }
    if(off(e,"gurpurab")===0){ night.name="Gurpurab"; night.lamps=0.7; night.fireworks=0.2; }
  }
  if(reg==="us"){ if(on(e,7,4)){ night.name="Fourth of July"; night.fireworks=0.85; } if(on(e,10,31)){ night.name="Halloween"; night.lanterns=1; } }
  if(eu){
    if(e.getMonth()===11&&e.getDate()<24){ night.name="Advent"; night.strings=0.4; }
    if(reg==="uk"&&on(e,11,5)){ night.name="Bonfire Night"; night.bonfire=1; night.fireworks=0.7; }
    if(reg==="france"&&on(e,7,14)){ night.name="Bastille Day"; night.fireworks=0.9; }
  }
  if(india||reg==="us"||eu){ if(on(e,12,24)||on(e,12,25)||(eu&&on(e,12,26))){ night.name="Christmas"; night.strings=1; } }
  if(on(e,12,31)){ night.name="New Year"; const m=now.getHours()*60+now.getMinutes(), fm=m>=720?m-1440:m;
    night.fireworks=fm<-45?0.1:fm<0?0.5:fm<40?1:0.25; night.strings=Math.max(night.strings,0.4); }
  if(reg==="nordic"&&now.getMonth()===5&&now.getDate()>=19&&now.getDate()<=25&&now.getDay()===5){ day.name="Midsummer"; day.bonfire=1; }
  if(india){
    if(off(now,"sankranti")===0){ day.name="Makar Sankranti"; day.kites=1; }
    if(on(now,8,15)){ day.name="Independence Day"; day.kites=0.8; }
    if(off(now,"holi")===0){ day.name="Holi"; day.colours=1; }
  }
  return {night,day};
}
const FEST={night:{},day:{},nk:0,dk:0,t:0,clock:1e9,sparks:[],kites:[],puffs:[],gulal:new Map()};
const _FB=[[[255,204,90]],[[255,77,64],[255,204,90]],[[90,255,115]],[[255,90,217],[140,115,255]],[[115,178,255],[255,255,255]],[[255,140,38]],[[255,255,255]]];
const _FG=[[255,64,153],[51,217,90],[255,217,38],[64,128,255],[255,128,25],[166,64,230]];
const _FK=[[255,64,77],[255,204,38],[64,191,102],[77,128,255],[255,115,204],[255,140,25]];
function _festActive(){ const n=FEST.night||{}, d=FEST.day||{};
  return (FEST.nk>0&&(n.lamps||n.fireworks||n.strings||n.lanterns||n.bonfire))||(FEST.dk>0&&(d.kites||d.colours||d.bonfire))
    ||FEST.sparks.length||FEST.puffs.length||FEST.gulal.size; }
function _festStep(dt){
  if(!COLS||document.body.classList.contains("music")) return;
  FEST.t+=dt; FEST.clock+=dt;
  if(FEST.clock>30){ FEST.clock=0; const l=_festLook(_festNow()); FEST.night=l.night; FEST.day=l.day; }
  const alt=(astroNow&&astroNow.sunAlt!=null)?astroNow.sunAlt:0;
  FEST.nk=Math.max(0,Math.min(1,(-alt-1)/5)); FEST.dk=Math.max(0,Math.min(1,(alt+2)/6));
  if(!_festActive()) return;
  const W=innerWidth, H=innerHeight, SP=H/ROWS, cw=crossWindKmh(), n=FEST.night, d=FEST.day, R=Math.random;
  const fw=(n.fireworks||0)*FEST.nk;
  if(fw>0.01&&R()<(2+22*fw)/60*dt&&FEST.sparks.length<700){
    const b=(R()*_FB.length)|0;
    FEST.sparks.push({x:W*(0.08+R()*0.84),y:H,vx:(R()-0.5)*SP*3,vy:-H*(0.55+R()*0.25),life:0,max:1.1+R()*0.6,rgb:_FB[b][0],rocket:1,b});
  }
  const fire=Math.max((n.bonfire||0)*FEST.nk,(d.bonfire||0)*FEST.dk);
  if(fire>0.01&&R()<fire*6*dt&&FEST.sparks.length<700)
    FEST.sparks.push({x:W*0.5+(R()-0.5)*SP*4,y:H-SP*3,vx:(R()-0.5)*SP*2,vy:-SP*(4+R()*5),life:0,max:1.5+R()*1.5,rgb:[255,(140+R()*77)|0,38],rocket:0});
  const born=[];
  for(let k=FEST.sparks.length-1;k>=0;k--){ const s=FEST.sparks[k]; s.life+=dt;
    if(s.rocket){ s.vy+=H*0.32*dt; s.x+=s.vx*dt; s.y+=s.vy*dt;
      if(s.vy>-H*0.08||s.life>s.max){ const pal=_FB[s.b], cnt=28+((R()*22)|0), sp=SP*(9+R()*7);
        for(let i=0;i<cnt;i++){ const a=i/cnt*6.2832+R()*0.2, v=sp*(i%3===0?0.55+R()*0.3:0.9+R()*0.15);
          born.push({x:s.x,y:s.y,vx:Math.cos(a)*v,vy:Math.sin(a)*v,life:0,max:1.3+R()*0.9,rgb:pal[i%pal.length],rocket:0}); }
        FEST.sparks.splice(k,1); continue; } }
    else { const dr=1-Math.min(1,dt*1.6); s.vx*=dr; s.vy*=dr; s.vy+=SP*5*dt; s.vx+=cw*SP*0.02*dt; s.x+=s.vx*dt; s.y+=s.vy*dt;
      if(s.life>s.max||s.y>H||s.x<-SP||s.x>W+SP){ FEST.sparks.splice(k,1); continue; } } }
  for(const b of born) FEST.sparks.push(b);
  const kn=Math.round((d.kites||0)*FEST.dk*7);
  while(FEST.kites.length<kn) FEST.kites.push({x:W*(0.1+R()*0.8),y:H*(0.1+R()*0.32),ph:R()*6.28,big:R()<0.3,rgb:_FK[(R()*6)|0],tail:_FK[(R()*6)|0]});
  if(FEST.kites.length>kn) FEST.kites.length=kn;
  FEST.kites.forEach((k,i)=>{ k.ph+=dt*(0.7+i*0.13); k.x+=(Math.sin(k.ph)*SP*0.6+cw*SP*0.01)*dt; k.y+=Math.cos(k.ph*1.3)*SP*0.4*dt;
    k.x=Math.min(W*0.95,Math.max(W*0.05,k.x)); k.y=Math.min(H*0.5,Math.max(H*0.06,k.y)); });
  const col=(d.colours||0)*FEST.dk;
  if(col>0.01&&R()<col*0.7*dt&&FEST.puffs.length<30)
    FEST.puffs.push({x:W*(0.05+R()*0.9),y:H*(0.45+R()*0.45),r:SP*(1.5+R()*2),life:0,max:4+R()*4,rgb:_FG[(R()*6)|0]});
  for(let k=FEST.puffs.length-1;k>=0;k--){ const p=FEST.puffs[k]; p.life+=dt; p.x+=cw*SP*0.03*dt; p.y-=SP*0.25*dt; p.r+=SP*0.35*dt;
    if(p.life>p.max){ for(const s of fgSurf){ if(p.x>s.x&&p.x<s.x+s.w&&p.y<s.y){ const k2=_surfKey(s), key=k2.cx.toFixed(3)+","+k2.cy.toFixed(3);
        const m=FEST.gulal.get(key)||new Map(); for(let c=Math.floor((p.x-p.r)/W*COLS);c<=Math.floor((p.x+p.r)/W*COLS);c++) if(R()<0.6) m.set(c,{rgb:p.rgb,life:10800});
        FEST.gulal.set(key,m); break; } }
      FEST.puffs.splice(k,1); } }
  for(const [key,m] of FEST.gulal){ for(const [c,g] of m){ g.life-=dt; if(g.life<=0) m.delete(c); } if(!m.size) FEST.gulal.delete(key); }
}
/* The cells: r,g,b (0..255), alpha, glows - painted over everything else. */
let _festArr=null;
function _festGrid(){
  if(!COLS||!_festActive()) return null;
  if(!_festArr||_festArr.length!==COLS*ROWS*5) _festArr=new Float32Array(COLS*ROWS*5);
  _festArr.fill(0);
  const A=_festArr, W=innerWidth, H=innerHeight, t=FEST.t, n=FEST.night, d=FEST.day, nk=FEST.nk, dk=FEST.dk;
  const put=(cx,cy,a,rgb,glow)=>{ if(cx<0||cy<0||cx>=COLS||cy>=ROWS||a<=0.02) return; const o=(cy*COLS+cx)*5; if(A[o+3]>=a) return;
    A[o]=rgb[0]; A[o+1]=rgb[1]; A[o+2]=rgb[2]; A[o+3]=Math.min(1,a); A[o+4]=glow?1:0; };
  const hash=x=>{ const s=Math.sin(x*12.9898)*43758.5453; return s-Math.floor(s); };
  const flick=seed=>0.72+0.28*hash(Math.floor(t*5+seed*3)*1.7+seed*31);
  const surfs=fgSurf.filter(s=>s.glass).map(s=>({c0:Math.ceil(s.x/W*COLS),c1:Math.floor((s.x+s.w)/W*COLS)-1,top:_solidTopRow(s)-1}));   // on the card itself, where a leaf rests - never on an invisible box
  if((n.lamps||0)*nk>0.02){ const a=n.lamps*nk;
    const diya=(cx,foot,seed)=>{ const fl=flick(seed);
      put(cx,foot,0.95*a,[143,61,26],0); put(cx-1,foot-1,0.95*a,[199,92,41],0); put(cx,foot-1,0.95*a,[77,36,15],0); put(cx+1,foot-1,0.95*a,[199,92,41],0);
      put(cx,foot-2,a*(0.7+0.3*fl),[255,(199+36*fl)|0,(87+51*fl)|0],1);
      put(cx-1,foot-2,a*0.22*fl,[255,140,38],1); put(cx+1,foot-2,a*0.22*fl,[255,140,38],1);
      if(fl>0.86) put(cx,foot-3,a*0.55,[255,133,31],1); };
    const row=(first,last,foot,seed)=>{ if(last<first) return; const cnt=Math.max(1,Math.floor((last-first)/7)+1);
      for(let k=0;k<cnt;k++){ const cx=cnt===1?((first+last)>>1):first+Math.round(k*(last-first)/(cnt-1)); diya(cx,foot,cx*0.37+seed); } };
    surfs.forEach((s,i)=>{ if(s.c1-s.c0>=2&&s.top>2) row(s.c0+1,s.c1-1,s.top,i); });
    row(1,COLS-2,ROWS-1,0.5);
  }
  if((n.strings||0)*nk>0.02){ const a=n.strings*nk, pal=[[255,64,64],[77,255,102],[255,204,77],[102,153,255]];
    const bulb=(cx,cy,k)=>{ const lit=hash(Math.floor(t*1.5+k*0.7)+k)>0.25; put(cx,cy,a*(lit?0.95:0.35),pal[k%4],1); };
    surfs.forEach((s,i)=>{ if(s.top<1) return; let k=i; for(let c=s.c0;c<=s.c1;c+=2) bulb(c,s.top,k++); });
    let k=0; for(let c=1;c<COLS;c+=3) bulb(c,0,k++);
  }
  if((n.lanterns||0)*nk>0.02){ const a=n.lanterns*nk;
    for(let c=4;c<COLS-1;c+=9){ put(c,ROWS-1,a*flick(c),[255,128,20],1); put(c+1,ROWS-1,a*0.8*flick(c+9),[255,107,13],1); } }
  const fireA=Math.max((n.bonfire||0)*nk,(d.bonfire||0)*dk);
  if(fireA>0.02){ const midC=COLS>>1;
    for(let dd=-3;dd<=3;dd++){ const cx=midC+dd, tall=(4.5-Math.abs(dd))*(0.6+0.6*flick(cx*1.3));
      for(let k=0;k<Math.ceil(tall);k++){ const f=k/Math.max(1,tall); put(cx,ROWS-1-k,fireA*(1-f*0.35),[255,(64+153*f)|0,(13+64*f*f)|0],1); } } }
  for(const s of FEST.sparks){ const cx=Math.floor(s.x/W*COLS), cy=Math.floor(s.y/H*ROWS), f=s.rocket?0.85:Math.max(0,1-s.life/s.max);
    const crack=(!s.rocket&&f<0.3)?(hash(cx*7+cy+Math.floor(t*12))>0.5?1:0.2):1; put(cx,cy,Math.min(1,(0.25+0.85*f)*crack),s.rgb,1); }
  for(const k of FEST.kites){ const cx=Math.floor(k.x/W*COLS), cy=Math.floor(k.y/H*ROWS), a=dk*(d.kites||0), dim=c=>c.map(v=>v*0.82);
    put(cx,cy-1,a,k.rgb,0); put(cx-1,cy,a,k.rgb,0); put(cx+1,cy,a,dim(k.rgb),0); put(cx,cy,a,k.tail,0); put(cx,cy+1,a,dim(k.rgb),0);
    if(k.big){ put(cx,cy-2,a,k.rgb,0); put(cx,cy+2,a,dim(k.rgb),0); }
    let x=cx, y=cy+2; for(let i=0;i<6;i++){ x-=0.6; y+=1.4; put(Math.floor(x),Math.floor(y),a*0.35,[235,235,242],0); } }
  for(const p of FEST.puffs){ const f=1-p.life/p.max, r=p.r/H*ROWS, px=p.x/W*COLS, py=p.y/H*ROWS;
    for(let cy=Math.floor(py-r);cy<=Math.floor(py+r);cy++) for(let cx=Math.floor(px-r);cx<=Math.floor(px+r);cx++){
      const dd=Math.hypot(cx+0.5-px,cy+0.5-py)/Math.max(0.5,r); if(dd>=1||hash(cx*3.1+cy*7.3)<=dd*0.8) continue;
      put(cx,cy,f*(1-dd*0.6)*0.9,p.rgb,1); } }
  for(const s of fgSurf){ const k2=_surfKey(s), m=FEST.gulal.get(k2.cx.toFixed(3)+","+k2.cy.toFixed(3)); if(!m) continue;
    const top=_solidTopRow(s)-1; for(const [c,g] of m) put(c,top,Math.min(0.8,g.life/1800)*0.8,g.rgb,0); }
  return A;
}

function fgFxFrame(dt){
  try{ _leafStep(dt); }catch(_){}
  try{ _festStep(dt); }catch(_){}
  if(!fgctx) return;
  if(fgPile.length && !(scKind==="snow")) _snowStep(dt,false,0);
  const wet=(scKind==="rain"||scKind==="thunder"||scKind==="snow") && !_lowFx;
  if(!wet){ if(fgActive){ fgctx.clearRect(0,0,innerWidth,innerHeight); fgSplash.length=0; fgDrip.length=0; fgActive=false; fgfx.style.display="none"; } return; }
  if(!fgActive){ fgActive=true; fgfx.style.display="block"; }
  const now=performance.now();
  if(now-fgSurfTs>900){ fgSurfTs=now; refreshFgSurf(); }
  const snow=(scKind==="snow");
  const inten = snow?Math.min(1,0.4+scSnow/4):(scKind==="thunder"?Math.min(1,0.65+scRain/8):Math.min(1,0.28+Math.max(scRain,scPrecip)/4));
  for(let si=0;si<fgSurf.length;si++){
    const s=fgSurf[si];
    if(Math.random() < inten*(s.w/innerWidth)*1.35){
      const px=s.x+Math.random()*s.w, cnt=snow?1:(2+(Math.random()*3|0));
      for(let k=0;k<cnt;k++) fgSplash.push({x:px,y:s.y,vx:(Math.random()-0.5)*(snow?26:130)+crossWindKmh()*(snow?1.6:0.9),vy:snow?12:-(50+Math.random()*110),g:snow?130:600,l:0,m:snow?1.0:0.46});
    }
    if(s.glass && !snow && Math.random() < inten*(s.h/innerHeight)*0.72){
      fgDrip.push({x:s.x+5+Math.random()*(s.w-10),y:s.y+Math.random()*s.h*0.55,vy:7+Math.random()*11,bot:s.y+s.h,r:0.9+Math.random()*1.1});
    }
  }
  // Snow settles on the top edge of the furniture. The wallpaper draws BEHIND
  // these elements, so anything landing there is occluded by them - which is
  // exactly what real snow on a ledge does.
  _snowStep(dt, snow, inten);
  fgctx.clearRect(0,0,innerWidth,innerHeight);
  fgctx.lineCap="round";
  const _s=_mSky, dR=Math.min(255,(_s[0]*1.35+94)|0), dG=Math.min(255,(_s[1]*1.35+98)|0), dB=Math.min(255,(_s[2]*1.35+106)|0);
  // splashes -> one batched stroke (tinted to the live sky/mosaic tone)
  const sq=(STYLE==="glass");
  fgctx.fillStyle = snow?"rgba(244,248,255,0.9)":`rgba(${dR},${dG},${dB},0.92)`;
  fgctx.beginPath();
  for(let i=fgSplash.length-1;i>=0;i--){
    const q=fgSplash[i]; q.l+=dt; if(q.l>=q.m){ fgSplash.splice(i,1); continue; }
    q.vy+=q.g*dt; q.x+=q.vx*dt; q.y+=q.vy*dt;
    const z=snow?1.8:1.3;
    if(sq){ fgctx.rect(q.x-z*0.5,q.y-z*0.5,z,z); } else { fgctx.moveTo(q.x+z*0.62,q.y); fgctx.arc(q.x,q.y,z*0.62,0,6.28); }
  }
  fgctx.fill();
  // drip trails -> one batched stroke; heads collected
  const heads=[];
  fgctx.strokeStyle=`rgba(${dR},${dG},${dB},0.22)`; fgctx.lineWidth=1.6;
  fgctx.beginPath();
  for(let i=fgDrip.length-1;i>=0;i--){
    const d=fgDrip[i]; d.vy+=52*dt; d.y+=d.vy*dt;
    if(d.y>=d.bot){ for(let k=0;k<2;k++) fgSplash.push({x:d.x+(Math.random()-0.5)*5,y:d.bot,vx:(Math.random()-0.5)*70,vy:-(18+Math.random()*54),g:600,l:0,m:0.34}); fgDrip.splice(i,1); continue; }
    fgctx.moveTo(d.x,d.y-19); fgctx.lineTo(d.x,d.y); heads.push(d);
  }
  fgctx.stroke();
  // drip heads -> one batched fill
  fgctx.fillStyle=`rgba(${dR},${dG},${dB},0.74)`; fgctx.beginPath();
  for(let i=0;i<heads.length;i++){ const d=heads[i];
    if(sq){ fgctx.rect(d.x-d.r,d.y-d.r,d.r*2,d.r*2); } else { fgctx.moveTo(d.x+d.r,d.y); fgctx.arc(d.x,d.y,d.r,0,6.28); } }
  fgctx.fill();
  if(fgSplash.length>240) fgSplash.splice(0,fgSplash.length-240);
  if(fgDrip.length>120) fgDrip.splice(0,fgDrip.length-120);
}
/* ---- WAKE REPLAY ----------------------------------------------------------
   Coming back from a long sleep, the sun teleporting across the sky is the one
   thing that gives the illusion away. Instead, replay the interval that was
   missed as a time-lapse that decelerates into now. Gaps under ten minutes
   resume instantly - replaying a brief interruption is worse than not. */
