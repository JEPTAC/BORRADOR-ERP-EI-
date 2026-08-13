import {api} from "../services/api.js";
import {fmt,statusBadge} from "../core/format.js";
import {loading,toast,modal,empty,wizard,guide} from "../core/ui.js";
import {summaryItem} from "../core/guided.js";
import {hasRole} from "../core/state.js";
import {runTotalQaRobot,runDeepQaCampaign,runRouteQaCampaign,resumeTotalQaRobot,robotCheckRows} from "./qa-total.js";
import {runFlowCertification,resumeLatestFlow,openFlowResults} from "./qa-flow.js";

export async function renderQa(root){
  if(!hasRole("super_admin")){
    root.innerHTML=`<section class="card card-pad"><h3>Acceso restringido</h3><p>La certificación del flujo es exclusiva de Superadministración.</p></section>`;
    return;
  }
  root.innerHTML=`
    <section class="qa-total-page">
      <header class="qa-total-hero card">
        <div class="qa-total-hero-copy">
          <span class="qa-total-eyebrow">SUPER ADMIN · CERTIFICACIÓN DE SALIDA</span>
          <h2>Certificación del flujo de pedidos</h2>
          <p>Esta es la prueba de lanzamiento: crea <strong>336 pedidos TEST-QA</strong> y los hace pasar por la ruta completa usando los <strong>roles, usuarios y RPC reales de cada módulo</strong>. Una combinación solo aprueba si llega exactamente a <strong>CLOSED</strong>.</p>
          <div class="qa-total-hero-actions">
            <button class="btn btn-primary btn-large" id="run-flow-cert">▶ Certificar flujo completo</button>
            <button class="btn btn-ghost" id="resume-flow-cert" hidden>↻ Reanudar flujo</button>
            <button class="btn btn-ghost" id="view-flow-result">Ver resultado / rutas</button>
          </div>
        </div>
        <div class="qa-total-seal"><span>FLOW</span><strong>10.25.5</strong><small>Order Certification</small></div>
      </header>

      <section class="qa-total-grid">
        <article class="qa-total-console card" id="qa-total-console">
          <div class="qa-total-console-head">
            <div><span class="qa-total-eyebrow">EJECUCIÓN ACTUAL</span><h3 id="qa-total-phase">Listo para certificar</h3><p id="qa-total-detail">La prueba principal todavía no está ejecutándose.</p></div>
            <strong id="qa-total-counts">—</strong>
          </div>
          <div class="qa-total-progress"><span id="qa-total-progress-bar"></span></div>
          <div class="qa-total-log" id="qa-total-log"><div class="qa-total-log-empty">Aquí verás cada pedido avanzando por su flujo real.</div></div>
        </article>
        <aside class="qa-total-scope card">
          <span class="qa-total-eyebrow">QUÉ CERTIFICA</span>
          <div class="qa-scope-item"><strong>336</strong><div><b>Pedidos completos</b><span>Tipo, condición de pago, mora/Caja, ruta de entrega, Corte y Compra.</span></div></div>
          <div class="qa-scope-item"><strong>ROL</strong><div><b>Usuario operativo real</b><span>En cada etapa toma un perfil autenticado del rol esperado y prueba sus permisos.</span></div></div>
          <div class="qa-scope-item"><strong>RPC</strong><div><b>Operación real</b><span>Cartera, Caja, Compras, Recepción, Corte, Alistamiento, Facturación y Despachos usan las mismas funciones del ERP.</span></div></div>
          <div class="qa-scope-item"><strong>FILTROS</strong><div><b>Bloqueos transversales</b><span>Nota, novedad + solución, reporte + solución, espera/reanudación y aprobación.</span></div></div>
          <div class="qa-scope-item"><strong>100%</strong><div><b>Ruta exacta</b><span>Etapa esperada = etapa obtenida, hasta CLOSED. Un salto incorrecto hace fallar el pedido.</span></div></div>
          <div class="qa-scope-item"><strong>22</strong><div><b>Ramas especiales</b><span>10 ramas de aprobación/cancelación + 12 casos de no-entrega (4 rutas × reprogramar/devolver/resolver).</span></div></div>
        </aside>
      </section>

      <section class="card">
        <header class="card-head"><div><span class="qa-total-eyebrow">EVIDENCIA DE LANZAMIENTO</span><h3>Ruta, módulo y usuario — pedido por pedido</h3><p>El resultado muestra las 336 combinaciones y, dentro de cada una, quién operó cada etapa, qué acción ejecutó, qué etapa esperaba y cuál obtuvo.</p></div><button class="btn btn-primary" id="view-flow-result-2">Abrir certificación</button></header>
      </section>

      <details class="card qa-manual">
        <summary class="qa-manual-head"><div><span class="qa-total-eyebrow">DIAGNÓSTICOS COMPLEMENTARIOS</span><h3>Pruebas técnicas secundarias</h3><p>Responsive, carga, EXTREME y robots antiguos quedan disponibles, pero no son el criterio principal del flujo.</p></div></summary>
        <div class="qa-manual-actions">
          <button class="qa-mini-action" id="run-matrix"><strong>336 rutas antiguas</strong><span>Diagnóstico de enrutamiento</span></button>
          <button class="qa-mini-action" id="run-controls"><strong>10 controles</strong><span>Reglas empresariales transversales</span></button>
          <button class="qa-mini-action" id="run-deep"><strong>Ciclos profundos</strong><span>Casos aislados por etapa</span></button>
          <button class="qa-mini-action qa-mini-action-danger" id="run-extreme"><strong>EXTREME</strong><span>Campaña masiva; no necesaria para certificar el flujo normal</span></button>
          <button class="qa-mini-action" id="run-pulse"><strong>Pulso concurrente</strong><span>Capacidad rápida</span></button>
        </div>
      </details>

      <section class="card"><header class="card-head"><div><span class="qa-total-eyebrow">HISTORIAL</span><h3>Ejecuciones QA</h3></div><button class="btn btn-ghost" id="refresh-qa">Actualizar</button></header><div class="card-body" id="qa-runs">${loading()}</div></section>
    </section>`;

  root.querySelector("#run-flow-cert").onclick=()=>confirmFlow(root);
  root.querySelector("#resume-flow-cert").onclick=()=>resumeLatestFlow(root);
  root.querySelector("#view-flow-result").onclick=()=>openLatestFlow();
  root.querySelector("#view-flow-result-2").onclick=()=>openLatestFlow();
  root.querySelector("#run-matrix").onclick=()=>confirmRun(root,"matrix");
  root.querySelector("#run-controls").onclick=()=>confirmRun(root,"controls");
  root.querySelector("#run-deep").onclick=()=>confirmDeep(root,"TOTAL");
  root.querySelector("#run-extreme").onclick=()=>confirmDeep(root,"EXTREME");
  root.querySelector("#run-pulse").onclick=()=>runConcurrencyPulse(root);
  root.querySelector("#refresh-qa").onclick=()=>load(root);
  root.addEventListener("erp:qa-total-finished",()=>load(root));
  root.addEventListener("erp:qa-flow-finished",()=>{load(root);loadFlowResumable(root)});
  await Promise.all([load(root),loadFlowResumable(root)]);
}

