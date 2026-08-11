import {api} from "../services/api.js";
import {fmt} from "../core/format.js";
import {empty,loading,paginationHtml,toast} from "../core/ui.js";
import {navigate} from "../core/router.js";
import {uploadOrderFile} from "../services/drive.js";

let currentRoot=null;
let currentPage=1;
let sandboxMode=false;

export function isCuttingFlow(data){return data?.order?.current_step_code==="CORTE"}

export async function renderCutting(root,{params={}}={}){
  currentRoot=root;
  sandboxMode=params.sandbox==="1";
  root.innerHTML=`
    ${sandboxMode?`<section class="sandbox-queue-banner"><strong>MODO SANDBOX · CORTE</strong><span>Carretos, consumos y evidencia son simulados. Producción permanece intacta.</span><button class="btn btn-ghost btn-compact" id="sandbox-cut-back">Volver al Bot</button></section>`:""}
    <section class="page-head cutting-page-head">
      <div><span class="cutting-kicker">Centro de corte</span><h2>Corte por referencia</h2><p>Selecciona una referencia y completa una sola secuencia guiada: iniciar, elegir origen, ejecutar y cerrar con evidencia.</p></div>
      <div class="page-actions"><button class="btn btn-ghost" id="cutting-refresh">Actualizar</button></div>
    </section>
    <section class="card card-pad cutting-workspace">
      <div class="cutting-toolbar"><input class="control search-wide" id="cutting-search" placeholder="Buscar referencia o nombre del cable"><button class="btn btn-primary" id="cutting-search-button">Buscar</button></div>
      <div id="cutting-result">${loading("Consultando referencias de Corte…")}</div>
    </section>`;
  root.querySelector("#sandbox-cut-back")?.addEventListener("click",()=>navigate("sandbox"));
  root.querySelector("#cutting-search-button")?.addEventListener("click",()=>loadCuttingGroups(1));
  root.querySelector("#cutting-refresh")?.addEventListener("click",()=>loadCuttingGroups(currentPage));
  root.querySelector("#cutting-search")?.addEventListener("keydown",e=>{if(e.key==="Enter")loadCuttingGroups(1)});
  window.__erpCuttingRefresh=()=>loadCuttingGroups(currentPage);
  await loadCuttingGroups(1);
}

async function loadCuttingGroups(page=1){
  const root=currentRoot;if(!root?.isConnected)return;
  currentPage=page;
  const target=root.querySelector("#cutting-result");
  target.innerHTML=loading("Organizando trabajo por referencia…");
  try{
    const search=root.querySelector("#cutting-search")?.value.trim()||"";
    const data=await (sandboxMode?api.sandboxCuttingWork(search,page,50):api.cuttingWork(search,page,50));
    const rows=data.items||[];
    target.innerHTML=rows.length?`<div class="cutting-result-head"><div><strong>${fmt.number(data.pagination?.totalItems||rows.length)} referencia(s)</strong><span>Las ejecuciones iniciadas permanecen visibles hasta cargar su evidencia final.</span></div></div><div class="erp-work-list cutting-group-list">${rows.map(groupRow).join("")}</div>${paginationHtml(data.pagination)}`:empty("No hay referencias pendientes","Cuando existan cortes por ejecutar aparecerán aquí.");
    target.querySelectorAll("[data-cut-group]").forEach(b=>b.addEventListener("click",()=>openCutGroup(b.dataset.cutGroup)));
    target.querySelectorAll("[data-page]").forEach(b=>b.addEventListener("click",()=>loadCuttingGroups(Number(b.dataset.page))));
  }catch(error){
    target.innerHTML=`<div class="module-error"><strong>No fue posible cargar Corte</strong><p>${fmt.escape(error.message)}</p><button class="btn btn-primary" data-retry>Reintentar</button></div>`;
    target.querySelector("[data-retry]")?.addEventListener("click",()=>loadCuttingGroups(page));
    toast(error.message,"error",8000);
  }
}

function groupRow(group){
  const status=String(group.executionStatus||"").toUpperCase();
  const progress=Number(group.completedLength||0)>0||status;
  const labels={WAITING_EVIDENCE:["Pendiente de foto","Cerrar con foto"],PAUSED:["Pausado","Reanudar"],IN_PROGRESS:["En corte","Continuar"],"":[progress?"En progreso":"Pendiente",progress?"Continuar":"Iniciar corte"]};
  const [badge,action]=labels[status]||labels[""];
  return `<article class="erp-work-row cutting-group-row ${status?"in-progress":""}"><div class="erp-work-main"><span class="erp-work-eyebrow">${status==="WAITING_EVIDENCE"?"EVIDENCIA OBLIGATORIA":status?"EJECUCIÓN ACTIVA":"REFERENCIA PENDIENTE"}</span><strong>${fmt.escape(group.reference||group.sku||"Sin referencia")}</strong><small>${fmt.escape(group.description||"")}</small></div><div class="erp-work-meta"><span><small>Falta cortar</small><b>${fmt.number(group.totalLength||0,3)} m</b></span><span><small>Cortes</small><b>${fmt.number(group.cutCount||0,2)}</b></span><span><small>Pedidos</small><b>${fmt.number(group.orderCount||0)}</b></span><span><small>Tiempo</small><b>${status?duration(Number(group.elapsedSeconds||0)):"Sin iniciar"}</b></span></div><div class="erp-work-status"><span class="badge ${status==="WAITING_EVIDENCE"?"badge-warning":status==="PAUSED"?"badge-gray":status?"badge-blue":"badge-gray"}">${badge}</span></div><button type="button" class="btn btn-primary erp-work-action" data-cut-group="${fmt.escape(group.groupKey)}">${action}</button></article>`;
}

