import {api} from "../services/api.js";
import {fmt,statusBadge} from "../core/format.js";
import {loading,toast,modal,empty,wizard,actionCards,guide} from "../core/ui.js";
import {workspaceIntro,summaryItem} from "../core/guided.js";

export async function renderQa(root){
  root.innerHTML=`
    <section class="page-head"><div><h2>Pruebas automáticas del ERP</h2><p>Valida rutas, controles, inventario y continuidad antes de habilitar cambios.</p></div><div class="page-actions"><button class="btn btn-ghost" id="qa-help">¿Qué prueban?</button></div></section>
    ${workspaceIntro({title:"Selecciona la validación",description:"Cada opción explicará su alcance antes de iniciar. Las pruebas usan el mismo motor transaccional del ERP.",cards:actionCards([{id:"run-all-qa",title:"Validación integral",description:"Ejecuta 336 rutas comerciales, 10 controles y 2 gates de integridad.",icon:"▶",tone:"accent"},{id:"run-matrix",title:"336 combinaciones",description:"Prueba tipos de pedido, pago, mora, retención de Caja, rutas, corte y compra.",icon:"336",tone:"primary"},{id:"run-controls",title:"10 controles empresariales",description:"Prueba concurrencia, puertas, entrega, historial, recepción acumulada y corte.",icon:"10",tone:"success"},{id:"check-queues",title:"Verificar integridad de colas",description:"Busca pedidos sin tarea, desalineados o invisibles por asignación.",icon:"✓",tone:"primary"}])})}
    <section class="card"><header class="card-head"><h3>Historial de pruebas</h3></header><div class="card-body" id="qa-runs">${loading()}</div></section>`;
  root.querySelector("#run-matrix").onclick=()=>confirmRun(root,"matrix");
  root.querySelector("#run-controls").onclick=()=>confirmRun(root,"controls");
  root.querySelector("#run-all-qa").onclick=()=>confirmRun(root,"all");
  root.querySelector("#check-queues").onclick=()=>checkQueues(root);
  root.querySelector("#qa-help").onclick=()=>guide({title:"Cobertura del bot QA",description:"Las pruebas verifican el flujo completo antes del lanzamiento.",items:[{title:"336 rutas comerciales",detail:"Combina tipo, pago, mora/retención de Caja, entrega, corte y compra."},{title:"10 controles empresariales",detail:"Comprueba idempotencia, versiones, sesiones, esperas, puertas, entrega, recepción acumulada y motor de corte."},{title:"2 gates de integridad",detail:"Añade autodiagnóstico estructural e integridad cruzada de los flujos reales."},{title:"Limpieza automática",detail:"Los registros de prueba se eliminan al terminar cuando corresponde."}]});
  await load(root);
}
async function load(root){const target=root.querySelector("#qa-runs");try{const runs=await api.qaRuns(50);target.innerHTML=runs.length?`<div class="qa-run-grid">${runs.map(run=>`<article class="qa-run-card"><header><div><strong>${fmt.escape(fmt.suite(run.runType||"MATRIX"))}</strong><span>${fmt.date(run.startedAt)}</span></div>${statusBadge(run.status)}</header><div class="qa-run-metrics"><div><label>Total</label><strong>${run.totalScenarios}</strong></div><div><label>Aprobados</label><strong class="success">${run.passedScenarios}</strong></div><div><label>Fallidos</label><strong class="danger">${run.failedScenarios}</strong></div><div><label>Duración</label><strong>${run.completedAt?fmt.number((new Date(run.completedAt)-new Date(run.startedAt))/1000,1)+" s":"En ejecución"}</strong></div></div><footer><button class="btn btn-primary" data-run="${run.id}">Abrir detalle</button></footer></article>`).join("")}</div>`:empty("Sin pruebas ejecutadas","Ejecuta la validación integral antes de habilitar la operación.");target.querySelectorAll("[data-run]").forEach(button=>button.onclick=()=>detail(button.dataset.run))}catch(error){target.innerHTML=`<div class="module-error"><strong>No fue posible cargar el historial de pruebas</strong><p>${fmt.escape(error.message)}</p><button class="btn btn-primary" id="retry-qa">Reintentar</button></div>`;target.querySelector("#retry-qa")?.addEventListener("click",()=>load(root));toast(error.message,"error",9000)}}
function confirmRun(root,type){
  const config={
    matrix:{title:"Probar 336 combinaciones",total:"336",detail:"Se recorrerán las combinaciones comerciales vigentes, incluida mora y retención de Caja."},
    controls:{title:"Probar 10 controles",total:"10",detail:"Se verificarán los controles transversales empresariales sobre la arquitectura V10.22."},
    all:{title:"Ejecutar validación integral",total:"336 + 10 + 2 gates",detail:"Ejecuta matriz, controles, autodiagnóstico estructural e integridad cruzada de datos."}
  }[type];
  wizard({title:config.title,subtitle:"Confirma el alcance antes de iniciar la prueba.",finishLabel:"Iniciar pruebas",steps:[
    {title:"Alcance",description:"La ejecución puede tardar mientras recorre los escenarios.",content:`<div class="wizard-summary">${summaryItem("Pruebas",config.total)}${summaryItem("Limpieza","Automática")}${summaryItem("Motor","Operación real")}${summaryItem("Resultado","Historial de QA")}</div><div class="wizard-confirm-box"><strong>${fmt.escape(config.title)}</strong><p>${fmt.escape(config.detail)}</p></div>`},
    {title:"Confirmar",description:"No cierres la pestaña durante la ejecución.",content:`<div class="wizard-tip">Al terminar, revisa cualquier escenario fallido antes de permitir el uso productivo.</div>`}
  ],onFinish:async()=>runSuite(root,type)});
}
async function runSuite(root,type){
  const buttons=[...root.querySelectorAll("#run-all-qa,#run-matrix,#run-controls")];
  buttons.forEach(button=>button.disabled=true);
  try{
    if(type==="matrix"){
      const result=await api.runQa(true);notify(result,"Combinaciones comerciales");
    }else if(type==="controls"){
      const result=await api.runQaControls(true);notify(result,"Controles empresariales");
    }else{
      const result=await api.runQaV1022(true);
      const matrix=result.matrix||{},controls=result.controls||{},self=result.selfCheck||{},flow=result.flowIntegrity||{};
      if(!result.success){
        const failed=[];
        if(matrix.status!=="PASSED")failed.push(`matriz: ${matrix.failed??"?"} fallo(s)`);
        if(controls.status!=="PASSED")failed.push(`controles: ${controls.failed??"?"} fallo(s)`);
        if(!self.success)failed.push("autodiagnóstico estructural");
        if(!flow.success)failed.push("integridad cruzada de flujos");
        throw new Error(`La validación integral requiere revisión: ${failed.join(" · ")||"diagnóstico incompleto"}.`);
      }
      toast(`Validación V10.22 aprobada: ${matrix.passed}/${matrix.total} rutas, ${controls.passed}/${controls.total} controles y 2 gates de integridad.`,"success",10000);
    }
    await load(root);
  }catch(error){toast(error.message||String(error),"error",9000);throw error}
  finally{buttons.forEach(button=>button.disabled=false)}
}
function notify(result,label){toast(result.failed?`${label}: ${result.failed} fallos.`:`${label}: ${result.passed}/${result.total} aprobados.`,result.failed?"error":"success",7000)}
async function detail(id){const data=await api.qaDetail(id);modal({title:`Detalle de prueba ${id.slice(0,8)}`,confirmLabel:"",body:`<div class="qa-summary"><div class="qa-box"><span class="muted">Tipo</span><strong class="qa-type">${fmt.escape(fmt.suite(data.run.run_type||"MATRIX"))}</strong></div><div class="qa-box"><span class="muted">Total</span><strong>${data.run.total_scenarios}</strong></div><div class="qa-box"><span class="muted">Aprobados</span><strong class="success">${data.run.passed_scenarios}</strong></div><div class="qa-box"><span class="muted">Fallidos</span><strong class="danger">${data.run.failed_scenarios}</strong></div></div><div class="section-gap-small"></div><div class="table-wrap mobile-card-table"><table><thead><tr><th>Escenario</th><th>Estado</th><th>Ruta esperada</th><th>Ruta obtenida</th><th>Error</th></tr></thead><tbody>${data.scenarios.map(scenario=>`<tr><td data-label="Escenario">${fmt.escape(fmt.label(scenario.scenario_key))}</td><td data-label="Estado">${statusBadge(scenario.status)}</td><td data-label="Ruta esperada">${fmt.escape(fmt.data(scenario.expected_path))}</td><td data-label="Ruta obtenida">${fmt.escape(fmt.data(scenario.actual_path))}</td><td data-label="Error" class="danger">${fmt.escape(scenario.error_message||"")}</td></tr>`).join("")}</tbody></table></div>`})}

