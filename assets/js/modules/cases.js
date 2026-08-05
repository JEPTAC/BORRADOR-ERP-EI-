import { API } from "../api.js";
import { uploadToDrive } from "../drive.js";
import { $, $$, esc, fmtDate, fmtNumber, badge, setLoading, setError, toast, openModal, formDataObject, arrayFrom, normalize, title } from "../ui.js";

const DEFAULT_ACTION_FIELDS={
  release_cartera:[{name:"detail",label:"Observación de Cartera",type:"textarea",required:true}],
  release_caja_prelogistica:[{name:"detail",label:"Observación de Caja",type:"textarea",required:true},{name:"paymentEvidence",label:"Soporte de pago",type:"file"}],
  release_caja_factura_pvn:[{name:"detail",label:"Validación de Caja",type:"textarea",required:true},{name:"invoiceFile",label:"Factura o soporte",type:"file",required:true}],
  release_compras:[{name:"detail",label:"Observación de Compras",type:"textarea",required:true},{name:"purchaseOrder",label:"Orden de compra",type:"text"}],
  receive_and_assign_order:[{name:"assignedUserUid",label:"Auxiliar de Alistamiento",type:"user_select",source:"alistamiento",required:true},{name:"detail",label:"Observación",type:"textarea"},{name:"requiresCut",label:"Requiere corte",type:"checkbox"}],
  start_alistamiento:[{name:"detail",label:"Observación de inicio",type:"textarea"}],
  complete_alistamiento:[{name:"detail",label:"Resultado y observaciones",type:"textarea",required:true},{name:"cutAssigneeIdentifier",label:"Auxiliar de corte",type:"user_select",source:"corte"}],
  start_corte:[{name:"detail",label:"Observación de inicio",type:"textarea"}],
  complete_corte:[{name:"detail",label:"Resultado del corte",type:"textarea",required:true},{name:"cutEvidence",label:"Evidencia",type:"file"}],
  release_facturacion:[{name:"detail",label:"Observación",type:"textarea"},{name:"invoiceNumber",label:"Número de factura",type:"text",required:true},{name:"invoiceFile",label:"Factura",type:"file",required:true}],
  start_delivery:[{name:"detail",label:"Observación de salida",type:"textarea"}],
  complete_delivery:[{name:"detail",label:"Observación",type:"textarea"},{name:"receivedBy",label:"Recibido por",type:"text",required:true},{name:"deliveryEvidence",label:"Evidencia de entrega",type:"file",required:true}],
  reprogram_no_delivery:[{name:"newDeliveryAt",label:"Nueva fecha y hora",type:"datetime-local",required:true},{name:"reason",label:"Motivo",type:"textarea",required:true}],
  close_case:[{name:"closureNote",label:"Observación de cierre",type:"textarea",required:true}],
  priority:[{name:"reason",label:"Motivo",type:"textarea",required:true},{name:"priorityLevel",label:"Prioridad",type:"select",options:["MEDIA","ALTA","URGENTE","CRITICA"],required:true}],
  cancellation:[{name:"reason",label:"Motivo de cancelación",type:"textarea",required:true}],
  route_change:[{name:"reason",label:"Motivo",type:"textarea",required:true},{name:"targetRoute",label:"Nueva ruta",type:"select",options:["cliente_punto","cliente_recoge","despacho_local","despacho_nacional"],required:true}],
  no_delivery:[{name:"reason",label:"Motivo de no entrega",type:"textarea",required:true}],
  reopen:[{name:"reason",label:"Motivo de reapertura",type:"textarea",required:true}],
  stock_exception:[{name:"reason",label:"Detalle de la excepción de inventario",type:"textarea",required:true}],
  flow_exception:[{name:"reason",label:"Detalle de la excepción de flujo",type:"textarea",required:true}],
  payment_exception:[{name:"reason",label:"Detalle de la excepción financiera",type:"textarea",required:true}],
  data_correction:[{name:"reason",label:"Dato a corregir y justificación",type:"textarea",required:true}]
};

