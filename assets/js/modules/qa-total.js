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
  setRobotUi(ctx.root,{phase:"Contratos e integridad",detail:"Validando controles empresariales, contratos, ramas críticas e integridad antes de ejecutar miles de casos…",progress:4});

  const controls=await capture(ctx,{checkKey:"DOMAIN-CONTROLS-10",layer:"DOMAIN",suite:"CONTROLES_EMPRESARIALES",severity:"CRITICAL",success:r=>r?.status==="PASSED"||r?.failed===0,actual:r=>r||{}},()=>api.runQaControls(true));
  if(!controls)appendLog(ctx.root,"La suite de controles no devolvió resultado; la certificación no podrá aprobar.","failed");

  await capture(ctx,{checkKey:"INTEGRITY-STRUCTURAL",layer:"INTEGRITY",suite:"AUTODIAGNOSTICO",severity:"CRITICAL",success:r=>r?.success===true},()=>api.selfCheckV1022());
  await capture(ctx,{checkKey:"INTEGRITY-FLOW",layer:"INTEGRITY",suite:"INTEGRIDAD_FLUJOS",severity:"CRITICAL",success:r=>r?.success===true},()=>api.flowIntegrity());

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


async function executeOneReleaseCase(id,{maxAttempts=5}={}){
  let lastError=null;
  for(let attempt=1;attempt<=maxAttempts;attempt++){
    try{return await api.qaRobotExecuteDeepCase(id)}
    catch(error){
      lastError=error;
      const message=summarizeError(error);
      await api.qaRobotTransportFailure(id,`Intento ${attempt}/${maxAttempts} · ${message}`,attempt===maxAttempts).catch(()=>{});
      if(attempt<maxAttempts)await sleep(Math.min(1600,180*Math.pow(2,attempt-1)));
    }
  }
  return {caseId:id,status:"FAILED",transportFailure:true,errorMessage:summarizeError(lastError)};
}

async function executeDeepBatch(ids=[],concurrency=6){
  const queue=[...ids];const results=[];
  const workers=new Array(Math.min(concurrency,queue.length||1)).fill(0).map(async()=>{
    while(queue.length){const id=queue.shift();results.push(await executeOneReleaseCase(id,{maxAttempts:5}))}
  });
  await Promise.all(workers);return results;
}

