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
  const roles=state.profile?.roles||[];
  const canPlan=roles.some(r=>["super_admin","gerencia","jefe_logistica","lider_logistica"].includes(r));
  const canApprove=roles.some(r=>["super_admin","gerencia","jefe_logistica","lider_logistica"].includes(r));
  if(currentView==="planner"&&!canPlan)currentView="today";
  if(currentView==="approvals"&&!canApprove)currentView="today";
  root.innerHTML=`
    <section class="page-head workforce-page-head">
      <div><span class="workforce-kicker">Jornada · actividades · capacidad</span><h2>Mi jornada de trabajo</h2><p>Organiza el día, registra actividades con propósito y consulta la ocupación real entre procesos ERP y trabajo adicional.</p></div>
      <div class="page-actions"><button class="btn btn-ghost" data-work-refresh>Actualizar</button></div>
    </section>
    <nav class="workforce-tabs" aria-label="Vistas de actividades">
      <button class="workforce-tab ${currentView==="today"?"active":""}" data-work-view="today"><span>Mi jornada</span><small>Hoy</small></button>
      <button class="workforce-tab ${currentView==="planner"?"active":""}" data-work-view="planner" ${canPlan?"":"hidden"}><span>Planificación</span><small>Equipo</small></button>
      <button class="workforce-tab ${currentView==="approvals"?"active":""}" data-work-view="approvals" ${canApprove?"":"hidden"}><span>Aprobaciones</span><small>Solicitudes</small></button>
      <button class="workforce-tab ${currentView==="analytics"?"active":""}" data-work-view="analytics"><span>Ocupación</span><small>Analítica</small></button>
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
  if(currentView==="approvals")return renderApprovals(root,content);
  if(currentView==="analytics")return renderAnalytics(root,content);
  return renderToday(root,content,force);
}

async function renderToday(root,content){
  const data=await api.workMyDay();
  const plannerTab=root.querySelector('[data-work-view="planner"]');
  const approvalsTab=root.querySelector('[data-work-view="approvals"]');
  if(plannerTab)plannerTab.hidden=!data.permissions?.canViewTeam;
  if(approvalsTab)approvalsTab.hidden=!data.permissions?.canApproveActivities;
  const s=data.summary||{};
  const pending=(data.pendingRequests||[]).length;
  content.innerHTML=`
    ${activeWorkCard(data.active,data.erpActive)}
    <section class="work-occupation-strip" aria-label="Ocupación de hoy">
      ${occupationMetric("Ocupación identificada",`${fmt.number(s.occupationPct||0,1)}%`,`${fmt.hours(s.classifiedSeconds)} de ${fmt.hours(s.scheduledBusinessSeconds)}`,"total")}
      ${occupationMetric("Proceso ERP",fmt.hours(s.fixedProcessSeconds),"Pedidos, Corte y procesos fijos del rol","fixed")}
      ${occupationMetric("Actividades varias",fmt.hours(s.miscActivitySeconds),"Trabajo adicional ejecutado y evidenciado","misc")}
      ${occupationMetric("Sin clasificar",fmt.hours(s.unclassifiedSeconds),"Tiempo todavía sin una categoría operativa","neutral")}
    </section>

    <section class="work-day-command">
      <div class="work-day-command-copy"><span class="workforce-kicker">Plan personal</span><h3>¿Necesitas agregar una actividad a tu día?</h3><p>Busca la actividad, explica por qué la necesitas y define cuándo la realizarías. ${approvalRouteText(data.permissions?.approvalScope)}</p></div>
      <button class="btn btn-primary work-add-activity" data-work-propose>+ Agregar actividad</button>
    </section>

    <div class="workforce-main-grid work-day-grid">
      <section class="card workforce-agenda-card">
        <header class="card-head"><div><h3>Agenda del día</h3><p>Actividades autorizadas y listas para ejecutar en su horario.</p></div><span class="workforce-count">${(data.today||[]).length}</span></header>
        <div class="card-body workforce-agenda-list">${agendaHtml(data)}</div>
      </section>
      <section class="card workforce-request-card">
        <header class="card-head"><div><h3>Solicitudes pendientes</h3><p>Actividades que agregaste y todavía requieren autorización.</p></div><span class="workforce-count ${pending?"attention":""}">${pending}</span></header>
        <div class="card-body">${pendingRequestsHtml(data.pendingRequests||[])}${requestDecisionsHtml(data.requestHistory||[])}</div>
      </section>
    </div>

    <section class="card workforce-history-card">
      <header class="card-head"><div><h3>Actividad registrada hoy</h3><p>Tiempo activo, pausas, evidencia y resultado. Los procesos ERP se consolidan en Ocupación.</p></div></header>
      <div class="card-body">${historyHtml(data.history||[])}</div>
    </section>`;

  bindTodayActions(content,data);
  startLiveClock(content,data.active);
}

function activeWorkCard(active,erpActive=null){
  if(!active){
    return `<section class="work-now idle ${erpActive?"erp-context":""}">
      <div class="work-now-status"><span class="work-pulse"></span><div><small>${erpActive?"Proceso ERP detectado":"Estado actual"}</small><strong>${erpActive?fmt.escape(erpActive.title):"Sin actividad varias en curso"}</strong><p>${erpActive?`El trabajo fijo de tu rol ya está siendo considerado en la ocupación. ${erpActive.type==="CUTTING"?"Pausa Corte antes de iniciar otra actividad.":""}`:"Cuando tengas una actividad autorizada podrás iniciarla desde tu agenda."}</p></div></div>
      <div class="work-now-context"><span>${erpActive?"Trabajo fijo":"Disponible"}</span><strong>${erpActive?.startedAt?`Desde ${timeOnly(erpActive.startedAt)}`:"Sin cronómetro adicional"}</strong></div>
    </section>`;
  }
  const metrics=active.metrics||{};
  const paused=active.status==="PAUSED";
  const types=new Set((active.evidence||[]).map(x=>x.type));
  const needsBefore=active.evidencePolicy==="BEFORE_AFTER"&&!types.has("BEFORE_PHOTO");
  return `<section class="work-now running ${paused?"paused":""}" data-active-execution="${fmt.escape(active.id)}" data-started-at="${fmt.escape(active.startedAt)}" data-base-elapsed="${Number(metrics.elapsedSeconds||0)}" data-paused="${paused}">
    <div class="work-now-status"><span class="work-pulse"></span><div><small>${paused?"Actividad pausada":"Actividad varias en ejecución"}</small><strong>${fmt.escape(active.title)}</strong><p>${fmt.escape(active.catalogName||"")}${active.plannedStart?` · programada ${timeOnly(active.plannedStart)}`:""}</p></div></div>
    <div class="work-now-clock"><strong data-live-clock>${clock(metrics.elapsedSeconds||0)}</strong><span>${fmt.hours(metrics.businessSeconds||0)} laborales · ${fmt.hours(metrics.pausedSeconds||0)} en pausa</span></div>
    <div class="work-now-actions">
      ${needsBefore?`<button class="btn btn-ghost" data-work-before-photo>Foto inicial</button>`:""}
      ${paused?`<button class="btn btn-primary" data-work-resume>Reanudar</button>`:`<button class="btn btn-ghost" data-work-pause>Pausar</button>`}
      <button class="btn btn-primary" data-work-finish ${needsBefore?'disabled title="Toma primero la foto inicial"':""}>${needsBefore?"Foto inicial pendiente":"Finalizar actividad"}</button>
    </div>
  </section>`;
}

function occupationMetric(label,value,detail,tone="neutral"){return `<article class="work-occupation-metric ${tone}"><span>${fmt.escape(label)}</span><strong>${fmt.escape(String(value))}</strong><small>${fmt.escape(detail)}</small></article>`}
function approvalRouteText(scope){return scope==="LOGISTICS"?"La solicitud deberá ser aprobada por un Líder Logístico o Jefatura Logística antes de poder iniciar.":"La solicitud deberá ser aprobada por Gerencia antes de poder iniciar."}
function pendingRequestsHtml(rows){
  if(!rows.length)return `<div class="work-empty-compact"><span>✓</span><div><strong>Sin solicitudes pendientes</strong><small>Tu agenda no tiene actividades esperando aprobación.</small></div></div>`;
  return `<div class="work-request-list">${rows.map(r=>`<article class="work-request-row"><div class="work-request-state"><span></span><small>Por aprobar</small></div><div><strong>${fmt.escape(r.title)}</strong><span>${r.plannedStart?`${fmt.day(r.plannedStart)} · ${timeOnly(r.plannedStart)}–${timeOnly(r.plannedEnd)}`:"Sin horario"}</span><small>${fmt.escape(r.reason||"")}</small></div></article>`).join("")}</div>`;
}
function requestDecisionsHtml(rows){
  if(!rows.length)return "";
  return `<div class="work-request-decisions"><span class="work-request-decisions-title">Decisiones recientes</span>${rows.map(r=>`<article class="work-request-decision ${String(r.approvalStatus||"").toLowerCase()}"><span>${r.approvalStatus==="APPROVED"?"✓":"×"}</span><div><strong>${fmt.escape(r.title)}</strong><small>${r.approvalStatus==="APPROVED"?`Aprobada${r.decidedBy?` por ${fmt.escape(r.decidedBy)}`:""}`:`Rechazada${r.decidedBy?` por ${fmt.escape(r.decidedBy)}`:""}`}${r.decisionNote?` · ${fmt.escape(r.decisionNote)}`:""}</small></div></article>`).join("")}</div>`;
}

function agendaHtml(data){
  const overdue=data.overdue||[],today=data.today||[],upcoming=data.upcoming||[];
  if(!overdue.length&&!today.length&&!upcoming.length)return empty("Jornada sin actividades autorizadas","Agrega una actividad si necesitas incluir trabajo adicional en tu día.");
  return `
    ${overdue.length?`<div class="agenda-section overdue"><div class="agenda-section-title"><strong>Vencidas</strong><span>${overdue.length}</span></div>${overdue.map(a=>agendaRow(a,true,Boolean(data.active))).join("")}</div>`:""}
    ${today.length?`<div class="agenda-section"><div class="agenda-section-title"><strong>Hoy</strong><span>${today.length}</span></div>${today.map(a=>agendaRow(a,false,Boolean(data.active))).join("")}</div>`:""}
    ${upcoming.length?`<div class="agenda-section upcoming"><div class="agenda-section-title"><strong>Próximos 7 días</strong><span>${upcoming.length}</span></div>${upcoming.map(upcomingRow).join("")}</div>`:""}`;
}

function agendaRow(a,overdue,hasActive){
  const tooEarly=a.plannedStart&&new Date(a.plannedStart).getTime()>Date.now()+15*60000;
  const disabled=hasActive||!a.catalogId||tooEarly;
  const label=tooEarly?`Disponible ${timeOnly(new Date(new Date(a.plannedStart).getTime()-15*60000).toISOString())}`:(a.memberStatus==="RETURNED"?"Retomar":"Iniciar");
  return `<article class="agenda-row ${overdue?"is-overdue":""}">
    <div class="agenda-time"><strong>${a.plannedStart?timeOnly(a.plannedStart):a.dueAt?"Límite":"—"}</strong><span>${a.plannedEnd?timeOnly(a.plannedEnd):a.dueAt?fmt.day(a.dueAt):""}</span></div>
    <div class="agenda-main"><div>${priorityBadge(a.priority)} ${a.kind==="DELIVERABLE"?'<span class="badge badge-blue"><span class="badge-dot"></span>Entregable</span>':""}</div><strong>${fmt.escape(a.title)}</strong><small>${fmt.escape(a.catalogName||a.kind||"")} · ${fmt.number(a.estimatedMinutes||0)} min${a.dueAt?` · vence ${fmt.date(a.dueAt)}`:""}${tooEarly?` · inicia ${timeOnly(a.plannedStart)}`:""}</small></div>
    <div class="agenda-actions"><button class="btn btn-primary" data-start-assignment="${fmt.escape(a.id)}" data-catalog-id="${fmt.escape(a.catalogId||"")}" ${disabled?"disabled":""}>${fmt.escape(label)}</button></div>
  </article>`;
}

function upcomingRow(a){return `<article class="agenda-row compact"><div class="agenda-time"><strong>${a.plannedStart?weekdayShort(a.plannedStart):"Límite"}</strong><span>${a.plannedStart?timeOnly(a.plannedStart):fmt.day(a.dueAt)}</span></div><div class="agenda-main"><strong>${fmt.escape(a.title)}</strong><small>${fmt.escape(a.catalogName||fmt.label(a.kind))}</small></div></article>`}

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
  content.querySelector("[data-work-propose]")?.addEventListener("click",()=>proposeActivityWizard(data,content));
  content.querySelectorAll("[data-start-assignment]").forEach(button=>button.onclick=async()=>{
    button.disabled=true;
    try{await api.workStart(button.dataset.catalogId,button.dataset.startAssignment,{});toast("Actividad iniciada.");window.dispatchEvent(new CustomEvent("erp:refresh-workforce"));await rerenderWorkforceContent(content)}catch(error){toast(error.message,"error",7000);button.disabled=false}
  });
  content.querySelector("[data-work-pause]")?.addEventListener("click",()=>pauseDialog(data.active,content));
  content.querySelector("[data-work-resume]")?.addEventListener("click",async event=>{const button=event.currentTarget;button.disabled=true;try{await api.workResume(data.active.id);toast("Actividad reanudada.");await rerenderWorkforceContent(content)}catch(error){toast(error.message,"error");button.disabled=false}});
  content.querySelector("[data-work-finish]")?.addEventListener("click",()=>finishDialog(data.active,content));
  content.querySelector("[data-work-before-photo]")?.addEventListener("click",()=>photoPicker(data.active,"BEFORE_PHOTO",content));
  content.querySelectorAll("[data-add-evidence]").forEach(button=>button.onclick=()=>evidenceDialog({id:button.dataset.addEvidence,evidencePolicy:button.dataset.policy,title:button.dataset.title},content));
}

function proposeActivityWizard(data,content){
  const catalog=(data.catalog||[]).filter(c=>c.activityKind==="ACTIVITY");
  if(!catalog.length){toast("No tienes actividades habilitadas en el catálogo.","error");return;}
  const now=roundToFiveMinutes(new Date());
  const defaultEnd=new Date(now.getTime()+60*60000);
  wizard({title:"Agregar actividad a mi jornada",subtitle:"La actividad no podrá iniciarse hasta ser autorizada. Esto evita registros accidentales y conserva la planificación del equipo.",finishLabel:"Enviar para aprobación",size:"wide",steps:[
    {title:"Buscar actividad",description:"Selecciona primero qué necesitas hacer. No se inicia nada desde esta lista.",content:`<div class="work-search-shell"><div class="field"><label>Buscar en mis actividades</label><input class="control" name="catalogSearch" placeholder="Ej. conteo, limpieza, cargue, organización…" autocomplete="off"></div><div class="field"><label>Categoría</label><select class="control" name="catalogGroup"><option value="">Todas</option>${[...new Set(catalog.map(c=>c.activityGroup))].map(g=>`<option value="${fmt.escape(g)}">${fmt.escape(GROUP_LABELS[g]||fmt.label(g))}</option>`).join("")}</select></div></div><div class="work-activity-picker" data-activity-picker></div><input type="hidden" name="catalogId" required>`,onEnter:({form,panel})=>{
      const render=()=>{const q=String(form.catalogSearch.value||"").trim().toLowerCase(),group=form.catalogGroup.value;const rows=catalog.filter(c=>(!group||c.activityGroup===group)&&(!q||`${c.name} ${c.description||""} ${GROUP_LABELS[c.activityGroup]||""}`.toLowerCase().includes(q)));panel.querySelector('[data-activity-picker]').innerHTML=rows.length?rows.map(c=>`<button type="button" class="work-activity-option ${form.catalogId.value===c.id?"selected":""}" data-pick-activity="${fmt.escape(c.id)}"><span class="work-catalog-icon">${activityGlyph(c.code)}</span><span><strong>${fmt.escape(c.name)}</strong><small>${fmt.escape(GROUP_LABELS[c.activityGroup]||fmt.label(c.activityGroup))} · ${fmt.number(c.medianMinutes&&c.samples>=5?c.medianMinutes:c.standardMinutes||0)} min · ${evidenceLabel(c.evidencePolicy)}</small></span><i>Seleccionar</i></button>`).join(""):`<div class="work-picker-empty">No encontramos actividades con ese criterio.</div>`;panel.querySelectorAll('[data-pick-activity]').forEach(b=>b.onclick=()=>{form.catalogId.value=b.dataset.pickActivity;render()})};form.catalogSearch.oninput=render;form.catalogGroup.onchange=render;render();},validate:({form})=>{if(!form.catalogId.value)throw new Error("Selecciona una actividad de la lista.");return true}},
    {title:"Motivo",description:"Explica por qué esta actividad debe hacer parte de tu jornada.",content:`<div class="work-reason-panel"><div><span>Motivo obligatorio</span><strong>¿Por qué necesitas realizar esta actividad?</strong><p>Una explicación breve permite al responsable aprobar con contexto y evita registrar actividades sin propósito.</p></div><div class="field"><label>Razón *</label><textarea class="control" name="reason" rows="5" minlength="10" maxlength="500" required placeholder="Ej. Se requiere conteo extraordinario de la zona B por diferencia detectada en ubicación física."></textarea><small class="field-help">Mínimo 10 caracteres. Sé concreto y operativo.</small></div></div>`,validate:({form})=>{if(String(form.reason.value||"").trim().length<10)throw new Error("Explica con un poco más de detalle por qué necesitas realizar la actividad.");return true}},
    {title:"Cuándo",description:"Puedes proponerla para ahora o incorporarla a tu agenda de hoy o de otro día.",content:`<div class="work-time-choice"><button class="work-time-card active" type="button" data-start-mode="NOW"><strong>Ahora</strong><span>Quedará lista al ser aprobada</span></button><button class="work-time-card" type="button" data-start-mode="SCHEDULED"><strong>Programar</strong><span>Define fecha y hora</span></button></div><input type="hidden" name="startMode" value="NOW"><div class="form-grid"><div class="field"><label>Inicio propuesto *</label><input class="control" type="datetime-local" name="plannedStart" value="${localDateTimeInput(now)}" required></div><div class="field"><label>Final estimado *</label><input class="control" type="datetime-local" name="plannedEnd" value="${localDateTimeInput(defaultEnd)}" required></div><div class="field"><label>Prioridad</label><select class="control" name="priority"><option value="MEDIUM">Normal</option><option value="HIGH">Alta</option><option value="URGENT">Urgente</option><option value="LOW">Baja</option></select></div></div><div class="wizard-tip">Si eliges “Ahora” y la aprobación llega unos minutos después, el ERP moverá el inicio planificado al momento de la aprobación para no penalizarte por el tiempo de espera.</div>`,onEnter:({form,panel})=>{const selected=catalog.find(c=>c.id===form.catalogId.value);const mins=Math.max(1,Number(selected?.medianMinutes&&selected.samples>=5?Math.round(selected.medianMinutes):selected?.standardMinutes||60));if(!form.dataset.timeInitialized){const start=roundToFiveMinutes(new Date());form.plannedStart.value=localDateTimeInput(start);form.plannedEnd.value=localDateTimeInput(new Date(start.getTime()+mins*60000));form.dataset.timeInitialized="1"}const selectMode=mode=>{form.startMode.value=mode;panel.querySelectorAll('[data-start-mode]').forEach(b=>b.classList.toggle('active',b.dataset.startMode===mode));if(mode==="NOW"){const start=roundToFiveMinutes(new Date());form.plannedStart.value=localDateTimeInput(start);form.plannedEnd.value=localDateTimeInput(new Date(start.getTime()+mins*60000));}};panel.querySelectorAll('[data-start-mode]').forEach(b=>b.onclick=()=>selectMode(b.dataset.startMode));},validate:({form})=>{if(!form.plannedStart.value||!form.plannedEnd.value)throw new Error("Completa el horario propuesto.");if(new Date(form.plannedEnd.value)<=new Date(form.plannedStart.value))throw new Error("La hora final debe ser posterior al inicio.");return true}},
    {title:"Revisión",description:"Confirma exactamente lo que será enviado al responsable.",content:`<div class="work-request-review"><article><span>Actividad</span><strong data-proposal-activity>—</strong></article><article><span>Motivo</span><strong data-proposal-reason>—</strong></article><article><span>Horario</span><strong data-proposal-time>—</strong></article><article><span>Aprobación</span><strong>${fmt.escape(data.permissions?.approvalScope==="LOGISTICS"?"Líder Logístico / Jefatura Logística":"Gerencia")}</strong></article></div><div class="work-approval-notice"><span>🔒</span><div><strong>No inicia automáticamente</strong><p>Al enviar, la actividad quedará “Por aprobar”. Solo aparecerá habilitada para iniciar cuando el responsable la autorice.</p></div></div>`,onEnter:({root,form})=>{const c=catalog.find(x=>x.id===form.catalogId.value);root.querySelector('[data-proposal-activity]').textContent=c?.name||"—";root.querySelector('[data-proposal-reason]').textContent=form.reason.value;root.querySelector('[data-proposal-time]').textContent=`${new Date(form.plannedStart.value).toLocaleString("es-CO",{dateStyle:"medium",timeStyle:"short"})} → ${timeOnly(new Date(form.plannedEnd.value).toISOString())}`}}
  ],onFinish:async({form})=>{const start=new Date(form.plannedStart.value),end=new Date(form.plannedEnd.value);const result=await api.workProposeAssignment({catalogId:form.catalogId.value,reason:form.reason.value,priority:form.priority.value,startMode:form.startMode.value,plannedStart:start.toISOString(),plannedEnd:end.toISOString(),estimatedMinutes:Math.max(1,Math.round((end-start)/60000))});toast(result.approvalScope==="LOGISTICS"?"Solicitud enviada a Liderazgo/Jefatura Logística.":"Solicitud enviada a Gerencia.");await rerenderWorkforceContent(content)}});
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
// APROBACIONES DE ACTIVIDADES PROPUESTAS
// ---------------------------------------------------------------------------
async function renderApprovals(root,content){
  const rows=await api.workPendingApprovals();
  const list=Array.isArray(rows)?rows:(rows?.items||[]);
  const logistics=list.filter(x=>x.approvalScope==="LOGISTICS").length;
  const management=list.filter(x=>x.approvalScope==="MANAGEMENT").length;
  content.innerHTML=`
    <section class="work-approval-hero">
      <div><span class="workforce-kicker">Gobierno de la jornada</span><h3>Actividades por autorizar</h3><p>Revisa el motivo y el horario antes de permitir que la actividad entre a la jornada. Una solicitud aprobada queda lista para iniciar; una asignación creada directamente por liderazgo no requiere este paso.</p></div>
      <div class="work-approval-hero-stats"><article><strong>${list.length}</strong><span>Pendientes</span></article>${logistics?`<article><strong>${logistics}</strong><span>Logística</span></article>`:""}${management?`<article><strong>${management}</strong><span>Gestión</span></article>`:""}</div>
    </section>
    <section class="card work-approval-board">
      <header class="card-head"><div><h3>Bandeja de aprobación</h3><p>${list.length?"Las solicitudes más antiguas aparecen primero.":"No hay actividades esperando tu decisión."}</p></div><span class="workforce-count ${list.length?"attention":""}">${list.length}</span></header>
      <div class="card-body">${approvalRowsHtml(list)}</div>
    </section>`;
  content.querySelectorAll('[data-work-approve]').forEach(button=>button.onclick=()=>decideWorkRequest(button.dataset.workApprove,"APPROVED",content,root));
  content.querySelectorAll('[data-work-reject]').forEach(button=>button.onclick=()=>decideWorkRequest(button.dataset.workReject,"REJECTED",content,root));
}

function approvalRowsHtml(rows){
  if(!rows.length)return `<div class="work-approval-empty"><span>✓</span><div><strong>Todo al día</strong><small>No tienes solicitudes de actividad pendientes por revisar.</small></div></div>`;
  return `<div class="work-approval-list">${rows.map(r=>{
    const warn=[];if(r.hasOverlap)warn.push("Se cruza con otra actividad");if(r.outsideWorkingTime)warn.push("Fuera de jornada laboral");
    return `<article class="work-approval-item ${warn.length?"has-warning":""}">
      <div class="work-approval-person"><span class="avatar">${fmt.initials(r.profileName)}</span><div><strong>${fmt.escape(r.profileName||"Usuario")}</strong><small>${fmt.escape((r.roles||[]).map(x=>fmt.role(x)).join(" · "))}</small></div><span class="work-scope-pill ${String(r.approvalScope||"").toLowerCase()}">${r.approvalScope==="LOGISTICS"?"Logística":"Gerencia"}</span></div>
      <div class="work-approval-work"><span class="work-approval-label">Actividad solicitada</span><h4>${fmt.escape(r.title||r.catalogName||"Actividad")}</h4><p>${fmt.escape(r.reason||"Sin motivo registrado")}</p><div class="work-approval-meta"><span><b>Horario</b>${r.plannedStart?`${fmt.day(r.plannedStart)} · ${timeOnly(r.plannedStart)}–${timeOnly(r.plannedEnd)}`:"Sin horario"}</span><span><b>Duración</b>${fmt.number(r.estimatedMinutes||0)} min</span><span><b>Prioridad</b>${fmt.label(r.priority||"MEDIUM")}</span></div>${warn.length?`<div class="work-approval-warning"><strong>Revisión necesaria</strong><span>${fmt.escape(warn.join(" · "))}</span></div>`:""}</div>
      <div class="work-approval-actions"><button class="btn btn-ghost" data-work-reject="${fmt.escape(r.id)}">Rechazar</button><button class="btn btn-primary" data-work-approve="${fmt.escape(r.id)}">Aprobar actividad</button></div>
    </article>`}).join("")}</div>`;
}

function decideWorkRequest(id,decision,content,root){
  const approving=decision==="APPROVED";
  modal({title:approving?"Aprobar actividad":"Rechazar actividad",confirmLabel:approving?"Aprobar y publicar":"Rechazar solicitud",body:`<div class="work-decision-copy"><strong>${approving?"La actividad quedará habilitada en la agenda del colaborador.":"La actividad no podrá iniciarse."}</strong><span>${approving?"Si el horario tiene un conflicto, el ERP te pedirá confirmarlo conscientemente.":"Indica la razón para que el colaborador entienda la decisión."}</span></div><div class="field"><label>${approving?"Nota de aprobación (opcional)":"Motivo del rechazo *"}</label><textarea class="control" name="note" rows="4" ${approving?"":"required"} placeholder="${approving?"Observación para el colaborador":"Explica por qué no se autoriza"}"></textarea></div>`,onConfirm:async dialog=>{
    const note=dialog.querySelector('[name="note"]').value||null;
    const result=await api.workDecideAssignment(id,decision,note,false);
    if(approving&&result?.requiresConfirmation){
      setTimeout(()=>modal({title:"Confirmar excepción de horario",confirmLabel:"Aprobar de todas formas",body:`<div class="callout warning"><strong>El ERP detectó una excepción de planificación</strong><p>${fmt.escape((result.conflicts||[]).map(x=>x.message||x.reason).filter(Boolean).join(" · ")||result.message||"Existe superposición o tiempo fuera de la jornada prevista.")}</p></div><p class="muted">Autoriza la excepción únicamente si la actividad debe realizarse en ese horario.</p>`,onConfirm:async()=>{await api.workDecideAssignment(id,"APPROVED",note,true);toast("Actividad aprobada y publicada.");await renderApprovals(root,content)}}),0);
      return;
    }
    toast(approving?"Actividad aprobada y publicada.":"Solicitud rechazada.");await renderApprovals(root,content);
  }});
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
      <div class="work-planner-actions"><div class="segment-control"><button class="${plannerMode==="week"?"active":""}" data-plan-mode="week">Semana</button><button class="${plannerMode==="month"?"active":""}" data-plan-mode="month">Mes</button></div><button class="btn btn-ghost" data-plan-new-custom>+ Nueva actividad</button><button class="btn btn-primary" data-plan-new>Asignar del catálogo</button></div>
    </section>
    ${plannerMode==="week"?weekPlannerHtml(data):monthPlannerHtml(data)}
    <section class="card work-team-now"><header class="card-head"><div><h3>Carga de actividades programadas</h3><p>Este bloque muestra actividades varias planificadas. La ocupación completa —procesos ERP + actividades varias— se consulta en Ocupación.</p></div></header><div class="card-body">${teamCapacityHtml(data.people||[],data.assignments||[],range)}</div></section>`;
  content.querySelector("[data-plan-prev]").onclick=()=>{plannerAnchor=plannerMode==="week"?addDays(plannerAnchor,-7):addMonths(plannerAnchor,-1);renderPlanner(root,content)};
  content.querySelector("[data-plan-next]").onclick=()=>{plannerAnchor=plannerMode==="week"?addDays(plannerAnchor,7):addMonths(plannerAnchor,1);renderPlanner(root,content)};
  content.querySelector("[data-plan-today]").onclick=()=>{plannerAnchor=plannerMode==="week"?startOfWeek(new Date()):new Date(new Date().getFullYear(),new Date().getMonth(),1);renderPlanner(root,content)};
  content.querySelectorAll("[data-plan-mode]").forEach(button=>button.onclick=()=>{plannerMode=button.dataset.planMode;plannerAnchor=plannerMode==="week"?startOfWeek(plannerAnchor):new Date(plannerAnchor.getFullYear(),plannerAnchor.getMonth(),1);renderPlanner(root,content)});
  content.querySelector("[data-plan-new]").onclick=()=>assignmentWizard(data,catalog,()=>renderPlanner(root,content),null,{newCatalog:false});
  content.querySelector("[data-plan-new-custom]").onclick=()=>assignmentWizard(data,catalog,()=>renderPlanner(root,content),null,{newCatalog:true,startNow:true});
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