function confirmFlow(root){
  wizard({title:"Certificar flujo completo",subtitle:"336 pedidos TEST-QA operados con roles reales",steps:[
    {title:"Qué va a hacer",description:"Creará las 336 combinaciones y recorrerá cada pedido hasta CLOSED usando los usuarios/roles esperados en Cartera, Caja, Compras, Recepción, Alistamiento, Corte, Facturación y Despachos."},
    {title:"Filtros incluidos",description:"En cada etapa prueba Nota, Novedad y solución, Reporte y solución, Espera/Reanudación; además cada pedido prueba una aprobación de prioridad."},
    {title:"Criterio",description:"Solo muestra LANZABLE si 336/336 cierran por la ruta exacta, ningún módulo/rol falla y también pasan las ramas especiales y de no-entrega."}
  ],confirmLabel:"Iniciar certificación",onConfirm:()=>runFlowCertification(root)});
}
async function openLatestFlow(){
  try{const latest=await api.qaFlowLatest();if(!latest?.available)return toast("Todavía no existe una certificación de flujo.","info",5000);await openFlowResults(latest.runId)}catch(error){toast(error.message||String(error),"error",9000)}
}
async function loadFlowResumable(root){
  try{const latest=await api.qaFlowLatestResumable();const b=root.querySelector("#resume-flow-cert");if(!b)return;if(latest?.available){b.hidden=false;b.textContent=`↻ Reanudar ${latest.progress?.passed||0}/${latest.progress?.planned||336}`}else b.hidden=true}catch{}
}


