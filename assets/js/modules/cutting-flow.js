import {api} from "../services/api.js";
import {fmt} from "../core/format.js";
import {empty,loading,paginationHtml,toast} from "../core/ui.js";
import {navigate} from "../core/router.js";
import {parallelWorkFooter} from "./active-work.js";

let currentRoot=null;
let currentPage=1;
let sandboxMode=false;

export function isCuttingFlow(data){
  return data?.order?.current_step_code==="CORTE";
}

export async function renderCutting(root,{params={}}={}){
  currentRoot=root;
  sandboxMode=params.sandbox==="1";
  root.innerHTML=`
    ${sandboxMode?`<section class="sandbox-queue-banner"><strong>MODO SANDBOX · CORTE</strong><span>Carretos y consumos son simulados. Inventario Siesa permanece intacto.</span><button class="btn btn-ghost btn-compact" id="sandbox-cut-back">Volver al Bot</button></section>`:""}
    <section class="page-head cutting-page-head">
      <div><span class="cutting-kicker">Centro de corte</span><h2>Cortes pendientes por referencia</h2><p>Una referencia puede reunir muchos pedidos. Inicia el grupo y el ERP te guiará para revisar cortes, elegir el origen físico y ejecutar cada carreto.</p></div>
      <div class="page-actions"><button class="btn btn-ghost" id="cutting-refresh">Actualizar</button></div>
    </section>
    <section class="workflow-hint"><span>1</span><strong>Busca la referencia.</strong><p>Todos los pedidos iguales se ejecutan como un solo trabajo de Corte.</p></section>
    <section class="card card-pad cutting-workspace">
      <div class="cutting-toolbar">
        <input class="control search-wide" id="cutting-search" placeholder="Buscar referencia o nombre del cable">
        <button class="btn btn-primary" id="cutting-search-button">Buscar</button>
      </div>
      <div id="cutting-result">${loading("Agrupando cortes pendientes…")}</div>
    </section>`;

  root.querySelector("#sandbox-cut-back")?.addEventListener("click",()=>navigate("sandbox"));
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
  target.innerHTML=loading("Calculando pendientes por referencia…");
  try{
    const search=root.querySelector("#cutting-search")?.value.trim()||"";
    const data=await (sandboxMode?api.sandboxCuttingGroups(search,page,50):api.cuttingGroups(search,page,50));
    const rows=data.items||[];
    target.innerHTML=rows.length?`
      <div class="cutting-result-head"><div><strong>${fmt.number(data.pagination?.totalItems||rows.length)} referencia(s)</strong><span>La longitud mostrada es únicamente lo que falta por cortar.</span></div></div>
      <div class="erp-work-list cutting-group-list">${rows.map(groupRow).join("")}</div>
      ${paginationHtml(data.pagination)}`:empty("No hay cortes pendientes","Cuando Recepción confirme líneas con corte, se agruparán aquí por material y variante.");
    target.querySelectorAll("[data-cut-group]").forEach(button=>button.addEventListener("click",()=>openCutGroup(button.dataset.cutGroup)));
    target.querySelectorAll("[data-page]").forEach(button=>button.addEventListener("click",()=>loadCuttingGroups(Number(button.dataset.page))));
  }catch(error){
    target.innerHTML=`<div class="module-error"><strong>No fue posible cargar Corte</strong><p>${fmt.escape(error.message)}</p><button class="btn btn-primary" data-retry>Reintentar</button></div>`;
    target.querySelector("[data-retry]")?.addEventListener("click",()=>loadCuttingGroups(page));
    toast(error.message,"error",8000);
  }
}

function groupRow(group){
  const progress=Number(group.completedLength||0)>0;
  return `<article class="erp-work-row cutting-group-row ${group.inProgress?"in-progress":""}">
    <div class="erp-work-main"><span class="erp-work-eyebrow">${progress?"CORTE PARCIAL":"REFERENCIA PENDIENTE"}</span><strong>${fmt.escape(group.reference||group.sku||"Sin referencia")}</strong><small>${fmt.escape(group.description)}${group.variantLabel?` · ${fmt.escape(group.variantLabel)}`:""}</small></div>
    <div class="erp-work-meta"><span><small>Falta cortar</small><b>${fmt.number(group.totalLength,3)} m</b></span><span><small>Cortes</small><b>${fmt.number(group.cutCount,2)}</b></span><span><small>Pedidos</small><b>${fmt.number(group.orderCount)}</b></span><span><small>Líneas</small><b>${fmt.number(group.itemCount)}</b></span></div>
    <div class="erp-work-status"><span class="badge ${progress?"badge-blue":"badge-gray"}">${progress?"En progreso":"Pendiente"}</span></div>
    <button type="button" class="btn btn-primary erp-work-action" data-cut-group="${fmt.escape(group.groupKey)}">${progress?"Continuar corte":"Iniciar corte"}</button>
  </article>`;
}

