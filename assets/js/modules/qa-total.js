import {api} from "../services/api.js";
import {CONFIG} from "../config.js";
import {state,hasRole} from "../core/state.js";
import {fmt} from "../core/format.js";

const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const MUTATION_RE=/(crear|guardar|enviar|aprobar|rechazar|eliminar|borrar|cancelar pedido|iniciar|finalizar|tomar|mover|ajustar|registrar|solicitar|confirmar|liberar|subir|anexar|aceptar|reprogramar|agregar actividad|vaciar|importar|sincronizar|ejecutar|cerrar pedido)/i;
const SAFE_RE=/(actualizar|buscar|filtr|ayuda|qué|semana|mes|mi jornada|planificación|aprobaciones|ocupación|analítica|anterior|siguiente|limpiar|restablecer|ver detalle|abrir detalle|mostrar|ocultar|expandir|contraer)/i;
const STEP_PROBES=[
  ["CARTERA","cartera","PVC"],["CAJA","caja","PVN"],["COMPRAS","purchasing","PVE"],
  ["RECEPCION_MERCANCIA","receiving","PVE"],["RECEPCION_PEDIDO","receiving","PVC"],
  ["ALISTAMIENTO","picking","PVC"],["FACTURACION","billing","PVC"],["CAJA_FACTURACION","caja","PVN"],
  ["CLIENT_POINT","shipping","PVC"],["CLIENT_PICKUP","shipping","PVC"],["LOCAL_DISPATCH","shipping","PVC"],
  ["NATIONAL_DISPATCH","shipping","PVN"],["CLOSURE","shipping","PVC"]
];
const RESPONSIVE_MODULES=["dashboard","orders","inventory","workforce","approvals","sandbox","cutting","receiving","shipping"];
const RESPONSIVE_WIDTHS=[360,390,424,768,960,1440];

function text(value){
  if(value==null)return "";
  if(typeof value==="string")return value;
  try{return JSON.stringify(value)}catch{return String(value)}
}
function summarizeError(error){return error?.technicalMessage||error?.message||String(error||"Error desconocido")}
function statusFromRows(rows=[]){return Array.isArray(rows)&&rows.every(row=>row?.ok!==false)}
function setRobotUi(root,patch={}){
  const phase=root?.querySelector?.("#qa-total-phase");
  const detail=root?.querySelector?.("#qa-total-detail");
  const counts=root?.querySelector?.("#qa-total-counts");
  const progress=root?.querySelector?.("#qa-total-progress-bar");
  if(phase&&patch.phase)phase.textContent=patch.phase;
  if(detail&&patch.detail)detail.textContent=patch.detail;
  if(counts&&patch.counts)counts.textContent=patch.counts;
  if(progress&&Number.isFinite(patch.progress))progress.style.width=`${Math.max(2,Math.min(100,patch.progress))}%`;
}
function appendLog(root,message,tone=""){
  const log=root?.querySelector?.("#qa-total-log");if(!log)return;
  const row=document.createElement("div");row.className=`qa-total-log-row ${tone}`;row.innerHTML=`<span>${new Date().toLocaleTimeString("es-CO",{hour12:false})}</span><p>${fmt.escape(message)}</p>`;log.prepend(row);
}

async function record(ctx,check){
  const start=performance.now();
  const payload={severity:"HIGH",status:"PASSED",...check};
  if(payload.durationMs==null)payload.durationMs=Math.round(performance.now()-start);
  const result=await api.qaRobotRecordCheck(ctx.runId,payload);
  ctx.lastCounts=result;
  const done=(result.passed||0)+(result.failed||0)+(result.warnings||0);
  const planned=Math.max(ctx.plannedChecks||1,done);
  setRobotUi(ctx.root,{counts:`${result.passed||0} correctas · ${result.failed||0} fallidas · ${result.warnings||0} advertencias`,progress:Math.min(96,(done/planned)*100)});
  appendLog(ctx.root,`${payload.status==="PASSED"?"✓":payload.status==="WARNING"?"!":"×"} ${payload.suite} · ${payload.checkKey}${payload.errorMessage?` · ${payload.errorMessage}`:""}`,payload.status.toLowerCase());
  return result;
}