function confirmDeep(root,mode){
  const extreme=mode==="EXTREME";
  wizard({title:extreme?"Ejecutar prueba exhaustiva cruzada":"Ejecutar ciclos profundos",subtitle:extreme?"Campaña de miles de casos aislados.":"288 ciclos transversales de negocio.",finishLabel:extreme?"Iniciar campaña exhaustiva":"Iniciar campaña",steps:[
    {title:"Cobertura",description:extreme?"Cruza entradas comerciales × etapas × novedades/reportes × decisiones.":"Cada tipo y etapa prueba incidencias, pausas, aprobaciones y cancelación.",content:`<div class="wizard-summary">${summaryItem("Modo",extreme?"EXTREME":"TOTAL")}${summaryItem("Producción","No se modifica")}${summaryItem("Pedidos","TEST-QA")}${summaryItem("Ejecución","Caso por transacción")}</div>`},
    {title:"Momento de ejecución",description:extreme?"No la ejecutes durante una operación crítica.":"Puede tomar varios minutos.",content:`<div class="wizard-confirm-box"><strong>${extreme?"Esta campaña puede generar miles de casos.":"El Robot seguirá aunque encuentre fallos."}</strong><p>${extreme?"Úsala como certificación de versión o fuera de las horas de mayor uso. No sustituye la prueba k6 de capacidad.":"Cada fallo conserva SQLSTATE, etapa, acción y combinación exacta para que pueda reproducirse."}</p></div>`}
  ],onFinish:async()=>{
    const btn=root.querySelector(extreme?"#run-extreme":"#run-deep");btn.disabled=true;
    try{const r=await runDeepQaCampaign(root,mode);toast(r.result?.status==="PASSED"?"Campaña profunda aprobada.":"La campaña encontró fallos. Revisa el detalle.",r.result?.status==="PASSED"?"success":"error",10000);await load(root)}
    catch(error){toast(error.message||String(error),"error",10000)}finally{btn.disabled=false}
  }});
}

function percentile(values,p){
  if(!values.length)return 0;const sorted=[...values].sort((a,b)=>a-b);const i=Math.min(sorted.length-1,Math.max(0,Math.ceil(p*sorted.length)-1));return sorted[i];
}
async function pulseCall(index){
  const calls=[()=>api.dashboard(),()=>api.listOrders({page:1,pageSize:20,includeHistory:false}),()=>api.inventoryFiltered({page:1,pageSize:20}),()=>api.workMyDay(),()=>api.approvals("PENDING",1,20),()=>api.exceptionSummary()];
  const started=performance.now();try{await calls[index%calls.length]();return {ok:true,ms:performance.now()-started}}catch(error){return {ok:false,ms:performance.now()-started,error:error.message||String(error)}}
}
async function runConcurrencyPulse(root){
  const button=root.querySelector("#run-pulse");button.disabled=true;button.textContent="Midiendo…";
  const stages=[5,10,20,40],all=[],stageResults=[];const startedAt=new Date();
  try{
    for(const concurrency of stages){
      const start=performance.now();const results=await Promise.all(new Array(concurrency).fill(0).map((_,i)=>pulseCall(i)));
      const elapsed=Math.max(1,performance.now()-start);all.push(...results);
      stageResults.push({concurrency,requests:results.length,errors:results.filter(x=>!x.ok).length,p95Ms:Math.round(percentile(results.map(x=>x.ms),.95)),rps:Number((results.length/(elapsed/1000)).toFixed(2))});
      toast(`Pulso ${concurrency}: p95 ${stageResults.at(-1).p95Ms} ms · ${stageResults.at(-1).errors} errores`,stageResults.at(-1).errors?"warning":"info",2500);
    }
    const durations=all.map(x=>x.ms),errors=all.filter(x=>!x.ok).length,errorRate=all.length?errors/all.length:0;
    const payload={source:"BROWSER_PULSE",profile:"PULSE_40",status:errorRate<.01&&percentile(durations,.95)<2000?"PASSED":"FAILED",maxVirtualUsers:40,totalRequests:all.length,requestRate:Number((stageResults.reduce((a,x)=>a+x.rps,0)/stageResults.length).toFixed(2)),errorRate,p50Ms:percentile(durations,.50),p90Ms:percentile(durations,.90),p95Ms:percentile(durations,.95),p99Ms:percentile(durations,.99),maxMs:Math.max(...durations,0),checksRate:1-errorRate,thresholds:{errorRate:"<1%",p95Ms:"<2000"},stages:stageResults,summary:{note:"Pulso desde un navegador y una sesión. No representa el límite de capacidad; usar k6 para breakpoint real.",errors:all.filter(x=>!x.ok).slice(0,10)},startedAt:startedAt.toISOString(),completedAt:new Date().toISOString()};
    await api.qaCapacityRecord(payload);toast(`Pulso terminado: p95 ${Math.round(payload.p95Ms)} ms · p99 ${Math.round(payload.p99Ms)} ms · ${(errorRate*100).toFixed(2)}% errores.`,payload.status==="PASSED"?"success":"warning",9000);await loadCapacity(root);
  }catch(error){toast(error.message||String(error),"error",9000)}finally{button.disabled=false;button.innerHTML="<strong>Pulso concurrente</strong><span>5 → 10 → 20 → 40 solicitudes simultáneas</span>"}
}

