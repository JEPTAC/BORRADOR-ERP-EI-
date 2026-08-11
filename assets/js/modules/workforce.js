import {api} from "../services/api.js";
import {fmt,statusBadge,priorityBadge} from "../core/format.js";
import {loading,empty,modal,wizard,toast} from "../core/ui.js";
import {state} from "../core/state.js";
import {uploadWorkEvidence} from "../services/drive.js";

let liveTimer=null;
let currentView="today";
let plannerMode="week";
let plannerAnchor=startOfWeek(new Date());
let analyticsRange={from:isoDate(addDays(new Date(),-29)),to:isoDate(new Date())};

const GROUP_LABELS={LOGISTICS:"Operación logística",COMMERCIAL:"Comercial",FINANCE:"Financiera",PURCHASING:"Compras",MANAGEMENT:"Gestión",GENERAL:"General",IMPROVEMENT:"Mejora continua"};
const PAUSE_REASONS={OTHER:"Otra causa",WAIT_MATERIAL:"Espera de material",WAIT_EQUIPMENT:"Espera de equipo",PRIORITY_CHANGE:"Cambio de prioridad",SUPPORT_OTHER:"Apoyo a otra operación",BREAK:"Pausa programada",INCIDENT:"Novedad / incidente"};
const DEVIATION_REASONS={"":"Sin causa especial",MATERIAL:"Material no disponible",INTERRUPTION:"Interrupción / prioridad urgente",EQUIPMENT:"Equipo o herramienta",COMPLEXITY:"Mayor complejidad",REWORK:"Corrección o retrabajo",WAITING:"Espera de tercero",OTHER:"Otra causa"};

export async function renderWorkforce(root){
  clearInterval(liveTimer);
  root.innerHTML=`
    <section class="page-head workforce-page-head">
      <div><span class="workforce-kicker">Tiempo, capacidad y ejecución</span><h2>Mi jornada</h2><p>Planifica, ejecuta y explica el trabajo real sin duplicar cronómetros ni perder trazabilidad.</p></div>
      <div class="page-actions"><button class="btn btn-ghost" data-work-refresh>Actualizar</button></div>
    </section>
    <nav class="workforce-tabs" aria-label="Vistas de actividades">
      <button class="workforce-tab ${currentView==="today"?"active":""}" data-work-view="today">Mi jornada</button>
      <button class="workforce-tab" data-work-view="planner" hidden>Planificación</button>
      <button class="workforce-tab" data-work-view="analytics">Analítica</button>
    </nav>
    <section id="workforce-content">${loading("Preparando tu jornada…")}</section>`;

  root.querySelector("[data-work-refresh]").onclick=()=>renderCurrent(root,true);
  root.querySelectorAll("[data-work-view]").forEach(button=>button.onclick=()=>{
    currentView=button.dataset.workView;
    root.querySelectorAll("[data-work-view]").forEach(b=>b.classList.toggle("active",b===button));
    renderCurrent(root);
  });
  await renderCurrent(root);
}

async function renderCurrent(root,force=false){
  clearInterval(liveTimer);
  const content=root.querySelector("#workforce-content");
  if(!content)return;
  content.innerHTML=loading();
  if(currentView==="planner")return renderPlanner(root,content);
  if(currentView==="analytics")return renderAnalytics(root,content);
  return renderToday(root,content,force);
}

async function renderToday(root,content){
  const data=await api.workMyDay();
  const plannerTab=root.querySelector('[data-work-view="planner"]');
  if(plannerTab)plannerTab.hidden=!data.permissions?.canViewTeam;
  content.innerHTML=`
    ${activeWorkCard(data.active)}
    <section class="workforce-summary-grid">
      ${summaryCard("Tiempo en actividades",fmt.hours(data.summary?.activeSeconds),"Trabajo adicional registrado hoy")}
      ${summaryCard("Actividades completadas",fmt.number(data.summary?.completed),"Ejecuciones cerradas hoy")}
      ${summaryCard("Planificado",`${fmt.number(data.summary?.plannedMinutes)} min`,"Carga asignada para hoy")}
      ${summaryCard("Por completar",fmt.number((data.summary?.pendingEvidence||0)+(data.summary?.pendingReview||0)),"Evidencias o revisión pendientes")}
    </section>
    <div class="workforce-main-grid">
      <section class="card workforce-agenda-card">
        <header class="card-head"><div><h3>Mi agenda de hoy</h3><p>Primero lo programado; también puedes iniciar una actividad espontánea.</p></div><span class="workforce-count">${(data.today||[]).length}</span></header>
        <div class="card-body workforce-agenda-list">${agendaHtml(data)}</div>
      </section>
      <section class="card workforce-quick-card">
        <header class="card-head"><div><h3>Registrar actividad</h3><p>Accesos rápidos al catálogo habilitado para tu rol.</p></div></header>
        <div class="card-body">${catalogHtml(data.catalog||[],Boolean(data.active))}</div>
      </section>
    </div>
    <section class="card workforce-history-card">
      <header class="card-head"><div><h3>Lo registrado hoy</h3><p>Tiempo activo, pausas, evidencia y estado de cada actividad.</p></div></header>
      <div class="card-body">${historyHtml(data.history||[])}</div>
    </section>`;

  bindTodayActions(content,data);
  startLiveClock(content,data.active);
}

