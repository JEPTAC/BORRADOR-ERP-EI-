import {api} from "../services/api.js";
import {fmt} from "../core/format.js";

const ACTIVE_STATUSES=new Set(["QUEUED","ASSIGNED","IN_PROGRESS","WAITING","BLOCKED"]);
const PRIORITY_WEIGHT={CRITICAL:1,URGENT:2,HIGH:3,MEDIUM:4,LOW:5};
const STEP_MODULE={
  CARTERA:"cartera",CAJA:"caja",CAJA_FACTURACION:"caja",COMPRAS:"purchasing",
  RECEPCION_MERCANCIA:"receiving",RECEPCION_PEDIDO:"receiving",ALISTAMIENTO:"picking",
  CORTE:"cutting",FACTURACION:"billing",CLIENT_POINT:"shipping",CLIENT_PICKUP:"shipping",
  LOCAL_DISPATCH:"shipping",NATIONAL_DISPATCH:"shipping",CLOSURE:"shipping"
};

let boundSlot=null;
let globalEventsBound=false;
let expanded=false;
let loading=false;
let refreshTimer=null;
let activeOrders=[];

export function moduleForStep(step){return STEP_MODULE[String(step||"").toUpperCase()]||"orders"}

export function parallelWorkFooter(step){
  return `<footer class="modal-foot parallel-work-footer">
    <div class="parallel-work-note"><span aria-hidden="true">⇄</span><div><strong>Trabajo en paralelo habilitado</strong><small>Los pedidos tomados permanecen asignados. Puedes cerrar esta ventana y atender otro sin perder el avance.</small></div></div>
    <div class="parallel-work-actions"><button class="btn btn-ghost" data-close>Cerrar</button><button class="btn btn-primary" data-take-another="${fmt.escape(String(step||""))}">Cerrar y tomar otro</button></div>
  </footer>`;
}

export function initActiveWork(){
  const slot=document.querySelector("#active-work-slot");
  if(!slot||boundSlot===slot)return;
  boundSlot=slot;

  slot.addEventListener("click",event=>{
    const toggle=event.target.closest("[data-active-work-toggle]");
    if(toggle){
      expanded=!expanded;
      render(slot);
      if(expanded)refreshActiveWork();
      return;
    }
    const order=event.target.closest("[data-active-work-order]");
    if(order){
      expanded=false;
      render(slot);
      window.dispatchEvent(new CustomEvent("erp:open-order",{detail:order.dataset.activeWorkOrder}));
      return;
    }
    if(event.target.closest("[data-active-work-refresh]"))refreshActiveWork(true);
  });

  if(!globalEventsBound){
    globalEventsBound=true;
    document.addEventListener("click",event=>{
      const current=document.querySelector("#active-work-slot");
      if(!expanded||current?.contains(event.target))return;
      expanded=false;
      if(current)render(current);
    });
    window.addEventListener("erp:work-changed",scheduleRefresh);
    window.addEventListener("erp:refresh",()=>refreshActiveWork(true));
  }
  render(slot);
  refreshActiveWork();
}

function scheduleRefresh(){
  clearTimeout(refreshTimer);
  refreshTimer=setTimeout(()=>refreshActiveWork(),180);
}

export async function refreshActiveWork(force=false){
  const slot=document.querySelector("#active-work-slot");
  if(!slot||loading)return;
  loading=true;
  render(slot);
  try{
    const data=await api.listOrders({assignment:"MINE",page:1,pageSize:100,includeHistory:false});
    activeOrders=(data.items||[])
      .filter(order=>ACTIVE_STATUSES.has(String(order.status||"").toUpperCase()))
      .sort((a,b)=>(PRIORITY_WEIGHT[a.priority]||9)-(PRIORITY_WEIGHT[b.priority]||9)||new Date(b.updatedAt||0)-new Date(a.updatedAt||0));
  }catch(error){
    if(force)console.error("[ERP ACTIVE WORK]",error);
  }finally{
    loading=false;
    render(slot);
  }
}

function render(slot){
  const count=activeOrders.length;
  const visible=activeOrders.slice(0,10);
  slot.innerHTML=`<div class="active-work">
    <button type="button" class="active-work-trigger ${count?"has-items":""}" data-active-work-toggle aria-expanded="${expanded}">
      <span class="active-work-trigger-icon" aria-hidden="true">⇄</span>
      <span class="active-work-trigger-copy"><strong>Mis pedidos activos</strong><small>${loading?"Actualizando…":count?`${count} en gestión simultánea`:`Sin pedidos tomados`}</small></span>
      <b>${count}</b>
    </button>
    ${expanded?`<section class="active-work-popover" aria-label="Mis pedidos activos">
      <header><div><strong>Trabajo simultáneo</strong><small>Puedes cambiar de pedido sin liberar los anteriores.</small></div><button type="button" class="icon-btn" data-active-work-refresh title="Actualizar" aria-label="Actualizar pedidos activos">↻</button></header>
      <div class="active-work-list">
        ${loading&&!count?`<div class="active-work-loading">Consultando tus pedidos…</div>`:visible.length?visible.map(activeOrderRow).join(""):`<div class="active-work-empty"><strong>No tienes pedidos activos</strong><span>Toma un pedido desde cualquier cola y aparecerá aquí.</span></div>`}
      </div>
      ${count>visible.length?`<footer>Mostrando ${visible.length} de ${count}. Consulta “Mis pedidos” para verlos todos.</footer>`:""}
    </section>`:""}
  </div>`;
}

function activeOrderRow(order){
  const status=String(order.status||"").toUpperCase();
  const statusText={QUEUED:"Pendiente",ASSIGNED:"Asignado",IN_PROGRESS:"En gestión",WAITING:"En espera",BLOCKED:"Con novedad"}[status]||fmt.label(status);
  return `<button type="button" class="active-work-order priority-${String(order.priority||"MEDIUM").toLowerCase()}" data-active-work-order="${fmt.escape(order.id)}">
    <span class="active-work-order-main"><strong>${fmt.escape(order.orderNumber)}</strong><small>${fmt.escape(order.clientName)} · ${fmt.escape(fmt.step(order.currentStep))}</small></span>
    <span class="active-work-order-meta"><b class="status-${status.toLowerCase()}">${fmt.escape(statusText)}</b><small>${fmt.hours(order.ageBusinessSeconds)}</small></span>
  </button>`;
}