async function loadCapacity(root){
  const target=root.querySelector("#qa-capacity");if(!target)return;
  try{
    const data=await api.qaCapacityRuns(20),items=data?.items||[];
    target.innerHTML=items.length?`<div class="table-wrap mobile-card-table"><table><thead><tr><th>Prueba</th><th>Carga</th><th>Solicitudes</th><th>RPS</th><th>p95</th><th>p99</th><th>Error</th><th>Estado</th></tr></thead><tbody>${items.map(x=>`<tr><td data-label="Prueba"><strong>${fmt.escape(x.source||"QA")}</strong><small>${fmt.escape(x.profile||"")} · ${fmt.date(x.createdAt)}</small></td><td data-label="Carga">${x.maxVirtualUsers??"—"}</td><td data-label="Solicitudes">${fmt.number(x.totalRequests||0)}</td><td data-label="RPS">${x.requestRate!=null?fmt.number(x.requestRate,1):"—"}</td><td data-label="p95">${x.p95Ms!=null?fmt.number(x.p95Ms,0)+" ms":"—"}</td><td data-label="p99">${x.p99Ms!=null?fmt.number(x.p99Ms,0)+" ms":"—"}</td><td data-label="Error">${x.errorRate!=null?fmt.number(Number(x.errorRate)*100,2)+"%":"—"}</td><td data-label="Estado">${statusBadge(x.status)}</td></tr>`).join("")}</tbody></table></div>`:empty("Sin mediciones de capacidad","Ejecuta el pulso concurrente o el workflow ERP QA Capacity (k6).");
  }catch(error){target.innerHTML=`<div class="module-error"><strong>No fue posible cargar capacidad</strong><p>${fmt.escape(error.message)}</p></div>`}
}

function confirmTotal(root){
  wizard({title:"Ejecutar Robot QA total",subtitle:"Certificación exhaustiva exclusiva de Super Admin.",finishLabel:"Iniciar recorrido total",steps:[
    {title:"Aislamiento",description:"La prueba puede crear y mover datos TEST, nunca pedidos productivos.",content:`<div class="wizard-summary">${summaryItem("Pedidos creados","TEST-QA")}${summaryItem("Producción","No se modifica")}${summaryItem("Limpieza","Automática")}${summaryItem("Usuario","Super Admin")}</div><div class="wizard-confirm-box"><strong>La prueba navega realmente la aplicación</strong><p>Se recomienda mantener esta pestaña abierta hasta que finalice. El visor E2E se ejecutará dentro del mismo navegador.</p></div>`},
    {title:"Cobertura",description:"336 rutas + cruce extremo + UI + Sandbox + responsive.",content:`<div class="wizard-tip">Para la certificación más fuerte también puedes ejecutar después <b>npm run test:total</b> o el workflow de GitHub Actions incluido en V10.25.1; ese segundo robot abre un navegador independiente y genera trazas.</div>`},
    {title:"Confirmar",description:"Puede tardar bastante: la prueba total incluye miles de casos funcionales aislados además del recorrido visual.",content:`<div class="wizard-confirm-box"><strong>No uses esta pestaña mientras el robot está trabajando.</strong><p>Si encuentra un fallo, continuará con las demás pruebas para entregar un diagnóstico completo.</p></div>`}
  ],onFinish:async()=>{
    const btn=root.querySelector("#run-total-robot");btn.disabled=true;btn.textContent="Robot ejecutándose…";
    try{const result=await runTotalQaRobot(root);toast(result.result?.status==="PASSED"?"Robot QA total aprobado.":"Robot QA terminó con fallos. Revisa el detalle.",result.result?.status==="PASSED"?"success":"error",10000)}
    catch(error){toast(error.message||String(error),"error",10000)}
    finally{btn.disabled=false;btn.textContent="▶ Ejecutar prueba total"}
  }});
}

async function loadResumable(root){
  const button=root.querySelector("#resume-total-robot");if(!button)return;
  try{
    const data=await api.qaRobotLatestResumable();
    button.hidden=!data?.available;
    if(data?.available){button.dataset.runId=data.runId;const p=data.progress||{};button.textContent=`↻ Reanudar ${fmt.number(p.executed||0)}/${fmt.number(p.planned||0)}`}
  }catch{button.hidden=true}
}
async function resumeLatest(root){
  const button=root.querySelector("#resume-total-robot"),runId=button?.dataset.runId;if(!runId)return toast("No hay una certificación pendiente para reanudar.","warning");
  button.disabled=true;const original=button.textContent;button.textContent="Reanudando…";
  try{const r=await resumeTotalQaRobot(root,runId);toast(r.result?.certified?"Certificación reanudada y aprobada.":"La ejecución terminó con hallazgos.",r.result?.certified?"success":"error",10000)}
  catch(error){toast(error.message||String(error),"error",10000)}
  finally{button.disabled=false;button.textContent=original;await Promise.all([load(root),loadResumable(root)])}
}