function assignmentWizard(data,catalog,reload,prefillDay=null,options={}){
  const permissions=data.permissions||{};
  const scopes=[];
  if(permissions.logistics)scopes.push(["LOGISTICS","Equipo logístico"]);
  if(permissions.management)scopes.push(["MANAGEMENT","Áreas de gestión"]);
  if(!scopes.length){toast("No tienes un ámbito de planificación habilitado.","error");return;}
  const defaultScope=options.scope&&scopes.some(([v])=>v===options.scope)?options.scope:scopes[0][0];
  const day=prefillDay||isoDate(new Date());
  const people=data.people||[];
  const initialMode=options.newCatalog?"NEW":"EXISTING";
  const initialStart=options.startNow?roundToFiveMinutes(new Date()):new Date(`${day}T08:00:00`);
  const initialEnd=new Date(initialStart.getTime()+60*60000);
  const kindOptions=scope=>scope==="MANAGEMENT"&&permissions.deliverables?[["ACTIVITY","Actividad de gestión"],["DELIVERABLE","Entregable con revisión"]]:[["ACTIVITY","Actividad de equipo"]];
  wizard({title:options.newCatalog?"Crear y asignar actividad":"Planificar actividad",subtitle:"Define el trabajo, a quién corresponde y cuándo debe realizarse. Las asignaciones hechas por liderazgo quedan autorizadas desde su publicación.",finishLabel:"Publicar en la agenda",size:"wide",steps:[
    {title:"Trabajo",description:"Parte del catálogo o crea una actividad nueva y reutilizable.",content:`
      <div class="work-planning-context">
        <div class="field"><label>Ámbito *</label><select class="control" name="scope" required>${scopes.map(([v,l])=>`<option value="${v}" ${v===defaultScope?"selected":""}>${l}</option>`).join("")}</select></div>
        <div class="field"><label>Tipo *</label><select class="control" name="kind" required></select></div>
      </div>
      <div class="work-catalog-mode" role="radiogroup" aria-label="Origen de la actividad">
        <label class="status-choice"><input type="radio" name="catalogMode" value="EXISTING" ${initialMode==="EXISTING"?"checked":""}><span><strong>Usar catálogo</strong><small>Busca una actividad ya tipificada y conserva su estándar.</small></span></label>
        <label class="status-choice"><input type="radio" name="catalogMode" value="NEW" ${initialMode==="NEW"?"checked":""}><span><strong>Crear nueva actividad</strong><small>Se incorpora al catálogo del ámbito para futuras asignaciones.</small></span></label>
      </div>
      <div data-existing-catalog>
        <div class="field"><label>Actividad / plantilla *</label><select class="control" name="catalogId"></select></div>
      </div>
      <div class="form-grid work-new-catalog-fields" data-new-catalog hidden>
        <div class="field"><label>Nombre de la nueva actividad *</label><input class="control" name="newCatalogName" maxlength="120" placeholder="Ej. Conteo cíclico extraordinario"></div>
        <div class="field"><label>Categoría *</label><select class="control" name="newCatalogGroup"></select></div>
        <div class="field full"><div class="work-catalog-persistence"><strong>Actividad reutilizable</strong><span>Quedará registrada en el catálogo correspondiente. Nombres equivalentes reutilizan el registro existente para evitar duplicados.</span></div></div>
      </div>
      <div class="form-grid">
        <div class="field full"><label>Título de esta asignación *</label><input class="control" name="title" required placeholder="Qué debe hacerse"></div>
        <div class="field full"><label>Resultado esperado / instrucciones</label><textarea class="control" name="description" rows="3" placeholder="Describe lo necesario para considerar la actividad terminada"></textarea></div>
      </div>`,onEnter:({form,panel})=>{
        const existing=panel.querySelector('[data-existing-catalog]'),custom=panel.querySelector('[data-new-catalog]');
        const syncScope=()=>{
          const scope=form.scope.value;
          const kinds=kindOptions(scope);const current=form.kind.value;
          form.kind.innerHTML=kinds.map(([v,l])=>`<option value="${v}">${l}</option>`).join("");
          if(kinds.some(([v])=>v===current))form.kind.value=current;
          syncCatalog();
        };
        const syncCatalog=()=>{
          fillCatalogSelect(form.catalogId,catalog,form.kind.value,form.scope.value);
          fillNewCatalogGroups(form.newCatalogGroup,form.kind.value,form.scope.value);
          const c=catalog.find(x=>x.id===form.catalogId.value);if(c&&(!form.title.value||form.dataset.titleFromCatalog==="1")){form.title.value=c.name;form.dataset.titleFromCatalog="1";if(c.description&&!form.description.value)form.description.value=c.description;}
        };
        const syncMode=()=>{const mode=form.querySelector('[name="catalogMode"]:checked')?.value||"EXISTING";existing.hidden=mode!=="EXISTING";custom.hidden=mode!=="NEW";form.catalogId.required=mode==="EXISTING";form.newCatalogName.required=mode==="NEW";form.newCatalogGroup.required=mode==="NEW";};
        form.scope.onchange=syncScope;form.kind.onchange=syncCatalog;form.querySelectorAll('[name="catalogMode"]').forEach(r=>r.onchange=syncMode);
        form.catalogId.onchange=()=>{const c=catalog.find(x=>x.id===form.catalogId.value);if(c){form.title.value=c.name;form.dataset.titleFromCatalog="1";if(c.description)form.description.value=c.description;}};
        form.newCatalogName.oninput=()=>{if((form.querySelector('[name="catalogMode"]:checked')?.value||"")==="NEW"){form.title.value=form.newCatalogName.value;form.dataset.titleFromCatalog="0";}};
        syncScope();syncMode();
      },validate:({form})=>{const mode=form.querySelector('[name="catalogMode"]:checked')?.value||"EXISTING";if(mode==="EXISTING"&&!form.catalogId.value)throw new Error("Selecciona una actividad del catálogo.");if(mode==="NEW"&&String(form.newCatalogName.value||"").trim().length<3)throw new Error("Escribe el nombre de la nueva actividad.");return true;}},
    {title:"Personas",description:"Selecciona a quién se asigna. Liderazgo Logístico trabaja con su equipo; Gerencia con sus áreas de gestión.",content:`<div class="work-assignee-picker">${people.map(p=>`<label class="work-person-choice" data-person-kind><input type="checkbox" name="profileId" value="${fmt.escape(p.id)}"><span class="avatar">${fmt.initials(p.name)}</span><span><strong>${fmt.escape(p.name)}</strong><small>${fmt.escape((p.roles||[]).map(r=>fmt.role(r)).join(" · "))}</small></span><b>${p.activeTitle?"Ocupado ahora":`${fmt.number(p.plannedMinutes7d)} min / 7d`}</b></label>`).join("")}</div>`,onEnter:({form})=>{const scope=form.scope.value;form.querySelectorAll('[data-person-kind]').forEach(label=>{const p=people.find(x=>x.id===label.querySelector('input').value);const roles=p?.roles||[];const allowed=scope==="LOGISTICS"?roles.some(r=>["jefe_logistica","lider_logistica","coordinador_logistico","aux_logistica","auxiliar_corte","recepcion_mercancia","despacho_nacional"].includes(r)):roles.some(r=>["ventas","jefe_logistica","compras","cartera","caja"].includes(r));label.hidden=!permissions.all&&!allowed;if(label.hidden)label.querySelector('input').checked=false;});},validate:({form})=>{if(!form.querySelector('[name="profileId"]:checked'))throw new Error("Selecciona al menos una persona.");return true;}},
    {title:"Horario",description:"Asígnala para ahora o reserva un bloque futuro. Se validan jornada, festivos y superposiciones.",content:`<div class="work-time-presets"><button class="btn btn-ghost" type="button" data-work-time-now>Asignar ahora</button><span>o define el bloque manualmente</span></div><div class="form-grid"><div class="field"><label>Inicio</label><input class="control" type="datetime-local" name="plannedStart" value="${localDateTimeInput(initialStart)}"></div><div class="field"><label>Finalización planificada</label><input class="control" type="datetime-local" name="plannedEnd" value="${localDateTimeInput(initialEnd)}"></div><div class="field"><label>Fecha límite</label><input class="control" type="datetime-local" name="dueAt" value="${day}T17:30"></div><div class="field"><label>Duración estimada (min) *</label><input class="control" type="number" min="1" max="1440" name="estimatedMinutes" value="60" required></div><div class="field"><label>Repetir</label><select class="control" name="frequency"><option value="NONE">No repetir</option><option value="DAILY">Cada día</option><option value="WEEKLY">Cada semana</option><option value="MONTHLY">Cada mes</option></select></div><div class="field"><label>Repetir hasta</label><input class="control" type="date" name="repeatUntil"></div></div><div class="wizard-tip">Una actividad publicada por un responsable autorizado aparece directamente en la agenda de la persona y no requiere aprobación adicional.</div>`,onEnter:({form,panel})=>{const kind=form.kind.value;form.dueAt.required=kind==="DELIVERABLE";form.plannedStart.required=kind==="ACTIVITY";form.plannedEnd.required=kind==="ACTIVITY";const mode=form.querySelector('[name="catalogMode"]:checked')?.value||"EXISTING";const c=mode==="EXISTING"?catalog.find(x=>x.id===form.catalogId.value):null;if(c&&c.standardMinutes&&!form.dataset.durationTouched)form.estimatedMinutes.value=c.medianMinutes&&c.samples>=5?Math.round(c.medianMinutes):c.standardMinutes;const applyNow=()=>{const start=roundToFiveMinutes(new Date());const mins=Math.max(1,Number(form.estimatedMinutes.value||60));form.plannedStart.value=localDateTimeInput(start);form.plannedEnd.value=localDateTimeInput(new Date(start.getTime()+mins*60000));};panel.querySelector('[data-work-time-now]').onclick=applyNow;form.estimatedMinutes.oninput=()=>{form.dataset.durationTouched="1";};form.frequency.onchange=()=>{form.repeatUntil.required=form.frequency.value!=="NONE"};}},
    {title:"Control",description:"Define evidencia, prioridad y, cuando aplique, aceptación del resultado.",content:`<div class="form-grid"><div class="field"><label>Evidencia *</label><select class="control" name="evidencePolicy"><option value="NONE">Sin evidencia</option><option value="FINAL_PHOTO">Foto final</option><option value="BEFORE_AFTER">Foto antes + después</option><option value="FILE">Archivo</option><option value="LINK">Enlace</option><option value="ERP_REFERENCE">Referencia ERP</option></select></div><div class="field"><label>Prioridad</label><select class="control" name="priority"><option value="MEDIUM">Media</option><option value="HIGH">Alta</option><option value="URGENT">Urgente</option><option value="CRITICAL">Crítica</option><option value="LOW">Baja</option></select></div><label class="status-choice full"><input type="checkbox" name="acceptanceRequired"><span><strong>Requiere aceptación final</strong><small>Útil para entregables o actividades cuyo resultado deba ser revisado por quien asigna.</small></span></label></div>`,onEnter:({form})=>{const mode=form.querySelector('[name="catalogMode"]:checked')?.value||"EXISTING";const c=mode==="EXISTING"?catalog.find(x=>x.id===form.catalogId.value):null;if(c)form.evidencePolicy.value=c.evidencePolicy||"NONE";else if(!form.dataset.newEvidenceInitialized){form.evidencePolicy.value=form.kind.value==="DELIVERABLE"?"FILE":"FINAL_PHOTO";form.dataset.newEvidenceInitialized="1";}form.acceptanceRequired.checked=form.kind.value==="DELIVERABLE"||(c?.acceptanceRequired===true);}},
    {title:"Revisión",description:"Confirma el trabajo antes de publicarlo en la agenda.",content:`<div class="wizard-summary work-assignment-review"><div class="wizard-summary-item"><label>Trabajo</label><strong data-review-title>—</strong></div><div class="wizard-summary-item"><label>Ámbito</label><strong data-review-scope>—</strong></div><div class="wizard-summary-item"><label>Personas</label><strong data-review-people>—</strong></div><div class="wizard-summary-item"><label>Horario</label><strong data-review-time>—</strong></div><div class="wizard-summary-item"><label>Evidencia</label><strong data-review-evidence>—</strong></div></div><label class="status-choice"><input type="checkbox" name="force"><span><strong>Permitir una excepción de horario si el ERP detecta conflicto</strong><small>No desactiva la validación: solo autoriza conscientemente una superposición o bloque extraordinario.</small></span></label>`,onEnter:({root,form})=>{const mode=form.querySelector('[name="catalogMode"]:checked')?.value||"EXISTING";root.querySelector('[data-review-title]').textContent=form.title.value;root.querySelector('[data-review-scope]').textContent=form.scope.value==="LOGISTICS"?"Equipo logístico":"Áreas de gestión";root.querySelector('[data-review-people]').textContent=[...form.querySelectorAll('[name="profileId"]:checked')].map(i=>people.find(p=>p.id===i.value)?.name||"").join(" · ");root.querySelector('[data-review-time]').textContent=form.kind.value==="DELIVERABLE"?`Vence ${form.dueAt.value||"—"}`:`${form.plannedStart.value||"—"} → ${form.plannedEnd.value||"—"}`;root.querySelector('[data-review-evidence]').textContent=evidenceLabel(form.evidencePolicy.value);}}
  ],onFinish:async({form})=>{
    const mode=form.querySelector('[name="catalogMode"]:checked')?.value||"EXISTING";
    let catalogId=form.catalogId.value||null;
    if(mode==="NEW"){
      const created=await api.workCreateCatalogItem({scope:form.scope.value,kind:form.kind.value,name:form.newCatalogName.value,description:form.description.value||null,activityGroup:form.newCatalogGroup.value,standardMinutes:Number(form.estimatedMinutes.value),evidencePolicy:form.evidencePolicy.value,acceptanceRequired:form.acceptanceRequired.checked,teamAllowed:form.kind.value==="ACTIVITY"});
      catalogId=created.item?.id;if(!catalogId)throw new Error("No fue posible incorporar la actividad al catálogo.");toast(created.alreadyExists?"La actividad ya existía y fue reutilizada.":"Nueva actividad incorporada al catálogo.");
    }
    const payload={kind:form.kind.value,catalogId,title:form.title.value,description:form.description.value||null,profileIds:[...form.querySelectorAll('[name="profileId"]:checked')].map(i=>i.value),plannedStart:form.plannedStart.value?new Date(form.plannedStart.value).toISOString():null,plannedEnd:form.plannedEnd.value?new Date(form.plannedEnd.value).toISOString():null,dueAt:form.dueAt.value?new Date(form.dueAt.value).toISOString():null,estimatedMinutes:Number(form.estimatedMinutes.value),evidencePolicy:form.evidencePolicy.value,acceptanceRequired:form.acceptanceRequired.checked,priority:form.priority.value,force:form.force.checked,recurrence:{frequency:form.frequency.value,until:form.repeatUntil.value||null}};
    const result=await api.workSaveAssignment(payload);
    if(!result.success){const details=[...new Set((result.conflicts||[]).map(x=>x.message).filter(Boolean))].slice(0,2).join(" · ");throw new Error(`Hay ${result.conflicts?.length||1} conflicto(s) de planificación${details?`: ${details}`:""}. Autoriza la excepción solo si realmente corresponde.`);}
    toast(result.createdIds?.length>1?`${result.createdIds.length} actividades programadas.`:"Actividad publicada en la agenda.");await reload();
  }});
}

