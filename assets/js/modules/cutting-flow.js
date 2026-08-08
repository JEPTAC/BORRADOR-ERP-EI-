import {api} from "../services/api.js";
import {fmt} from "../core/format.js";
import {empty,loading,paginationHtml,toast,modal} from "../core/ui.js";
import {navigate} from "../core/router.js";
import {parallelWorkFooter} from "./active-work.js";

let currentRoot=null;
let currentPage=1;

export function isCuttingFlow(data){
  return data?.order?.current_step_code==="CORTE";
}

export async function renderCutting(root){
  currentRoot=root;
  root.innerHTML=`
    <section class="page-head cutting-page-head">
      <div><span class="cutting-kicker">Centro de corte</span><h2>Cortes pendientes por referencia</h2><p>Las solicitudes iguales se consolidan para calcular el carreto necesario y ejecutar varios pedidos en una sola operación.</p></div>
      <div class="page-actions"><button class="btn btn-ghost" id="cutting-refresh">Actualizar</button></div>
    </section>
    <section class="cutting-guide-strip">
      <div><span>1</span><strong>Selecciona una referencia</strong><small>Verás todos los pedidos y cortes agrupados.</small></div>
      <div><span>2</span><strong>Confirma el carreto</strong><small>El ERP calcula consumo y remanente.</small></div>
      <div><span>3</span><strong>Ejecuta y entrega</strong><small>Alistamiento recibe automáticamente los cortes.</small></div>
    </section>
    <section class="card card-pad cutting-workspace">
      <div class="cutting-toolbar">
        <input class="control search-wide" id="cutting-search" placeholder="Buscar referencia, SKU o material">
        <button class="btn btn-primary" id="cutting-search-button">Buscar</button>
      </div>
      <div id="cutting-result">${loading("Agrupando cortes pendientes…")}</div>
    </section>`;

  root.querySelector("#cutting-search-button")?.addEventListener("click",()=>loadCuttingGroups(1));
  root.querySelector("#cutting-refresh")?.addEventListener("click",()=>loadCuttingGroups(currentPage));
  root.querySelector("#cutting-search")?.addEventListener("keydown",event=>{if(event.key==="Enter")loadCuttingGroups(1)});
  window.__erpCuttingRefresh=()=>loadCuttingGroups(currentPage);
  await loadCuttingGroups(1);
}

async function loadCuttingGroups(page=1){
  const root=currentRoot;
  if(!root?.isConnected)return;
  currentPage=page;
  const target=root.querySelector("#cutting-result");
  target.innerHTML=loading("Calculando requerimientos por referencia…");
  try{
    const search=root.querySelector("#cutting-search")?.value.trim()||"";
    const data=await api.cuttingGroups(search,page,50);
    const rows=data.items||[];
    target.innerHTML=rows.length?`
      <div class="cutting-result-head"><div><strong>${fmt.number(data.pagination?.totalItems||rows.length)} referencia(s)</strong><span>Solo se muestran cortes disponibles para tu usuario.</span></div></div>
      <div class="cutting-group-grid">${rows.map(groupCard).join("")}</div>
      ${paginationHtml(data.pagination)}`:empty("No hay cortes pendientes","Cuando Recepción confirme un pedido con corte, sus referencias aparecerán agrupadas aquí.");
    target.querySelectorAll("[data-cut-group]").forEach(card=>card.addEventListener("click",()=>openCutGroup(card.dataset.cutGroup)));
    target.querySelectorAll("[data-page]").forEach(button=>button.addEventListener("click",()=>loadCuttingGroups(Number(button.dataset.page))));
  }catch(error){
    target.innerHTML=`<div class="module-error"><strong>No fue posible cargar Corte</strong><p>${fmt.escape(error.message)}</p><button class="btn btn-primary" data-retry>Reintentar</button></div>`;
    target.querySelector("[data-retry]")?.addEventListener("click",()=>loadCuttingGroups(page));
    toast(error.message,"error",8000);
  }
}

