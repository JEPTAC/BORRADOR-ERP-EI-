import {api} from "../services/api.js";
import {fmt} from "../core/format.js";
import {modal,toast} from "../core/ui.js";

const sleep=ms=>new Promise(r=>setTimeout(r,ms));
const MAX_SLICE_STEPS=20;

function setUi(root,{phase,detail,counts,progress}={}){
  const $=s=>root?.querySelector?.(s);
  if(phase&&$("#qa-total-phase"))$("#qa-total-phase").textContent=phase;
  if(detail&&$("#qa-total-detail"))$("#qa-total-detail").textContent=detail;
  if(counts&&$("#qa-total-counts"))$("#qa-total-counts").textContent=counts;
  if(Number.isFinite(progress)&&$("#qa-total-progress-bar"))$("#qa-total-progress-bar").style.width=`${Math.max(2,Math.min(100,progress))}%`;
}
function log(root,message,tone=""){
  const box=root?.querySelector?.("#qa-total-log");if(!box)return;
  box.querySelector(".qa-total-log-empty")?.remove();
  const row=document.createElement("div");row.className=`qa-total-log-row ${tone}`;
  row.innerHTML=`<span>${new Date().toLocaleTimeString("es-CO",{hour12:false})}</span><p>${fmt.escape(message)}</p>`;
  box.prepend(row);
}
function errText(e){return e?.technicalMessage||e?.message||String(e||"Error desconocido")}
function isTransient(e){return /statement timeout|canceling statement|timeout|gateway|status of 50[04]|failed to fetch|network|load failed|connection/i.test(errText(e))}
async function withRetry(fn){
  // V10.25.11: una sola solicitud. Los reintentos automáticos bajo 503/504
  // pueden agotar el pool y convertir una degradación puntual en una tormenta.
  return await fn();
}

async function refreshProgress(root,runId,{soft=true,attempts=3}={}){
  try{
    const p=await withRetry(()=>api.qaFlowProgress(runId),{attempts,baseDelay:700});
    const done=(p.passed||0)+(p.failed||0);
    setUi(root,{phase:"Certificando flujo real de pedidos",detail:`${done}/336 pedidos terminados · ${p.passed||0} cerrados correctamente · ${p.failed||0} con error · ${p.pending||0} pendientes`,counts:`${p.stepsAudited||0} etapas auditadas`,progress:5+(done/336)*90});
    root.dispatchEvent(new CustomEvent("erp:qa-flow-progress",{detail:p}));
    return p;
  }catch(e){
    if(!soft)throw e;
    log(root,`El contador no respondió todavía (${errText(e)}). La ejecución continúa.`,"warning");
    return null;
  }
}

async function runOneCase(root,item){
  let slices=0;
  for(;;){
    slices++;
    if(slices>MAX_SLICE_STEPS)throw new Error(`${item.caseKey}: excedió ${MAX_SLICE_STEPS} etapas sin terminar.`);
    let result=null;
    try{result=await api.qaFlowExecuteSlice(item.caseId)}
    catch(e){
      log(root,`${item.caseKey} · conexión interrumpida · ${errText(e)}`,"warning");
      throw e;
    }
    if(result?.status==="FAILED"){
      log(root,`× ${item.caseKey} · ${result.failedStep||"?"} · ${result.module||"?"} · ${result.expectedRole||"?"} · ${result.errorMessage||"Error"}`,"failed");
      return result;
    }
    if(result?.completed){log(root,`✓ ${item.caseKey} · CLOSED`,"passed");return result}
    log(root,`${item.caseKey} → ${result?.currentStep||"siguiente etapa"}`);
    await sleep(250);
  }
}