function activeWorkCard(active){
  if(!active)return `<section class="work-now idle"><div class="work-now-status"><span class="work-pulse"></span><div><small>Ahora</small><strong>Sin actividad adicional en curso</strong><p>Los procesos normales del ERP continúan midiéndose en sus módulos. Usa este cronómetro para trabajo adicional.</p></div></div><span class="work-now-hint">Selecciona una actividad abajo</span></section>`;
  const metrics=active.metrics||{};
  const paused=active.status==="PAUSED";
  const types=new Set((active.evidence||[]).map(x=>x.type));
  const needsBefore=active.evidencePolicy==="BEFORE_AFTER"&&!types.has("BEFORE_PHOTO");
  return `<section class="work-now running ${paused?"paused":""}" data-active-execution="${fmt.escape(active.id)}" data-started-at="${fmt.escape(active.startedAt)}" data-base-elapsed="${Number(metrics.elapsedSeconds||0)}" data-paused="${paused}">
    <div class="work-now-status"><span class="work-pulse"></span><div><small>${paused?"Actividad pausada":"Trabajando ahora"}</small><strong>${fmt.escape(active.title)}</strong><p>${fmt.escape(active.catalogName||"")}${active.plannedStart?` · Programada ${timeOnly(active.plannedStart)}`:""}</p></div></div>
    <div class="work-now-clock"><strong data-live-clock>${clock(metrics.elapsedSeconds||0)}</strong><span>${fmt.hours(metrics.businessSeconds||0)} laborales · ${fmt.hours(metrics.pausedSeconds||0)} en pausa</span></div>
    <div class="work-now-actions">
      ${needsBefore?`<button class="btn btn-ghost" data-work-before-photo>Foto inicial</button>`:""}
      ${paused?`<button class="btn btn-primary" data-work-resume>Reanudar</button>`:`<button class="btn btn-ghost" data-work-pause>Pausar</button>`}
      <button class="btn btn-primary" data-work-finish ${needsBefore?'disabled title="Toma primero la foto inicial"':""}>${needsBefore?"Foto inicial pendiente":"Finalizar actividad"}</button>
    </div>
  </section>`;
}

function summaryCard(label,value,detail){return `<article class="workforce-summary-card"><span>${fmt.escape(label)}</span><strong>${fmt.escape(String(value))}</strong><small>${fmt.escape(detail)}</small></article>`}

function agendaHtml(data){
  const overdue=data.overdue||[],today=data.today||[],upcoming=data.upcoming||[];
  if(!overdue.length&&!today.length&&!upcoming.length)return empty("Jornada sin actividades programadas","Puedes iniciar una actividad espontánea desde el catálogo.");
  return `
    ${overdue.length?`<div class="agenda-section overdue"><div class="agenda-section-title"><strong>Vencidas</strong><span>${overdue.length}</span></div>${overdue.map(a=>agendaRow(a,true,Boolean(data.active))).join("")}</div>`:""}
    ${today.length?`<div class="agenda-section"><div class="agenda-section-title"><strong>Hoy</strong><span>${today.length}</span></div>${today.map(a=>agendaRow(a,false,Boolean(data.active))).join("")}</div>`:""}
    ${upcoming.length?`<div class="agenda-section upcoming"><div class="agenda-section-title"><strong>Próximos 7 días</strong><span>${upcoming.length}</span></div>${upcoming.map(upcomingRow).join("")}</div>`:""}`;
}

function agendaRow(a,overdue,hasActive){
  return `<article class="agenda-row ${overdue?"is-overdue":""}">
    <div class="agenda-time"><strong>${a.plannedStart?timeOnly(a.plannedStart):a.dueAt?"Límite":"—"}</strong><span>${a.plannedEnd?timeOnly(a.plannedEnd):a.dueAt?fmt.day(a.dueAt):""}</span></div>
    <div class="agenda-main"><div>${priorityBadge(a.priority)} ${a.kind==="DELIVERABLE"?'<span class="badge badge-blue"><span class="badge-dot"></span>Entregable</span>':""}</div><strong>${fmt.escape(a.title)}</strong><small>${fmt.escape(a.catalogName||a.kind||"")} · ${fmt.number(a.estimatedMinutes||0)} min${a.dueAt?` · vence ${fmt.date(a.dueAt)}`:""}</small></div>
    <div class="agenda-actions"><button class="btn btn-primary" data-start-assignment="${fmt.escape(a.id)}" data-catalog-id="${fmt.escape(a.catalogId||"")}" ${hasActive||!a.catalogId?"disabled":""}>${a.memberStatus==="RETURNED"?"Retomar":"Iniciar"}</button></div>
  </article>`;
}

function upcomingRow(a){return `<article class="agenda-row compact"><div class="agenda-time"><strong>${a.plannedStart?weekdayShort(a.plannedStart):"Límite"}</strong><span>${a.plannedStart?timeOnly(a.plannedStart):fmt.day(a.dueAt)}</span></div><div class="agenda-main"><strong>${fmt.escape(a.title)}</strong><small>${fmt.escape(a.catalogName||fmt.label(a.kind))}</small></div></article>`}

function catalogHtml(catalog,disabled){
  const activities=catalog.filter(c=>c.activityKind==="ACTIVITY");
  if(!activities.length)return empty("Sin actividades habilitadas","Solicita al administrador revisar el catálogo de tu rol.");
  const grouped=Object.groupBy?Object.groupBy(activities,x=>x.activityGroup):activities.reduce((acc,x)=>((acc[x.activityGroup]??=[]).push(x),acc),{});
  return Object.entries(grouped).map(([group,items])=>`<div class="work-catalog-group"><div class="work-catalog-title">${fmt.escape(GROUP_LABELS[group]||fmt.label(group))}</div><div class="work-catalog-list">${items.map(c=>`<button class="work-catalog-item" data-start-catalog="${fmt.escape(c.id)}" ${disabled?"disabled":""}><span class="work-catalog-icon">${activityGlyph(c.code)}</span><span><strong>${fmt.escape(c.name)}</strong><small>${fmt.number(c.medianMinutes||c.standardMinutes||0)} min ${c.samples>=5?"mediana histórica":"referencia"} · ${evidenceLabel(c.evidencePolicy)}</small></span><b>›</b></button>`).join("")}</div></div>`).join("");
}

function historyHtml(rows){
  if(!rows.length)return empty("Aún no has registrado actividades hoy","Cuando finalices una actividad aparecerá aquí.");
  return `<div class="work-history-list">${rows.map(row=>{
    const evidencePending=row.status==="WAITING_EVIDENCE";
    const reviewPending=row.status==="SUBMITTED";
    return `<article class="work-history-row">
      <div class="work-history-time"><strong>${timeOnly(row.startedAt)}</strong><span>${row.endedAt?timeOnly(row.endedAt):"En curso"}</span></div>
      <div class="work-history-main"><div>${statusBadge(row.status)}</div><strong>${fmt.escape(row.title)}</strong><small>${fmt.hours(row.activeSeconds)} activas · ${fmt.hours(row.pausedSeconds)} pausa · ${fmt.escape(GROUP_LABELS[row.activityGroup]||fmt.label(row.activityGroup))}</small></div>
      <div class="work-history-actions">${evidencePending?`<button class="btn btn-primary" data-add-evidence="${fmt.escape(row.id)}" data-policy="${fmt.escape(row.evidencePolicy||"")}" data-title="${fmt.escape(row.title)}">Anexar evidencia</button>`:reviewPending?'<span class="work-awaiting-review">En revisión</span>':(row.evidence||[]).length?`<span class="work-evidence-count">${row.evidence.length} evidencia(s)</span>`:""}</div>
    </article>`;
  }).join("")}</div>`;
}