function groupCard(group){
  return `<button type="button" class="cutting-group-card ${group.inProgress?"in-progress":""}" data-cut-group="${fmt.escape(group.groupKey)}">
    <header><div><span class="cutting-reference">${fmt.escape(group.reference||group.sku||"Sin referencia")}</span><strong>${fmt.escape(group.description)}</strong>${group.variantLabel?`<small class="cutting-variant-badge">${fmt.escape(group.variantLabel)}</small>`:""}</div><span class="cutting-state">${group.inProgress?"En ejecución":"Pendiente"}</span></header>
    <div class="cutting-total"><small>Longitud total requerida</small><strong>${fmt.number(group.totalLength,3)} <b>m</b></strong></div>
    <div class="cutting-card-metrics">
      <div><small>Cortes</small><strong>${fmt.number(group.cutCount,2)}</strong></div>
      <div><small>Ítems</small><strong>${fmt.number(group.itemCount)}</strong></div>
      <div><small>Pedidos</small><strong>${fmt.number(group.orderCount)}</strong></div>
    </div>
    <footer><span>Agrupado por material oficial${group.variantLabel?" y variante":""}</span><strong>Abrir grupo →</strong></footer>
  </button>`;
}

export function renderCuttingOrder(host,data){
  host.innerHTML=`<div class="modal-overlay simple-process-overlay">
    <section class="modal simple-process-modal cutting-order-notice">
      <header class="modal-head simple-process-head"><div><span class="wizard-kicker">Corte agrupado</span><h3>${fmt.escape(data.order.order_number)}</h3><p>${fmt.escape(data.order.client_name)}</p></div><button class="icon-btn" data-close>×</button></header>
      <div class="modal-body simple-process-body">
        <section class="cutting-order-message"><span>CT</span><div><h4>Este pedido se gestiona desde el Centro de corte</h4><p>Las referencias se agrupan con otros pedidos iguales para calcular el carreto total y ejecutar los cortes con menor desperdicio.</p></div></section>
        <div class="cutting-order-summary"><div><small>Referencias con corte</small><strong>${(data.cutRequirements||[]).filter(item=>item.process_status!=="READY").length||data.items.filter(item=>item.requires_cut).length}</strong></div><div><small>Auxiliar asignado</small><strong>${fmt.escape(data.order.current_role_code?fmt.role(data.order.current_role_code):"Corte")}</strong></div></div>
        <button class="btn btn-primary btn-large cutting-open-center" data-open-cutting>Abrir Centro de corte</button>
      </div>
      ${parallelWorkFooter("CORTE")}
    </section>
  </div>`;
  host.querySelectorAll("[data-close]").forEach(button=>button.addEventListener("click",()=>host.replaceChildren()));
  host.querySelector("[data-open-cutting]")?.addEventListener("click",()=>{host.replaceChildren();navigate("cutting")});
}

async function openCutGroup(groupKey){
  const host=document.querySelector("#modal-root");
  host.innerHTML=`<div class="modal-overlay cutting-overlay"><section class="modal cutting-group-modal"><div class="modal-body">${loading("Preparando el grupo de corte…")}</div></section></div>`;
  try{
    const [data,optimizer]=await Promise.all([api.cuttingGroup(groupKey),api.cuttingOptimizer(groupKey)]);
    renderCutGroup(host,data,optimizer);
  }catch(error){
    host.innerHTML=`<div class="modal-overlay"><section class="modal"><header class="modal-head"><h3>No fue posible abrir el grupo</h3><button class="icon-btn" data-close>×</button></header><div class="modal-body"><p class="danger">${fmt.escape(error.message)}</p></div></section></div>`;
    host.querySelector("[data-close]")?.addEventListener("click",()=>host.replaceChildren());
  }
}

