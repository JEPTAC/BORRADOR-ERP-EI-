import {api} from "../services/api.js";
import {fmt,statusBadge,priorityBadge} from "../core/format.js";
import {paginationHtml,empty,loading,toast,guide} from "../core/ui.js";
import {openOrder} from "./orders.js";
import {openCutPickup} from "./picking-flow.js";
import {openPurchaseArrival} from "./receiving-order.js";
import {renderSentOrdersPanel} from "./shipping-flow.js";
import {hasRole} from "../core/state.js";

export async function renderQueue(root,{moduleId,steps,params={}}){
  let selected=params.step&&steps.includes(params.step)?params.step:steps[0];
  let page=Number(params.page||1),assignment=params.assignment||"ALL";
  const showSentOrders=moduleId==="shipping"&&(hasRole("ventas")||hasRole("super_admin"));
  root.innerHTML=`
    <section class="page-head simple-page-head"><div><h2>${moduleTitle(moduleId)}</h2><p>Abre un pedido y marca su situación. El ERP te pedirá únicamente lo indispensable para avanzar.</p></div><div class="page-actions"><button class="btn btn-ghost" id="queue-help">¿Cómo funciona?</button></div></section>
    ${steps.length>1?`<section class="simple-stage-selector"><span>Etapa:</span>${steps.map(step=>`<button type="button" data-step="${step}" class="${step===selected?"active":""}">${fmt.escape(fmt.step(step))}</button>`).join("")}</section>`:""}
    <section class="card card-pad simple-queue-panel">
      <div class="queue-filter-bar simple-filter-bar">
        <div class="queue-filter-main"><input class="control search-wide" id="queue-search" placeholder="Buscar pedido o cliente"><select class="control" id="queue-status"><option value="">Todos los estados</option><option value="QUEUED">Pendiente</option><option value="ASSIGNED">Asignado</option><option value="IN_PROGRESS">En gestión</option><option value="WAITING">En espera</option><option value="BLOCKED">Con novedad</option></select><button class="btn btn-primary" id="queue-filter">Buscar</button></div>
        <div class="queue-scope" aria-label="Alcance de la cola"><button class="btn ${assignment==="ALL"?"btn-primary":"btn-ghost"}" data-assignment="ALL">Toda la cola</button><button class="btn ${assignment==="UNASSIGNED"?"btn-primary":"btn-ghost"}" data-assignment="UNASSIGNED">Sin asignar</button><button class="btn ${assignment==="MINE"?"btn-primary":"btn-ghost"}" data-assignment="MINE">Mis pedidos</button></div>
      </div>
      <div class="simple-queue-message"><strong>Lista de trabajo</strong><span>Busca el pedido y usa la acción de la derecha. El popup te guiará paso a paso sin mostrar formularios innecesarios.</span></div>
      ${showSentOrders?`<section class="sent-orders-panel"><header><div><span>Seguimiento comercial</span><h3>Pedidos enviados</h3><p>Ventas y Superadministración pueden enviar un reporte de no entrega a Logística.</p></div></header><div id="sent-orders-result">${loading("Consultando pedidos enviados…")}</div></section>`:""}
      ${moduleId==="picking"?`<section class="cut-pickup-queue"><header><div><span>Entrega desde Corte</span><h3>Cortes por recoger</h3><p>Recoge primero las referencias terminadas y después continúa con la verificación normal del pedido.</p></div><span class="cut-pickup-queue-count" id="cut-pickup-count">0</span></header><div id="cut-pickup-result">${loading("Consultando cortes listos…")}</div></section>`:""}
      <div id="queue-result">${loading()}</div>
      ${moduleId==="picking"?`<section class="picking-partial-queue"><header><div><span>Continuidad del pedido</span><h3>Pedidos parciales pendientes</h3><p>El mismo pedido vuelve aquí cuando termina la primera salida y llega la mercancía faltante.</p></div></header><div id="picking-partial-result">${loading("Consultando parciales…")}</div></section>`:""}
    </section>`;

  async function load(newPage=1){
    page=newPage;
    const target=root.querySelector("#queue-result");
    target.innerHTML=loading("Consultando pedidos…");
    try{
      const search=root.querySelector("#queue-search").value.trim();
      const pickupPromise=moduleId==="picking"?loadCutPickups(search):Promise.resolve(new Set());
      const [data,pickupIds]=await Promise.all([
        api.listOrders({step:selected,status:root.querySelector("#queue-status").value||null,search,assignment,page,pageSize:50,includeHistory:false}),
        pickupPromise
      ]);
      const rows=moduleId==="picking"?data.items.filter(item=>!pickupIds.has(item.id)):data.items;
      const content=rows.length?workList(rows):empty("No hay pedidos en esta cola",assignment==="MINE"?"No tienes pedidos asignados. Consulta Toda la cola para tomar uno.":"No existen pedidos activos con estos filtros.");
      const countLabel=moduleId==="picking"&&pickupIds.size?`${rows.length} pedido(s) para alistar`:`${fmt.number(data.pagination?.totalItems||0)} pedido(s)`;
      target.innerHTML=`<div class="queue-result-head"><div><strong>${countLabel}</strong><span>${fmt.step(selected)} · ${scopeLabel(assignment)}</span></div></div>${content}${rows.length?paginationHtml(data.pagination):""}`;
      target.querySelectorAll("[data-order]").forEach(element=>element.onclick=()=>{const row=rows.find(item=>item.id===element.dataset.order);if(row?.purchaseShadow)openPurchaseArrival(row,{refreshLists:()=>load(page)});else openOrder(element.dataset.order)});
      target.querySelectorAll("[data-page]").forEach(element=>element.onclick=()=>load(Number(element.dataset.page)));
      if(moduleId==="picking")await loadPendingPartials();
      if(showSentOrders){const sent=root.querySelector("#sent-orders-result");if(sent)await renderSentOrdersPanel(sent,{search,page:1,onOpen:openOrder});}
    }catch(error){
      target.innerHTML=`<div class="module-error"><strong>No fue posible consultar esta cola</strong><p>${fmt.escape(error.message)}</p><button class="btn btn-primary" id="retry-queue">Reintentar</button></div>`;
      target.querySelector("#retry-queue")?.addEventListener("click",()=>load(page));
      toast(error.message,"error",8000);
    }
  }


  async function loadCutPickups(search){
    const target=root.querySelector("#cut-pickup-result");
    const counter=root.querySelector("#cut-pickup-count");
    if(!target)return new Set();
    target.innerHTML=loading("Consultando cortes listos…");
    try{
      const data=await api.cutPickupsPending(search,1,50);
      const rows=data.items||[];
      if(counter)counter.textContent=String(data.pagination?.totalItems||rows.length);
      target.innerHTML=rows.length?`<div class="erp-work-list compact">${rows.map(cutPickupQueueRow).join("")}</div>`:empty("No hay cortes por recoger","Cuando Corte termine una referencia, el pedido aparecerá aquí antes de la verificación normal.");
      target.querySelectorAll("[data-order]").forEach(element=>element.onclick=()=>element.dataset.cutStage==="CORTE"?openCutPickup(element.dataset.order,{refreshLists:()=>load(page)}):openOrder(element.dataset.order));
      return new Set(rows.map(row=>row.id));
    }catch(error){
      if(counter)counter.textContent="!";
      target.innerHTML=`<div class="module-error compact"><strong>No fue posible consultar cortes por recoger</strong><p>${fmt.escape(error.message)}</p></div>`;
      return new Set();
    }
  }

  async function loadPendingPartials(){
    const target=root.querySelector("#picking-partial-result");
    if(!target)return;
    target.innerHTML=loading("Consultando pedidos parciales…");
    try{
      const data=await api.pickingPending(root.querySelector("#queue-search").value.trim(),1,50);
      const rows=data.items||[];
      target.innerHTML=rows.length?`<div class="erp-work-list compact">${rows.map(partialQueueRow).join("")}</div><div class="picking-partial-help"><strong>${rows.filter(row=>row.canResume).length} disponible(s) para retomar</strong><span>Los demás siguen en facturación o despacho de la salida anterior.</span></div>`:empty("No hay parciales pendientes","Cuando una salida quede incompleta, el mismo pedido aparecerá aquí sin duplicarse.");
      target.querySelectorAll("[data-order]").forEach(element=>element.onclick=()=>openOrder(element.dataset.order));
    }catch(error){
      target.innerHTML=`<div class="module-error"><strong>No fue posible consultar los pedidos parciales</strong><p>${fmt.escape(error.message)}</p></div>`;
    }
  }

  root.querySelectorAll("[data-step]").forEach(button=>button.onclick=()=>{
    selected=button.dataset.step;
    root.querySelectorAll("[data-step]").forEach(item=>item.classList.toggle("active",item===button));
    load(1);
  });
  root.querySelectorAll("[data-assignment]").forEach(button=>button.onclick=()=>{
    assignment=button.dataset.assignment;
    root.querySelectorAll("[data-assignment]").forEach(item=>item.className=`btn ${item===button?"btn-primary":"btn-ghost"}`);
    load(1);
  });
  root.querySelector("#queue-filter").onclick=()=>load(1);
  root.querySelector("#queue-search").onkeydown=event=>{if(event.key==="Enter")load(1)};
  window.__erpQueueRefresh=()=>load(page);
  root.querySelector("#queue-help").onclick=()=>guide({title:"Gestión sencilla de pedidos",description:"Cada pedido se trabaja desde una sola ventana.",items:[{title:"Busca el pedido",detail:"La lista muestra estado, responsable y tiempo sin ocupar espacio innecesario."},{title:"Usa la acción de la derecha",detail:"Iniciar, Continuar o Abrir te lleva al popup correspondiente."},{title:"Marca la situación",detail:"Puedes dejarlo pendiente, iniciar la gestión, ponerlo en espera o finalizarlo."},{title:"Completa solo lo necesario",detail:"Cuando una etapa exige factura, validación, corte o recepción, el ERP mostrará únicamente ese formulario."},{title:"Vuelve cuando quieras",detail:"Si dejas el pedido en gestión o espera, aparecerá en la misma cola para continuar después."}]});
  await load(page);
}