export function renderCuttingOrder(host,data){
  host.innerHTML=`<div class="modal-overlay simple-process-overlay"><section class="modal simple-process-modal cutting-order-notice"><header class="modal-head simple-process-head"><div><span class="wizard-kicker">Corte por referencia</span><h3>${fmt.escape(data.order.order_number)}</h3><p>${fmt.escape(data.order.client_name)}</p></div><button class="icon-btn" data-close aria-label="Cerrar">×</button></header><div class="modal-body simple-process-body"><section class="cutting-order-message"><span>CT</span><div><h4>Los cortes se ejecutan agrupados por referencia</h4><p>Abre el Centro de Corte para trabajar la referencia completa y registrar su tiempo hasta la evidencia final.</p></div></section><button class="btn btn-primary btn-large cutting-open-center" data-open-cutting>Abrir Centro de corte</button></div>${guidedFooter()}</section></div>`;
  bindClose(host);
  host.querySelector("[data-open-cutting]")?.addEventListener("click",()=>{host.replaceChildren();navigate("cutting",data.order.is_test?{sandbox:"1"}:{})});
}

async function openCutGroup(groupKey,{message=""}={}){
  const host=document.querySelector("#modal-root");
  host.innerHTML=`<div class="modal-overlay cutting-overlay"><section class="modal cutting-guided-modal"><div class="modal-body">${loading("Preparando ejecución de Corte…")}</div></section></div>`;
  try{
    const active=await api.cuttingActiveExecution(groupKey);
    if(active){renderExecution(host,active,{message});return}
    const data=await (sandboxMode?api.sandboxCuttingGroup(groupKey):api.cuttingGroup(groupKey));
    renderStart(host,data);
  }catch(error){
    host.innerHTML=`<div class="modal-overlay"><section class="modal"><header class="modal-head"><h3>No fue posible abrir la referencia</h3><button class="icon-btn" data-close>×</button></header><div class="modal-body"><p class="danger">${fmt.escape(error.message)}</p></div></section></div>`;
    bindClose(host);
  }
}

function renderStart(host,data){
  const group=data.group||{};const items=data.items||[];
  host.innerHTML=`<div class="modal-overlay cutting-overlay"><section class="modal cutting-guided-modal cut-start-modal"><header class="modal-head cut-guide-head"><div><span class="cut-guide-kicker">CORTE · ${fmt.escape(group.reference||group.sku||"SIN REFERENCIA")}</span><h3>${fmt.escape(group.description||"Material por cortar")}</h3><p>Esta ejecución medirá el trabajo completo de la referencia.</p></div><button class="icon-btn" data-close aria-label="Cerrar">×</button></header><div class="modal-body cut-guide-body"><section class="cut-now-card"><div class="cut-now-icon">1</div><div><span>PRIMERA ACCIÓN</span><h4>Inicia solamente cuando vayas a comenzar a cortar</h4><p>Al iniciar se guardan la hora, el auxiliar y los pedidos incluidos. Los pedidos nuevos de esta referencia quedarán para una ejecución posterior.</p></div></section><section class="cut-start-facts"><div><small>Pedidos</small><strong>${fmt.number(group.orderCount)}</strong></div><div><small>Cortes</small><strong>${fmt.number(group.cutCount,2)}</strong></div><div><small>Longitud total</small><strong>${fmt.number(group.totalLength,3)} m</strong></div></section><section class="cut-review-compact"><header><strong>Qué se va a cortar</strong><span>Revisa antes de iniciar</span></header><div>${items.map(cutRequirementRow).join("")}</div></section><section class="cut-primary-action"><div><strong>¿Todo correcto?</strong><span>Este botón inicia la medición real de Corte.</span></div><button type="button" class="btn btn-primary cut-main-cta" data-start-cut>Iniciar corte por referencia</button></section></div>${guidedFooter("Puedes cerrar esta ventana antes de iniciar sin generar tiempo de Corte.")}</section></div>`;
  bindClose(host);
  host.querySelector("[data-start-cut]")?.addEventListener("click",async e=>{
    e.currentTarget.disabled=true;e.currentTarget.textContent="Iniciando corte…";
    try{const result=await api.cuttingStart(group.groupKey);toast("Corte iniciado. El tiempo ya está corriendo.","success",6000);renderExecution(host,result)}
    catch(error){toast(error.message,"error",8000);e.currentTarget.disabled=false;e.currentTarget.textContent="Iniciar corte por referencia"}
  });
}

