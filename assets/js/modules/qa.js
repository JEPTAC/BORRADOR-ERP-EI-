import {api} from "../services/api.js";
import {fmt,statusBadge} from "../core/format.js";
import {loading,toast,modal,empty,wizard,guide} from "../core/ui.js";
import {summaryItem} from "../core/guided.js";
import {hasRole} from "../core/state.js";
import {runTotalQaRobot,robotCheckRows} from "./qa-total.js";

export async function renderQa(root){
  if(!hasRole("super_admin")){
    root.innerHTML=`<section class="card card-pad"><h3>Acceso restringido</h3><p>El Robot QA total es exclusivo de Superadministración.</p></section>`;
    return;
  }
  root.innerHTML=`
    <section class="qa-total-page">
      <header class="qa-total-hero card">
        <div class="qa-total-hero-copy">
          <span class="qa-total-eyebrow">SUPER ADMIN · CONTROL DE LIBERACIÓN</span>
          <h2>Robot QA total del sistema</h2>
          <p>Recorre rutas de pedidos, integridad de datos, módulos, botones seguros, colas Sandbox y responsive. Los pedidos que crea son <strong>TEST-QA</strong> aislados de producción y se eliminan al terminar.</p>
          <div class="qa-total-hero-actions">
            <button class="btn btn-primary btn-large" id="run-total-robot">▶ Ejecutar prueba total</button>
            <button class="btn btn-ghost" id="qa-help">Ver cobertura</button>
          </div>
        </div>
        <div class="qa-total-seal"><span>QA</span><strong>10.25</strong><small>Robot integral</small></div>
      </header>

      <section class="qa-total-grid">
        <article class="qa-total-console card" id="qa-total-console">
          <div class="qa-total-console-head">
            <div><span class="qa-total-eyebrow">EJECUCIÓN ACTUAL</span><h3 id="qa-total-phase">Listo para probar</h3><p id="qa-total-detail">Ninguna prueba total está ejecutándose.</p></div>
            <strong id="qa-total-counts">—</strong>
          </div>
          <div class="qa-total-progress"><span id="qa-total-progress-bar"></span></div>
          <div class="qa-total-log" id="qa-total-log"><div class="qa-total-log-empty">Los eventos del Robot aparecerán aquí.</div></div>
        </article>
        <aside class="qa-total-scope card">
          <span class="qa-total-eyebrow">COBERTURA</span>
          <div class="qa-scope-item"><strong>336</strong><div><b>Rutas comerciales</b><span>Tipos, pagos, mora/Caja, entrega, corte y compra.</span></div></div>
          <div class="qa-scope-item"><strong>10</strong><div><b>Controles empresariales</b><span>Concurrencia, gates, parciales, entrega y Corte.</span></div></div>
          <div class="qa-scope-item"><strong>10</strong><div><b>Ramas críticas</b><span>Aprobación/rechazo, cambio de ruta, reapertura, excepciones y cancelación.</span></div></div>
          <div class="qa-scope-item"><strong>100%</strong><div><b>Módulos Super Admin</b><span>Navegación automática y controles no destructivos.</span></div></div>
          <div class="qa-scope-item"><strong>6</strong><div><b>Viewports</b><span>360, 390, 424, 768, 960 y 1440 px.</span></div></div>
          <div class="qa-scope-item"><strong>TEST</strong><div><b>Operación real aislada</b><span>Una orden sintética por cada etapa operativa.</span></div></div>
        </aside>
      </section>

      <section class="qa-robot-stage card" id="qa-robot-stage" hidden></section>

      <section class="qa-manual card">
        <div class="qa-manual-head"><div><span class="qa-total-eyebrow">PRUEBAS DIRIGIDAS</span><h3>Ejecutar solo una capa</h3><p>Úsalas cuando quieras validar una corrección específica sin recorrer toda la aplicación.</p></div><button class="btn btn-ghost" id="check-queues">Verificar colas</button></div>
        <div class="qa-manual-actions">
          <button class="qa-mini-action" id="run-matrix"><strong>336 combinaciones</strong><span>Solo enrutamiento comercial</span></button>
          <button class="qa-mini-action" id="run-controls"><strong>10 controles</strong><span>Solo reglas empresariales</span></button>
          <button class="qa-mini-action" id="run-integral"><strong>Backend integral</strong><span>Matriz + controles + 2 gates</span></button>
        </div>
      </section>

      <section class="card"><header class="card-head"><div><span class="qa-total-eyebrow">HISTORIAL</span><h3>Ejecuciones QA</h3></div><button class="btn btn-ghost" id="refresh-qa">Actualizar</button></header><div class="card-body" id="qa-runs">${loading()}</div></section>
    </section>`;

  root.querySelector("#run-total-robot").onclick=()=>confirmTotal(root);
  root.querySelector("#run-matrix").onclick=()=>confirmRun(root,"matrix");
  root.querySelector("#run-controls").onclick=()=>confirmRun(root,"controls");
  root.querySelector("#run-integral").onclick=()=>confirmRun(root,"all");
  root.querySelector("#check-queues").onclick=()=>checkQueues(root);
  root.querySelector("#refresh-qa").onclick=()=>load(root);
  root.querySelector("#qa-help").onclick=()=>guide({title:"Cobertura del Robot QA total",description:"Combina pruebas de dominio con uso automático de la aplicación real.",items:[
    {title:"Dominio exhaustivo",detail:"Ejecuta las 336 combinaciones finitas de extremo a extremo, 10 controles empresariales y 10 ramas críticas adicionales."},
    {title:"Integridad y contratos",detail:"Verifica health check, Workforce, colas, aislamiento Sandbox, roles y motores críticos."},
    {title:"Recorrido de interfaz",detail:"Abre todos los módulos visibles para Super Admin, acciona controles seguros y captura errores JS/RPC."},
    {title:"Sandbox por etapa",detail:"Crea pedidos TEST-QA en cada etapa y confirma que la cola y su acción de apertura funcionan."},
    {title:"Responsive",detail:"Vuelve a recorrer módulos críticos en seis anchos de viewport y busca overflow o diálogos fuera de pantalla."},
    {title:"Playwright externo",detail:"El repositorio incluye además E2E de navegador real para login, navegación, Sandbox, consola, capturas, video y trazas en CI."}
  ]});
  root.addEventListener("erp:qa-total-finished",()=>load(root));
  await load(root);
}

