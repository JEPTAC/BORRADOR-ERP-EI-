import {api} from "../services/api.js";
import {state,can} from "../core/state.js";
import {fmt,statusBadge,priorityBadge} from "../core/format.js";
import {modal,toast,serializeForm,paginationHtml,empty,loading} from "../core/ui.js";
import {uploadOrderFile} from "../services/drive.js";

let currentList={filters:{page:1,pageSize:50,assignment:"ALL",includeHistory:true},root:null,data:null};

export async function renderOrders(root,{moduleId="orders",params={}}={}){
  currentList.root=root;
  currentList.filters={...currentList.filters,...params,page:Number(params.page||1)};
  root.innerHTML=`
    <section class="page-head">
      <div>
        <h2>${moduleId==="sales"?"Registro y control comercial":"Bandeja integral de pedidos"}</h2>
        <p>Paginación real, colas por etapa, responsables, SLA, control de versión y expediente completo.</p>
      </div>
      <div class="page-actions">
        ${can("orders","canCreate")||can("sales","canCreate")?'<button class="btn btn-primary" id="create-order">＋ Crear pedido</button>':""}
        <button class="btn btn-ghost" id="export-list">Exportar página</button>
      </div>
    </section>
    <section class="card card-pad">
      <div class="toolbar">
        <input class="control search-wide" id="f-search" placeholder="Pedido, cliente o referencia" value="${fmt.escape(currentList.filters.search||"")}">
        ${select("f-step","Etapa",state.catalogs.steps,"code","name",currentList.filters.step)}
        ${simpleSelect("f-status","Estado",["QUEUED","ASSIGNED","IN_PROGRESS","WAITING","BLOCKED","CLOSED","CANCELLED"],currentList.filters.status)}
        ${select("f-type","Tipo",state.catalogs.orderTypes,"code","name",currentList.filters.orderType)}
        ${select("f-route","Ruta",state.catalogs.deliveryRoutes,"code","name",currentList.filters.route)}
        ${simpleSelect("f-assignment","Asignación",["ALL","MINE","UNASSIGNED"],currentList.filters.assignment)}
        <label class="filter-pill"><input type="checkbox" id="f-history" ${currentList.filters.includeHistory!==false?"checked":""}> Histórico</label>
        <button class="btn btn-primary" id="apply-filters">Filtrar</button>
      </div>
      <div id="orders-result">${loading("Cargando pedidos…")}</div>
    </section>`;

  root.querySelector("#create-order")?.addEventListener("click",openCreateOrder);
  root.querySelector("#apply-filters").onclick=()=>loadOrders(1);
  root.querySelector("#f-search").onkeydown=e=>{if(e.key==="Enter")loadOrders(1)};
  root.querySelector("#export-list").onclick=exportCurrent;
  if(moduleId==="sales"&&params.create==="1")openCreateOrder();
  await loadOrders(currentList.filters.page);
}

async function loadOrders(page=1){
  const root=currentList.root;
  if(!root?.isConnected)return;
  const result=root.querySelector("#orders-result");
  result.innerHTML=loading("Consultando la operación…");
  const filters={
    search:root.querySelector("#f-search").value.trim(),
    step:root.querySelector("#f-step").value,
    status:root.querySelector("#f-status").value,
    orderType:root.querySelector("#f-type").value,
    route:root.querySelector("#f-route").value,
    assignment:root.querySelector("#f-assignment").value,
    includeHistory:root.querySelector("#f-history").checked,
    page,
    pageSize:50
  };
  currentList.filters=filters;
  const data=await api.listOrders(filters);
  currentList.data=data;
  result.innerHTML=data.items.length?`${ordersTable(data.items)}${paginationHtml(data.pagination)}`:empty("No se encontraron pedidos","Ajuste los filtros o cree un pedido nuevo.");
  result.querySelectorAll("[data-order]").forEach(x=>x.onclick=()=>openOrder(x.dataset.order));
  result.querySelectorAll("[data-page]").forEach(x=>x.onclick=()=>loadOrders(Number(x.dataset.page)));
}

function ordersTable(rows){
  return `<div class="table-wrap"><table><thead><tr><th>Pedido</th><th>Cliente</th><th>Tipo / pago</th><th>Etapa</th><th>Estado</th><th>Responsable</th><th>Tiempo etapa</th><th>Prioridad</th><th>Actualizado</th></tr></thead><tbody>${rows.map(o=>`<tr>
    <td><span class="table-link" data-order="${o.id}">${fmt.escape(o.orderNumber)}</span><div class="cell-sub">${fmt.escape(o.externalReference||"")}</div></td>
    <td><div class="cell-main">${fmt.escape(o.clientName)}</div><div class="cell-sub">${fmt.escape(o.route)}</div></td>
    <td><span class="badge badge-blue">${fmt.escape(o.orderType)}</span><div class="cell-sub">${fmt.escape(o.paymentCondition)}</div></td>
    <td><div class="cell-main">${fmt.escape(o.stepName||o.currentStep)}</div><div class="cell-sub">${fmt.escape(o.currentStep)}</div></td>
    <td>${statusBadge(o.status)}${o.slaExceeded?'<div class="cell-sub danger">SLA excedido</div>':""}</td>
    <td>${fmt.escape(o.assigneeName||"En cola")}<div class="cell-sub">${fmt.escape(o.roleCode||"")}</div></td>
    <td>${fmt.hours(o.ageBusinessSeconds)}</td>
    <td>${priorityBadge(o.priority)}</td>
    <td>${fmt.date(o.updatedAt)}</td>
  </tr>`).join("")}</tbody></table></div>`;
}