function renderCutGroup(host,data,optimizer={}){
  const group=data.group||{};
  const items=data.items||[];
  const reels=data.reels||[];
  host.innerHTML=`<div class="modal-overlay cutting-overlay">
    <section class="modal cutting-group-modal">
      <header class="modal-head cutting-modal-head">
        <div><span class="cutting-kicker">Material oficial agrupado</span><h3>${fmt.escape(group.reference||group.sku||"Sin referencia")}</h3><p>${fmt.escape(group.description||"")}${group.variantLabel?` · <strong>${fmt.escape(group.variantLabel)}</strong>`:""}</p></div>
        <button class="icon-btn" data-close aria-label="Cerrar">×</button>
      </header>
      <div class="modal-body cutting-modal-body">
        <section class="cutting-group-summary">
          <div><small>Cantidad a cortar</small><strong>${fmt.number(group.cutCount,2)} <b>corte(s)</b></strong></div>
          <div><small>Longitud requerida</small><strong>${fmt.number(group.totalLength,3)} <b>m</b></strong></div>
          <div><small>Pedidos incluidos</small><strong>${fmt.number(group.orderCount)}</strong></div>
          <div><small>Carretos disponibles</small><strong>${reels.length}</strong></div>
        </section>

        <section class="cutting-layout">
          <div class="cutting-items-panel">
            <header><div><h4>Detalle individual</h4><p>Cada línea conserva su pedido y puede resolverse por separado cuando corresponda.</p></div><span>${items.length} ítem(s)</span></header>
            <div class="cutting-item-list">${items.map((item,index)=>cutItem(item,index,reels)).join("")}</div>
          </div>

          <aside class="cutting-calculator">
            <span class="cutting-step-tag">Ejecutar todos</span>
            <h4>Carreto de trabajo</h4>
            <p>Confirma cuánto tiene el carreto. El ERP descontará los cortes y dejará el remanente registrado en Inventario.</p>
            ${optimizerPanel(optimizer)}
            ${reelControls("group",reels,group.totalLength)}
            <section class="cutting-live-balance" data-balance>
              <div><small>Disponible</small><strong data-balance-reel>0 m</strong></div>
              <span>−</span><div><small>Cortes</small><strong>${fmt.number(group.totalLength,3)} m</strong></div>
              <span>−</span><div><small>Merma</small><strong data-balance-scrap>0 m</strong></div>
              <span>=</span><div class="remaining"><small>Queda</small><strong data-balance-remaining>0 m</strong></div>
            </section>
            <section class="cutting-approval-warning" data-cut-approval-warning hidden><span>APROBACIÓN REQUERIDA</span><strong>El remanente quedará por debajo de 50 m</strong><p>Solicita autorización antes de ejecutar el corte. Puedes seguir trabajando otros grupos mientras se decide.</p><button type="button" class="btn btn-warning" data-request-remainder-approval>Enviar a aprobación</button></section>
            <button type="button" class="btn btn-primary cutting-execute-all" data-execute-group>Ejecutar todos los cortes de esta referencia</button>
            <small class="cutting-calculator-note">La operación es transaccional: si algo falla, no se descuenta inventario ni se cierra ningún pedido.</small>
          </aside>
        </section>
      </div>
      ${parallelWorkFooter("CORTE")}
    </section>
  </div>`;

  host.querySelectorAll("[data-close]").forEach(button=>button.addEventListener("click",()=>host.replaceChildren()));
  bindReelMode(host,"group",reels);
  bindOptimizer(host,optimizer);
  bindBalance(host,Number(group.totalLength||0));
  host.querySelector("[data-request-remainder-approval]")?.addEventListener("click",()=>{
    const payload=readReelPayload(host,"group");
    if(!payload)return;
    modal({title:"Aprobar remanente crítico",confirmLabel:"Enviar solicitud",size:"wide",body:`<div class="cutting-approval-dialog"><strong>El carreto quedará con menos de 50 metros.</strong><p>La ejecución seguirá bloqueada hasta que la excepción sea aprobada. Los demás grupos de Corte pueden seguir trabajando.</p></div><div class="field"><label>Enviar a *</label><select class="control" name="assignedRole" required><option value="jefe_logistica">Jefatura Logística</option><option value="auditoria">Auditoría</option><option value="gerencia">Gerencia</option></select></div><div class="field"><label>Justificación *</label><textarea class="control" name="reason" required rows="4" placeholder="Explica por qué conviene utilizar este carreto"></textarea></div>`,onConfirm:async dialog=>{
      await api.requestCutRemainderApproval(group.groupKey,{...payload,assignedRole:dialog.querySelector('[name="assignedRole"]').value,reason:dialog.querySelector('[name="reason"]').value.trim()});
      toast("Solicitud de remanente enviada a aprobación.","success",6500);
    }});
  });

  host.querySelector("[data-execute-group]")?.addEventListener("click",async event=>{
    const payload=readReelPayload(host,"group");
    if(!payload)return;
    event.currentTarget.disabled=true;
    try{
      const result=await api.executeCutGroup(group.groupKey,payload);
      toast(`Cortes ejecutados. Quedan ${fmt.number(result.remainingLength,3)} m en el carreto.`,"success",7000);
      host.replaceChildren();
      await loadCuttingGroups(currentPage);
      window.__erpQueueRefresh?.();
      window.__erpOrderListRefresh?.();
    }catch(error){toast(error.message,"error",8000);event.currentTarget.disabled=false}
  });

  host.querySelectorAll("[data-full-reel]").forEach(button=>button.addEventListener("click",()=>toggleResolutionPanel(host,button.closest("[data-cut-item]"),"FULL_REEL")));
  host.querySelectorAll("[data-no-cut]").forEach(button=>button.addEventListener("click",()=>toggleResolutionPanel(host,button.closest("[data-cut-item]"),"NO_CUT")));
  host.querySelectorAll("[data-cancel-resolution]").forEach(button=>button.addEventListener("click",()=>closeResolution(button.closest("[data-cut-item]"))));
  host.querySelectorAll("[data-confirm-full-reel]").forEach(button=>button.addEventListener("click",()=>resolveIndividual(host,group.groupKey,button.closest("[data-cut-item]"),"FULL_REEL",button)));
  host.querySelectorAll("[data-confirm-no-cut]").forEach(button=>button.addEventListener("click",()=>resolveIndividual(host,group.groupKey,button.closest("[data-cut-item]"),"NO_CUT",button)));
  items.forEach(item=>bindReelMode(host,`item-${item.requirementId}`,reels));
}

