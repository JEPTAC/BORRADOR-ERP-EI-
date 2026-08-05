import {fmt,statusBadge,priorityBadge} from "./format.js";

export function workspaceIntro({title,description,helper="Selecciona una opción para comenzar.",cards=""}){
  return `<section class="guided-workspace"><div class="guided-workspace-head"><div><span class="guided-kicker">Espacio de trabajo guiado</span><h3>${fmt.escape(title)}</h3><p>${fmt.escape(description)}</p></div><div class="guided-helper-pill">${fmt.escape(helper)}</div></div>${cards}</section>`;
}

export function orderVisualCards(rows,{queue=false}={}){
  const css=queue?"queue-visual-grid":"order-visual-grid";
  return `<div class="${css}">${rows.map(order=>`
    <article class="order-visual-card ${queue?"queue-order-card":""}">
      <div class="order-card-head"><div><span class="order-card-number">${fmt.escape(order.orderNumber)}</span><span class="order-card-reference">${fmt.escape(order.externalReference||fmt.label(order.orderType))}</span></div>${priorityBadge(order.priority)}</div>
      <div class="order-card-body"><p class="order-card-client">${fmt.escape(order.clientName)}</p><div class="order-card-route"><strong>${fmt.escape(fmt.step(order.stepName||order.currentStep))}</strong><span>${fmt.escape(fmt.route(order.route))}</span></div><div class="order-card-meta"><div><label>Estado</label><strong>${fmt.escape(fmt.label(order.status))}</strong></div><div><label>Responsable</label><strong>${fmt.escape(order.assigneeName||"En cola")}</strong></div><div><label>Tiempo en etapa</label><strong>${fmt.hours(order.ageBusinessSeconds)}</strong></div><div><label>Condición de pago</label><strong>${fmt.escape(fmt.payment(order.paymentCondition))}</strong></div></div></div>
      <footer class="order-card-foot"><div>${statusBadge(order.status)}</div><button class="btn btn-primary" data-order="${fmt.escape(order.id)}">Abrir pedido</button></footer>
    </article>`).join("")}</div>`;
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