function catalogScope(item){if(item.catalogScope)return item.catalogScope;if(item.activityGroup==="LOGISTICS")return"LOGISTICS";if(["COMMERCIAL","FINANCE","PURCHASING","MANAGEMENT"].includes(item.activityGroup))return"MANAGEMENT";return item.managerScope||null;}
function fillCatalogSelect(select,catalog,kind,scope){
  const rows=catalog.filter(c=>c.activityKind===kind&&(!catalogScope(c)||catalogScope(c)===scope));
  select.innerHTML=rows.length?rows.map(c=>`<option value="${fmt.escape(c.id)}">${c.custom?"★ ":""}${fmt.escape(c.name)} · ${fmt.number(c.medianMinutes&&c.samples>=5?c.medianMinutes:c.standardMinutes||0)} min</option>`).join(""):'<option value="">Sin actividades disponibles</option>';
}
function fillNewCatalogGroups(select,kind,scope){
  const rows=scope==="MANAGEMENT"?[["MANAGEMENT","Gestión"],["COMMERCIAL","Comercial"],["FINANCE","Financiera"],["PURCHASING","Compras"],["GENERAL","General"],["IMPROVEMENT","Mejora continua"]]:[["LOGISTICS","Operación logística"],["GENERAL","General"],["IMPROVEMENT","Mejora continua"]];
  const current=select.value;select.innerHTML=rows.map(([v,l])=>`<option value="${v}">${l}</option>`).join("");if(rows.some(([v])=>v===current))select.value=current;
}

