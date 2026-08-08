import {api} from "../services/api.js";
import {fmt,statusBadge} from "../core/format.js";
import {empty,actionCards,guide} from "../core/ui.js";
import {workspaceIntro} from "../core/guided.js";
import {navigate} from "../core/router.js";
import {state,can} from "../core/state.js";

export async function renderDashboard(root){
  const today=new Date();
  const to=today.toISOString().slice(0,10);
  const from=new Date(Date.now()-30*864e5).toISOString().slice(0,10);
  const [data,partialData,exceptionData]=await Promise.all([api.dashboard(),api.partialFulfillmentMetrics(from,to),api.exceptionSummary().catch(()=>({}))]);
  const k=data.kpis||{};
  const queues=data.queues||[];
  const recent=data.recent||[];
  const partialSummary=partialData.summary||{};
  const partialOrders=partialData.orders||[];
  const cards=[];
  if(can("sales","canCreate")||can("orders","canCreate"))cards.push({id:"guide-new-order",title:"Crear un pedido",description:"El asistente te pedirá solo la información necesaria, paso a paso.",icon:"＋",tone:"accent"});
  if(state.modules.some(m=>["cartera","caja","purchasing","receiving","picking","cutting","billing","shipping"].includes(m.code)&&m.canRead))cards.push({id:"guide-my-work",title:"Ver mis tareas",description:"Abre los pedidos asignados a tu usuario y continúa la etapa correspondiente.",icon:"✓",tone:"primary"});
  if(can("approvals","canRead"))cards.push({id:"guide-approvals",title:"Centro de excepciones",description:"Atiende Novedades, Reportes, Aprobaciones y alertas SLA desde una sola bandeja.",icon:"!",tone:"warning"});
  if(can("orders","canRead"))cards.push({id:"guide-orders",title:"Buscar un pedido",description:"Encuentra rápidamente un pedido por número, cliente, etapa o estado.",icon:"⌕"});
  if(can("qa","canRead"))cards.push({id:"guide-qa",title:"Validar el ERP",description:"Ejecuta las pruebas automáticas antes de habilitar nuevos cambios.",icon:"▶",tone:"success"});

  root.innerHTML=`
    <section class="page-head"><div><h2>Resumen de la operación</h2><p>Consulta cargas de trabajo, pedidos críticos, tiempos y decisiones pendientes.</p></div></section>
    ${workspaceIntro({title:`Hola, ${state.profile?.name?.split(" ")[0]||"bienvenido"}`,description:"Aquí encuentras las opciones principales disponibles para tu rol. Selecciona una tarjeta y el ERP te guiará.",cards:actionCards(cards)})}
    <section class="grid grid-kpi">
      ${kpi("Pedidos activos",k.activeOrders,"Actualmente en proceso")}${kpi("Mis tareas",k.myTasks,"Asignadas a tu usuario")}${kpi("Pedidos parciales",partialSummary.partialPending||0,"Con mercancía pendiente","warning")}${kpi("Pedidos bloqueados",k.blocked,"Necesitan intervención","warning")}${kpi("Excepciones escaladas",exceptionData.escalated||0,exceptionData.critical?`${exceptionData.critical} crítica(s) por SLA`:"SLA bajo control",exceptionData.critical?"danger":exceptionData.escalated?"warning":"success")}${kpi("Prioridad alta",k.critical,"Urgentes o críticos","danger")}${kpi("Cerrados hoy",k.closedToday,"Entregas finalizadas","success")}${kpi("Decisiones pendientes",exceptionData.pendingApprovals??k.pendingApprovals,"Solicitudes por revisar")}
    </section>
    ${partialOrders.length?`<div class="section-gap"></div><section class="card partial-time-card"><header class="card-head"><div><h3>Pedidos parciales: tiempo parcial y tiempo real</h3><p class="muted">Cada fila corresponde al mismo pedido; no se crean pedidos duplicados.</p></div></header><div class="card-body">${partialTimesTable(partialOrders.slice(0,8))}</div></section>`:""}
    <div class="section-gap"></div>
    <section class="card"><header class="card-head"><h3>Carga de trabajo por etapa</h3><span class="muted">Actualizado ${fmt.date(data.generatedAt)}</span></header><div class="card-body"><div class="queue-grid">${queues.map(queueCard).join("")}</div></div></section>
    <div class="section-gap"></div>
    <section class="grid grid-2">
      <article class="card"><header class="card-head"><h3>Pedidos actualizados recientemente</h3><button class="btn btn-ghost" id="all-orders">Ver todos</button></header><div class="card-body">${recent.length?recentTable(recent):empty()}</div></article>
      <article class="card"><header class="card-head"><h3>Cómo trabajar en el ERP</h3></header><div class="card-body"><div class="timeline">${principle("Selecciona una tarea","Entra al módulo correspondiente y elige visualmente el pedido que vas a gestionar.")}${principle("Sigue el asistente","El ERP te mostrará qué información registrar y validará cada paso.")}${principle("Revisa antes de confirmar","La última pantalla resume lo que se guardará para evitar errores.")}${principle("Consulta la trazabilidad","Cada decisión, tiempo y documento queda dentro del expediente del pedido.")}</div><button class="btn btn-ghost" id="dashboard-help">Ver guía rápida</button></div></article>
    </section>`;

  root.querySelector("#guide-new-order")?.addEventListener("click",()=>navigate("sales",{create:"1"}));
  root.querySelector("#guide-my-work")?.addEventListener("click",()=>navigate("orders",{assignment:"MINE",history:"0"}));
  root.querySelector("#guide-approvals")?.addEventListener("click",()=>navigate("approvals"));
  root.querySelector("#guide-orders")?.addEventListener("click",()=>navigate("orders"));
  root.querySelector("#guide-qa")?.addEventListener("click",()=>navigate("qa"));
  root.querySelector("#all-orders").onclick=()=>navigate("orders");
  root.querySelector("#dashboard-help").onclick=()=>guide({title:"Guía rápida del ERP",description:"La operación sigue el mismo patrón en todos los módulos.",items:[{title:"Elige una opción",detail:"Las tarjetas grandes muestran lo que puedes hacer según tu rol."},{title:"Selecciona un pedido",detail:"Las tarjetas de pedidos muestran cliente, etapa, prioridad y responsable."},{title:"Completa pasos cortos",detail:"Los formularios extensos se dividieron en pasos sencillos."},{title:"Confirma la información",detail:"Antes de guardar verás un resumen completo."}]});
  root.querySelectorAll("[data-step]").forEach(element=>element.onclick=()=>navigate("orders",{step:element.dataset.step,history:"0"}));
  root.querySelectorAll("[data-order]").forEach(element=>element.onclick=()=>window.dispatchEvent(new CustomEvent("erp:open-order",{detail:element.dataset.order})));
}
function kpi(label,value,foot,tone=""){return `<article class="card kpi"><div class="kpi-label">${label}</div><div class="kpi-value ${tone}">${fmt.number(value)}</div><div class="kpi-foot">${foot}</div></article>`}
function queueCard(q){const total=Number(q.quantity||0),overdue=Number(q.overdue||0);return `<article class="queue-card" data-step="${q.stepCode}"><div class="queue-top"><span class="queue-name">${fmt.escape(fmt.step(q.name||q.stepCode))}</span>${overdue?`<span class="badge badge-red"><span class="badge-dot"></span>${overdue} fuera de plazo</span>`:""}</div><div class="queue-number">${fmt.number(total)}</div><div class="progress"><span style="width:${Math.min(100,total?Number(q.inProgress||0)/total*100:0)}%"></span></div><div class="queue-meta"><span>${fmt.number(q.inProgress)} en proceso</span><span>${fmt.number(q.waiting)} en espera</span></div></article>`}
function recentTable(rows){return `<div class="table-wrap"><table style="min-width:650px"><thead><tr><th>Pedido</th><th>Cliente</th><th>Etapa actual</th><th>Estado</th></tr></thead><tbody>${rows.map(row=>`<tr><td><span class="table-link" data-order="${row.id}">${fmt.escape(row.orderNumber)}</span><div class="cell-sub">${fmt.escape(fmt.label(row.orderType))}</div></td><td>${fmt.escape(row.clientName)}</td><td>${fmt.escape(fmt.step(row.currentStep))}</td><td>${statusBadge(row.status)}</td></tr>`).join("")}</tbody></table></div>`}
function principle(title,text){return `<div class="timeline-item"><h4>${title}</h4><p>${text}</p></div>`}

function partialTimesTable(rows){return `<div class="table-wrap"><table><thead><tr><th>Pedido</th><th>Cliente</th><th>Rondas</th><th>Tiempo parcial</th><th>Tiempo real</th><th>Pendientes</th><th>Estado</th></tr></thead><tbody>${rows.map(row=>`<tr><td><span class="table-link" data-order="${fmt.escape(row.id)}">${fmt.escape(row.orderNumber)}</span></td><td>${fmt.escape(row.clientName)}</td><td>${fmt.number(row.roundCount)}</td><td>${fmt.number(row.partialHours,2)} h</td><td>${fmt.number(row.realHours,2)} h</td><td>${fmt.number(row.pendingItemCount)}</td><td><span class="order-partial-tag">${row.status==="COMPLETE"?"Completado":"Pedido parcial"}</span></td></tr>`).join("")}</tbody></table></div>`}