export async function runFlowCanary(root){
  const button=root.querySelector("#run-flow-canary");
  if(button)button.disabled=true;
  try{
    setUi(root,{phase:"Pedido canario",detail:"Validando usuarios antes de ejecutar un único flujo de extremo a extremo.",counts:"1 pedido",progress:4});
    const ready=await api.qaFlowUserReadiness();
    if(!ready?.success){
      const missing=(ready?.missingAuthenticatedRoles||[]).map(fmt.label);
      throw new Error(missing.length?`Faltan roles con usuario autenticado: ${missing.join(", ")}`:"Configuración QA incompleta.");
    }
    const created=await api.qaFlowCreateCanary();
    log(root,`Canario creado: ${created.caseKey||String(created.caseId).slice(0,8)}.`);
    setUi(root,{phase:"Ejecutando pedido canario",detail:"Debe recorrer Ventas → filtros → logística → facturación → entrega → Cierre → CLOSED.",counts:"0/1",progress:10});
    const result=await runOneCase(root,{caseId:created.caseId,caseKey:created.caseKey});
    const passed=result?.status==="PASSED"&&result?.completed;
    setUi(root,{phase:passed?"CANARIO PASSED":"CANARIO FAILED",detail:passed?"El pedido llegó a CLOSED. Ya puedes ejecutar la certificación de 336 rutas.":`${result?.failedStep||"Etapa desconocida"} · ${result?.errorMessage||"El flujo encontró un error."}`,counts:passed?"1/1 CLOSED":"0/1",progress:100});
    toast(passed?"Pedido canario cerrado correctamente. Ahora sí ejecuta los 336.":"El pedido canario encontró un fallo. Revisa sus etapas antes de ejecutar los 336.",passed?"success":"error",10000);
    await openFlowCase(created.caseId);
    return {...result,runId:created.runId,caseId:created.caseId};
  }catch(e){
    log(root,`Canario · ${errText(e)}`,"failed");
    setUi(root,{phase:"CANARIO FAILED",detail:errText(e),counts:"0/1",progress:100});
    toast(errText(e),"error",10000);
    throw e;
  }finally{if(button)button.disabled=false}
}

