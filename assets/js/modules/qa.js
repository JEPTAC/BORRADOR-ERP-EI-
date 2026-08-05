import {api} from "../services/api.js";
import {fmt,statusBadge} from "../core/format.js";
import {loading,toast,modal,empty} from "../core/ui.js";

export async function renderQa(root){
  root.innerHTML=`<section class="page-head"><div><h2>Centro de pruebas automatizadas</h2><p>Valida rutas comerciales, controles transaccionales, concurrencia, inventario y continuidad operativa.</p></div><div class="page-actions"><button class="btn btn-primary" id="run-all-qa">▶ Ejecutar validación integral</button><button class="btn btn-ghost" id="run-matrix">Matriz 192</button><button class="btn btn-ghost" id="run-controls">Controles 10</button></div></section>
  <section class="grid grid-3"><article class="card card-pad"><div class="kpi-label">Matriz comercial</div><div class="kpi-value">192</div><div class="kpi-foot">4 tipos × 3 pagos × 4 rutas × corte × compra</div></article><article class="card card-pad"><div class="kpi-label">Controles transversales</div><div class="kpi-value">10</div><div class="kpi-foot">Concurrencia, puertas, entrega, histórico e inventario</div></article><article class="card card-pad"><div class="kpi-label">Motor probado</div><div class="kpi-value">1</div><div class="kpi-foot">Las pruebas utilizan el mismo motor transaccional del ERP</div></article></section><div style="height:16px"></div><section class="card"><header class="card-head"><h3>Historial de ejecuciones</h3></header><div class="card-body" id="qa-runs">${loading()}</div></section>`;
  root.querySelector("#run-matrix").onclick=()=>runSuite(root,"matrix");
  root.querySelector("#run-controls").onclick=()=>runSuite(root,"controls");
  root.querySelector("#run-all-qa").onclick=()=>runSuite(root,"all");
  await load(root);
}
async function load(root){
  const runs=await api.qaRuns(50),target=root.querySelector("#qa-runs");
  target.innerHTML=runs.length?`<div class="table-wrap"><table style="min-width:900px"><thead><tr><th>Inicio</th><th>Suite</th><th>Estado</th><th>Total</th><th>Aprobados</th><th>Fallidos</th><th>Duración</th><th>Detalle</th></tr></thead><tbody>${runs.map(r=>`<tr><td>${fmt.date(r.startedAt)}</td><td><span class="badge badge-blue">${fmt.escape(r.runType||"MATRIX")}</span></td><td>${statusBadge(r.status)}</td><td>${r.totalScenarios}</td><td class="success">${r.passedScenarios}</td><td class="danger">${r.failedScenarios}</td><td>${r.completedAt?fmt.number((new Date(r.completedAt)-new Date(r.startedAt))/1000,1)+" s":"En ejecución"}</td><td><button class="btn btn-ghost" data-run="${r.id}">Abrir</button></td></tr>`).join("")}</tbody></table></div>`:empty("Sin ejecuciones","Ejecute la validación integral antes de habilitar producción.");
  target.querySelectorAll("[data-run]").forEach(b=>b.onclick=()=>detail(b.dataset.run));
}
async function runSuite(root,type){
  const buttons=[...root.querySelectorAll("#run-all-qa,#run-matrix,#run-controls")];buttons.forEach(b=>b.disabled=true);
  const main=root.querySelector("#run-all-qa"),original=main.textContent;
  try{
    if(type==="matrix"){
      main.textContent="Ejecutando matriz de 192…";const r=await api.runQa(true);notify(r,"Matriz comercial");
    }else if(type==="controls"){
      main.textContent="Ejecutando 10 controles…";const r=await api.runQaControls(true);notify(r,"Controles empresariales");
    }else{
      main.textContent="Fase 1/2 · matriz de 192…";const matrix=await api.runQa(true);notify(matrix,"Matriz comercial");
      if(matrix.failed)throw new Error(`La matriz comercial terminó con ${matrix.failed} fallos. No se ejecutó la segunda fase.`);
      main.textContent="Fase 2/2 · controles empresariales…";const controls=await api.runQaControls(true);notify(controls,"Controles empresariales");
      if(!controls.failed)toast("Validación integral aprobada: 202 escenarios y controles sin fallos.","success",9000);
    }
    await load(root);
  }catch(error){toast(error.message||String(error),"error",9000);throw error}
  finally{buttons.forEach(b=>b.disabled=false);main.textContent=original}
}
function notify(result,label){toast(result.failed?`${label}: ${result.failed} fallos.`:`${label}: ${result.passed}/${result.total} aprobados.`,result.failed?"error":"success",7000)}
async function detail(id){
  const d=await api.qaDetail(id);
  modal({title:`Ejecución QA ${id.slice(0,8)}`,confirmLabel:"",body:`<div class="qa-summary"><div class="qa-box"><span class="muted">Suite</span><strong style="font-size:15px">${fmt.escape(d.run.run_type||"MATRIX")}</strong></div><div class="qa-box"><span class="muted">Total</span><strong>${d.run.total_scenarios}</strong></div><div class="qa-box"><span class="muted">Aprobados</span><strong class="success">${d.run.passed_scenarios}</strong></div><div class="qa-box"><span class="muted">Fallidos</span><strong class="danger">${d.run.failed_scenarios}</strong></div></div><div style="height:14px"></div><div class="table-wrap"><table><thead><tr><th>Escenario</th><th>Estado</th><th>Resultado esperado</th><th>Resultado real</th><th>Error</th></tr></thead><tbody>${d.scenarios.map(s=>`<tr><td>${fmt.escape(s.scenario_key)}</td><td>${statusBadge(s.status)}</td><td><code>${fmt.escape(JSON.stringify(s.expected_path))}</code></td><td><code>${fmt.escape(JSON.stringify(s.actual_path))}</code></td><td class="danger">${fmt.escape(s.error_message||"")}</td></tr>`).join("")}</tbody></table></div>`});
}