function normalizeCase(x){
  const c=x.case||x;
  return {caseId:c.caseId||c.case_id||c.id,reference:c.reference||c.orderNumber||c.order_number||c.caseId||c.case_id,client:c.client||c.customer||"",orderKind:c.orderKind||c.order_kind||"",status:c.status||"",currentProcess:c.currentProcess||c.current_process||"",route:c.route||c.deliveryType||c.delivery_type||"",assignedName:c.assignedName||c.assigned_name||c.assignedTo||"",updatedAt:c.updatedAt||c.updated_at||c.createdAt||c.created_at,priority:c.priority||"",raw:c};
}

export async function renderCasesPage(container,context={}){
  const state={page:1,pageSize:50,search:"",status:"",route:"",orderKind:context.orderKind||"",assignment:"all",lifecycle:"active",processes:context.processes||null};
  container.innerHTML=`<section class="panel"><div class="panel-header"><div><h3>${esc(context.label||"Pedidos")}</h3><p>Consulta paginada directamente desde Supabase. No existe límite artificial de 25 pedidos.</p></div></div>
    <div class="toolbar">
      <input data-filter="search" placeholder="Buscar pedido, cliente o referencia">
      <select data-filter="status"><option value="">Todos los estados</option><option value="ASIGNADO">Asignado</option><option value="EN_PROCESO">En proceso</option><option value="EN_ESPERA">En espera</option><option value="CERRADO">Cerrado</option><option value="CANCELADO">Cancelado</option></select>
      <select data-filter="route"><option value="">Todas las rutas</option><option value="cliente_punto">Punto</option><option value="cliente_recoge">Recoge</option><option value="despacho_local">Local</option><option value="despacho_nacional">Nacional</option></select>
      <select data-filter="orderKind"><option value="">Todos los tipos</option><option>PVC</option><option>PVN</option><option>PVE</option><option>PVP</option></select>
      <select data-filter="assignment"><option value="all">Todos</option><option value="mine">Asignados a mí</option><option value="unassigned">Sin asignar</option></select>
      <select data-filter="lifecycle"><option value="active">Activos</option><option value="terminal">Cerrados/cancelados</option><option value="all">Todos</option></select>
    </div><div data-table></div></section>`;
  const table=$("[data-table]",container);
  let searchTimer;
  $$('[data-filter]',container).forEach(control=>control.addEventListener(control.tagName==="INPUT"?"input":"change",()=>{
    clearTimeout(searchTimer);searchTimer=setTimeout(()=>{state[control.dataset.filter]=control.value;state.page=1;load();},control.tagName==="INPUT"?280:0);
  }));
  async function load(){
    setLoading(table,"Consultando pedidos…");
    try{
      const response=await API.cases(state);const rows=arrayFrom(response).map(normalizeCase);const pg=response.pagination||{};
      table.innerHTML=rows.length?`<div class="table-wrap"><table class="data-table"><thead><tr><th>Pedido</th><th>Cliente</th><th>Tipo</th><th>Proceso</th><th>Estado</th><th>Ruta</th><th>Asignado</th><th>Actualización</th></tr></thead><tbody>${rows.map(c=>`<tr><td><button class="link-button" data-case="${esc(c.caseId)}">${esc(c.reference)}</button>${c.priority?`<br>${badge(c.priority)}`:""}</td><td>${esc(c.client)}</td><td>${esc(c.orderKind||"—")}</td><td>${esc(title(c.currentProcess)||"—")}</td><td>${badge(c.status)}</td><td>${esc(title(c.route)||"—")}</td><td>${esc(c.assignedName||"—")}</td><td>${fmtDate(c.updatedAt)}</td></tr>`).join("")}</tbody></table></div><div class="pagination"><button class="btn btn-secondary" data-prev ${state.page<=1?"disabled":""}>Anterior</button><span>Página ${pg.page||state.page} de ${pg.totalPages||pg.total_pages||1} · ${fmtNumber(pg.totalItems||pg.total_items||rows.length)} registros</span><button class="btn btn-secondary" data-next ${pg.hasNextPage===false||state.page>=(pg.totalPages||pg.total_pages||1)?"disabled":""}>Siguiente</button></div>`:'<div class="empty-state">No hay pedidos para los filtros seleccionados.</div>';
      $$('[data-case]',table).forEach(b=>b.onclick=()=>openCaseDrawer(b.dataset.case,context));
      const prev=$("[data-prev]",table),next=$("[data-next]",table);if(prev)prev.onclick=()=>{state.page--;load()};if(next)next.onclick=()=>{state.page++;load()};
    }catch(error){setError(table,error)}
  }
  context.refresh=load;await load();return {refresh:load};
}