function renderExecution(host,data,{message=""}={}){
  const execution=data.execution||{};const group=data.group||{};const items=data.items||[];const recent=data.recentBatches||[];
  if(String(execution.status).toUpperCase()==="PAUSED"){renderPaused(host,data);return}
  if(String(execution.status).toUpperCase()==="WAITING_EVIDENCE"||data.physicalComplete){renderEvidence(host,data);return}
  const state={executionId:execution.id,groupKey:group.groupKey,group,items,origins:[],selectedLotId:null,selectedOrigin:null,plan:null,reelLength:0,scrapLength:0};
  host.innerHTML=`<div class="modal-overlay cutting-overlay"><section class="modal cutting-guided-modal cut-reference-modal"><header class="modal-head cut-guide-head"><div><span class="cut-guide-kicker">CORTE EN EJECUCIÓN · ${fmt.escape(group.reference||execution.reference||"")}</span><h3>${fmt.escape(group.description||execution.description||"Material por cortar")}</h3><p>Completa la acción resaltada. El ERP te llevará automáticamente a la siguiente.</p></div><button class="icon-btn" data-close aria-label="Cerrar">×</button></header><div class="modal-body cut-guide-body cut-reference-body"><section class="cut-live-strip"><div><small>Inicio</small><strong>${dateTime(execution.startedAt)}</strong></div><div class="cut-live-time"><small>Tiempo activo</small><strong data-cut-timer>${duration(Number(data.metrics?.businessSeconds||0))}</strong></div><div><small>Carretos utilizados</small><strong>${fmt.number(data.metrics?.reelCount||0)}</strong></div><button type="button" class="btn btn-ghost" data-pause-cut>Pausar corte</button></section>${message?`<section class="cut-flow-message"><strong>${fmt.escape(message)}</strong><span>La ejecución continúa con el mismo tiempo y la misma referencia.</span></section>`:""}<nav class="cut-step-rail" aria-label="Progreso de Corte"><div data-cut-progress="1"><span>1</span><strong>Revisar</strong></div><i></i><div data-cut-progress="2"><span>2</span><strong>Carreto</strong></div><i></i><div data-cut-progress="3"><span>3</span><strong>Confirmar</strong></div><i></i><div><span>4</span><strong>Foto final</strong></div></nav>

  <section class="cut-step-panel" data-cut-step="1">
    <div class="cut-step-title"><span>PASO 1 DE 4</span><h4>Revisa los cortes pendientes</h4><p>Solo verifica. No necesitas tomar ninguna decisión de inventario todavía.</p></div>
    <section class="cut-step-metrics"><div><small>Pedidos</small><strong>${fmt.number(group.orderCount)}</strong></div><div><small>Cortes pendientes</small><strong>${fmt.number(group.cutCount,2)}</strong></div><div><small>Longitud pendiente</small><strong>${fmt.number(group.totalLength,3)} m</strong></div></section>
    <section class="cut-review-compact"><div>${items.filter(i=>Number(i.remainingLength||0)>0).map(cutRequirementRow).join("")}</div></section>
    ${recent.length?`<details class="cut-history"><summary>Ver carretos ya utilizados en esta ejecución</summary><div>${recent.map(batchHistoryRow).join("")}</div></details>`:""}
    <section class="cut-primary-action"><div><strong>Siguiente: seleccionar el origen físico</strong><span>Continúa cuando las medidas estén correctas.</span></div><button type="button" class="btn btn-primary cut-main-cta" data-cut-next="2">Continuar a carreto</button></section>
  </section>

  <section class="cut-step-panel" data-cut-step="2" hidden>
    <div class="cut-step-title"><span>PASO 2 DE 4</span><h4>Selecciona de qué carreto vas a cortar</h4><p>La referencia está bloqueada. Solo podrás seleccionar existencias compatibles.</p></div>
    <section class="cut-material-lock"><div><small>Material bloqueado</small><strong>${fmt.escape(group.reference||"")}</strong><span>${fmt.escape(group.description||"")}</span></div><b>${fmt.number(group.totalLength,3)} m pendientes</b></section>
    <section class="cut-origin-picker"><div class="cut-origin-search"><input class="control" data-origin-search placeholder="Buscar carreto, lote, bodega o ubicación"><button type="button" class="btn btn-ghost" data-origin-search-button>Buscar</button></div><div class="cut-origin-results" data-origin-results>${loading("Consultando inventario compatible…")}</div></section>
    <section class="cut-origin-confirm" data-origin-confirm hidden><div class="cut-selected-origin" data-selected-origin></div><div class="cut-origin-fields"><label><span>Cantidad que registra el ERP</span><input class="control" data-system-length readonly></label><label><span>Cantidad física encontrada *</span><input class="control" data-reel-length type="number" min="0.0001" step="0.0001"></label><label><span>Merma prevista</span><input class="control" data-scrap-length type="number" min="0" step="0.0001" value="0"></label></div><div class="cut-inventory-difference" data-inventory-difference hidden></div></section>
    <section class="cut-primary-action split"><button class="btn btn-ghost" data-cut-prev="1">Volver a revisar</button><div><strong>Siguiente: calcular qué cortes caben</strong><span>Primero debes seleccionar un carreto y confirmar su cantidad física.</span></div><button class="btn btn-primary cut-main-cta" data-preview-batch disabled>Calcular este carreto</button></section>
  </section>

  <section class="cut-step-panel" data-cut-step="3" hidden>
    <div class="cut-step-title"><span>PASO 3 DE 4</span><h4>Revisa el resultado antes de descontar inventario</h4><p>Aquí ves exactamente cuánto se cortará, cuánto quedará y si necesitarás otro carreto.</p></div>
    <div data-cut-plan>${loading("Calculando plan…")}</div>
    <section class="cut-primary-action split"><button class="btn btn-ghost" data-cut-prev="2">Cambiar carreto</button><div><strong>Última comprobación de este carreto</strong><span>La acción de la derecha sí modifica inventario.</span></div><button class="btn btn-primary cut-main-cta" data-execute-batch disabled>Confirmar y ejecutar</button></section>
  </section>
  </div>${guidedFooter("El avance queda guardado. Puedes cerrar y volver después sin reiniciar el tiempo.")}</section></div>`;
  bindClose(host);bindExecution(host,state);showStep(host,1);startTimer(host,Number(data.metrics?.businessSeconds||0));
}