async function capture(ctx,base,fn){
  const started=performance.now();
  try{
    const result=await fn();
    const ok=base.success?base.success(result):true;
    await record(ctx,{...base,status:ok?"PASSED":"FAILED",actual:base.actual?base.actual(result):result,durationMs:Math.round(performance.now()-started),errorMessage:ok?null:(base.failureMessage?.(result)||"El resultado no cumplió el criterio esperado.")});
    return result;
  }catch(error){
    await record(ctx,{...base,status:"FAILED",actual:{},durationMs:Math.round(performance.now()-started),errorMessage:summarizeError(error)});
    return null;
  }
}

function frameErrors(win){return Array.isArray(win?.__erpQaRobotErrors)?win.__erpQaRobotErrors:[]}
function installFrameDiagnostics(frame){
  const w=frame.contentWindow;if(!w||w.__erpQaRobotInstalled)return;
  w.__erpQaRobotInstalled=true;w.__erpQaRobotErrors=[];
  const push=(type,message,extra={})=>w.__erpQaRobotErrors.push({type,message:String(message||""),at:new Date().toISOString(),...extra});
  w.addEventListener("error",event=>push("window.error",event.message,{source:event.filename,line:event.lineno,column:event.colno}));
  w.addEventListener("unhandledrejection",event=>push("unhandledrejection",event.reason?.message||event.reason));
  w.addEventListener("erp:rpc-error",event=>push("rpc",event.detail?.message||"RPC error",event.detail||{}));
  const original=w.console?.error?.bind(w.console);
  if(original)w.console.error=(...args)=>{push("console.error",args.map(text).join(" "));original(...args)};
}
function visible(el){if(!el)return false;const s=el.ownerDocument.defaultView.getComputedStyle(el),r=el.getBoundingClientRect();return s.display!=="none"&&s.visibility!=="hidden"&&r.width>0&&r.height>0}
async function waitForFrame(frame,predicate,timeout=20000){
  const started=Date.now();
  while(Date.now()-started<timeout){
    try{if(predicate(frame.contentDocument,frame.contentWindow))return true}catch{}
    await sleep(150);
  }
  return false;
}
async function prepareFrame(ctx){
  const host=ctx.root.querySelector("#qa-robot-stage");
  host.hidden=false;host.innerHTML=`<div class="qa-robot-frame-head"><div><strong>Visor del Robot</strong><span>La aplicación real se ejecuta dentro de este navegador.</span></div><span class="badge badge-blue">E2E local</span></div><div class="qa-robot-frame-shell"><iframe id="qa-robot-frame" title="Robot QA del ERP" tabindex="-1"></iframe></div>`;
  const frame=host.querySelector("#qa-robot-frame");
  const base=new URL("./",location.href);base.hash="";base.search="";
  frame.src=base.toString();
  const loaded=await new Promise(resolve=>{const timer=setTimeout(()=>resolve(false),25000);frame.onload=()=>{clearTimeout(timer);resolve(true)}});
  if(!loaded)throw new Error("El visor E2E no pudo cargar la aplicación.");
  const ready=await waitForFrame(frame,(doc)=>Boolean(doc?.querySelector("#page-content")||doc?.querySelector("#login-form")),25000);
  if(!ready)throw new Error("El visor E2E no alcanzó un estado operativo.");
  if(frame.contentDocument.querySelector("#login-form"))throw new Error("El visor no heredó la sesión Super Admin. Recarga el ERP e inténtalo nuevamente.");
  installFrameDiagnostics(frame);
  return frame;
}
async function gotoFrame(frame,module,params={}){
  const qs=new URLSearchParams(Object.entries(params).filter(([,v])=>v!==null&&v!==undefined&&v!=="")).toString();
  const target=`#/${module}${qs?`?${qs}`:""}`;
  frame.contentWindow.location.hash=target;
  const ok=await waitForFrame(frame,(doc,win)=>win.location.hash===target&&!doc.querySelector("#page-content .loading")&&Boolean(doc.querySelector("#page-content")),18000);
  await sleep(250);
  return ok;
}
function inspectFrame(frame,module){
  const doc=frame.contentDocument,w=frame.contentWindow;
  const page=doc.querySelector("#page-content");
  const moduleError=page?.querySelector(".module-error");
  const html=doc.documentElement;
  const overflow=Math.max(html.scrollWidth-doc.defaultView.innerWidth,doc.body?.scrollWidth-doc.defaultView.innerWidth||0);
  const interactives=[...page.querySelectorAll("button,input,select,textarea,a[href]")].filter(visible);
  return {module,hasContent:Boolean(page?.textContent?.trim()),moduleError:moduleError?.textContent?.trim()||null,horizontalOverflow:Math.max(0,Math.round(overflow)),interactiveCount:interactives.length,errors:frameErrors(w).slice(-20)};
}
async function clickSafeControls(frame,module){
  const doc=frame.contentDocument,page=doc.querySelector("#page-content");if(!page)return {clicked:0,failures:[]};
  const failures=[];let clicked=0;
  const buttons=[...page.querySelectorAll("button")].filter(visible).filter(btn=>{
    const label=(btn.getAttribute("aria-label")||btn.textContent||"").trim();
    if(!label||btn.disabled||btn.closest("#qa-total-console"))return false;
    if(MUTATION_RE.test(label))return false;
    return SAFE_RE.test(label);
  }).slice(0,10);
  for(const button of buttons){
    const label=(button.getAttribute("aria-label")||button.textContent||"").trim().replace(/\s+/g," ").slice(0,100);
    const before=frameErrors(frame.contentWindow).length;
    try{
      button.click();clicked++;await sleep(220);
      const modal=doc.querySelector("#modal-root .modal");
      if(modal){doc.dispatchEvent(new KeyboardEvent("keydown",{key:"Escape",bubbles:true}));await sleep(100)}
      const after=frameErrors(frame.contentWindow).slice(before);
      if(after.length)failures.push({label,errors:after});
      if(frame.contentWindow.location.hash&&!frame.contentWindow.location.hash.startsWith(`#/${module}`))await gotoFrame(frame,module);
    }catch(error){failures.push({label,errors:[{message:summarizeError(error)}]})}
  }
  return {clicked,failures};
}