function relationArray(detail,...names){for(const name of names){const v=detail?.[name];if(Array.isArray(v))return v;if(v?.items&&Array.isArray(v.items))return v.items;}return []}
function getCaseObject(detail){return detail.case||detail.data?.case||detail.record||detail}

export async function openCaseDrawer(caseId,context={}){
  const drawer=$("#case-drawer"),backdrop=$("#drawer-backdrop");drawer.classList.remove("hidden");backdrop.classList.remove("hidden");drawer.innerHTML='<div class="loading-state"><div class="spinner" style="margin:auto"></div><p>Cargando pedido…</p></div>';
  const close=()=>{drawer.classList.add("hidden");backdrop.classList.add("hidden");drawer.innerHTML=""};backdrop.onclick=close;
  try{
    const [detail,actions]=await Promise.all([API.caseDetail(caseId),API.caseActions(caseId)]);const c=getCaseObject(detail);const items=relationArray(detail,"items","caseItems","case_items");const history=relationArray(detail,"history","stateHistory","caseStateHistory","case_state_history","events");const comments=relationArray(detail,"comments","caseComments","case_comments");const requests=relationArray(detail,"requests","workflowRequests","workflow_requests");
    drawer.innerHTML=`<header class="drawer-header"><div><p class="eyebrow">${esc(c.order_kind||c.orderKind||"Pedido")}</p><h3>${esc(c.reference||c.case_id||caseId)}</h3><small>${esc(c.client||"")}</small></div><button class="icon-btn" data-close>×</button></header><div class="drawer-body">
      <div class="tabs"><button class="tab-btn active" data-tab="summary">Resumen</button><button class="tab-btn" data-tab="items">Ítems (${items.length})</button><button class="tab-btn" data-tab="history">Historial (${history.length})</button><button class="tab-btn" data-tab="comments">Comentarios (${comments.length})</button><button class="tab-btn" data-tab="requests">Solicitudes (${requests.length})</button><button class="tab-btn" data-tab="actions">Acciones</button></div>
      <div data-pane="summary">${renderSummary(c)}</div><div data-pane="items" class="hidden">${renderItems(items)}</div><div data-pane="history" class="hidden">${renderHistory(history)}</div><div data-pane="comments" class="hidden">${renderComments(comments,caseId)}</div><div data-pane="requests" class="hidden">${renderRequests(requests)}</div><div data-pane="actions" class="hidden">${renderActions(actions)}</div>
    </div>`;
    $("[data-close]",drawer).onclick=close;$$('[data-tab]',drawer).forEach(btn=>btn.onclick=()=>{$$('[data-tab]',drawer).forEach(x=>x.classList.toggle("active",x===btn));$$('[data-pane]',drawer).forEach(x=>x.classList.toggle("hidden",x.dataset.pane!==btn.dataset.tab));});
    $$('[data-action]',drawer).forEach(btn=>btn.onclick=()=>openActionModal(caseId,JSON.parse(decodeURIComponent(btn.dataset.action)),async()=>{close();await context.refresh?.();}));
    const add=$("[data-add-comment]",drawer);if(add)add.onclick=()=>openCommentModal(caseId,async()=>{close();await openCaseDrawer(caseId,context)});
  }catch(error){drawer.innerHTML=`<div class="empty-state"><h3>No fue posible abrir el pedido</h3><p>${esc(error.message)}</p><button class="btn btn-secondary" data-close>Cerrar</button></div>`;$("[data-close]",drawer).onclick=close;}
}