function renderPaused(host,data){
  const e=data.execution||{};const p=data.currentPause||{};const g=data.group||{};
  host.innerHTML=`<div class="modal-overlay cutting-overlay"><section class="modal cutting-guided-modal cut-paused-modal"><header class="modal-head cut-guide-head"><div><span class="cut-guide-kicker">CORTE PAUSADO · ${fmt.escape(g.reference||e.reference||"")}</span><h3>${fmt.escape(g.description||e.description||"Material por cortar")}</h3><p>El tiempo productivo está detenido hasta que indiques que vas a continuar.</p></div><button class="icon-btn" data-close>×</button></header><div class="modal-body cut-guide-body"><section class="cut-state-screen paused"><span class="cut-state-mark">Ⅱ</span><div><small>PAUSA REGISTRADA</small><h4>Continúa solo cuando realmente vuelvas a cortar</h4><p>${fmt.escape(p.reason||"Pausa operativa")}</p></div><section class="cut-state-facts"><div><small>Inicio del corte</small><strong>${dateTime(e.startedAt)}</strong></div><div><small>Estado</small><strong>Tiempo activo detenido</strong></div></section><button class="btn btn-primary cut-main-cta" data-resume-cut>Continuar corte</button></section></div>${guidedFooter("Cerrar el popup no reanuda el corte. Debes usar “Continuar corte”.")}</section></div>`;
  bindClose(host);
  host.querySelector("[data-resume-cut]")?.addEventListener("click",async event=>{
    const button=event.currentTarget;button.disabled=true;button.textContent="Reanudando…";
    try{const result=await api.cuttingResume(e.id);toast("Corte reanudado.","success");renderExecution(host,result)}
    catch(error){toast(error.message,"error");button.disabled=false;button.textContent="Continuar corte"}
  });
}

function renderEvidence(host,data){
  const e=data.execution||{};const g=data.group||{};const m=data.metrics||{};const evidence=data.evidence;
  host.innerHTML=`<div class="modal-overlay cutting-overlay"><section class="modal cutting-guided-modal cut-evidence-modal"><header class="modal-head cut-guide-head"><div><span class="cut-guide-kicker">CIERRE DE CORTE · ${fmt.escape(g.reference||e.reference||"")}</span><h3>${fmt.escape(g.description||e.description||"Material cortado")}</h3><p>El corte físico está completo. Falta una única acción para liberar el material a Alistamiento.</p></div><button class="icon-btn" data-close>×</button></header><div class="modal-body cut-guide-body"><nav class="cut-step-rail complete"><div class="done"><span>✓</span><strong>Revisar</strong></div><i></i><div class="done"><span>✓</span><strong>Carreto</strong></div><i></i><div class="done"><span>✓</span><strong>Cortar</strong></div><i></i><div class="active"><span>4</span><strong>Foto final</strong></div></nav><section class="cut-state-screen evidence"><span class="cut-state-mark">4</span><div><small>ÚLTIMO PASO OBLIGATORIO</small><h4>Fotografía el material ya cortado y organizado</h4><p>La foto marca la hora final del Corte. Mientras no exista evidencia, la referencia no queda disponible para recoger en Alistamiento.</p></div><section class="cut-evidence-metrics"><div><small>Pedidos</small><strong>${fmt.number(e.initialOrderCount||g.orderCount)}</strong></div><div><small>Cortes</small><strong>${fmt.number(e.initialCutCount||0,2)}</strong></div><div><small>Metros cortados</small><strong>${fmt.number(m.cutLength||e.initialLength||0,3)} m</strong></div><div><small>Carretos usados</small><strong>${fmt.number(m.reelCount||0)}</strong></div><div><small>Tiempo total</small><strong>${duration(Number(m.businessSeconds||0))}</strong></div><div><small>Tiempo activo</small><strong>${duration(Number(m.activeBusinessSeconds||0))}</strong></div></section>${evidence?`<div class="cut-evidence-ready"><strong>Foto registrada correctamente</strong><span>${fmt.escape(evidence.fileName||"Evidencia de Corte")}. Cerrando la referencia…</span></div>`:`<input type="file" accept="image/*" capture="environment" data-cut-evidence-file hidden><button type="button" class="btn btn-success cut-main-cta" data-attach-cut-evidence>Anexar foto y finalizar corte</button><small class="cut-evidence-help">Toma una foto clara donde se vea el material o los carretos ya cortados antes de entregarlos.</small>`}</section></div>${guidedFooter("Sin la foto final, el Corte permanece abierto y no se libera a Alistamiento.")}</section></div>`;
  bindClose(host);
  if(evidence){queueMicrotask(()=>finalizeExecution(host,e.id));return}
  const input=host.querySelector("[data-cut-evidence-file]");const button=host.querySelector("[data-attach-cut-evidence]");
  button?.addEventListener("click",()=>input?.click());
  input?.addEventListener("change",async()=>{
    const file=input.files?.[0];if(!file)return;
    if(!file.type?.startsWith("image/")){toast("Debes seleccionar una imagen.","error");input.value="";return}
    button.disabled=true;const original=button.textContent;
    try{
      if(data.isTest){button.textContent="Registrando evidencia Sandbox…";await api.sandboxCuttingEvidence(e.id,{fileName:file.name,mimeType:file.type,sizeBytes:file.size})}
      else{
        button.textContent="Subiendo foto…";
        const uploaded=await uploadOrderFile(data.anchorOrderId,file,"CUTTING_EVIDENCE",null,data.anchorOrderNumber);
        if(!uploaded?.file?.id)throw new Error("Google Drive no devolvió la evidencia cargada.");
        button.textContent="Registrando evidencia…";
        await api.cuttingRegisterEvidence(e.id,uploaded.file.id);
      }
      button.textContent="Finalizando corte…";await finalizeExecution(host,e.id);
    }catch(error){toast(error.message||"No fue posible cerrar Corte.","error",9000);button.disabled=false;button.textContent=original;input.value=""}
  });
}

