import {api} from "../services/api.js";
import {fmt} from "../core/format.js";
import {modal,toast} from "../core/ui.js";
import {uploadOrderFile} from "../services/drive.js";
import {parallelWorkFooter} from "./active-work.js";

const RELEASE_STEPS=new Set(["CARTERA","CAJA"]);
const BILLING_STEPS=new Set(["FACTURACION","CAJA_FACTURACION"]);

export function isFinancialFlowStep(data){
  const step=data?.order?.current_step_code;
  return RELEASE_STEPS.has(step)||BILLING_STEPS.has(step);
}

export function renderFinancialFlow(host,data,{reload,refreshLists}){
  if(data.order.current_step_code==="CAJA_FACTURACION")return renderCashInvoice(host,data,{reload,refreshLists});
  if(data.order.current_step_code==="FACTURACION")return renderLogisticsBilling(host,data,{reload,refreshLists});
  return renderReleaseManagement(host,data,{reload,refreshLists});
}

function activeTask(data){
  return (data.tasks||[]).find(task=>["QUEUED","ASSIGNED","IN_PROGRESS","WAITING","BLOCKED"].includes(task.status))||null;
}
function actionCodes(data){return new Set((data.actions?.actions||[]).map(action=>action.code))}
function latestValidation(data,step){
  return [...(data.financialValidations||[])].reverse().find(row=>row.validation_type===step)||null;
}
function currentTaskFiles(data){
  const task=activeTask(data);
  return task?(data.files||[]).filter(file=>file.task_id===task.id):[];
}
function registeredInvoice(data){
  const task=activeTask(data);
  const taskFiles=currentTaskFiles(data);
  const fileIds=new Set(taskFiles.map(file=>file.id));
  const rows=[...(data.invoices||[])].reverse().filter(row=>row.status==="REGISTERED");
  if(!task)return rows[0]||null;
  return rows.find(row=>(row.drive_file_id&&fileIds.has(row.drive_file_id))||row.metadata?.taskId===task.id)||null;
}
function pvpAnnex(data){return [...currentTaskFiles(data)].reverse().find(file=>String(file.file_category||"").toUpperCase()==="PVP_ANNEX")||null}
function isCashOrder(order){return ["PVN","PNV"].includes(String(order?.order_type_code||"").toUpperCase())}
function isPvpOrder(order){return String(order?.order_type_code||"").toUpperCase()==="PVP"}
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
        ${parallelWorkFooter(order.current_step_code)}
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