function renderSummary(c){const fields=[["case_id","ID"],["reference","Referencia"],["client","Cliente"],["order_kind","Tipo"],["payment_condition","Condición de pago"],["delivery_type","Entrega"],["current_process","Proceso actual"],["status","Estado"],["assigned_name","Asignado a"],["sales_advisor","Asesor"],["purchase_order","Orden de compra"],["requested_delivery","Entrega solicitada"],["created_at","Creado"],["updated_at","Actualizado"]];return `<div class="detail-grid">${fields.map(([k,l])=>{let v=c[k]??c[k.replace(/_([a-z])/g,(_,x)=>x.toUpperCase())];if(k.endsWith("_at"))v=fmtDate(v);return `<div class="detail-item"><span>${esc(l)}</span><strong>${esc(v??"—")}</strong></div>`}).join("")}</div>${c.description?`<section class="panel" style="margin-top:14px"><h4>Descripción</h4><p>${esc(c.description)}</p></section>`:""}`}
function renderItems(items){if(!items.length)return '<div class="empty-state">Este pedido no tiene ítems registrados.</div>';return `<div class="table-wrap"><table class="data-table"><thead><tr><th>Referencia</th><th>Descripción</th><th>Cantidad</th><th>Unidad</th><th>Estado</th><th>Ubicación</th></tr></thead><tbody>${items.map(i=>`<tr><td>${esc(i.reference||i.referencia||"—")}</td><td>${esc(i.description||i.descripcion||"—")}</td><td>${esc(i.quantity_text||i.quantity||i.cantidad||i.quantity_numeric||"—")}</td><td>${esc(i.unit||i.unidad||"—")}</td><td>${badge(i.item_status||i.status)}</td><td>${esc(i.location||i.ubicacion||"—")}</td></tr>`).join("")}</tbody></table></div>`}
function renderHistory(history){if(!history.length)return '<div class="empty-state">Sin historial registrado.</div>';return `<div class="timeline">${history.map(h=>`<article class="timeline-item"><strong>${esc(title(h.process_code||h.current_process||h.event_type||h.status||"Evento"))}</strong><span>${fmtDate(h.timestamp||h.created_at||h.started_at)}</span><p>${esc(h.detail||h.reason||h.description||"")}</p></article>`).join("")}</div>`}
function renderComments(comments,caseId){return `<div style="display:flex;justify-content:flex-end;margin-bottom:12px"><button class="btn btn-primary" data-add-comment>Agregar comentario</button></div>${comments.length?`<div class="timeline">${comments.map(c=>`<article class="comment"><div class="comment-header"><strong>${esc(c.created_by_name||c.createdByName||"Usuario")}</strong><span>${fmtDate(c.created_at||c.createdAt)}</span></div><p>${esc(c.body||c.comment||c.message||"")}</p></article>`).join("")}</div>`:'<div class="empty-state">Sin comentarios.</div>'}`}
function renderRequests(requests){if(!requests.length)return '<div class="empty-state">No hay solicitudes registradas.</div>';return `<div class="timeline">${requests.map(r=>`<article class="comment"><div class="comment-header"><strong>${esc(title(r.request_type||r.requestType))}</strong>${badge(r.status)}</div><p>${esc(r.reason||"")}</p><small>${esc(r.requested_by_name||r.requestedByName||"")} · ${fmtDate(r.created_at||r.createdAt)}</small></article>`).join("")}</div>`}
function collectActions(data){return [...arrayFrom(data.operationalActions),...arrayFrom(data.requestActions),...arrayFrom(data.pendingApprovals).map(x=>({...x,code:"decide_approval",label:`Decidir: ${title(x.requestType||x.request_type)}`,requestId:x.requestId||x.request_id}))]}
function renderActions(actions){const list=collectActions(actions);if(!list.length)return '<div class="empty-state">No hay acciones disponibles para este usuario en el estado actual.</div>';return `<div class="action-grid">${list.map(a=>`<button class="action-card" data-action="${encodeURIComponent(JSON.stringify(a))}"><strong>${esc(a.label||title(a.code))}</strong><span>${esc(a.category||a.actionType||"Acción controlada por Supabase")}</span></button>`).join("")}</div>`}