async function finalizeExecution(host,executionId){
  try{const result=await api.cuttingFinalize(executionId);toast(`Corte finalizado. Tiempo activo: ${duration(Number(result.metrics?.activeBusinessSeconds||0))}.`,"success",8000);host.replaceChildren();await loadCuttingGroups(currentPage);window.__erpQueueRefresh?.();window.__erpOrderListRefresh?.()}
  catch(error){toast(error.message,"error",9000)}
}

function bindExecution(host,state){
  host.querySelector("[data-pause-cut]")?.addEventListener("click",()=>pauseDialog(host,state));
  host.querySelectorAll("[data-cut-next]").forEach(b=>b.addEventListener("click",()=>{const step=Number(b.dataset.cutNext);showStep(host,step);if(step===2)loadOrigins(host,state,"")}));
  host.querySelectorAll("[data-cut-prev]").forEach(b=>b.addEventListener("click",()=>showStep(host,Number(b.dataset.cutPrev))));
  host.querySelector("[data-origin-search-button]")?.addEventListener("click",()=>loadOrigins(host,state,host.querySelector("[data-origin-search]")?.value.trim()||""));
  host.querySelector("[data-origin-search]")?.addEventListener("keydown",e=>{if(e.key==="Enter"){e.preventDefault();loadOrigins(host,state,e.currentTarget.value.trim())}});
  host.querySelector("[data-reel-length]")?.addEventListener("input",()=>syncDifference(host,state));
  host.querySelector("[data-scrap-length]")?.addEventListener("input",()=>{state.scrapLength=Number(host.querySelector("[data-scrap-length]")?.value||0)});
  host.querySelector("[data-preview-batch]")?.addEventListener("click",()=>previewBatch(host,state));
  host.querySelector("[data-execute-batch]")?.addEventListener("click",e=>executeBatch(host,state,e.currentTarget));
  host.querySelectorAll("[data-no-cut]").forEach(b=>b.addEventListener("click",()=>toggleNoCut(b.closest("[data-cut-item]"),true)));
  host.querySelectorAll("[data-confirm-no-cut]").forEach(b=>b.addEventListener("click",()=>resolveNoCut(host,state,b.closest("[data-cut-item]"),b)));
  host.querySelectorAll("[data-full-reel]").forEach(b=>b.addEventListener("click",()=>openFullReelDialog(host,state,b.closest("[data-cut-item]"))));
}

function pauseDialog(host,state){
  nestedDialog(host,{title:"Pausar corte",confirmLabel:"Confirmar pausa",body:`<div class="cut-dialog-guide"><strong>Usa la pausa solo si realmente vas a detener el trabajo.</strong><span>Este intervalo se descontará del tiempo activo de Corte.</span></div><div class="field"><label>Motivo de la pausa *</label><textarea class="control" name="reason" required rows="4" placeholder="Ej. cambio de turno, máquina ocupada, prioridad operativa…"></textarea></div>`,onConfirm:async d=>{const result=await api.cuttingPause(state.executionId,d.querySelector('[name="reason"]').value.trim());toast("Corte pausado.","success");renderPaused(host,result)}});
}

function cutRequirementRow(item,index){
  const done=Number(item.lengthCompleted||0),remaining=Number(item.remainingLength??item.totalLength??0),units=Number(item.unitsRemaining??item.unitsRequired??0);
  return `<article class="cut-reference-order" data-cut-item data-requirement-id="${fmt.escape(item.requirementId)}"><span class="cut-reference-index">${index+1}</span><div class="cut-reference-order-main"><small>${fmt.escape(item.orderNumber||"")} · ${fmt.escape(item.clientName||"")}</small><strong>${fmt.number(units,2)} corte(s) × ${fmt.number(item.lengthEach,3)} m</strong>${done>0?`<span>${fmt.number(done,3)} m ya ejecutados</span>`:""}</div><div class="cut-reference-order-total"><small>Falta</small><strong>${fmt.number(remaining,3)} m</strong></div>${remaining>0?`<details class="cut-guide-exception"><summary>Caso especial</summary><div class="cut-guide-exception-actions"><button type="button" class="btn btn-warning btn-compact" data-full-reel>Carreto completo</button><button type="button" class="btn btn-ghost btn-compact" data-no-cut>No necesita corte</button></div></details><section class="cutting-resolution-panel" data-resolution-panel="NO_CUT" hidden><label>Motivo obligatorio<textarea class="control" data-no-cut-reason></textarea></label><button type="button" class="btn btn-primary" data-confirm-no-cut>Confirmar corrección</button></section>`:'<span class="badge badge-blue">Corte físico listo</span>'}</article>`;
}