export function renderCuttingOrder(host,data){
  host.innerHTML=`<div class="modal-overlay simple-process-overlay">
    <section class="modal simple-process-modal cutting-order-notice">
      <header class="modal-head simple-process-head"><div><span class="wizard-kicker">Corte por referencia</span><h3>${fmt.escape(data.order.order_number)}</h3><p>${fmt.escape(data.order.client_name)}</p></div><button class="icon-btn" data-close aria-label="Cerrar">×</button></header>
      <div class="modal-body simple-process-body">
        <section class="cutting-order-message"><span>CT</span><div><h4>Los cortes se ejecutan agrupados por referencia</h4><p>Este pedido puede compartir referencia con otros pedidos. El Centro de Corte consolida todos los tramos y conserva la trazabilidad individual.</p></div></section>
        <button class="btn btn-primary btn-large cutting-open-center" data-open-cutting>Abrir Centro de corte</button>
      </div>
      ${parallelWorkFooter("CORTE")}
    </section>
  </div>`;
  host.querySelectorAll("[data-close]").forEach(button=>button.addEventListener("click",()=>host.replaceChildren()));
  host.querySelector("[data-open-cutting]")?.addEventListener("click",()=>{host.replaceChildren();navigate("cutting",data.order.is_test?{sandbox:"1"}:{})});
}

async function openCutGroup(groupKey,{startStep=1,message=""}={}){
  const host=document.querySelector("#modal-root");
  host.innerHTML=`<div class="modal-overlay cutting-overlay"><section class="modal cutting-group-modal"><div class="modal-body">${loading("Preparando el corte agrupado…")}</div></section></div>`;
  try{
    const [data,optimizer]=await Promise.all([
      sandboxMode?api.sandboxCuttingGroup(groupKey):api.cuttingGroup(groupKey),
      sandboxMode?api.sandboxCuttingOptimizer(groupKey):api.cuttingOptimizer(groupKey)
    ]);
    renderCutGroup(host,data,optimizer,{startStep,message});
  }catch(error){
    host.innerHTML=`<div class="modal-overlay"><section class="modal"><header class="modal-head"><h3>No fue posible abrir la referencia</h3><button class="icon-btn" data-close>×</button></header><div class="modal-body"><p class="danger">${fmt.escape(error.message)}</p></div></section></div>`;
    host.querySelector("[data-close]")?.addEventListener("click",()=>host.replaceChildren());
  }
}