async function checkQueues(root){try{const result=await api.queueIntegrity(false);modal({title:"Integridad de colas",confirmLabel:result.ok?"":"Reparar colas",cancelLabel:result.ok?"Cerrar":"Cancelar",body:`<div class="qa-summary"><div class="qa-box"><span class="muted">Pedidos activos</span><strong>${result.activeOrders}</strong></div><div class="qa-box"><span class="muted">Sin tarea activa</span><strong class="${result.missingTaskCount?"danger":"success"}">${result.missingTaskCount}</strong></div><div class="qa-box"><span class="muted">Etapa desalineada</span><strong class="${result.mismatchCount?"danger":"success"}">${result.mismatchCount}</strong></div><div class="qa-box"><span class="muted">Estado</span><strong>${result.ok?"Correcto":"Requiere revisión"}</strong></div></div>${result.issues?.length?`<div class="section-gap-small"></div><div class="table-wrap mobile-card-table"><table><thead><tr><th>Pedido</th><th>Problema</th><th>Etapa del pedido</th><th>Etapa de tarea</th></tr></thead><tbody>${result.issues.map(item=>`<tr><td data-label="Pedido">${fmt.escape(item.orderNumber)}</td><td data-label="Problema" class="danger">${fmt.escape(item.issue)}</td><td data-label="Etapa del pedido">${fmt.escape(fmt.step(item.orderStep))}</td><td data-label="Etapa de tarea">${fmt.escape(fmt.step(item.taskStep||""))}</td></tr>`).join("")}</tbody></table></div><div class="wizard-tip">La reparación recreará tareas faltantes y alineará etapa, estado y responsable con la tarea activa. No elimina pedidos.</div>`:`<div class="empty"><strong>Colas íntegras</strong><div>Todos los pedidos activos tienen una tarea coherente con su etapa.</div></div>`}`,onConfirm:result.ok?undefined:async()=>{const repaired=await api.queueIntegrity(true);toast(`Reparación terminada: ${repaired.repaired} ajuste(s).`,repaired.ok?"success":"warning",8000);await load(root)}})}catch(error){toast(error.message,"error",9000)}}
