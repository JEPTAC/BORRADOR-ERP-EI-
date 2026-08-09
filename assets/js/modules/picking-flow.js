import {api} from "../services/api.js";
import {fmt} from "../core/format.js";
import {toast} from "../core/ui.js";
import {parallelWorkFooter} from "./active-work.js";

const DRAFT_PREFIX="erp:alistamiento:v10.8:";
const ACTIVE_STATUSES=new Set(["QUEUED","ASSIGNED","IN_PROGRESS","WAITING","BLOCKED"]);

export function isPickingFlow(data){
  return data?.order?.current_step_code==="ALISTAMIENTO"||hasPartialPending(data);
}

export async function openCutPickup(orderId,{refreshLists}={}){
  const host=document.querySelector("#modal-root");
  host.innerHTML='<div class="modal-overlay"><section class="modal cut-pickup-standalone"><div class="modal-body"><div class="loading">Consultando cortes listos…</div></div></section></div>';
  try{
    const data=await api.cutPickupDetail(orderId);
    renderStandaloneCutPickup(host,data,{refreshLists});
  }catch(error){
    host.innerHTML=`<div class="modal-overlay"><section class="modal"><header class="modal-head"><div><h3>No fue posible abrir la recogida</h3></div><button class="icon-btn" data-close>×</button></header><div class="modal-body"><p class="danger">${fmt.escape(error.message)}</p></div></section></div>`;
    bindClose(host);
  }
}