function renderCutGroup(host,data,optimizer={},options={}){
  const group=data.group||{};
  const items=data.items||[];
  const recent=data.recentBatches||[];
  const state={
    groupKey:group.groupKey,
    group,
    items,
    origins:normalizeOrigins(data.reels||[]),
    allOrigins:normalizeOrigins(data.reels||[]),
    selectedLotId:null,
    selectedOrigin:null,
    plan:null,
    reelLength:0,
    scrapLength:0
  };

  host.innerHTML=`<div class="modal-overlay cutting-overlay">
    <section class="modal cutting-group-modal cut-reference-modal">
      <header class="modal-head cutting-modal-head">
        <div><span class="cutting-kicker">Corte agrupado por referencia</span><h3>${fmt.escape(group.reference||group.sku||"Sin referencia")}</h3><p>${fmt.escape(group.description||"")}${group.variantLabel?` · <strong>${fmt.escape(group.variantLabel)}</strong>`:""}</p></div>
        <button class="icon-btn" data-close aria-label="Cerrar">×</button>
      </header>
      <div class="modal-body cutting-modal-body cut-reference-body">
        ${options.message?`<section class="cut-continuation-banner"><strong>${fmt.escape(options.message)}</strong><span>El trabajo sigue siendo la misma referencia. Selecciona el siguiente carreto para continuar.</span></section>`:""}
        <nav class="cut-guide-progress cut-reference-progress" aria-label="Progreso de corte">
          <div data-cut-progress="1"><span>1</span><div><strong>Revisar</strong><small>Pedidos y medidas</small></div></div>
          <div data-cut-progress="2"><span>2</span><div><strong>Origen</strong><small>Carreto físico</small></div></div>
          <div data-cut-progress="3"><span>3</span><div><strong>Confirmar</strong><small>Ejecutar este carreto</small></div></div>
        </nav>

        <section class="cut-guide-step" data-cut-step="1">
          <div class="cut-guide-intro"><span>PASO 1 DE 3</span><h4>Revisa todo lo pendiente de esta referencia</h4><p>Estos pedidos comparten el mismo material. El ERP conserva cada pedido y cada medida aunque el trabajo se ejecute como un solo corte agrupado.</p></div>
          <section class="cut-guide-summary cut-reference-summary">
            <div><small>Pedidos</small><strong>${fmt.number(group.orderCount)}</strong></div>
            <div><small>Cortes pendientes</small><strong>${fmt.number(group.cutCount,2)}</strong></div>
            <div><small>Longitud pendiente</small><strong>${fmt.number(group.totalLength,3)} m</strong></div>
          </section>
          <div class="cut-reference-orders">${items.map(cutRequirementRow).join("")}</div>
          ${recent.length?`<details class="cut-history"><summary>Ver ${recent.length} carreto(s) usado(s) anteriormente</summary><div>${recent.map(batchHistoryRow).join("")}</div></details>`:""}
          <footer class="cut-guide-actions"><span>Si cantidades y medidas coinciden, continúa al origen físico.</span><button type="button" class="btn btn-primary btn-large" data-cut-next="2">Continuar · Seleccionar carreto</button></footer>
        </section>

        <section class="cut-guide-step" data-cut-step="2" hidden>
          <div class="cut-guide-intro"><span>PASO 2 DE 3</span><h4>¿De qué carreto vas a sacar el cable?</h4><p>La referencia y la variante ya están bloqueadas. Solo puedes elegir existencias físicas compatibles.</p></div>
          <section class="cut-material-lock"><div><small>Material oficial</small><strong>${fmt.escape(group.reference||group.sku||"")}</strong><span>${fmt.escape(group.description||"")}${group.variantLabel?` · ${fmt.escape(group.variantLabel)}`:""}</span></div><b>${fmt.number(group.totalLength,3)} m pendientes</b></section>
          ${optimizer?.recommended?recommendedOrigin(optimizer.recommended):""}
          <section class="cut-origin-picker">
            <header><div><h5>Buscar carreto, lote o ubicación</h5><p>Busca únicamente dentro de esta referencia.</p></div></header>
            <div class="cut-origin-search"><input class="control" data-origin-search placeholder="Ej. carreto, lote, bodega o ubicación"><button type="button" class="btn btn-ghost" data-origin-search-button>Buscar</button></div>
            <div class="cut-origin-results" data-origin-results>${originRows(state.origins)}</div>
          </section>
          <section class="cut-origin-confirm" data-origin-confirm hidden>
            <div class="cut-selected-origin" data-selected-origin></div>
            <div class="cut-origin-fields">
              <label><span>Cantidad que muestra el ERP</span><input class="control" data-system-length readonly></label>
              <label><span>Cantidad real encontrada en el carreto *</span><input class="control" data-reel-length type="number" min="0.0001" step="0.0001" placeholder="Mide o confirma el carreto"></label>
              <label><span>Merma adicional prevista</span><input class="control" data-scrap-length type="number" min="0" step="0.0001" value="0"></label>
            </div>
            <div class="cut-inventory-difference" data-inventory-difference hidden></div>
          </section>
          <footer class="cut-guide-actions"><button type="button" class="btn btn-ghost" data-cut-prev="1">Atrás</button><button type="button" class="btn btn-primary btn-large" data-preview-batch>Continuar · Calcular este carreto</button></footer>
        </section>

        <section class="cut-guide-step" data-cut-step="3" hidden>
          <div class="cut-guide-intro"><span>PASO 3 DE 3</span><h4>Confirma qué hará este carreto</h4><p>El ERP distribuye cortes completos entre los pedidos. Si el carreto no alcanza para toda la referencia, conservará el pendiente para el siguiente carreto.</p></div>
          <div data-cut-plan>${loading("Calculando el plan…")}</div>
          <footer class="cut-guide-actions"><button type="button" class="btn btn-ghost" data-cut-prev="2">Cambiar carreto</button><button type="button" class="btn btn-primary btn-large" data-execute-batch disabled>Confirmar y ejecutar este carreto</button></footer>
        </section>
      </div>
      ${parallelWorkFooter("CORTE")}
    </section>
  </div>`;

  host.querySelectorAll("[data-close]").forEach(button=>button.addEventListener("click",()=>host.replaceChildren()));
  bindGuide(host,state,optimizer);
  showStep(host,Number(options.startStep||1));
  if(Number(options.startStep||1)===2)loadOrigins(host,state,"");
}

