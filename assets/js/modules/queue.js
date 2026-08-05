import {api} from "../services/api.js";
import {fmt,statusBadge,priorityBadge} from "../core/format.js";
import {paginationHtml,empty,loading,toast,guide} from "../core/ui.js";
import {orderVisualCards,viewSwitch} from "../core/guided.js";
import {openOrder} from "./orders.js";

export async function renderQueue(root,{moduleId,steps,params={}}){
  let selected=params.step&&steps.includes(params.step)?params.step:steps[0];
  let page=Number(params.page||1),assignment=params.assignment||"ALL",view="cards";
  root.innerHTML=`
    <section class="page-head simple-page-head"><div><h2>${moduleTitle(moduleId)}</h2><p>Abre un pedido y marca su situación. El ERP te pedirá únicamente lo indispensable para avanzar.</p></div><div class="page-actions"><button class="btn btn-ghost" id="queue-help">¿Cómo funciona?</button></div></section>
    ${steps.length>1?`<section class="simple-stage-selector"><span>Etapa:</span>${steps.map(step=>`<button type="button" data-step="${step}" class="${step===selected?"active":""}">${fmt.escape(fmt.step(step))}</button>`).join("")}</section>`:""}
    <section class="card card-pad simple-queue-panel">
      <div class="queue-filter-bar simple-filter-bar">
        <div class="queue-filter-main"><input class="control search-wide" id="queue-search" placeholder="Buscar pedido o cliente"><select class="control" id="queue-status"><option value="">Todos los estados</option><option value="QUEUED">Pendiente</option><option value="ASSIGNED">Asignado</option><option value="IN_PROGRESS">En gestión</option><option value="WAITING">En espera</option><option value="BLOCKED">Con novedad</option></select><button class="btn btn-primary" id="queue-filter">Buscar</button></div>
        <div class="queue-scope" aria-label="Alcance de la cola"><button class="btn ${assignment==="ALL"?"btn-primary":"btn-ghost"}" data-assignment="ALL">Toda la cola</button><button class="btn ${assignment==="UNASSIGNED"?"btn-primary":"btn-ghost"}" data-assignment="UNASSIGNED">Sin asignar</button><button class="btn ${assignment==="MINE"?"btn-primary":"btn-ghost"}" data-assignment="MINE">Mis pedidos</button></div>
        ${viewSwitch(view)}
      </div>
      <div class="simple-queue-message"><strong>Solo debes elegir un pedido</strong><span>Al abrirlo verás el estado actual, lo que falta y el siguiente paso recomendado.</span></div>
      <div id="queue-result">${loading()}</div>
    </section>`;

  async function load(newPage=1){
    page=newPage;
    const target=root.querySelector("#queue-result");
    target.innerHTML=loading("Consultando pedidos…");
    try{
      const data=await api.listOrders({step:selected,status:root.querySelector("#queue-status").value||null,search:root.querySelector("#queue-search").value.trim(),assignment,page,pageSize:50,includeHistory:false});
      const content=data.items.length?(view==="cards"?orderVisualCards(data.items,{queue:true}):table(data.items)):empty("No hay pedidos en esta cola",assignment==="MINE"?"No tienes pedidos asignados. Consulta Toda la cola para tomar uno.":"No existen pedidos activos con estos filtros.");
      target.innerHTML=`<div class="queue-result-head"><div><strong>${fmt.number(data.pagination?.totalItems||0)} pedido(s)</strong><span>${fmt.step(selected)} · ${scopeLabel(assignment)}</span></div></div>${content}${data.items.length?paginationHtml(data.pagination):""}`;
      target.querySelectorAll("[data-order]").forEach(element=>element.onclick=()=>openOrder(element.dataset.order));
      target.querySelectorAll("[data-page]").forEach(element=>element.onclick=()=>load(Number(element.dataset.page)));
    }catch(error){
      target.innerHTML=`<div class="module-error"><strong>No fue posible consultar esta cola</strong><p>${fmt.escape(error.message)}</p><button class="btn btn-primary" id="retry-queue">Reintentar</button></div>`;
      target.querySelector("#retry-queue")?.addEventListener("click",()=>load(page));
      toast(error.message,"error",8000);
    }
  }

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

function moduleTitle(moduleId){return({cartera:"Cartera",caja:"Caja",purchasing:"Compras",receiving:"Recepción",picking:"Alistamiento",cutting:"Corte",billing:"Facturación",shipping:"Despachos y entregas"})[moduleId]||"Cola de trabajo"}
function scopeLabel(value){return value==="MINE"?"Mis pedidos":value==="UNASSIGNED"?"Sin asignar":"Toda la cola"}
function table(rows){return `<div class="table-wrap"><table><thead><tr><th>Pedido</th><th>Cliente</th><th>Etapa</th><th>Situación</th><th>Responsable</th><th>Tiempo</th><th>Entrega</th></tr></thead><tbody>${rows.map(order=>`<tr data-order="${fmt.escape(order.id)}" class="clickable-row"><td><span class="table-link">${fmt.escape(order.orderNumber)}</span><div class="cell-sub">${priorityBadge(order.priority)}</div></td><td><div class="cell-main">${fmt.escape(order.clientName)}</div><div class="cell-sub">${fmt.escape(fmt.payment(order.paymentCondition))}</div></td><td>${fmt.escape(fmt.step(order.stepName||order.currentStep))}</td><td>${statusBadge(order.status)}</td><td>${fmt.escape(order.assigneeName||"Sin asignar")}</td><td>${fmt.hours(order.ageBusinessSeconds)}</td><td>${fmt.escape(fmt.route(order.route))}</td></tr>`).join("")}</tbody></table></div>`}
