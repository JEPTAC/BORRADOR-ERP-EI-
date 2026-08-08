import {api} from "../services/api.js";
import {fmt,statusBadge} from "../core/format.js";
import {empty,loading,wizard,toast,actionCards,guide} from "../core/ui.js";
import {workspaceIntro,summaryItem} from "../core/guided.js";
import {openOrder} from "./orders.js";

export async function renderApprovals(root){
  let currentStatus="PENDING";
  root.innerHTML=`
    <section class="page-head"><div><h2>Bandeja de decisiones</h2><p>Revisa cada solicitud con su pedido, motivo y trazabilidad antes de decidir.</p></div><div class="page-actions"><button class="btn btn-ghost" id="approvals-help">¿Cómo decido correctamente?</button></div></section>
    ${workspaceIntro({title:"Selecciona el grupo de solicitudes",description:"Primero elige qué solicitudes deseas revisar. Después abre una tarjeta y sigue el asistente de decisión.",cards:actionCards([{id:"pending-approvals",title:"Pendientes por decidir",description:"Solicitudes que requieren una decisión de tu rol.",icon:"!",tone:"accent"},{id:"approved-approvals",title:"Aprobadas",description:"Consulta solicitudes que fueron autorizadas.",icon:"✓",tone:"success"},{id:"rejected-approvals",title:"Rechazadas",description:"Consulta solicitudes que no fueron autorizadas.",icon:"×",tone:"warning"},{id:"all-approvals",title:"Historial completo",description:"Muestra todas las solicitudes y decisiones.",icon:"▦",tone:"primary"}])})}
    <section class="card card-pad"><div class="selection-hint"><strong>Solicitudes ${currentStatus?fmt.label(currentStatus).toLowerCase():"registradas"}</strong><span>Selecciona una tarjeta para abrir el pedido o registrar la decisión.</span></div><div id="approval-result">${loading()}</div></section>`;

  async function load(){
    const target=root.querySelector("#approval-result");
    target.innerHTML=loading("Consultando solicitudes…");
    const data=await api.approvals(currentStatus||null,1,100);
    target.innerHTML=data.items.length?cards(data.items):empty("Sin solicitudes","No hay decisiones para el grupo seleccionado.");
    target.querySelectorAll("[data-order]").forEach(button=>button.onclick=()=>openOrder(button.dataset.order));
    target.querySelectorAll("[data-decide]").forEach(button=>button.onclick=()=>decisionWizard(JSON.parse(button.dataset.request),button.dataset.decision,load));
  }
  const set=status=>{currentStatus=status;load()};
  root.querySelector("#pending-approvals").onclick=()=>set("PENDING");
  root.querySelector("#approved-approvals").onclick=()=>set("APPROVED");
  root.querySelector("#rejected-approvals").onclick=()=>set("REJECTED");
  root.querySelector("#all-approvals").onclick=()=>set("");
  root.querySelector("#approvals-help").onclick=()=>guide({title:"Cómo decidir una solicitud",description:"Una decisión debe quedar sustentada y ser fácil de auditar.",items:[{title:"Abre el pedido",detail:"Revisa su etapa, estado, documentos y comentarios."},{title:"Lee el motivo",detail:"Comprueba qué solicita el usuario y cuál es el efecto esperado."},{title:"Selecciona aprobar o rechazar",detail:"El asistente te mostrará el resultado antes de confirmar."},{title:"Escribe una justificación",detail:"La razón debe ser concreta y suficiente para la trazabilidad."}]});
  await load();
}
function cards(rows){return `<div class="decision-grid">${rows.map(request=>`<article class="decision-card"><div class="decision-card-head"><div><strong>${fmt.escape(request.orderNumber)}</strong><span>${fmt.escape(request.clientName)}</span></div>${statusBadge(request.status)}</div><div class="decision-card-body"><label>Solicitud</label><h3>${fmt.escape(fmt.request(request.requestType))}</h3>${request.requestPayload?.exceptionCode?`<span class="decision-exception-code">${fmt.escape(request.requestPayload.exceptionCode.replaceAll("_"," "))}</span>`:""}<p>${fmt.escape(request.reason)}</p><div class="decision-meta"><span>Solicita: <strong>${fmt.escape(request.requestedBy)}</strong></span><span>Destino: <strong>${fmt.escape(fmt.role(request.assignedRole||"jefe_logistica"))}</strong></span><span>${fmt.date(request.createdAt)}</span></div></div><footer class="decision-card-foot"><button class="btn btn-ghost" data-order="${request.orderId}">Ver pedido</button>${request.status==="PENDING"?`<button class="btn btn-success" data-decide data-decision="APPROVED" data-request='${fmt.escape(JSON.stringify(request))}'>Aprobar</button><button class="btn btn-danger" data-decide data-decision="REJECTED" data-request='${fmt.escape(JSON.stringify(request))}'>Rechazar</button>`:""}</footer></article>`).join("")}</div>`}
function decisionWizard(request,decision,reload){
  const approve=decision==="APPROVED";
  wizard({title:approve?"Aprobar solicitud":"Rechazar solicitud",subtitle:"Revisa el efecto de la decisión y registra una justificación clara.",finishLabel:approve?"Confirmar aprobación":"Confirmar rechazo",steps:[{title:"Revisar solicitud",description:"Comprueba pedido, cliente, tipo y motivo.",content:`<div class="wizard-summary">${summaryItem("Pedido",request.orderNumber)}${summaryItem("Cliente",request.clientName)}${summaryItem("Tipo",fmt.request(request.requestType))}${summaryItem("Solicitante",request.requestedBy)}</div><div class="review-text"><strong>Motivo registrado</strong><p>${fmt.escape(request.reason)}</p></div>`},{title:"Justificar decisión",description:"La explicación quedará en la auditoría del pedido.",content:`<div class="field"><label>Motivo de la decisión *</label><textarea class="control" name="reason" required placeholder="Explique por qué ${approve?"se aprueba":"se rechaza"} la solicitud"></textarea></div>`},{title:"Confirmar",description:"Esta acción quedará registrada con tu usuario.",content:`<div class="wizard-confirm-box"><strong>${approve?"La solicitud será aprobada":"La solicitud será rechazada"}</strong><p>${approve?"El ERP ejecutará la acción automática o dejará la gestión manual correspondiente.":"El pedido conservará su estado actual y la solicitud quedará cerrada."}</p></div><div class="review-text" data-decision-reason></div>`,onEnter:({root,data})=>{root.querySelector("[data-decision-reason]").innerHTML=`<strong>Justificación</strong><p>${fmt.escape(data.reason||"")}</p>`}}],onFinish:async({data})=>{await api.decideApproval(request.id,decision,data.reason.trim());toast(`Solicitud ${approve?"aprobada":"rechazada"}.`);await reload()}});
}