function cutRequirementRow(item,index){
  const done=Number(item.lengthCompleted||0);
  const remaining=Number(item.remainingLength??item.totalLength??0);
  const unitsRemaining=Number(item.unitsRemaining??item.unitsRequired??0);
  return `<article class="cut-reference-order" data-cut-item data-requirement-id="${fmt.escape(item.requirementId)}">
    <span class="cut-reference-index">${index+1}</span>
    <div class="cut-reference-order-main"><small>${fmt.escape(item.orderNumber)} · ${fmt.escape(item.clientName)}</small><strong>${fmt.number(unitsRemaining,2)} corte(s) × ${fmt.number(item.lengthEach,3)} m</strong>${done>0?`<span>${fmt.number(done,3)} m ya ejecutados anteriormente</span>`:""}</div>
    <div class="cut-reference-order-total"><small>Falta</small><strong>${fmt.number(remaining,3)} m</strong></div>
    <details class="cut-guide-exception"><summary>Caso especial</summary><div class="cut-guide-exception-actions"><button type="button" class="btn btn-warning btn-compact" data-full-reel>Carreto completo</button><button type="button" class="btn btn-ghost btn-compact" data-no-cut>No necesita corte</button></div></details>
    <section class="cutting-resolution-panel" data-resolution-panel="NO_CUT" hidden><label>Motivo obligatorio<textarea class="control" data-no-cut-reason placeholder="Explica por qué esta línea no necesita corte"></textarea></label><button type="button" class="btn btn-primary" data-confirm-no-cut>Confirmar corrección</button></section>
  </article>`;
}

function batchHistoryRow(batch){
  return `<article class="cut-history-row"><div><strong>${fmt.escape(batch.lotNumber||"Carreto")}</strong><small>${fmt.escape(batch.location||"")} · ${batch.executedAt?new Date(batch.executedAt).toLocaleString():""}</small></div><span>${fmt.number(batch.cutLength,3)} m cortados</span><b>${fmt.number(batch.remainingLength,3)} m restantes</b></article>`;
}

function recommendedOrigin(candidate){
  return `<section class="cut-origin-recommendation"><div><span>RECOMENDACIÓN DEL ERP</span><strong>${fmt.escape([candidate.lotNumber,candidate.serialNumber].filter(Boolean).join(" · ")||"Carreto sugerido")}</strong><p>${fmt.number(candidate.usableLength,3)} m disponibles · ${fmt.escape(candidate.locationName||candidate.location||"Sin ubicación")}</p></div><button type="button" class="btn btn-ghost" data-recommended-lot="${fmt.escape(candidate.lotId)}">Usar recomendación</button></section>`;
}

function normalizeOrigins(rows){
  return (rows||[]).map(row=>({
    lotId:row.lotId,
    inventoryItemId:row.inventoryItemId,
    lotNumber:row.lotNumber,
    serialNumber:row.serialNumber,
    warehouseCode:row.warehouseCode,
    location:row.location,
    locationName:row.locationName,
    available:Number(row.available??row.quantityAvailable??0),
    sourceSystem:row.sourceSystem
  }));
}

function originRows(rows){
  if(!rows.length)return `<div class="cut-origin-empty"><strong>No hay carretos disponibles</strong><span>Actualiza el inventario oficial antes de ejecutar esta referencia.</span></div>`;
  return rows.map(originRow).join("");
}

function originRow(row){
  return `<button type="button" class="cut-origin-row" data-origin-lot="${fmt.escape(row.lotId)}"><div><small>${fmt.escape(row.warehouseCode||"Bodega")} · ${fmt.escape(row.locationName||row.location||"Sin ubicación")}</small><strong>${fmt.escape([row.lotNumber,row.serialNumber].filter(Boolean).join(" · ")||"Carreto sin identificación")}</strong><span>${fmt.escape(row.sourceSystem||"Inventario ERP")}</span></div><b>${fmt.number(row.available,3)} m</b><em>Seleccionar</em></button>`;
}

