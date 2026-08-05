import {api} from "../services/api.js";
import {state,can} from "../core/state.js";
import {fmt,statusBadge,priorityBadge} from "../core/format.js";
import {wizard,modal,toast,serializeForm,paginationHtml,empty,loading,actionCards,guide} from "../core/ui.js";
import {workspaceIntro,orderVisualCards,viewSwitch,summaryItem,choice} from "../core/guided.js";
import {uploadOrderFile} from "../services/drive.js";

let currentList={filters:{page:1,pageSize:50,assignment:"ALL",includeHistory:true},root:null,data:null};
let currentView="cards";

export async function renderOrders(root,{moduleId="orders",params={}}={}){
  currentList.root=root;
  currentList.filters={...currentList.filters,...params,page:Number(params.page||1)};
  if(params.history==="0")currentList.filters.includeHistory=false;
  const canCreate=can("orders","canCreate")||can("sales","canCreate");
  const cards=[
    ...(canCreate?[{id:"create-order",title:"Crear pedido",description:"Registra el pedido en cinco pasos cortos y revisa la información antes de enviarlo.",icon:"＋",tone:"accent"}]:[]),
    {id:"show-all-orders",title:"Todos los pedidos",description:"Consulta operación activa e historial con filtros sencillos.",icon:"▦",tone:"primary"},
    {id:"show-my-orders",title:"Mis pedidos asignados",description:"Muestra únicamente los pedidos que requieren tu intervención.",icon:"✓",tone:"success"},
    {id:"show-blocked-orders",title:"Pedidos con atención",description:"Encuentra pedidos bloqueados o en espera para revisar su situación.",icon:"!",tone:"warning"},
    {id:"orders-help",title:"Cómo usar este módulo",description:"Consulta una guía corta para buscar, abrir y gestionar pedidos.",icon:"?"}
  ];
  root.innerHTML=`
    <section class="page-head"><div><h2>${moduleId==="sales"?"Registro y control comercial":"Control integral de pedidos"}</h2><p>Selecciona una opción, encuentra el pedido visualmente y sigue el asistente de la operación.</p></div><div class="page-actions"><button class="btn btn-ghost" id="export-list">Exportar resultados</button></div></section>
    ${workspaceIntro({title:moduleId==="sales"?"¿Qué necesitas registrar?":"¿Qué deseas hacer con los pedidos?",description:"Las tarjetas muestran las opciones habilitadas para tu usuario. Ningún formulario extenso se presenta de una sola vez.",cards:actionCards(cards)})}
    <section class="card card-pad">
      <div class="toolbar">
        <input class="control search-wide" id="f-search" placeholder="Buscar pedido, cliente o referencia" value="${fmt.escape(currentList.filters.search||"")}">
        ${select("f-step","Etapa",state.catalogs.steps,"code","name",currentList.filters.step)}
        ${simpleSelect("f-status","Estado",["QUEUED","ASSIGNED","IN_PROGRESS","WAITING","BLOCKED","CLOSED","CANCELLED"],currentList.filters.status)}
        ${select("f-type","Tipo",state.catalogs.orderTypes,"code","name",currentList.filters.orderType)}
        ${select("f-route","Modalidad",state.catalogs.deliveryRoutes,"code","name",currentList.filters.route)}
        ${simpleSelect("f-assignment","Asignación",["ALL","MINE","UNASSIGNED"],currentList.filters.assignment)}
        <label class="filter-pill"><input type="checkbox" id="f-history" ${currentList.filters.includeHistory!==false?"checked":""}> Incluir historial</label>
        <button class="btn btn-primary" id="apply-filters">Buscar</button>
        ${viewSwitch(currentView)}
      </div>
      <div class="selection-hint"><strong>Selecciona un pedido</strong><span>Las tarjetas resumen etapa, estado, responsable, tiempo y prioridad antes de abrir el expediente.</span></div>
      <div id="orders-result">${loading("Cargando pedidos…")}</div>
    </section>`;

  root.querySelector("#create-order")?.addEventListener("click",openCreateOrder);
  root.querySelector("#show-all-orders").onclick=()=>{setFilters({assignment:"ALL",status:"",includeHistory:true});loadOrders(1)};
  root.querySelector("#show-my-orders").onclick=()=>{setFilters({assignment:"MINE",status:"",includeHistory:false});loadOrders(1)};
  root.querySelector("#show-blocked-orders").onclick=()=>{setFilters({assignment:"ALL",status:"BLOCKED",includeHistory:false});loadOrders(1)};
  root.querySelector("#orders-help").onclick=()=>guide({title:"Cómo gestionar pedidos",description:"El módulo está organizado para reducir errores.",items:[{title:"Selecciona una opción",detail:"Usa las tarjetas grandes para crear, buscar o revisar pedidos con atención."},{title:"Filtra solo cuando sea necesario",detail:"Puedes buscar por número, cliente, etapa, tipo, ruta o responsable."},{title:"Abre una tarjeta",detail:"Verás el expediente completo y las acciones permitidas para tu rol."},{title:"Sigue el paso a paso",detail:"Cada acción valida los datos y muestra un resumen antes de guardar."}]});
  root.querySelector("#apply-filters").onclick=()=>loadOrders(1);
  root.querySelector("#f-search").onkeydown=event=>{if(event.key==="Enter")loadOrders(1)};
  root.querySelector("#export-list").onclick=exportCurrent;
  root.querySelectorAll("[data-view]").forEach(button=>button.onclick=()=>{currentView=button.dataset.view;root.querySelectorAll("[data-view]").forEach(item=>item.classList.toggle("active",item===button));renderOrderResults()});
  if(moduleId==="sales"&&params.create==="1")openCreateOrder();
  await loadOrders(currentList.filters.page);
}

function setFilters(values){
  if("assignment" in values)currentList.root.querySelector("#f-assignment").value=values.assignment;
  if("status" in values)currentList.root.querySelector("#f-status").value=values.status;
  if("includeHistory" in values)currentList.root.querySelector("#f-history").checked=values.includeHistory;
}

async function loadOrders(page=1){
  const root=currentList.root;
  if(!root?.isConnected)return;
  const result=root.querySelector("#orders-result");
  result.innerHTML=loading("Consultando la operación…");
  const filters={search:root.querySelector("#f-search").value.trim(),step:root.querySelector("#f-step").value,status:root.querySelector("#f-status").value,orderType:root.querySelector("#f-type").value,route:root.querySelector("#f-route").value,assignment:root.querySelector("#f-assignment").value,includeHistory:root.querySelector("#f-history").checked,page,pageSize:50};
  currentList.filters=filters;
  currentList.data=await api.listOrders(filters);
  renderOrderResults();
}

function renderOrderResults(){
  const root=currentList.root;
  const result=root?.querySelector("#orders-result");
  const data=currentList.data;
  if(!result||!data)return;
  const content=data.items.length?(currentView==="cards"?orderVisualCards(data.items):ordersTable(data.items)):empty("No se encontraron pedidos","Ajusta los filtros o crea un pedido nuevo.");
  result.innerHTML=`${content}${data.items.length?paginationHtml(data.pagination):""}`;
  result.querySelectorAll("[data-order]").forEach(element=>element.onclick=()=>openOrder(element.dataset.order));
  result.querySelectorAll("[data-page]").forEach(element=>element.onclick=()=>loadOrders(Number(element.dataset.page)));
}

function ordersTable(rows){
  return `<div class="table-wrap"><table><thead><tr><th>Pedido</th><th>Cliente</th><th>Tipo y pago</th><th>Etapa</th><th>Estado</th><th>Responsable</th><th>Tiempo</th><th>Prioridad</th><th>Actualizado</th></tr></thead><tbody>${rows.map(order=>`<tr><td><span class="table-link" data-order="${order.id}">${fmt.escape(order.orderNumber)}</span><div class="cell-sub">${fmt.escape(order.externalReference||"")}</div></td><td><div class="cell-main">${fmt.escape(order.clientName)}</div><div class="cell-sub">${fmt.escape(fmt.route(order.route))}</div></td><td><span class="badge badge-blue">${fmt.escape(fmt.label(order.orderType))}</span><div class="cell-sub">${fmt.escape(fmt.payment(order.paymentCondition))}</div></td><td><div class="cell-main">${fmt.escape(fmt.step(order.stepName||order.currentStep))}</div></td><td>${statusBadge(order.status)}${order.slaExceeded?'<div class="cell-sub danger">Plazo excedido</div>':""}</td><td>${fmt.escape(order.assigneeName||"En cola")}<div class="cell-sub">${fmt.escape(fmt.role(order.roleCode||""))}</div></td><td>${fmt.hours(order.ageBusinessSeconds)}</td><td>${priorityBadge(order.priority)}</td><td>${fmt.date(order.updatedAt)}</td></tr>`).join("")}</tbody></table></div>`;
}