function cutPickupQueueRow(order){
  return `<article class="erp-work-row cut-pickup-row"><div class="erp-work-main"><span class="erp-work-eyebrow">${order.pickupWhileCutting?"RECOGIDA ANTICIPADA":"CORTES LISTOS"}</span><strong>${fmt.escape(order.orderNumber)}</strong><small>${fmt.escape(order.clientName)}</small></div><div class="erp-work-meta"><span><small>Referencias</small><b>${fmt.number(order.cutPickupPendingCount)}</b></span><span><small>Longitud</small><b>${fmt.number(order.cutPickupTotalLength,3)} m</b></span><span><small>Responsable</small><b>${fmt.escape(order.assigneeName||"Sin asignar")}</b></span></div><div class="erp-work-status">${priorityBadge(order.priority)}<small>${order.pickupWhileCutting?`${fmt.number(order.cutsStillPending)} corte(s) aún en proceso`:fmt.escape(fmt.route(order.route))}</small></div><button type="button" class="btn btn-primary erp-work-action" data-order="${fmt.escape(order.id)}" data-cut-stage="${fmt.escape(order.currentStep||"ALISTAMIENTO")}">Recoger</button></article>`;
}

function partialQueueRow(order){
  const action=order.canResume?"Retomar":"Abrir";
  return `<article class="erp-work-row"><div class="erp-work-main"><span class="erp-work-eyebrow">PEDIDO PARCIAL</span><strong>${fmt.escape(order.orderNumber)}</strong><small>${fmt.escape(order.clientName)}</small></div><div class="erp-work-meta"><span><small>Pendientes</small><b>${fmt.number(order.pendingItemCount||0)}</b></span><span><small>Etapa</small><b>${fmt.escape(fmt.step(order.currentStep||"ALISTAMIENTO"))}</b></span><span><small>Tiempo</small><b>${fmt.hours(order.ageBusinessSeconds||0)}</b></span></div><div class="erp-work-status">${statusBadge(order.status)}${priorityBadge(order.priority)}</div><button type="button" class="btn ${order.canResume?"btn-primary":"btn-ghost"} erp-work-action" data-order="${fmt.escape(order.id)}">${action}</button></article>`;
}

