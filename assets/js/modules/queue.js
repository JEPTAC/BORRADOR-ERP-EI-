import {api} from "../services/api.js";
import {fmt,statusBadge,priorityBadge} from "../core/format.js";
import {paginationHtml,empty,loading,toast,guide} from "../core/ui.js";
import {orderVisualCards,viewSwitch} from "../core/guided.js";
import {openOrder} from "./orders.js";
import {openCutPickup} from "./picking-flow.js";
import {openPurchaseArrival} from "./receiving-order.js";
import {renderSentOrdersPanel} from "./shipping-flow.js";
import {hasRole} from "../core/state.js";

export async function renderQueue(root,{moduleId,steps,params={}}){
  const sandbox=params.sandbox==="1"&&hasRole("super_admin");
  let selected=params.step&&steps.includes(params.step)?params.step:steps[0];
  let page=Number(params.page||1),assignment=sandbox?"ALL":params.assignment||"ALL",view="cards";
  const showSentOrders=!sandbox&&moduleId==="shipping"&&(hasRole("ventas")||hasRole("super_admin"));
  root.innerHTML=`
    ${sandbox?`<section class="sandbox-queue-banner"><strong>MODO SANDBOX · SUPER ADMIN</strong><span>Esta cola muestra exclusivamente pedidos TEST. Ningún dato productivo se modifica.</span><button class="btn btn-ghost btn-compact" id="sandbox-back">Volver al Bot</button></section>`:""}
    <section class="page-head simple-page-head"><div><h2>${moduleTitle(moduleId)}${sandbox?" · Sandbox":""}</h2><p>${sandbox?"Prueba el módulo real con pedidos ficticios completamente aislados.":"Abre un pedido y marca su situación. El ERP te pedirá únicamente lo indispensable para avanzar."}</p></div><div class="page-actions"><button class="btn btn-ghost" id="queue-help">¿Cómo funciona?</button></div></section>
    ${steps.length>1?`<section class="simple-stage-selector"><span>Etapa:</span>${steps.map(step=>`<button type="button" data-step="${step}" class="${step===selected?"active":""}">${fmt.escape(fmt.step(step))}</button>`).join("")}</section>`:""}
    <section class="card card-pad simple-queue-panel">
      <div class="queue-filter-bar simple-filter-bar">
        <div class="queue-filter-main"><input class="control search-wide" id="queue-search" placeholder="Buscar pedido o cliente"><select class="control" id="queue-status"><option value="">Todos los estados</option><option value="QUEUED">Pendiente</option><option value="ASSIGNED">Asignado</option><option value="IN_PROGRESS">En gestión</option><option value="WAITING">En espera</option><option value="BLOCKED">Con novedad</option></select><button class="btn btn-primary" id="queue-filter">Buscar</button></div>
        ${sandbox?"":`<div class="queue-scope" aria-label="Alcance de la cola"><button class="btn ${assignment==="ALL"?"btn-primary":"btn-ghost"}" data-assignment="ALL">Toda la cola</button><button class="btn ${assignment==="UNASSIGNED"?"btn-primary":"btn-ghost"}" data-assignment="UNASSIGNED">Sin asignar</button><button class="btn ${assignment==="MINE"?"btn-primary":"btn-ghost"}" data-assignment="MINE">Mis pedidos</button></div>`}
        ${viewSwitch(view)}
      </div>
      <div class="simple-queue-message"><strong>Solo debes elegir un pedido</strong><span>Al abrirlo verás el estado actual, lo que falta y el siguiente paso recomendado.</span></div>
      ${showSentOrders?`<section class="sent-orders-panel"><header><div><span>Seguimiento comercial</span><h3>Pedidos enviados</h3><p>Ventas y Superadministración pueden enviar un reporte de no entrega a Logística.</p></div></header><div id="sent-orders-result">${loading("Consultando pedidos enviados…")}</div></section>`:""}
      ${moduleId==="picking"&&!sandbox?`<section class="cut-pickup-queue"><header><div><span>Entrega desde Corte</span><h3>Cortes por recoger</h3><p>Recoge primero las referencias terminadas y después continúa con la verificación normal del pedido.</p></div><span class="cut-pickup-queue-count" id="cut-pickup-count">0</span></header><div id="cut-pickup-result">${loading("Consultando cortes listos…")}</div></section>`:""}
      <div id="queue-result">${loading()}</div>
      ${moduleId==="picking"&&!sandbox?`<section class="picking-partial-queue"><header><div><span>Continuidad del pedido</span><h3>Pedidos parciales pendientes</h3><p>El mismo pedido vuelve aquí cuando termina la primera salida y llega la mercancía faltante.</p></div></header><div id="picking-partial-result">${loading("Consultando parciales…")}</div></section>`:""}
    </section>`;

  async function load(newPage=1){
    page=newPage;
    const target=root.querySelector("#queue-result");
    target.innerHTML=loading("Consultando pedidos…");
    try{
      const search=root.querySelector("#queue-search").value.trim();
      const pickupPromise=moduleId==="picking"&&!sandbox?loadCutPickups(search):Promise.resolve(new Set());
      const [data,pickupIds]=await Promise.all([
        (sandbox?api.sandboxOrders({step:selected,status:root.querySelector("#queue-status").value||null,search,page,pageSize:50}):api.listOrders({step:selected,status:root.querySelector("#queue-status").value||null,search,assignment,page,pageSize:50,includeHistory:false})),
        pickupPromise
      ]);
      const rows=moduleId==="picking"&&!sandbox?data.items.filter(item=>!pickupIds.has(item.id)):data.items;
      const content=rows.length?(view==="cards"?orderVisualCards(rows,{queue:true}):table(rows)):empty("No hay pedidos en esta cola",assignment==="MINE"?"No tienes pedidos asignados. Consulta Toda la cola para tomar uno.":"No existen pedidos activos con estos filtros.");
      const countLabel=moduleId==="picking"&&pickupIds.size?`${rows.length} pedido(s) para alistar`:`${fmt.number(data.pagination?.totalItems||0)} pedido(s)`;
      target.innerHTML=`<div class="queue-result-head"><div><strong>${countLabel}</strong><span>${fmt.step(selected)} · ${scopeLabel(assignment)}</span></div></div>${content}${rows.length?paginationHtml(data.pagination):""}`;
      target.querySelectorAll("[data-order]").forEach(element=>element.onclick=()=>{const row=rows.find(item=>item.id===element.dataset.order);if(row?.purchaseShadow)openPurchaseArrival(row,{refreshLists:()=>load(page)});else openOrder(element.dataset.order)});
      target.querySelectorAll("[data-page]").forEach(element=>element.onclick=()=>load(Number(element.dataset.page)));
      if(moduleId==="picking"&&!sandbox)await loadPendingPartials();
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
      target.innerHTML=rows.length?`<div class="cut-pickup-queue-grid">${rows.map(cutPickupQueueCard).join("")}</div>`:empty("No hay cortes por recoger","Cuando Corte termine una referencia, el pedido aparecerá aquí antes de la verificación normal.");
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
      target.innerHTML=rows.length?`${orderVisualCards(rows,{queue:true})}<div class="picking-partial-help"><strong>${rows.filter(row=>row.canResume).length} disponible(s) para retomar</strong><span>Los demás siguen en facturación o despacho de la salida anterior.</span></div>`:empty("No hay parciales pendientes","Cuando una salida quede incompleta, el mismo pedido aparecerá aquí sin duplicarse.");
      target.querySelectorAll("[data-order]").forEach(element=>element.onclick=()=>openOrder(element.dataset.order));
    }catch(error){
      target.innerHTML=`<div class="module-error"><strong>No fue posible consultar los pedidos parciales</strong><p>${fmt.escape(error.message)}</p></div>`;
    }
  }

  root.querySelector("#sandbox-back")?.addEventListener("click",()=>location.hash="#/sandbox");
  root.querySelectorAll("[data-step]").forEach(button=>button.onclick=()=>{
    selected=button.dataset.step;
    root.querySelectorAll("[data-step]").forEach(item=>item.classList.toggle("active",item===button));
    load(1);
  });
  root.querySelectorAll("[data-view]").forEach(button=>button.onclick=()=>{
    view=button.dataset.view;
    root.querySelectorAll("[data-view]").forEach(item=>item.classList.toggle("active",item===button));
    load(page);
  });
  root.querySelectorAll("[data-assignment]").forEach(button=>button.onclick=()=>{
    assignment=button.dataset.assignment;
    root.querySelectorAll("[data-assignment]").forEach(item=>item.className=`btn ${item===button?"btn-primary":"btn-ghost"}`);
    load(1);
  });
  root.querySelector("#queue-filter").onclick=()=>load(1);
  root.querySelector("#queue-search").onkeydown=event=>{if(event.key==="Enter")load(1)};
  window.__erpQueueRefresh=()=>load(page);
  root.querySelector("#queue-help").onclick=()=>guide({title:"Gestión sencilla de pedidos",description:"Cada pedido se trabaja desde una sola ventana.",items:[{title:"Abre la tarjeta",detail:"Verás el estado actual y el siguiente paso recomendado."},{title:"Marca la situación",detail:"Puedes dejarlo pendiente, iniciar la gestión, ponerlo en espera o finalizarlo."},{title:"Completa solo lo necesario",detail:"Cuando una etapa exige factura, validación, corte o recepción, el ERP mostrará únicamente ese formulario."},{title:"Vuelve cuando quieras",detail:"Si dejas el pedido en gestión o espera, aparecerá en la misma cola para continuar después."}]});
  await load(page);
}