async function load(root){
  const target=root.querySelector("#qa-runs");if(!target)return;
  try{
    const runs=await api.qaRuns(60);
    target.innerHTML=runs.length?`<div class="qa-run-grid">${runs.map(run=>`<article class="qa-run-card ${run.runType==="TOTAL_ROBOT"?"qa-run-total":""}"><header><div><strong>${fmt.escape(run.runType==="TOTAL_ROBOT"?"Robot QA total":fmt.suite(run.runType||"MATRIX"))}</strong><span>${fmt.date(run.startedAt)}</span></div>${statusBadge(run.status)}</header><div class="qa-run-metrics"><div><label>Total</label><strong>${run.totalScenarios}</strong></div><div><label>Aprobados</label><strong class="success">${run.passedScenarios}</strong></div><div><label>Fallidos</label><strong class="danger">${run.failedScenarios}</strong></div><div><label>Duración</label><strong>${run.completedAt?fmt.number((new Date(run.completedAt)-new Date(run.startedAt))/1000,1)+" s":"En ejecución"}</strong></div></div><footer><button class="btn btn-primary" data-run="${run.id}" data-type="${run.runType||"MATRIX"}">Abrir detalle</button></footer></article>`).join("")}</div>`:empty("Sin pruebas ejecutadas","Ejecuta el Robot QA total antes de liberar cambios importantes.");
    target.querySelectorAll("[data-run]").forEach(button=>button.onclick=()=>detail(button.dataset.run,button.dataset.type));
  }catch(error){target.innerHTML=`<div class="module-error"><strong>No fue posible cargar el historial</strong><p>${fmt.escape(error.message)}</p></div>`}
}

function confirmRun(root,type){
  const config={matrix:{title:"Probar 336 combinaciones",total:"336",detail:"Recorre tipos de pedido, pago, mora/retención, entrega, Corte y compra."},controls:{title:"Probar 10 controles",total:"10",detail:"Verifica reglas transversales empresariales."},all:{title:"Ejecutar certificación integral",total:"Todo el gate release",detail:"Rutas, recorridos completos, ramas, integridad, interfaz real, Sandbox y responsive."}}[type];
  wizard({title:config.title,subtitle:"Prueba dirigida del motor ERP.",finishLabel:"Iniciar",steps:[{title:"Alcance",description:config.detail,content:`<div class="wizard-summary">${summaryItem("Pruebas",config.total)}${summaryItem("Limpieza","Automática")}${summaryItem("Entorno","Motor real")}${summaryItem("Producción","Protegida")}</div>`},{title:"Confirmar",description:"Revisa el resultado antes de liberar cambios.",content:`<div class="wizard-tip">Esta prueba no reemplaza el Robot QA total de interfaz.</div>`}],onFinish:async()=>runSuite(root,type)});
}
async function runSuite(root,type){
  const buttons=[...root.querySelectorAll("#run-integral,#run-matrix,#run-controls")];buttons.forEach(b=>b.disabled=true);
  try{
    if(type==="matrix"){const r=await runRouteQaCampaign(root);toast(r.result?.status==="PASSED"?"336/336 rutas canónicas aprobadas.":"La certificación de rutas encontró hallazgos.",r.result?.status==="PASSED"?"success":"error",9000)}
    else if(type==="controls"){const r=await api.runQaControls(true);notify(r,"Controles empresariales")}
    else{const r=await runTotalQaRobot(root);toast(r.result?.certified?"ERP certificado para liberación.":"La certificación integral no quedó en verde.",r.result?.certified?"success":"error",10000)}
    await load(root);
  }catch(error){toast(error.message||String(error),"error",9000)}finally{buttons.forEach(b=>b.disabled=false)}
}
function notify(result,label){toast(result.failed?`${label}: ${result.failed} fallo(s).`:`${label}: ${result.passed}/${result.total} aprobadas.`,result.failed?"error":"success",7000)}