function cancelAssignmentDialog(id,reload){modal({title:"Cancelar asignación",confirmLabel:"Cancelar actividad",body:`<div class="field"><label>Motivo</label><textarea class="control" name="note" rows="3" placeholder="Explica por qué deja de realizarse"></textarea></div>`,onConfirm:async dialog=>{await api.workCancelAssignment(id,dialog.querySelector('[name="note"]').value||null);toast("Asignación cancelada.");await reload()}})}

// ---------------------------------------------------------------------------
// ANALÍTICA
// ---------------------------------------------------------------------------
async function renderAnalytics(root,content){
  const canManage=state.profile?.roles?.some(r=>["super_admin","gerencia","jefe_logistica","lider_logistica","auditoria"].includes(r));
  const people=canManage?await api.workPeople(null).catch(()=>[]):[];
  const selected=content.dataset.analyticsProfile||"";
  const [data,occupation]=await Promise.all([
    api.workAnalytics(analyticsRange.from,analyticsRange.to,selected||null),
    api.workOccupation(analyticsRange.from,analyticsRange.to,selected||null)
  ]);
  content.innerHTML=`
    <section class="card work-analytics-toolbar"><div class="form-grid"><div class="field"><label>Desde</label><input class="control" type="date" data-analytics-from value="${analyticsRange.from}"></div><div class="field"><label>Hasta</label><input class="control" type="date" data-analytics-to value="${analyticsRange.to}"></div>${canManage?`<div class="field"><label>Persona / equipo</label><select class="control" data-analytics-profile><option value="">Mi ámbito completo</option>${people.map(p=>`<option value="${fmt.escape(p.id)}" ${selected===p.id?"selected":""}>${fmt.escape(p.name)}</option>`).join("")}</select></div>`:""}<div class="field analytics-apply"><label>&nbsp;</label><button class="btn btn-primary" data-analytics-apply>Aplicar</button></div></div></section>
    ${occupationOverview(occupation)}
    ${analyticsSummary(data.summary)}
    <div class="grid grid-2 work-analytics-grid">
      <section class="card"><header class="card-head"><div><h3>Actividades varias</h3><p>Distribución del tiempo adicional por familia de actividad.</p></div></header><div class="card-body">${barList(data.activityGroups||[],x=>GROUP_LABELS[x.group]||fmt.label(x.group),x=>x.activeSeconds)}</div></section>
      <section class="card"><header class="card-head"><div><h3>Tiempos de referencia aprendidos</h3><p>Mediana y percentil 80 construidos con ejecuciones reales.</p></div></header><div class="card-body">${activityStandardsHtml(data.topActivities||[])}</div></section>
      <section class="card"><header class="card-head"><div><h3>Causas de desviación</h3><p>Pareto de razones registradas cuando una actividad se aparta de lo estimado.</p></div></header><div class="card-body">${causeList(data.deviationCauses||[])}</div></section>
      <section class="card"><header class="card-head"><div><h3>Equipo ahora</h3><p>Actividades varias en ejecución; el trabajo fijo se integra en Ocupación.</p></div></header><div class="card-body">${teamNowHtml(data.teamNow||[])}</div></section>
    </div>
    ${data.pendingReviews?.length?`<section class="card work-review-card"><header class="card-head"><div><h3>Entregables pendientes de revisión</h3><p>Aceptar confirma el resultado; devolver exige una nota para corrección.</p></div></header><div class="card-body">${pendingReviewsHtml(data.pendingReviews)}</div></section>`:""}
    <section class="work-ethics-note"><strong>Cómo leer Ocupación</strong><span>Combina procesos fijos instrumentados del ERP (por ejemplo Corte, Alistamiento, Recepción y demás sesiones de proceso) con actividades varias. Los intervalos superpuestos se fusionan para no contar dos veces el mismo minuto. El tiempo sin categoría no se interpreta automáticamente como improductivo.</span></section>`;
  content.querySelector("[data-analytics-apply]").onclick=()=>{analyticsRange={from:content.querySelector('[data-analytics-from]').value,to:content.querySelector('[data-analytics-to]').value};content.dataset.analyticsProfile=content.querySelector('[data-analytics-profile]')?.value||"";renderAnalytics(root,content)};
  content.querySelectorAll("[data-review-accept]").forEach(button=>button.onclick=()=>reviewDelivery(button.dataset.reviewAccept,"ACCEPTED",content,root));
  content.querySelectorAll("[data-review-return]").forEach(button=>button.onclick=()=>reviewDelivery(button.dataset.reviewReturn,"RETURNED",content,root));
}