function select(id,label,items=[],valueKey="code",labelKey="name",selected=""){
  return `<select class="control" id="${id}"><option value="">${label}: todos</option>${items.map(x=>`<option value="${fmt.escape(x[valueKey])}" ${x[valueKey]===selected?"selected":""}>${fmt.escape(x[labelKey])}</option>`).join("")}</select>`;
}
function simpleSelect(id,label,items,selected=""){
  return `<select class="control" id="${id}"><option value="">${label}: todos</option>${items.map(x=>`<option value="${x}" ${x===selected?"selected":""}>${x}</option>`).join("")}</select>`;
}
function formSelect(name,items,valueKey=null,labelKey=null,selected=null){
  return `<select class="control" name="${name}" required>${items.map(x=>{const value=valueKey?x[valueKey]:x;const label=labelKey?x[labelKey]:x;return `<option value="${fmt.escape(value)}" ${value===(selected??"MEDIUM")?"selected":""}>${fmt.escape(label)}</option>`}).join("")}</select>`;
}

function openCreateOrder(){
  const types=state.catalogs.orderTypes||[];
  const payments=state.catalogs.paymentConditions||[];
  const routes=state.catalogs.deliveryRoutes||[];
  const m=modal({
    title:"Crear pedido",
    confirmLabel:"Crear y enrutar",
    body:`<form id="order-form"><div class="form-grid">
      <div class="field"><label>Número de pedido</label><input class="control" name="orderNumber" required></div>
      <div class="field"><label>Referencia externa</label><input class="control" name="externalReference"></div>
      <div class="field"><label>Tipo de pedido</label>${formSelect("orderType",types,"code","name",types[0]?.code)}</div>
      <div class="field"><label>Condición de pago</label>${formSelect("paymentCondition",payments,"code","name",payments[0]?.code)}</div>
      <div class="field"><label>Modalidad de entrega</label>${formSelect("deliveryRoute",routes,"code","name",routes[0]?.code)}</div>
      <div class="field"><label>Prioridad</label>${formSelect("priority",["LOW","MEDIUM","HIGH","URGENT","CRITICAL"])}</div>
      <div class="field"><label>Cliente</label><input class="control" name="clientName" required></div>
      <div class="field"><label>NIT / documento</label><input class="control" name="clientDocument"></div>
      <div class="field"><label>Ciudad</label><input class="control" name="clientCity"></div>
      <div class="field"><label>Dirección</label><input class="control" name="clientAddress"></div>
      <div class="field"><label>Teléfono</label><input class="control" name="clientPhone"></div>
      <div class="field"><label>Fecha solicitada</label><input class="control" name="requestedDeliveryDate" type="date"></div>
      <div class="field"><label><input type="checkbox" name="requiresCut"> Requiere corte</label></div>
      <div class="field"><label><input type="checkbox" name="requiresPurchase"> Requiere compra</label></div>
      <div class="full">
        <div class="card-head" style="padding-left:0"><h3>Ítems del pedido</h3><button class="btn btn-ghost" type="button" id="add-item">＋ Agregar línea</button></div>
        <div class="items-editor" id="items-editor"></div>
      </div>
    </div></form>`,
    onConfirm:async()=>{
      const form=document.querySelector("#order-form");
      if(!form.reportValidity())throw new Error("Complete los campos obligatorios.");
      const data=serializeForm(form);
      const items=[...document.querySelectorAll(".item-row")].map((row,i)=>({
        lineNumber:i+1,
        sku:row.querySelector('[name="sku"]').value.trim()||null,
        reference:row.querySelector('[name="reference"]').value.trim()||null,
        description:row.querySelector('[name="description"]').value.trim(),
        quantity:Number(row.querySelector('[name="quantity"]').value),
        unit:row.querySelector('[name="unit"]').value.trim()||"UND",
        warehouseLocation:row.querySelector('[name="location"]').value.trim()||null,
        requiresCut:row.querySelector('[name="itemCut"]').checked,
        requestedCutLength:Number(row.querySelector('[name="cutLength"]').value||0)||null
      }));
      if(!items.length||items.some(i=>!i.description||!Number.isFinite(i.quantity)||i.quantity<=0))throw new Error("Registre al menos un ítem válido.");
      const result=await api.createOrder({...data,items});
      toast(`Pedido ${result.orderNumber} creado y enviado a ${result.currentStep}.`);
      await loadOrders(1);
      setTimeout(()=>openOrder(result.orderId),150);
    }
  });
  const editor=m.root.querySelector("#items-editor");
  const add=()=>{
    const row=document.createElement("div");
    row.className="item-row item-row-enterprise";
    row.innerHTML=`
      <input class="control" name="sku" placeholder="SKU">
      <input class="control" name="reference" placeholder="Referencia">
      <input class="control" name="description" placeholder="Descripción" required>
      <input class="control" name="quantity" type="number" min="0.0001" step="any" placeholder="Cantidad" required>
      <input class="control" name="unit" value="UND" placeholder="Unidad">
      <input class="control" name="location" placeholder="Ubicación sugerida">
      <label class="filter-pill"><input type="checkbox" name="itemCut"> Corte</label>
      <input class="control" name="cutLength" type="number" step="any" placeholder="Longitud">
      <button type="button" class="icon-btn" title="Eliminar línea">×</button>`;
    row.querySelector("button").onclick=()=>row.remove();
    editor.append(row);
  };
  m.root.querySelector("#add-item").onclick=add;
  add();
}