function cutPickupQueueCard(order){
  return `<button type="button" class="cut-pickup-queue-card ${order.pickupWhileCutting?"early":""}" data-order="${fmt.escape(order.id)}" data-cut-stage="${fmt.escape(order.currentStep||"ALISTAMIENTO")}">
    <header><div><span>${order.pickupWhileCutting?"RECOGIDA ANTICIPADA":"CORTES LISTOS"}</span><strong>${fmt.escape(order.orderNumber)}</strong></div>${priorityBadge(order.priority)}</header>
    <h4>${fmt.escape(order.clientName)}</h4>
    <div class="cut-pickup-queue-metrics"><div><small>Referencias</small><strong>${fmt.number(order.cutPickupPendingCount)}</strong></div><div><small>Longitud</small><strong>${fmt.number(order.cutPickupTotalLength,3)} m</strong></div><div><small>Responsable</small><strong>${fmt.escape(order.assigneeName||"Sin asignar")}</strong></div></div>
    <footer><span>${order.pickupWhileCutting?`${fmt.number(order.cutsStillPending)} corte(s) aún en proceso`:fmt.escape(fmt.route(order.route))}</span><strong>Recoger ahora →</strong></footer>
  </button>`;
}

function moduleTitle(moduleId){return({cartera:"Cartera",caja:"Caja",purchasing:"Compras",receiving:"Recepción",picking:"Alistamiento",cutting:"Corte",billing:"Facturación",shipping:"Despachos y entregas"})[moduleId]||"Cola de trabajo"}
function scopeLabel(value){return value==="MINE"?"Mis pedidos":value==="UNASSIGNED"?"Sin asignar":"Toda la cola"}
function table(rows){return `<div class="table-wrap"><table><thead><tr><th>Pedido</th><th>Cliente</th><th>Etapa</th><th>Situación</th><th>Responsable</th><th>Tiempo</th><th>Entrega</th></tr></thead><tbody>${rows.map(order=>`<tr data-order="${fmt.escape(order.id)}" data-purchase-shadow="${order.purchaseShadow?"1":"0"}" class="clickable-row ${order.purchaseShadow?"purchase-shadow-row":""}"><td><span class="table-link">${fmt.escape(order.orderNumber)}</span>${order.purchaseShadow?`<div><span class="purchase-shadow-tag">PVE · ${order.arrivalStatus==="ARRIVED"?"Mercancía OK":order.arrivalStatus==="WAITING"?"En espera":"Seguimiento"}</span></div>`:""}${order.exceptionLabel?`<div><span class="order-exception-tag">${fmt.escape(order.exceptionLabel)}</span></div>`:""}${order.fulfillmentStatus==="PARTIAL"||order.partialLabel?`<div><span class="order-partial-tag">Pedido parcial</span></div>`:""}<div class="cell-sub">${priorityBadge(order.priority)}</div></td><td><div class="cell-main">${fmt.escape(order.clientName)}</div><div class="cell-sub">${fmt.escape(fmt.payment(order.paymentCondition))}</div></td><td>${fmt.escape(fmt.step(order.stepName||order.currentStep))}</td><td>${statusBadge(order.status)}</td><td>${fmt.escape(order.assigneeName||"Sin asignar")}</td><td>${fmt.hours(order.ageBusinessSeconds)}</td><td>${fmt.escape(fmt.route(order.route))}</td></tr>`).join("")}</tbody></table></div>`}
