import {api} from "../services/api.js";
import {fmt} from "../core/format.js";
import {modal,toast} from "../core/ui.js";
import {uploadOrderFile} from "../services/drive.js";

const RELEASE_STEPS=new Set(["CARTERA","CAJA"]);

export function isFinancialFlowStep(data){
  const step=data?.order?.current_step_code;
  return RELEASE_STEPS.has(step)||step==="CAJA_FACTURACION";
}

export function renderFinancialFlow(host,data,{reload,refreshLists}){
  if(data.order.current_step_code==="CAJA_FACTURACION")return renderCashInvoice(host,data,{reload,refreshLists});
  return renderReleaseManagement(host,data,{reload,refreshLists});
}

function activeTask(data){
  return (data.tasks||[]).find(task=>["QUEUED","ASSIGNED","IN_PROGRESS","WAITING","BLOCKED"].includes(task.status))||null;
}
function actionCodes(data){return new Set((data.actions?.actions||[]).map(action=>action.code))}
function latestValidation(data,step){
  return [...(data.financialValidations||[])].reverse().find(row=>row.validation_type===step)||null;
}
function registeredInvoice(data){return [...(data.invoices||[])].reverse().find(row=>row.status==="REGISTERED")||null}
function closeHost(host){host.replaceChildren()}
function refresh(refreshLists){refreshLists?.()}
async function guarded(action){try{return await action()}catch(error){toast(error.message||String(error),"error",7000)}}

function statusLabel(task,closed=false){
  if(closed)return {label:"Cerrado",tone:"done",detail:"La gestión terminó y el pedido está listo para liberarse."};
  const value=task?.status;
  if(value==="IN_PROGRESS")return {label:"En gestión",tone:"working",detail:"La responsable está revisando el pedido."};
  if(value==="WAITING")return {label:"En espera",tone:"waiting",detail:"La gestión quedó pendiente de información o respuesta."};
  if(value==="BLOCKED")return {label:"Con novedad",tone:"blocked",detail:"Existe una situación que debe resolverse."};
  return {label:"Pendiente",tone:"pending",detail:"La gestión aún no ha comenzado."};
}

function renderReleaseManagement(host,data,{reload,refreshLists}){
  const order=data.order;
  const task=activeTask(data);
  const actions=actionCodes(data);
  const validation=latestValidation(data,order.current_step_code);
  const closed=validation?.decision==="APPROVED";
  const status=statusLabel(task,closed);
  const canStart=actions.has("CLAIM")||actions.has("START")||actions.has("RESUME");
  const started=["IN_PROGRESS","WAITING","BLOCKED"].includes(task?.status)||closed;
  const area=order.current_step_code==="CARTERA"?"Cartera":"Caja";
  const reason=order.current_step_code==="CARTERA"?"El cliente fue marcado con mora en crédito.":"El pedido fue marcado como retenido por Caja.";

  host.innerHTML=`
    <div class="modal-overlay simple-process-overlay">
      <section class="modal simple-process-modal financial-simple-modal">
        <header class="modal-head simple-process-head">
          <div><span class="wizard-kicker">${area}</span><h3>${fmt.escape(order.order_number)}</h3><p>${fmt.escape(order.client_name)} · ${fmt.escape(fmt.label(order.order_type_code))}</p></div>
          <button class="icon-btn" data-close aria-label="Cerrar">×</button>
        </header>
        <div class="modal-body simple-process-body">
          <section class="financial-reason"><span>Motivo de ingreso</span><strong>${fmt.escape(reason)}</strong></section>
          <section class="financial-current-state ${status.tone}">
            <div><small>Estado actual</small><strong>${fmt.escape(status.label)}</strong><p>${fmt.escape(status.detail)}</p></div>
            <span class="financial-state-dot"></span>
          </section>
          <section class="financial-action-stack">
            <button class="btn btn-primary financial-main-button" data-financial-start ${canStart?"":"disabled"}>
              <span>1</span><div><strong>${started?"Gestión iniciada":"Iniciar gestión"}</strong><small>${started?"El pedido ya fue tomado por el área.":"Toma el pedido para comenzar."}</small></div>
            </button>
            <button class="btn financial-main-button ${started&&!closed?"btn-primary":"btn-ghost"}" data-financial-status ${started&&!closed?"":"disabled"}>
              <span>2</span><div><strong>Estado</strong><small>Actualiza la situación o marca la gestión como cerrada.</small></div>
            </button>
            <button class="btn financial-main-button ${closed?"btn-success":"btn-ghost"}" data-financial-release ${closed?"":"disabled"}>
              <span>3</span><div><strong>Liberar pedido</strong><small>Envía el pedido directamente a Recepción de pedidos.</small></div>
            </button>
          </section>
          ${validation?`<section class="financial-last-update"><small>Última actualización</small><strong>${fmt.escape(validation.notes||"Gestión actualizada")}</strong><span>${fmt.date(validation.created_at)}</span></section>`:""}
          <details class="simple-details"><summary>Ver información completa del pedido</summary>${orderDetails(data)}</details>
        </div>
        <footer class="modal-foot"><button class="btn btn-ghost" data-close>Cerrar</button></footer>
      </section>
    </div>`;

  host.querySelectorAll("[data-close]").forEach(button=>button.onclick=()=>closeHost(host));
  host.querySelector("[data-financial-start]")?.addEventListener("click",()=>guarded(async()=>{
    if(started)return;
    await begin(data);
    toast("Gestión iniciada.","success");refresh(refreshLists);await reload();
  }));
  host.querySelector("[data-financial-status]")?.addEventListener("click",()=>openStateDialog(data,{reload,refreshLists}));
  host.querySelector("[data-financial-release]")?.addEventListener("click",()=>guarded(async()=>{
    await releaseToReception(data);
    toast("Pedido liberado y enviado a Recepción de pedidos.","success",6000);refresh(refreshLists);closeHost(host);
  }));
}

