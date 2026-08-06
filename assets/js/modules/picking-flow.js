import {api} from "../services/api.js";
import {fmt} from "../core/format.js";
import {toast} from "../core/ui.js";

const DRAFT_PREFIX="erp:alistamiento:v10.8:";
const ACTIVE_STATUSES=new Set(["QUEUED","ASSIGNED","IN_PROGRESS","WAITING","BLOCKED"]);

export function isPickingFlow(data){
  return data?.order?.current_step_code==="ALISTAMIENTO"||hasPartialPending(data);
}

export function renderPickingFlow(host,data,{reload,refreshLists}={}){
  if(data.order.current_step_code!=="ALISTAMIENTO"){
    renderPartialResume(host,data,{reload,refreshLists});
    return;
  }

  const task=activeTask(data);
  if(!task){
    host.innerHTML=shell(data,`<section class="picking-empty"><strong>No existe una tarea activa de Alistamiento.</strong><p>Solicita revisión del flujo antes de continuar.</p></section>`);
    bindClose(host);
    return;
  }

  const actions=actionCodes(data);
  if(task.status!=="IN_PROGRESS"){
    const resumed=rounds(data).length>0;
    const label=resumed?"Retomar pedido":"Tomar pedido";
    const canStart=actions.has("CLAIM")||actions.has("START")||actions.has("RESUME");
    host.innerHTML=shell(data,`
      <section class="picking-take-card">
        <span class="picking-step-tag">${resumed?`Ronda ${rounds(data).length+1}`:"Paso 1"}</span>
        <h4>${label}</h4>
        <p>${resumed?"Solo se verificarán las referencias que quedaron pendientes en la salida anterior.":"Al tomarlo quedará asignado a tu usuario y podrás verificar la mercancía línea por línea."}</p>
        <button type="button" class="btn btn-primary picking-take-button" data-picking-take ${canStart?"":"disabled"}>${label}</button>
        ${canStart?"":`<div class="picking-warning">Responsable actual: <strong>${fmt.escape(assigneeName(data))}</strong></div>`}
      </section>`);
    bindClose(host);
    host.querySelector("[data-picking-take]")?.addEventListener("click",async event=>{
      event.currentTarget.disabled=true;
      try{
        await beginPicking(data);
        refreshLists?.();
        await reload?.();
      }catch(error){
        toast(error.message,"error",7000);
        event.currentTarget.disabled=false;
      }
    });
    return;
  }

  if(!actions.has("COMPLETE")){
    host.innerHTML=shell(data,`<section class="picking-empty"><strong>Pedido en gestión</strong><p>Este pedido está bloqueado para evitar verificaciones simultáneas.</p><div class="picking-warning">Responsable: <strong>${fmt.escape(assigneeName(data))}</strong></div></section>`);
    bindClose(host);
    return;
  }

  renderVerification(host,data,{reload,refreshLists});
}

function renderVerification(host,data,{reload,refreshLists}){
  const task=activeTask(data);
  const pending=pendingItems(data);
  const draft=loadDraft(task,pending);
  const roundNo=rounds(data).length+1;
  const previous=rounds(data).length;

  host.innerHTML=shell(data,`
    <section class="picking-progress-strip">
      <div class="done"><span>1</span><strong>Pedido tomado</strong></div>
      <div class="active"><span>2</span><strong>Verificación de mercancía</strong></div>
      <div><span>3</span><strong>Enviar a facturación</strong></div>
    </section>
    ${partialBanner(data)}
    <section class="picking-verification-card">
      <header class="picking-stage-head">
        <div><span class="picking-step-tag">Ronda ${roundNo}</span><h4>Verificación de mercancía</h4><p>${previous?"Solo aparecen los elementos pendientes de la salida anterior.":"Marca Encontrado o No encontrado en cada línea."}</p></div>
        <div class="picking-counter"><strong data-picking-verified>0</strong><span>de ${pending.length} verificadas</span></div>
      </header>
      <div class="picking-items" data-picking-items>
        ${pending.map((item,index)=>itemRow(item,index,draft[item.id])).join("")}
      </div>
      <section class="picking-result-summary" data-picking-summary></section>
      <button type="button" class="btn btn-primary picking-send-button" data-picking-send disabled>Enviar a facturación</button>
      <small class="picking-route-note">${pending.some(item=>item.requires_cut)?"Las líneas encontradas que requieran corte pasarán primero por Corte y después continuarán a facturación.":"El pedido continuará directamente al proceso de facturación correspondiente."}</small>
    </section>
    ${roundHistory(data)}
  `);
  bindClose(host);

  const sync=()=>{
    const rows=[...host.querySelectorAll("[data-picking-item]")];
    const results=rows.map(readRow);
    const verified=results.filter(row=>row.result).length;
    const missing=results.filter(row=>row.result==="MISSING").length;
    const found=results.filter(row=>row.result==="FOUND").length;
    const missingWithoutReason=results.some(row=>row.result==="MISSING"&&!row.novelty);
    host.querySelector("[data-picking-verified]").textContent=String(verified);
    host.querySelector("[data-picking-summary]").innerHTML=summaryMarkup(pending.length,found,missing,verified);
    const send=host.querySelector("[data-picking-send]");
    send.disabled=verified!==pending.length||missingWithoutReason||pending.length===0;
    saveDraft(task,results);
  };

  host.querySelectorAll("[data-result]").forEach(button=>button.addEventListener("click",()=>{
    const row=button.closest("[data-picking-item]");
    row.querySelectorAll("[data-result]").forEach(item=>item.classList.toggle("selected",item===button));
    row.dataset.result=button.dataset.result;
    const novelty=row.querySelector("[data-novelty-wrap]");
    novelty.hidden=button.dataset.result!=="MISSING";
    const textarea=novelty.querySelector("textarea");
    textarea.required=button.dataset.result==="MISSING";
    if(button.dataset.result==="FOUND")textarea.value="";
    sync();
  }));
  host.querySelectorAll("[data-picking-item] textarea").forEach(textarea=>textarea.addEventListener("input",sync));
  host.querySelector("[data-picking-send]")?.addEventListener("click",()=>openConfirmation(host,data,task,refreshLists));
  sync();
}