export async function runFlowCertification(root,{runId=null}={}){
  const button=root.querySelector("#run-flow-cert")||root.querySelector("#run-total-robot");
  const resume=root.querySelector("#resume-flow-cert")||root.querySelector("#resume-total-robot");
  if(button)button.disabled=true;if(resume)resume.disabled=true;
  try{
    let id=runId;
    if(!id){
      setUi(root,{phase:"Validando usuarios operativos",detail:"Comprobando que cada rol del flujo tenga usuarios activos vinculados a Authentication.",counts:"Preflight",progress:2});
      const ready=await withRetry(()=>api.qaFlowUserReadiness(),{attempts:4,baseDelay:800});
      if(!ready?.success){
        const missing=(ready?.missingAuthenticatedRoles||[]).map(fmt.label);
        const invalid=(ready?.activeProfilesWithoutAuth||[]).map(x=>`${x.name||x.email||x.profileId} (${fmt.label(x.role||"")})`);
        const detail=[missing.length?`Faltan roles con usuario autenticado: ${missing.join(", ")}`:"",invalid.length?`Perfiles activos sin Authentication: ${invalid.join(", ")}`:""].filter(Boolean).join(" · ");
        setUi(root,{phase:"Configuración QA incompleta",detail,counts:"No se inició la corrida",progress:2});
        throw new Error(detail||"Faltan usuarios operativos para certificar el flujo.");
      }
      setUi(root,{phase:"Construyendo 336 pedidos",detail:"Creando el inventario completo de combinaciones comerciales.",counts:"0/336",progress:3});
      const created=await withRetry(()=>api.qaFlowCreateRun(),{attempts:3,baseDelay:1000});id=created.runId;
      log(root,`Corrida de flujo creada: ${String(id).slice(0,8)} · 336 pedidos TEST-QA.`);
    }else log(root,`Reanudando certificación ${String(id).slice(0,8)}.`);

    const pending=await withRetry(()=>api.qaFlowPendingCases(id),{attempts:5,baseDelay:900});
    const queue=[...(pending.items||[])];
    log(root,`${queue.length} pedido(s) pendientes. Modo estable: 1 pedido a la vez; sin refrescos productivos entre slices.`);
    await refreshProgress(root,id,{soft:true,attempts:3});

    let completedSinceRefresh=0;
    const deferred=[];
    for(const item of queue){
      try{await runOneCase(root,item,{attempts:2})}
      catch(e){
        if(isTransient(e)){
          log(root,`■ QA detenido de forma segura: ${item.caseKey} recibió ${errText(e)}. No se enviarán más RPC hasta reanudar manualmente.`,"warning");
          setUi(root,{phase:"Supabase ocupado · QA detenido",detail:"El avance quedó guardado. No recargues repetidamente; espera a que la base se recupere y pulsa Reanudar una sola vez.",counts:"Sin nuevas solicitudes automáticas",progress:Math.min(96,5+((completedSinceRefresh||0)/336)*90)});
          toast("QA detenido para proteger la conexión. El avance quedó guardado.","warning",10000);
          return {runId:id,incomplete:true,transportPending:true,stoppedSafely:true,error:errText(e)};
        }
        deferred.push({item,error:e});
        log(root,`↻ ${item.caseKey} se pospone: ${errText(e)}.`,"warning");
      }
      completedSinceRefresh++;
      if(completedSinceRefresh>=8){completedSinceRefresh=0;await refreshProgress(root,id,{soft:true,attempts:2})}
      await sleep(180);
    }

    if(deferred.length){
      log(root,`Reintentando ${deferred.length} pedido(s) demorados uno por uno después de enfriar la conexión.`);
      setUi(root,{phase:"Reintentando pedidos demorados",detail:`${deferred.length} caso(s) pendientes de transporte/timeouts.`,counts:"Modo serial",progress:94});
      await sleep(2500);
      for(const {item} of deferred){
        try{await runOneCase(root,item,{attempts:3})}
        catch(e){log(root,`○ ${item.caseKey} sigue pendiente: ${errText(e)}. No se invalida como error funcional; queda reanudable.`,"warning")}
        await sleep(500);
      }
    }

    let progress=null;
    try{progress=await refreshProgress(root,id,{soft:false,attempts:5})}
    catch(e){
      log(root,`No fue posible leer el contador final: ${errText(e)}. La corrida conserva su avance y puede reanudarse.`,"warning");
      setUi(root,{phase:"Certificación reanudable",detail:"Supabase no respondió al contador final. Espera unos segundos y pulsa Reanudar; no se repetirán los casos cerrados.",counts:"Avance guardado",progress:96});
      toast("El avance quedó guardado; el contador final no respondió todavía.","warning",9000);
      return {runId:id,incomplete:true,transportPending:true};
    }

    if(progress.pending>0){
      setUi(root,{phase:"Certificación incompleta",detail:`Se recorrió toda la cola. Quedan ${progress.pending||0} pedido(s) pendientes por timeout/transporte; puedes reanudar sin repetir los terminados.`,counts:`${progress.passed||0} correctos · ${progress.failed||0} fallidos · ${progress.pending||0} pendientes`,progress:Math.min(96,5+((progress.executed||0)/336)*90)});
      toast("Se procesó toda la cola; solo quedan casos pendientes por reintento.","warning",9000);
      return {runId:id,progress,incomplete:true};
    }

    setUi(root,{phase:"Validando ramas especiales",detail:"Comprobando aprobaciones, cambio de ruta, reapertura, excepciones y cancelación.",progress:97});
    const final=await withRetry(()=>api.qaFlowFinish(id),{attempts:3,baseDelay:1200});
    setUi(root,{phase:final.launchable?"ERP LANZABLE":"ERP NO LANZABLE",detail:final.launchable?"336/336 pedidos cerraron por su ruta exacta con roles y módulos válidos.":`${final.failed||0} pedido(s) fallaron o una rama especial no cumplió.`,counts:`${final.passed||0}/336 correctos`,progress:100});
    log(root,final.launchable?"✓ CERTIFICACIÓN DE FLUJO APROBADA · ERP LANZABLE":"× CERTIFICACIÓN DE FLUJO FALLIDA · revisar hallazgos",final.launchable?"passed":"failed");
    root.dispatchEvent(new CustomEvent("erp:qa-flow-finished",{detail:{...final,runId:id}}));
    toast(final.launchable?"Flujo certificado: 336/336 pedidos correctos.":"El flujo encontró errores. Abre los hallazgos por módulo/usuario.",final.launchable?"success":"error",10000);
    return final;
  }finally{if(button)button.disabled=false;if(resume)resume.disabled=false}
}