function select(id,label,items=[],valueKey="code",labelKey="name",selected=""){
  return `<select class="control" id="${id}"><option value="">${label}: todos</option>${items.map(item=>`<option value="${fmt.escape(item[valueKey])}" ${item[valueKey]===selected?"selected":""}>${fmt.escape(item[labelKey])}</option>`).join("")}</select>`;
}
function simpleSelect(id,label,items,selected=""){
  return `<select class="control" id="${id}"><option value="">${label}: todos</option>${items.map(item=>`<option value="${item}" ${item===selected?"selected":""}>${fmt.escape(fmt.label(item))}</option>`).join("")}</select>`;
}
function formSelect(name,items,valueKey=null,labelKey=null,selected=null){
  return `<select class="control" name="${name}" required>${items.map(item=>{const value=valueKey?item[valueKey]:item;const label=labelKey?item[labelKey]:fmt.label(item);return `<option value="${fmt.escape(value)}" ${value===(selected??"MEDIUM")?"selected":""}>${fmt.escape(label)}</option>`}).join("")}</select>`;
}

function openCreateOrder(){
  const types=state.catalogs.orderTypes||[],payments=state.catalogs.paymentConditions||[],routes=state.catalogs.deliveryRoutes||[];
  const assistant=wizard({
    title:"Crear un nuevo pedido",
    subtitle:"Registra la información comercial sin saltarte ningún dato importante.",
    finishLabel:"Crear y enviar al flujo",
    steps:[
      {title:"Identificación",description:"Indica cómo reconocer el pedido y su prioridad.",content:`<div class="form-grid"><div class="field"><label>Número de pedido *</label><input class="control" name="orderNumber" placeholder="Ejemplo: PVC-5001" required></div><div class="field"><label>Referencia externa</label><input class="control" name="externalReference" placeholder="OC, cotización o referencia"></div><div class="field"><label>Tipo de pedido *</label>${formSelect("orderType",types,"code","name",types[0]?.code)}</div><div class="field"><label>Prioridad *</label>${formSelect("priority",["LOW","MEDIUM","HIGH","URGENT","CRITICAL"])}</div></div><div class="wizard-tip">Usa el número oficial del pedido. La prioridad alta, urgente o crítica debe corresponder a una necesidad real.</div>`},
      {title:"Cliente",description:"Completa los datos que permiten identificar y contactar al cliente.",content:`<div class="form-grid"><div class="field full"><label>Nombre o razón social *</label><input class="control" name="clientName" required></div><div class="field"><label>NIT o documento</label><input class="control" name="clientDocument"></div><div class="field"><label>Ciudad</label><input class="control" name="clientCity"></div><div class="field"><label>Dirección</label><input class="control" name="clientAddress"></div><div class="field"><label>Teléfono</label><input class="control" name="clientPhone"></div></div>`},
      {title:"Condiciones",description:"Define pago, entrega y necesidades especiales del pedido.",content:`<div class="form-grid"><div class="field"><label>Condición de pago *</label>${formSelect("paymentCondition",payments,"code","name",payments[0]?.code)}</div><div class="field"><label>Modalidad de entrega *</label>${formSelect("deliveryRoute",routes,"code","name",routes[0]?.code)}</div><div class="field"><label>Fecha solicitada</label><input class="control" name="requestedDeliveryDate" type="date"></div></div><div class="wizard-choice-grid"><label class="wizard-choice"><input type="checkbox" name="requiresCut"><span><strong>Requiere corte</strong><small>Actívalo cuando uno o más materiales deban pasar por corte.</small></span></label><label class="wizard-choice"><input type="checkbox" name="requiresPurchase"><span><strong>Requiere compra</strong><small>Actívalo cuando el pedido dependa de una orden de compra.</small></span></label></div>`},
      {title:"Materiales",description:"Agrega cada línea del pedido. Puedes registrar tantas como necesites.",content:`<div class="items-wizard-head"><div><strong>Ítems del pedido</strong><p>La descripción y la cantidad son obligatorias. Si un material requiere corte, registra también la longitud solicitada.</p></div><button class="btn btn-ghost" type="button" id="add-item">＋ Agregar material</button></div><div class="items-editor" id="items-editor"></div>`,validate:({root})=>{const rows=[...root.querySelectorAll(".item-row")];if(!rows.length)throw new Error("Agrega al menos un material.");let cutItems=0;for(const [index,row] of rows.entries()){const description=row.querySelector('[name="description"]').value.trim(),quantity=Number(row.querySelector('[name="quantity"]').value),requiresCut=row.querySelector('[name="itemCut"]').checked,cutLength=Number(row.querySelector('[name="cutLength"]').value);if(!description||!Number.isFinite(quantity)||quantity<=0)throw new Error(`El material ${index+1} debe tener descripción y cantidad mayor que cero.`);if(requiresCut){cutItems++;if(!Number.isFinite(cutLength)||cutLength<=0)throw new Error(`Registra la longitud solicitada para el material ${index+1}.`)}}const orderRequiresCut=root.querySelector('[name="requiresCut"]')?.checked;if(orderRequiresCut&&!cutItems)throw new Error("Marcaste que el pedido requiere corte. Selecciona al menos un material y registra su longitud.");return true}},
      {title:"Revisión",description:"Comprueba la información antes de crear el pedido.",content:`<div id="order-review" class="wizard-summary"></div><div class="wizard-confirm-box"><strong>¿Todo está correcto?</strong><p>Al confirmar, el ERP creará el pedido y lo enviará automáticamente a la primera etapa que corresponda.</p></div>`,onEnter:({root,form})=>{const d=serializeForm(form),count=root.querySelectorAll(".item-row").length;root.querySelector("#order-review").innerHTML=[summaryItem("Pedido",d.orderNumber),summaryItem("Cliente",d.clientName),summaryItem("Tipo",fmt.label(d.orderType)),summaryItem("Pago",fmt.payment(d.paymentCondition)),summaryItem("Entrega",fmt.route(d.deliveryRoute)),summaryItem("Prioridad",fmt.label(d.priority)),summaryItem("Materiales",String(count)),summaryItem("Corte / compra",`${d.requiresCut?"Corte":"Sin corte"} · ${d.requiresPurchase?"Compra":"Sin compra"}`)].join("")}}
    ],
    onFinish:async({root,form,data})=>{
      const items=[...root.querySelectorAll(".item-row")].map((row,index)=>({lineNumber:index+1,sku:row.querySelector('[name="sku"]').value.trim()||null,reference:row.querySelector('[name="reference"]').value.trim()||null,description:row.querySelector('[name="description"]').value.trim(),quantity:Number(row.querySelector('[name="quantity"]').value),unit:row.querySelector('[name="unit"]').value.trim()||"UND",warehouseLocation:row.querySelector('[name="location"]').value.trim()||null,requiresCut:row.querySelector('[name="itemCut"]').checked,requestedCutLength:row.querySelector('[name="itemCut"]').checked?(Number(row.querySelector('[name="cutLength"]').value)||null):null}));
      const result=await api.createOrder({...data,items});
      toast(`Pedido ${result.orderNumber} creado y enviado a ${fmt.step(result.currentStep)}.`,"success",6500);
      await loadOrders(1);
      setTimeout(()=>openOrder(result.orderId),180);
    }
  });
  const editor=assistant.root.querySelector("#items-editor");
  const add=()=>{
    const row=document.createElement("div");
    row.className="item-row item-row-guided";
    row.innerHTML=`<div class="item-row-number"></div><input class="control" name="sku" placeholder="SKU"><input class="control" name="reference" placeholder="Referencia"><input class="control item-description" name="description" placeholder="Descripción del material" required><input class="control" name="quantity" type="number" min="0.0001" step="any" placeholder="Cantidad" required><input class="control" name="unit" value="UND" placeholder="Unidad"><input class="control" name="location" placeholder="Ubicación sugerida"><label class="filter-pill"><input type="checkbox" name="itemCut"> Requiere corte</label><input class="control" name="cutLength" type="number" step="any" placeholder="Longitud"><button type="button" class="icon-btn" title="Eliminar línea">×</button>`;
    const cutToggle=row.querySelector('[name="itemCut"]');
    const cutLength=row.querySelector('[name="cutLength"]');
    const syncCut=()=>{cutLength.disabled=!cutToggle.checked;cutLength.required=cutToggle.checked;if(!cutToggle.checked)cutLength.value=""};
    cutToggle.onchange=syncCut;syncCut();
    row.querySelector("button").onclick=()=>{row.remove();renumberItems(editor)};
    editor.append(row);renumberItems(editor);
  };
  assistant.root.querySelector("#add-item").onclick=add;
  add();
}
function renumberItems(editor){[...editor.querySelectorAll(".item-row-number")].forEach((element,index)=>element.textContent=String(index+1))}

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
  const order=data.order;
  const actions=data.actions?.actions||[];
  const domainActions=data.actions?.domainActions||[];
  const allActions=[...actions.map(action=>({code:action.code,label:action.label,description:actionDescription(action.code),tone:action.kind==="danger"?"warning":action.kind==="success"?"success":action.kind==="primary"?"accent":"primary",domain:false})),...domainActions.map(action=>({code:action.code,label:action.label,description:domainDescription(action.code),tone:"",domain:true}))];
  drawer.innerHTML=`
    <header class="drawer-head"><div class="drawer-title"><h2>${fmt.escape(order.order_number)}</h2><div>${statusBadge(order.status)} ${priorityBadge(order.priority)} <span class="muted">${fmt.escape(order.client_name)}</span></div></div><button class="icon-btn" id="close-drawer">×</button></header>
    <div class="drawer-content">
      ${allActions.length?`<section class="operation-guide"><strong>¿Qué necesitas hacer con este pedido?</strong><p>Selecciona una opción. El ERP te explicará el proceso y pedirá únicamente la información necesaria.</p></section><section class="guided-order-actions">${allActions.map(action=>`<button class="guided-order-action ${action.domain?"domain":""} ${action.tone}" data-${action.domain?"domain":"action"}="${action.code}"><strong>${fmt.escape(action.label)}</strong><small>${fmt.escape(action.description)}</small></button>`).join("")}</section><div class="section-gap-small"></div>`:""}
      <div class="detail-tabs"><button class="detail-tab active" data-tab="summary">Resumen</button><button class="detail-tab" data-tab="items">Ítems (${data.items.length})</button><button class="detail-tab" data-tab="controls">Controles</button><button class="detail-tab" data-tab="checklist">Lista de control (${(data.checklist||[]).filter(item=>item.completed).length}/${(data.checklist||[]).length})</button><button class="detail-tab" data-tab="timeline">Trazabilidad (${data.events.length})</button><button class="detail-tab" data-tab="times">Tiempos</button><button class="detail-tab" data-tab="docs">Documentos (${data.files.length})</button><button class="detail-tab" data-tab="comments">Comentarios (${data.comments.length})</button><button class="detail-tab" data-tab="approvals">Aprobaciones (${data.approvals.length})</button></div>
      <div id="detail-panel">${summaryTab(data)}</div>
    </div>`;
  drawer.querySelector("#close-drawer").onclick=()=>closeDrawer(drawer,overlay);
  drawer.querySelectorAll("[data-tab]").forEach(button=>button.onclick=()=>{drawer.querySelectorAll("[data-tab]").forEach(item=>item.classList.toggle("active",item===button));drawer.querySelector("#detail-panel").innerHTML=tabContent(button.dataset.tab,data)});
  drawer.querySelectorAll("[data-action]").forEach(button=>button.onclick=()=>handleAction(data,button.dataset.action,drawer,overlay));
  drawer.querySelectorAll("[data-domain]").forEach(button=>button.onclick=()=>handleDomain(data,button.dataset.domain,drawer,overlay));
}
function actionDescription(code){return ({CLAIM:"Toma el pedido y déjalo asignado a tu usuario.",START:"Inicia la etapa y activa la toma de tiempo.",RESUME:"Continúa una etapa que estaba en espera.",COMPLETE:"Finaliza la etapa después de verificar sus controles.",WAIT:"Pausa la etapa indicando el motivo.",BLOCK:"Registra un impedimento que requiere intervención.",NO_DELIVERY:"Registra el intento fallido y su causa.",COMMENT:"Agrega una observación al expediente.",REQUEST_APPROVAL:"Solicita una decisión formal antes de continuar.",ASSIGN:"Selecciona un responsable habilitado.",REPROGRAM:"Define una nueva fecha para la entrega."})[code]||"Continúa la operación siguiendo el paso a paso."}
function domainDescription(code){return ({FILE:"Adjunta un soporte o evidencia al expediente.",CHECKLIST:"Completa los controles obligatorios de la etapa.",FINANCIAL:"Registra la validación de Cartera o Caja.",PURCHASE:"Registra la orden de compra y el proveedor.",RECEIPT:"Registra mercancía recibida, calidad, lote y ubicación.",CUT:"Registra medidas, consumo y desperdicio del corte.",INVOICE:"Registra la factura y sus datos principales.",DELIVERY:"Registra programación, guía y resultado de la entrega.",STICKERS:"Imprime las etiquetas de la mercancía recibida."})[code]||"Registra el control requerido para esta etapa."}