function bindTodayActions(content,data){
  content.querySelectorAll("[data-start-catalog]").forEach(button=>button.onclick=async()=>{
    button.disabled=true;
    try{await api.workStart(button.dataset.startCatalog,null,{});toast("Actividad iniciada.");await rerenderWorkforceContent(content)}catch(error){toast(error.message,"error",7000);button.disabled=false}
  });
  content.querySelectorAll("[data-start-assignment]").forEach(button=>button.onclick=async()=>{
    button.disabled=true;
    try{await api.workStart(button.dataset.catalogId,button.dataset.startAssignment,{});toast("Actividad programada iniciada.");window.dispatchEvent(new CustomEvent("erp:refresh-workforce"));await rerenderWorkforceContent(content)}catch(error){toast(error.message,"error",7000);button.disabled=false}
  });
  content.querySelector("[data-work-pause]")?.addEventListener("click",()=>pauseDialog(data.active,content));
  content.querySelector("[data-work-resume]")?.addEventListener("click",async event=>{const button=event.currentTarget;button.disabled=true;try{await api.workResume(data.active.id);toast("Actividad reanudada.");await rerenderWorkforceContent(content)}catch(error){toast(error.message,"error");button.disabled=false}});
  content.querySelector("[data-work-finish]")?.addEventListener("click",()=>finishDialog(data.active,content));
  content.querySelector("[data-work-before-photo]")?.addEventListener("click",()=>photoPicker(data.active,"BEFORE_PHOTO",content));
  content.querySelectorAll("[data-add-evidence]").forEach(button=>button.onclick=()=>evidenceDialog({id:button.dataset.addEvidence,evidencePolicy:button.dataset.policy,title:button.dataset.title},content));
}

async function rerenderWorkforceContent(content){
  const page=content.closest("#page-content");
  if(!page)return location.reload();
  const root=page;
  await renderCurrent(root);
}

function pauseDialog(active,content){
  modal({title:"Pausar actividad",confirmLabel:"Pausar",body:`<div class="form-grid"><div class="field"><label>Motivo de la pausa</label><select class="control" name="reason">${Object.entries(PAUSE_REASONS).map(([value,label])=>`<option value="${value}">${fmt.escape(label)}</option>`).join("")}</select></div><div class="field full"><label>Nota opcional</label><textarea class="control" name="note" rows="3" placeholder="Contexto breve de la pausa"></textarea></div></div>`,onConfirm:async dialog=>{await api.workPause(active.id,dialog.querySelector('[name="reason"]').value,dialog.querySelector('[name="note"]').value);toast("Actividad pausada.");await rerenderWorkforceContent(content)}});
}

function finishDialog(active,content){
  modal({title:"Finalizar actividad",confirmLabel:"Finalizar cronómetro",body:`<div class="work-finish-summary"><strong>${fmt.escape(active.title)}</strong><span>Tiempo actual: <b>${clock(active.metrics?.elapsedSeconds||0)}</b></span></div><div class="form-grid"><div class="field"><label>Causa de desviación, si aplica</label><select class="control" name="deviationReason">${Object.entries(DEVIATION_REASONS).map(([value,label])=>`<option value="${value}">${fmt.escape(label)}</option>`).join("")}</select></div><div class="field full"><label>Resultado / observación</label><textarea class="control" name="resultNote" rows="3" placeholder="¿Qué quedó realizado?"></textarea></div></div><div class="wizard-tip">El cronómetro se detiene ahora. Si la actividad exige evidencia, quedará pendiente hasta anexarla.</div>`,onConfirm:async dialog=>{const result=await api.workFinish(active.id,{deviationReason:dialog.querySelector('[name="deviationReason"]').value||null,resultNote:dialog.querySelector('[name="resultNote"]').value||null});toast(result.completion?.status==="WAITING_EVIDENCE"?"Tiempo guardado. Falta anexar la evidencia.":result.completion?.status==="SUBMITTED"?"Entregable enviado a revisión.":"Actividad completada.");await rerenderWorkforceContent(content)}});
}

function photoPicker(execution,type,content){
  const input=document.createElement("input");input.type="file";input.accept="image/*";input.capture="environment";
  input.onchange=async()=>{const file=input.files?.[0];if(!file)return;try{toast("Cargando evidencia…","success",2500);await uploadWorkEvidence(execution.id,file,type,execution.title);toast("Evidencia guardada.");await rerenderWorkforceContent(content)}catch(error){toast(error.message,"error",8000)}};
  input.click();
}

function evidenceDialog(execution,content){
  const policy=execution.evidencePolicy;
  if(policy==="FINAL_PHOTO")return photoPicker(execution,"FINAL_PHOTO",content);
  if(policy==="BEFORE_AFTER"){
    const dialog=modal({title:"Completar evidencia",confirmLabel:"Cerrar",body:`<div class="evidence-choice"><button type="button" class="work-evidence-choice" data-evidence-type="BEFORE_PHOTO"><strong>Foto inicial</strong><span>Estado antes de la actividad</span></button><button type="button" class="work-evidence-choice" data-evidence-type="AFTER_PHOTO"><strong>Foto final</strong><span>Resultado después de la actividad</span></button></div>`,onConfirm:async()=>{}});
    dialog.root.querySelectorAll("[data-evidence-type]").forEach(button=>button.onclick=()=>{dialog.close();photoPicker(execution,button.dataset.evidenceType,content)});
    return;
  }
  if(policy==="LINK"||policy==="ERP_REFERENCE"){
    modal({title:policy==="LINK"?"Anexar enlace":"Anexar referencia ERP",confirmLabel:"Guardar evidencia",body:`<div class="field"><label>${policy==="LINK"?"Enlace":"Referencia"}</label><input class="control" name="value" required placeholder="${policy==="LINK"?"https://…":"Pedido, informe o registro relacionado"}"></div><div class="field"><label>Nota opcional</label><textarea class="control" name="note" rows="3"></textarea></div>`,onConfirm:async dialog=>{await api.workRegisterEvidence(execution.id,{evidenceType:policy,externalValue:dialog.querySelector('[name="value"]').value,note:dialog.querySelector('[name="note"]').value});toast("Evidencia registrada.");await rerenderWorkforceContent(content)}});return;
  }
  const input=document.createElement("input");input.type="file";input.accept=policy==="FILE"?"*/*":"image/*";
  input.onchange=async()=>{const file=input.files?.[0];if(!file)return;try{await uploadWorkEvidence(execution.id,file,policy==="FILE"?"FILE":"FINAL_PHOTO",execution.title);toast("Evidencia guardada.");await rerenderWorkforceContent(content)}catch(error){toast(error.message,"error",8000)}};input.click();
}