function occupationOverview(data={}){
  const s=data.summary||{};
  const top=`<section class="work-occupation-hero"><div><span class="workforce-kicker">Ocupación integrada</span><h3>${data.mode==="TEAM"?"Capacidad utilizada del equipo":"Composición real de la jornada"}</h3><p>Trabajo fijo del ERP + actividades varias, fusionando solapamientos antes de calcular el porcentaje.</p></div><div class="work-occupation-ring" style="--occupation:${Math.min(100,Number(s.occupationPct||0))}"><span><strong>${fmt.number(s.occupationPct||0,1)}%</strong><small>identificada</small></span></div></section>`;
  const metrics=`<section class="work-occupation-strip analytics"><article class="work-occupation-metric fixed"><span>Trabajo fijo ERP</span><strong>${fmt.hours(s.fixedProcessSeconds)}</strong><small>${fmt.number(s.fixedPct||0,1)}% de capacidad</small></article><article class="work-occupation-metric misc"><span>Actividades varias</span><strong>${fmt.hours(s.miscActivitySeconds)}</strong><small>${fmt.number(s.miscPct||0,1)}% de capacidad</small></article><article class="work-occupation-metric total"><span>Tiempo identificado</span><strong>${fmt.hours(s.classifiedSeconds)}</strong><small>${fmt.hours(s.overlapSeconds)} de cruce ya descontado</small></article><article class="work-occupation-metric neutral"><span>Sin categoría</span><strong>${fmt.hours(s.unclassifiedSeconds)}</strong><small>No equivale automáticamente a inactividad</small></article></section>`;
  if(data.mode==="TEAM")return top+metrics+teamOccupationHtml(data.team||[]);
  return top+metrics+personOccupationBreakdown(data);
}