function renderPartialResume(host,data,{reload,refreshLists}){
  const pending=pendingItems(data);
  const hasActive=(data.tasks||[]).some(task=>ACTIVE_STATUSES.has(task.status));
  const canResume=data.order.status==="CLOSED"&&!hasActive&&pending.length>0;
  host.innerHTML=shell(data,`
    <section class="picking-partial-resume">
      <span class="picking-partial-badge">PEDIDO PARCIAL</span>
      <h4>${canResume?"Retomar pedido":"Salida parcial en curso"}</h4>
      <p>${canResume?"La salida anterior ya terminó. Retoma el mismo pedido para verificar únicamente la mercancía que llegó después.":"La primera salida todavía está en facturación o despacho. Cuando finalice, el pedido quedará disponible para retomar lo pendiente."}</p>
      <div class="picking-resume-stats"><div><small>Rondas realizadas</small><strong>${rounds(data).length}</strong></div><div><small>Líneas pendientes</small><strong>${pending.length}</strong></div><div><small>Etapa actual</small><strong>${fmt.escape(fmt.step(data.order.current_step_code))}</strong></div></div>
      ${pendingPreview(pending)}
      <button type="button" class="btn btn-primary picking-take-button" data-resume-partial ${canResume?"":"disabled"}>Retomar pedido</button>
    </section>
    ${roundHistory(data)}
  `);
  bindClose(host);
  host.querySelector("[data-resume-partial]")?.addEventListener("click",async event=>{
    event.currentTarget.disabled=true;
    try{
      await api.resumePartialPicking(data.order.id);
      toast("Pedido parcial reabierto en Alistamiento.","success",6000);
      refreshLists?.();
      await reload?.();
    }catch(error){
      toast(error.message,"error",7000);
      event.currentTarget.disabled=false;
    }
  });
}

function shell(data,content){
  const fulfillment=data.order.metadata?.fulfillment||{};
  return `<div class="modal-overlay simple-process-overlay">
    <section class="modal simple-process-modal wide picking-process-modal">
      <header class="modal-head simple-process-head picking-process-head">
        <div><span class="wizard-kicker">Alistamiento</span><h3>${fmt.escape(data.order.order_number)}</h3><p>${fmt.escape(data.order.client_name)} · ${fmt.escape(fmt.label(data.order.order_type_code))}</p></div>
        <div class="picking-head-actions">${fulfillment.partialLabel||fulfillment.status==="PARTIAL"?'<span class="picking-partial-badge">PEDIDO PARCIAL</span>':""}<button class="icon-btn" data-close aria-label="Cerrar">×</button></div>
      </header>
      <div class="modal-body simple-process-body picking-process-body">
        <section class="picking-order-strip">
          <div><small>Responsable</small><strong>${fmt.escape(assigneeName(data))}</strong></div>
          <div><small>Entrega</small><strong>${fmt.escape(fmt.route(data.order.delivery_route_code))}</strong></div>
          <div><small>Líneas totales</small><strong>${(data.items||[]).length}</strong></div>
          <div><small>Pendientes</small><strong>${pendingItems(data).length}</strong></div>
        </section>
        ${content}
        <details class="simple-details"><summary>Ver información completa del pedido</summary>${details(data)}</details>
      </div>
      <footer class="modal-foot"><button class="btn btn-ghost" data-close>Cerrar</button></footer>
    </section>
  </div>`;
}