function qaPath(path){
  return Array.isArray(path)&&path.length?path.map(step=>fmt.step(step)).join(" → "):"—";
}
function qaCombination(spec={}){
  const bits=[spec.orderType||"—",spec.paymentCondition||"—",spec.deliveryRoute||"—"];
  bits.push(`Corte ${spec.requiresCut?"Sí":"No"}`);
  bits.push(`Compra ${spec.requiresPurchase?"Sí":"No"}`);
  if(spec.hasCreditArrears)bits.push("Mora Sí");
  if(spec.heldByCashier)bits.push("Caja Sí");
  return bits.join(" · ");
}
function qaTimeline(timeline=[]){
  if(!Array.isArray(timeline)||!timeline.length)return `<div class="empty compact"><strong>Sin evidencia por etapas</strong><div>La ruta aún no ha ejecutado transiciones o corresponde a una corrida anterior sin evidencia recuperable.</div></div>`;
  return `<div class="table-wrap mobile-card-table"><table><thead><tr><th>#</th><th>Etapa</th><th>Acciones ejecutadas</th><th>Siguiente esperada</th><th>Siguiente real</th><th>Resultado</th></tr></thead><tbody>${timeline.map(e=>`<tr><td data-label="#">${e.stepIndex||"—"}</td><td data-label="Etapa"><strong>${fmt.escape(fmt.step(e.stepCode||""))}</strong></td><td data-label="Acciones"><small>${fmt.escape((e.actions||[]).map(a=>fmt.label(a)).join(" → ")||"—")}</small></td><td data-label="Esperada">${fmt.escape(fmt.step(e.expectedNextStep||""))}</td><td data-label="Real">${fmt.escape(fmt.step(e.actualNextStep||""))}</td><td data-label="Resultado">${e.status==="PASSED"?'<strong class="success">PASSED</strong>':'<strong class="danger">FAILED</strong>'}${e.errorMessage?`<small class="danger">${fmt.escape(e.errorMessage)}</small>`:""}</td></tr>`).join("")}</tbody></table></div>`;
}
async function openRouteObservatory(family,runId=null){
  try{
    const data=await api.qaReleaseRouteMatrix(runId,family,"ALL",null,1,500);
    const items=data.items||[],summary=data.summary||{};
    const complete=Number(summary.planned||0)===336&&Number(summary.normal||0)===336&&Number(summary.failed||0)===0&&Number(summary.pending||0)===0;
    const label=family==="JOURNEY_FULL"?"Recorridos completos":"Rutas canónicas";
    const rows=items.map((x,index)=>{
      const evidenceOk=Number(x.evidenceSteps||0)===Number(x.expectedEvidenceSteps||0)&&Number(x.evidenceFailed||0)===0;
      const state=x.normal?'<strong class="success">NORMAL</strong>':x.status==="FAILED"?'<strong class="danger">FALLÓ</strong>':x.status==="PASSED"?'<strong class="danger">NO AUDITABLE</strong>':`<strong>${fmt.escape(fmt.label(x.status||"PENDING"))}</strong>`;
      return `<tr><td data-label="#">${index+1}</td><td data-label="Combinación"><strong>${fmt.escape(x.caseKey||"—")}</strong><small>${fmt.escape(qaCombination(x.specification||{}))}</small></td><td data-label="Estado">${state}<small>${fmt.escape(x.orderNumber||"")}</small></td><td data-label="Ruta esperada"><small>${fmt.escape(qaPath(x.expectedPath))}</small></td><td data-label="Ruta real"><small class="${x.pathMatch?"success":"danger"}">${fmt.escape(qaPath(x.actualPath))}</small></td><td data-label="Evidencia"><strong class="${evidenceOk?"success":"danger"}">${x.evidenceSteps||0}/${x.expectedEvidenceSteps||0}</strong><small>${x.evidenceFailed||0} etapa(s) fallidas</small></td><td data-label="Transporte"><strong class="${(x.transportFailures||0)||(x.timeoutFailures||0)?"danger":"success"}">${x.transportFailures||0} / ${x.timeoutFailures||0}</strong><small>transporte / timeout</small></td><td data-label="Detalle"><details><summary>Ver recorrido</summary><div class="section-gap-small"></div><p><strong>Esperada:</strong> ${fmt.escape(qaPath(x.expectedPath))}</p><p><strong>Real:</strong> ${fmt.escape(qaPath(x.actualPath))}</p><p><strong>Limpieza:</strong> ${x.cleanupVerified?"OK":"NO"} · <strong>Intentos:</strong> ${x.attemptCount||0} · <strong>Cerró:</strong> ${x.closed?"Sí":"No"}</p>${x.errorMessage?`<p class="danger"><strong>${fmt.escape(x.errorSqlstate||"ERROR")}</strong> · ${fmt.escape(x.errorMessage)}</p>`:""}${qaTimeline(x.timeline||[])}</details></td></tr>`;
    }).join("");
    modal({title:`Observatorio · ${label}`,size:"xwide",confirmLabel:"",body:`<div class="qa-summary"><div class="qa-box"><span class="muted">Planificadas</span><strong>${summary.planned||0}/336</strong></div><div class="qa-box"><span class="muted">Normales auditadas</span><strong class="${complete?"success":"danger"}">${summary.normal||0}/336</strong></div><div class="qa-box"><span class="muted">Fallidas</span><strong class="${summary.failed?"danger":"success"}">${summary.failed||0}</strong></div><div class="qa-box"><span class="muted">Pendientes</span><strong class="${summary.pending?"danger":"success"}">${summary.pending||0}</strong></div></div><div class="section-gap-small"></div><div class="wizard-tip"><strong>Una ruta solo cuenta como NORMAL</strong> si la ruta esperada coincide exactamente con la real, termina en CLOSED, tiene evidencia para cada transición, limpió su pedido TEST y registró 0 timeout / 0 transporte.</div><div class="section-gap-small"></div><div class="table-wrap mobile-card-table"><table><thead><tr><th>#</th><th>Combinación</th><th>Estado</th><th>Ruta esperada</th><th>Ruta real</th><th>Evidencia</th><th>Transporte</th><th>Detalle</th></tr></thead><tbody>${rows||`<tr><td colspan="8">No hay rutas creadas en la última corrida QA.</td></tr>`}</tbody></table></div>`});
  }catch(error){toast(error.message||String(error),"error",10000)}
}