function workList(rows){
  return `<div class="erp-work-list">${rows.map(order=>{const actionLabel=order.purchaseShadow?(order.arrivalStatus==="ARRIVED"?"Revisar":"Registrar llegada"):String(order.status||"").toUpperCase()==="IN_PROGRESS"?"Continuar":String(order.status||"").toUpperCase()==="ASSIGNED"?"Iniciar":"Abrir";return `<article class="erp-work-row ${order.purchaseShadow?"purchase-shadow-row":""}"><div class="erp-work-main"><span class="erp-work-eyebrow">${fmt.escape(fmt.step(order.stepName||order.currentStep))}</span><strong>${fmt.escape(order.orderNumber)}</strong><small>${fmt.escape(order.clientName)} · ${fmt.escape(fmt.payment(order.paymentCondition))}</small>${order.exceptionLabel?`<em class="order-exception-tag">${fmt.escape(order.exceptionLabel)}</em>`:""}${order.fulfillmentStatus==="PARTIAL"||order.partialLabel?'<em class="order-partial-tag">Pedido parcial</em>':""}${order.purchaseShadow?`<em class="purchase-shadow-tag">PVE · ${order.arrivalStatus==="ARRIVED"?"Mercancía OK":order.arrivalStatus==="WAITING"?"En espera":"Seguimiento"}</em>`:""}</div><div class="erp-work-meta"><span><small>Estado</small><b>${statusBadge(order.status)}</b></span><span><small>Responsable</small><b>${fmt.escape(order.assigneeName||"Sin asignar")}</b></span><span><small>Tiempo</small><b>${fmt.hours(order.ageBusinessSeconds)}</b></span><span><small>Entrega</small><b>${fmt.escape(fmt.route(order.route))}</b></span></div><div class="erp-work-status">${priorityBadge(order.priority)}</div><button type="button" class="btn btn-primary erp-work-action" data-order="${fmt.escape(order.id)}" data-purchase-shadow="${order.purchaseShadow?"1":"0"}">${actionLabel}</button></article>`}).join("")}</div>`;
}

function moduleTitle(moduleId){return({cartera:"Cartera",caja:"Caja",purchasing:"Compras",receiving:"Recepción",picking:"Alistamiento",cutting:"Corte",billing:"Facturación",shipping:"Despachos y entregas"})[moduleId]||"Cola de trabajo"}
function scopeLabel(value){return value==="MINE"?"Mis pedidos":value==="UNASSIGNED"?"Sin asignar":"Toda la cola"}