export async function openOrder(orderId){
  document.querySelector(".drawer-overlay")?.remove();
  document.querySelector(".drawer")?.remove();
  const overlay=document.createElement("div");
  overlay.className="drawer-overlay";
  const drawer=document.createElement("aside");
  drawer.className="drawer";
  drawer.innerHTML=loading("Abriendo expediente del pedido…");
  document.body.append(overlay,drawer);
  overlay.onclick=()=>closeDrawer(drawer,overlay);
  try{
    const data=await api.getOrder(orderId);
    renderOrderDrawer(drawer,overlay,data);
  }catch(e){
    drawer.innerHTML=`<div class="card-pad danger">${fmt.escape(e.message)}</div>`;
  }
}

function closeDrawer(drawer,overlay){overlay?.remove();drawer?.remove()}
async function refreshOrder(orderId,drawer,overlay){
  drawer.innerHTML=loading("Actualizando expediente…");
  const data=await api.getOrder(orderId);
  renderOrderDrawer(drawer,overlay,data);
}

function renderOrderDrawer(drawer,overlay,data){
  const o=data.order;
  const actions=data.actions?.actions||[];
  const domainActions=data.actions?.domainActions||[];
  drawer.innerHTML=`
    <header class="drawer-head">
      <div class="drawer-title"><h2>${fmt.escape(o.order_number)}</h2><div>${statusBadge(o.status)} ${priorityBadge(o.priority)} <span class="muted">${fmt.escape(o.client_name)}</span></div></div>
      <button class="icon-btn" id="close-drawer">×</button>
    </header>
    <div class="drawer-content">
      ${(actions.length||domainActions.length)?`<section class="action-panel">
        <div class="cell-sub" style="margin-bottom:9px">ACCIONES AUTORIZADAS · VERSIÓN ${o.version}</div>
        <div class="action-row">
          ${actions.map(a=>actionButton(a)).join("")}
          ${domainActions.map(a=>`<button class="btn btn-ghost" data-domain="${a.code}">${fmt.escape(a.label)}</button>`).join("")}
        </div>
      </section>`:""}
      <div class="detail-tabs">
        <button class="detail-tab active" data-tab="summary">Resumen</button>
        <button class="detail-tab" data-tab="items">Ítems (${data.items.length})</button>
        <button class="detail-tab" data-tab="controls">Controles</button>
        <button class="detail-tab" data-tab="checklist">Checklist (${(data.checklist||[]).filter(x=>x.completed).length}/${(data.checklist||[]).length})</button>
        <button class="detail-tab" data-tab="timeline">Trazabilidad (${data.events.length})</button>
        <button class="detail-tab" data-tab="times">Tiempos</button>
        <button class="detail-tab" data-tab="docs">Documentos (${data.files.length})</button>
        <button class="detail-tab" data-tab="comments">Comentarios (${data.comments.length})</button>
        <button class="detail-tab" data-tab="approvals">Aprobaciones (${data.approvals.length})</button>
      </div>
      <div id="detail-panel">${summaryTab(data)}</div>
    </div>`;

  drawer.querySelector("#close-drawer").onclick=()=>closeDrawer(drawer,overlay);
  drawer.querySelectorAll("[data-tab]").forEach(b=>b.onclick=()=>{
    drawer.querySelectorAll("[data-tab]").forEach(x=>x.classList.toggle("active",x===b));
    drawer.querySelector("#detail-panel").innerHTML=tabContent(b.dataset.tab,data);
  });
  drawer.querySelectorAll("[data-action]").forEach(b=>b.onclick=()=>handleAction(data,b.dataset.action,drawer,overlay));
  drawer.querySelectorAll("[data-domain]").forEach(b=>b.onclick=()=>handleDomain(data,b.dataset.domain,drawer,overlay));
}

