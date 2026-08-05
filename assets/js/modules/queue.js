import {api} from "../services/api.js";
import {fmt,statusBadge,priorityBadge} from "../core/format.js";
import {paginationHtml,empty,loading,actionCards,guide,toast} from "../core/ui.js";
import {workspaceIntro,orderVisualCards,viewSwitch} from "../core/guided.js";
import {openOrder} from "./orders.js";

export async function renderQueue(root,{moduleId,steps,params={}}){
  let selected=params.step&&steps.includes(params.step)?params.step:steps[0];
  let page=Number(params.page||1),assignment=params.assignment||"ALL",view="cards";
  const stepCards=steps.map((step,index)=>({title:fmt.step(step),description:stepDescription(step),icon:String(index+1),tone:step===selected?"accent":"",data:{step}}));
  root.innerHTML=`
    <section class="page-head"><div><h2>${moduleTitle(moduleId)}</h2><p>Selecciona una etapa y después el pedido. La cola completa aparece primero para evitar que un pedido sin responsable quede oculto.</p></div><div class="page-actions"><button class="btn btn-ghost" id="queue-help">¿Cómo trabajo aquí?</button></div></section>
    ${workspaceIntro({title:"Elige la etapa de trabajo",description:"Cada tarjeta representa una cola real del proceso. Los pedidos sin asignar permanecen visibles hasta que un responsable los tome.",cards:actionCards(stepCards)})}
    <section class="card card-pad">
      <div class="queue-filter-bar">
        <div class="queue-filter-main"><input class="control search-wide" id="queue-search" placeholder="Buscar pedido, cliente o referencia"><select class="control" id="queue-status"><option value="">Todos los estados activos</option><option value="QUEUED">En cola</option><option value="ASSIGNED">Asignado</option><option value="IN_PROGRESS">En proceso</option><option value="WAITING">En espera</option><option value="BLOCKED">Bloqueado</option></select><button class="btn btn-primary" id="queue-filter">Buscar</button></div>
        <div class="queue-scope" aria-label="Alcance de la cola"><button class="btn ${assignment==="ALL"?"btn-primary":"btn-ghost"}" data-assignment="ALL">Toda la cola</button><button class="btn ${assignment==="UNASSIGNED"?"btn-primary":"btn-ghost"}" data-assignment="UNASSIGNED">Sin asignar</button><button class="btn ${assignment==="MINE"?"btn-primary":"btn-ghost"}" data-assignment="MINE">Mis tareas</button></div>
        ${viewSwitch(view)}
      </div>
      <div class="selection-hint"><strong>Selecciona un pedido</strong><span>La tarjeta completa es interactiva y muestra etapa, responsable, prioridad y tiempo antes de abrir el expediente.</span></div>
      <div id="queue-result">${loading()}</div>
    </section>`;

  async function load(newPage=1){
    page=newPage;
    const target=root.querySelector("#queue-result");
    target.innerHTML=loading("Consultando la cola de trabajo…");
    try{
      const data=await api.listOrders({step:selected,status:root.querySelector("#queue-status").value||null,search:root.querySelector("#queue-search").value.trim(),assignment,page,pageSize:50,includeHistory:false});
      const content=data.items.length?(view==="cards"?orderVisualCards(data.items,{queue:true}):table(data.items)):empty("Cola sin pedidos",assignment==="MINE"?"No tienes pedidos asignados. Consulta Toda la cola o Sin asignar.":assignment==="UNASSIGNED"?"No hay pedidos pendientes de asignación en esta etapa.":"No hay pedidos activos para esta etapa y los filtros seleccionados.");
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
    root.querySelectorAll("[data-step]").forEach(card=>card.classList.toggle("selected",card===button));
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
  root.querySelector("#queue-help").onclick=()=>guide({title:"Cómo gestionar una cola",description:"La cola completa es la vista inicial para que ningún pedido se pierda por falta de asignación.",items:[{title:"Toda la cola",detail:"Muestra todos los pedidos activos de la etapa, asignados o no."},{title:"Sin asignar",detail:"Permite encontrar pedidos que todavía deben ser tomados o asignados."},{title:"Mis tareas",detail:"Muestra únicamente los pedidos asignados directamente a tu usuario."},{title:"Abre la tarjeta completa",detail:"El expediente mostrará las acciones disponibles y el asistente correspondiente."}]});
  await load(page);
}

function moduleTitle(moduleId){return({cartera:"Cola de Cartera",caja:"Cola de Caja",purchasing:"Cola de Compras",receiving:"Recepción de pedidos y mercancía",picking:"Cola de Alistamiento",cutting:"Cola de Corte",billing:"Cola de Facturación",shipping:"Despachos, entregas y cierre"})[moduleId]||"Cola de trabajo"}
function stepDescription(step){return({CARTERA:"Pedidos pendientes de validación de crédito, mora y cupo.",CAJA:"Pedidos pendientes de pago o soporte financiero.",COMPRAS:"Pedidos que requieren abastecimiento u orden de compra.",RECEPCION_MERCANCIA:"Mercancía pendiente de ingreso físico, calidad, lote y ubicación.",RECEPCION_PEDIDO:"Pedidos pendientes de recepción documental y asignación.",ALISTAMIENTO:"Pedidos listos para preparación y verificación de materiales.",CORTE:"Materiales pendientes de medida, corte, consumo y desperdicio.",FACTURACION:"Pedidos pendientes de factura y validación comercial.",CLIENT_POINT:"Entregas programadas en punto.",CLIENT_PICKUP:"Pedidos que serán recogidos por el cliente.",LOCAL_DISPATCH:"Despachos de cobertura local.",NATIONAL_DISPATCH:"Despachos de cobertura nacional.",CLOSURE:"Pedidos entregados pendientes de cierre documental."})[step]||"Pedidos activos en esta etapa."}
function scopeLabel(value){return value==="MINE"?"Mis tareas":value==="UNASSIGNED"?"Sin asignar":"Toda la cola"}
function table(rows){return `<div class="table-wrap"><table><thead><tr><th>Prioridad</th><th>Pedido</th><th>Cliente</th><th>Estado</th><th>Responsable</th><th>Tiempo laboral</th><th>Plazo objetivo</th><th>Modalidad de entrega</th></tr></thead><tbody>${rows.map(order=>`<tr data-order="${fmt.escape(order.id)}" class="clickable-row"><td>${priorityBadge(order.priority)}</td><td><span class="table-link">${fmt.escape(order.orderNumber)}</span><div class="cell-sub">${fmt.escape(fmt.label(order.orderType))}</div></td><td><div class="cell-main">${fmt.escape(order.clientName)}</div><div class="cell-sub">${fmt.escape(fmt.payment(order.paymentCondition))}</div></td><td>${statusBadge(order.status)}</td><td>${fmt.escape(order.assigneeName||"En cola")}<div class="cell-sub">${fmt.escape(fmt.role(order.roleCode||""))}</div></td><td>${fmt.hours(order.ageBusinessSeconds)}</td><td>${order.slaExceeded?'<span class="badge badge-red"><span class="badge-dot"></span>Fuera de plazo</span>':'<span class="badge badge-green"><span class="badge-dot"></span>Dentro del plazo</span>'}</td><td>${fmt.escape(fmt.route(order.route))}</td></tr>`).join("")}</tbody></table></div>`}