export async function resumeLatestFlow(root){
  let latest;
  try{latest=await withRetry(()=>api.qaFlowLatestResumable(),{attempts:5,baseDelay:1000})}
  catch(e){toast(`Supabase sigue ocupado: ${errText(e)}. Espera 10–20 segundos y vuelve a pulsar Reanudar.`,"warning",9000);return null}
  if(!latest?.available){toast("No hay una certificación de flujo pendiente.","info",5000);return null}
  return runFlowCertification(root,{runId:latest.runId});
}

function path(v){return Array.isArray(v)?v.map(fmt.step).join(" → "):"—"}
function actionText(actions=[]){return (actions||[]).map(a=>`${a.action}${a.actor?` · ${a.actor}`:""}${a.role?` (${fmt.label(a.role)})`:""}`).join(" → ")}

export async function openFlowResults(runId=null){
  if(!runId){
    const latest=await api.qaFlowLatestResumable();
    if(latest?.available)runId=latest.runId;
  }
  if(!runId){toast("Ejecuta primero una certificación de flujo.","info",6000);return}
  try{
    const [matrix,summary]=await Promise.all([api.qaFlowMatrix(runId,"ALL"),api.qaFlowSummary(runId)]);
    const items=matrix.items||[],failures=summary.failures||[],cert=summary.run?.flowCertification||null;
    const passed=items.filter(x=>x.status==="PASSED").length,failed=items.filter(x=>x.status==="FAILED").length,pending=items.filter(x=>x.status==="PENDING").length;
    const rows=items.map((x,i)=>`<tr><td>${i+1}</td><td><strong>${fmt.escape(x.caseKey||"")}</strong><small>${fmt.escape(fmt.data(x.specification||{}))}</small></td><td><strong class="${x.status==="PASSED"?"success":x.status==="FAILED"?"danger":"warning"}">${fmt.escape(x.status||"")}</strong></td><td><small>${fmt.escape(path(x.expectedPath))}</small></td><td><small>${fmt.escape(path(x.actualPath))}</small></td><td>${x.errorMessage?`<span class="danger">${fmt.escape(x.errorMessage)}</span>`:`<button class="btn btn-ghost btn-small" data-flow-detail="${x.caseId}">Ver etapas</button>`}</td></tr>`).join("");
    const mod=(summary.byModule||[]).map(x=>`<div class="qa-box"><span class="muted">${fmt.escape(fmt.label(x.module||""))}</span><strong class="${x.failed?"danger":"success"}">${x.passed||0}/${x.total||0}</strong><small>${x.failed||0} fallidas</small></div>`).join("");
    const roles=(summary.byRole||[]).map(x=>`<div class="qa-box"><span class="muted">${fmt.escape(fmt.label(x.role||""))}</span><strong class="${x.failed?"danger":"success"}">${x.passed||0}/${x.total||0}</strong><small>${x.users||0} usuario(s) real(es) usado(s)</small></div>`).join("");
    const verdict=cert?`<div class="wizard-confirm-box"><strong class="${cert.launchable?"success":"danger"}">${cert.launchable?"ERP LANZABLE":"ERP NO LANZABLE"}</strong><p>Flujo 336: ${cert.passed||0}/336 · fallidos ${cert.failed||0} · ramas especiales ${cert.branchSuite?.passed||0}/10 · no-entrega ${cert.deliveryExceptionSuite?.passed||0}/12 · pedidos TEST remanentes ${cert.remainingTestOrders??"—"}.</p></div><div class="section-gap-small"></div>`:"";
    const body=`${verdict}<div class="qa-summary"><div class="qa-box"><span class="muted">Correctos</span><strong class="success">${passed}/336</strong></div><div class="qa-box"><span class="muted">Fallidos</span><strong class="${failed?"danger":"success"}">${failed}</strong></div><div class="qa-box"><span class="muted">Pendientes</span><strong class="${pending?"warning":"success"}">${pending}</strong></div></div><div class="section-gap-small"></div><div class="wizard-tip"><strong>Qué certifica:</strong> cada pedido se crea como TEST-QA y cada etapa se ejecuta con un perfil autenticado del rol que realmente debe operar ese módulo. Si el rol no ve el pedido, no puede tomarlo, una RPC lo rechaza o la ruta cambia, el caso falla.</div><div class="section-gap"></div><h3>Módulos realmente recorridos</h3><div class="qa-summary">${mod||"—"}</div><div class="section-gap"></div><h3>Roles/usuarios realmente usados</h3><div class="qa-summary">${roles||"—"}</div>${failures.length?`<div class="section-gap"></div><h3 class="danger">Hallazgos</h3><div class="table-wrap mobile-card-table"><table><thead><tr><th>Pedido</th><th>Etapa</th><th>Módulo</th><th>Rol / usuario</th><th>Error</th></tr></thead><tbody>${failures.map(f=>`<tr><td>${fmt.escape(f.caseKey||"")}</td><td>${fmt.escape(fmt.step(f.stepCode||""))}</td><td>${fmt.escape(fmt.label(f.moduleCode||""))}</td><td>${fmt.escape(fmt.label(f.roleCode||""))}<small>${fmt.escape(f.actorName||"")}</small></td><td class="danger"><strong>${fmt.escape(f.errorSqlstate||"")}</strong><small>${fmt.escape(f.errorMessage||"")}</small></td></tr>`).join("")}</tbody></table></div>`:""}<div class="section-gap"></div><h3>336 pedidos</h3><div class="table-wrap mobile-card-table"><table><thead><tr><th>#</th><th>Combinación</th><th>Estado</th><th>Ruta esperada</th><th>Ruta real</th><th>Detalle</th></tr></thead><tbody>${rows}</tbody></table></div>`;
    const dialog=modal({title:"Certificación del flujo de pedidos",size:"xwide",confirmLabel:"",body});
    dialog?.root?.querySelectorAll?.("[data-flow-detail]").forEach(b=>b.onclick=()=>openFlowCase(b.dataset.flowDetail));
  }catch(e){toast(errText(e),"error",10000)}
}