function itemRow(item,index,saved={}){
  const result=saved?.result||"";
  const novelty=saved?.novelty||item.metadata?.lastNovelty||"";
  return `<article class="picking-item-row" data-picking-item data-item-id="${fmt.escape(item.id)}" data-result="${fmt.escape(result)}">
    <div class="picking-item-number">${index+1}</div>
    <div class="picking-item-data">
      <div><small>Referencia</small><strong>${fmt.escape(item.reference||item.sku||"—")}</strong></div>
      <div class="description"><small>Mercancía</small><strong>${fmt.escape(item.description)}</strong></div>
      <div><small>Cantidad</small><strong>${fmt.number(item.quantity,3)} ${fmt.escape(item.unit)}</strong></div>
      <div><small>Ubicación</small><strong>${fmt.escape(item.warehouse_location||"—")}</strong></div>
      ${item.requires_cut?`<div><small>Corte</small><strong>${item.requested_cut_length?`${fmt.number(item.requested_cut_length,3)} ${fmt.escape(item.unit)}`:"Requiere corte"}</strong></div>`:""}
    </div>
    <div class="picking-mini-actions">
      <button type="button" class="picking-result found ${result==="FOUND"?"selected":""}" data-result="FOUND">Encontrado</button>
      <button type="button" class="picking-result missing ${result==="MISSING"?"selected":""}" data-result="MISSING">No encontrado</button>
    </div>
    <div class="picking-novelty" data-novelty-wrap ${result==="MISSING"?"":"hidden"}>
      <label>¿Por qué no se encontró? *</label>
      <textarea class="control" rows="2" placeholder="Ejemplo: referencia agotada, ubicación vacía o cantidad incompleta" ${result==="MISSING"?"required":""}>${fmt.escape(novelty)}</textarea>
      <small>La novedad quedará registrada automáticamente en el pedido.</small>
    </div>
  </article>`;
}

function summaryMarkup(total,found,missing,verified){
  const pending=total-verified;
  const kind=verified===total?(missing?"partial":"complete"):"pending";
  return `<div class="picking-summary-state ${kind}"><strong>${verified===total?(missing?"Envío parcial":"Envío completo"):"Verificación en curso"}</strong><span>${found} encontrada(s) · ${missing} no encontrada(s) · ${pending} por marcar</span></div>`;
}

function openConfirmation(host,data,task,refreshLists){
  const results=[...host.querySelectorAll("[data-picking-item]")].map(readRow);
  const missing=results.filter(row=>row.result==="MISSING");
  const found=results.length-missing.length;
  const layer=document.createElement("div");
  layer.className="picking-confirm-layer";
  layer.innerHTML=`<section class="picking-confirm-dialog">
    <header><div><span class="picking-step-tag">Confirmación final</span><h4>${missing.length?"Enviar pedido parcial":"Enviar pedido completo"}</h4><p>Esta acción cerrará la ronda actual de Alistamiento.</p></div><button class="icon-btn" data-cancel>×</button></header>
    <div class="picking-confirm-body">
      <div class="picking-confirm-counts"><div><small>Encontradas</small><strong>${found}</strong></div><div><small>Pendientes</small><strong>${missing.length}</strong></div></div>
      ${missing.length?`<div class="picking-confirm-warning"><strong>El pedido continuará con etiqueta de pedido parcial.</strong><p>Cuando termine esta salida y llegue la mercancía faltante, podrás reabrir el mismo pedido desde Alistamiento.</p></div>`:`<div class="picking-confirm-success"><strong>Toda la mercancía fue encontrada.</strong><p>El pedido continuará sin pendientes.</p></div>`}
    </div>
    <footer><button class="btn btn-ghost" data-cancel>Volver</button><button class="btn btn-primary" data-confirm-picking>Confirmar y enviar a facturación</button></footer>
  </section>`;
  host.append(layer);
  layer.querySelectorAll("[data-cancel]").forEach(button=>button.onclick=()=>layer.remove());
  layer.querySelector("[data-confirm-picking]").onclick=async event=>{
    event.currentTarget.disabled=true;
    try{
      const result=await api.confirmPickingRound(data.order.id,{items:results});
      clearDraft(task);
      toast(result.partial?`Pedido parcial enviado. Quedaron ${result.missingLines} línea(s) pendientes.`:"Alistamiento completo y enviado a facturación.","success",7500);
      refreshLists?.();
      host.replaceChildren();
    }catch(error){
      toast(error.message,"error",7500);
      event.currentTarget.disabled=false;
    }
  };
}