function batchHistoryRow(batch){return `<article class="cut-history-row"><div><strong>${fmt.escape(batch.lotNumber||"Carreto")}</strong><small>${fmt.escape(batch.location||"")} · ${dateTime(batch.executedAt)}</small></div><span>${fmt.number(batch.cutLength,3)} m cortados</span><b>${fmt.number(batch.remainingLength,3)} m restantes</b></article>`}
function normalizeOrigins(rows){return (rows||[]).map(r=>({lotId:r.lotId,inventoryItemId:r.inventoryItemId,lotNumber:r.lotNumber,serialNumber:r.serialNumber,warehouseCode:r.warehouseCode,location:r.location,locationName:r.locationName,available:Number(r.available??r.quantityAvailable??0),sourceSystem:r.sourceSystem}))}
function originRows(rows){return rows.length?rows.map(originRow).join(""):`<div class="cut-origin-empty"><strong>No hay carretos disponibles</strong><span>Actualiza el inventario oficial antes de continuar.</span></div>`}
function originRow(r){return `<button type="button" class="cut-origin-row" data-origin-lot="${fmt.escape(r.lotId)}"><div><small>${fmt.escape(r.warehouseCode||"Bodega")} · ${fmt.escape(r.locationName||r.location||"Sin ubicación")}</small><strong>${fmt.escape([r.lotNumber,r.serialNumber].filter(Boolean).join(" · ")||"Carreto sin identificación")}</strong><span>${fmt.escape(r.sourceSystem||"Inventario ERP")}</span></div><b>${fmt.number(r.available,3)} m</b><em>Seleccionar</em></button>`}

async function loadOrigins(host,state,search=""){
  const target=host.querySelector("[data-origin-results]");if(!target)return;target.innerHTML=loading("Buscando carretos compatibles…");
  try{
    if(sandboxMode){const g=await api.sandboxCuttingGroup(state.groupKey);state.origins=normalizeOrigins(g.reels||[]).filter(r=>!search||`${r.lotNumber||""} ${r.serialNumber||""} ${r.location||""}`.toLowerCase().includes(search.toLowerCase()))}
    else{const data=await api.cuttingOriginSearch(state.groupKey,search,60);state.origins=normalizeOrigins(data.items||[])}
    target.innerHTML=originRows(state.origins);target.querySelectorAll("[data-origin-lot]").forEach(b=>b.addEventListener("click",()=>selectOrigin(host,state,b.dataset.originLot)));
  }catch(error){target.innerHTML=`<div class="module-error"><strong>No fue posible consultar carretos</strong><p>${fmt.escape(error.message)}</p></div>`}
}

function selectOrigin(host,state,id){
  const row=state.origins.find(x=>String(x.lotId)===String(id));if(!row)return;
  state.selectedLotId=row.lotId;state.selectedOrigin=row;
  host.querySelectorAll("[data-origin-lot]").forEach(button=>button.classList.toggle("selected",String(button.dataset.originLot)===String(id)));
  const box=host.querySelector("[data-origin-confirm]");box.hidden=false;
  host.querySelector("[data-selected-origin]").innerHTML=`<div><small>Carreto seleccionado</small><strong>${fmt.escape([row.lotNumber,row.serialNumber].filter(Boolean).join(" · ")||"Carreto")}</strong><span>${fmt.escape(row.warehouseCode||"")} · ${fmt.escape(row.locationName||row.location||"")}</span></div><b>${fmt.number(row.available,3)} m en ERP</b>`;
  host.querySelector("[data-system-length]").value=String(row.available);host.querySelector("[data-reel-length]").value=String(row.available);state.reelLength=row.available;
  const preview=host.querySelector("[data-preview-batch]");if(preview)preview.disabled=false;
  syncDifference(host,state);box.scrollIntoView({behavior:"smooth",block:"nearest"});
}

function syncDifference(host,state){
  const real=Number(host.querySelector("[data-reel-length]")?.value||0);state.reelLength=real;state.scrapLength=Number(host.querySelector("[data-scrap-length]")?.value||0);
  const diff=real-Number(state.selectedOrigin?.available||0),target=host.querySelector("[data-inventory-difference]");if(!target)return;
  const preview=host.querySelector("[data-preview-batch]");if(preview)preview.disabled=!state.selectedOrigin||real<=0;
  if(!state.selectedOrigin||real<=0||Math.abs(diff)<.0001){target.hidden=true;target.innerHTML="";return}
  target.hidden=false;target.innerHTML=`<strong>Diferencia de inventario: ${diff>0?"+":""}${fmt.number(diff,3)} m</strong><span>El ERP registrará el recuento físico antes de descontar los cortes.</span>`;
}

async function previewBatch(host,state){
  if(!state.selectedOrigin){toast("Selecciona primero el carreto físico.","error");return}
  const reel=Number(host.querySelector("[data-reel-length]")?.value||0),scrap=Number(host.querySelector("[data-scrap-length]")?.value||0);
  if(reel<=0){toast("Indica la cantidad real encontrada.","error");return}if(scrap<0){toast("La merma no puede ser negativa.","error");return}
  state.reelLength=reel;state.scrapLength=scrap;showStep(host,3);const target=host.querySelector("[data-cut-plan]");target.innerHTML=loading("Distribuyendo cortes completos…");
  try{state.plan=sandboxMode?localSandboxPlan(state):await api.cuttingExecutionPlan(state.executionId,state.selectedLotId,reel,scrap);renderPlan(host,state)}
  catch(error){state.plan=null;target.innerHTML=`<div class="module-error"><strong>No fue posible calcular el plan</strong><p>${fmt.escape(error.message)}</p></div>`}
}

function localSandboxPlan(state){
  const required=Number(state.group.totalLength||0),capacity=Math.max(state.reelLength-state.scrapLength,0),cut=Math.min(required,capacity);
  return {canExecute:capacity>=required,reason:capacity>=required?null:"En Sandbox selecciona un carreto que cubra el grupo.",systemLength:Number(state.selectedOrigin?.available||0),confirmedLength:state.reelLength,discrepancy:state.reelLength-Number(state.selectedOrigin?.available||0),plannedLength:cut,plannedCuts:Number(state.group.cutCount||0),scrapLength:state.scrapLength,reelRemaining:state.reelLength-cut-state.scrapLength,groupRemainingAfter:Math.max(required-cut,0),groupCompleted:capacity>=required,partialBatch:capacity<required,approvalRequired:false,approvalReady:true,plan:[]};
}