function optimizerPanel(optimizer={}){
  const recommended=optimizer.recommended||null;
  const best=optimizer.bestMaterialUse||null;
  const candidates=optimizer.candidates||[];
  if(!candidates.length)return `<section class="cut-optimizer empty"><div><span>OPTIMIZADOR</span><strong>No hay carretos registrados para sugerir</strong><p>Registra o selecciona manualmente un carreto para esta referencia.</p></div></section>`;
  const same=recommended?.lotId&&best?.lotId===recommended.lotId;
  return `<section class="cut-optimizer">
    <header><div><span>OPTIMIZADOR DE CARRETOS</span><strong>Sugerencia para minimizar desperdicio</strong><p>El ERP prioriza un carreto suficiente que no obligue aprobación. La decisión final sigue siendo del operario.</p></div><small>${fmt.number(optimizer.requiredLength,3)} m requeridos</small></header>
    <div class="cut-optimizer-main">
      ${recommended?optimizerChoice("Recomendado",recommended,"recommended"):""}
      ${best&&!same?optimizerChoice("Mayor aprovechamiento",best,"material"):""}
    </div>
    <details><summary>Comparar ${candidates.length} carreto(s) disponible(s)</summary><div class="cut-optimizer-list">${candidates.map((candidate,index)=>`<button type="button" class="cut-optimizer-candidate" data-optimizer-lot="${fmt.escape(candidate.lotId)}" data-optimizer-length="${Number(candidate.usableLength||0)}"><span>#${index+1} ${fmt.escape(candidate.lotNumber||"Sin lote")}</span><strong>${fmt.number(candidate.usableLength,3)} m</strong><small>${candidate.sufficient?`Quedarían ${fmt.number(candidate.projectedRemaining,3)} m${candidate.approvalRequired?" · requiere aprobación":""}`:`Faltan ${fmt.number(Math.abs(candidate.projectedRemaining),3)} m`}</small></button>`).join("")}</div></details>
  </section>`;
}

function optimizerChoice(label,candidate,kind){
  const insufficient=Number(candidate.projectedRemaining||0)<0;
  return `<article class="cut-optimizer-choice ${candidate.approvalRequired?"approval":""} ${insufficient?"insufficient":""}"><span>${label}</span><strong>${fmt.escape([candidate.lotNumber,candidate.serialNumber].filter(Boolean).join(" · ")||"Sin lote")}</strong><p>${fmt.number(candidate.usableLength,3)} m disponibles · ${fmt.escape(candidate.locationName||candidate.location||"Sin ubicación")} · ${insufficient?`faltan ${fmt.number(Math.abs(candidate.projectedRemaining),3)} m`:`remanente ${fmt.number(candidate.projectedRemaining,3)} m`}</p>${candidate.approvalRequired?`<small>Requiere aprobación por remanente menor a 50 m</small>`:""}<button type="button" class="btn btn-ghost btn-compact" data-optimizer-lot="${fmt.escape(candidate.lotId)}" data-optimizer-length="${Number(candidate.usableLength||0)}">Usar esta sugerencia</button></article>`;
}

function bindOptimizer(host,optimizer={}){
  host.querySelectorAll("[data-optimizer-lot]").forEach(button=>button.addEventListener("click",()=>{
    const box=host.querySelector('[data-reel-fields="group"]');
    if(!box)return;
    const select=box.querySelector("[data-reel-select]");
    const option=[...select.options].find(item=>item.value===button.dataset.optimizerLot);
    if(!option){toast("El carreto sugerido ya no está disponible. Actualiza el grupo.","error");return}
    select.value=button.dataset.optimizerLot;
    select.dispatchEvent(new Event("change",{bubbles:true}));
    const length=box.querySelector("[data-reel-length]");
    if(length&&button.dataset.optimizerLength)length.value=button.dataset.optimizerLength;
    length?.dispatchEvent(new Event("input",{bubbles:true}));
    box.scrollIntoView({behavior:"smooth",block:"center"});
    toast("Carreto sugerido aplicado. Revisa el balance antes de ejecutar.","success",5000);
  }));
}

function cutItem(item,index,reels){
  return `<article class="cutting-item" data-cut-item data-requirement-id="${fmt.escape(item.requirementId)}">
    <div class="cutting-item-index">${index+1}</div>
    <div class="cutting-item-main"><span>${fmt.escape(item.orderNumber)} · ${fmt.escape(item.clientName)}</span><strong>${fmt.escape(item.reference||item.sku||item.description)}</strong><p>${fmt.escape(item.description)}</p></div>
    <div class="cutting-item-quantity"><small>Cantidad</small><strong>${fmt.number(item.unitsRequired,2)} × ${fmt.number(item.lengthEach,3)} m</strong><b>${fmt.number(item.totalLength,3)} m total</b></div>
    <div class="cutting-item-actions"><button type="button" class="btn btn-warning" data-full-reel>Carreto completo</button><button type="button" class="btn btn-ghost" data-no-cut>No necesita corte</button></div>
    <section class="cutting-resolution-panel" data-resolution-panel="FULL_REEL" hidden>
      <header><div><strong>Entregar carreto completo</strong><p>Solo se confirma si la medida del carreto coincide exactamente con este ítem.</p></div><button class="icon-btn" data-cancel-resolution>×</button></header>
      ${reelControls(`item-${item.requirementId}`,reels,item.totalLength,true)}
      <button type="button" class="btn btn-success" data-confirm-full-reel>Confirmar carreto completo</button>
    </section>
    <section class="cutting-resolution-panel" data-resolution-panel="NO_CUT" hidden>
      <header><div><strong>Corregir asignación de corte</strong><p>La referencia quedará disponible para recoger en Alistamiento.</p></div><button class="icon-btn" data-cancel-resolution>×</button></header>
      <label>Motivo obligatorio<textarea class="control" data-no-cut-reason placeholder="Explica por qué esta referencia no necesita corte"></textarea></label>
      <button type="button" class="btn btn-primary" data-confirm-no-cut>Confirmar que no necesita corte</button>
    </section>
  </article>`;
}

function reelControls(prefix,reels,required,exact=false){
  return `<div class="cutting-reel-fields" data-reel-fields="${fmt.escape(prefix)}" data-required="${Number(required||0)}">
    <label>Carreto<select class="control" data-reel-select><option value="">Registrar nuevo carreto</option>${reels.map(reel=>`<option value="${fmt.escape(reel.lotId)}" data-length="${Number(reel.quantityAvailable||0)}">${fmt.escape([reel.variantLabel,reel.lotNumber,reel.serialNumber].filter(Boolean).join(" · ")||"Sin lote")} · ${fmt.number(reel.quantityAvailable,3)} m · ${fmt.escape(reel.locationName||reel.location||"Sin ubicación")}</option>`).join("")}</select></label>
    <label>${exact?"Medida exacta del carreto":"Longitud disponible del carreto"} *<input class="control" data-reel-length type="number" min="0.0001" step="0.0001" value="${exact?Number(required||0):""}" placeholder="Ej. 500"></label>
    <label data-new-reel-field>Número o identificación<input class="control" data-lot-number placeholder="Ej. CR-0245"></label>
    <label data-new-reel-field>Ubicación<input class="control" data-location value="CORTE" placeholder="Ubicación física"></label>
    ${exact?"":'<label>Merma adicional<input class="control" data-scrap-length type="number" min="0" step="0.0001" value="0"></label>'}
  </div>`;
}

function bindReelMode(host,prefix,reels){
  const box=host.querySelector(`[data-reel-fields="${CSS.escape(prefix)}"]`);
  if(!box)return;
  const select=box.querySelector("[data-reel-select]");
  const length=box.querySelector("[data-reel-length]");
  const sync=()=>{
    const option=select.selectedOptions[0];
    const existing=Boolean(select.value);
    box.querySelectorAll("[data-new-reel-field]").forEach(field=>field.hidden=existing);
    if(existing&&option?.dataset.length)length.value=option.dataset.length;
    length.dispatchEvent(new Event("input",{bubbles:true}));
  };
  select.addEventListener("change",sync);
  sync();
}

function bindBalance(host,required){
  const box=host.querySelector('[data-reel-fields="group"]');
  if(!box)return;
  const sync=()=>{
    const reel=Number(box.querySelector("[data-reel-length]")?.value||0);
    const scrap=Number(box.querySelector("[data-scrap-length]")?.value||0);
    const remaining=reel-required-scrap;
    host.querySelector("[data-balance-reel]").textContent=`${fmt.number(reel,3)} m`;
    host.querySelector("[data-balance-scrap]").textContent=`${fmt.number(scrap,3)} m`;
    const value=host.querySelector("[data-balance-remaining]");
    value.textContent=`${fmt.number(remaining,3)} m`;
    value.closest(".remaining")?.classList.toggle("negative",remaining<0);
    const critical=remaining>0&&remaining<50;
    const warning=host.querySelector("[data-cut-approval-warning]");if(warning)warning.hidden=!critical;
    const button=host.querySelector("[data-execute-group]");
    if(button){button.disabled=reel<=0||remaining<0;button.textContent=critical?"Ejecutar cortes (requiere aprobación)":"Ejecutar todos los cortes de esta referencia";}
  };
  box.querySelectorAll("input,select").forEach(control=>control.addEventListener("input",sync));
  sync();
}

function readReelPayload(scope,prefix){
  const box=scope.querySelector(`[data-reel-fields="${CSS.escape(prefix)}"]`);
  if(!box)return null;
  const reelLength=Number(box.querySelector("[data-reel-length]")?.value||0);
  const scrapLength=Number(box.querySelector("[data-scrap-length]")?.value||0);
  if(!Number.isFinite(reelLength)||reelLength<=0){toast("Indica cuánto tiene el carreto.","error");box.querySelector("[data-reel-length]")?.focus();return null}
  if(!Number.isFinite(scrapLength)||scrapLength<0){toast("La merma no puede ser negativa.","error");return null}
  const inventoryLotId=box.querySelector("[data-reel-select]")?.value||null;
  const lotNumber=box.querySelector("[data-lot-number]")?.value.trim()||null;
  const location=box.querySelector("[data-location]")?.value.trim()||"CORTE";
  return {reelLength,scrapLength,inventoryLotId,lotNumber,location};
}

function toggleResolutionPanel(host,item,mode){
  host.querySelectorAll("[data-cut-item]").forEach(row=>{
    row.querySelectorAll("[data-resolution-panel]").forEach(panel=>panel.hidden=!(row===item&&panel.dataset.resolutionPanel===mode));
    row.classList.toggle("resolving",row===item);
  });
  item.querySelector(`[data-resolution-panel="${mode}"]`)?.scrollIntoView({behavior:"smooth",block:"nearest"});
}
function closeResolution(item){item.querySelectorAll("[data-resolution-panel]").forEach(panel=>panel.hidden=true);item.classList.remove("resolving")}

async function resolveIndividual(host,groupKey,item,mode,button){
  const requirementId=item.dataset.requirementId;
  let payload={};
  if(mode==="FULL_REEL"){
    payload=readReelPayload(item,`item-${requirementId}`);
    if(!payload)return;
  }else{
    const reason=item.querySelector("[data-no-cut-reason]")?.value.trim();
    if(!reason){toast("Escribe el motivo de la corrección.","error");item.querySelector("[data-no-cut-reason]")?.focus();return}
    payload={reason};
  }
  button.disabled=true;
  try{
    await api.resolveCutRequirement(requirementId,mode,payload);
    toast(mode==="FULL_REEL"?"Carreto completo enviado a Alistamiento.":"La referencia quedó marcada como no requiere corte.","success",6500);
    await loadCuttingGroups(currentPage);
    try{const [latest,optimizer]=await Promise.all([api.cuttingGroup(groupKey),api.cuttingOptimizer(groupKey)]);renderCutGroup(host,latest,optimizer)}catch{host.replaceChildren()}
    window.__erpQueueRefresh?.();
  }catch(error){toast(error.message,"error",8000);button.disabled=false}
}