function renderStandaloneCutPickup(host,data,{refreshLists}={}){
  const order=data.order||{};
  const items=(data.items||[]).map(item=>({
    id:item.requirementId,reference:item.reference,sku:item.sku,description:item.description,
    units_required:item.unitsRequired,length_each:item.lengthEach,total_length:item.totalLength,
    resolution_code:item.resolution,lot_number:item.lotNumber,location:item.location
  }));
  host.innerHTML=`<div class="modal-overlay simple-process-overlay">
    <section class="modal simple-process-modal wide picking-process-modal cut-pickup-standalone" data-order-id="${fmt.escape(order.id)}">
      <header class="modal-head simple-process-head picking-process-head"><div><span class="wizard-kicker">Alistamiento · Recogida desde Corte</span><h3>${fmt.escape(order.orderNumber)}</h3><p>${fmt.escape(order.clientName)} · ${fmt.escape(fmt.route(order.route))}</p></div><button class="icon-btn" data-close aria-label="Cerrar">×</button></header>
      <div class="modal-body simple-process-body picking-process-body">
        <section class="cut-pickup-early-banner"><span>LISTO PARA RECOGER</span><div><strong>${data.pickupWhileCutting?"Recogida anticipada":"Cortes terminados"}</strong><p>${data.pickupWhileCutting?`Puedes recoger estas referencias ahora. Otras referencias del mismo pedido todavía continúan en Corte mientras Alistamiento avanza en paralelo.`:"Confirma las referencias entregadas por Corte antes de iniciar la verificación normal."}</p></div></section>
        <section class="cut-pickup-workbench">
          <header class="cut-pickup-stage-head"><div><span class="picking-step-tag">Entrega física</span><h4>Cortes por recoger</h4><p>Marca únicamente lo que recibiste físicamente.</p></div><div class="cut-pickup-counter"><strong data-cut-pickup-selected>0</strong><span>de ${items.length} marcados</span></div></header>
          <div class="cut-pickup-items">${items.map((item,index)=>cutPickupItem(item,index)).join("")}</div>
          <button type="button" class="btn btn-primary cut-pickup-confirm" data-confirm-cut-pickup disabled>Confirmar recogida seleccionada</button>
        </section>
      </div>
      ${parallelWorkFooter("ALISTAMIENTO")}
    </section>
  </div>`;
  bindClose(host);
  bindPickupSelection(host,items,async ids=>{
    const result=await api.confirmCutPickup(order.id,ids);
    toast(result.allCollected?"Recogida completada.":`Recogida registrada. Quedan ${result.remaining} referencia(s) listas por entregar.`,"success",6500);
    refreshLists?.();
    window.__erpQueueRefresh?.();
    window.__erpCuttingRefresh?.();
    if(result.remaining>0){
      const latest=await api.cutPickupDetail(order.id);
      renderStandaloneCutPickup(host,latest,{refreshLists});
    }else host.replaceChildren();
  });
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
    const hasPickup=pendingCutPickups(data).length>0;
    const label=hasPickup?"Tomar pedido para recoger cortes":resumed?"Retomar pedido":"Tomar pedido";
    const canStart=actions.has("CLAIM")||actions.has("START")||actions.has("RESUME");
    host.innerHTML=shell(data,`
      <section class="picking-take-card ${hasPickup?"cut-pickup-take":""}">
        <span class="picking-step-tag">${hasPickup?"Cortes listos":resumed?`Ronda ${rounds(data).length+1}`:"Paso 1"}</span>
        <h4>${label}</h4>
        <p>${hasPickup?`Hay ${pendingCutPickups(data).length} referencia(s) terminada(s) por recoger antes de verificar el resto de la mercancía.`:resumed?"Solo se verificarán las referencias que quedaron pendientes en la salida anterior.":"Al tomarlo quedará asignado a tu usuario y podrás verificar la mercancía línea por línea."}</p>
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

  if(pendingCutPickups(data).length){
    renderCutPickup(host,data,{reload,refreshLists});
    return;
  }

  renderVerification(host,data,{reload,refreshLists}).catch(error=>{toast(error.message,"error",7500);host.replaceChildren();});
}

function renderCutPickup(host,data,{reload,refreshLists}){
  const items=pendingCutPickups(data);
  host.innerHTML=shell(data,`
    ${pickingProgress(data,"PICKUP")}
    <section class="cut-pickup-workbench">
      <header class="cut-pickup-stage-head">
        <div><span class="picking-step-tag">Paso previo al alistamiento</span><h4>Cortes por recoger</h4><p>Confirma físicamente cada referencia terminada. Puedes recoger una parte y volver después por las demás.</p></div>
        <div class="cut-pickup-counter"><strong data-cut-pickup-selected>0</strong><span>de ${items.length} marcados</span></div>
      </header>
      <div class="cut-pickup-items">
        ${items.map((item,index)=>cutPickupItem(item,index)).join("")}
      </div>
      <section class="cut-pickup-summary">
        <div><small>Referencias listas</small><strong>${items.length}</strong></div>
        <div><small>Longitud procesada</small><strong>${fmt.number(items.reduce((sum,item)=>sum+Number(item.total_length||0),0),3)} m</strong></div>
        <div><small>Después de recoger</small><strong>Verificar mercancía</strong></div>
      </section>
      <button type="button" class="btn btn-primary cut-pickup-confirm" data-confirm-cut-pickup disabled>Confirmar recogida seleccionada</button>
      <small class="picking-route-note">Los cortes recogidos quedan ligados a este mismo pedido y no vuelven a aparecer en la bandeja.</small>
    </section>`);
  bindClose(host);

  bindPickupSelection(host,items,async ids=>{
    const result=await api.confirmCutPickup(data.order.id,ids);
    toast(result.allCollected?"Todos los cortes fueron recogidos. Continúa con la verificación de mercancía.":`Recogida registrada. Quedan ${result.remaining} corte(s) pendientes.`,"success",7000);
    refreshLists?.();
    await reload?.();
  });
}

function cutPickupItem(item,index){
  const resolution=String(item.resolution_code||"").toUpperCase();
  const resolutionLabel=resolution==="FULL_REEL"?"Carreto completo":resolution==="NO_CUT"?"No requería corte":"Corte ejecutado";
  return `<article class="cut-pickup-item" data-cut-pickup-item data-requirement-id="${fmt.escape(item.id)}">
    <div class="cut-pickup-index">${index+1}</div>
    <div class="cut-pickup-data">
      <span class="cut-pickup-resolution ${fmt.escape(resolution.toLowerCase())}">${fmt.escape(resolutionLabel)}</span>
      <strong>${fmt.escape(item.reference||item.sku||item.description)}</strong>
      <p>${fmt.escape(item.description)}</p>
      <div><span><small>Cantidad</small><b>${fmt.number(item.units_required,2)} × ${fmt.number(item.length_each,3)} m</b></span><span><small>Total</small><b>${fmt.number(item.total_length,3)} m</b></span><span><small>Carreto</small><b>${fmt.escape(cutLotLabel(item))}</b></span></div>
    </div>
    <button type="button" class="cut-pickup-toggle" data-toggle-cut-pickup aria-pressed="false"><span aria-hidden="true">○</span> Marcar como recogido</button>
  </article>`;
}

function cutLotLabel(item){
  const batch=(item.cut_batch_id||item.inventory_lot_id)?"Listo en Corte":"Sin carreto";
  return item.lot_number||item.location||item.metadata?.lotNumber||item.metadata?.location||batch;
}

function bindPickupSelection(host,items,onConfirm){
  const sync=()=>{
    const selected=[...host.querySelectorAll("[data-cut-pickup-item].selected")];
    const counter=host.querySelector("[data-cut-pickup-selected]");
    if(counter)counter.textContent=String(selected.length);
    const button=host.querySelector("[data-confirm-cut-pickup]");
    if(button){
      button.disabled=selected.length===0;
      button.textContent=selected.length===items.length?"Confirmar todos como recogidos":`Confirmar ${selected.length} recogido(s)`;
    }
  };
  host.querySelectorAll("[data-toggle-cut-pickup]").forEach(button=>button.addEventListener("click",()=>{
    const row=button.closest("[data-cut-pickup-item]");
    const selected=!row.classList.contains("selected");
    row.classList.toggle("selected",selected);
    button.setAttribute("aria-pressed",String(selected));
    button.innerHTML=selected?'<span aria-hidden="true">✓</span> Marcado como recogido':'<span aria-hidden="true">○</span> Marcar como recogido';
    sync();
  }));
  host.querySelector("[data-confirm-cut-pickup]")?.addEventListener("click",async event=>{
    const ids=[...host.querySelectorAll("[data-cut-pickup-item].selected")].map(row=>row.dataset.requirementId);
    if(!ids.length)return;
    event.currentTarget.disabled=true;
    try{await onConfirm(ids)}catch(error){toast(error.message,"error",7500);event.currentTarget.disabled=false}
  });
  sync();
}

async function renderVerification(host,data,{reload,refreshLists}){
  const task=activeTask(data);
  const allPending=pendingItems(data);
  const cutMap=new Map((data.cutRequirements||[]).map(item=>[item.order_item_id,item]));
  const cutsPending=(data.cutRequirements||[]).filter(item=>String(item.process_status||"").toUpperCase()!=="READY");
  const processable=allPending.filter(item=>{
    if(!item.requires_cut)return true;
    const cut=cutMap.get(item.id);
    return cut&&String(cut.process_status||"").toUpperCase()==="READY"&&String(cut.collection_status||"").toUpperCase()==="COLLECTED";
  });
  let serverDraft={};
  try{
    const pre=await api.pickingPrecheck(data.order.id);
    serverDraft=Object.fromEntries((pre.items||[]).map(item=>[item.orderItemId,{result:item.result||"",novelty:item.novelty||"",origins:item.origins||[]}])) ;
  }catch(error){
    console.warn("[ALISTAMIENTO PRECHECK]",error);
  }
  const localDraft=loadDraft(task,processable);
  const draft=Object.fromEntries(processable.map(item=>[item.id,{...(serverDraft[item.id]||{}),...(localDraft[item.id]||{})}]));
  const roundNo=rounds(data).length+1;
  const previous=rounds(data).length;
  const parallel=cutsPending.length>0;

  host.innerHTML=shell(data,`
    ${pickingProgress(data,"VERIFY")}
    ${partialBanner(data)}
    ${parallel?`<section class="picking-parallel-cut-banner"><span>CORTE EN PARALELO</span><div><strong>${cutsPending.length} referencia(s) siguen en Corte</strong><p>Alista ahora la mercancía que no requiere corte. El avance se guarda y el pedido no podrá pasar a Facturación hasta recoger y verificar los cortes pendientes.</p></div></section>`:""}
    <section class="picking-verification-card">
      <header class="picking-stage-head">
        <div><span class="picking-step-tag">Ronda ${roundNo}</span><h4>Verificación de mercancía</h4><p>${parallel?"Trabaja únicamente las líneas disponibles mientras Corte avanza al mismo tiempo.":previous?"Solo aparecen los elementos pendientes de la salida anterior.":"Marca Encontrado o No encontrado en cada línea."}</p></div>
        <div class="picking-counter"><strong data-picking-verified>0</strong><span>de ${processable.length} verificadas</span></div>
      </header>
      ${processable.length?`<div class="picking-items" data-picking-items>${processable.map((item,index)=>itemRow(item,index,draft[item.id])).join("")}</div>`:`<div class="picking-waiting-cuts"><strong>No hay líneas disponibles para alistar todavía.</strong><p>Todas las referencias pendientes están actualmente en Corte. Puedes cerrar este popup y atender otro pedido.</p></div>`}
      <section class="picking-result-summary" data-picking-summary></section>
      ${processable.length?`<button type="button" class="btn btn-primary picking-send-button" data-picking-send disabled>${parallel?"Guardar avance y esperar cortes":"Enviar a facturación"}</button>`:""}
      <small class="picking-route-note">${parallel?"Corte y Alistamiento están trabajando sobre el mismo pedido en paralelo, sin duplicarlo.":hasCutHistory(data)?"Los cortes ya fueron procesados y recogidos. Al finalizar esta verificación, el pedido continuará al proceso de facturación correspondiente.":"El pedido continuará directamente al proceso de facturación correspondiente."}</small>
    </section>
    ${roundHistory(data)}
  `);
  bindClose(host);
  const itemMap=new Map(processable.map(item=>[item.id,item]));
  host.querySelectorAll("[data-picking-item]").forEach(row=>{
    const item=itemMap.get(row.dataset.itemId);
    row.__savedOrigins=draft[row.dataset.itemId]?.origins||[];
    if(row.dataset.result==="FOUND"&&!item?.requires_cut)loadOriginPlan(row,item,row.__savedOrigins).then(sync).catch(error=>{row.dataset.originError=error.message;sync()});
  });

  const sync=()=>{
    const rows=[...host.querySelectorAll("[data-picking-item]")];
    const results=rows.map(readRow);
    const verified=results.filter(row=>row.result).length;
    const missing=results.filter(row=>row.result==="MISSING").length;
    const found=results.filter(row=>row.result==="FOUND").length;
    const missingWithoutReason=results.some(row=>row.result==="MISSING"&&!row.novelty);
    const originPending=[...host.querySelectorAll("[data-picking-item]")].some(row=>row.dataset.result==="FOUND"&&row.dataset.requiresCut!=="true"&&!originSelectionValid(row));
    const counter=host.querySelector("[data-picking-verified]");if(counter)counter.textContent=String(verified);
    const summary=host.querySelector("[data-picking-summary]");if(summary)summary.innerHTML=summaryMarkup(processable.length,found,missing,verified)+(originPending?'<div class="picking-origin-alert">Falta confirmar el origen físico de una o más líneas encontradas.</div>':"");
    const send=host.querySelector("[data-picking-send]");if(send)send.disabled=verified!==processable.length||missingWithoutReason||originPending||processable.length===0;
    saveDraft(task,results);
  };

  host.querySelectorAll("[data-result]").forEach(button=>button.addEventListener("click",async()=>{
    const row=button.closest("[data-picking-item]");
    row.querySelectorAll("[data-result]").forEach(item=>{const selected=item===button;item.classList.toggle("selected",selected);item.setAttribute("aria-pressed",String(selected));});
    row.dataset.result=button.dataset.result;
    const novelty=row.querySelector("[data-novelty-wrap]");novelty.hidden=button.dataset.result!=="MISSING";
    const textarea=novelty.querySelector("textarea");textarea.required=button.dataset.result==="MISSING";if(button.dataset.result==="FOUND")textarea.value="";
    const origin=row.querySelector("[data-origin-wrap]");
    if(origin)origin.hidden=button.dataset.result!=="FOUND";
    if(button.dataset.result==="FOUND"&&row.dataset.requiresCut!=="true"){
      try{await loadOriginPlan(row,itemMap.get(row.dataset.itemId),row.__savedOrigins||[])}catch(error){toast(error.message,"error",6500);row.dataset.originError=error.message}
    }
    sync();
  }));
  host.addEventListener("picking:origin-change",sync);
  host.querySelectorAll("[data-picking-item] textarea").forEach(textarea=>textarea.addEventListener("input",sync));
  host.querySelector("[data-picking-send]")?.addEventListener("click",async event=>{
    const results=[...host.querySelectorAll("[data-picking-item]")].map(readRow);
    if(parallel){
      event.currentTarget.disabled=true;
      try{
        await api.savePickingPrecheck(data.order.id,results);
        let latest=await api.getOrder(data.order.id);
        const actions=actionCodes(latest);
        if(actions.has("WAIT"))await api.executeAction(latest.order.id,"WAIT",{reason:"Esperando cortes pendientes",detail:`Alistamiento paralelo guardado. ${cutsPending.length} referencia(s) continúan en Corte.`},latest.order.version);
        clearDraft(task);
        toast("Avance de Alistamiento guardado. Corte continúa en paralelo.","success",6500);
        refreshLists?.();host.replaceChildren();
      }catch(error){toast(error.message,"error",7500);event.currentTarget.disabled=false}
    }else openConfirmation(host,data,task,refreshLists);
  });
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
    <section class="modal simple-process-modal wide picking-process-modal" data-order-id="${fmt.escape(data.order.id)}">
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
      ${parallelWorkFooter(data.order.current_step_code)}
    </section>
  </div>`;
}

function itemRow(item,index,saved={}){
  const result=saved?.result||"";
  const novelty=saved?.novelty||item.metadata?.lastNovelty||"";
  return `<article class="picking-item-row" data-picking-item data-item-id="${fmt.escape(item.id)}" data-result="${fmt.escape(result)}" data-requires-cut="${item.requires_cut?"true":"false"}">
    <div class="picking-item-number">${index+1}</div>
    <div class="picking-item-data">
      <div><small>Referencia</small><strong>${fmt.escape(item.reference||item.sku||"—")}</strong></div>
      <div class="description"><small>Mercancía</small><strong>${fmt.escape(item.description)}</strong></div>
      <div><small>Cantidad</small><strong>${fmt.number(item.quantity,3)} ${fmt.escape(item.unit)}</strong></div>
      ${item.requires_cut?`<div><small>Origen</small><strong>Corte define el carreto</strong></div><div><small>Corte</small><strong>${item.requested_cut_length?`${fmt.number(item.requested_cut_length,3)} ${fmt.escape(item.unit)}`:"Requiere corte"}</strong></div>`:`<div><small>Origen físico</small><strong>Se confirma al encontrar</strong></div>`}
    </div>
    <div class="picking-mini-actions">
      <button type="button" class="picking-result found ${result==="FOUND"?"selected":""}" data-result="FOUND" aria-pressed="${result==="FOUND"?"true":"false"}"><span class="picking-result-icon" aria-hidden="true">✓</span><span>Encontrado</span></button>
      <button type="button" class="picking-result missing ${result==="MISSING"?"selected":""}" data-result="MISSING" aria-pressed="${result==="MISSING"?"true":"false"}"><span class="picking-result-icon" aria-hidden="true">!</span><span>No encontrado</span></button>
    </div>
    ${item.requires_cut?`<div class="picking-cut-origin-note" ${result==="FOUND"?"":"hidden"}><strong>Origen trazado por Corte</strong><span>El carreto y el consumo físico ya quedaron registrados en el subflujo de Corte.</span></div>`:`<div class="picking-origin" data-origin-wrap ${result==="FOUND"?"":"hidden"}><div class="picking-origin-loading">Marca Encontrado para consultar lotes y ubicaciones oficiales.</div></div>`}
    <div class="picking-novelty" data-novelty-wrap ${result==="MISSING"?"":"hidden"}>
      <label>¿Por qué no se encontró? *</label>
      <textarea class="control" rows="2" placeholder="Ejemplo: referencia agotada, ubicación vacía o cantidad incompleta" ${result==="MISSING"?"required":""}>${fmt.escape(novelty)}</textarea>
      <small>El faltante quedará trazado en esta ronda y podrá generar una salida parcial.</small>
    </div>
  </article>`;
}

async function loadOriginPlan(row,item,savedOrigins=[]){
  if(!row||!item||item.requires_cut)return;
  const wrap=row.querySelector("[data-origin-wrap]");if(!wrap)return;
  wrap.hidden=false;
  if(row.dataset.originLoaded==="true")return;
  row.dataset.originLoaded="loading";
  wrap.innerHTML='<div class="picking-origin-loading">Consultando inventario oficial y ubicación…</div>';
  const plan=await api.pickingOriginPlan(item.id);
  row.__originPlan=plan;
  const candidates=plan.candidates||[];
  const savedMap=new Map((savedOrigins||[]).map(origin=>[origin.lotId,Number(origin.quantity||0)]));
  const suggestedMap=new Map((plan.suggestedPlan||[]).map(origin=>[origin.lotId,Number(origin.quantity||0)]));
  const selection=savedMap.size?savedMap:suggestedMap;
  if(!candidates.length){
    wrap.innerHTML=`<div class="picking-origin-empty"><strong>Sin existencia física disponible</strong><span>Marca No encontrado o registra una Novedad si el inventario físico no coincide.</span></div>`;
    row.dataset.originLoaded="true";return;
  }
  wrap.innerHTML=`<div class="picking-origin-head"><div><strong>Origen físico</strong><p>El ERP propone de dónde tomar la mercancía. Puedes cambiarlo si físicamente la encuentras en otra ubicación.</p></div><span>${fmt.number(plan.required,3)} ${fmt.escape(plan.unit)}</span></div>
    ${Number(plan.shortage||0)>0?`<div class="picking-origin-shortage">El inventario actual no alcanza: faltan ${fmt.number(plan.shortage,3)} ${fmt.escape(plan.unit)}.</div>`:""}
    <div class="picking-origin-options">${candidates.map(candidate=>{const qty=selection.get(candidate.lotId)||0;return `<div class="picking-origin-option ${qty>0?"selected":""}" data-origin-option>
      <input type="checkbox" data-origin-check value="${fmt.escape(candidate.lotId)}" ${qty>0?"checked":""}>
      <span class="picking-origin-loc"><strong>${fmt.escape([candidate.warehouseCode,candidate.location].filter(Boolean).join(" · ")||"Ubicación")}</strong><small>${fmt.escape([candidate.locationName,candidate.lotNumber&&`Lote ${candidate.lotNumber}`,candidate.serialNumber].filter(Boolean).join(" · ")||"Sin detalle adicional")}</small></span>
      <span class="picking-origin-available">Disp. <b>${fmt.number(candidate.available,3)}</b></span>
      <label class="picking-origin-qty"><small>Tomar</small><input class="control" data-origin-qty type="number" min="0" max="${Number(candidate.available)}" step="any" value="${qty||""}" ${qty>0?"":"disabled"}></label>
      ${candidate.recommended?'<em>Recomendado</em>':""}
    </label>`}).join("")}</div>
    <div class="picking-origin-total" data-origin-total></div>`;
  row.dataset.originLoaded="true";
  const update=()=>{
    wrap.querySelectorAll("[data-origin-option]").forEach(option=>{const check=option.querySelector("[data-origin-check]"),input=option.querySelector("[data-origin-qty]");input.disabled=!check.checked;if(!check.checked)input.value="";option.classList.toggle("selected",check.checked)});
    const origins=readOrigins(row),sum=origins.reduce((acc,origin)=>acc+origin.quantity,0),required=Number(plan.required||item.quantity||0),valid=Math.abs(sum-required)<=0.0001;
    row.dataset.originValid=String(valid);
    const total=wrap.querySelector("[data-origin-total]");if(total){total.className=`picking-origin-total ${valid?"valid":"invalid"}`;total.innerHTML=`<span>Asignado <strong>${fmt.number(sum,3)} / ${fmt.number(required,3)} ${fmt.escape(plan.unit)}</strong></span><b>${valid?"Origen completo":"Ajusta las cantidades"}</b>`;}
    row.dispatchEvent(new CustomEvent("picking:origin-change",{bubbles:true}));
  };
  wrap.querySelectorAll("[data-origin-check]").forEach(check=>check.addEventListener("change",update));
  wrap.querySelectorAll("[data-origin-qty]").forEach(input=>input.addEventListener("input",update));
  update();
}

function readOrigins(row){
  return [...(row?.querySelectorAll("[data-origin-option]")||[])].filter(option=>option.querySelector("[data-origin-check]")?.checked).map(option=>({lotId:option.querySelector("[data-origin-check]").value,quantity:Number(option.querySelector("[data-origin-qty]").value)||0})).filter(origin=>origin.quantity>0);
}

function originSelectionValid(row){
  if(row.dataset.requiresCut==="true")return true;
  return row.dataset.originLoaded==="true"&&row.dataset.originValid==="true";
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

function pendingCutPickups(data){return (data.cutRequirements||[]).filter(item=>String(item.process_status||"").toUpperCase()==="READY"&&String(item.collection_status||"PENDING").toUpperCase()==="PENDING")}
function hasCutHistory(data){return (data.cutRequirements||[]).length>0}
function pickingProgress(data,stage){
  const hasCuts=hasCutHistory(data);
  if(!hasCuts)return `<section class="picking-progress-strip"><div class="done"><span>1</span><strong>Pedido tomado</strong></div><div class="${stage==="VERIFY"?"active":""}"><span>2</span><strong>Verificación de mercancía</strong></div><div><span>3</span><strong>Enviar a facturación</strong></div></section>`;
  return `<section class="picking-progress-strip four-steps"><div class="done"><span>1</span><strong>Pedido tomado</strong></div><div class="${stage==="PICKUP"?"active":"done"}"><span>2</span><strong>Recoger cortes</strong></div><div class="${stage==="VERIFY"?"active":""}"><span>3</span><strong>Verificar mercancía</strong></div><div><span>4</span><strong>Enviar a facturación</strong></div></section>`;
}
function activeTask(data){return [...(data.tasks||[])].reverse().find(task=>ACTIVE_STATUSES.has(task.status))||null}
function actionCodes(data){return new Set((data.actions?.actions||[]).map(action=>action.code))}
function rounds(data){return data.pickingRounds||[]}
function pendingItems(data){return (data.items||[]).filter(item=>!["FULFILLED","CANCELLED"].includes(String(item.item_status||"PENDING").toUpperCase()))}
function hasPartialPending(data){return data?.order?.metadata?.fulfillment?.status==="PARTIAL"&&pendingItems(data).length>0}
function assigneeName(data){const task=activeTask(data);return task?.assigned_name||data.order.current_assignee_name||data.order.metadata?.receptionAssignment?.pickingProfileName||"Auxiliar asignado"}
function bindClose(host){host.querySelectorAll("[data-close]").forEach(button=>button.onclick=()=>host.replaceChildren())}
function readRow(row){return {orderItemId:row.dataset.itemId,result:row.dataset.result||"",novelty:row.querySelector("textarea")?.value.trim()||"",origins:row.dataset.result==="FOUND"&&row.dataset.requiresCut!=="true"?readOrigins(row):[]}}
function draftKey(task){return `${DRAFT_PREFIX}${task?.id||"none"}`}
function loadDraft(task,items){
  try{
    const raw=JSON.parse(localStorage.getItem(draftKey(task))||"{}");
    return Object.fromEntries(items.map(item=>[item.id,raw[item.id]||{}]));
  }catch{return {}}
}
function saveDraft(task,rows){
  const value=Object.fromEntries(rows.map(row=>[row.orderItemId,{result:row.result,novelty:row.novelty,origins:row.origins||[]}]));
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