function bindGuide(host,state,optimizer){
  host.querySelectorAll("[data-cut-next]").forEach(button=>button.addEventListener("click",()=>{
    const step=Number(button.dataset.cutNext);
    showStep(host,step);
    if(step===2)loadOrigins(host,state,"");
  }));
  host.querySelectorAll("[data-cut-prev]").forEach(button=>button.addEventListener("click",()=>showStep(host,Number(button.dataset.cutPrev))));

  host.querySelector("[data-origin-search-button]")?.addEventListener("click",()=>loadOrigins(host,state,host.querySelector("[data-origin-search]")?.value.trim()||""));
  host.querySelector("[data-origin-search]")?.addEventListener("keydown",event=>{if(event.key==="Enter"){event.preventDefault();loadOrigins(host,state,event.currentTarget.value.trim())}});
  host.querySelector("[data-recommended-lot]")?.addEventListener("click",event=>selectOriginById(host,state,event.currentTarget.dataset.recommendedLot));
  host.querySelector("[data-reel-length]")?.addEventListener("input",()=>syncDifference(host,state));
  host.querySelector("[data-scrap-length]")?.addEventListener("input",()=>{state.scrapLength=Number(host.querySelector("[data-scrap-length]")?.value||0)});
  host.querySelector("[data-preview-batch]")?.addEventListener("click",()=>previewBatch(host,state));
  host.querySelector("[data-execute-batch]")?.addEventListener("click",event=>executeBatch(host,state,event.currentTarget));

  host.querySelectorAll("[data-no-cut]").forEach(button=>button.addEventListener("click",()=>toggleNoCut(button.closest("[data-cut-item]"),true)));
  host.querySelectorAll("[data-confirm-no-cut]").forEach(button=>button.addEventListener("click",()=>resolveNoCut(host,state,button.closest("[data-cut-item]"),button)));
  host.querySelectorAll("[data-full-reel]").forEach(button=>button.addEventListener("click",()=>openFullReelDialog(host,state,button.closest("[data-cut-item]"))));
}

function showStep(host,step){
  host.querySelectorAll("[data-cut-step]").forEach(panel=>{const active=Number(panel.dataset.cutStep)===step;panel.hidden=!active;panel.classList.toggle("active",active)});
  host.querySelectorAll("[data-cut-progress]").forEach(node=>{const n=Number(node.dataset.cutProgress);node.classList.toggle("active",n===step);node.classList.toggle("done",n<step)});
  host.querySelector(".cut-reference-body")?.scrollTo({top:0,behavior:"smooth"});
}

async function loadOrigins(host,state,search=""){
  const target=host.querySelector("[data-origin-results]");
  if(!target)return;
  target.innerHTML=loading("Buscando carretos compatibles…");
  try{
    if(sandboxMode){
      state.origins=state.allOrigins.filter(row=>!search||`${row.lotNumber||""} ${row.serialNumber||""} ${row.location||""}`.toLowerCase().includes(search.toLowerCase()));
    }else{
      const data=await api.cuttingOriginSearch(state.groupKey,search,60);
      state.origins=normalizeOrigins(data.items||[]);
    }
    target.innerHTML=originRows(state.origins);
    target.querySelectorAll("[data-origin-lot]").forEach(button=>button.addEventListener("click",()=>selectOriginById(host,state,button.dataset.originLot)));
  }catch(error){target.innerHTML=`<div class="module-error"><strong>No fue posible consultar carretos</strong><p>${fmt.escape(error.message)}</p></div>`}
}

function selectOriginById(host,state,lotId){
  const row=state.origins.find(item=>String(item.lotId)===String(lotId));
  if(!row){toast("Ese carreto ya no está en la lista actual. Busca nuevamente.","error");return}
  state.selectedLotId=row.lotId;
  state.selectedOrigin=row;
  const box=host.querySelector("[data-origin-confirm]");
  box.hidden=false;
  host.querySelector("[data-selected-origin]").innerHTML=`<div><small>Origen seleccionado</small><strong>${fmt.escape([row.lotNumber,row.serialNumber].filter(Boolean).join(" · ")||"Carreto")}</strong><span>${fmt.escape(row.warehouseCode||"")} · ${fmt.escape(row.locationName||row.location||"Sin ubicación")}</span></div><b>${fmt.number(row.available,3)} m en ERP</b>`;
  host.querySelector("[data-system-length]").value=String(row.available);
  host.querySelector("[data-reel-length]").value=String(row.available);
  state.reelLength=row.available;
  syncDifference(host,state);
  box.scrollIntoView({behavior:"smooth",block:"center"});
}