function renderPlan(host,state){
  const p=state.plan||{},target=host.querySelector("[data-cut-plan]"),button=host.querySelector("[data-execute-batch]");
  if(!p.canExecute){target.innerHTML=`<section class="cut-plan-blocked"><strong>Este carreto no permite completar ningún corte</strong><p>${fmt.escape(p.reason||"")}</p></section>`;button.disabled=true;return}
  target.innerHTML=`<section class="cut-plan-focus"><div class="cut-plan-key"><small>Vas a cortar ahora</small><strong>${fmt.number(p.plannedLength,3)} m</strong><span>${fmt.number(p.plannedCuts||0,2)} corte(s)</span></div><div class="cut-plan-equation"><div><small>Carreto físico</small><strong>${fmt.number(p.confirmedLength,3)} m</strong></div><b>−</b><div><small>Corte</small><strong>${fmt.number(p.plannedLength,3)} m</strong></div>${Number(p.scrapLength||0)>0?`<b>−</b><div><small>Merma</small><strong>${fmt.number(p.scrapLength,3)} m</strong></div>`:""}<b>=</b><div class="result"><small>Remanente</small><strong>${fmt.number(p.reelRemaining,3)} m</strong></div></div></section>${p.partialBatch?`<section class="cut-next-reel"><strong>Después necesitarás otro carreto</strong><p>Se registrará este consumo y volverás a seleccionar origen. Quedarán ${fmt.number(p.groupRemainingAfter,3)} m pendientes.</p></section>`:`<section class="cut-last-reel"><strong>Este es el último carreto de la ejecución</strong><p>Después de confirmarlo pasarás a la foto final obligatoria.</p></section>`}${(p.plan||[]).length?`<section class="cut-plan-orders"><header><strong>Pedidos que se cortan con este carreto</strong></header>${p.plan.map(planRow).join("")}</section>`:""}${p.approvalRequired?`<section class="cutting-approval-warning"><strong>Remanente crítico: ${fmt.number(p.reelRemaining,3)} m</strong><p>${p.approvalReady?"La aprobación ya está disponible.":"Debes solicitar aprobación antes de ejecutar este carreto."}</p>${p.approvalReady?"":'<button type="button" class="btn btn-warning" data-request-remainder-approval>Enviar a aprobación</button>'}</section>`:""}`;
  button.disabled=Boolean(p.approvalRequired&&!p.approvalReady);button.textContent=p.partialBatch?"Confirmar carreto y seguir":"Confirmar último carreto";
  target.querySelector("[data-request-remainder-approval]")?.addEventListener("click",()=>requestRemainderApproval(host,state));
}

function planRow(row){return `<article><div><strong>${fmt.escape(row.orderNumber||"Pedido")}</strong><small>${fmt.escape(row.clientName||"")}</small></div><span>${fmt.number(row.unitsToCut,2)} × ${fmt.number(row.lengthEach,3)} m</span><b>${fmt.number(row.lengthToCut,3)} m</b></article>`}

async function executeBatch(host,state,button){
  button.disabled=true;const original=button.textContent;button.textContent="Registrando corte…";
  try{
    const payload={inventoryLotId:state.selectedLotId,reelLength:state.reelLength,scrapLength:state.scrapLength,expectedPlannedLength:Number(state.plan?.plannedLength||0)};
    const result=await (sandboxMode?api.sandboxExecuteCutGroup(state.groupKey,payload):api.executeCutGroup(state.groupKey,payload));
    await loadCuttingGroups(currentPage);
    if(result.waitingEvidence||result.groupCompleted){toast("Corte físico completo. Falta la foto final para cerrar.","success",7000);const detail=await api.cuttingExecution(state.executionId);renderEvidence(host,detail)}
    else{const message=`${fmt.number(result.cutLength,3)} m registrados. Quedan ${fmt.number(result.groupRemainingLength,3)} m.`;toast(message,"success",7000);await openCutGroup(state.groupKey,{message})}
  }catch(error){toast(error.message,"error",9000);button.disabled=false;button.textContent=original}
}

async function openFullReelDialog(host,state,item){
  const req=state.items.find(r=>String(r.requirementId)===String(item?.dataset.requirementId));if(!req)return;
  try{
    if(!state.origins.length){if(sandboxMode){const g=await api.sandboxCuttingGroup(state.groupKey);state.origins=normalizeOrigins(g.reels||[])}else{const result=await api.cuttingOriginSearch(state.groupKey,"",60);state.origins=normalizeOrigins(result.items||[])}}
    if(!state.origins.length){toast("No hay carretos compatibles disponibles.","error");return}
    nestedDialog(host,{title:"Carreto completo",confirmLabel:"Confirmar carreto completo",body:`<div class="cut-dialog-guide"><strong>${fmt.escape(req.orderNumber||"Pedido")} · ${fmt.escape(state.group.reference||"")}</strong><span>Usa esta opción solo cuando el carreto físico completo coincide exactamente con los ${fmt.number(req.remainingLength,3)} m pendientes.</span></div><div class="field"><label>Carreto físico *</label><select class="control" name="lotId" required><option value="">Seleccionar…</option>${state.origins.map(r=>`<option value="${fmt.escape(r.lotId)}">${fmt.escape([r.lotNumber,r.serialNumber].filter(Boolean).join(" · ")||"Carreto")} · ${fmt.number(r.available,3)} m · ${fmt.escape(r.locationName||r.location||"")}</option>`).join("")}</select></div><div class="field"><label>Medida exacta</label><input class="control" name="reelLength" type="number" step="0.0001" value="${Number(req.remainingLength||0)}" readonly></div>`,onConfirm:async dialog=>{const lotId=dialog.querySelector('[name="lotId"]').value;await (sandboxMode?api.sandboxResolveCutRequirement(req.requirementId,"FULL_REEL",{inventoryLotId:lotId,reelLength:Number(req.remainingLength)}):api.resolveCutRequirement(req.requirementId,"FULL_REEL",{inventoryLotId:lotId,reelLength:Number(req.remainingLength)}));toast("Carreto completo registrado.","success");await openCutGroup(state.groupKey)}});
  }catch(error){toast(error.message,"error",8000)}
}