async function runBackend(ctx){
  setRobotUi(ctx.root,{phase:"Motor funcional",detail:"Recorriendo rutas comerciales, controles y gates de integridad…",progress:5});
  const result=await capture(ctx,{checkKey:"DOMAIN-ROUTING-336",layer:"DOMAIN",suite:"RUTAS_336",severity:"CRITICAL",success:r=>r?.matrix?.status==="PASSED",actual:r=>r?.matrix||{}},()=>api.runQaV1022(true));
  if(result){
    await record(ctx,{checkKey:"DOMAIN-CONTROLS-10",layer:"DOMAIN",suite:"CONTROLES_EMPRESARIALES",severity:"CRITICAL",status:result.controls?.status==="PASSED"?"PASSED":"FAILED",actual:result.controls||{},errorMessage:result.controls?.status==="PASSED"?null:"La suite empresarial reportó fallos."});
    await record(ctx,{checkKey:"INTEGRITY-STRUCTURAL",layer:"INTEGRITY",suite:"AUTODIAGNOSTICO",severity:"CRITICAL",status:result.selfCheck?.success?"PASSED":"FAILED",actual:result.selfCheck||{},errorMessage:result.selfCheck?.success?null:"El autodiagnóstico estructural no está completamente aprobado."});
    await record(ctx,{checkKey:"INTEGRITY-CROSS-FLOW",layer:"INTEGRITY",suite:"INTEGRIDAD_FLUJOS",severity:"CRITICAL",status:result.flowIntegrity?.success?"PASSED":"FAILED",actual:result.flowIntegrity||{},errorMessage:result.flowIntegrity?.success?null:"La integridad cruzada de flujos encontró inconsistencias."});
  }

  const contract=await capture(ctx,{checkKey:"CONTRACT-SYSTEM",layer:"CONTRACT",suite:"CONTRATO_SISTEMA",severity:"CRITICAL",success:r=>r?.success===true},()=>api.qaRobotSystemContract());
  for(const check of contract?.checks||[]){await record(ctx,{checkKey:`CONTRACT-${check.key}`,layer:"CONTRACT",suite:"CONTRATO_SISTEMA",severity:"HIGH",status:check.success?"PASSED":"FAILED",actual:check,errorMessage:check.success?null:check.detail})}

  const branches=await capture(ctx,{checkKey:"DOMAIN-BRANCH-SUITE",layer:"DOMAIN",suite:"RAMAS_CRITICAS",severity:"CRITICAL",success:r=>r?.success===true},()=>api.qaRobotBranchSuite(ctx.runId));
  for(const check of branches?.checks||[]){await record(ctx,{checkKey:`BRANCH-${check.key}`,layer:"DOMAIN",suite:"RAMAS_CRITICAS",severity:/CANCELLATION|ROUTE|REOPEN/.test(check.key)?"CRITICAL":"HIGH",status:check.success?"PASSED":"FAILED",orderId:check.orderId||null,actual:check,errorMessage:check.success?null:check.detail})}

  await capture(ctx,{checkKey:"HEALTH-GLOBAL",layer:"INTEGRITY",suite:"HEALTH_CHECK",severity:"CRITICAL",success:statusFromRows},()=>api.health());
  await capture(ctx,{checkKey:"HEALTH-WORKFORCE",layer:"INTEGRITY",suite:"WORKFORCE_HEALTH",severity:"HIGH",success:statusFromRows},()=>api.workHealth());
  await capture(ctx,{checkKey:"HEALTH-QUEUES",layer:"INTEGRITY",suite:"QUEUE_HEALTH",severity:"CRITICAL",success:r=>r?.ok===true},()=>api.queueIntegrity(false));
  await capture(ctx,{checkKey:"HEALTH-RESERVATIONS",layer:"INTEGRITY",suite:"RESERVATION_HEALTH",severity:"MEDIUM",success:r=>r&&typeof r==="object"},()=>api.materialReservationHealth());
  await capture(ctx,{checkKey:"HEALTH-RUNTIME",layer:"CONTRACT",suite:"RUNTIME_DIAGNOSTICS",severity:"HIGH",success:r=>Boolean(r)},()=>api.runtimeDiagnostics());
}

