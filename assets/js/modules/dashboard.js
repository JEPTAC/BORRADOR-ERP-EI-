import {api} from "../services/api.js";
import {fmt,statusBadge} from "../core/format.js";
import {empty} from "../core/ui.js";
import {navigate} from "../core/router.js";

export async function renderDashboard(root){
  const data=await api.dashboard();const k=data.kpis||{};const queues=data.queues||[];const recent=data.recent||[];
  root.innerHTML=`
    <section class="page-head"><div><h2>Operación en tiempo real</h2><p>Pedidos, cargas de trabajo, riesgos y cumplimiento de SLA.</p></div><div class="page-actions"><button class="btn btn-primary" id="new-order">＋ Nuevo pedido</button><button class="btn btn-ghost" id="go-qa">Ejecutar QA</button></div></section>
    <section class="grid grid-kpi">
      ${kpi("Pedidos activos",k.activeOrders,"En flujo operativo")}${kpi("Mis tareas",k.myTasks,"Asignadas al usuario")}${kpi("Bloqueados",k.blocked,"Requieren intervención","warning")}${kpi("Prioridad alta",k.critical,"Urgentes y críticos","danger")}${kpi("Cerrados hoy",k.closedToday,"Despachos completados","success")}${kpi("Aprobaciones",k.pendingApprovals,"Pendientes de decisión")}
    </section>
    <div style="height:18px"></div>
    <section class="card"><header class="card-head"><h3>Colas operativas</h3><span class="muted">${fmt.date(data.generatedAt)}</span></header><div class="card-body"><div class="queue-grid">${queues.map(queueCard).join("")}</div></div></section>
    <div style="height:18px"></div>
    <section class="grid grid-2">
      <article class="card"><header class="card-head"><h3>Actividad reciente</h3><button class="btn btn-ghost" id="all-orders">Ver todos</button></header><div class="card-body">${recent.length?recentTable(recent):empty()}</div></article>
      <article class="card"><header class="card-head"><h3>Principios de control</h3></header><div class="card-body"><div class="timeline">
        ${principle("Una tarea activa por pedido","Evita dobles movimientos y estados incompatibles.")}
        ${principle("Una sesión activa por operario","La toma de tiempos no se duplica entre procesos.")}
        ${principle("Versionado optimista","Impide sobrescribir cambios realizados por otro usuario.")}
        ${principle("Auditoría e idempotencia","Cada decisión queda trazada y no se procesa dos veces.")}
      </div></div></article>
    </section>`;
  root.querySelector("#new-order").onclick=()=>navigate("sales");root.querySelector("#go-qa").onclick=()=>navigate("qa");root.querySelector("#all-orders").onclick=()=>navigate("orders");
  root.querySelectorAll("[data-step]").forEach(x=>x.onclick=()=>navigate("orders",{step:x.dataset.step}));
  root.querySelectorAll("[data-order]").forEach(x=>x.onclick=()=>window.dispatchEvent(new CustomEvent("erp:open-order",{detail:x.dataset.order})));
}
function kpi(label,value,foot,tone=""){return `<article class="card kpi"><div class="kpi-label">${label}</div><div class="kpi-value ${tone}">${fmt.number(value)}</div><div class="kpi-foot">${foot}</div></article>`}
function queueCard(q){const total=Number(q.quantity||0),overdue=Number(q.overdue||0);return `<article class="queue-card" data-step="${q.stepCode}"><div class="queue-top"><span class="queue-name">${fmt.escape(q.name)}</span>${overdue?`<span class="badge badge-red">${overdue} SLA</span>`:""}</div><div class="queue-number">${fmt.number(total)}</div><div class="progress"><span style="width:${Math.min(100,total?((Number(q.inProgress||0)/total)*100):0)}%"></span></div><div class="queue-meta"><span>${fmt.number(q.inProgress)} en proceso</span><span>${fmt.number(q.waiting)} en espera</span></div></article>`}
function recentTable(rows){return `<div class="table-wrap"><table style="min-width:650px"><thead><tr><th>Pedido</th><th>Cliente</th><th>Etapa</th><th>Estado</th></tr></thead><tbody>${rows.map(r=>`<tr><td><span class="table-link" data-order="${r.id}">${fmt.escape(r.orderNumber)}</span><div class="cell-sub">${fmt.escape(r.orderType)}</div></td><td>${fmt.escape(r.clientName)}</td><td>${fmt.escape(r.currentStep)}</td><td>${statusBadge(r.status)}</td></tr>`).join("")}</tbody></table></div>`}
function principle(title,text){return `<div class="timeline-item"><h4>${title}</h4><p>${text}</p></div>`}