async function beginPicking(data){
  let latest=await api.getOrder(data.order.id);
  let actions=actionCodes(latest);
  if(actions.has("CLAIM")){
    await api.executeAction(latest.order.id,"CLAIM",{detail:"Pedido tomado para Alistamiento"},latest.order.version);
    latest=await api.getOrder(latest.order.id);
    actions=actionCodes(latest);
  }
  if(actions.has("START"))await api.executeAction(latest.order.id,"START",{detail:"Verificación de mercancía iniciada"},latest.order.version);
  else if(actions.has("RESUME"))await api.executeAction(latest.order.id,"RESUME",{detail:"Verificación de mercancía retomada"},latest.order.version);
}

function activeTask(data){return [...(data.tasks||[])].reverse().find(task=>ACTIVE_STATUSES.has(task.status))||null}
function actionCodes(data){return new Set((data.actions?.actions||[]).map(action=>action.code))}
function rounds(data){return data.pickingRounds||[]}
function pendingItems(data){return (data.items||[]).filter(item=>!["FULFILLED","CANCELLED"].includes(String(item.item_status||"PENDING").toUpperCase()))}
function hasPartialPending(data){return data?.order?.metadata?.fulfillment?.status==="PARTIAL"&&pendingItems(data).length>0}
function assigneeName(data){const task=activeTask(data);return task?.assigned_name||data.order.current_assignee_name||data.order.metadata?.receptionAssignment?.pickingProfileName||"Auxiliar asignado"}
function bindClose(host){host.querySelectorAll("[data-close]").forEach(button=>button.onclick=()=>host.replaceChildren())}
function readRow(row){return {orderItemId:row.dataset.itemId,result:row.dataset.result||"",novelty:row.querySelector("textarea")?.value.trim()||""}}
function draftKey(task){return `${DRAFT_PREFIX}${task?.id||"none"}`}
function loadDraft(task,items){
  try{
    const raw=JSON.parse(localStorage.getItem(draftKey(task))||"{}");
    return Object.fromEntries(items.map(item=>[item.id,raw[item.id]||{}]));
  }catch{return {}}
}
function saveDraft(task,rows){
  const value=Object.fromEntries(rows.map(row=>[row.orderItemId,{result:row.result,novelty:row.novelty}]));
  localStorage.setItem(draftKey(task),JSON.stringify(value));
}
function clearDraft(task){localStorage.removeItem(draftKey(task))}

function partialBanner(data){
  const roundCount=rounds(data).length;
  if(!roundCount)return "";
  return `<section class="picking-resume-banner"><span class="picking-partial-badge">RETOMADO</span><div><strong>Continuación del mismo pedido</strong><p>Las líneas ya enviadas no vuelven a aparecer. Esta es la ronda ${roundCount+1}.</p></div></section>`;
}
function pendingPreview(items){return `<div class="picking-pending-preview"><h5>Mercancía pendiente</h5>${items.map(item=>`<article><div><strong>${fmt.escape(item.reference||item.sku||item.description)}</strong><span>${fmt.escape(item.description)}</span></div><b>${fmt.number(item.quantity,3)} ${fmt.escape(item.unit)}</b></article>`).join("")}</div>`}
function roundHistory(data){
  const rows=rounds(data);
  if(!rows.length)return "";
  return `<details class="picking-round-history"><summary>Ver rondas anteriores (${rows.length})</summary><div>${rows.map(row=>`<article><span>Ronda ${row.round_no}</span><strong class="${row.status==="PARTIAL"?"warning":"success"}">${row.status==="PARTIAL"?"Parcial":"Completa"}</strong><small>${row.found_lines} encontrada(s) · ${row.missing_lines} pendiente(s) · ${fmt.number(Number(row.business_seconds||0)/3600,2)} h productivas</small></article>`).join("")}</div></details>`;
}
function details(data){
  return `<div class="picking-details-grid"><div><small>Cliente</small><strong>${fmt.escape(data.order.client_name)}</strong></div><div><small>Tipo</small><strong>${fmt.escape(fmt.label(data.order.order_type_code))}</strong></div><div><small>Pago</small><strong>${fmt.escape(fmt.payment(data.order.payment_condition_code))}</strong></div><div><small>Ruta</small><strong>${fmt.escape(fmt.route(data.order.delivery_route_code))}</strong></div></div>${pendingPreview(data.items||[])}`;
}