async function runReleaseCampaign(ctx,{build=true}={}){
  setRobotUi(ctx.root,{phase:"Certificación funcional completa",detail:"Inventariando 336 rutas + 336 recorridos secuenciales + todas las ramas finitas aplicables…",progress:9});
  let built=null;
  let progress=await api.qaRobotDeepProgress(ctx.runId,36).catch(()=>null);
  if(build||progress?.routes?.planned!==336||progress?.journeys?.planned!==336){
    built=await api.qaRobotBuildReleaseCampaign(ctx.runId);
    progress=await api.qaRobotDeepProgress(ctx.runId,36);
  }
  await api.qaRobotResetStaleCases(ctx.runId,60).catch(()=>{});
  progress=await api.qaRobotDeepProgress(ctx.runId,36);
  const total=Math.max(1,progress.total||built?.totalCases||1);
  appendLog(ctx.root,`Plan de liberación: ${fmt.number(total)} casos persistentes. Rutas canónicas: ${fmt.number(progress.routes?.planned||0)} · recorridos completos: ${fmt.number(progress.journeys?.planned||0)}.`);
  let stagnant=0;let lastDone=-1;
  while((progress.pending||0)>0||(progress.running||0)>0){
    if((progress.pending||0)>0){
      const ids=progress.pendingIds||[];
      if(ids.length)await executeDeepBatch(ids,6);
    }
    progress=await api.qaRobotDeepProgress(ctx.runId,36);
    const done=(progress.executed??((progress.passed||0)+(progress.failed||0)));
    const pct=10+Math.min(45,(done/total)*45);
    setRobotUi(ctx.root,{detail:`${fmt.number(done)}/${fmt.number(total)} ejecutados · ${fmt.number(progress.passed||0)} aprobados · ${fmt.number(progress.failed||0)} fallidos · ${fmt.number(progress.pending||0)} pendientes · timeouts ${fmt.number(progress.timeoutFailures||0)} · transporte ${fmt.number(progress.transportFailures||0)}`,progress:pct});
    if(done===lastDone)stagnant++;else stagnant=0;
    lastDone=done;
    if(stagnant>=4&&(progress.running||0)>0){await api.qaRobotResetStaleCases(ctx.runId,45).catch(()=>{});stagnant=0}
    if(!progress.pendingIds?.length&&(progress.pending||0)>0)await sleep(180);
    else await sleep(30);
  }
  progress=await api.qaRobotDeepProgress(ctx.runId,50);
  const routeOk=progress.routes?.planned===336&&progress.routes?.passed===336&&progress.routes?.failed===0;
  const journeyOk=progress.journeys?.planned===336&&progress.journeys?.passed===336&&progress.journeys?.failed===0;
  const fullOk=progress.done===true&&(progress.failed||0)===0&&(progress.transportFailures||0)===0&&(progress.timeoutFailures||0)===0;
  await record(ctx,{checkKey:"DOMAIN-ROUTING-336",layer:"DOMAIN",suite:"RUTAS_CANONICAS",severity:"CRITICAL",status:routeOk?"PASSED":"FAILED",actual:progress.routes||{},errorMessage:routeOk?null:`Rutas: ${progress.routes?.passed||0}/336 aprobadas · ${progress.routes?.failed||0} fallidas.`});
  await record(ctx,{checkKey:"DOMAIN-JOURNEYS-336",layer:"DOMAIN",suite:"RECORRIDOS_COMPLETOS",severity:"CRITICAL",status:journeyOk?"PASSED":"FAILED",actual:progress.journeys||{},errorMessage:journeyOk?null:`Recorridos secuenciales: ${progress.journeys?.passed||0}/336 aprobados.`});
  await record(ctx,{checkKey:"DOMAIN-EXTREME-CAMPAIGN",layer:"DOMAIN",suite:"CAMPAÑA_EXTREME",severity:"CRITICAL",status:fullOk?"PASSED":"FAILED",actual:progress,errorMessage:fullOk?null:`Planificados ${progress.total||0} · ejecutados ${progress.executed||0} · fallidos ${progress.failed||0} · pendientes ${progress.pending||0} · timeout ${progress.timeoutFailures||0} · transporte ${progress.transportFailures||0}.`});
  return progress;
}


export async function runDeepQaCampaign(root,mode="EXTREME"){
  if(!hasRole("super_admin"))throw new Error("La campaña QA profunda es exclusiva de Superadministración.");
  const normalized=String(mode||"EXTREME").toUpperCase();
  const run=await api.qaRobotCreateRun({appVersion:CONFIG.version,build:CONFIG.build,campaign:normalized,startedAt:new Date().toISOString()});
  const ctx={runId:run.runId,root,plannedChecks:2,lastCounts:null};root.dataset.qaRobotRun=run.runId;
  let finalResult=null;
  try{
    await record(ctx,{checkKey:"PLAN-DEEP-READY",layer:"CONTRACT",suite:"PLAN_QA",severity:"INFO",status:"PASSED",actual:{mode:normalized,runId:run.runId}});
    if(normalized==="EXTREME")await runReleaseCampaign(ctx);else{
      const built=await api.qaRobotBuildDeepCampaign(ctx.runId,normalized);
      let progress=await api.qaRobotDeepProgress(ctx.runId,24);
      while((progress.pending||0)>0){await executeDeepBatch(progress.pendingIds||[],4);progress=await api.qaRobotDeepProgress(ctx.runId,24)}
      await record(ctx,{checkKey:"DOMAIN-DEEP-CAMPAIGN",layer:"DOMAIN",suite:"CICLOS_TRANSVERSALES",severity:"CRITICAL",status:progress.failed===0&&progress.pending===0?"PASSED":"FAILED",actual:{...progress,built},errorMessage:progress.failed===0&&progress.pending===0?null:`${progress.failed||0} fallidos · ${progress.pending||0} pendientes.`});
    }
  }catch(error){
    await record(ctx,{checkKey:"DEEP-FATAL",layer:"DOMAIN",suite:"ORQUESTADOR_PROFUNDO",severity:"CRITICAL",status:"FAILED",errorMessage:summarizeError(error)}).catch(()=>{});
  }finally{
    finalResult=await api.qaRobotFinishDirectedRun(run.runId,normalized).catch(error=>({status:"FAILED",failed:1,error:summarizeError(error)}));
    setRobotUi(root,{phase:finalResult.status==="PASSED"?"Campaña aprobada":"Campaña con hallazgos",detail:finalResult.status==="PASSED"?"Todos los casos profundos finalizaron correctamente.":`${finalResult.failed||0} comprobación(es) agregadas fallaron. Revisa los casos profundos.`,progress:100,counts:`${finalResult.passed||0} correctas · ${finalResult.failed||0} fallidas · ${finalResult.warnings||0} advertencias`});
    root.dispatchEvent(new CustomEvent("erp:qa-total-finished",{detail:{runId:run.runId,result:finalResult}}));
  }
  return {runId:run.runId,result:finalResult};
}