function confirmTotal(root){
  wizard({title:"Ejecutar Robot QA total",subtitle:"Prueba profunda exclusiva de Super Admin.",finishLabel:"Iniciar recorrido total",steps:[
    {title:"Aislamiento",description:"La prueba puede crear y mover datos TEST, nunca pedidos productivos.",content:`<div class="wizard-summary">${summaryItem("Pedidos creados","TEST-QA")}${summaryItem("Producción","No se modifica")}${summaryItem("Limpieza","Automática")}${summaryItem("Usuario","Super Admin")}</div><div class="wizard-confirm-box"><strong>La prueba navega realmente la aplicación</strong><p>Se recomienda mantener esta pestaña abierta hasta que finalice. El visor E2E se ejecutará dentro del mismo navegador.</p></div>`},
    {title:"Cobertura",description:"Dominio + UI + Sandbox + responsive.",content:`<div class="wizard-tip">Para la certificación más fuerte también puedes ejecutar después <b>npm run test:total</b> o el workflow de GitHub Actions incluido en V10.25; ese segundo robot abre un navegador independiente y genera trazas.</div>`},
    {title:"Confirmar",description:"Puede tardar varios minutos según conexión y cantidad de módulos.",content:`<div class="wizard-confirm-box"><strong>No uses esta pestaña mientras el robot está trabajando.</strong><p>Si encuentra un fallo, continuará con las demás pruebas para entregar un diagnóstico completo.</p></div>`}
  ],onFinish:async()=>{
    const btn=root.querySelector("#run-total-robot");btn.disabled=true;btn.textContent="Robot ejecutándose…";
    try{const result=await runTotalQaRobot(root);toast(result.result?.status==="PASSED"?"Robot QA total aprobado.":"Robot QA terminó con fallos. Revisa el detalle.",result.result?.status==="PASSED"?"success":"error",10000)}
    catch(error){toast(error.message||String(error),"error",10000)}
    finally{btn.disabled=false;btn.textContent="▶ Ejecutar prueba total"}
  }});
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
  const config={matrix:{title:"Probar 336 combinaciones",total:"336",detail:"Recorre tipos de pedido, pago, mora/retención, entrega, Corte y compra."},controls:{title:"Probar 10 controles",total:"10",detail:"Verifica reglas transversales empresariales."},all:{title:"Validar backend integral",total:"336 + 10 + 2 gates",detail:"Matriz, controles, autodiagnóstico e integridad cruzada."}}[type];
  wizard({title:config.title,subtitle:"Prueba dirigida del motor ERP.",finishLabel:"Iniciar",steps:[{title:"Alcance",description:config.detail,content:`<div class="wizard-summary">${summaryItem("Pruebas",config.total)}${summaryItem("Limpieza","Automática")}${summaryItem("Entorno","Motor real")}${summaryItem("Producción","Protegida")}</div>`},{title:"Confirmar",description:"Revisa el resultado antes de liberar cambios.",content:`<div class="wizard-tip">Esta prueba no reemplaza el Robot QA total de interfaz.</div>`}],onFinish:async()=>runSuite(root,type)});
}
async function runSuite(root,type){
  const buttons=[...root.querySelectorAll("#run-integral,#run-matrix,#run-controls")];buttons.forEach(b=>b.disabled=true);
  try{
    if(type==="matrix"){const r=await api.runQa(true);notify(r,"Combinaciones comerciales")}
    else if(type==="controls"){const r=await api.runQaControls(true);notify(r,"Controles empresariales")}
    else{const r=await api.runQaV1022(true);if(!r.success)throw new Error("La validación integral de backend encontró fallos.");toast(`Backend aprobado: ${r.matrix?.passed}/${r.matrix?.total} rutas, ${r.controls?.passed}/${r.controls?.total} controles y 2 gates.`,"success",9000)}
    await load(root);
  }catch(error){toast(error.message||String(error),"error",9000)}finally{buttons.forEach(b=>b.disabled=false)}
}
function notify(result,label){toast(result.failed?`${label}: ${result.failed} fallo(s).`:`${label}: ${result.passed}/${result.total} aprobadas.`,result.failed?"error":"success",7000)}