function requestRemainderApproval(host,state){
  const p=state.plan||{};
  nestedDialog(host,{title:"Autorizar remanente crítico",confirmLabel:"Enviar solicitud",body:`<div class="cut-dialog-guide warning"><strong>Remanente proyectado: ${fmt.number(p.reelRemaining,3)} m</strong><span>La aprobación quedará ligada a este carreto y a este plan específico.</span></div><div class="field"><label>Enviar a *</label><select class="control" name="assignedRole" required><option value="jefe_logistica">Jefatura Logística</option><option value="auditoria">Auditoría</option><option value="gerencia">Gerencia</option></select></div><div class="field"><label>Justificación *</label><textarea class="control" name="reason" required rows="4"></textarea></div>`,onConfirm:async dialog=>{await api.requestCutRemainderApproval(state.groupKey,{inventoryLotId:state.selectedLotId,reelLength:state.reelLength,scrapLength:state.scrapLength,assignedRole:dialog.querySelector('[name="assignedRole"]').value,reason:dialog.querySelector('[name="reason"]').value.trim()});const paused=await api.cuttingPause(state.executionId,"Esperando aprobación de remanente crítico");toast("Solicitud enviada. Corte quedó pausado mientras esperas la aprobación.","success",7500);renderPaused(host,paused)}});
}

function toggleNoCut(item,show){const panel=item?.querySelector('[data-resolution-panel="NO_CUT"]');if(panel)panel.hidden=!show}
async function resolveNoCut(host,state,item,button){const id=item?.dataset.requirementId,reason=item?.querySelector("[data-no-cut-reason]")?.value.trim();if(!reason){toast("Escribe el motivo.","error");return}button.disabled=true;try{await (sandboxMode?api.sandboxResolveCutRequirement(id,"NO_CUT",{reason}):api.resolveCutRequirement(id,"NO_CUT",{reason}));toast("Corrección registrada.","success");await openCutGroup(state.groupKey)}catch(error){toast(error.message,"error");button.disabled=false}}

function nestedDialog(host,{title,body,confirmLabel="Confirmar",onConfirm}){
  const layer=document.createElement("div");layer.className="cut-nested-layer";
  layer.innerHTML=`<section class="cut-nested-dialog"><header><div><span>ACCIÓN ESPECIAL DE CORTE</span><h4>${fmt.escape(title)}</h4></div><button class="icon-btn" data-nested-close aria-label="Cerrar">×</button></header><div class="cut-nested-body">${body}</div><footer><button class="btn btn-ghost" data-nested-close>Cancelar</button><button class="btn btn-primary" data-nested-confirm>${fmt.escape(confirmLabel)}</button></footer></section>`;
  host.append(layer);const close=()=>layer.remove();layer.querySelectorAll("[data-nested-close]").forEach(b=>b.onclick=close);
  layer.querySelector("[data-nested-confirm]").onclick=async event=>{for(const control of layer.querySelectorAll("input,select,textarea")){if(!control.checkValidity()){control.reportValidity();return}}event.currentTarget.disabled=true;try{await onConfirm(layer);close()}catch(error){toast(error.message,"error");event.currentTarget.disabled=false}};
}

function showStep(host,n){
  host.querySelectorAll("[data-cut-step]").forEach(panel=>panel.hidden=Number(panel.dataset.cutStep)!==n);
  host.querySelectorAll("[data-cut-progress]").forEach(item=>{const value=Number(item.dataset.cutProgress);item.classList.toggle("active",value===n);item.classList.toggle("done",value<n)});
  host.querySelector(".cut-reference-body")?.scrollTo({top:0,behavior:"smooth"});
}

function guidedFooter(note="El avance queda guardado al confirmar cada acción."){
  return `<footer class="modal-foot cut-guided-footer"><div><strong>Trabajo seguro</strong><span>${fmt.escape(note)}</span></div><button class="btn btn-ghost" data-close>Cerrar</button></footer>`;
}
function bindClose(host){host.querySelectorAll("[data-close]").forEach(b=>b.addEventListener("click",()=>host.replaceChildren()))}
function dateTime(value){if(!value)return "—";try{return new Date(value).toLocaleString("es-CO",{dateStyle:"short",timeStyle:"short"})}catch{return String(value)}}
function duration(seconds){const s=Math.max(0,Math.round(Number(seconds||0))),h=Math.floor(s/3600),m=Math.floor((s%3600)/60);return h?`${h} h ${m} min`:`${m} min`}
function startTimer(host,baseSeconds=0){const node=host.querySelector("[data-cut-timer]");if(!node)return;const started=Date.now();const tick=()=>{if(!node.isConnected)return;node.textContent=duration(Number(baseSeconds||0)+(Date.now()-started)/1000)};tick();const id=setInterval(()=>{if(!node.isConnected){clearInterval(id);return}tick()},30000)}