function syncDifference(host,state){
  const real=Number(host.querySelector("[data-reel-length]")?.value||0);
  state.reelLength=real;
  state.scrapLength=Number(host.querySelector("[data-scrap-length]")?.value||0);
  const diff=real-Number(state.selectedOrigin?.available||0);
  const target=host.querySelector("[data-inventory-difference]");
  if(!target)return;
  if(!state.selectedOrigin||!Number.isFinite(real)||real<=0||Math.abs(diff)<0.0001){target.hidden=true;target.innerHTML="";return}
  target.hidden=false;
  target.classList.toggle("negative",diff<0);
  target.classList.toggle("positive",diff>0);
  target.innerHTML=`<strong>Diferencia de inventario: ${diff>0?"+":""}${fmt.number(diff,3)} m</strong><span>Al confirmar, el ERP registrará primero el recuento físico y conservará la diferencia en la trazabilidad.</span>`;
}

async function previewBatch(host,state){
  if(!state.selectedOrigin){toast("Selecciona primero el carreto físico.","error");return}
  const reelLength=Number(host.querySelector("[data-reel-length]")?.value||0);
  const scrapLength=Number(host.querySelector("[data-scrap-length]")?.value||0);
  if(!Number.isFinite(reelLength)||reelLength<=0){toast("Indica la cantidad real encontrada en el carreto.","error");return}
  if(!Number.isFinite(scrapLength)||scrapLength<0){toast("La merma no puede ser negativa.","error");return}
  state.reelLength=reelLength;state.scrapLength=scrapLength;
  showStep(host,3);
  const target=host.querySelector("[data-cut-plan]");
  target.innerHTML=loading("Distribuyendo cortes completos entre los pedidos…");
  try{
    state.plan=sandboxMode?localSandboxPlan(state):await api.cuttingBatchPlan(state.groupKey,state.selectedLotId,reelLength,scrapLength);
    renderPlan(host,state);
  }catch(error){state.plan=null;target.innerHTML=`<div class="module-error"><strong>No fue posible calcular el plan</strong><p>${fmt.escape(error.message)}</p></div>`}
}

function localSandboxPlan(state){
  const required=Number(state.group.totalLength||0);
  const capacity=Math.max(state.reelLength-state.scrapLength,0);
  const cut=Math.min(required,capacity);
  return {canExecute:capacity>=required,reason:capacity>=required?null:"En Sandbox usa un carreto que cubra todo el grupo de prueba.",systemLength:Number(state.selectedOrigin?.available||0),confirmedLength:state.reelLength,discrepancy:state.reelLength-Number(state.selectedOrigin?.available||0),plannedLength:cut,plannedCuts:Number(state.group.cutCount||0),scrapLength:state.scrapLength,reelRemaining:state.reelLength-cut-state.scrapLength,groupRemainingBefore:required,groupRemainingAfter:Math.max(required-cut,0),groupCompleted:capacity>=required,partialBatch:capacity<required,approvalRequired:false,approvalReady:true,plan:[]};
}

function renderPlan(host,state){
  const plan=state.plan||{};
  const target=host.querySelector("[data-cut-plan]");
  const execute=host.querySelector("[data-execute-batch]");
  if(!plan.canExecute){
    target.innerHTML=`<section class="cut-plan-blocked"><strong>Este carreto no permite completar ningún corte</strong><p>${fmt.escape(plan.reason||"Selecciona otro carreto o confirma una cantidad mayor.")}</p></section>`;
    execute.disabled=true;return;
  }
  const discrepancy=Number(plan.discrepancy||0);
  const rows=plan.plan||[];
  const approvalBlocked=Boolean(plan.approvalRequired&&!plan.approvalReady);
  target.innerHTML=`
    <section class="cut-plan-summary">
      <div><small>Carreto confirmado</small><strong>${fmt.number(plan.confirmedLength,3)} m</strong></div>
      <div><small>Cortar ahora</small><strong>${fmt.number(plan.plannedLength,3)} m</strong></div>
      <div><small>Remanente carreto</small><strong>${fmt.number(plan.reelRemaining,3)} m</strong></div>
      <div><small>Quedará por cortar</small><strong>${fmt.number(plan.groupRemainingAfter,3)} m</strong></div>
    </section>
    ${Math.abs(discrepancy)>0.0001?`<section class="cut-plan-notice"><strong>Recuento físico: ${discrepancy>0?"+":""}${fmt.number(discrepancy,3)} m frente al ERP</strong><span>La diferencia se registrará antes de descontar los cortes.</span></section>`:""}
    ${plan.partialBatch?`<section class="cut-plan-partial"><strong>Este carreto no completa toda la referencia</strong><p>Se ejecutarán ${fmt.number(plan.plannedCuts,2)} corte(s) por ${fmt.number(plan.plannedLength,3)} m. Después quedarán ${fmt.number(plan.groupRemainingAfter,3)} m y el ERP te pedirá el siguiente carreto.</p></section>`:`<section class="cut-plan-complete"><strong>Este carreto completa toda la referencia</strong><p>Al confirmar, todos los cortes pendientes de este grupo quedarán listos para recogida en Alistamiento.</p></section>`}
    ${rows.length?`<section class="cut-plan-orders"><header><strong>Cortes que saldrán de este carreto</strong><span>${rows.length} línea(s) de pedido</span></header>${rows.map(planRow).join("")}</section>`:""}
    ${plan.approvalRequired?`<section class="cutting-approval-warning"><span>APROBACIÓN REQUERIDA</span><strong>El carreto quedará con ${fmt.number(plan.reelRemaining,3)} m</strong><p>${plan.approvalReady?"La aprobación ya está disponible. Puedes ejecutar este carreto.":"Solicita autorización para este carreto y este plan específico antes de ejecutar."}</p>${plan.approvalReady?"":'<button type="button" class="btn btn-warning" data-request-remainder-approval>Enviar a aprobación</button>'}</section>`:""}
    <section class="cut-plan-final"><strong>Solo el botón Confirmar modifica inventario.</strong><span>La operación completa se revierte si falla cualquier validación.</span></section>`;
  execute.disabled=approvalBlocked;
  execute.textContent=plan.partialBatch?"Confirmar este carreto y continuar":"Confirmar corte completo";
  target.querySelector("[data-request-remainder-approval]")?.addEventListener("click",()=>requestRemainderApproval(host,state));
}

