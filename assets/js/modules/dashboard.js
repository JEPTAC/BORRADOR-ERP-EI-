import {api} from "../services/api.js";
import {fmt,statusBadge} from "../core/format.js";
import {empty} from "../core/ui.js";
import {navigate} from "../core/router.js";

export async function renderDashboard(root){
  const data=await api.dashboard();const k=data.kpis||{};const queues=data.queues||[];const recent=data.recent||[];
  root.innerHTML=`
    <section class="page-head"><div><h2>Resumen de la operación</h2><p>Consulta cargas de trabajo, pedidos críticos, tiempos y decisiones pendientes.</p></div><div class="page-actions"><button class="btn btn-primary" id="new-order">＋ Nuevo pedido</button><button class="btn btn-ghost" id="go-qa">Abrir pruebas automáticas</button></div></section>
    <section class="grid grid-kpi">
      ${kpi("Pedidos activos",k.activeOrders,"Actualmente en proceso")}${kpi("Mis tareas",k.myTasks,"Asignadas a tu usuario")}${kpi("Pedidos bloqueados",k.blocked,"Necesitan intervención","warning")}${kpi("Prioridad alta",k.critical,"Urgentes o críticos","danger")}${kpi("Cerrados hoy",k.closedToday,"Entregas finalizadas","success")}${kpi("Decisiones pendientes",k.pendingApprovals,"Solicitudes por revisar")}
    </section>
    <div style="height:18px"></div>
    <section class="card"><header class="card-head"><h3>Carga de trabajo por etapa</h3><span class="muted">Actualizado ${fmt.date(data.generatedAt)}</span></header><div class="card-body"><div class="queue-grid">${queues.map(queueCard).join("")}</div></div></section>
    <div style="height:18px"></div>
    <section class="grid grid-2">
      <article class="card"><header class="card-head"><h3>Pedidos actualizados recientemente</h3><button class="btn btn-ghost" id="all-orders">Ver todos los pedidos</button></header><div class="card-body">${recent.length?recentTable(recent):empty()}</div></article>
      <article class="card"><header class="card-head"><h3>Controles que protegen la operación</h3></header><div class="card-body"><div class="timeline">
        ${principle("Una tarea activa por pedido","Evita movimientos duplicados y estados incompatibles.")}
        ${principle("Una sesión activa por operario","La toma de tiempos no se duplica entre procesos.")}
        ${principle("Control de cambios simultáneos","Impide sobrescribir el trabajo realizado por otra persona.")}
        ${principle("Registro de cada decisión","Las acciones quedan trazadas y no se procesan dos veces.")}
      </div></div></article>
    </section>`;
  root.querySelector("#new-order").onclick=()=>navigate("sales",{create:"1"});root.querySelector("#go-qa").onclick=()=>navigate("qa");root.querySelector("#all-orders").onclick=()=>navigate("orders");
  root.querySelectorAll("[data-step]").forEach(x=>x.onclick=()=>navigate("orders",{step:x.dataset.step}));
  root.querySelectorAll("[data-order]").forEach(x=>x.onclick=()=>window.dispatchEvent(new CustomEvent("erp:open-order",{detail:x.dataset.order})));
}
function kpi(label,value,foot,tone=""){return `<article class="card kpi"><div class="kpi-label">${label}</div><div class="kpi-value ${tone}">${fmt.number(value)}</div><div class="kpi-foot">${foot}</div></article>`}
function queueCard(q){const total=Number(q.quantity||0),overdue=Number(q.overdue||0);return `<article class="queue-card" data-step="${q.stepCode}"><div class="queue-top"><span class="queue-name">${fmt.escape(fmt.step(q.name||q.stepCode))}</span>${overdue?`<span class="badge badge-red"><span class="badge-dot"></span>${overdue} fuera de plazo</span>`:""}</div><div class="queue-number">${fmt.number(total)}</div><div class="progress"><span style="width:${Math.min(100,total?((Number(q.inProgress||0)/total)*100):0)}%"></span></div><div class="queue-meta"><span>${fmt.number(q.inProgress)} en proceso</span><span>${fmt.number(q.waiting)} en espera</span></div></article>`}
function recentTable(rows){return `<div class="table-wrap"><table style="min-width:650px"><thead><tr><th>Pedido</th><th>Cliente</th><th>Etapa actual</th><th>Estado</th></tr></thead><tbody>${rows.map(r=>`<tr><td><span class="table-link" data-order="${r.id}">${fmt.escape(r.orderNumber)}</span><div class="cell-sub">${fmt.escape(fmt.label(r.orderType))}</div></td><td>${fmt.escape(r.clientName)}</td><td>${fmt.escape(fmt.step(r.currentStep))}</td><td>${statusBadge(r.status)}</td></tr>`).join("")}</tbody></table></div>`}
function principle(title,text){return `<div class="timeline-item"><h4>${title}</h4><p>${text}</p></div>`}