async function runModuleCrawler(ctx,frame){
  setRobotUi(ctx.root,{phase:"Recorrido automático de la aplicación",detail:"Entrando módulo por módulo y accionando controles seguros…",progress:22});
  const modules=(state.modules||[]).filter(m=>m.canRead).map(m=>m.code).filter(Boolean);
  for(const module of modules){
    const before=frameErrors(frame.contentWindow).length;
    const started=performance.now();
    const navigated=await gotoFrame(frame,module);
    const inspection=inspectFrame(frame,module);
    const safe=module==="qa"?{clicked:0,failures:[]}:await clickSafeControls(frame,module);
    const newErrors=frameErrors(frame.contentWindow).slice(before);
    const failures=[...safe.failures,...newErrors.map(error=>({label:"runtime",errors:[error]}))];
    const ok=navigated&&inspection.hasContent&&!inspection.moduleError&&inspection.horizontalOverflow<=4&&failures.length===0;
    await record(ctx,{checkKey:`UI-MODULE-${module.toUpperCase()}`,layer:"UI",suite:"RECORRIDO_MODULOS",moduleCode:module,severity:module==="dashboard"||module==="orders"?"CRITICAL":"HIGH",status:ok?"PASSED":"FAILED",actual:{...inspection,safeControlsClicked:safe.clicked},durationMs:Math.round(performance.now()-started),errorMessage:ok?null:[inspection.moduleError,inspection.horizontalOverflow>4?`Desbordamiento horizontal ${inspection.horizontalOverflow}px`:null,failures.length?`${failures.length} error(es) de interacción/runtime`:null].filter(Boolean).join(" · ")});
  }
}