function actionButton(a){
  const css=a.kind==="success"?"btn-success":a.kind==="danger"?"btn-danger":a.kind==="warning"?"btn-warning":a.kind==="primary"?"btn-primary":"btn-ghost";
  return `<button class="btn ${css}" data-action="${a.code}">${fmt.escape(a.label)}</button>`;
}
function info(label,value){return `<div class="info-box"><label>${fmt.escape(label)}</label><strong>${fmt.escape(value??"—")}</strong></div>`}
function summaryTab(d){
  const o=d.order;
  const active=d.tasks.find(t=>["QUEUED","ASSIGNED","IN_PROGRESS","WAITING","BLOCKED"].includes(t.status));
  return `<div class="detail-grid">
    ${info("Cliente",o.client_name)}${info("Tipo",o.order_type_code)}${info("Pago",o.payment_condition_code)}${info("Ruta",o.delivery_route_code)}
    ${info("Etapa",o.current_step_code)}${info("Estado",o.status)}${info("Responsable",o.current_role_code||"En cola")}${info("Versión",o.version)}
    ${info("Creado",fmt.date(o.created_at))}${info("Actualizado",fmt.date(o.updated_at))}${info("Requiere corte",o.requires_cut?"Sí":"No")}${info("Requiere compra",o.requires_purchase?"Sí":"No")}
  </div>
  <div style="height:16px"></div>
  <div class="grid grid-2">
    <section class="card"><header class="card-head"><h3>Ruta operativa</h3></header><div class="card-body">${tasksTimeline(d.tasks)}</div></section>
    <section class="card"><header class="card-head"><h3>Control de etapa actual</h3></header><div class="card-body">${active?stageControlSummary(active,d.checklist||[]):'<p class="muted">No existe una tarea operativa activa.</p>'}</div></section>
  </div>`;
}
function stageControlSummary(task,checklist){
  const rows=checklist.filter(x=>x.task_id===task.id);
  const done=rows.filter(x=>x.completed).length;
  return `<div class="detail-grid" style="grid-template-columns:repeat(2,minmax(0,1fr))">${info("Tarea",task.step_code)}${info("Estado",task.status)}${info("Controles",`${done}/${rows.length}`)}${info("Asignado",task.assigned_role_code||"En cola")}</div><div style="height:12px"></div><div class="progress"><span style="width:${rows.length?done/rows.length*100:100}%"></span></div>`;
}
function tabContent(tab,d){
  if(tab==="summary")return summaryTab(d);
  if(tab==="items")return itemsTab(d.items);
  if(tab==="controls")return controlsTab(d);
  if(tab==="checklist")return checklistTab(d);
  if(tab==="timeline")return eventsTab(d.events);
  if(tab==="times")return timesTab(d.tasks,d.sessions);
  if(tab==="docs")return docsTab(d.files);
  if(tab==="comments")return commentsTab(d.comments);
  if(tab==="approvals")return approvalsTab(d.approvals);
  return "";
}
function tasksTimeline(tasks){return `<div class="timeline">${tasks.map(t=>`<div class="timeline-item"><h4>${fmt.escape(t.step_code)} · ${statusBadge(t.status)}</h4><p>${fmt.escape(t.result_detail||t.assigned_role_code||"Tarea de proceso")}</p><time>${fmt.date(t.created_at)}${t.completed_at?` → ${fmt.date(t.completed_at)}`:""}</time></div>`).join("")}</div>`}
function itemsTab(items){return items.length?`<div class="table-wrap"><table style="min-width:860px"><thead><tr><th>Línea</th><th>SKU</th><th>Referencia</th><th>Descripción</th><th>Cantidad</th><th>Unidad</th><th>Ubicación</th><th>Corte</th></tr></thead><tbody>${items.map(i=>`<tr><td>${i.line_number}</td><td>${fmt.escape(i.sku||"—")}</td><td>${fmt.escape(i.reference||"—")}</td><td>${fmt.escape(i.description)}</td><td>${fmt.number(i.quantity,3)}</td><td>${fmt.escape(i.unit)}</td><td>${fmt.escape(i.warehouse_location||"—")}</td><td>${i.requires_cut?"Sí":"No"}</td></tr>`).join("")}</tbody></table></div>`:empty()}
function controlsTab(d){
  const cards=[];
  if(d.financialValidations?.length)cards.push(controlTable("Validaciones financieras",d.financialValidations,["validation_type","decision","amount","reference","notes","created_at"]));
  if(d.purchaseOrders?.length)cards.push(controlTable("Órdenes de compra",d.purchaseOrders,["po_number","supplier_name","status","total_amount","expected_at"]));
  if(d.receipts?.length)cards.push(controlTable("Recepciones",d.receipts,["receipt_number","purchase_order","supplier_name","status","received_at"]));
  if(d.cutJobs?.length)cards.push(controlTable("Trabajos de corte",d.cutJobs,["requested_length","actual_length","scrap_length","status","completed_at"]));
  if(d.invoices?.length)cards.push(controlTable("Facturas",d.invoices,["invoice_number","invoice_date","amount","status"]));
  if(d.deliveries?.length)cards.push(controlTable("Despachos y entregas",d.deliveries,["route_code","status","scheduled_at","tracking_number","received_by"]));
  return cards.length?`<div class="grid grid-2">${cards.join("")}</div>`:empty("Sin controles de dominio","Registre el soporte requerido para la etapa actual.");
}
function controlTable(title,rows,fields){return `<article class="card"><header class="card-head"><h3>${fmt.escape(title)}</h3></header><div class="card-body"><div class="table-wrap"><table style="min-width:640px"><thead><tr>${fields.map(f=>`<th>${fmt.escape(f.replaceAll("_"," "))}</th>`).join("")}</tr></thead><tbody>${rows.map(r=>`<tr>${fields.map(f=>`<td>${fmt.escape(formatCell(r[f]))}</td>`).join("")}</tr>`).join("")}</tbody></table></div></div></article>`}
function formatCell(v){if(v==null||v==="")return "—";if(typeof v==="number")return fmt.number(v,2);if(typeof v==="string"&&/^\d{4}-\d{2}-\d{2}T/.test(v))return fmt.date(v);return String(v)}
function checklistTab(d){
  const active=d.tasks.find(t=>["QUEUED","ASSIGNED","IN_PROGRESS","WAITING","BLOCKED"].includes(t.status));
  const rows=(d.checklist||[]).filter(x=>!active||x.task_id===active.id);
  return rows.length?`<div class="checklist-list">${rows.map(x=>`<label class="checklist-item ${x.completed?"done":""}"><input type="checkbox" disabled ${x.completed?"checked":""}><span><strong>${fmt.escape(x.label)}</strong><small>${x.required?"Obligatorio":"Opcional"}${x.note?` · ${fmt.escape(x.note)}`:""}</small></span></label>`).join("")}</div>`:empty("Sin checklist","La etapa no tiene controles configurados.");
}
function eventsTab(events){return events.length?`<div class="timeline">${events.map(e=>`<div class="timeline-item"><h4>${fmt.escape(e.actionCode||e.eventType)}</h4><p>${fmt.escape([e.fromStep,e.toStep].filter(Boolean).join(" → "))} · ${fmt.escape(e.actorName||"Sistema")} (${fmt.escape(e.actorRole||"")})</p><time>${fmt.date(e.createdAt)}</time></div>`).join("")}</div>`:empty()}
function timesTab(tasks,sessions){return `<div class="table-wrap"><table style="min-width:860px"><thead><tr><th>Etapa</th><th>Estado</th><th>Tiempo transcurrido</th><th>Tiempo productivo laboral</th><th>Espera estimada</th><th>Sesiones</th></tr></thead><tbody>${tasks.map(t=>{const wait=Math.max(0,Number(t.raw_seconds||0)-Number(t.business_seconds||0));return `<tr><td>${fmt.escape(t.step_code)}</td><td>${statusBadge(t.status)}</td><td>${fmt.hours(t.raw_seconds)}</td><td>${fmt.hours(t.business_seconds)}</td><td>${fmt.hours(wait)}</td><td>${sessions.filter(s=>s.task_id===t.id).length}</td></tr>`}).join("")}</tbody></table></div>`}
function docsTab(files){return files.length?`<div class="grid grid-2">${files.map(f=>`<a class="card card-pad" href="${fmt.escape(f.web_view_link||"#")}" target="_blank" rel="noopener"><strong>${fmt.escape(f.file_name)}</strong><div class="cell-sub">${fmt.escape(f.file_category)} · ${fmt.date(f.created_at)}</div></a>`).join("")}</div>`:empty("Sin documentos","Use “Subir evidencia” para registrar archivos en Drive.")}
function commentsTab(comments){return comments.length?`<div class="timeline">${comments.map(c=>`<div class="timeline-item"><h4>${fmt.escape(c.author)} · ${fmt.escape(c.type)}</h4><p>${fmt.escape(c.body)}</p><time>${fmt.date(c.createdAt)}</time></div>`).join("")}</div>`:empty()}
function approvalsTab(rows){return rows.length?`<div class="table-wrap"><table style="min-width:760px"><thead><tr><th>Tipo</th><th>Estado</th><th>Motivo</th><th>Decisión</th><th>Fecha</th></tr></thead><tbody>${rows.map(a=>`<tr><td>${fmt.escape(a.request_type)}</td><td>${statusBadge(a.status)}</td><td>${fmt.escape(a.reason)}</td><td>${fmt.escape(a.decision_reason||"—")}</td><td>${fmt.date(a.created_at)}</td></tr>`).join("")}</tbody></table></div>`:empty()}

async function handleAction(data,action,drawer,overlay){
  const order=data.order;
  if(["CLAIM","START","RESUME"].includes(action))return execute(order,action,{detail:`${action} desde consola operativa`},drawer,overlay);
  if(action==="COMPLETE")return promptAction(order,action,"Finalizar etapa","Resultado y observaciones","Finalizar",drawer,overlay);
  if(["WAIT","BLOCK","NO_DELIVERY"].includes(action))return promptAction(order,action,action==="NO_DELIVERY"?"Registrar no entrega":"Registrar espera o bloqueo","Motivo obligatorio",action==="NO_DELIVERY"?"Registrar":"Guardar",drawer,overlay,"reason");
  if(action==="COMMENT")return promptAction(order,action,"Agregar comentario","Escriba el comentario","Publicar",drawer,overlay,"body");
  if(action==="REQUEST_APPROVAL")return approvalRequest(order,drawer,overlay);
  if(action==="ASSIGN")return assignmentModal(data,drawer,overlay);
  if(action==="REPROGRAM")return reprogramModal(order,drawer,overlay);
}
function promptAction(order,action,title,label,confirm,drawer,overlay,key="detail"){
  modal({title,confirmLabel:confirm,body:`<form id="action-form"><div class="field"><label>${label}</label><textarea class="control" name="value" required></textarea></div></form>`,onConfirm:async()=>{const value=document.querySelector('#action-form [name="value"]').value.trim();if(!value)throw new Error("Debe registrar el detalle.");await execute(order,action,{[key]:value},drawer,overlay)}});
}
async function assignmentModal(data,drawer,overlay){
  const pool=await api.assignmentPool(data.order.current_step_code);
  modal({title:"Asignar responsable",confirmLabel:"Asignar",body:`<form id="assign-form"><div class="field"><label>Responsable habilitado</label><select class="control" name="profileId" required><option value="">Seleccione…</option>${pool.map(p=>`<option value="${p.id}">${fmt.escape(p.name)} · ${fmt.escape((p.roles||[]).join(", "))}</option>`).join("")}</select></div></form>`,onConfirm:async()=>{const d=serializeForm(document.querySelector("#assign-form"));await execute(data.order,"ASSIGN",d,drawer,overlay)}});
}
function reprogramModal(order,drawer,overlay){
  modal({title:"Reprogramar entrega",confirmLabel:"Reprogramar",body:`<form id="reprogram-form"><div class="field"><label>Nueva fecha y hora</label><input class="control" name="scheduledAt" type="datetime-local" required></div><div class="field"><label>Observación</label><textarea class="control" name="detail"></textarea></div></form>`,onConfirm:async()=>{const d=serializeForm(document.querySelector("#reprogram-form"));d.scheduledAt=new Date(d.scheduledAt).toISOString();await execute(order,"REPROGRAM",d,drawer,overlay)}});
}
function approvalRequest(order,drawer,overlay){
  modal({title:"Solicitar aprobación",confirmLabel:"Enviar solicitud",body:`<form id="approval-form"><div class="field"><label>Tipo</label><select class="control" name="requestType"><option>CANCELLATION</option><option>PRIORITY</option><option>ROUTE_CHANGE</option><option>REOPEN</option><option>STOCK_EXCEPTION</option><option>FLOW_EXCEPTION</option><option>PAYMENT_EXCEPTION</option><option>DATA_CORRECTION</option></select></div><div class="field"><label>Motivo</label><textarea class="control" name="reason" required></textarea></div><div class="field"><label>Prioridad o ruta destino</label><input class="control" name="value" placeholder="HIGH o LOCAL_DISPATCH"></div></form>`,onConfirm:async()=>{const d=serializeForm(document.querySelector("#approval-form"));const payload={requestType:d.requestType,reason:d.reason};if(d.requestType==="PRIORITY")payload.priority=(d.value||"HIGH").toUpperCase();if(d.requestType==="ROUTE_CHANGE")payload.route=d.value.toUpperCase();await execute(order,"REQUEST_APPROVAL",payload,drawer,overlay)}});
}
async function execute(order,action,payload,drawer,overlay){
  const result=await api.executeAction(order.id,action,payload,order.version);
  toast(`${action}: operación registrada.`);
  if(currentList.root?.isConnected)await loadOrders(currentList.filters.page);
  await refreshOrder(result.orderId||order.id,drawer,overlay);
}

async function handleDomain(data,type,drawer,overlay){
  if(type==="FILE")return fileModal(data,drawer,overlay);
  if(type==="CHECKLIST")return checklistModal(data,drawer,overlay);
  if(type==="FINANCIAL")return financialModal(data,drawer,overlay);
  if(type==="PURCHASE")return purchaseModal(data,drawer,overlay);
  if(type==="RECEIPT")return receiptModal(data,drawer,overlay);
  if(type==="CUT")return cutModal(data,drawer,overlay);
  if(type==="INVOICE")return invoiceModal(data,drawer,overlay);
  if(type==="DELIVERY")return deliveryModal(data,drawer,overlay);
  if(type==="STICKERS")return printStickers(data.order.id);
}
function afterDomain(data,drawer,overlay,message){toast(message);return refreshOrder(data.order.id,drawer,overlay)}
function fileModal(data,drawer,overlay){
  modal({title:"Subir evidencia a Google Drive",confirmLabel:"Subir archivo",body:`<form id="file-form"><div class="field"><label>Categoría</label><select class="control" name="category"><option>EVIDENCE</option><option>INVOICE</option><option>PAYMENT</option><option>PURCHASE_ORDER</option><option>RECEIPT</option><option>DELIVERY</option><option>QUALITY</option></select></div><div class="field"><label>Archivo</label><input class="control" name="file" type="file" required></div></form>`,onConfirm:async()=>{const form=document.querySelector("#file-form");const file=form.file.files[0];if(!file)throw new Error("Seleccione un archivo.");await uploadOrderFile(data.order.id,file,form.category.value,data.actions?.taskId||null,data.order.order_number||data.order.orderNumber);await afterDomain(data,drawer,overlay,"Archivo registrado en Drive.")}});
}
function checklistModal(data,drawer,overlay){
  const task=data.tasks.find(t=>["QUEUED","ASSIGNED","IN_PROGRESS","WAITING","BLOCKED"].includes(t.status));
  const rows=(data.checklist||[]).filter(x=>x.task_id===task?.id);
  if(!task||!rows.length)return toast("La etapa no tiene una lista de verificación activa.","error");
  modal({title:`Checklist · ${task.step_code}`,confirmLabel:"Guardar controles",body:`<form id="checklist-form"><div class="checklist-list">${rows.map(x=>`<div class="checklist-edit"><label class="checklist-item ${x.completed?"done":""}"><input type="checkbox" name="done_${x.item_code}" ${x.completed?"checked":""}><span><strong>${fmt.escape(x.label)}</strong><small>${x.required?"Obligatorio":"Opcional"}</small></span></label><input class="control" name="note_${x.item_code}" value="${fmt.escape(x.note||"")}" placeholder="Observación"></div>`).join("")}</div></form>`,onConfirm:async()=>{const form=document.querySelector("#checklist-form");for(const x of rows){const completed=form.querySelector(`[name="done_${CSS.escape(x.item_code)}"]`).checked;const note=form.querySelector(`[name="note_${CSS.escape(x.item_code)}"]`).value.trim()||null;if(completed!==x.completed||note!==(x.note||null))await api.updateChecklist(task.id,x.item_code,completed,note)}await afterDomain(data,drawer,overlay,"Checklist actualizado.")}});
}
function financialModal(data,drawer,overlay){
  const type=data.order.current_step_code;
  modal({title:`Validación de ${type}`,confirmLabel:"Registrar validación",body:`<form id="financial-form"><div class="form-grid"><div class="field"><label>Decisión</label><select class="control" name="decision"><option>APPROVED</option><option>REJECTED</option><option>PENDING</option></select></div><div class="field"><label>Valor</label><input class="control" name="amount" type="number" step="any"></div><div class="field"><label>Referencia</label><input class="control" name="reference"></div><div class="field full"><label>Notas</label><textarea class="control" name="notes" required></textarea></div></div></form>`,onConfirm:async()=>{const d=serializeForm(document.querySelector("#financial-form"));await api.saveFinancialValidation(data.order.id,{...d,validationType:type});await afterDomain(data,drawer,overlay,"Validación financiera registrada.")}});
}
function purchaseModal(data,drawer,overlay){
  modal({title:"Registrar orden de compra",confirmLabel:"Guardar orden",body:`<form id="purchase-form"><div class="form-grid"><div class="field"><label>Número OC</label><input class="control" name="poNumber" required></div><div class="field"><label>Proveedor</label><input class="control" name="supplierName" required></div><div class="field"><label>Estado</label><select class="control" name="status"><option>ISSUED</option><option>CONFIRMED</option><option>PARTIAL</option><option>RECEIVED</option></select></div><div class="field"><label>Valor total</label><input class="control" name="totalAmount" type="number" step="any"></div><div class="field"><label>Moneda</label><input class="control" name="currency" value="COP"></div><div class="field"><label>Fecha esperada</label><input class="control" name="expectedAt" type="datetime-local"></div></div></form>`,onConfirm:async()=>{const d=serializeForm(document.querySelector("#purchase-form"));if(d.expectedAt)d.expectedAt=new Date(d.expectedAt).toISOString();await api.savePurchaseOrder(data.order.id,d);await afterDomain(data,drawer,overlay,"Orden de compra registrada.")}});
}
function receiptModal(data,drawer,overlay){
  const itemOptions=data.items.map(i=>`<option value="${i.id}" data-sku="${fmt.escape(i.sku||"")}" data-description="${fmt.escape(i.description)}" data-unit="${fmt.escape(i.unit)}" data-quantity="${i.quantity}">${i.line_number} · ${fmt.escape(i.sku||i.reference||i.description)}</option>`).join("");
  const m=modal({title:"Registrar recepción de mercancía",confirmLabel:"Guardar recepción",body:`<form id="receipt-form"><div class="form-grid"><div class="field"><label>Número de recepción</label><input class="control" name="receiptNumber"></div><div class="field"><label>Orden de compra</label><input class="control" name="purchaseOrder"></div><div class="field"><label>Proveedor</label><input class="control" name="supplierName"></div><div class="field"><label>Estado</label><select class="control" name="status"><option>CONFORMING</option><option>PARTIAL</option><option>NONCONFORMING</option></select></div><div class="field full"><div class="card-head" style="padding-left:0"><h3>Líneas recibidas</h3><button type="button" class="btn btn-ghost" id="add-receipt-line">＋ Línea</button></div><div id="receipt-lines" class="items-editor"></div></div></div></form>`,onConfirm:async()=>{const form=document.querySelector("#receipt-form");const d=serializeForm(form);const lines=[...form.querySelectorAll(".receipt-line")].map(row=>({orderItemId:row.querySelector('[name="orderItemId"]').value||null,sku:row.querySelector('[name="sku"]').value||null,description:row.querySelector('[name="description"]').value,expectedQuantity:Number(row.querySelector('[name="expectedQuantity"]').value||0)||null,receivedQuantity:Number(row.querySelector('[name="receivedQuantity"]').value),acceptedQuantity:Number(row.querySelector('[name="acceptedQuantity"]').value),rejectedQuantity:Number(row.querySelector('[name="rejectedQuantity"]').value||0),unit:row.querySelector('[name="unit"]').value,location:row.querySelector('[name="location"]').value,lotNumber:row.querySelector('[name="lotNumber"]').value||null,qualityStatus:row.querySelector('[name="qualityStatus"]').value,metadata:{lotNumber:row.querySelector('[name="lotNumber"]').value||null}}));if(!lines.length||lines.some(x=>!x.description||x.receivedQuantity<=0))throw new Error("Registre al menos una línea válida.");await api.saveReceipt(data.order.id,{receiptNumber:d.receiptNumber,purchaseOrder:d.purchaseOrder,supplierName:d.supplierName,status:d.status,lines});await afterDomain(data,drawer,overlay,"Recepción, calidad e inventario registrados.")}});
  const root=m.root.querySelector("#receipt-lines");
  const add=()=>{const row=document.createElement("div");row.className="receipt-line card card-pad";row.innerHTML=`<div class="form-grid"><div class="field full"><label>Ítem del pedido</label><select class="control" name="orderItemId"><option value="">Material adicional</option>${itemOptions}</select></div><div class="field"><label>SKU</label><input class="control" name="sku"></div><div class="field"><label>Descripción</label><input class="control" name="description" required></div><div class="field"><label>Esperado</label><input class="control" name="expectedQuantity" type="number" step="any"></div><div class="field"><label>Recibido</label><input class="control" name="receivedQuantity" type="number" step="any" required></div><div class="field"><label>Aceptado</label><input class="control" name="acceptedQuantity" type="number" step="any" required></div><div class="field"><label>Rechazado</label><input class="control" name="rejectedQuantity" type="number" step="any" value="0"></div><div class="field"><label>Unidad</label><input class="control" name="unit" value="UND"></div><div class="field"><label>Ubicación</label><input class="control" name="location" value="RECEPCION"></div><div class="field"><label>Lote</label><input class="control" name="lotNumber"></div><div class="field"><label>Calidad</label><select class="control" name="qualityStatus"><option>ACCEPTED</option><option>CONDITIONAL</option><option>REJECTED</option></select></div><div class="field"><button class="btn btn-danger" type="button" data-remove>Eliminar línea</button></div></div>`;const sel=row.querySelector('[name="orderItemId"]');sel.onchange=()=>{const opt=sel.selectedOptions[0];if(!opt?.value)return;row.querySelector('[name="sku"]').value=opt.dataset.sku||"";row.querySelector('[name="description"]').value=opt.dataset.description||"";row.querySelector('[name="unit"]').value=opt.dataset.unit||"UND";row.querySelector('[name="expectedQuantity"]').value=opt.dataset.quantity||"";row.querySelector('[name="receivedQuantity"]').value=opt.dataset.quantity||"";row.querySelector('[name="acceptedQuantity"]').value=opt.dataset.quantity||""};row.querySelector("[data-remove]").onclick=()=>row.remove();root.append(row)};
  m.root.querySelector("#add-receipt-line").onclick=add;add();
}
async function cutModal(data,drawer,overlay){
  const lots=await api.inventoryLots(null,"");
  const cutItems=data.items.filter(i=>i.requires_cut);
  modal({title:"Registrar corte",confirmLabel:"Guardar corte",body:`<form id="cut-form"><div class="form-grid"><div class="field full"><label>Chipa o lote disponible</label><select class="control" name="inventoryLotId" required><option value="">Seleccione…</option>${lots.map(l=>`<option value="${l.id}">${fmt.escape(l.sku)} · ${fmt.escape(l.description)} · ${fmt.escape(l.location)} · disponible ${fmt.number(l.available,3)} ${fmt.escape(l.unit)}</option>`).join("")}</select></div><div class="field full"><label>Ítem del pedido</label><select class="control" name="orderItemId" required><option value="">Seleccione…</option>${cutItems.map(i=>`<option value="${i.id}">${i.line_number} · ${fmt.escape(i.sku||i.description)}</option>`).join("")}</select></div><div class="field"><label>Longitud solicitada</label><input class="control" name="requestedLength" type="number" step="any" required></div><div class="field"><label>Longitud real</label><input class="control" name="actualLength" type="number" step="any" required></div><div class="field"><label>Desperdicio</label><input class="control" name="scrapLength" type="number" step="any" value="0"></div></div></form>`,onConfirm:async()=>{const d=serializeForm(document.querySelector("#cut-form"));await api.saveCutJob(data.order.id,d);await afterDomain(data,drawer,overlay,"Corte, consumo y desperdicio registrados.")}});
}
function invoiceModal(data,drawer,overlay){
  modal({title:"Registrar factura",confirmLabel:"Guardar factura",body:`<form id="invoice-form"><div class="form-grid"><div class="field"><label>Número</label><input class="control" name="invoiceNumber" required></div><div class="field"><label>Fecha</label><input class="control" name="invoiceDate" type="date" value="${new Date().toISOString().slice(0,10)}" required></div><div class="field"><label>Valor</label><input class="control" name="amount" type="number" step="any"></div><div class="field"><label>Moneda</label><input class="control" name="currency" value="COP"></div></div></form>`,onConfirm:async()=>{const d=serializeForm(document.querySelector("#invoice-form"));await api.saveInvoice(data.order.id,d);await afterDomain(data,drawer,overlay,"Factura registrada.")}});
}
function deliveryModal(data,drawer,overlay){
  modal({title:"Registrar despacho o entrega",confirmLabel:"Guardar",body:`<form id="delivery-form"><div class="form-grid"><div class="field"><label>Estado</label><select class="control" name="status"><option>PLANNED</option><option>DISPATCHED</option><option>IN_TRANSIT</option><option>DELIVERED</option><option>NOT_DELIVERED</option></select></div><div class="field"><label>Programado</label><input class="control" name="scheduledAt" type="datetime-local"></div><div class="field"><label>Despachado</label><input class="control" name="dispatchedAt" type="datetime-local"></div><div class="field"><label>Entregado</label><input class="control" name="deliveredAt" type="datetime-local"></div><div class="field"><label>Transportadora</label><input class="control" name="carrier"></div><div class="field"><label>Guía</label><input class="control" name="trackingNumber"></div><div class="field"><label>Recibido por</label><input class="control" name="receivedBy"></div><div class="field full"><label>Motivo no entrega</label><textarea class="control" name="noDeliveryReason"></textarea></div></div></form>`,onConfirm:async()=>{const d=serializeForm(document.querySelector("#delivery-form"));for(const key of ["scheduledAt","dispatchedAt","deliveredAt"])if(d[key])d[key]=new Date(d[key]).toISOString();await api.saveDelivery(data.order.id,d);await afterDomain(data,drawer,overlay,"Despacho o entrega registrados.")}});
}

function exportCurrent(){
  const rows=currentList.data?.items||[];
  if(!rows.length)return toast("No hay registros para exportar.","error");
  const headers=Object.keys(rows[0]);
  const csv=[headers.join(","),...rows.map(r=>headers.map(h=>`"${String(r[h]??"").replaceAll('"','""')}"`).join(","))].join("\n");
  const a=document.createElement("a");
  a.href=URL.createObjectURL(new Blob([csv],{type:"text/csv;charset=utf-8"}));
  a.download=`pedidos_${new Date().toISOString().slice(0,10)}.csv`;
  a.click();
  URL.revokeObjectURL(a.href);
}

async function printStickers(orderId){
  const rows=await api.stickers(orderId);
  if(!rows.length)return toast("No hay líneas recibidas para imprimir.","error");
  const w=window.open("","_blank","width=1000,height=800");
  w.document.write(`<!doctype html><meta charset="utf-8"><title>Stickers ERP</title><style>body{font-family:Arial;margin:12mm}.grid{display:grid;grid-template-columns:repeat(2,1fr);gap:7mm}.s{border:2px solid #111;border-radius:8px;padding:7mm;min-height:62mm;page-break-inside:avoid}.h{display:flex;justify-content:space-between;border-bottom:1px solid #333;padding-bottom:4mm;margin-bottom:4mm}.big{font-size:20px;font-weight:900}.r{display:grid;grid-template-columns:110px 1fr;margin:2mm 0}.l{font-size:10px;text-transform:uppercase;color:#555}.v{font-weight:700}@media print{body{margin:5mm}.s{min-height:55mm}}</style><div class="grid">${rows.map(r=>`<article class="s"><div class="h"><div><div class="l">Recepción</div><div class="big">${fmt.escape(r.receiptNumber||"")}</div></div><div><div class="l">OC</div><strong>${fmt.escape(r.purchaseOrder||"—")}</strong></div></div><div class="r"><span class="l">Material</span><span class="v">${fmt.escape(r.description)}</span></div><div class="r"><span class="l">SKU</span><span class="v">${fmt.escape(r.sku||"—")}</span></div><div class="r"><span class="l">Cantidad</span><span class="v">${fmt.number(r.quantity,3)} ${fmt.escape(r.unit)}</span></div><div class="r"><span class="l">Ubicación</span><span class="v">${fmt.escape(r.location||"—")}</span></div><div class="r"><span class="l">Calidad</span><span class="v">${fmt.escape(r.qualityStatus||"—")}</span></div></article>`).join("")}</div><script>onload=()=>print()<\/script>`);
  w.document.close();
}