function startLiveClock(content,active){
  clearInterval(liveTimer);if(!active||active.status==="PAUSED")return;
  const target=content.querySelector("[data-live-clock]");if(!target)return;
  const started=new Date(active.startedAt).getTime();
  liveTimer=setInterval(()=>{target.textContent=clock(Math.max(0,Math.floor((Date.now()-started)/1000)))},1000);
}

// ---------------------------------------------------------------------------
// PLANIFICACIÓN
// ---------------------------------------------------------------------------
async function renderPlanner(root,content){
  const range=plannerRange();
  const data=await api.workPlanner(range.from,range.to);
  const catalog=await api.workCatalog();
  content.innerHTML=`
    <section class="work-planner-toolbar card">
      <div class="work-planner-nav"><button class="icon-btn" data-plan-prev aria-label="Anterior">‹</button><button class="btn btn-ghost" data-plan-today>Hoy</button><button class="icon-btn" data-plan-next aria-label="Siguiente">›</button><div><strong>${fmt.escape(plannerTitle())}</strong><span>${plannerMode==="week"?"Distribución semanal de capacidad":"Panorama mensual de compromisos"}</span></div></div>
      <div class="work-planner-actions"><div class="segment-control"><button class="${plannerMode==="week"?"active":""}" data-plan-mode="week">Semana</button><button class="${plannerMode==="month"?"active":""}" data-plan-mode="month">Mes</button></div><button class="btn btn-primary" data-plan-new>Asignar actividad</button></div>
    </section>
    ${plannerMode==="week"?weekPlannerHtml(data):monthPlannerHtml(data)}
    <section class="card work-team-now"><header class="card-head"><div><h3>Capacidad del equipo</h3><p>La carga se calcula con los minutos planificados; no es un ranking de personas.</p></div></header><div class="card-body">${teamCapacityHtml(data.people||[],data.assignments||[],range)}</div></section>`;
  content.querySelector("[data-plan-prev]").onclick=()=>{plannerAnchor=plannerMode==="week"?addDays(plannerAnchor,-7):addMonths(plannerAnchor,-1);renderPlanner(root,content)};
  content.querySelector("[data-plan-next]").onclick=()=>{plannerAnchor=plannerMode==="week"?addDays(plannerAnchor,7):addMonths(plannerAnchor,1);renderPlanner(root,content)};
  content.querySelector("[data-plan-today]").onclick=()=>{plannerAnchor=plannerMode==="week"?startOfWeek(new Date()):new Date(new Date().getFullYear(),new Date().getMonth(),1);renderPlanner(root,content)};
  content.querySelectorAll("[data-plan-mode]").forEach(button=>button.onclick=()=>{plannerMode=button.dataset.planMode;plannerAnchor=plannerMode==="week"?startOfWeek(plannerAnchor):new Date(plannerAnchor.getFullYear(),plannerAnchor.getMonth(),1);renderPlanner(root,content)});
  content.querySelector("[data-plan-new]").onclick=()=>assignmentWizard(data,catalog,()=>renderPlanner(root,content));
  content.querySelectorAll("[data-plan-day]").forEach(button=>button.onclick=()=>assignmentWizard(data,catalog,()=>renderPlanner(root,content),button.dataset.planDay));
  content.querySelectorAll("[data-assignment-cancel]").forEach(button=>button.onclick=()=>cancelAssignmentDialog(button.dataset.assignmentCancel,()=>renderPlanner(root,content)));
}

function weekPlannerHtml(data){
  const days=[...Array(7).keys()].map(i=>addDays(startOfWeek(plannerAnchor),i));
  const byProfile=new Map((data.people||[]).map(p=>[p.id,p]));
  return `<section class="work-week-board card"><div class="work-week-grid"><div class="work-week-corner">Equipo</div>${days.map(d=>`<button class="work-week-day ${isToday(d)?"today":""}" data-plan-day="${isoDate(d)}"><strong>${weekdayShort(d)}</strong><span>${d.getDate()} ${monthShort(d)}</span></button>`).join("")}${[...(data.people||[])].map(person=>`<div class="work-week-person"><span class="avatar">${fmt.initials(person.name)}</span><div><strong>${fmt.escape(person.name)}</strong><small>${fmt.escape((person.roles||[]).map(r=>fmt.role(r)).join(" · "))}</small></div></div>${days.map(day=>`<div class="work-week-cell ${isToday(day)?"today":""}">${assignmentsForDay(data.assignments||[],person.id,day).map(assignmentBlock).join("")||'<span class="work-cell-empty">Disponible</span>'}</div>`).join("")}`).join("")}</div></section>`;
}

function monthPlannerHtml(data){
  const first=new Date(plannerAnchor.getFullYear(),plannerAnchor.getMonth(),1);const start=startOfWeek(first);const cells=[...Array(42).keys()].map(i=>addDays(start,i));
  return `<section class="work-month-board card"><div class="work-month-weekdays">${["Lun","Mar","Mié","Jue","Vie","Sáb","Dom"].map(x=>`<span>${x}</span>`).join("")}</div><div class="work-month-grid">${cells.map(day=>{const rows=(data.assignments||[]).filter(a=>sameDate(new Date(a.plannedStart||a.dueAt),day));return `<button class="work-month-day ${day.getMonth()!==first.getMonth()?"outside":""} ${isToday(day)?"today":""}" data-plan-day="${isoDate(day)}"><span class="work-month-number">${day.getDate()}</span><div class="work-month-items">${rows.slice(0,4).map(a=>`<span class="work-month-item ${a.kind==="DELIVERABLE"?"deliverable":""}"><b>${a.plannedStart?timeOnly(a.plannedStart):"Límite"}</b> ${fmt.escape(a.title)} · ${fmt.escape(firstName(a.profileName))}</span>`).join("")}${rows.length>4?`<small>+${rows.length-4} más</small>`:""}</div></button>`}).join("")}</div></section>`;
}