async function detail(id,type){
  if(type==="TOTAL_ROBOT"){
    const [data,certificate]=await Promise.all([api.qaRobotDetail(id),api.qaRobotReleaseCertificate(id).catch(()=>null)]),run=data.run||{},checks=data.checks||[],deep=data.deepSummary||{},deepFailures=data.deepFailures||[];
    const cert=certificate||run.summary?.releaseCertificate||null;
    const gates=cert?.gates||{};
    const gate=(label,g,detailText)=>`<div class="qa-box"><span class="muted">${fmt.escape(label)}</span><strong class="${g?.ok?"success":"danger"}">${g?.ok?"PASSED":"NO PASSED"}</strong><small>${fmt.escape(detailText(g||{}))}</small></div>`;
    const certificateBlock=cert?`<div class="section-gap-small"></div><section class="qa-release-certificate"><div class="card-head compact"><div><span class="qa-total-eyebrow">CERTIFICADO DE LIBERACIÓN</span><h3 class="${cert.certified?"success":"danger"}">${cert.certified?"ERP CERTIFICADO":"ERP NO CERTIFICADO"}</h3><p>Estado: ${fmt.escape(cert.releaseState||"—")} · versión ${fmt.escape(cert.version||"10.25.4")}</p></div></div><div class="qa-summary qa-release-gates">${gate("Rutas canónicas",gates.routing,g=>`${g.passed||0}/336 aprobadas · ${g.pending||0} pendientes`)}${gate("Recorridos completos",gates.journeys,g=>`${g.passed||0}/336 aprobados · ${g.pending||0} pendientes`)}${gate("Campaña EXTREME",gates.extreme,g=>`${g.executed||0}/${g.planned||0} ejecutados · ${g.failed||0} fallidos · timeout ${g.timeouts||0} · transporte ${g.transport||0}`)}${gate("Interfaz",gates.interface,g=>`${g.passedModules||0}/${g.expectedModules||0} módulos`)}${gate("Integridad",gates.integrity,g=>`${g.passed||0}/${g.expected||0} checks`)}${gate("Responsive",gates.responsive,g=>`${g.passed||0}/${g.expected||0} viewports/módulos`)}${gate("Acciones Sandbox UI",gates.sandboxUi,g=>`${g.passed||0}/${g.expected||0} acciones`)}${gate("Limpieza",gates.cleanup,g=>`${g.remainingTestOrders||0} pedidos TEST remanentes`)}</div></section>`:"";
    const deepBlock=Number(deep.total||0)>0?`<div class="section-gap"></div><div class="card-head compact"><div><span class="qa-total-eyebrow">CASOS FUNCIONALES AISLADOS</span><h3>Campaña profunda</h3><p>${fmt.number(deep.total||0)} casos · ${fmt.number(deep.passed||0)} correctos · ${fmt.number(deep.failed||0)} fallidos · ${fmt.number(deep.pending||0)} pendientes.</p></div></div>${deepFailures.length?`<div class="table-wrap mobile-card-table"><table><thead><tr><th>Caso</th><th>Familia</th><th>SQLSTATE</th><th>Contexto</th><th>Error original</th><th>Tiempo</th></tr></thead><tbody>${deepFailures.map(x=>`<tr><td data-label="Caso"><strong>${fmt.escape(x.caseKey||"—")}</strong><small>${fmt.escape(x.campaignMode||"")}</small></td><td data-label="Familia">${fmt.escape(fmt.label(x.family||""))}</td><td data-label="SQLSTATE"><code>${fmt.escape(x.errorSqlstate||"—")}</code></td><td data-label="Contexto"><small>${fmt.escape(fmt.data(x.specification||{}))}</small></td><td data-label="Error" class="danger">${fmt.escape(x.errorMessage||"—")}</td><td data-label="Tiempo">${x.durationMs!=null?fmt.number(x.durationMs)+" ms":"—"}</td></tr>`).join("")}</tbody></table></div>`:`<div class="empty compact"><strong>Sin fallos funcionales profundos</strong><div>Todos los casos aislados registrados finalizaron correctamente.</div></div>`}`:"";
    modal({title:`Robot QA ${id.slice(0,8)}`,size:"xwide",confirmLabel:"",body:`<div class="qa-summary"><div class="qa-box"><span class="muted">Estado</span><strong>${fmt.escape(fmt.label(run.status))}</strong></div><div class="qa-box"><span class="muted">Comprobaciones</span><strong>${run.total_scenarios}</strong></div><div class="qa-box"><span class="muted">Correctas</span><strong class="success">${run.passed_scenarios}</strong></div><div class="qa-box"><span class="muted">Fallidas</span><strong class="danger">${run.failed_scenarios}</strong></div></div><div class="section-gap-small"></div><div class="table-wrap mobile-card-table qa-robot-detail-table"><table><thead><tr><th>Capa</th><th>Prueba</th><th>Módulo</th><th>Estado</th><th>Tiempo</th><th>Detalle</th></tr></thead><tbody>${robotCheckRows(checks)}</tbody></table></div>${certificateBlock}${deepBlock}`});return;
  }
  const data=await api.qaDetail(id);modal({title:`Detalle de prueba ${id.slice(0,8)}`,size:"xwide",confirmLabel:"",body:`<div class="qa-summary"><div class="qa-box"><span class="muted">Tipo</span><strong>${fmt.escape(fmt.suite(data.run.run_type||"MATRIX"))}</strong></div><div class="qa-box"><span class="muted">Total</span><strong>${data.run.total_scenarios}</strong></div><div class="qa-box"><span class="muted">Aprobados</span><strong class="success">${data.run.passed_scenarios}</strong></div><div class="qa-box"><span class="muted">Fallidos</span><strong class="danger">${data.run.failed_scenarios}</strong></div></div><div class="section-gap-small"></div><div class="table-wrap mobile-card-table"><table><thead><tr><th>Escenario</th><th>Estado</th><th>Etapa / acción</th><th>Ruta esperada</th><th>Ruta obtenida</th><th>Error original</th></tr></thead><tbody>${data.scenarios.map(s=>`<tr><td data-label="Escenario">${fmt.escape(fmt.label(s.scenario_key))}</td><td data-label="Estado">${statusBadge(s.status)}</td><td data-label="Etapa / acción"><strong>${fmt.escape(fmt.step(s.failure_step_code||""))}</strong><small>${fmt.escape(s.failure_action||"")}${s.error_sqlstate?` · ${fmt.escape(s.error_sqlstate)}`:""}</small></td><td data-label="Ruta esperada">${fmt.escape(fmt.data(s.expected_path))}</td><td data-label="Ruta obtenida">${fmt.escape(fmt.data(s.actual_path))}</td><td data-label="Error" class="danger">${fmt.escape(s.error_message||"")}</td></tr>`).join("")}</tbody></table></div>`});
}