async function begin(data){
  let latest=await api.getOrder(data.order.id);
  let actions=actionCodes(latest);
  if(actions.has("CLAIM")){
    await api.executeAction(latest.order.id,"CLAIM",{detail:"Pedido tomado por el área financiera"},latest.order.version);
    latest=await api.getOrder(latest.order.id);actions=actionCodes(latest);
  }
  if(actions.has("START"))await api.executeAction(latest.order.id,"START",{detail:"Gestión financiera iniciada"},latest.order.version);
  else if(actions.has("RESUME"))await api.executeAction(latest.order.id,"RESUME",{detail:"Gestión financiera retomada"},latest.order.version);
}

function openStateDialog(data,{reload,refreshLists}){
  modal({
    title:"Actualizar estado",
    confirmLabel:"Guardar estado",
    size:"wide",
    body:`<div class="financial-status-choices">
      ${stateChoice("IN_PROGRESS","En gestión","La revisión continúa activa.",true)}
      ${stateChoice("WAITING","En espera","Falta información o una respuesta.")}
      ${stateChoice("NOVELTY","Con novedad","Existe una situación que impide continuar.")}
      ${stateChoice("CLOSED","Cerrado","La gestión terminó y el pedido puede liberarse.")}
    </div><div class="field"><label>Observación</label><textarea class="control" name="notes" placeholder="Describe brevemente la actualización"></textarea></div>`,
    onConfirm:async dialog=>{
      const state=dialog.querySelector('[name="financialState"]:checked')?.value;
      const notes=dialog.querySelector('[name="notes"]').value.trim();
      if(!state)throw new Error("Selecciona un estado.");
      if(["WAITING","NOVELTY"].includes(state)&&!notes)throw new Error("Escribe el motivo de la espera o novedad.");
      await applyState(data,state,notes);
      toast(state==="CLOSED"?"Gestión cerrada. Ya puedes liberar el pedido.":"Estado actualizado.","success");
      refresh(refreshLists);setTimeout(()=>reload(),80);
    }
  });
}

function stateChoice(value,title,detail,checked=false){
  return `<label class="financial-state-choice"><input type="radio" name="financialState" value="${value}" ${checked?"checked":""}><span><strong>${title}</strong><small>${detail}</small></span></label>`;
}

