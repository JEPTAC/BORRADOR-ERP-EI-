import {api} from "../services/api.js";
import {state} from "../core/state.js";
import {fmt} from "../core/format.js";
import {toast,loading} from "../core/ui.js";
import {downloadDriveFile} from "../services/drive.js";
import {readOrderPdf} from "../services/pdf-order-reader.js";
import {materialPickerHtml,bindMaterialPicker,readMaterialPicker,resolveMaterialLines} from "../services/materials.js";
import {parallelWorkFooter} from "./active-work.js";

const DRAFT_PREFIX="erp:recepcion-pedido:v10.6:";

export function isOrderReceptionStep(data){
  return data?.order?.current_step_code==="RECEPCION_PEDIDO";
}

export function renderOrderReception(host,data,{reload,refreshLists}={}){
  const task=activeTask(data);
  const actions=actionCodes(data);
  const canStart=actions.has("CLAIM")||actions.has("START")||actions.has("RESUME");
  const inProgress=task?.status==="IN_PROGRESS";

  if(!task){
    host.innerHTML=baseShell(data,`<div class="reception-empty-state"><strong>El pedido no tiene una tarea activa.</strong><p>Solicita a la jefatura logística revisar el flujo.</p></div>`,false);
    bindClose(host);
    return;
  }

  if(!inProgress){
    const label=task.status==="WAITING"||task.status==="BLOCKED"?"Retomar pedido":"Tomar pedido";
    const detail=task.status==="WAITING"||task.status==="BLOCKED"
      ?"La recepción quedó pausada. Retómala para continuar exactamente donde estaba."
      :"Al tomarlo quedará asignado a tu usuario y nadie podrá procesarlo al mismo tiempo.";
    const blocked=!canStart;
    host.innerHTML=baseShell(data,`
      <section class="reception-take-card">
        <span class="reception-step-tag">Paso 1 de 4</span>
        <h4>${fmt.escape(label)}</h4>
        <p>${fmt.escape(detail)}</p>
        <button type="button" class="btn btn-primary reception-take-button" data-take-order ${blocked?"disabled":""}>${fmt.escape(label)}</button>
        ${blocked?`<div class="reception-assigned-warning">Este pedido está asignado a <strong>${fmt.escape(assigneeName(data))}</strong> y tu usuario no tiene permiso para tomarlo.</div>`:""}
      </section>`,false);
    bindClose(host);
    host.querySelector("[data-take-order]")?.addEventListener("click",async event=>{
      event.currentTarget.disabled=true;
      try{
        await beginReception(data);
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
    host.innerHTML=baseShell(data,`<section class="reception-take-card"><span class="reception-step-tag">Pedido en gestión</span><h4>Este pedido está siendo atendido</h4><p>La recepción permanece bloqueada para evitar que dos usuarios modifiquen las líneas o las asignaciones al mismo tiempo.</p><div class="reception-assigned-warning">Responsable actual: <strong>${fmt.escape(assigneeName(data))}</strong></div></section>`,false);
    bindClose(host);
    return;
  }

  const draft=loadDraft(data);
  renderWorkbench(host,data,draft,{reload,refreshLists});
}

function renderWorkbench(host,data,draft,callbacks){
  const content=draft.stage==="PDF"?pdfStage(data,draft):draft.stage==="EDIT"?editStage(data,draft):draft.stage==="ASSIGN"?assignmentStageLoading(data,draft):reviewStage(data,draft);
  host.innerHTML=baseShell(data,`
    ${progressBar(draft.stage)}
    <div class="reception-workspace" data-reception-workspace>${content}</div>`,true);
  bindClose(host);
  bindStage(host,data,draft,callbacks);
}

function baseShell(data,content,showDetails){
  const order=data.order;
  return `<div class="modal-overlay simple-process-overlay">
    <section class="modal simple-process-modal wide reception-process-modal" data-order-id="${fmt.escape(data.order.id)}">
      <header class="modal-head simple-process-head reception-process-head">
        <div><span class="wizard-kicker">Recepción de pedidos</span><h3>${fmt.escape(order.order_number)}</h3><p>${fmt.escape(order.client_name)} · ${fmt.escape(fmt.label(order.order_type_code))}</p></div>
        <button class="icon-btn" data-close aria-label="Cerrar">×</button>
      </header>
      <div class="modal-body simple-process-body reception-process-body">
        <section class="reception-order-strip">
          <div><small>Responsable actual</small><strong>${fmt.escape(assigneeName(data))}</strong></div>
          <div><small>Pago</small><strong>${fmt.escape(fmt.payment(order.payment_condition_code))}</strong></div>
          <div><small>Entrega</small><strong>${fmt.escape(fmt.route(order.delivery_route_code))}</strong></div>
          <div><small>Archivos del asesor</small><strong>${(data.files||[]).length}</strong></div>
        </section>
        ${content}
        ${showDetails?`<details class="simple-details reception-full-details"><summary>Ver información completa del pedido</summary>${fullDetails(data)}</details>`:""}
      </div>
      ${parallelWorkFooter(order.current_step_code)}
    </section>
  </div>`;
}

function reviewStage(data){
  const items=data.items||[];
  return `<section class="reception-stage-card">
    <div class="reception-stage-heading"><div><span class="reception-step-tag">Paso 2 de 4</span><h4>Revisa lo que cargó el asesor</h4><p>Consulta la información y los soportes antes de decidir cómo continuar.</p></div></div>
    <div class="reception-advisor-grid">
      <article><small>Asesor</small><strong>${fmt.escape(data.order.seller_name||data.order.metadata?.sellerName||"Registrado en el pedido")}</strong></article>
      <article><small>Cliente</small><strong>${fmt.escape(data.order.client_name)}</strong></article>
      <article><small>Referencia externa</small><strong>${fmt.escape(data.order.external_reference||"—")}</strong></article>
      <article><small>Materiales informados</small><strong>${items.length}</strong></article>
    </div>
    ${advisorFiles(data.files||[])}
    <div class="reception-current-lines">${readOnlyLines(items)}</div>
    <div class="reception-decision-grid">
      <button type="button" class="reception-decision-card correct" data-info-correct>
        <span>✓</span><strong>Información correcta</strong><small>Conservar exactamente las líneas registradas por el asesor.</small>
      </button>
      <button type="button" class="reception-decision-card assign" data-info-assign>
        <span>PDF</span><strong>Asignar información</strong><small>Leer el PDF, identificar líneas y cortes, y corregir el resultado.</small>
      </button>
    </div>
  </section>`;
}

function pdfStage(data,draft){
  const pdfs=pdfFiles(data.files||[]);
  return `<section class="reception-stage-card">
    <div class="reception-stage-heading"><div><span class="reception-step-tag">Paso 2 de 4</span><h4>Leer el pedido en PDF</h4><p>El lector reutiliza el motor de Trazabilidad Logística y deja el resultado totalmente editable.</p></div><button type="button" class="btn btn-ghost" data-back-review>Volver</button></div>
    <div class="reception-pdf-panel">
      ${pdfs.length?`<div class="field"><label>PDF cargado por el asesor</label><select class="control" data-source-pdf>${pdfs.map(file=>`<option value="${fmt.escape(file.drive_file_id)}" ${file.drive_file_id===draft.sourceFileId?"selected":""}>${fmt.escape(file.file_name)}</option>`).join("")}</select></div>`:`<div class="reception-file-warning"><strong>No hay un PDF registrado en el pedido.</strong><p>Puedes seleccionar el archivo manualmente sin modificar los soportes existentes.</p></div>`}
      <div class="reception-pdf-actions">
        ${pdfs.length?'<button type="button" class="btn btn-primary" data-read-drive-pdf>Leer PDF del asesor</button>':""}
        <label class="btn btn-ghost reception-file-picker">Seleccionar PDF manualmente<input type="file" accept="application/pdf,.pdf" data-local-pdf hidden></label>
      </div>
      <div class="reception-reader-status" data-reader-status>El lector identificará referencias, descripciones, cantidades, unidades y posibles cortes.</div>
    </div>
  </section>`;
}

function editStage(data,draft){
  const rows=(draft.lines||[]).map((line,index)=>editableLine(line,index)).join("");
  return `<section class="reception-stage-card">
    <div class="reception-stage-heading"><div><span class="reception-step-tag">Paso 3 de 4</span><h4>Validar líneas detectadas</h4><p>Corrige, agrega o elimina cualquier dato antes de confirmar la información.</p></div><button type="button" class="btn btn-ghost" data-back-pdf>Volver al PDF</button></div>
    <div class="reception-reader-summary"><strong>${draft.lines?.length||0} línea(s) detectada(s)</strong><span>${fmt.escape(draft.sourceFileName||"Carga manual")}</span></div>
    <div class="reception-lines-editor" data-lines-editor>${rows||'<div class="reception-file-warning"><strong>No se detectaron líneas.</strong><p>Agrega la primera línea manualmente.</p></div>'}</div>
    <div class="reception-editor-actions"><button type="button" class="btn btn-ghost" data-add-line>＋ Agregar línea</button><button type="button" class="btn btn-primary" data-confirm-lines>Confirmar información</button></div>
    ${draft.rawPreview?`<details class="reception-raw-text"><summary>Ver texto extraído del PDF</summary><pre>${fmt.escape(draft.rawPreview)}</pre></details>`:""}
  </section>`;
}

function assignmentStageLoading(){
  return `<section class="reception-stage-card"><div class="reception-stage-heading"><div><span class="reception-step-tag">Paso 4 de 4</span><h4>Asignar responsables</h4><p>Selecciona quién alistará la mercancía y, cuando aplique, quién realizará los cortes.</p></div></div><div data-assignment-content>${loading("Consultando auxiliares disponibles…")}</div></section>`;
}

function assignmentStage(data,draft,pickingPool,cutPool){
  const hasCuts=(draft.lines||[]).some(line=>line.requiresCut);
  return `<section class="reception-stage-card">
    <div class="reception-stage-heading"><div><span class="reception-step-tag">Paso 4 de 4</span><h4>Asignar responsables</h4><p>La confirmación enviará el pedido directamente a los auxiliares seleccionados.</p></div><button type="button" class="btn btn-ghost" data-back-lines>Editar información</button></div>
    <div class="reception-assignment-grid">
      <div class="field"><label>Auxiliar de alistamiento *</label><select class="control" data-picking-profile required><option value="">Seleccione…</option>${pickingPool.map(person=>`<option value="${person.id}" ${person.id===draft.pickingProfileId?"selected":""}>${fmt.escape(person.name)}</option>`).join("")}</select><small>Solo usuarios activos con rol Auxiliar de logística.</small></div>
      ${hasCuts?`<div class="field"><label>Auxiliar de corte *</label><select class="control" data-cut-profile required><option value="">Seleccione…</option>${cutPool.map(person=>`<option value="${person.id}" ${person.id===draft.cutProfileId?"selected":""}>${fmt.escape(person.name)}</option>`).join("")}</select><small>Se mostrará únicamente porque existen líneas marcadas para corte.</small></div>`:`<article class="reception-no-cut"><span>✓</span><div><strong>Este pedido no requiere corte</strong><p>No se generará tarea para auxiliares de corte.</p></div></article>`}
    </div>
    <div class="reception-final-summary">
      <div><small>Líneas definitivas</small><strong>${draft.lines.length}</strong></div>
      <div><small>Líneas con corte</small><strong>${draft.lines.filter(line=>line.requiresCut).length}</strong></div>
      <div><small>Origen de información</small><strong>${draft.mode==="CORRECT"?"Asesor":"Lector PDF"}</strong></div>
    </div>
    <button type="button" class="btn btn-primary reception-confirm-button" data-confirm-reception>Confirmar recepción y asignación</button>
  </section>`;
}

function bindStage(host,data,draft,callbacks){
  host.querySelector("[data-info-correct]")?.addEventListener("click",()=>{
    draft.mode="CORRECT";
    draft.stage="ASSIGN";
    draft.lines=(data.items||[]).map((item,index)=>fromOrderItem(item,index));
    persistDraft(data.order.id,draft);
    renderWorkbench(host,data,draft,callbacks);
  });
  host.querySelector("[data-info-assign]")?.addEventListener("click",()=>{
    draft.mode="PDF";
    draft.stage="PDF";
    const first=pdfFiles(data.files||[])[0];
    draft.sourceFileId=draft.sourceFileId||first?.drive_file_id||"";
    draft.sourceFileName=draft.sourceFileName||first?.file_name||"";
    persistDraft(data.order.id,draft);
    renderWorkbench(host,data,draft,callbacks);
  });
  host.querySelector("[data-back-review]")?.addEventListener("click",()=>{draft.stage="REVIEW";persistDraft(data.order.id,draft);renderWorkbench(host,data,draft,callbacks)});
  host.querySelector("[data-back-pdf]")?.addEventListener("click",()=>{draft.stage="PDF";persistDraft(data.order.id,draft);renderWorkbench(host,data,draft,callbacks)});
  host.querySelector("[data-back-lines]")?.addEventListener("click",()=>{draft.stage=draft.mode==="PDF"?"EDIT":"REVIEW";persistDraft(data.order.id,draft);renderWorkbench(host,data,draft,callbacks)});

  host.querySelector("[data-read-drive-pdf]")?.addEventListener("click",async event=>{
    const select=host.querySelector("[data-source-pdf]");
    const file=(data.files||[]).find(item=>item.drive_file_id===select?.value);
    if(!file)return toast("Selecciona un PDF válido.","error");
    draft.sourceFileId=file.drive_file_id;
    draft.sourceFileName=file.file_name;
    await processPdf(host,data,draft,callbacks,()=>downloadDriveFile(file.drive_file_id));
  });
  host.querySelector("[data-local-pdf]")?.addEventListener("change",async event=>{
    const file=event.target.files?.[0];
    if(!file)return;
    draft.sourceFileId="";
    draft.sourceFileName=file.name;
    await processPdf(host,data,draft,callbacks,()=>file);
  });

  if(draft.stage==="EDIT")bindLineEditor(host,data,draft,callbacks);
  if(draft.stage==="ASSIGN")loadAssignmentStage(host,data,draft,callbacks);
}

async function processPdf(host,data,draft,callbacks,getFile){
  const status=host.querySelector("[data-reader-status]");
  const buttons=[...host.querySelectorAll("[data-read-drive-pdf], [data-local-pdf]")];
  buttons.forEach(button=>button.disabled=true);
  if(status)status.innerHTML='<span class="spinner"></span> Leyendo y organizando las líneas del pedido…';
  try{
    const file=await getFile();
    const parsed=await readOrderPdf(file);
    const detected=parsed.items.map((line,index)=>mergeReaderLine(line,data.items||[],index));
    draft.lines=await resolveMaterialLines(detected);
    draft.rawPreview=parsed.raw.slice(0,30000);
    draft.readerVersion=parsed.readerVersion;
    draft.stage="EDIT";
    persistDraft(data.order.id,draft);
    renderWorkbench(host,data,draft,callbacks);
    toast(`${draft.lines.length} línea(s) detectada(s). Revisa el resultado antes de confirmar.`,"success",6000);
  }catch(error){
    if(status)status.textContent=error.message;
    toast(error.message,"error",7500);
    buttons.forEach(button=>button.disabled=false);
  }
}

function bindLineEditor(host,data,draft,callbacks){
  const editor=host.querySelector("[data-lines-editor]");
  if(!editor)return;
  bindRows(editor);
  const save=()=>{
    try{draft.lines=collectEditorLines(editor,false);persistDraft(data.order.id,draft)}catch{}
  };
  editor.addEventListener("input",save);
  editor.addEventListener("material:selected",save);
  editor.addEventListener("change",event=>{if(event.target.matches('[data-field="requiresCut"]'))syncCutRow(event.target.closest("[data-line-row]"));save()});
  editor.addEventListener("click",event=>{
    const remove=event.target.closest("[data-remove-line]");
    if(!remove)return;
    remove.closest("[data-line-row]")?.remove();
    renumberEditor(editor);
    save();
  });
  host.querySelector("[data-add-line]")?.addEventListener("click",()=>{
    const emptyMessage=editor.querySelector(".reception-file-warning");
    emptyMessage?.remove();
    editor.insertAdjacentHTML("beforeend",editableLine(blankLine(),editor.querySelectorAll("[data-line-row]").length));
    bindRows(editor);
    renumberEditor(editor);
  });
  host.querySelector("[data-confirm-lines]")?.addEventListener("click",()=>{
    try{
      draft.lines=collectEditorLines(editor,!data.order.is_test);
      draft.stage="ASSIGN";
      persistDraft(data.order.id,draft);
      renderWorkbench(host,data,draft,callbacks);
    }catch(error){toast(error.message,"error",7000)}
  });
}

async function loadAssignmentStage(host,data,draft,callbacks){
  const mount=host.querySelector("[data-assignment-content]");
  if(!mount)return;
  try{
    const [pickingRaw,cutRaw]=await Promise.all([api.assignmentPool("ALISTAMIENTO"),api.assignmentPool("CORTE")]);
    const pickingPool=(pickingRaw||[]).filter(person=>(person.roles||[]).includes("aux_logistica"));
    const cutPool=(cutRaw||[]).filter(person=>(person.roles||[]).includes("auxiliar_corte"));
    mount.closest(".reception-stage-card").outerHTML=assignmentStage(data,draft,pickingPool,cutPool);
    bindAssignmentControls(host,data,draft,callbacks,pickingPool,cutPool);
  }catch(error){mount.innerHTML=`<div class="reception-file-warning"><strong>No fue posible cargar los auxiliares.</strong><p>${fmt.escape(error.message)}</p></div>`}
}

function bindAssignmentControls(host,data,draft,callbacks,pickingPool,cutPool){
  const picking=host.querySelector("[data-picking-profile]");
  const cut=host.querySelector("[data-cut-profile]");
  picking?.addEventListener("change",()=>{draft.pickingProfileId=picking.value;persistDraft(data.order.id,draft)});
  cut?.addEventListener("change",()=>{draft.cutProfileId=cut.value;persistDraft(data.order.id,draft)});
  host.querySelector("[data-back-lines]")?.addEventListener("click",()=>{draft.stage=draft.mode==="PDF"?"EDIT":"REVIEW";persistDraft(data.order.id,draft);renderWorkbench(host,data,draft,callbacks)});
  host.querySelector("[data-confirm-reception]")?.addEventListener("click",()=>{
    const hasCuts=draft.lines.some(line=>line.requiresCut);
    draft.pickingProfileId=picking?.value||"";
    draft.cutProfileId=cut?.value||"";
    if(!draft.pickingProfileId)return toast("Selecciona el auxiliar de alistamiento.","error");
    if(!pickingPool.some(person=>person.id===draft.pickingProfileId))return toast("El auxiliar de alistamiento seleccionado ya no está disponible.","error");
    if(hasCuts&&!draft.cutProfileId)return toast("Selecciona el auxiliar de corte.","error");
    if(hasCuts&&!cutPool.some(person=>person.id===draft.cutProfileId))return toast("El auxiliar de corte seleccionado ya no está disponible.","error");
    persistDraft(data.order.id,draft);
    confirmReception(host,data,draft,callbacks);
  });
}

function confirmReception(host,data,draft,{reload,refreshLists}={}){
  openSubdialog(host,{
    title:"Confirmar recepción y asignación",
    confirmLabel:"Sí, confirmar y enviar",
    body:`<div class="reception-confirm-dialog"><strong>Esta acción cerrará Recepción de pedidos.</strong><p>Se guardarán las líneas definitivas. Alistamiento quedará activo inmediatamente y, si existen cortes, únicamente esas líneas se enviarán a Corte en paralelo.</p><div>${summaryChip("Líneas",draft.lines.length)}${summaryChip("Con corte",draft.lines.filter(line=>line.requiresCut).length)}</div></div>`,
    onConfirm:async button=>{
      button.disabled=true;
      try{
        await api.confirmOrderReception(data.order.id,{
          sourceMode:draft.mode,
          sourceFileId:draft.sourceFileId||null,
          sourceFileName:draft.sourceFileName||null,
          readerVersion:draft.readerVersion||null,
          pickingProfileId:draft.pickingProfileId,
          cutProfileId:draft.lines.some(line=>line.requiresCut)?draft.cutProfileId:null,
          lines:draft.lines.map((line,index)=>({
            orderItemId:line.orderItemId||null,
            lineNumber:index+1,
            sku:line.sku||null,
            reference:line.reference||null,
            description:line.description,
            quantity:Number(line.quantity),
            unit:line.unit||"UND",
            warehouseLocation:line.warehouseLocation||null,
            requiresCut:Boolean(line.requiresCut),
            requestedCutLength:line.requiresCut?Number(line.requestedCutLength||line.quantity):null,
            metadata:{readerConfidence:line.readerConfidence||null,sourceLine:line.sourceLine||null,materialMasterId:line.materialMasterId||null,materialVariantId:line.materialVariantId||null,variantLabel:line.variantLabel||null,source:"RECEPTION_SIESA_MASTER"}
          }))
        });
        clearDraft(data.order.id);
        host.replaceChildren();
        refreshLists?.();
        toast(draft.lines.some(line=>line.requiresCut)?"Recepción confirmada. Alistamiento quedó activo y los cortes fueron enviados a Corte en paralelo.":"Recepción confirmada. El pedido fue asignado a Alistamiento.","success",7000);
      }catch(error){toast(error.message,"error",7500);button.disabled=false}
    }
  });
}

function openSubdialog(host,{title,body,confirmLabel,onConfirm}){
  const layer=document.createElement("div");
  layer.className="reception-subdialog-layer";
  layer.innerHTML=`<section class="modal reception-subdialog"><header class="modal-head"><h3>${fmt.escape(title)}</h3><button type="button" class="icon-btn" data-sub-close>×</button></header><div class="modal-body">${body}</div><footer class="modal-foot"><button type="button" class="btn btn-ghost" data-sub-close>Cancelar</button><button type="button" class="btn btn-primary" data-sub-confirm>${fmt.escape(confirmLabel)}</button></footer></section>`;
  host.append(layer);
  layer.querySelectorAll("[data-sub-close]").forEach(button=>button.onclick=()=>layer.remove());
  layer.querySelector("[data-sub-confirm]").onclick=async event=>{
    try{
      const controls=[...layer.querySelectorAll("input,select,textarea")].filter(control=>!control.disabled&&control.type!=="hidden");
      for(const control of controls)if(!control.checkValidity()){control.reportValidity();control.focus();return}
      await onConfirm(event.currentTarget);
    }catch(error){toast(error.message||String(error),"error",7000);event.currentTarget.disabled=false}
  };
}

export function openPurchaseArrival(order,{refreshLists}={}){
  const host=document.querySelector("#modal-root");
  const status=String(order.arrivalStatus||"").toUpperCase();
  const waiting=status==="WAITING";
  const arrived=status==="ARRIVED";
  host.innerHTML=`<div class="modal-overlay simple-process-overlay">
    <section class="modal simple-process-modal wide reception-process-modal purchase-shadow-modal" data-order-id="${fmt.escape(order.id)}">
      <header class="modal-head simple-process-head reception-process-head"><div><span class="wizard-kicker">Recepción · seguimiento de Compras</span><h3>${fmt.escape(order.orderNumber)}</h3><p>${fmt.escape(order.clientName)} · PVE</p></div><button class="icon-btn" data-close aria-label="Cerrar">×</button></header>
      <div class="modal-body simple-process-body reception-process-body">
        <section class="purchase-shadow-banner"><span>EN PARALELO CON COMPRAS</span><div><strong>${arrived?"Mercancía recibida":waiting?"Esperando llegada a la sede":"Confirma el estado físico de la mercancía"}</strong><p>Este seguimiento no duplica el pedido ni interfiere con la gestión de Compras.</p></div></section>
        <section class="purchase-shadow-status">
          <div><small>Etapa principal</small><strong>${fmt.escape(fmt.step(order.currentStep))}</strong></div>
          <div><small>Estado de llegada</small><strong>${arrived?"Mercancía OK":waiting?"En espera":"Sin marcar"}</strong></div>
          <div><small>Destino posterior</small><strong>Recepción de pedidos</strong></div>
        </section>
        <div class="purchase-shadow-actions">
          ${arrived?`<button class="btn btn-success btn-large" disabled>✓ Mercancía OK</button><p>${order.currentStep==="COMPRAS"?"La mercancía ya está registrada. Cuando Compras libere el pedido, Recepción quedará habilitada automáticamente.":"El pedido ya puede continuar en Recepción."}</p>`:waiting?`<button class="btn btn-success btn-large" data-arrival="ARRIVED">Mercancía OK</button><p>Úsalo cuando la mercancía ya esté físicamente en la sede.</p>`:`<button class="btn btn-warning btn-large" data-arrival="WAITING">Marcar espera</button><p>Indica que Recepción está esperando la llegada física del PVE.</p>`}
        </div>
      </div>
      ${parallelWorkFooter(order.currentStep||"COMPRAS")}
    </section>
  </div>`;
  bindClose(host);
  host.querySelector("[data-arrival]")?.addEventListener("click",async event=>{
    const button=event.currentTarget;button.disabled=true;
    try{
      const result=await api.setPurchaseArrival(order.id,button.dataset.arrival);
      toast(button.dataset.arrival==="WAITING"?"Pedido marcado en espera de mercancía.":"Mercancía OK registrada.","success",6000);
      refreshLists?.();window.__erpQueueRefresh?.();
      host.replaceChildren();
    }catch(error){toast(error.message,"error",7000);button.disabled=false}
  });
}

function editableLine(line,index){
  const unresolved=line.materialResolution==="NOT_FOUND";
  return `<article class="reception-line-row official-reception-line ${unresolved?"unresolved":""}" data-line-row data-order-item-id="${fmt.escape(line.orderItemId||"")}">
    <div class="reception-line-number">${index+1}</div>
    <div class="reception-line-material">
      ${materialPickerHtml({materialMasterId:line.materialMasterId||line.material_master_id,materialVariantId:line.materialVariantId||line.material_variant_id,variantLabel:line.variantLabel||line.variant_label,reference:line.reference,sku:line.sku,name:line.description,description:line.description,unit:line.unit})}
      ${unresolved?`<div class="material-resolution-warning">No se pudo relacionar automáticamente esta línea. Busca y selecciona el material oficial antes de continuar.</div>`:""}
    </div>
    <div class="reception-line-fields official-line-quantity">
      <div class="field"><label>Cantidad *</label><input class="control" data-field="quantity" type="number" min="0.0001" step="any" value="${fmt.escape(line.quantity??"")}" placeholder="Cantidad" required></div>
      <div class="field"><label>Ubicación operativa</label><input class="control" data-field="warehouseLocation" value="${fmt.escape(line.warehouseLocation||"")}" placeholder="Opcional"></div>
    </div>
    <div class="reception-cut-controls">
      <label class="filter-pill"><input type="checkbox" data-field="requiresCut" ${line.requiresCut?"checked":""}> Requiere corte</label>
      <input class="control" data-field="requestedCutLength" type="number" min="0.0001" step="any" value="${fmt.escape(line.requestedCutLength??"")}" placeholder="Longitud por unidad" ${line.requiresCut?"required":"disabled"}>
      <button type="button" class="icon-btn" data-remove-line title="Eliminar línea">×</button>
    </div>
  </article>`;
}

function collectEditorLines(editor,strict){
  const rows=[...editor.querySelectorAll("[data-line-row]")];
  if(strict&&!rows.length)throw new Error("Agrega al menos una línea al pedido.");
  return rows.map((row,index)=>{
    let material;
    try{material=readMaterialPicker(row.querySelector("[data-material-picker]"),strict)}catch(error){throw new Error(`Línea ${index+1}: ${error.message}`)}
    const value=name=>row.querySelector(`[data-field="${name}"]`)?.value?.trim()||"";
    const quantity=Number(value("quantity"));
    const requiresCut=row.querySelector('[data-field="requiresCut"]').checked;
    const requestedCutLength=Number(value("requestedCutLength"));
    if(strict&&(!Number.isFinite(quantity)||quantity<=0))throw new Error(`La línea ${index+1} necesita una cantidad válida.`);
    if(strict&&requiresCut&&(!Number.isFinite(requestedCutLength)||requestedCutLength<=0))throw new Error(`Registra la longitud de corte de la línea ${index+1}.`);
    return {orderItemId:row.dataset.orderItemId||null,materialMasterId:material.materialMasterId,materialVariantId:material.materialVariantId,variantLabel:material.variantLabel,sku:material.sku,reference:material.reference,description:material.description,quantity:Number.isFinite(quantity)?quantity:0,unit:material.unit||"UND",warehouseLocation:value("warehouseLocation")||null,requiresCut,requestedCutLength:requiresCut&&Number.isFinite(requestedCutLength)?requestedCutLength:null};
  });
}

function bindRows(editor){
  editor.querySelectorAll("[data-line-row]").forEach(row=>{
    syncCutRow(row);
    bindMaterialPicker(row.querySelector("[data-material-picker]"),{onChange:()=>row.classList.remove("unresolved")});
  });
}
function syncCutRow(row){
  if(!row)return;
  const toggle=row.querySelector('[data-field="requiresCut"]');
  const length=row.querySelector('[data-field="requestedCutLength"]');
  length.disabled=!toggle.checked;
  length.required=toggle.checked;
  if(toggle.checked&&!length.value){
    const quantity=Number(row.querySelector('[data-field="quantity"]')?.value||0);
    if(quantity>0)length.value=String(quantity);
  }
  if(!toggle.checked)length.value="";
}
function renumberEditor(editor){editor.querySelectorAll(".reception-line-number").forEach((node,index)=>node.textContent=String(index+1))}

function readOnlyLines(items){
  if(!items.length)return '<div class="reception-file-warning"><strong>El asesor no registró materiales.</strong><p>Usa Asignar información para leer el PDF.</p></div>';
  return `<div class="reception-lines-preview">${items.map(item=>`<article><div><strong>${fmt.escape(item.reference||item.sku||item.description)}</strong><p>${fmt.escape(item.description)}</p></div><span>${fmt.number(item.quantity,3)} ${fmt.escape(item.unit||"UND")}</span>${item.requires_cut?'<b>Corte</b>':""}</article>`).join("")}</div>`;
}

function advisorFiles(files){
  if(!files.length)return '<div class="reception-file-warning"><strong>No hay archivos cargados.</strong><p>La información podrá asignarse manualmente o mediante un PDF local.</p></div>';
  return `<section class="reception-files"><header><strong>Archivos enviados por el asesor</strong><span>${files.length} soporte(s)</span></header><div>${files.map(file=>`<article><span class="reception-file-icon">${isPdf(file)?"PDF":"DOC"}</span><div><strong>${fmt.escape(file.file_name)}</strong><small>${fmt.escape(file.file_category||"EVIDENCE")} · ${formatBytes(file.size_bytes)}</small></div>${file.web_view_link?`<a class="btn btn-ghost" href="${fmt.escape(file.web_view_link)}" target="_blank" rel="noopener">Abrir</a>`:""}</article>`).join("")}</div></section>`;
}

function fullDetails(data){
  return `<div class="simple-detail-sections"><section><h4>Información principal</h4><div class="detail-grid">${detail("Cliente",data.order.client_name)}${detail("Tipo",fmt.label(data.order.order_type_code))}${detail("Pago",fmt.payment(data.order.payment_condition_code))}${detail("Ruta",fmt.route(data.order.delivery_route_code))}${detail("Creado",fmt.date(data.order.created_at))}</div></section><section><h4>Comentarios y reportes</h4>${(data.comments||[]).length?`<div class="timeline">${data.comments.slice(-8).reverse().map(row=>`<div class="timeline-item"><h4>${fmt.escape(fmt.label(row.type||"Comentario"))} · ${fmt.escape(row.author)}</h4><p>${fmt.escape(row.body)}</p><time>${fmt.date(row.createdAt)}</time></div>`).join("")}</div>`:'<p class="cell-sub">Sin registros.</p>'}</section></div>`;
}
function detail(label,value){return `<div class="info-box"><label>${fmt.escape(label)}</label><strong>${fmt.escape(value??"—")}</strong></div>`}

function progressBar(stage){
  const current={REVIEW:2,PDF:2,EDIT:3,ASSIGN:4}[stage]||2;
  return `<div class="reception-progress">${["Tomar pedido","Revisar información","Validar líneas","Asignar auxiliares"].map((label,index)=>`<div class="${index+1<current?"done":index+1===current?"current":""}"><span>${index+1}</span><small>${label}</small></div>`).join("")}</div>`;
}

function loadDraft(data){
  const fallback={stage:"REVIEW",mode:null,lines:[],sourceFileId:"",sourceFileName:"",pickingProfileId:"",cutProfileId:"",readerVersion:null,rawPreview:""};
  try{
    const parsed=JSON.parse(localStorage.getItem(DRAFT_PREFIX+data.order.id)||"null");
    if(!parsed||parsed.orderVersion>data.order.version)return {...fallback,orderVersion:data.order.version};
    return {...fallback,...parsed,orderVersion:data.order.version};
  }catch{return {...fallback,orderVersion:data.order.version}}
}
function persistDraft(orderId,draft){draft.updatedAt=new Date().toISOString();localStorage.setItem(DRAFT_PREFIX+orderId,JSON.stringify(draft))}
function clearDraft(orderId){localStorage.removeItem(DRAFT_PREFIX+orderId)}

function fromOrderItem(item,index){
  return {orderItemId:item.id,materialMasterId:item.material_master_id||item.metadata?.materialMasterId||null,materialVariantId:item.material_variant_id||item.metadata?.materialVariantId||null,variantLabel:item.metadata?.variantLabel||null,sku:item.sku||null,reference:item.reference||null,description:item.description||"",quantity:Number(item.quantity||0),unit:item.unit||"UND",warehouseLocation:item.warehouse_location||null,requiresCut:Boolean(item.requires_cut),requestedCutLength:item.requested_cut_length==null?null:Number(item.requested_cut_length),sourceLine:index+1};
}
function mergeReaderLine(line,current,index){
  const normalized=String(line.reference||line.sku||"").trim().toUpperCase();
  const match=current.find(item=>[item.reference,item.sku].some(value=>String(value||"").trim().toUpperCase()===normalized))||current[index];
  return {...line,orderItemId:match?.id||null,materialMasterId:match?.material_master_id||match?.metadata?.materialMasterId||null,materialVariantId:match?.material_variant_id||match?.metadata?.materialVariantId||null,variantLabel:match?.metadata?.variantLabel||line.variantLabel||line.color||null,warehouseLocation:match?.warehouse_location||"",requestedCutLength:line.requiresCut?(line.requestedCutLength||line.quantity):null};
}
function blankLine(){return {orderItemId:null,materialMasterId:null,materialVariantId:null,variantLabel:null,sku:null,reference:null,description:"",quantity:1,unit:"UND",warehouseLocation:"",requiresCut:false,requestedCutLength:null,materialResolution:"NOT_FOUND"}}

function pdfFiles(files){return files.filter(isPdf)}
function isPdf(file){return /pdf/i.test(file.mime_type||"")||/\.pdf$/i.test(file.file_name||"")}
function formatBytes(value){const bytes=Number(value||0);if(!bytes)return "Tamaño no informado";if(bytes<1024)return `${bytes} B`;if(bytes<1048576)return `${(bytes/1024).toFixed(1)} KB`;return `${(bytes/1048576).toFixed(1)} MB`}
function summaryChip(label,value){return `<span class="reception-summary-chip"><small>${fmt.escape(label)}</small><strong>${fmt.escape(value)}</strong></span>`}

function activeTask(data){return (data.tasks||[]).find(task=>["QUEUED","ASSIGNED","IN_PROGRESS","WAITING","BLOCKED"].includes(task.status))||null}
function actionCodes(data){return new Set((data.actions?.actions||[]).map(action=>action.code))}
function assigneeName(data){const task=activeTask(data);if(task?.assigned_profile_id===state.profile?.id)return state.profile.name||"Tu usuario";return task?.assigned_name||fmt.role(task?.assigned_role_code||data.order.current_role_code)||"Sin asignar"}
async function beginReception(data){
  let latest=data;
  let actions=actionCodes(latest);
  if(actions.has("CLAIM")){
    await api.executeAction(latest.order.id,"CLAIM",{detail:"Pedido tomado en Recepción"},latest.order.version);
    latest=await api.getOrder(latest.order.id);
    actions=actionCodes(latest);
  }
  if(actions.has("START"))await api.executeAction(latest.order.id,"START",{detail:"Recepción de pedido iniciada"},latest.order.version);
  else if(actions.has("RESUME"))await api.executeAction(latest.order.id,"RESUME",{detail:"Recepción de pedido retomada"},latest.order.version);
}
function bindClose(host){host.querySelectorAll("[data-close]").forEach(button=>button.onclick=()=>host.replaceChildren())}