async function runModuleCrawler(ctx,frame){
  setRobotUi(ctx.root,{phase:"Recorrido automático de la aplicación",detail:"Entrando módulo por módulo y accionando controles seguros…",progress:58});
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
  setRobotUi(ctx.root,{phase:"Responsive real",detail:"Probando anchos de teléfono, tablet y escritorio dentro del ERP…",progress:70});
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

async function exercisePrimarySandboxAction(frame,step){
  const doc=frame.contentDocument,w=frame.contentWindow;const before=frameErrors(w).length;
  const selectors={
    CARTERA:"[data-financial-start]:not([disabled])",CAJA:"[data-financial-start]:not([disabled])",
    COMPRAS:"[data-next-action]:not([disabled]),[data-status-choice='WORKING']:not([disabled])",
    RECEPCION_MERCANCIA:"[data-next-action]:not([disabled]),[data-status-choice='WORKING']:not([disabled])",
    RECEPCION_PEDIDO:"[data-take-order]:not([disabled])",ALISTAMIENTO:"[data-picking-take]:not([disabled]),[data-resume-partial]:not([disabled])",
    FACTURACION:"[data-billing-action='accept']:not([disabled])",CAJA_FACTURACION:"[data-cash-action='accept']:not([disabled])",
    CLIENT_POINT:"[data-take-shipping]:not([disabled])",CLIENT_PICKUP:"[data-take-shipping]:not([disabled])",
    LOCAL_DISPATCH:"[data-take-shipping]:not([disabled])",NATIONAL_DISPATCH:"[data-take-shipping]:not([disabled])"
  };
  if(step==="CLOSURE"){
    const input=doc.querySelector("#modal-root [data-closure-photo]");
    if(!input)return {executed:false,action:"CLOSURE_EVIDENCE",reason:"No apareció el control de foto de cierre."};
    try{
      const file=new w.File([new Uint8Array([137,80,78,71,13,10,26,10])],"qa-cierre.png",{type:"image/png"});
      const dt=new w.DataTransfer();dt.items.add(file);input.files=dt.files;input.dispatchEvent(new w.Event("change",{bubbles:true}));
      await sleep(1500);
      const errors=frameErrors(w).slice(before);
      return {executed:errors.length===0,action:"CLOSURE_EVIDENCE",errors};
    }catch(error){return {executed:false,action:"CLOSURE_EVIDENCE",reason:summarizeError(error)}}
  }
  const selector=selectors[step];
  if(!selector)return {executed:false,action:"PRIMARY",reason:`No existe driver UI para ${step}.`};
  const button=doc.querySelector(`#modal-root ${selector}`);
  if(!button||button.disabled||!visible(button))return {executed:false,action:"PRIMARY",reason:`No apareció una acción primaria habilitada para ${step}.`};
  const label=(button.textContent||button.getAttribute("aria-label")||step).trim().replace(/\s+/g," ").slice(0,120);
  try{button.click();await sleep(850);const errors=frameErrors(w).slice(before);return {executed:errors.length===0,action:label,errors}}
  catch(error){return {executed:false,action:label,reason:summarizeError(error)}}
}
async function runSandboxProbes(ctx,frame){
  setRobotUi(ctx.root,{phase:"Operación Sandbox",detail:"Creando pedidos TEST y abriendo cada etapa con la interfaz real…",progress:88});
  for(const [step,module,type] of STEP_PROBES){
    const started=performance.now();let seeded=null;
    try{
      seeded=await api.qaRobotSeedOrder(ctx.runId,{scenarioKey:`STEP-${step}`,stepCode:step,orderType:type,paymentCondition:type==="PVN"?"CASH":"CREDIT",deliveryRoute:step==="NATIONAL_DISPATCH"?"NATIONAL_DISPATCH":"LOCAL_DISPATCH",requiresPurchase:type==="PVE"});
      await gotoFrame(frame,module,{sandbox:"1",step});
      const found=await waitForFrame(frame,doc=>Boolean(rowForOrder(doc,seeded.orderNumber)),10000);
      let opened=false;let primary={executed:false,action:null,reason:null};
      if(found){
        const row=rowForOrder(frame.contentDocument,seeded.orderNumber);
        const open=[...row.querySelectorAll("button")].find(btn=>visible(btn)&&/(abrir|continuar|retomar|gestionar|ver|tomar)/i.test(btn.textContent||""));
        if(open){open.click();opened=true;await sleep(500);primary=await exercisePrimarySandboxAction(frame,step)}
      }
      const moduleError=frame.contentDocument.querySelector("#page-content .module-error")?.textContent?.trim()||null;
      const runtime=frameErrors(frame.contentWindow).filter(e=>e.at&&new Date(e.at).getTime()>=Date.now()-15000).slice(-10);
      const ok=found&&opened&&primary.executed&&!moduleError&&runtime.length===0;
      await record(ctx,{checkKey:`SANDBOX-STEP-${step}`,layer:"SANDBOX",suite:"ETAPAS_OPERATIVAS",moduleCode:module,orderId:seeded.orderId,severity:"CRITICAL",status:ok?"PASSED":"FAILED",actual:{orderNumber:seeded.orderNumber,found,opened,primaryActionExecuted:primary.executed,primaryAction:primary.action,primaryReason:primary.reason,moduleError,runtimeErrors:runtime},durationMs:Math.round(performance.now()-started),errorMessage:ok?null:[moduleError,!found?"El pedido TEST no apareció en la cola Sandbox de su etapa.":null,found&&!opened?"La tarjeta apareció pero el Robot no logró abrirla.":null,opened&&!primary.executed?`La tarjeta abrió, pero no ejecutó su acción primaria: ${primary.reason||primary.action||"sin detalle"}.`:null,runtime.map(x=>x.message).join(" · ")].filter(Boolean).join(" · ")});
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
    let opened=false,startedCut=false;
    if(found){
      const groupButton=[...frame.contentDocument.querySelectorAll("[data-cut-group]")].find(visible);
      if(groupButton){groupButton.click();opened=await waitForFrame(frame,doc=>Boolean(doc.querySelector("#modal-root [data-start-cut],#modal-root [data-pause-cut],#modal-root [data-resume-cut]")),8000);
        const startButton=frame.contentDocument.querySelector("#modal-root [data-start-cut]");
        if(startButton&&visible(startButton)&&!startButton.disabled){startButton.click();await sleep(900);startedCut=Boolean(frame.contentDocument.querySelector("#modal-root [data-pause-cut],#modal-root [data-cut-step='1']"))}
        else startedCut=Boolean(frame.contentDocument.querySelector("#modal-root [data-pause-cut],#modal-root [data-resume-cut]"));
      }
    }
    const error=frame.contentDocument.querySelector("#page-content .module-error")?.textContent?.trim()||null;
    const ok=found&&opened&&startedCut&&!error;
    await record(ctx,{checkKey:"SANDBOX-CUTTING-PARALLEL",layer:"SANDBOX",suite:"CORTE_MODERNO",moduleCode:"cutting",orderId:cutOrder.orderId,severity:"CRITICAL",status:ok?"PASSED":"FAILED",actual:{found,opened,primaryActionExecuted:startedCut,error},durationMs:Math.round(performance.now()-started),errorMessage:ok?null:error||(!found?"El requerimiento de Corte TEST no apareció en el Centro de Corte.":!opened?"La referencia apareció pero no abrió el flujo de Corte.":"El flujo abrió pero no logró ejecutar Iniciar corte.")});
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
    const plan=await api.qaRobotPlan();ctx.plannedChecks=5+(plan?.domain?.enterpriseControls||10)+(plan?.domain?.branchChecks||10)+8+((state.modules||[]).filter(m=>m.canRead).length)+RESPONSIVE_MODULES.length*RESPONSIVE_WIDTHS.length+STEP_PROBES.length+1;
    await record(ctx,{checkKey:"PLAN-READY",layer:"CONTRACT",suite:"PLAN_QA",severity:"INFO",status:"PASSED",actual:plan});
    await runBackend(ctx);
    await runReleaseCampaign(ctx);
    frame=await prepareFrame(ctx);await runModuleCrawler(ctx,frame);await runResponsive(ctx,frame);await runSandboxProbes(ctx,frame);
  }catch(error){
    await record(ctx,{checkKey:"ROBOT-FATAL",layer:"UI",suite:"ORQUESTADOR",severity:"CRITICAL",status:"FAILED",errorMessage:summarizeError(error)}).catch(()=>{});
  }finally{
    setRobotUi(root,{phase:"Cerrando y limpiando",detail:"Eliminando pedidos TEST creados por esta ejecución…",progress:97});
    finalResult=await api.qaRobotFinishRun(run.runId,true).catch(error=>({status:"FAILED",releaseState:"FAILED",certified:false,failed:(ctx.lastCounts?.failed||0)+1,error:summarizeError(error)}));
    const certified=finalResult.certified===true;
    const releaseState=finalResult.releaseState||"FAILED";
    const gates=finalResult.certificate?.gates||{};
    const releaseDetail=certified
      ?`336/336 rutas · 336/336 recorridos · ${fmt.number(gates.extreme?.executed||0)}/${fmt.number(gates.extreme?.planned||0)} casos · 0 pendientes · 0 transporte · interfaz, integridad y responsive aprobados.`
      :releaseState==="INCOMPLETE"
        ?`QA incompleto: ${fmt.number(gates.extreme?.executed||0)}/${fmt.number(gates.extreme?.planned||0)} casos ejecutados · ${fmt.number(gates.extreme?.pending||0)} pendientes. No liberar.`
        :`No certificado. Rutas ${fmt.number(gates.routing?.passed||0)}/336 · recorridos ${fmt.number(gates.journeys?.passed||0)}/336 · fallidos ${fmt.number(gates.extreme?.failed||0)} · timeout ${fmt.number(gates.extreme?.timeouts||0)} · transporte ${fmt.number(gates.extreme?.transport||0)}.`;
    setRobotUi(root,{phase:certified?"ERP CERTIFICADO PARA LIBERACIÓN":releaseState==="INCOMPLETE"?"QA INCOMPLETO":"ERP NO CERTIFICADO",detail:releaseDetail,progress:100,counts:`${finalResult.passed||0} correctas · ${finalResult.failed||0} fallidas · ${finalResult.warnings||0} advertencias`});
    appendLog(root,certified?"✓ CERTIFICADO: todos los gates de liberación quedaron en verde.":`× ${releaseState}: el ERP no queda autorizado por el Robot para liberación.`,certified?"passed":"failed");
    root.dispatchEvent(new CustomEvent("erp:qa-total-finished",{detail:{runId:run.runId,result:finalResult}}));
  }
  return {runId:run.runId,result:finalResult};
}

export async function runRouteQaCampaign(root){
  if(!hasRole("super_admin"))throw new Error("La certificación de rutas es exclusiva de Superadministración.");
  const run=await api.qaRobotCreateRun({appVersion:CONFIG.version,build:CONFIG.build,campaign:"ROUTES_336",startedAt:new Date().toISOString()});
  const ctx={runId:run.runId,root,plannedChecks:1,lastCounts:null};root.dataset.qaRobotRun=run.runId;
  let finalResult=null;
  try{
    const built=await api.qaRobotBuildRouteCampaign(run.runId);
    let progress=await api.qaRobotDeepProgress(run.runId,36);
    const total=built.canonicalRoutes||336;
    while((progress.pending||0)>0||(progress.running||0)>0){
      if(progress.pendingIds?.length)await executeDeepBatch(progress.pendingIds,6);
      progress=await api.qaRobotDeepProgress(run.runId,36);
      const done=progress.executed||0;
      setRobotUi(root,{phase:"336 rutas canónicas",detail:`${fmt.number(done)}/${fmt.number(total)} ejecutadas · ${fmt.number(progress.passed||0)} aprobadas · ${fmt.number(progress.failed||0)} fallidas · timeouts ${fmt.number(progress.timeoutFailures||0)} · transporte ${fmt.number(progress.transportFailures||0)}`,progress:Math.min(98,5+(done/Math.max(1,total))*90)});
      if(!progress.pendingIds?.length&&(progress.pending||0)>0)await sleep(120);
    }
    finalResult=await api.qaRobotFinishDirectedRun(run.runId,"ROUTES_336");
    setRobotUi(root,{phase:finalResult.status==="PASSED"?"336/336 RUTAS APROBADAS":"RUTAS NO APROBADAS",detail:`Ejecutadas ${fmt.number(finalResult.executed||0)}/${fmt.number(finalResult.planned||0)} · fallidas ${fmt.number(finalResult.failed||0)} · pendientes ${fmt.number(finalResult.pending||0)} · timeout ${fmt.number(finalResult.timeoutFailures||0)} · transporte ${fmt.number(finalResult.transportFailures||0)}`,progress:100});
  }catch(error){
    finalResult={status:"FAILED",error:summarizeError(error)};setRobotUi(root,{phase:"RUTAS NO APROBADAS",detail:summarizeError(error),progress:100});
  }finally{root.dispatchEvent(new CustomEvent("erp:qa-total-finished",{detail:{runId:run.runId,result:finalResult}}))}
  return {runId:run.runId,result:finalResult};
}

export async function resumeTotalQaRobot(root,runId){
  if(!hasRole("super_admin"))throw new Error("El Robot QA total es exclusivo de Superadministración.");
  if(!runId)throw new Error("No se indicó la ejecución QA que debe reanudarse.");
  const ctx={runId,root,plannedChecks:90,lastCounts:null};root.dataset.qaRobotRun=runId;
  setRobotUi(root,{phase:"Reanudando certificación",detail:`Continuando ejecución ${runId.slice(0,8)} desde los casos persistidos…`,progress:4});
  appendLog(root,`Reanudando ${runId.slice(0,8)}. Los casos ya aprobados no se ejecutarán de nuevo.`);
  let finalResult=null;
  try{
    await api.qaRobotResetStaleCases(runId,30).catch(()=>{});
    await runBackend(ctx);
    await runReleaseCampaign(ctx,{build:false});
    const frame=await prepareFrame(ctx);await runModuleCrawler(ctx,frame);await runResponsive(ctx,frame);await runSandboxProbes(ctx,frame);
  }catch(error){
    await record(ctx,{checkKey:"ROBOT-FATAL",layer:"UI",suite:"ORQUESTADOR",severity:"CRITICAL",status:"FAILED",errorMessage:summarizeError(error)}).catch(()=>{});
  }finally{
    finalResult=await api.qaRobotFinishRun(runId,true).catch(error=>({status:"FAILED",releaseState:"FAILED",certified:false,error:summarizeError(error)}));
    const certified=finalResult.certified===true;const state=finalResult.releaseState||"FAILED";
    setRobotUi(root,{phase:certified?"ERP CERTIFICADO PARA LIBERACIÓN":state==="INCOMPLETE"?"QA INCOMPLETO":"ERP NO CERTIFICADO",detail:certified?"La ejecución reanudada completó todos los gates sin pendientes ni transporte.":"La ejecución reanudada todavía contiene hallazgos. Revisa el certificado.",progress:100});
    root.dispatchEvent(new CustomEvent("erp:qa-total-finished",{detail:{runId,result:finalResult}}));
  }
  return {runId,result:finalResult};
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