function teamOccupationHtml(rows){
  if(!rows.length)return `<section class="card work-occupation-team"><div class="card-body">${empty("Sin información de ocupación","No hay perfiles dentro del ámbito seleccionado.")}</div></section>`;
  return `<section class="card work-occupation-team"><header class="card-head"><div><h3>Ocupación por persona</h3><p>Separa trabajo fijo del rol y actividades varias para entender dónde se utiliza la capacidad.</p></div></header><div class="card-body"><div class="work-occupation-team-list">${rows.map(r=>`<article><div class="work-team-identity"><span class="avatar">${fmt.initials(r.name)}</span><div><strong>${fmt.escape(r.name)}</strong><small>${fmt.escape((r.roles||[]).map(x=>fmt.role(x)).join(" · "))}</small></div></div><div class="work-stacked-meter" title="Trabajo fijo ${fmt.number(r.fixedPct,1)}% · Actividades varias ${fmt.number(r.miscPct,1)}%"><span class="fixed" style="width:${Math.min(100,Number(r.fixedPct||0))}%"></span><span class="misc" style="width:${Math.min(Math.max(0,100-Number(r.fixedPct||0)),Number(r.miscPct||0))}%"></span></div><div class="work-team-hours"><strong>${fmt.number(r.occupationPct,1)}%</strong><small>${fmt.hours(r.fixedProcessSeconds)} fijo · ${fmt.hours(r.miscActivitySeconds)} varias</small></div></article>`).join("")}</div></div></section>`;
}