function planRow(row){
  return `<article><div><strong>${fmt.escape(row.orderNumber||"Pedido")}</strong><small>${fmt.escape(row.clientName||"")}</small></div><span>${fmt.number(row.unitsToCut,2)} × ${fmt.number(row.lengthEach,3)} m</span><b>${fmt.number(row.lengthToCut,3)} m</b>${row.completesRequirement?'<em>Completa línea</em>':'<em>Continúa después</em>'}</article>`;
}

async function requestRemainderApproval(host,state){
  const plan=state.plan;
  nestedDialog(host,{title:"Autorizar remanente crítico",confirmLabel:"Enviar solicitud",body:`<div class="cutting-approval-dialog"><strong>Carreto: ${fmt.escape([state.selectedOrigin?.lotNumber,state.selectedOrigin?.serialNumber].filter(Boolean).join(" · ")||"Seleccionado")}</strong><p>Quedará un remanente de ${fmt.number(plan.reelRemaining,3)} m después de cortar ${fmt.number(plan.plannedLength,3)} m.</p></div><div class="field"><label>Enviar a *</label><select class="control" name="assignedRole" required><option value="jefe_logistica">Jefatura Logística</option><option value="auditoria">Auditoría</option><option value="gerencia">Gerencia</option></select></div><div class="field"><label>Justificación *</label><textarea class="control" name="reason" required rows="4" placeholder="Explica por qué conviene utilizar este carreto"></textarea></div>`,onConfirm:async dialog=>{
    await api.requestCutRemainderApproval(state.groupKey,{inventoryLotId:state.selectedLotId,reelLength:state.reelLength,scrapLength:state.scrapLength,assignedRole:dialog.querySelector('[name="assignedRole"]').value,reason:dialog.querySelector('[name="reason"]').value.trim()});
    toast("Solicitud enviada. Puedes cerrar este grupo y continuar con otro mientras se aprueba.","success",7000);
  }});
}

async function executeBatch(host,state,button){
  const plan=state.plan;
  if(!plan?.canExecute)return;
  button.disabled=true;
  try{
    const payload={inventoryLotId:state.selectedLotId,reelLength:state.reelLength,scrapLength:state.scrapLength,expectedPlannedLength:Number(plan.plannedLength||0)};
    const result=await (sandboxMode?api.sandboxExecuteCutGroup(state.groupKey,payload):api.executeCutGroup(state.groupKey,payload));
    await loadCuttingGroups(currentPage);
    window.__erpQueueRefresh?.();window.__erpOrderListRefresh?.();
    if(result.groupCompleted===false){
      const message=`Carreto registrado: ${fmt.number(result.cutLength,3)} m cortados. Quedan ${fmt.number(result.groupRemainingLength,3)} m de esta referencia.`;
      toast(message,"success",8000);
      await openCutGroup(state.groupKey,{startStep:2,message});
    }else{
      toast(`Referencia completada. Remanente del último carreto: ${fmt.number(result.reelRemaining??result.remainingLength,3)} m.`,"success",8000);
      host.replaceChildren();
    }
  }catch(error){toast(error.message,"error",9000);button.disabled=false}
}