async function detail(id,type){
  if(type==="TOTAL_ROBOT"){
    const data=await api.qaRobotDetail(id),run=data.run||{},checks=data.checks||[];
    modal({title:`Robot QA ${id.slice(0,8)}`,size:"xwide",confirmLabel:"",body:`<div class="qa-summary"><div class="qa-box"><span class="muted">Estado</span><strong>${fmt.escape(fmt.label(run.status))}</strong></div><div class="qa-box"><span class="muted">Comprobaciones</span><strong>${run.total_scenarios}</strong></div><div class="qa-box"><span class="muted">Correctas</span><strong class="success">${run.passed_scenarios}</strong></div><div class="qa-box"><span class="muted">Fallidas</span><strong class="danger">${run.failed_scenarios}</strong></div></div><div class="section-gap-small"></div><div class="table-wrap mobile-card-table qa-robot-detail-table"><table><thead><tr><th>Capa</th><th>Prueba</th><th>Módulo</th><th>Estado</th><th>Tiempo</th><th>Detalle</th></tr></thead><tbody>${robotCheckRows(checks)}</tbody></table></div>`});return;
  }
  const data=await api.qaDetail(id);modal({title:`Detalle de prueba ${id.slice(0,8)}`,size:"xwide",confirmLabel:"",body:`<div class="qa-summary"><div class="qa-box"><span class="muted">Tipo</span><strong>${fmt.escape(fmt.suite(data.run.run_type||"MATRIX"))}</strong></div><div class="qa-box"><span class="muted">Total</span><strong>${data.run.total_scenarios}</strong></div><div class="qa-box"><span class="muted">Aprobados</span><strong class="success">${data.run.passed_scenarios}</strong></div><div class="qa-box"><span class="muted">Fallidos</span><strong class="danger">${data.run.failed_scenarios}</strong></div></div><div class="section-gap-small"></div><div class="table-wrap mobile-card-table"><table><thead><tr><th>Escenario</th><th>Estado</th><th>Ruta esperada</th><th>Ruta obtenida</th><th>Error</th></tr></thead><tbody>${data.scenarios.map(s=>`<tr><td data-label="Escenario">${fmt.escape(fmt.label(s.scenario_key))}</td><td data-label="Estado">${statusBadge(s.status)}</td><td data-label="Ruta esperada">${fmt.escape(fmt.data(s.expected_path))}</td><td data-label="Ruta obtenida">${fmt.escape(fmt.data(s.actual_path))}</td><td data-label="Error" class="danger">${fmt.escape(s.error_message||"")}</td></tr>`).join("")}</tbody></table></div>`});
}

async function checkQueues(){
  try{const result=await api.queueIntegrity(false);modal({title:"Integridad de colas",confirmLabel:result.ok?"":"Reparar colas",cancelLabel:result.ok?"Cerrar":"Cancelar",body:`<div class="qa-summary"><div class="qa-box"><span class="muted">Pedidos activos</span><strong>${result.activeOrders}</strong></div><div class="qa-box"><span class="muted">Sin tarea activa</span><strong class="${result.missingTaskCount?"danger":"success"}">${result.missingTaskCount}</strong></div><div class="qa-box"><span class="muted">Etapa desalineada</span><strong class="${result.mismatchCount?"danger":"success"}">${result.mismatchCount}</strong></div><div class="qa-box"><span class="muted">Estado</span><strong>${result.ok?"Correcto":"Requiere revisión"}</strong></div></div>${result.issues?.length?`<div class="section-gap-small"></div><div class="table-wrap mobile-card-table"><table><thead><tr><th>Pedido</th><th>Problema</th><th>Etapa pedido</th><th>Etapa tarea</th></tr></thead><tbody>${result.issues.map(i=>`<tr><td data-label="Pedido">${fmt.escape(i.orderNumber)}</td><td data-label="Problema" class="danger">${fmt.escape(i.issue)}</td><td data-label="Etapa pedido">${fmt.escape(fmt.step(i.orderStep))}</td><td data-label="Etapa tarea">${fmt.escape(fmt.step(i.taskStep||""))}</td></tr>`).join("")}</tbody></table></div>`:`<div class="empty"><strong>Colas íntegras</strong><div>Todos los pedidos activos tienen una tarea coherente.</div></div>`}`,onConfirm:result.ok?undefined:async()=>{const repaired=await api.queueIntegrity(true);toast(`Reparación terminada: ${repaired.repaired} ajuste(s).`,repaired.ok?"success":"warning",8000)}})}catch(error){toast(error.message,"error",9000)}
}