async function runResponsive(ctx,frame){
  setRobotUi(ctx.root,{phase:"Responsive real",detail:"Probando anchos de teléfono, tablet y escritorio dentro del ERP…",progress:48});
  const shell=frame.closest(".qa-robot-frame-shell");
  for(const width of RESPONSIVE_WIDTHS){
    frame.style.width=`${width}px`;shell?.classList.toggle("mobile-probe",width<768);await sleep(120);
    for(const module of RESPONSIVE_MODULES){
      const before=frameErrors(frame.contentWindow).length;
      await gotoFrame(frame,module);
      const inspection=inspectFrame(frame,module);const errors=frameErrors(frame.contentWindow).slice(before);
      const doc=frame.contentDocument;
      const badFixed=[...doc.querySelectorAll(".modal,.task-panel,.drawer,[role='dialog']")].filter(visible).filter(el=>{const r=el.getBoundingClientRect();return r.right>width+4||r.left<-4});
      const ok=!inspection.moduleError&&inspection.horizontalOverflow<=4&&!errors.length&&!badFixed.length;
      await record(ctx,{checkKey:`RESP-${width}-${module.toUpperCase()}`,layer:"RESPONSIVE",suite:"VIEWPORT_SWEEP",moduleCode:module,severity:width<=424?"HIGH":"MEDIUM",status:ok?"PASSED":"FAILED",actual:{width,module,horizontalOverflow:inspection.horizontalOverflow,runtimeErrors:errors.length,outOfViewportDialogs:badFixed.length},errorMessage:ok?null:`Responsive ${width}px: ${inspection.moduleError||""} ${inspection.horizontalOverflow>4?`overflow ${inspection.horizontalOverflow}px`:""} ${errors.length?`${errors.length} error(es)`:""} ${badFixed.length?`${badFixed.length} diálogo(s) fuera del viewport`:""}`.trim()});
    }
  }
  frame.style.width="100%";shell?.classList.remove("mobile-probe");
}

