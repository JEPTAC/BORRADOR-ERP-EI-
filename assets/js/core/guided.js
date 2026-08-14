import {fmt,statusBadge,priorityBadge} from "./format.js";

export function workspaceIntro({title,description,helper="Selecciona la acción que necesitas.",cards=""}){
  return `<section class="guided-workspace"><div class="guided-workspace-head"><div><span class="guided-kicker">Acciones disponibles</span><h3>${fmt.escape(title)}</h3><p>${fmt.escape(description)}</p></div><div class="guided-helper-pill">${fmt.escape(helper)}</div></div>${cards}</section>`;
}

export function orderVisualCards(rows,{queue=false}={}){
  const css=queue?"queue-visual-grid":"order-visual-grid";
  return `<div class="${css} simple-order-grid">${rows.map(order=>{
    const status=order.exceptionLabel?{label:order.exceptionLabel,tone:order.status==="WAITING"?"waiting":"blocked"}:simpleStatus(order.status);
    return `<button type="button" class="order-visual-card simple-order-card ${queue?"queue-order-card":""} ${order.slaExceeded?"overdue":""}" data-order="${fmt.escape(order.id)}" data-purchase-shadow="${order.purchaseShadow?"1":"0"}">
      <div class="simple-order-top"><div><span class="simple-order-number">${fmt.escape(order.orderNumber)}</span><span class="simple-order-client">${fmt.escape(order.clientName)}</span></div><div class="simple-order-tags">${order.purchaseShadow?`<span class="purchase-shadow-tag">PVE · ${order.arrivalStatus==="ARRIVED"?"Mercancía OK":order.arrivalStatus==="WAITING"?"En espera":"Seguimiento"}</span>`:""}${order.exceptionLabel?`<span class="order-exception-tag ${order.status==="WAITING"?"novelty":"report"}">${fmt.escape(order.exceptionLabel)}</span>`:""}${order.fulfillmentStatus==="PARTIAL"||order.partialLabel?`<span class="order-partial-tag">Pedido parcial${Number(order.pendingItemCount||0)>0?` · ${fmt.number(order.pendingItemCount)} pendiente(s)`:""}</span>`:""}${priorityBadge(order.priority)}</div></div>
      <div class="simple-order-stage"><span>Etapa actual</span><strong>${fmt.escape(fmt.step(order.stepName||order.currentStep))}</strong></div>
      <div class="simple-order-status ${status.tone}"><span class="simple-status-dot"></span><div><small>Situación</small><strong>${fmt.escape(status.label)}</strong></div></div>
      <div class="simple-order-facts"><span><small>Responsable</small><strong>${fmt.escape(order.assigneeName||"Sin asignar")}</strong></span><span><small>Tiempo</small><strong>${fmt.hours(order.ageBusinessSeconds)}</strong></span><span><small>Entrega</small><strong>${fmt.escape(fmt.route(order.route))}</strong></span></div>
      <footer class="simple-order-foot"><span>${order.purchaseShadow?"Seguimiento físico paralelo":order.canResume===false?"Salida parcial en curso":order.slaExceeded?"Requiere atención":"Listo para gestionar"}</span><strong>${order.purchaseShadow?(order.arrivalStatus==="WAITING"?"Confirmar llegada →":order.arrivalStatus==="ARRIVED"?"Ver estado →":"Marcar espera →"):order.canResume===false?"Ver estado →":"Gestionar pedido →"}</strong></footer>
    </button>`;
  }).join("")}</div>`;
}

export function viewSwitch(mode="cards"){
  return `<div class="view-switch" aria-label="Tipo de vista"><button type="button" data-view="cards" class="${mode==="cards"?"active":""}">Tarjetas</button><button type="button" data-view="table" class="${mode==="table"?"active":""}">Lista</button></div>`;
}

export function summaryItem(label,value){
  return `<div class="wizard-summary-item"><label>${fmt.escape(label)}</label><strong>${fmt.escape(value??"—")}</strong></div>`;
}

export function choice(name,value,title,description,selected=false){
  return `<label class="wizard-choice"><input type="radio" name="${fmt.escape(name)}" value="${fmt.escape(value)}" ${selected?"checked":""} required><span><strong>${fmt.escape(title)}</strong><small>${fmt.escape(description)}</small></span></label>`;
}

export function simpleStatus(value){
  const code=String(value||"").toUpperCase();
  if(["QUEUED","ASSIGNED"].includes(code))return {label:"Pendiente por iniciar",tone:"pending"};
  if(code==="IN_PROGRESS")return {label:"En gestión",tone:"working"};
  if(code==="WAITING")return {label:"En espera",tone:"waiting"};
  if(code==="BLOCKED")return {label:"Con novedad",tone:"blocked"};
  if(["CLOSED","COMPLETED"].includes(code))return {label:"Gestionado",tone:"done"};
  if(code==="CANCELLED")return {label:"Cancelado",tone:"blocked"};
  return {label:fmt.label(value),tone:"pending"};
}