function assignmentBlock(a){return `<article class="work-assignment-block ${a.kind==="DELIVERABLE"?"deliverable":""} priority-${String(a.priority||"MEDIUM").toLowerCase()}"><div><strong>${a.plannedStart?timeOnly(a.plannedStart):"Entregable"}</strong><span>${a.plannedEnd?`– ${timeOnly(a.plannedEnd)}`:a.dueAt?`vence ${timeOnly(a.dueAt)}`:""}</span></div><b>${fmt.escape(a.title)}</b><small>${fmt.number(a.estimatedMinutes)} min · ${fmt.label(a.memberStatus)}</small><button class="work-assignment-menu" data-assignment-cancel="${fmt.escape(a.id)}" title="Cancelar asignación" aria-label="Cancelar asignación">×</button></article>`}

function teamCapacityHtml(people,assignments,range){
  if(!people.length)return empty("Sin equipo disponible","No hay perfiles dentro de tu ámbito de planificación.");
  const businessDays=countBusinessDays(range.from,range.to);const capacity=Math.max(1,businessDays*510);
  return `<div class="work-capacity-list">${people.map(p=>{const planned=assignments.filter(a=>a.profileId===p.id).reduce((s,a)=>s+Number(a.estimatedMinutes||0),0);const pct=Math.round(100*planned/capacity);return `<article class="work-capacity-row"><div><span class="avatar">${fmt.initials(p.name)}</span><div><strong>${fmt.escape(p.name)}</strong><small>${p.activeTitle?`Ahora: ${fmt.escape(p.activeTitle)}`:`${fmt.number(planned)} min planificados`}</small></div></div><div class="capacity-meter"><span style="width:${Math.min(pct,100)}%"></span></div><b class="${pct>100?"danger":pct>85?"warning":""}">${pct}%</b></article>`}).join("")}</div>`;
}

