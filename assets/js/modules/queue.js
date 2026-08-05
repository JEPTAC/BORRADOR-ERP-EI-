import {api} from "../services/api.js";
import {fmt,statusBadge,priorityBadge} from "../core/format.js";
import {paginationHtml,empty,loading,actionCards,guide} from "../core/ui.js";
import {workspaceIntro,orderVisualCards,viewSwitch} from "../core/guided.js";
import {openOrder} from "./orders.js";

export async function renderQueue(root,{moduleId,steps,params={}}){
  let selected=params.step&&steps.includes(params.step)?params.step:steps[0];
  let page=Number(params.page||1),assignment=params.assignment||"MINE",view="cards";
  const stepCards=steps.map((step,index)=>({title:fmt.step(step),description:index===0?"Abrir la cola principal de este módulo.":"Consultar los pedidos que están en esta etapa.",icon:String(index+1),tone:step===selected?"accent":"",data:{step}}));
  root.innerHTML=`
    <section class="page-head"><div><h2>Cola de trabajo</h2><p>Selecciona una etapa y luego el pedido que deseas gestionar. El expediente te mostrará únicamente las acciones permitidas.</p></div><div class="page-actions"><button class="btn btn-ghost" id="queue-help">¿Cómo trabajo aquí?</button></div></section>
    ${workspaceIntro({title:"Elige la etapa de trabajo",description:"Las opciones disponibles corresponden a este módulo y a los permisos de tu usuario.",cards:actionCards(stepCards)})}
    <section class="card card-pad"><div class="toolbar"><input class="control search-wide" id="queue-search" placeholder="Buscar por pedido, cliente o referencia"><select class="control" id="queue-status"><option value="">Todos los estados activos</option><option value="QUEUED">En cola</option><option value="ASSIGNED">Asignado</option><option value="IN_PROGRESS">En proceso</option><option value="WAITING">En espera</option><option value="BLOCKED">Bloqueado</option></select><button class="btn ${assignment==="MINE"?"btn-primary":"btn-ghost"}" id="mine">Mis tareas</button><button class="btn ${assignment==="ALL"?"btn-primary":"btn-ghost"}" id="all">Toda la cola</button><button class="btn btn-primary" id="queue-filter">Buscar</button>${viewSwitch(view)}</div><div class="selection-hint"><strong>Selecciona un pedido</strong><span>Abre una tarjeta para ver el paso actual, registrar controles y continuar el flujo.</span></div><div id="queue-result">${loading()}</div></section>`;

  async function load(newPage=1){
    page=newPage;
    const target=root.querySelector("#queue-result");
    target.innerHTML=loading("Consultando la cola de trabajo…");
    const data=await api.listOrders({step:selected,status:root.querySelector("#queue-status").value||null,search:root.querySelector("#queue-search").value,assignment,page,pageSize:50,includeHistory:false});
    const content=data.items.length?(view==="cards"?orderVisualCards(data.items,{queue:true}):table(data.items)):empty("Cola sin pedidos","No hay pedidos activos para esta etapa y los filtros seleccionados.");
    target.innerHTML=`${content}${data.items.length?paginationHtml(data.pagination):""}`;
    target.querySelectorAll("[data-order]").forEach(element=>element.onclick=()=>openOrder(element.dataset.order));
    target.querySelectorAll("[data-page]").forEach(element=>element.onclick=()=>load(Number(element.dataset.page)));
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
  root.querySelector("#queue-filter").onclick=()=>load(1);
  root.querySelector("#queue-search").onkeydown=event=>{if(event.key==="Enter")load(1)};
  root.querySelector("#mine").onclick=()=>{assignment="MINE";root.querySelector("#mine").className="btn btn-primary";root.querySelector("#all").className="btn btn-ghost";load(1)};
  root.querySelector("#all").onclick=()=>{assignment="ALL";root.querySelector("#all").className="btn btn-primary";root.querySelector("#mine").className="btn btn-ghost";load(1)};
  root.querySelector("#queue-help").onclick=()=>guide({title:"Cómo gestionar una cola",description:"Trabaja siempre desde el pedido y sigue el orden sugerido.",items:[{title:"Elige la etapa",detail:"Solo verás las etapas que pertenecen al módulo."},{title:"Busca o selecciona",detail:"Usa las tarjetas para identificar cliente, prioridad, responsable y tiempo."},{title:"Abre el pedido",detail:"El expediente mostrará las acciones que realmente puedes ejecutar."},{title:"Sigue el asistente",detail:"Cada acción te indicará qué registrar antes de confirmar."}]});
  await load(page);
}
function table(rows){return `<div class="table-wrap"><table><thead><tr><th>Prioridad</th><th>Pedido</th><th>Cliente</th><th>Estado</th><th>Responsable</th><th>Tiempo laboral</th><th>Plazo objetivo</th><th>Modalidad de entrega</th></tr></thead><tbody>${rows.map(order=>`<tr><td>${priorityBadge(order.priority)}</td><td><span class="table-link" data-order="${order.id}">${fmt.escape(order.orderNumber)}</span><div class="cell-sub">${fmt.escape(fmt.label(order.orderType))}</div></td><td><div class="cell-main">${fmt.escape(order.clientName)}</div><div class="cell-sub">${fmt.escape(fmt.payment(order.paymentCondition))}</div></td><td>${statusBadge(order.status)}</td><td>${fmt.escape(order.assigneeName||"En cola")}<div class="cell-sub">${fmt.escape(fmt.role(order.roleCode||""))}</div></td><td>${fmt.hours(order.ageBusinessSeconds)}</td><td>${order.slaExceeded?'<span class="badge badge-red"><span class="badge-dot"></span>Fuera de plazo</span>':'<span class="badge badge-green"><span class="badge-dot"></span>Dentro del plazo</span>'}</td><td>${fmt.escape(fmt.route(order.route))}</td></tr>`).join("")}</tbody></table></div>`}