async function applyState(data,state,notes){
  let latest=await api.getOrder(data.order.id);
  let actions=actionCodes(latest);
  if(state==="IN_PROGRESS"){
    if(actions.has("RESUME"))await api.executeAction(latest.order.id,"RESUME",{detail:notes||"Gestión retomada"},latest.order.version);
    else if(actions.has("COMMENT")&&notes)await api.executeAction(latest.order.id,"COMMENT",{body:notes,commentType:"STATUS",visibility:"INTERNAL"},latest.order.version);
    return;
  }
  if(state==="CLOSED"){
    if(actions.has("RESUME")){
      await api.executeAction(latest.order.id,"RESUME",{detail:"Gestión retomada para cierre"},latest.order.version);
      latest=await api.getOrder(latest.order.id);
    }
    await api.saveFinancialValidation(latest.order.id,{validationType:latest.order.current_step_code,decision:"APPROVED",notes:notes||"Gestión cerrada y lista para liberar",metadata:{operationalStatus:"CLOSED"}});
    return;
  }
  if(state==="NOVELTY"&&actions.has("COMMENT")){
    await api.executeAction(latest.order.id,"COMMENT",{body:notes,commentType:"NOVELTY",visibility:"INTERNAL"},latest.order.version);
    latest=await api.getOrder(latest.order.id);actions=actionCodes(latest);
  }
  if(actions.has("WAIT"))await api.executeAction(latest.order.id,"WAIT",{reason:notes},latest.order.version);
}

async function completeChecklist(data,note){
  const task=activeTask(data);
  const pending=(data.checklist||[]).filter(item=>item.task_id===task?.id&&item.required&&!item.completed);
  for(const item of pending)await api.updateChecklist(task.id,item.item_code,true,note);
}

async function releaseToReception(data){
  let latest=await api.getOrder(data.order.id);
  const step=latest.order.current_step_code;
  const validation=latestValidation(latest,step);
  if(validation?.decision!=="APPROVED")throw new Error("Primero debes cerrar la gestión.");
  if(actionCodes(latest).has("RESUME")){
    await api.executeAction(latest.order.id,"RESUME",{detail:"Gestión retomada para liberar"},latest.order.version);
    latest=await api.getOrder(latest.order.id);
  }
  await completeChecklist(latest,"Confirmado al liberar el pedido");
  latest=await api.getOrder(latest.order.id);
  if(!actionCodes(latest).has("COMPLETE"))throw new Error("El pedido no está listo para liberarse.");
  await api.executeAction(latest.order.id,"COMPLETE",{detail:"Gestión cerrada y pedido liberado a Recepción"},latest.order.version);
}

function renderCashInvoice(host,data,{reload,refreshLists}){
  const order=data.order;
  const task=activeTask(data);
  const actions=actionCodes(data);
  const accepted=task?.status==="IN_PROGRESS";
  const invoice=registeredInvoice(data);
  const canAccept=actions.has("CLAIM")||actions.has("START")||actions.has("RESUME");

  host.innerHTML=`
    <div class="modal-overlay simple-process-overlay">
      <section class="modal simple-process-modal financial-simple-modal">
        <header class="modal-head simple-process-head">
          <div><span class="wizard-kicker">Caja · Facturación PVN</span><h3>${fmt.escape(order.order_number)}</h3><p>${fmt.escape(order.client_name)} · ${fmt.escape(fmt.route(order.delivery_route_code))}</p></div>
          <button class="icon-btn" data-close aria-label="Cerrar">×</button>
        </header>
        <div class="modal-body simple-process-body">
          <section class="cash-invoice-intro"><strong>Pedido alistado</strong><p>Caja solo debe aceptar el pedido, subir la factura y enviarlo a la logística correspondiente.</p></section>
          <section class="cash-invoice-steps">
            ${invoiceStep(1,"Aceptar pedido",accepted,"Toma el pedido para iniciar la facturación.",!accepted&&canAccept,"accept")}
            ${invoiceStep(2,"Subir factura",Boolean(invoice),invoice?`Factura ${invoice.invoice_number} registrada.`:"Adjunta el PDF y registra el número de factura.",accepted&&!invoice,"invoice")}
            ${invoiceStep(3,"Enviar a logística",false,`El pedido irá a ${fmt.route(order.delivery_route_code)}.`,accepted&&Boolean(invoice),"send")}
          </section>
          ${invoice?`<section class="invoice-confirmed"><span>Factura registrada</span><strong>${fmt.escape(invoice.invoice_number)}</strong><small>${fmt.date(invoice.invoice_date)}${invoice.amount?` · ${fmt.number(invoice.amount)} COP`:""}</small></section>`:""}
          <details class="simple-details"><summary>Ver información completa del pedido</summary>${orderDetails(data)}</details>
        </div>
        <footer class="modal-foot"><button class="btn btn-ghost" data-close>Cerrar</button></footer>
      </section>
    </div>`;

  host.querySelectorAll("[data-close]").forEach(button=>button.onclick=()=>closeHost(host));
  host.querySelector('[data-cash-action="accept"]')?.addEventListener("click",()=>guarded(async()=>{
    await begin(data);toast("Pedido aceptado por Caja.","success");refresh(refreshLists);await reload();
  }));
  host.querySelector('[data-cash-action="invoice"]')?.addEventListener("click",()=>openInvoiceUpload(data,{reload,refreshLists}));
  host.querySelector('[data-cash-action="send"]')?.addEventListener("click",()=>guarded(async()=>{
    let latest=await api.getOrder(order.id);
    if(!registeredInvoice(latest))throw new Error("Primero debes subir la factura.");
    await completeChecklist(latest,"Factura verificada por Caja");
    latest=await api.getOrder(order.id);
    if(!actionCodes(latest).has("COMPLETE"))throw new Error("El pedido no está listo para enviarse a logística.");
    await api.executeAction(order.id,"COMPLETE",{detail:"Factura cargada y pedido enviado a logística"},latest.order.version);
    toast(`Pedido enviado a ${fmt.route(order.delivery_route_code)}.`,"success",6000);refresh(refreshLists);closeHost(host);
  }));
}