function personOccupationBreakdown(data){
  const fixed=data.fixedBreakdown||[],misc=data.miscBreakdown||[];
  return `<div class="grid grid-2 work-occupation-breakdown"><section class="card"><header class="card-head"><div><h3>Trabajo fijo del rol</h3><p>Tiempo cronometrado por los procesos normales del ERP.</p></div></header><div class="card-body">${fixed.length?`<div class="work-source-list">${fixed.map(x=>`<article><strong>${fmt.escape(x.label)}</strong><span>${fmt.hours(x.seconds)}</span></article>`).join("")}</div>`:empty("Sin proceso fijo registrado","No hay sesiones ERP instrumentadas para este periodo.")}</div></section><section class="card"><header class="card-head"><div><h3>Actividades varias</h3><p>Trabajo adicional autorizado y ejecutado.</p></div></header><div class="card-body">${misc.length?`<div class="work-source-list">${misc.map(x=>`<article><strong>${fmt.escape(GROUP_LABELS[x.group]||fmt.label(x.group))}</strong><span>${fmt.hours(x.seconds)} · ${fmt.number(x.executions)} ejecución(es)</span></article>`).join("")}</div>`:empty("Sin actividades varias","No hay ejecuciones adicionales para este periodo.")}</div></section></div>`;
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
function roundToFiveMinutes(value){const d=new Date(value);d.setSeconds(0,0);const remainder=d.getMinutes()%5;if(remainder)d.setMinutes(d.getMinutes()+(5-remainder));return d}
function localDateTimeInput(value){const d=new Date(value);const pad=n=>String(n).padStart(2,"0");return `${d.getFullYear()}-${pad(d.getMonth()+1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`}
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