function renderLogisticsBilling(host,data,{reload,refreshLists}){
  const order=data.order;
  const task=activeTask(data);
  const actions=actionCodes(data);
  const accepted=task?.status==="IN_PROGRESS";
  const cashOrder=isCashOrder(order);
  const pvp=isPvpOrder(order);
  const invoice=registeredInvoice(data);
  const annex=pvpAnnex(data);
  const document=pvp?annex:invoice;
  const canAccept=actions.has("CLAIM")||actions.has("START")||actions.has("RESUME");
  const canRouteToCash=cashOrder&&!document;
  const documentTitle=pvp?"Anexo PVP":"Factura";
  const documentDetail=pvp
    ?(annex?`Anexo ${annex.file_name} cargado.`:"Adjunta el archivo comercial denominado Anexo PVP.")
    :(invoice?`Factura ${invoice.invoice_number} registrada.`:"Adjunta la factura mediante Google Drive.");

  host.innerHTML=`
    <div class="modal-overlay simple-process-overlay">
      <section class="modal simple-process-modal financial-simple-modal billing-process-modal">
        <header class="modal-head simple-process-head">
          <div><span class="wizard-kicker">Facturación · Logística</span><h3>${fmt.escape(order.order_number)}</h3><p>${fmt.escape(order.client_name)} · ${fmt.escape(fmt.label(order.order_type_code))} · ${fmt.escape(fmt.route(order.delivery_route_code))}</p></div>
          <button class="icon-btn" data-close aria-label="Cerrar">×</button>
        </header>
        <div class="modal-body simple-process-body">
          <section class="billing-process-intro ${cashOrder?"cash-warning":""}">
            <div><span>${cashOrder?"Pedido pagado de contado":"Documento requerido"}</span><strong>${cashOrder?"Este pedido debe facturarlo Caja":pvp?"Carga de Anexo PVP":"Facturación normal de Logística"}</strong><p>${cashOrder?"El ERP intenta enviarlo automáticamente a Caja. Usa Enviar a Caja cuando haya llegado por error a Facturación.":pvp?"Para los pedidos PVP no se registra factura en este paso; se adjunta el Anexo PVP.":"Los pedidos PVC y PVE conservan el proceso normal de factura y envío a despacho."}</p></div>
          </section>

          ${!accepted?`<section class="billing-entry-actions ${cashOrder?"two-options":""}">
            <button type="button" class="billing-entry-card accept" data-billing-action="accept" ${canAccept?"":"disabled"}>
              <span>1</span><div><strong>Aceptar pedido</strong><small>${cashOrder?"Continúa aquí solo si Logística debe resolverlo manualmente.":"Toma el pedido para cargar el documento correspondiente."}</small></div>
            </button>
            ${cashOrder?`<button type="button" class="billing-entry-card cash" data-billing-action="cash" ${canRouteToCash?"":"disabled"}>
              <span>→</span><div><strong>Enviar a Caja</strong><small>Corrige el enrutamiento y mueve la facturación a Caja.</small></div>
            </button>`:""}
          </section>`:`<section class="cash-invoice-steps billing-document-steps">
            ${invoiceStep(1,"Pedido aceptado",true,"La gestión fue tomada por el responsable.",false,"accepted")}
            ${invoiceStep(2,`Subir ${documentTitle}`,Boolean(document),documentDetail,!document,pvp?"annex":"invoice")}
            ${invoiceStep(3,"Enviar a despacho",false,`El pedido continuará a ${fmt.route(order.delivery_route_code)}.`,Boolean(document),"send")}
          </section>`}

          ${document?billingDocumentSummary(document,{pvp}):""}
          <details class="simple-details"><summary>Ver información completa del pedido</summary>${orderDetails(data)}</details>
        </div>
        ${parallelWorkFooter(order.current_step_code)}
      </section>
    </div>`;

  host.querySelectorAll("[data-close]").forEach(button=>button.onclick=()=>closeHost(host));
  host.querySelector('[data-billing-action="accept"]')?.addEventListener("click",()=>guarded(async()=>{
    await begin(data);toast("Pedido aceptado en Facturación.","success");refresh(refreshLists);await reload();
  }));
  host.querySelector('[data-billing-action="cash"]')?.addEventListener("click",()=>guarded(async()=>{
    await api.routeBillingToCash(order.id,"Pedido pagado de contado enviado manualmente a Caja");
    toast("Pedido enviado a Caja.","success",6000);refresh(refreshLists);closeHost(host);
  }));
  host.querySelector('[data-cash-action="invoice"]')?.addEventListener("click",()=>openInvoiceUpload(data,{reload,refreshLists,source:"LOGISTICA_FACTURACION"}));
  host.querySelector('[data-cash-action="annex"]')?.addEventListener("click",()=>openPvpAnnexUpload(data,{reload,refreshLists}));
  host.querySelector('[data-cash-action="send"]')?.addEventListener("click",()=>guarded(()=>completeBillingAndDispatch(data,{refreshLists,host,pvp})));
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
      <section class="modal simple-process-modal financial-simple-modal billing-process-modal">
        <header class="modal-head simple-process-head">
          <div><span class="wizard-kicker">Caja · Pedido pagado de contado</span><h3>${fmt.escape(order.order_number)}</h3><p>${fmt.escape(order.client_name)} · ${fmt.escape(fmt.route(order.delivery_route_code))}</p></div>
          <button class="icon-btn" data-close aria-label="Cerrar">×</button>
        </header>
        <div class="modal-body simple-process-body">
          <section class="cash-invoice-intro"><strong>Pedido pagado de contado</strong><p>Caja debe aceptar el pedido, cargar la factura mediante Google Drive y enviarlo al despacho correspondiente.</p></section>
          <section class="cash-invoice-steps">
            ${invoiceStep(1,"Aceptar pedido",accepted,"Toma el pedido para iniciar la facturación.",!accepted&&canAccept,"accept")}
            ${invoiceStep(2,"Subir factura",Boolean(invoice),invoice?`Factura ${invoice.invoice_number} registrada.`:"Adjunta el PDF y registra los datos de la factura.",accepted&&!invoice,"invoice")}
            ${invoiceStep(3,"Enviar a despacho",false,`El pedido irá a ${fmt.route(order.delivery_route_code)}.`,accepted&&Boolean(invoice),"send")}
          </section>
          ${invoice?billingDocumentSummary(invoice,{pvp:false}):""}
          <details class="simple-details"><summary>Ver información completa del pedido</summary>${orderDetails(data)}</details>
        </div>
        ${parallelWorkFooter(order.current_step_code)}
      </section>
    </div>`;

  host.querySelectorAll("[data-close]").forEach(button=>button.onclick=()=>closeHost(host));
  host.querySelector('[data-cash-action="accept"]')?.addEventListener("click",()=>guarded(async()=>{
    await begin(data);toast("Pedido aceptado por Caja.","success");refresh(refreshLists);await reload();
  }));
  host.querySelector('[data-cash-action="invoice"]')?.addEventListener("click",()=>openInvoiceUpload(data,{reload,refreshLists,source:"CAJA_FACTURACION"}));
  host.querySelector('[data-cash-action="send"]')?.addEventListener("click",()=>guarded(()=>completeBillingAndDispatch(data,{refreshLists,host,pvp:false})));
}

function invoiceStep(number,title,done,detail,enabled,action){
  return `<button type="button" class="cash-invoice-step ${done?"done":enabled?"active":"locked"}" data-cash-action="${action}" ${enabled?"":"disabled"}><span>${done?"✓":number}</span><div><strong>${fmt.escape(title)}</strong><small>${fmt.escape(detail)}</small></div></button>`;
}

function billingDocumentSummary(document,{pvp}){
  if(pvp)return `<section class="invoice-confirmed pvp-annex-confirmed"><span>Anexo PVP cargado</span><strong>${fmt.escape(document.file_name||"Anexo PVP")}</strong><small>${fmt.date(document.created_at)}</small></section>`;
  return `<section class="invoice-confirmed"><span>Factura registrada</span><strong>${fmt.escape(document.invoice_number)}</strong><small>${fmt.date(document.invoice_date)}${document.amount?` · ${fmt.number(document.amount)} COP`:""}</small></section>`;
}

function openInvoiceUpload(data,{reload,refreshLists,source}){
  modal({
    title:"Subir factura",
    confirmLabel:"Guardar factura",
    size:"wide",
    body:`<div class="billing-upload-note"><strong>Carga directa mediante Google Drive</strong><p>Selecciona la factura en PDF. El ERP registrará automáticamente el nombre y la fecha de carga.</p></div><div class="field"><label>Factura PDF *</label><input class="control" name="file" type="file" accept="application/pdf,.pdf" required autofocus></div>`,
    onConfirm:async dialog=>{
      const file=dialog.querySelector('[name="file"]').files[0];
      if(!file)throw new Error("Selecciona la factura en PDF.");
      const task=activeTask(data);
      const uploaded=await uploadOrderFile(data.order.id,file,"INVOICE",task?.id,data.order.order_number);
      const invoiceNumber=file.name.replace(/\.[^.]+$/u,"").trim()||`FACTURA-${data.order.order_number}`;
      await api.saveInvoice(data.order.id,{
        invoiceNumber,
        invoiceDate:new Date().toISOString().slice(0,10),
        currency:"COP",
        driveFileRecordId:uploaded?.file?.id||null,
        metadata:{source,fileName:file.name,taskId:task?.id||null,automaticRecord:true}
      });
      toast("Factura cargada correctamente.","success");refresh(refreshLists);setTimeout(()=>reload(),80);
    }
  });
}

function openPvpAnnexUpload(data,{reload,refreshLists}){
  modal({
    title:"Subir Anexo PVP",
    confirmLabel:"Guardar Anexo PVP",
    size:"wide",
    body:`<div class="billing-upload-note"><strong>Documento requerido para PVP</strong><p>Adjunta el archivo comercial correspondiente. En el ERP quedará identificado únicamente como Anexo PVP.</p></div><div class="field"><label>Anexo PVP *</label><input class="control" name="file" type="file" required autofocus></div>`,
    onConfirm:async dialog=>{
      const file=dialog.querySelector('[name="file"]').files[0];
      if(!file)throw new Error("Selecciona el Anexo PVP.");
      await uploadOrderFile(data.order.id,file,"PVP_ANNEX",activeTask(data)?.id,data.order.order_number);
      toast("Anexo PVP cargado correctamente.","success");refresh(refreshLists);setTimeout(()=>reload(),80);
    }
  });
}

async function completeBillingAndDispatch(data,{refreshLists,host,pvp}){
  let latest=await api.getOrder(data.order.id);
  if(pvp){
    if(!pvpAnnex(latest))throw new Error("Primero debes subir el Anexo PVP.");
  }else if(!registeredInvoice(latest))throw new Error("Primero debes subir la factura.");
  await completeChecklist(latest,pvp?"Anexo PVP verificado":"Factura verificada");
  latest=await api.getOrder(data.order.id);
  if(!actionCodes(latest).has("COMPLETE"))throw new Error("El pedido no está listo para enviarse a despacho.");
  await api.executeAction(data.order.id,"COMPLETE",{detail:pvp?"Anexo PVP cargado y pedido enviado a despacho":"Factura cargada y pedido enviado a despacho"},latest.order.version);
  toast(`Pedido enviado a ${fmt.route(data.order.delivery_route_code)}.`,"success",6000);refresh(refreshLists);closeHost(host);
}

function orderDetails(data){
  const order=data.order;
  const items=data.items||[];
  return `<div class="simple-detail-sections"><section><h4>Información principal</h4><div class="detail-grid">${info("Cliente",order.client_name)}${info("Tipo",fmt.label(order.order_type_code))}${info("Pago",fmt.payment(order.payment_condition_code))}${info("Entrega",fmt.route(order.delivery_route_code))}${info("Prioridad",fmt.label(order.priority))}</div></section><section><h4>Materiales</h4>${items.length?`<div class="table-wrap"><table><thead><tr><th>Material</th><th>Cantidad</th><th>Corte</th></tr></thead><tbody>${items.map(item=>`<tr><td>${fmt.escape(item.sku||item.description)}</td><td>${fmt.number(item.quantity,3)} ${fmt.escape(item.unit)}</td><td>${item.requires_cut?"Sí":"No"}</td></tr>`).join("")}</tbody></table></div>`:"<p>Sin materiales registrados.</p>"}</section></div>`;
}
function info(label,value){return `<div class="info-box"><label>${fmt.escape(label)}</label><strong>${fmt.escape(value??"—")}</strong></div>`}