function invoiceStep(number,title,done,detail,enabled,action){
  return `<button type="button" class="cash-invoice-step ${done?"done":enabled?"active":"locked"}" data-cash-action="${action}" ${enabled?"":"disabled"}><span>${done?"✓":number}</span><div><strong>${fmt.escape(title)}</strong><small>${fmt.escape(detail)}</small></div></button>`;
}

function openInvoiceUpload(data,{reload,refreshLists}){
  modal({
    title:"Subir factura",
    confirmLabel:"Guardar factura",
    size:"wide",
    body:`<div class="form-grid"><div class="field full"><label>Factura PDF *</label><input class="control" name="file" type="file" accept="application/pdf,.pdf" required></div><div class="field"><label>Número de factura *</label><input class="control" name="invoiceNumber" required autofocus></div><div class="field"><label>Fecha *</label><input class="control" name="invoiceDate" type="date" value="${new Date().toISOString().slice(0,10)}" required></div><div class="field"><label>Valor</label><input class="control" name="amount" type="number" min="0" step="any"></div></div>`,
    onConfirm:async dialog=>{
      const file=dialog.querySelector('[name="file"]').files[0];
      const invoiceNumber=dialog.querySelector('[name="invoiceNumber"]').value.trim();
      const invoiceDate=dialog.querySelector('[name="invoiceDate"]').value;
      const amount=dialog.querySelector('[name="amount"]').value;
      if(!file)throw new Error("Selecciona la factura en PDF.");
      const uploaded=await uploadOrderFile(data.order.id,file,"INVOICE",activeTask(data)?.id,data.order.order_number);
      const payload={invoiceNumber,invoiceDate,currency:"COP",driveFileRecordId:uploaded?.file?.id||null,metadata:{source:"CAJA_FACTURACION",fileName:file.name}};
      if(amount)payload.amount=amount;
      await api.saveInvoice(data.order.id,payload);
      toast("Factura cargada correctamente.","success");refresh(refreshLists);setTimeout(()=>reload(),80);
    }
  });
}

function orderDetails(data){
  const order=data.order;
  const items=data.items||[];
  return `<div class="simple-detail-sections"><section><h4>Información principal</h4><div class="detail-grid">${info("Cliente",order.client_name)}${info("Tipo",fmt.label(order.order_type_code))}${info("Pago",fmt.payment(order.payment_condition_code))}${info("Entrega",fmt.route(order.delivery_route_code))}${info("Prioridad",fmt.label(order.priority))}</div></section><section><h4>Materiales</h4>${items.length?`<div class="table-wrap"><table><thead><tr><th>Material</th><th>Cantidad</th><th>Corte</th></tr></thead><tbody>${items.map(item=>`<tr><td>${fmt.escape(item.sku||item.description)}</td><td>${fmt.number(item.quantity,3)} ${fmt.escape(item.unit)}</td><td>${item.requires_cut?"Sí":"No"}</td></tr>`).join("")}</tbody></table></div>`:"<p>Sin materiales registrados.</p>"}</section></div>`;
}
function info(label,value){return `<div class="info-box"><label>${fmt.escape(label)}</label><strong>${fmt.escape(value??"—")}</strong></div>`}