function assignmentWizard(data,catalog,reload,prefillDay=null){
  const permissions=data.permissions||{};
  const kinds=[];if(permissions.logistics)kinds.push(["ACTIVITY","Actividad de equipo"]);if(permissions.deliverables)kinds.push(["DELIVERABLE","Entregable de gestión"]);
  const defaultKind=kinds[0]?.[0]||"ACTIVITY";
  const day=prefillDay||isoDate(new Date());
  const people=data.people||[];
  wizard({title:"Asignar trabajo",subtitle:"Planifica capacidad o define un entregable con fecha límite y evidencia.",finishLabel:"Publicar asignación",size:"wide",steps:[
    {title:"Qué se necesita",description:"Selecciona el tipo, actividad y resultado esperado.",content:`<div class="form-grid"><div class="field"><label>Tipo *</label><select class="control" name="kind" required>${kinds.map(([v,l])=>`<option value="${v}">${l}</option>`).join("")}</select></div><div class="field"><label>Actividad / plantilla *</label><select class="control" name="catalogId" required></select></div><div class="field full"><label>Título *</label><input class="control" name="title" required placeholder="Ej. Organizar zona de cables o entregar análisis de cartera"></div><div class="field full"><label>Descripción / resultado esperado</label><textarea class="control" name="description" rows="3"></textarea></div></div>`,onEnter:({form})=>{const kind=form.kind.value||defaultKind;fillCatalogSelect(form.catalogId,catalog,kind);const sync=()=>{fillCatalogSelect(form.catalogId,catalog,form.kind.value);};form.kind.onchange=sync;form.catalogId.onchange=()=>{const c=catalog.find(x=>x.id===form.catalogId.value);if(c&&!form.title.value)form.title.value=c.name}}},
    {title:"A quién",description:"Puedes asignar una actividad logística al equipo completo; el esfuerzo se medirá por persona-hora.",content:`<div class="work-assignee-picker">${people.map(p=>`<label class="work-person-choice" data-person-kind><input type="checkbox" name="profileId" value="${fmt.escape(p.id)}"><span class="avatar">${fmt.initials(p.name)}</span><span><strong>${fmt.escape(p.name)}</strong><small>${fmt.escape((p.roles||[]).map(r=>fmt.role(r)).join(" · "))}</small></span><b>${p.activeTitle?"Ocupado ahora":`${fmt.number(p.plannedMinutes7d)} min / 7d`}</b></label>`).join("")}</div>`,onEnter:({form})=>{const kind=form.kind.value;form.querySelectorAll('[data-person-kind]').forEach(label=>{const p=people.find(x=>x.id===label.querySelector('input').value);const allowed=kind==="ACTIVITY"?(p.roles||[]).some(r=>["jefe_logistica","coordinador_logistico","aux_logistica","auxiliar_corte","recepcion_mercancia","despacho_nacional"].includes(r)):((p.roles||[]).some(r=>["ventas","jefe_logistica","compras","cartera"].includes(r)));label.hidden=!permissions.all&&!allowed;if(label.hidden)label.querySelector('input').checked=false})},validate:({form})=>{if(!form.querySelector('[name="profileId"]:checked'))throw new Error("Selecciona al menos una persona.");return true}},
    {title:"Cuándo",description:"Las actividades usan horario; los entregables además tienen fecha límite.",content:`<div class="form-grid"><div class="field"><label>Inicio</label><input class="control" type="datetime-local" name="plannedStart" value="${day}T08:00"></div><div class="field"><label>Finalización planificada</label><input class="control" type="datetime-local" name="plannedEnd" value="${day}T09:00"></div><div class="field"><label>Fecha límite</label><input class="control" type="datetime-local" name="dueAt" value="${day}T17:30"></div><div class="field"><label>Duración estimada (min) *</label><input class="control" type="number" min="1" max="1440" name="estimatedMinutes" value="60" required></div><div class="field"><label>Repetir</label><select class="control" name="frequency"><option value="NONE">No repetir</option><option value="DAILY">Cada día</option><option value="WEEKLY">Cada semana</option><option value="MONTHLY">Cada mes</option></select></div><div class="field"><label>Repetir hasta</label><input class="control" type="date" name="repeatUntil"></div></div><div class="wizard-tip">Si existe otro bloque en el mismo horario, el ERP lo advertirá antes de crear la asignación.</div>`,onEnter:({form})=>{const kind=form.kind.value;form.dueAt.required=kind==="DELIVERABLE";form.plannedStart.required=kind==="ACTIVITY";form.plannedEnd.required=kind==="ACTIVITY";const c=catalog.find(x=>x.id===form.catalogId.value);if(c&&c.standardMinutes)form.estimatedMinutes.value=c.medianMinutes&&c.samples>=5?Math.round(c.medianMinutes):c.standardMinutes;form.frequency.onchange=()=>{form.repeatUntil.required=form.frequency.value!=="NONE"}}},
    {title:"Evidencia y control",description:"Define qué debe quedar demostrado al terminar.",content:`<div class="form-grid"><div class="field"><label>Evidencia *</label><select class="control" name="evidencePolicy"><option value="NONE">Sin evidencia</option><option value="FINAL_PHOTO">Foto final</option><option value="BEFORE_AFTER">Foto antes + después</option><option value="FILE">Archivo</option><option value="LINK">Enlace</option><option value="ERP_REFERENCE">Referencia ERP</option></select></div><div class="field"><label>Prioridad</label><select class="control" name="priority"><option>MEDIUM</option><option>HIGH</option><option>URGENT</option><option>CRITICAL</option><option>LOW</option></select></div><label class="status-choice full"><input type="checkbox" name="acceptanceRequired"><span><strong>Requiere aceptación final</strong><small>El trabajo queda “En revisión” hasta que el responsable lo acepte. Se recomienda para entregables de Gerencia.</small></span></label></div>`,onEnter:({form})=>{const c=catalog.find(x=>x.id===form.catalogId.value);if(c)form.evidencePolicy.value=c.evidencePolicy||"NONE";form.acceptanceRequired.checked=form.kind.value==="DELIVERABLE"||(c?.acceptanceRequired===true)}},
    {title:"Revisión",description:"Publica la asignación. Si hay un choque real de horario, podrás confirmarlo conscientemente.",content:`<div class="wizard-summary work-assignment-review"><div class="wizard-summary-item"><label>Trabajo</label><strong data-review-title>—</strong></div><div class="wizard-summary-item"><label>Personas</label><strong data-review-people>—</strong></div><div class="wizard-summary-item"><label>Horario</label><strong data-review-time>—</strong></div><div class="wizard-summary-item"><label>Evidencia</label><strong data-review-evidence>—</strong></div></div><label class="status-choice"><input type="checkbox" name="force"><span><strong>Permitir superposición solo si el ERP detecta conflicto</strong><small>Úsalo únicamente cuando la actividad deba coexistir deliberadamente con otro bloque.</small></span></label>`,onEnter:({root,form})=>{root.querySelector('[data-review-title]').textContent=form.title.value;root.querySelector('[data-review-people]').textContent=[...form.querySelectorAll('[name="profileId"]:checked')].map(i=>people.find(p=>p.id===i.value)?.name||"").join(" · ");root.querySelector('[data-review-time]').textContent=form.kind.value==="DELIVERABLE"?`Vence ${form.dueAt.value||"—"}`:`${form.plannedStart.value||"—"} → ${form.plannedEnd.value||"—"}`;root.querySelector('[data-review-evidence]').textContent=evidenceLabel(form.evidencePolicy.value)}}
  ],onFinish:async({form})=>{
    const payload={kind:form.kind.value,catalogId:form.catalogId.value,title:form.title.value,description:form.description.value||null,profileIds:[...form.querySelectorAll('[name="profileId"]:checked')].map(i=>i.value),plannedStart:form.plannedStart.value?new Date(form.plannedStart.value).toISOString():null,plannedEnd:form.plannedEnd.value?new Date(form.plannedEnd.value).toISOString():null,dueAt:form.dueAt.value?new Date(form.dueAt.value).toISOString():null,estimatedMinutes:Number(form.estimatedMinutes.value),evidencePolicy:form.evidencePolicy.value,acceptanceRequired:form.acceptanceRequired.checked,priority:form.priority.value,force:form.force.checked,recurrence:{frequency:form.frequency.value,until:form.repeatUntil.value||null}};
    const result=await api.workSaveAssignment(payload);
    if(!result.success){const details=[...new Set((result.conflicts||[]).map(x=>x.message).filter(Boolean))].slice(0,2).join(" · ");throw new Error(`Hay ${result.conflicts?.length||1} conflicto(s) de planificación${details?`: ${details}`:""}. Regresa a Revisión y autoriza la excepción solo si realmente corresponde.`)}
    toast(result.createdIds?.length>1?`${result.createdIds.length} actividades programadas.`:"Actividad asignada.");await reload();
  }});
}

function fillCatalogSelect(select,catalog,kind){
  const rows=catalog.filter(c=>c.activityKind===kind);select.innerHTML=rows.map(c=>`<option value="${fmt.escape(c.id)}">${fmt.escape(c.name)} · ${fmt.number(c.medianMinutes&&c.samples>=5?c.medianMinutes:c.standardMinutes||0)} min</option>`).join("");
}

function cancelAssignmentDialog(id,reload){modal({title:"Cancelar asignación",confirmLabel:"Cancelar actividad",body:`<div class="field"><label>Motivo</label><textarea class="control" name="note" rows="3" placeholder="Explica por qué deja de realizarse"></textarea></div>`,onConfirm:async dialog=>{await api.workCancelAssignment(id,dialog.querySelector('[name="note"]').value||null);toast("Asignación cancelada.");await reload()}})}