function fieldHtml(field,catalog={}){const name=field.name,label=field.label||title(name),required=field.required?"required":"";if(field.type==="textarea")return `<label class="span-2">${esc(label)}<textarea name="${esc(name)}" rows="4" ${required}></textarea></label>`;if(field.type==="checkbox"||field.type==="boolean")return `<label class="span-2"><span><input type="checkbox" name="${esc(name)}"> ${esc(label)}</span></label>`;if(field.type==="select")return `<label>${esc(label)}<select name="${esc(name)}" ${required}><option value="">Seleccione…</option>${(field.options||[]).map(o=>{const v=typeof o==="string"?o:o.code;const l=typeof o==="string"?title(o):o.label;return `<option value="${esc(v)}">${esc(l)}</option>`}).join("")}</select></label>`;if(field.type==="user_select"){const users=catalog.assignmentPools?.[field.source]||catalog.assignmentPools?.[field.source==="alistamiento"?"alistamiento":"corte"]||[];return `<label>${esc(label)}<select name="${esc(name)}" ${required}><option value="">Seleccione…</option>${users.map(u=>`<option value="${esc(u.uid||u.email)}">${esc(u.name||u.email)} · ${esc(u.role||"")}</option>`).join("")}</select></label>`}if(field.type==="file"||field.type==="file_or_url")return `<label class="span-2">${esc(label)}<input type="file" name="${esc(name)}" ${required}><small>Se cargará a Google Drive.</small></label>`;return `<label>${esc(label)}<input type="${esc(field.type||"text")}" name="${esc(name)}" ${required}></label>`}

async function openActionModal(caseId,action,onDone){const code=normalize(action.code||action.actionCode||""),fields=(action.fields?.length?action.fields:DEFAULT_ACTION_FIELDS[code])||[];let catalog={};try{catalog=await API.catalog()}catch(_){catalog={}};if(code==="decide_approval")fields.splice(0,fields.length,{name:"decision",label:"Decisión",type:"select",options:[{code:"APPROVED",label:"Aprobar"},{code:"REJECTED",label:"Rechazar"}],required:true},{name:"reason",label:"Motivo de la decisión",type:"textarea",required:true});openModal({titleText:action.label||title(code),body:`<form id="action-form" class="form-grid">${fields.map(f=>fieldHtml(f,catalog)).join("")}</form>`,confirmText:"Ejecutar",onConfirm:async modal=>{const form=$("#action-form",modal);if(!form.reportValidity())return false;const payload=formDataObject(form);if(action.requestId)payload.requestId=action.requestId;for(const input of $$('input[type="file"]',form)){if(input.files?.[0]){toast("Cargando archivo a Drive","ok",input.files[0].name);const uploaded=await uploadToDrive(input.files[0],["ERP_V9",caseId,code]);payload[input.name]=uploaded;}}
      await API.execute(caseId,code,payload);toast("Acción completada","ok",action.label||title(code));await onDone?.();return true;}})}

function openCommentModal(caseId,onDone){openModal({titleText:"Agregar comentario",body:'<form id="comment-form" class="form-grid"><label class="span-2">Comentario<textarea name="body" rows="5" required></textarea></label><label>Tipo<select name="commentType"><option value="COMMENT">Comentario</option><option value="NOVELTY">Novedad</option><option value="SUPERVISION">Supervisión</option></select></label><label>Visibilidad<select name="visibility"><option value="CASE">Pedido</option><option value="INTERNAL">Interna</option></select></label></form>',onConfirm:async modal=>{const form=$("#comment-form",modal);if(!form.reportValidity())return false;await API.addComment(caseId,formDataObject(form));toast("Comentario registrado");await onDone?.();return true;}})}
