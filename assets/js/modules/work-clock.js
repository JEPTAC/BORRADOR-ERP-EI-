import {api} from "../services/api.js";
import {navigate} from "../core/router.js";
import {fmt} from "../core/format.js";

let slot=null;
let data=null;
let pollTimer=null;
let tickTimer=null;
let bound=false;

export function initWorkClock(){
  slot=document.querySelector("#work-clock-slot");
  if(!slot)return;
  if(!bound){
    bound=true;
    slot.addEventListener("click",()=>navigate("workforce"));
    window.addEventListener("erp:work-changed",scheduleRefresh);
    window.addEventListener("erp:refresh-workforce",()=>refresh(true));
    document.addEventListener("visibilitychange",()=>{if(!document.hidden)refresh()});
  }
  render();
  refresh();
  clearInterval(pollTimer);pollTimer=setInterval(()=>refresh(),60000);
  clearInterval(tickTimer);tickTimer=setInterval(render,1000);
}

function scheduleRefresh(){setTimeout(()=>refresh(),220)}

async function refresh(force=false){
  if(!slot)return;
  try{data=await api.workMyDay();render()}catch(error){if(force)console.error("[ERP WORK CLOCK]",error)}
}

function render(){
  if(!slot)return;
  const active=data?.active;
  if(!active){
    const pending=(data?.today?.length||0)+(data?.overdue?.length||0);
    slot.innerHTML=`<button type="button" class="work-clock-trigger idle" aria-label="Abrir Mi Jornada"><span class="work-clock-dot"></span><span><strong>Mi jornada</strong><small>${pending?`${pending} actividad(es) pendiente(s)`:"Sin actividad adicional"}</small></span></button>`;
    return;
  }
  const elapsed=active.status==="PAUSED"?Number(active.metrics?.elapsedSeconds||0):Math.max(Number(active.metrics?.elapsedSeconds||0),Math.floor((Date.now()-new Date(active.startedAt).getTime())/1000));
  slot.innerHTML=`<button type="button" class="work-clock-trigger running ${active.status==="PAUSED"?"paused":""}" aria-label="Abrir actividad actual"><span class="work-clock-dot"></span><span><strong>${fmt.escape(shorten(active.title,24))}</strong><small>${active.status==="PAUSED"?"Pausada":"En curso"} · ${clock(elapsed)}</small></span></button>`;
}

function shorten(value,max){const s=String(value||"Actividad");return s.length>max?`${s.slice(0,max-1)}…`:s}
function clock(seconds){const n=Math.max(0,Math.floor(Number(seconds||0))),h=Math.floor(n/3600),m=Math.floor((n%3600)/60),s=n%60;return [h,m,s].map(x=>String(x).padStart(2,"0")).join(":")}