// ---------------------------------------------------------------------------
// ANALÍTICA
// ---------------------------------------------------------------------------
async function renderAnalytics(root,content){
  const canManage=state.profile?.roles?.some(r=>["super_admin","gerencia","jefe_logistica","auditoria"].includes(r));
  const people=canManage?await api.workPeople(null).catch(()=>[]):[];
  const selected=content.dataset.analyticsProfile||"";
  const data=await api.workAnalytics(analyticsRange.from,analyticsRange.to,selected||null);
  content.innerHTML=`
    <section class="card work-analytics-toolbar"><div class="form-grid"><div class="field"><label>Desde</label><input class="control" type="date" data-analytics-from value="${analyticsRange.from}"></div><div class="field"><label>Hasta</label><input class="control" type="date" data-analytics-to value="${analyticsRange.to}"></div>${canManage?`<div class="field"><label>Persona / equipo</label><select class="control" data-analytics-profile><option value="">Mi ámbito completo</option>${people.map(p=>`<option value="${fmt.escape(p.id)}" ${selected===p.id?"selected":""}>${fmt.escape(p.name)}</option>`).join("")}</select></div>`:""}<div class="field analytics-apply"><label>&nbsp;</label><button class="btn btn-primary" data-analytics-apply>Aplicar</button></div></div></section>
    ${analyticsSummary(data.summary)}
    <div class="grid grid-2 work-analytics-grid">
      <section class="card"><header class="card-head"><div><h3>Distribución del trabajo adicional</h3><p>Tiempo activo por familia de actividad.</p></div></header><div class="card-body">${barList(data.activityGroups||[],x=>GROUP_LABELS[x.group]||fmt.label(x.group),x=>x.activeSeconds)}</div></section>
      <section class="card"><header class="card-head"><div><h3>Tiempos de referencia aprendidos</h3><p>Mediana y percentil 80 a partir de ejecuciones reales.</p></div></header><div class="card-body">${activityStandardsHtml(data.topActivities||[])}</div></section>
      <section class="card"><header class="card-head"><div><h3>Causas de desviación</h3><p>Pareto de razones registradas cuando una actividad tomó más o menos de lo esperado.</p></div></header><div class="card-body">${causeList(data.deviationCauses||[])}</div></section>
      <section class="card"><header class="card-head"><div><h3>Equipo ahora</h3><p>Quién tiene una actividad adicional en ejecución. Los procesos ERP siguen visibles en sus propias colas.</p></div></header><div class="card-body">${teamNowHtml(data.teamNow||[])}</div></section>
    </div>
    ${data.pendingReviews?.length?`<section class="card work-review-card"><header class="card-head"><div><h3>Entregables pendientes de revisión</h3><p>Aceptar confirma el resultado; devolver exige una nota para corrección.</p></div></header><div class="card-body">${pendingReviewsHtml(data.pendingReviews)}</div></section>`:""}
    <section class="work-ethics-note"><strong>Cómo leer estos indicadores</strong><span>Utilización, puntualidad y duración describen procesos y capacidad; no constituyen por sí solos una calificación de desempeño. El ERP conserva tiempo no clasificado como “sin categoría”, no como improductividad.</span></section>`;
  content.querySelector("[data-analytics-apply]").onclick=()=>{analyticsRange={from:content.querySelector('[data-analytics-from]').value,to:content.querySelector('[data-analytics-to]').value};content.dataset.analyticsProfile=content.querySelector('[data-analytics-profile]')?.value||"";renderAnalytics(root,content)};
  content.querySelectorAll("[data-review-accept]").forEach(button=>button.onclick=()=>reviewDelivery(button.dataset.reviewAccept,"ACCEPTED",content,root));
  content.querySelectorAll("[data-review-return]").forEach(button=>button.onclick=()=>reviewDelivery(button.dataset.reviewReturn,"RETURNED",content,root));
}

function analyticsSummary(s={}){return `<section class="workforce-summary-grid analytics"><article class="workforce-summary-card"><span>Jornada clasificada</span><strong>${fmt.number(s.utilizationPct,1)}%</strong><small>${fmt.hours(s.classifiedBusinessSeconds)} de ${fmt.hours(s.scheduledBusinessSeconds)}</small></article><article class="workforce-summary-card"><span>Tiempo sin categoría</span><strong>${fmt.hours(s.unclassifiedBusinessSeconds)}</strong><small>No se interpreta automáticamente como improductivo</small></article><article class="workforce-summary-card"><span>Cumplimiento de fecha</span><strong>${fmt.number(s.onTimePct,1)}%</strong><small>Asignaciones terminadas dentro del compromiso</small></article><article class="workforce-summary-card"><span>Inicio según plan</span><strong>${fmt.number(s.startAdherencePct,1)}%</strong><small>Inicio dentro de ±5 min del bloque programado</small></article></section>`}
function barList(rows,label,value){if(!rows.length)return empty("Sin datos","Todavía no existen ejecuciones para el periodo.");const max=Math.max(...rows.map(value),1);return `<div class="work-bar-list">${rows.map(r=>`<div class="work-bar-row"><div><strong>${fmt.escape(label(r))}</strong><span>${fmt.hours(value(r))} · ${fmt.number(r.executions)} ejecución(es)</span></div><div class="work-bar-track"><span style="width:${Math.max(3,100*value(r)/max)}%"></span></div></div>`).join("")}</div>`}
function activityStandardsHtml(rows){if(!rows.length)return empty("Sin estándar aprendido","Con cinco o más ejecuciones, el ERP empieza a mostrar referencias históricas.");return `<div class="work-standard-list">${rows.map(r=>`<article><div><strong>${fmt.escape(r.name)}</strong><span>${fmt.escape(GROUP_LABELS[r.group]||fmt.label(r.group))} · ${fmt.number(r.executions)} muestras</span></div><div><b>${fmt.number(r.medianMinutes,1)} min</b><small>mediana</small></div><div><b>${fmt.number(r.p80Minutes,1)} min</b><small>P80</small></div></article>`).join("")}</div>`}
function causeList(rows){if(!rows.length)return empty("Sin causas registradas","Las causas aparecerán cuando el equipo las indique al finalizar una actividad.");return `<div class="work-cause-list">${rows.map(r=>`<article><strong>${fmt.escape(DEVIATION_REASONS[r.reason]||fmt.label(r.reason))}</strong><span>${fmt.number(r.executions)} caso(s)</span><b>${fmt.hours(r.activeSeconds)}</b></article>`).join("")}</div>`}
function teamNowHtml(rows){if(!rows.length)return empty("Sin actividades adicionales activas","El equipo puede estar trabajando en procesos ERP normales o sin una actividad adicional iniciada.");return `<div class="team-now-list">${rows.map(r=>`<article><span class="avatar">${fmt.initials(r.profileName)}</span><div><strong>${fmt.escape(r.profileName)}</strong><small>${fmt.escape(r.title)} · desde ${timeOnly(r.startedAt)}</small></div>${statusBadge(r.status)}</article>`).join("")}</div>`}
function pendingReviewsHtml(rows){return `<div class="work-review-list">${rows.map(r=>`<article><div><strong>${fmt.escape(r.title)}</strong><span>${fmt.escape(r.profileName)} · ${r.dueAt?`vencía ${fmt.date(r.dueAt)}`:"sin fecha"}</span><small>${fmt.escape(r.resultNote||"Sin nota de resultado")}</small></div><div class="work-review-evidence">${(r.evidence||[]).map(e=>e.webViewLink?`<a href="${fmt.escape(e.webViewLink)}" target="_blank" rel="noopener">${fmt.escape(e.fileName||fmt.label(e.type))}</a>`:`<span>${fmt.escape(e.value||fmt.label(e.type))}</span>`).join("")}</div><div class="work-review-actions"><button class="btn btn-ghost" data-review-return="${fmt.escape(r.executionId)}">Devolver</button><button class="btn btn-primary" data-review-accept="${fmt.escape(r.executionId)}">Aceptar</button></div></article>`).join("")}</div>`}
function reviewDelivery(id,decision,content,root){modal({title:decision==="ACCEPTED"?"Aceptar entregable":"Devolver entregable",confirmLabel:decision==="ACCEPTED"?"Aceptar resultado":"Devolver para corrección",body:`<div class="field"><label>${decision==="RETURNED"?"Qué debe corregirse *":"Nota opcional"}</label><textarea class="control" name="note" rows="4" ${decision==="RETURNED"?"required":""}></textarea></div>`,onConfirm:async dialog=>{await api.workReviewDelivery(id,decision,dialog.querySelector('[name="note"]').value||null);toast(decision==="ACCEPTED"?"Entregable aceptado.":"Entregable devuelto para corrección.");await renderAnalytics(root,content)}})}