async function checkQueues(){
  try{const result=await api.queueIntegrity(false);modal({title:"Integridad de colas",confirmLabel:result.ok?"":"Reparar colas",cancelLabel:result.ok?"Cerrar":"Cancelar",body:`<div class="qa-summary"><div class="qa-box"><span class="muted">Pedidos activos</span><strong>${result.activeOrders}</strong></div><div class="qa-box"><span class="muted">Sin tarea activa</span><strong class="${result.missingTaskCount?"danger":"success"}">${result.missingTaskCount}</strong></div><div class="qa-box"><span class="muted">Etapa desalineada</span><strong class="${result.mismatchCount?"danger":"success"}">${result.mismatchCount}</strong></div><div class="qa-box"><span class="muted">Estado</span><strong>${result.ok?"Correcto":"Requiere revisión"}</strong></div></div>${result.issues?.length?`<div class="section-gap-small"></div><div class="table-wrap mobile-card-table"><table><thead><tr><th>Pedido</th><th>Problema</th><th>Etapa pedido</th><th>Etapa tarea</th></tr></thead><tbody>${result.issues.map(i=>`<tr><td data-label="Pedido">${fmt.escape(i.orderNumber)}</td><td data-label="Problema" class="danger">${fmt.escape(i.issue)}</td><td data-label="Etapa pedido">${fmt.escape(fmt.step(i.orderStep))}</td><td data-label="Etapa tarea">${fmt.escape(fmt.step(i.taskStep||""))}</td></tr>`).join("")}</tbody></table></div>`:`<div class="empty"><strong>Colas íntegras</strong><div>Todos los pedidos activos tienen una tarea coherente.</div></div>`}`,onConfirm:result.ok?undefined:async()=>{const repaired=await api.queueIntegrity(true);toast(`Reparación terminada: ${repaired.repaired} ajuste(s).`,repaired.ok?"success":"warning",8000)}})}catch(error){toast(error.message,"error",9000)}
}