function openFullReelDialog(host,state,item){
  if(!item)return;
  const requirement=state.items.find(row=>String(row.requirementId)===String(item.dataset.requirementId));
  if(!requirement)return;
  const required=Number(requirement.remainingLength??requirement.totalLength??0);
  const origins=state.origins||[];
  if(!origins.length){toast("No hay carretos oficiales disponibles para esta referencia.","error");return}
  nestedDialog(host,{title:"Entregar carreto completo",confirmLabel:"Confirmar carreto completo",body:`<div class="cutting-approval-dialog"><strong>${fmt.escape(requirement.orderNumber)} · ${fmt.escape(state.group.reference||"")}</strong><p>Usa esta opción únicamente cuando el carreto físico completo mide exactamente ${fmt.number(required,3)} m y se entregará sin generar remanente.</p></div><div class="field"><label>Carreto físico *</label><select class="control" name="lotId" required><option value="">Seleccionar…</option>${origins.map(row=>`<option value="${fmt.escape(row.lotId)}">${fmt.escape([row.lotNumber,row.serialNumber].filter(Boolean).join(" · ")||"Carreto")} · ${fmt.number(row.available,3)} m · ${fmt.escape(row.locationName||row.location||"")}</option>`).join("")}</select></div><div class="field"><label>Medida exacta confirmada</label><input class="control" name="reelLength" type="number" step="0.0001" value="${required}" readonly></div>`,onConfirm:async dialog=>{
    const lotId=dialog.querySelector('[name="lotId"]').value;
    if(!lotId)throw new Error("Selecciona el carreto físico");
    await (sandboxMode?api.sandboxResolveCutRequirement(requirement.requirementId,"FULL_REEL",{inventoryLotId:lotId,reelLength:required}):api.resolveCutRequirement(requirement.requirementId,"FULL_REEL",{inventoryLotId:lotId,reelLength:required}));
    toast("Carreto completo registrado y enviado a recogida.","success",6500);
    await loadCuttingGroups(currentPage);
    try{await openCutGroup(state.groupKey)}catch{host.replaceChildren()}
  }});
}

function nestedDialog(host,{title,body,confirmLabel="Confirmar",cancelLabel="Cancelar",onConfirm}){
  const layer=document.createElement("div");
  layer.className="cut-nested-layer";
  layer.innerHTML=`<section class="cut-nested-dialog"><header><div><span>ACCIÓN DE CORTE</span><h4>${fmt.escape(title)}</h4></div><button type="button" class="icon-btn" data-nested-close aria-label="Cerrar">×</button></header><div class="cut-nested-body">${body}</div><footer><button type="button" class="btn btn-ghost" data-nested-close>${fmt.escape(cancelLabel)}</button><button type="button" class="btn btn-primary" data-nested-confirm>${fmt.escape(confirmLabel)}</button></footer></section>`;
  host.append(layer);
  const close=()=>layer.remove();
  layer.querySelectorAll("[data-nested-close]").forEach(button=>button.addEventListener("click",close));
  layer.addEventListener("click",event=>{if(event.target===layer)close()});
  layer.querySelector("[data-nested-confirm]")?.addEventListener("click",async event=>{
    const controls=[...layer.querySelectorAll("input,select,textarea")].filter(control=>!control.disabled&&control.type!=="hidden");
    for(const control of controls){if(!control.checkValidity()){control.reportValidity();control.focus();return}}
    event.currentTarget.disabled=true;
    try{await onConfirm?.(layer);close()}catch(error){toast(error.message||String(error),"error",8000);event.currentTarget.disabled=false}
  });
  return {layer,close};
}

function toggleNoCut(item,show){
  if(!item)return;
  const panel=item.querySelector('[data-resolution-panel="NO_CUT"]');
  if(panel)panel.hidden=!show;
}

async function resolveNoCut(host,state,item,button){
  const requirementId=item?.dataset.requirementId;
  const reason=item?.querySelector("[data-no-cut-reason]")?.value.trim();
  if(!reason){toast("Escribe el motivo de la corrección.","error");return}
  button.disabled=true;
  try{
    await (sandboxMode?api.sandboxResolveCutRequirement(requirementId,"NO_CUT",{reason}):api.resolveCutRequirement(requirementId,"NO_CUT",{reason}));
    toast("La línea quedó marcada como no requiere corte.","success",6000);
    await loadCuttingGroups(currentPage);
    try{await openCutGroup(state.groupKey)}catch{host.replaceChildren()}
  }catch(error){toast(error.message,"error",8000);button.disabled=false}
}