// ---------------------------------------------------------------------------
// HELPERS
// ---------------------------------------------------------------------------
function plannerRange(){if(plannerMode==="week"){const start=startOfWeek(plannerAnchor);return {from:isoDate(start),to:isoDate(addDays(start,6))}}const start=new Date(plannerAnchor.getFullYear(),plannerAnchor.getMonth(),1),end=new Date(plannerAnchor.getFullYear(),plannerAnchor.getMonth()+1,0);return {from:isoDate(startOfWeek(start)),to:isoDate(addDays(startOfWeek(end),6))}}
function plannerTitle(){if(plannerMode==="week"){const s=startOfWeek(plannerAnchor),e=addDays(s,6);return `${s.getDate()} ${monthShort(s)} – ${e.getDate()} ${monthShort(e)} ${e.getFullYear()}`}return new Intl.DateTimeFormat("es-CO",{month:"long",year:"numeric"}).format(plannerAnchor).replace(/^./,c=>c.toUpperCase())}
function assignmentsForDay(rows,profileId,day){return rows.filter(a=>a.profileId===profileId&&sameDate(new Date(a.plannedStart||a.dueAt),day)).sort((a,b)=>new Date(a.plannedStart||a.dueAt)-new Date(b.plannedStart||b.dueAt))}
function evidenceLabel(policy){return ({NONE:"sin evidencia",FINAL_PHOTO:"foto final",BEFORE_AFTER:"antes + después",FILE:"archivo",LINK:"enlace",ERP_REFERENCE:"referencia ERP"})[policy]||fmt.label(policy)}
function activityGlyph(code=""){if(code.includes("CLEAN"))return"✦";if(code.includes("LOADING"))return"↑";if(code.includes("UNLOADING"))return"↓";if(code.includes("COUNT"))return"#";if(code.includes("ORGANIZE")||code.includes("RELOCATION"))return"▦";if(code.includes("TRAIN"))return"△";if(code.includes("IMPROVEMENT"))return"↗";return"●"}
function clock(seconds){const n=Math.max(0,Math.floor(Number(seconds||0))),h=Math.floor(n/3600),m=Math.floor((n%3600)/60),s=n%60;return [h,m,s].map(x=>String(x).padStart(2,"0")).join(":")}
function isoDate(d){const date=new Date(d);const y=date.getFullYear(),m=String(date.getMonth()+1).padStart(2,"0"),day=String(date.getDate()).padStart(2,"0");return `${y}-${m}-${day}`}
function addDays(d,n){const x=new Date(d);x.setDate(x.getDate()+n);return x}
function addMonths(d,n){const x=new Date(d);x.setMonth(x.getMonth()+n);return x}
function startOfWeek(d){const x=new Date(d);x.setHours(0,0,0,0);const day=(x.getDay()+6)%7;x.setDate(x.getDate()-day);return x}
function sameDate(a,b){return a.getFullYear()===b.getFullYear()&&a.getMonth()===b.getMonth()&&a.getDate()===b.getDate()}
function isToday(d){return sameDate(new Date(),new Date(d))}
function timeOnly(value){if(!value)return"—";return new Intl.DateTimeFormat("es-CO",{hour:"2-digit",minute:"2-digit",hour12:false,timeZone:"America/Bogota"}).format(new Date(value))}
function weekdayShort(value){return new Intl.DateTimeFormat("es-CO",{weekday:"short",timeZone:"America/Bogota"}).format(new Date(value)).replace(".","").replace(/^./,c=>c.toUpperCase())}
function monthShort(value){return new Intl.DateTimeFormat("es-CO",{month:"short",timeZone:"America/Bogota"}).format(new Date(value)).replace(".","")}
function firstName(name=""){return String(name).trim().split(/\s+/)[0]||""}
function countBusinessDays(from,to){let count=0,d=new Date(`${from}T12:00:00`),end=new Date(`${to}T12:00:00`);while(d<=end){if(d.getDay()!==0&&d.getDay()!==6)count++;d=addDays(d,1)}return count}