export async function openFlowCase(caseId){
  try{
    const data=await api.qaFlowCaseDetail(caseId),c=data.case||{},s=data.state||{},steps=data.steps||[];
    const rows=steps.map(x=>`<tr><td>${x.stepIndex}</td><td><strong>${fmt.escape(fmt.step(x.stepCode||""))}</strong><small>${fmt.escape(fmt.label(x.moduleCode||""))}</small></td><td><strong>${fmt.escape(fmt.label(x.expectedRole||""))}</strong><small>${fmt.escape(x.actorName||"")}</small></td><td><small>${fmt.escape(actionText(x.actions||[]))}</small></td><td>${fmt.escape(fmt.step(x.expectedNextStep||""))}</td><td class="${x.expectedNextStep===x.actualNextStep?"success":"danger"}">${fmt.escape(fmt.step(x.actualNextStep||""))}</td><td><strong class="${x.status==="PASSED"?"success":"danger"}">${fmt.escape(x.status)}</strong>${x.errorMessage?`<small class="danger">${fmt.escape(x.errorSqlstate||"")} · ${fmt.escape(x.errorMessage)}</small>`:""}</td></tr>`).join("");
    modal({title:c.case_key||"Recorrido",size:"xwide",confirmLabel:"",body:`<div class="qa-summary"><div class="qa-box"><span class="muted">Pedido TEST</span><strong>${fmt.escape(s.order_number||"—")}</strong></div><div class="qa-box"><span class="muted">Estado</span><strong>${fmt.escape(c.status||"—")}</strong></div><div class="qa-box"><span class="muted">Etapas ejecutadas</span><strong>${s.steps_executed||0}</strong></div></div><div class="section-gap-small"></div><p><strong>Esperada:</strong> ${fmt.escape(path(s.expected_path))}</p><p><strong>Real:</strong> ${fmt.escape(path(s.actual_path))}</p><div class="section-gap"></div><div class="table-wrap mobile-card-table"><table><thead><tr><th>#</th><th>Etapa / módulo</th><th>Rol / usuario</th><th>Acciones reales</th><th>Esperaba</th><th>Obtuvo</th><th>Resultado</th></tr></thead><tbody>${rows||`<tr><td colspan="7">Este pedido aún no tiene etapas auditadas.</td></tr>`}</tbody></table></div>`});
  }catch(e){toast(errText(e),"error",10000)}
}