function rowForOrder(doc,orderNumber){
  const nodes=[...doc.querySelectorAll("#page-content *")].filter(el=>el.children.length===0&&el.textContent?.includes(orderNumber));
  for(const node of nodes){const row=node.closest("article,tr,.erp-work-row,.queue-row,.lab-order-row,.sent-order-card,.order-row");if(row)return row}
  return nodes[0]?.parentElement||null;
}
async function runSandboxProbes(ctx,frame){
  setRobotUi(ctx.root,{phase:"Operación Sandbox",detail:"Creando pedidos TEST y abriendo cada etapa con la interfaz real…",progress:72});
  for(const [step,module,type] of STEP_PROBES){
    const started=performance.now();let seeded=null;
    try{
      seeded=await api.qaRobotSeedOrder(ctx.runId,{scenarioKey:`STEP-${step}`,stepCode:step,orderType:type,paymentCondition:type==="PVN"?"CASH":"CREDIT",deliveryRoute:step==="NATIONAL_DISPATCH"?"NATIONAL_DISPATCH":"LOCAL_DISPATCH",requiresPurchase:type==="PVE"});
      await gotoFrame(frame,module,{sandbox:"1",step});
      const found=await waitForFrame(frame,doc=>Boolean(rowForOrder(doc,seeded.orderNumber)),10000);
      let opened=false;
      if(found){
        const row=rowForOrder(frame.contentDocument,seeded.orderNumber);
        const open=[...row.querySelectorAll("button")].find(btn=>visible(btn)&&/(abrir|continuar|retomar|gestionar|ver|tomar)/i.test(btn.textContent||""));
        if(open){open.click();opened=true;await sleep(300)}
      }
      const moduleError=frame.contentDocument.querySelector("#page-content .module-error")?.textContent?.trim()||null;
      const runtime=frameErrors(frame.contentWindow).filter(e=>e.at&&new Date(e.at).getTime()>=Date.now()-15000).slice(-10);
      const ok=found&&!moduleError&&runtime.length===0;
      await record(ctx,{checkKey:`SANDBOX-STEP-${step}`,layer:"SANDBOX",suite:"ETAPAS_OPERATIVAS",moduleCode:module,orderId:seeded.orderId,severity:"CRITICAL",status:ok?"PASSED":"FAILED",actual:{orderNumber:seeded.orderNumber,found,opened,moduleError,runtimeErrors:runtime},durationMs:Math.round(performance.now()-started),errorMessage:ok?null:moduleError||(!found?"El pedido TEST no apareció en la cola Sandbox de su etapa.":runtime.map(x=>x.message).join(" · "))});
      frame.contentDocument.dispatchEvent(new KeyboardEvent("keydown",{key:"Escape",bubbles:true}));
    }catch(error){
      await record(ctx,{checkKey:`SANDBOX-STEP-${step}`,layer:"SANDBOX",suite:"ETAPAS_OPERATIVAS",moduleCode:module,orderId:seeded?.orderId||null,severity:"CRITICAL",status:"FAILED",durationMs:Math.round(performance.now()-started),errorMessage:summarizeError(error)});
    }
  }

  const started=performance.now();let cutOrder=null;
  try{
    cutOrder=await api.qaRobotSeedOrder(ctx.runId,{scenarioKey:"CUT-PARALLEL-EVIDENCE",stepCode:"ALISTAMIENTO",orderType:"PVC",paymentCondition:"CREDIT",deliveryRoute:"LOCAL_DISPATCH",requiresCut:true});
    await gotoFrame(frame,"cutting",{sandbox:"1"});
    const found=await waitForFrame(frame,doc=>doc.querySelector("#page-content")?.textContent?.includes("QA-REF-001"),10000);
    const error=frame.contentDocument.querySelector("#page-content .module-error")?.textContent?.trim()||null;
    await record(ctx,{checkKey:"SANDBOX-CUTTING-PARALLEL",layer:"SANDBOX",suite:"CORTE_MODERNO",moduleCode:"cutting",orderId:cutOrder.orderId,severity:"CRITICAL",status:found&&!error?"PASSED":"FAILED",actual:{found,error},durationMs:Math.round(performance.now()-started),errorMessage:found&&!error?null:error||"El requerimiento de Corte TEST no apareció en el Centro de Corte."});
  }catch(error){await record(ctx,{checkKey:"SANDBOX-CUTTING-PARALLEL",layer:"SANDBOX",suite:"CORTE_MODERNO",moduleCode:"cutting",orderId:cutOrder?.orderId||null,severity:"CRITICAL",status:"FAILED",durationMs:Math.round(performance.now()-started),errorMessage:summarizeError(error)})}
}