function info(label,value){return `<div class="info-box"><label>${fmt.escape(label)}</label><strong>${fmt.escape(value??"—")}</strong></div>`}
function summaryTab(d){
  const o=d.order;
  const active=d.tasks.find(t=>["QUEUED","ASSIGNED","IN_PROGRESS","WAITING","BLOCKED"].includes(t.status));
  return `<div class="detail-grid">
    ${info("Cliente",o.client_name)}${info("Tipo",fmt.label(o.order_type_code))}${info("Pago",fmt.payment(o.payment_condition_code))}${info("Ruta",fmt.route(o.delivery_route_code))}
    ${info("Etapa",fmt.step(o.current_step_code))}${info("Estado",fmt.label(o.status))}${info("Responsable",o.current_role_code?fmt.role(o.current_role_code):"En cola")}${info("Versión",o.version)}
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
  return `<div class="detail-grid" style="grid-template-columns:repeat(2,minmax(0,1fr))">${info("Tarea",fmt.step(task.step_code))}${info("Estado",fmt.label(task.status))}${info("Controles",`${done}/${rows.length}`)}${info("Asignado",task.assigned_role_code?fmt.role(task.assigned_role_code):"En cola")}</div><div style="height:12px"></div><div class="progress"><span style="width:${rows.length?done/rows.length*100:100}%"></span></div>`;
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
function tasksTimeline(tasks){return `<div class="timeline">${tasks.map(t=>`<div class="timeline-item"><h4>${fmt.escape(fmt.step(t.step_code))} · ${statusBadge(t.status)}</h4><p>${fmt.escape(t.result_detail||(t.assigned_role_code?fmt.role(t.assigned_role_code):"Tarea de proceso"))}</p><time>${fmt.date(t.created_at)}${t.completed_at?` → ${fmt.date(t.completed_at)}`:""}</time></div>`).join("")}</div>`}
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
const CONTROL_FIELD_LABELS={
  validation_type:"Tipo de validación",decision:"Decisión",amount:"Valor",reference:"Referencia",notes:"Observaciones",created_at:"Fecha de registro",
  po_number:"Orden de compra",supplier_name:"Proveedor",status:"Estado",total_amount:"Valor total",expected_at:"Fecha esperada",
  receipt_number:"Número de recepción",purchase_order:"Orden de compra",received_at:"Fecha de recepción",
  requested_length:"Longitud solicitada",actual_length:"Longitud real",scrap_length:"Desperdicio",completed_at:"Fecha de finalización",
  invoice_number:"Número de factura",invoice_date:"Fecha de factura",route_code:"Modalidad de entrega",scheduled_at:"Fecha programada",
  tracking_number:"Número de guía",received_by:"Recibido por"
};
function controlTable(title,rows,fields){return `<article class="card"><header class="card-head"><h3>${fmt.escape(title)}</h3></header><div class="card-body"><div class="table-wrap"><table style="min-width:640px"><thead><tr>${fields.map(f=>`<th>${fmt.escape(CONTROL_FIELD_LABELS[f]||f.replaceAll("_"," "))}</th>`).join("")}</tr></thead><tbody>${rows.map(r=>`<tr>${fields.map(f=>`<td>${fmt.escape(formatCell(r[f],f))}</td>`).join("")}</tr>`).join("")}</tbody></table></div></div></article>`}
function formatCell(v,field=""){if(v==null||v==="")return "—";if(typeof v==="number")return fmt.number(v,2);if(typeof v==="boolean")return v?"Sí":"No";if(typeof v==="string"&&/^\d{4}-\d{2}-\d{2}(T|$)/.test(v))return fmt.date(v);if(["status","decision","validation_type","route_code"].includes(field))return fmt.label(v);return String(v)}
function checklistTab(d){
  const active=d.tasks.find(t=>["QUEUED","ASSIGNED","IN_PROGRESS","WAITING","BLOCKED"].includes(t.status));
  const rows=(d.checklist||[]).filter(x=>!active||x.task_id===active.id);
  return rows.length?`<div class="checklist-list">${rows.map(x=>`<label class="checklist-item ${x.completed?"done":""}"><input type="checkbox" disabled ${x.completed?"checked":""}><span><strong>${fmt.escape(x.label)}</strong><small>${x.required?"Obligatorio":"Opcional"}${x.note?` · ${fmt.escape(x.note)}`:""}</small></span></label>`).join("")}</div>`:empty("Sin checklist","La etapa no tiene controles configurados.");
}
function eventsTab(events){return events.length?`<div class="timeline">${events.map(e=>`<div class="timeline-item"><h4>${fmt.escape(fmt.action(e.actionCode||e.eventType))}</h4><p>${fmt.escape([e.fromStep,e.toStep].filter(Boolean).map(x=>fmt.step(x)).join(" → "))} · ${fmt.escape(e.actorName||"Sistema")} (${fmt.escape(fmt.role(e.actorRole||""))})</p><time>${fmt.date(e.createdAt)}</time></div>`).join("")}</div>`:empty()}
function timesTab(tasks,sessions){return `<div class="table-wrap"><table style="min-width:860px"><thead><tr><th>Etapa</th><th>Estado</th><th>Tiempo transcurrido</th><th>Tiempo productivo laboral</th><th>Espera estimada</th><th>Sesiones</th></tr></thead><tbody>${tasks.map(t=>{const wait=Math.max(0,Number(t.raw_seconds||0)-Number(t.business_seconds||0));return `<tr><td>${fmt.escape(fmt.step(t.step_code))}</td><td>${statusBadge(t.status)}</td><td>${fmt.hours(t.raw_seconds)}</td><td>${fmt.hours(t.business_seconds)}</td><td>${fmt.hours(wait)}</td><td>${sessions.filter(s=>s.task_id===t.id).length}</td></tr>`}).join("")}</tbody></table></div>`}
function docsTab(files){return files.length?`<div class="grid grid-2">${files.map(f=>`<a class="card card-pad" href="${fmt.escape(f.web_view_link||"#")}" target="_blank" rel="noopener"><strong>${fmt.escape(f.file_name)}</strong><div class="cell-sub">${fmt.escape(fmt.label(f.file_category))} · ${fmt.date(f.created_at)}</div></a>`).join("")}</div>`:empty("Sin documentos","Use “Subir archivo” para agregar documentos al expediente.")}
function commentsTab(comments){return comments.length?`<div class="timeline">${comments.map(c=>`<div class="timeline-item"><h4>${fmt.escape(c.author)} · ${fmt.escape(fmt.label(c.type))}</h4><p>${fmt.escape(c.body)}</p><time>${fmt.date(c.createdAt)}</time></div>`).join("")}</div>`:empty()}
function approvalsTab(rows){return rows.length?`<div class="table-wrap"><table style="min-width:760px"><thead><tr><th>Tipo</th><th>Estado</th><th>Motivo</th><th>Decisión</th><th>Fecha</th></tr></thead><tbody>${rows.map(a=>`<tr><td>${fmt.escape(fmt.request(a.request_type))}</td><td>${statusBadge(a.status)}</td><td>${fmt.escape(a.reason)}</td><td>${fmt.escape(a.decision_reason||"—")}</td><td>${fmt.date(a.created_at)}</td></tr>`).join("")}</tbody></table></div>`:empty()}

async function handleAction(data,action,drawer,overlay){
  const order=data.order;
  if(["CLAIM","START","RESUME"].includes(action))return simpleActionWizard(order,action,drawer,overlay);
  if(action==="COMPLETE")return textActionWizard(order,action,"Finalizar etapa","Describe el resultado y cualquier novedad antes de cerrar esta etapa.","Resultado y observaciones","Finalizar etapa",drawer,overlay,"detail");
  if(["WAIT","BLOCK","NO_DELIVERY"].includes(action)){const title=action==="NO_DELIVERY"?"Registrar no entrega":action==="BLOCK"?"Bloquear pedido":"Poner etapa en espera";return textActionWizard(order,action,title,"Explica claramente la causa para que el siguiente responsable pueda actuar.","Motivo obligatorio",action==="NO_DELIVERY"?"Registrar no entrega":"Guardar estado",drawer,overlay,"reason")}
  if(action==="COMMENT")return commentWizard(order,drawer,overlay);
  if(action==="REQUEST_APPROVAL")return approvalRequest(order,drawer,overlay);
  if(action==="ASSIGN")return assignmentWizard(data,drawer,overlay);
  if(action==="REPROGRAM")return reprogramWizard(order,drawer,overlay);
}
function simpleActionWizard(order,action,drawer,overlay){
  const label=fmt.action(action),explanation=action==="CLAIM"?"El pedido quedará asignado a tu usuario.":action==="START"?"Se iniciará la etapa y comenzará la toma de tiempo productivo.":"Se reanudará la etapa y continuará la toma de tiempo.";
  wizard({title:label,subtitle:"Confirma que estás listo para continuar.",finishLabel:label,steps:[{title:"Antes de continuar",description:"Verifica qué sucederá con el pedido.",content:`<div class="wizard-confirm-box"><strong>${fmt.escape(label)}</strong><p>${fmt.escape(explanation)}</p></div><div class="field"><label>Observación opcional</label><textarea class="control" name="detail" placeholder="Registra una aclaración si es necesaria"></textarea></div>`},{title:"Confirmación",description:"Comprueba el pedido y la acción.",content:`<div class="wizard-summary">${summaryItem("Pedido",order.order_number)}${summaryItem("Cliente",order.client_name)}${summaryItem("Etapa",fmt.step(order.current_step_code))}${summaryItem("Acción",label)}</div>`}],onFinish:async({data})=>execute(order,action,{detail:data.detail||`${label} desde asistente guiado`},drawer,overlay)});
}
function textActionWizard(order,action,title,description,label,finishLabel,drawer,overlay,key){
  wizard({title,subtitle:description,finishLabel,steps:[{title:"Registrar motivo",description:"La información quedará dentro de la trazabilidad del pedido.",content:`<div class="field"><label>${fmt.escape(label)} *</label><textarea class="control" name="value" required placeholder="Escribe información clara y suficiente"></textarea></div><div class="wizard-tip">Evita mensajes genéricos. Indica qué ocurrió, qué falta y quién debería intervenir.</div>`},{title:"Revisar",description:"Confirma antes de guardar.",content:`<div class="wizard-summary">${summaryItem("Pedido",order.order_number)}${summaryItem("Cliente",order.client_name)}${summaryItem("Etapa",fmt.step(order.current_step_code))}${summaryItem("Acción",fmt.action(action))}</div><div class="review-text" data-review-text></div>`,onEnter:({root,data})=>{root.querySelector("[data-review-text]").innerHTML=`<strong>Información que se registrará</strong><p>${fmt.escape(data.value||"")}</p>`}}],onFinish:async({data})=>execute(order,action,{[key]:data.value.trim()},drawer,overlay)});
}
function commentWizard(order,drawer,overlay){
  wizard({title:"Agregar comentario",subtitle:"Registra una novedad o información útil en el expediente.",finishLabel:"Publicar comentario",steps:[{title:"Tipo de comentario",description:"Selecciona cómo debe clasificarse.",content:`<div class="wizard-choice-grid">${choice("commentType","COMMENT","Comentario","Información general del pedido.",true)}${choice("commentType","NOVELTY","Novedad","Situación que requiere seguimiento.")}${choice("commentType","SUPERVISION","Supervisión","Orientación o decisión de un responsable.")}</div><div class="field"><label>Visibilidad</label><select class="control" name="visibility"><option value="INTERNAL">Interno del ERP</option><option value="PUBLIC">General</option></select></div>`},{title:"Escribir comentario",description:"Sé claro y evita abreviaturas difíciles de entender.",content:`<div class="field"><label>Comentario *</label><textarea class="control" name="body" required placeholder="Describe la situación, la acción realizada o lo que debe revisarse"></textarea></div>`},{title:"Revisar",description:"El comentario quedará asociado al pedido.",content:`<div class="wizard-summary">${summaryItem("Pedido",order.order_number)}${summaryItem("Cliente",order.client_name)}<div class="wizard-summary-item"><label>Tipo</label><strong data-comment-type></strong></div></div><div class="review-text" data-comment-review></div>`,onEnter:({root,data})=>{root.querySelector("[data-comment-type]").textContent=fmt.label(data.commentType);root.querySelector("[data-comment-review]").innerHTML=`<strong>Comentario</strong><p>${fmt.escape(data.body||"")}</p>`}}],onFinish:async({data})=>execute(order,"COMMENT",{body:data.body.trim(),commentType:data.commentType,visibility:data.visibility},drawer,overlay)});
}
async function assignmentWizard(data,drawer,overlay){
  const pool=await api.assignmentPool(data.order.current_step_code);
  if(!pool.length)return toast("No hay responsables habilitados para esta etapa.","error");
  wizard({title:"Asignar responsable",subtitle:"Selecciona a la persona que continuará la etapa actual.",finishLabel:"Confirmar asignación",steps:[{title:"Seleccionar responsable",description:"Solo aparecen usuarios habilitados para esta etapa.",content:`<div class="assignee-grid">${pool.map((person,index)=>`<label class="assignee-card"><input type="radio" name="profileId" value="${person.id}" ${index===0?"checked":""} required><span><strong>${fmt.escape(person.name)}</strong><small>${fmt.escape((person.roles||[]).map(role=>fmt.role(role)).join(" · "))}</small></span></label>`).join("")}</div>`},{title:"Confirmar",description:"Verifica la etapa y la persona seleccionada.",content:`<div class="wizard-summary">${summaryItem("Pedido",data.order.order_number)}${summaryItem("Etapa",fmt.step(data.order.current_step_code))}<div class="wizard-summary-item"><label>Responsable</label><strong data-assignee-name></strong></div></div>`,onEnter:({root,data:formData})=>{const person=pool.find(item=>item.id===formData.profileId);root.querySelector("[data-assignee-name]").textContent=person?.name||"—"}}],onFinish:async({data:formData})=>execute(data.order,"ASSIGN",{profileId:formData.profileId},drawer,overlay)});
}
function reprogramWizard(order,drawer,overlay){
  wizard({title:"Reprogramar entrega",subtitle:"Define la nueva fecha y explica el cambio.",finishLabel:"Reprogramar entrega",steps:[{title:"Nueva programación",description:"Selecciona una fecha y hora realista.",content:`<div class="field"><label>Nueva fecha y hora *</label><input class="control" name="scheduledAt" type="datetime-local" required></div><div class="field"><label>Motivo *</label><textarea class="control" name="detail" required></textarea></div>`},{title:"Confirmar",description:"Comprueba la nueva programación.",content:`<div class="wizard-summary">${summaryItem("Pedido",order.order_number)}<div class="wizard-summary-item"><label>Nueva fecha</label><strong data-new-date></strong></div></div><div class="review-text" data-reprogram-reason></div>`,onEnter:({root,data})=>{root.querySelector("[data-new-date]").textContent=data.scheduledAt?fmt.date(new Date(data.scheduledAt).toISOString()):"—";root.querySelector("[data-reprogram-reason]").innerHTML=`<strong>Motivo</strong><p>${fmt.escape(data.detail||"")}</p>`}}],onFinish:async({data})=>execute(order,"REPROGRAM",{scheduledAt:new Date(data.scheduledAt).toISOString(),detail:data.detail.trim()},drawer,overlay)});
}
function approvalRequest(order,drawer,overlay){
  const routes=state.catalogs.deliveryRoutes||[],priorities=["LOW","MEDIUM","HIGH","URGENT","CRITICAL"];
  const assistant=wizard({title:"Solicitar aprobación",subtitle:"Selecciona el tipo de decisión y explica por qué es necesaria.",finishLabel:"Enviar solicitud",steps:[{title:"Tipo de solicitud",description:"Escoge la decisión formal que necesita el pedido.",content:`<div class="wizard-choice-grid">${choice("requestType","CANCELLATION","Cancelación","Cancelar el pedido de forma controlada.",true)}${choice("requestType","PRIORITY","Cambiar prioridad","Modificar el nivel de urgencia.")}${choice("requestType","ROUTE_CHANGE","Cambiar entrega","Modificar la modalidad de entrega.")}${choice("requestType","REOPEN","Reabrir pedido","Reactivar un pedido ya cerrado.")}${choice("requestType","STOCK_EXCEPTION","Excepción de inventario","Autorizar una condición especial de disponibilidad.")}${choice("requestType","FLOW_EXCEPTION","Excepción del flujo","Autorizar una desviación controlada.")}${choice("requestType","PAYMENT_EXCEPTION","Excepción financiera","Autorizar una situación especial de pago.")}${choice("requestType","DATA_CORRECTION","Corregir información","Solicitar corrección controlada de datos.")}</div>`},{title:"Información requerida",description:"Completa únicamente los datos correspondientes al tipo elegido.",content:`<div class="field" data-approval-priority hidden><label>Nueva prioridad</label><select class="control" name="priority">${priorities.map(item=>`<option value="${item}">${fmt.escape(fmt.label(item))}</option>`).join("")}</select></div><div class="field" data-approval-route hidden><label>Nueva modalidad</label><select class="control" name="route"><option value="">Seleccione…</option>${routes.map(item=>`<option value="${fmt.escape(item.code)}">${fmt.escape(item.name||fmt.route(item.code))}</option>`).join("")}</select></div><div class="field"><label>Motivo de la solicitud *</label><textarea class="control" name="reason" required placeholder="Explique la situación, el riesgo y el resultado esperado"></textarea></div>`,onEnter:({root,data})=>{root.querySelector("[data-approval-priority]").hidden=data.requestType!=="PRIORITY";root.querySelector("[data-approval-route]").hidden=data.requestType!=="ROUTE_CHANGE"},validate:({data})=>{if(data.requestType==="ROUTE_CHANGE"&&!data.route)throw new Error("Selecciona la nueva modalidad de entrega.");return true}},{title:"Revisar",description:"La solicitud quedará pendiente de decisión.",content:`<div class="wizard-summary">${summaryItem("Pedido",order.order_number)}<div class="wizard-summary-item"><label>Tipo</label><strong data-request-type></strong></div><div class="wizard-summary-item"><label>Cambio solicitado</label><strong data-request-change></strong></div></div><div class="review-text" data-request-reason></div>`,onEnter:({root,data})=>{root.querySelector("[data-request-type]").textContent=fmt.request(data.requestType);root.querySelector("[data-request-change]").textContent=data.requestType==="PRIORITY"?fmt.label(data.priority):data.requestType==="ROUTE_CHANGE"?fmt.route(data.route):"No aplica";root.querySelector("[data-request-reason]").innerHTML=`<strong>Motivo</strong><p>${fmt.escape(data.reason||"")}</p>`}}],onFinish:async({data})=>{const payload={requestType:data.requestType,reason:data.reason.trim()};if(data.requestType==="PRIORITY")payload.priority=data.priority;if(data.requestType==="ROUTE_CHANGE")payload.route=data.route;await execute(order,"REQUEST_APPROVAL",payload,drawer,overlay)}});
  const refresh=()=>{const type=assistant.form.querySelector('[name="requestType"]:checked')?.value;assistant.root.querySelector("[data-approval-priority]").hidden=type!=="PRIORITY";assistant.root.querySelector("[data-approval-route]").hidden=type!=="ROUTE_CHANGE"};
  assistant.root.querySelectorAll('[name="requestType"]').forEach(input=>input.addEventListener("change",refresh));refresh();
}
async function execute(order,action,payload,drawer,overlay){
  const result=await api.executeAction(order.id,action,payload,order.version);
  toast(`${fmt.action(action)}: operación registrada correctamente.`,"success",6000);
  if(currentList.root?.isConnected)await loadOrders(currentList.filters.page);
  await refreshOrder(result.orderId||order.id,drawer,overlay);
}

async function handleDomain(data,type,drawer,overlay){
  if(type==="FILE")return fileWizard(data,drawer,overlay);
  if(type==="CHECKLIST")return checklistWizard(data,drawer,overlay);
  if(type==="FINANCIAL")return financialWizard(data,drawer,overlay);
  if(type==="PURCHASE")return purchaseWizard(data,drawer,overlay);
  if(type==="RECEIPT")return receiptWizard(data,drawer,overlay);
  if(type==="CUT")return cutWizard(data,drawer,overlay);
  if(type==="INVOICE")return invoiceWizard(data,drawer,overlay);
  if(type==="DELIVERY")return deliveryWizard(data,drawer,overlay);
  if(type==="STICKERS")return printStickers(data.order.id);
}
function afterDomain(data,drawer,overlay,message){toast(message,"success",6000);return refreshOrder(data.order.id,drawer,overlay)}
function fileWizard(data,drawer,overlay){
  wizard({title:"Adjuntar documento",subtitle:"Clasifica el archivo para que quede organizado dentro del expediente.",finishLabel:"Subir archivo",steps:[{title:"Clasificar",description:"Selecciona la categoría del documento.",content:`<div class="wizard-choice-grid">${choice("category","EVIDENCE","Evidencia general","Fotos, actas u otros soportes.",true)}${choice("category","INVOICE","Factura","Documento de facturación.")}${choice("category","PAYMENT","Soporte de pago","Comprobante o validación financiera.")}${choice("category","PURCHASE_ORDER","Orden de compra","Documento del proveedor.")}${choice("category","RECEIPT","Recepción","Soporte del ingreso de mercancía.")}${choice("category","DELIVERY","Entrega","Prueba de despacho o recibido.")}${choice("category","QUALITY","Calidad","Inspección o novedad de calidad.")}</div>`},{title:"Seleccionar archivo",description:"Escoge el documento desde tu equipo.",content:`<div class="field"><label>Archivo *</label><input class="control" name="file" type="file" required></div><div class="wizard-tip">Verifica que el documento sea legible y corresponda al pedido.</div>`},{title:"Confirmar",description:"El archivo quedará asociado al expediente.",content:`<div class="wizard-summary">${summaryItem("Pedido",data.order.order_number)}<div class="wizard-summary-item"><label>Categoría</label><strong data-file-category></strong></div><div class="wizard-summary-item"><label>Archivo</label><strong data-file-name></strong></div></div>`,onEnter:({root,form,data:formData})=>{root.querySelector("[data-file-category]").textContent=fmt.label(formData.category);root.querySelector("[data-file-name]").textContent=form.querySelector('[name="file"]').files[0]?.name||"—"}}],onFinish:async({form,data:formData})=>{const file=form.querySelector('[name="file"]').files[0];if(!file)throw new Error("Selecciona un archivo.");await uploadOrderFile(data.order.id,file,formData.category,data.actions?.taskId||null,data.order.order_number);await afterDomain(data,drawer,overlay,"Archivo registrado en el expediente.")}});
}
function checklistWizard(data,drawer,overlay){
  const task=data.tasks.find(item=>["QUEUED","ASSIGNED","IN_PROGRESS","WAITING","BLOCKED"].includes(item.status));
  const rows=(data.checklist||[]).filter(item=>item.task_id===task?.id);
  if(!task||!rows.length)return toast("La etapa no tiene una lista de verificación activa.","error");
  wizard({title:`Lista de control · ${fmt.step(task.step_code)}`,subtitle:"Completa cada control antes de finalizar la etapa.",finishLabel:"Guardar controles",steps:[{title:"Verificar controles",description:"Marca únicamente lo que ya fue comprobado.",content:`<div class="checklist-list">${rows.map(item=>`<div class="checklist-edit"><label class="checklist-item ${item.completed?"done":""}"><input type="checkbox" name="done_${item.item_code}" ${item.completed?"checked":""}><span><strong>${fmt.escape(item.label)}</strong><small>${item.required?"Obligatorio":"Opcional"}</small></span></label><input class="control" name="note_${item.item_code}" value="${fmt.escape(item.note||"")}" placeholder="Observación si aplica"></div>`).join("")}</div>`},{title:"Revisar",description:"Comprueba cuántos controles quedarían completos.",content:`<div class="wizard-confirm-box"><strong data-check-count></strong><p>Los controles obligatorios deben completarse antes de finalizar la etapa.</p></div>`,onEnter:({root,form})=>{const completed=rows.filter(item=>form.querySelector(`[name="done_${CSS.escape(item.item_code)}"]`)?.checked).length;root.querySelector("[data-check-count]").textContent=`${completed} de ${rows.length} controles marcados`}}],onFinish:async({form})=>{for(const item of rows){const completed=form.querySelector(`[name="done_${CSS.escape(item.item_code)}"]`).checked,note=form.querySelector(`[name="note_${CSS.escape(item.item_code)}"]`).value.trim()||null;if(completed!==item.completed||note!==(item.note||null))await api.updateChecklist(task.id,item.item_code,completed,note)}await afterDomain(data,drawer,overlay,"Lista de control actualizada.")}});
}
function financialWizard(data,drawer,overlay){
  const type=data.order.current_step_code;
  wizard({title:`Validación de ${fmt.step(type)}`,subtitle:"Registra la decisión financiera y su soporte.",finishLabel:"Registrar validación",steps:[{title:"Decisión",description:"Selecciona el resultado de la revisión.",content:`<div class="wizard-choice-grid">${choice("decision","APPROVED","Aprobado","La validación permite continuar el flujo.",true)}${choice("decision","PENDING","Pendiente","Falta información o confirmación.")}${choice("decision","REJECTED","Rechazado","La validación no permite continuar.")}</div>`},{title:"Datos de soporte",description:"Registra valor, referencia y observaciones.",content:`<div class="form-grid"><div class="field"><label>Valor</label><input class="control" name="amount" type="number" step="any"></div><div class="field"><label>Referencia</label><input class="control" name="reference"></div><div class="field full"><label>Observaciones *</label><textarea class="control" name="notes" required></textarea></div></div>`},{title:"Confirmar",description:"Comprueba la decisión.",content:`<div class="wizard-summary">${summaryItem("Pedido",data.order.order_number)}${summaryItem("Etapa",fmt.step(type))}<div class="wizard-summary-item"><label>Decisión</label><strong data-financial-decision></strong></div><div class="wizard-summary-item"><label>Valor</label><strong data-financial-amount></strong></div></div><div class="review-text" data-financial-notes></div>`,onEnter:({root,data:formData})=>{root.querySelector("[data-financial-decision]").textContent=fmt.label(formData.decision);root.querySelector("[data-financial-amount]").textContent=formData.amount?fmt.money(formData.amount):"No registrado";root.querySelector("[data-financial-notes]").innerHTML=`<strong>Observaciones</strong><p>${fmt.escape(formData.notes||"")}</p>`}}],onFinish:async({data:formData})=>{await api.saveFinancialValidation(data.order.id,{...formData,validationType:type});await afterDomain(data,drawer,overlay,"Validación financiera registrada.")}});
}
function purchaseWizard(data,drawer,overlay){
  wizard({title:"Registrar orden de compra",subtitle:"Completa la información del proveedor y la entrega esperada.",finishLabel:"Guardar orden de compra",steps:[{title:"Orden y proveedor",description:"Identifica el documento y el proveedor.",content:`<div class="form-grid"><div class="field"><label>Número de orden *</label><input class="control" name="poNumber" required></div><div class="field"><label>Proveedor *</label><input class="control" name="supplierName" required></div><div class="field"><label>Valor total</label><input class="control" name="totalAmount" type="number" step="any"></div><div class="field"><label>Fecha esperada</label><input class="control" name="expectedAt" type="datetime-local"></div></div>`},{title:"Estado",description:"Indica la situación actual de la orden.",content:`<div class="wizard-choice-grid">${choice("status","ISSUED","Emitida","La orden fue generada y enviada.",true)}${choice("status","CONFIRMED","Confirmada","El proveedor confirmó la orden.")}${choice("status","PARTIAL","Parcial","La orden tiene cumplimiento parcial.")}${choice("status","RECEIVED","Recibida","La mercancía fue recibida.")}${choice("status","CANCELLED","Cancelada","La orden no continuará.")}</div>`},{title:"Revisar",description:"Comprueba la información registrada.",content:`<div class="wizard-summary">${summaryItem("Pedido",data.order.order_number)}<div class="wizard-summary-item"><label>Orden</label><strong data-po-number></strong></div><div class="wizard-summary-item"><label>Proveedor</label><strong data-po-supplier></strong></div><div class="wizard-summary-item"><label>Estado</label><strong data-po-status></strong></div></div>`,onEnter:({root,data:formData})=>{root.querySelector("[data-po-number]").textContent=formData.poNumber||"—";root.querySelector("[data-po-supplier]").textContent=formData.supplierName||"—";root.querySelector("[data-po-status]").textContent=fmt.label(formData.status)}}],onFinish:async({data:formData})=>{if(formData.expectedAt)formData.expectedAt=new Date(formData.expectedAt).toISOString();await api.savePurchaseOrder(data.order.id,formData);await afterDomain(data,drawer,overlay,"Orden de compra registrada.")}});
}
function receiptWizard(data,drawer,overlay){
  const itemOptions=data.items.map(item=>`<option value="${item.id}" data-sku="${fmt.escape(item.sku||"")}" data-description="${fmt.escape(item.description)}" data-unit="${fmt.escape(item.unit)}" data-quantity="${item.quantity}">${item.line_number} · ${fmt.escape(item.sku||item.description)}</option>`).join("");
  const assistant=wizard({title:"Registrar recepción de mercancía",subtitle:"Registra el documento, las cantidades y el resultado de calidad.",finishLabel:"Guardar recepción",steps:[{title:"Documento de recepción",description:"Identifica la recepción y su proveedor.",content:`<div class="form-grid"><div class="field"><label>Número de recepción *</label><input class="control" name="receiptNumber" required></div><div class="field"><label>Orden de compra</label><input class="control" name="purchaseOrder"></div><div class="field"><label>Proveedor</label><input class="control" name="supplierName"></div><div class="field"><label>Estado</label><select class="control" name="status"><option value="CONFORMING">Conforme</option><option value="PARTIAL">Parcial</option><option value="NONCONFORMING">No conforme</option></select></div></div>`},{title:"Material recibido",description:"Agrega una línea por material, lote o ubicación.",content:`<div class="items-wizard-head"><div><strong>Líneas recibidas</strong><p>Registra cantidad recibida, aceptada, rechazada y ubicación.</p></div><button class="btn btn-ghost" type="button" id="add-receipt-line">＋ Agregar línea</button></div><div id="receipt-lines" class="items-editor"></div>`,validate:({root})=>{const lines=[...root.querySelectorAll(".receipt-line")];if(!lines.length)throw new Error("Agrega al menos una línea recibida.");if(lines.some(row=>!row.querySelector('[name="description"]').value.trim()||Number(row.querySelector('[name="receivedQuantity"]').value)<=0))throw new Error("Cada línea debe tener descripción y cantidad recibida mayor que cero.");return true}},{title:"Revisar",description:"Comprueba el total de líneas y el estado de recepción.",content:`<div class="wizard-summary">${summaryItem("Pedido",data.order.order_number)}<div class="wizard-summary-item"><label>Recepción</label><strong data-receipt-number></strong></div><div class="wizard-summary-item"><label>Estado</label><strong data-receipt-status></strong></div><div class="wizard-summary-item"><label>Líneas</label><strong data-receipt-lines></strong></div></div>`,onEnter:({root,data:formData})=>{root.querySelector("[data-receipt-number]").textContent=formData.receiptNumber||"—";root.querySelector("[data-receipt-status]").textContent=fmt.label(formData.status);root.querySelector("[data-receipt-lines]").textContent=String(root.querySelectorAll(".receipt-line").length)}}],onFinish:async({root,data:formData})=>{const lines=[...root.querySelectorAll(".receipt-line")].map(row=>({orderItemId:row.querySelector('[name="orderItemId"]').value||null,sku:row.querySelector('[name="sku"]').value||null,description:row.querySelector('[name="description"]').value.trim(),expectedQuantity:Number(row.querySelector('[name="expectedQuantity"]').value||0)||null,receivedQuantity:Number(row.querySelector('[name="receivedQuantity"]').value),acceptedQuantity:Number(row.querySelector('[name="acceptedQuantity"]').value),rejectedQuantity:Number(row.querySelector('[name="rejectedQuantity"]').value||0),unit:row.querySelector('[name="unit"]').value,location:row.querySelector('[name="location"]').value,lotNumber:row.querySelector('[name="lotNumber"]').value||null,qualityStatus:row.querySelector('[name="qualityStatus"]').value,metadata:{lotNumber:row.querySelector('[name="lotNumber"]').value||null}}));await api.saveReceipt(data.order.id,{receiptNumber:formData.receiptNumber,purchaseOrder:formData.purchaseOrder,supplierName:formData.supplierName,status:formData.status,lines});await afterDomain(data,drawer,overlay,"Recepción, calidad e inventario registrados.")}});
  const list=assistant.root.querySelector("#receipt-lines");
  const add=()=>{const row=document.createElement("div");row.className="receipt-line card card-pad";row.innerHTML=`<div class="form-grid"><div class="field full"><label>Ítem del pedido</label><select class="control" name="orderItemId"><option value="">Material adicional</option>${itemOptions}</select></div><div class="field"><label>SKU</label><input class="control" name="sku"></div><div class="field"><label>Descripción *</label><input class="control" name="description" required></div><div class="field"><label>Esperado</label><input class="control" name="expectedQuantity" type="number" step="any"></div><div class="field"><label>Recibido *</label><input class="control" name="receivedQuantity" type="number" step="any" required></div><div class="field"><label>Aceptado *</label><input class="control" name="acceptedQuantity" type="number" step="any" required></div><div class="field"><label>Rechazado</label><input class="control" name="rejectedQuantity" type="number" step="any" value="0"></div><div class="field"><label>Unidad</label><input class="control" name="unit" value="UND"></div><div class="field"><label>Ubicación</label><input class="control" name="location" value="RECEPCION"></div><div class="field"><label>Lote</label><input class="control" name="lotNumber"></div><div class="field"><label>Calidad</label><select class="control" name="qualityStatus"><option value="ACCEPTED">Aceptado</option><option value="CONDITIONAL">Aceptado con condición</option><option value="REJECTED">Rechazado</option></select></div><div class="field"><button class="btn btn-danger" type="button" data-remove>Eliminar línea</button></div></div>`;const selectItem=row.querySelector('[name="orderItemId"]');selectItem.onchange=()=>{const option=selectItem.selectedOptions[0];if(!option?.value)return;row.querySelector('[name="sku"]').value=option.dataset.sku||"";row.querySelector('[name="description"]').value=option.dataset.description||"";row.querySelector('[name="unit"]').value=option.dataset.unit||"UND";row.querySelector('[name="expectedQuantity"]').value=option.dataset.quantity||"";row.querySelector('[name="receivedQuantity"]').value=option.dataset.quantity||"";row.querySelector('[name="acceptedQuantity"]').value=option.dataset.quantity||""};row.querySelector("[data-remove]").onclick=()=>row.remove();list.append(row)};
  assistant.root.querySelector("#add-receipt-line").onclick=add;add();
}
async function cutWizard(data,drawer,overlay){
  const lots=await api.inventoryLots(null,"");
  const cutItems=data.items.filter(item=>item.requires_cut);
  if(!lots.length)return toast("No hay lotes disponibles para registrar el corte.","error");
  if(!cutItems.length)return toast("El pedido no tiene ítems marcados para corte.","error");
  wizard({title:"Registrar trabajo de corte",subtitle:"Selecciona la chipa, el material y registra las medidas reales.",finishLabel:"Guardar corte",steps:[{title:"Seleccionar material",description:"Elige el lote disponible y la línea del pedido.",content:`<div class="field"><label>Chipa o lote disponible *</label><select class="control" name="inventoryLotId" required><option value="">Seleccione…</option>${lots.map(lot=>`<option value="${lot.id}">${fmt.escape(lot.sku)} · ${fmt.escape(lot.description)} · ${fmt.escape(lot.location)} · disponible ${fmt.number(lot.available,3)} ${fmt.escape(lot.unit)}</option>`).join("")}</select></div><div class="field"><label>Ítem del pedido *</label><select class="control" name="orderItemId" required><option value="">Seleccione…</option>${cutItems.map(item=>`<option value="${item.id}">${item.line_number} · ${fmt.escape(item.sku||item.description)}</option>`).join("")}</select></div>`},{title:"Registrar medidas",description:"Indica lo solicitado, lo cortado y el desperdicio.",content:`<div class="form-grid"><div class="field"><label>Longitud solicitada *</label><input class="control" name="requestedLength" type="number" min="0" step="any" required></div><div class="field"><label>Longitud real *</label><input class="control" name="actualLength" type="number" min="0" step="any" required></div><div class="field"><label>Desperdicio</label><input class="control" name="scrapLength" type="number" min="0" step="any" value="0"></div></div><div class="wizard-tip">Mide y verifica antes de guardar. Estos datos alimentan el consumo de inventario y el VSM.</div>`},{title:"Revisar",description:"Comprueba las medidas antes de afectar el inventario.",content:`<div class="wizard-summary"><div class="wizard-summary-item"><label>Solicitado</label><strong data-cut-requested></strong></div><div class="wizard-summary-item"><label>Real</label><strong data-cut-actual></strong></div><div class="wizard-summary-item"><label>Desperdicio</label><strong data-cut-scrap></strong></div></div>`,onEnter:({root,data:formData})=>{root.querySelector("[data-cut-requested]").textContent=formData.requestedLength||"—";root.querySelector("[data-cut-actual]").textContent=formData.actualLength||"—";root.querySelector("[data-cut-scrap]").textContent=formData.scrapLength||"0"}}],onFinish:async({data:formData})=>{await api.saveCutJob(data.order.id,formData);await afterDomain(data,drawer,overlay,"Corte, consumo y desperdicio registrados.")}});
}
function invoiceWizard(data,drawer,overlay){
  wizard({title:"Registrar factura",subtitle:"Completa los datos principales de facturación.",finishLabel:"Guardar factura",steps:[{title:"Datos de factura",description:"Registra número, fecha y valor.",content:`<div class="form-grid"><div class="field"><label>Número de factura *</label><input class="control" name="invoiceNumber" required></div><div class="field"><label>Fecha *</label><input class="control" name="invoiceDate" type="date" value="${new Date().toISOString().slice(0,10)}" required></div><div class="field"><label>Valor</label><input class="control" name="amount" type="number" step="any"></div><div class="field"><label>Moneda</label><input class="control" name="currency" value="COP"></div></div>`},{title:"Revisar",description:"Comprueba los datos antes de guardar.",content:`<div class="wizard-summary">${summaryItem("Pedido",data.order.order_number)}<div class="wizard-summary-item"><label>Factura</label><strong data-invoice-number></strong></div><div class="wizard-summary-item"><label>Fecha</label><strong data-invoice-date></strong></div><div class="wizard-summary-item"><label>Valor</label><strong data-invoice-amount></strong></div></div>`,onEnter:({root,data:formData})=>{root.querySelector("[data-invoice-number]").textContent=formData.invoiceNumber||"—";root.querySelector("[data-invoice-date]").textContent=formData.invoiceDate||"—";root.querySelector("[data-invoice-amount]").textContent=formData.amount?fmt.money(formData.amount):"No registrado"}}],onFinish:async({data:formData})=>{await api.saveInvoice(data.order.id,formData);await afterDomain(data,drawer,overlay,"Factura registrada.")}});
}
function deliveryWizard(data,drawer,overlay){
  wizard({title:"Registrar despacho o entrega",subtitle:"Indica el estado, las fechas y el soporte de transporte.",finishLabel:"Guardar entrega",steps:[{title:"Resultado",description:"Selecciona la situación actual de la entrega.",content:`<div class="wizard-choice-grid">${choice("status","PLANNED","Programado","La entrega tiene fecha definida.",true)}${choice("status","DISPATCHED","Despachado","El pedido salió de la operación.")}${choice("status","IN_TRANSIT","En tránsito","La transportadora tiene el pedido.")}${choice("status","DELIVERED","Entregado","El cliente recibió el pedido.")}${choice("status","NOT_DELIVERED","No entregado","El intento no pudo completarse.")}</div>`},{title:"Datos de transporte",description:"Completa únicamente la información disponible.",content:`<div class="form-grid"><div class="field"><label>Fecha programada</label><input class="control" name="scheduledAt" type="datetime-local"></div><div class="field"><label>Fecha de despacho</label><input class="control" name="dispatchedAt" type="datetime-local"></div><div class="field"><label>Fecha de entrega</label><input class="control" name="deliveredAt" type="datetime-local"></div><div class="field"><label>Transportadora</label><input class="control" name="carrier"></div><div class="field"><label>Número de guía</label><input class="control" name="trackingNumber"></div><div class="field"><label>Recibido por</label><input class="control" name="receivedBy"></div><div class="field full"><label>Motivo de no entrega</label><textarea class="control" name="noDeliveryReason"></textarea></div></div>`},{title:"Revisar",description:"Comprueba el resultado de la entrega.",content:`<div class="wizard-summary">${summaryItem("Pedido",data.order.order_number)}<div class="wizard-summary-item"><label>Estado</label><strong data-delivery-status></strong></div><div class="wizard-summary-item"><label>Transportadora</label><strong data-delivery-carrier></strong></div><div class="wizard-summary-item"><label>Guía</label><strong data-delivery-tracking></strong></div></div>`,onEnter:({root,data:formData})=>{root.querySelector("[data-delivery-status]").textContent=fmt.label(formData.status);root.querySelector("[data-delivery-carrier]").textContent=formData.carrier||"No registrada";root.querySelector("[data-delivery-tracking]").textContent=formData.trackingNumber||"No registrada"}}],onFinish:async({data:formData})=>{for(const key of ["scheduledAt","dispatchedAt","deliveredAt"])if(formData[key])formData[key]=new Date(formData[key]).toISOString();await api.saveDelivery(data.order.id,formData);await afterDomain(data,drawer,overlay,"Despacho o entrega registrados.")}});
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
  w.document.write(`<!doctype html><meta charset="utf-8"><title>Etiquetas de recepción</title><style>body{font-family:Arial;margin:12mm}.grid{display:grid;grid-template-columns:repeat(2,1fr);gap:7mm}.s{border:2px solid #111;border-radius:8px;padding:7mm;min-height:62mm;page-break-inside:avoid}.h{display:flex;justify-content:space-between;border-bottom:1px solid #333;padding-bottom:4mm;margin-bottom:4mm}.big{font-size:20px;font-weight:900}.r{display:grid;grid-template-columns:110px 1fr;margin:2mm 0}.l{font-size:10px;text-transform:uppercase;color:#555}.v{font-weight:700}@media print{body{margin:5mm}.s{min-height:55mm}}</style><div class="grid">${rows.map(r=>`<article class="s"><div class="h"><div><div class="l">Recepción</div><div class="big">${fmt.escape(r.receiptNumber||"")}</div></div><div><div class="l">OC</div><strong>${fmt.escape(r.purchaseOrder||"—")}</strong></div></div><div class="r"><span class="l">Material</span><span class="v">${fmt.escape(r.description)}</span></div><div class="r"><span class="l">SKU</span><span class="v">${fmt.escape(r.sku||"—")}</span></div><div class="r"><span class="l">Cantidad</span><span class="v">${fmt.number(r.quantity,3)} ${fmt.escape(r.unit)}</span></div><div class="r"><span class="l">Ubicación</span><span class="v">${fmt.escape(r.location||"—")}</span></div><div class="r"><span class="l">Calidad</span><span class="v">${fmt.escape(fmt.label(r.qualityStatus||"—"))}</span></div></article>`).join("")}</div><script>onload=()=>print()<\/script>`);
  w.document.close();
}