export async function runTotalQaRobot(root){
  if(!hasRole("super_admin"))throw new Error("El Robot QA total es exclusivo de Superadministración.");
  const run=await api.qaRobotCreateRun({appVersion:CONFIG.version,build:CONFIG.build,userAgent:navigator.userAgent,startedAt:new Date().toISOString()});
  const ctx={runId:run.runId,root,plannedChecks:90,lastCounts:null};
  root.dataset.qaRobotRun=run.runId;
  setRobotUi(root,{phase:"Preparando Robot QA",detail:`Ejecución ${run.runId.slice(0,8)} · aislada de producción`,progress:2,counts:"0 correctas · 0 fallidas"});
  appendLog(root,`Robot QA ${run.runId.slice(0,8)} iniciado. Ningún pedido productivo será modificado.`);
  let frame=null;let finalResult=null;
  try{
    const plan=await api.qaRobotPlan();ctx.plannedChecks=4+(plan?.domain?.enterpriseControls||10)+(plan?.domain?.branchChecks||10)+8+((state.modules||[]).filter(m=>m.canRead).length)+RESPONSIVE_MODULES.length*RESPONSIVE_WIDTHS.length+STEP_PROBES.length+1;
    await record(ctx,{checkKey:"PLAN-READY",layer:"CONTRACT",suite:"PLAN_QA",severity:"INFO",status:"PASSED",actual:plan});
    await runBackend(ctx);
    frame=await prepareFrame(ctx);await runModuleCrawler(ctx,frame);await runResponsive(ctx,frame);await runSandboxProbes(ctx,frame);
  }catch(error){
    await record(ctx,{checkKey:"ROBOT-FATAL",layer:"UI",suite:"ORQUESTADOR",severity:"CRITICAL",status:"FAILED",errorMessage:summarizeError(error)}).catch(()=>{});
  }finally{
    setRobotUi(root,{phase:"Cerrando y limpiando",detail:"Eliminando pedidos TEST creados por esta ejecución…",progress:97});
    finalResult=await api.qaRobotFinishRun(run.runId,true).catch(error=>({status:"FAILED",failed:(ctx.lastCounts?.failed||0)+1,error:summarizeError(error)}));
    setRobotUi(root,{phase:finalResult.status==="PASSED"?"Sistema aprobado":"Revisión necesaria",detail:finalResult.status==="PASSED"?"El Robot QA terminó sin fallos críticos.":`${finalResult.failed||0} comprobación(es) fallaron. Abre el detalle antes de liberar cambios.`,progress:100,counts:`${finalResult.passed||0} correctas · ${finalResult.failed||0} fallidas · ${finalResult.warnings||0} advertencias`});
    appendLog(root,finalResult.status==="PASSED"?"✓ Ejecución total aprobada.":`× Ejecución terminada con ${finalResult.failed||0} fallo(s).`,finalResult.status==="PASSED"?"passed":"failed");
    root.dispatchEvent(new CustomEvent("erp:qa-total-finished",{detail:{runId:run.runId,result:finalResult}}));
  }
  return {runId:run.runId,result:finalResult};
}

export function robotCheckRows(checks=[]){
  return checks.map(c=>`<tr><td data-label="Capa"><span class="qa-layer">${fmt.escape(fmt.label(c.layer))}</span></td><td data-label="Prueba"><strong>${fmt.escape(c.suite)}</strong><small>${fmt.escape(c.checkKey)}</small></td><td data-label="Módulo">${fmt.escape(c.moduleCode||"—")}</td><td data-label="Estado"><span class="badge ${c.status==="PASSED"?"badge-green":c.status==="WARNING"?"badge-yellow":c.status==="SKIPPED"?"badge-gray":"badge-red"}"><span class="badge-dot"></span>${fmt.escape(fmt.label(c.status))}</span></td><td data-label="Tiempo">${c.durationMs!=null?`${fmt.number(c.durationMs)} ms`:"—"}</td><td data-label="Detalle" class="${c.status==="FAILED"?"danger":""}">${fmt.escape(c.errorMessage||summaryActual(c.actual))}</td></tr>`).join("");
}
function summaryActual(value){
  if(value==null)return "—";
  if(typeof value==="string")return value.slice(0,160);
  if(Array.isArray(value))return `${value.length} resultado(s)`;
  if(typeof value==="object"){
    if(value.detail)return String(value.detail).slice(0,160);
    if(value.total!=null&&value.passed!=null)return `${value.passed}/${value.total} aprobadas`;
    return Object.entries(value).slice(0,3).map(([k,v])=>`${k}: ${typeof v==="object"?"…":String(v)}`).join(" · ");
  }
  return String(value);
}
