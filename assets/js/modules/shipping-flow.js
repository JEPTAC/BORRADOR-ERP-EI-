import {api} from "../services/api.js";
import {fmt,statusBadge,priorityBadge} from "../core/format.js";
import {modal,toast,loading,empty,paginationHtml} from "../core/ui.js";
import {uploadOrderFile} from "../services/drive.js";
import {hasRole} from "../core/state.js";
import {parallelWorkFooter} from "./active-work.js";

const ROUTE_STEPS=new Set(["CLIENT_POINT","CLIENT_PICKUP","LOCAL_DISPATCH","NATIONAL_DISPATCH"]);
export function isShippingFlow(data){return ROUTE_STEPS.has(data?.order?.current_step_code)||data?.order?.current_step_code==="CLOSURE"}

function activeTask(data){return (data.tasks||[]).find(task=>["QUEUED","ASSIGNED","IN_PROGRESS","WAITING","BLOCKED"].includes(task.status))||null}
function actionSet(data){return new Set((data.actions?.actions||[]).map(action=>action.code))}
function latestDelivery(data){return [...(data.deliveries||[])].sort((a,b)=>new Date(b.updated_at||b.created_at)-new Date(a.updated_at||a.created_at))[0]||null}
function destination(delivery,order={}){
  const stored=delivery?.metadata?.destination||{};
  const metadata=order?.metadata||{};
  return {
    department:stored.department||metadata.clientDepartment||order.client_department||"",
    municipality:stored.municipality||metadata.clientCity||order.client_city||"",
    address:stored.address||metadata.clientAddress||order.client_address||"",
    source:stored.source||"SALES_ORDER_ADDRESS"
  };
}
function deliveryEvidence(data,taskId){return (data.files||[]).filter(file=>file.file_category==="DELIVERY_EVIDENCE"&&(!taskId||file.task_id===taskId)).sort((a,b)=>new Date(b.created_at)-new Date(a.created_at))[0]||null}
function guideFile(data){return (data.files||[]).filter(file=>file.file_category==="SHIPPING_GUIDE").sort((a,b)=>new Date(b.created_at)-new Date(a.created_at))[0]||null}
function canReportNoDelivery(){return hasRole("ventas")||hasRole("super_admin")}
function canOperateShipping(){return hasRole("super_admin")||hasRole("coordinador_logistico")||hasRole("despacho_nacional")||hasRole("jefe_logistica")}

export function renderShippingFlow(host,data,{reload,refreshLists}={}){
  if(!canOperateShipping())return renderCommercialViewer(host,data,{refreshLists});
  const step=data.order.current_step_code;
  if(step==="CLOSURE")return renderClosure(host,data,{reload,refreshLists});
  return renderDispatch(host,data,{reload,refreshLists});
}


function renderCommercialViewer(host,data,{refreshLists}={}){
  const delivery=latestDelivery(data),place=destination(delivery,data.order),hasException=Boolean(data.order?.metadata?.deliveryExceptionOpen)||delivery?.status==="NOT_DELIVERED";
  shell(host,data,`<section class="shipping-commercial-view"><header><div><span>Seguimiento comercial</span><h4>Pedido enviado</h4><p>Consulta la guía, la dirección registrada y el estado. Ventas no puede modificar el despacho.</p></div>${statusBadge(delivery?.status||data.order.status)}</header>${dispatchRecap(delivery,place)}<div class="commercial-shipping-actions">${canReportNoDelivery()&&!hasException&&delivery?.dispatched_at?'<button class="btn btn-danger btn-large" data-commercial-no-delivery>Reportar no entrega</button>':hasException?'<span class="sent-order-alert">Novedad de no entrega registrada</span>':''}</div><details class="simple-details" open><summary>Ver trazabilidad y tiempos</summary>${shippingSummary(data)}</details></section>`,``);
  host.querySelector("[data-commercial-no-delivery]")?.addEventListener("click",()=>openNoDeliveryReport({id:data.order.id,orderNumber:data.order.order_number},{onSaved:()=>{host.replaceChildren();refreshLists?.();}}));
}

function shell(host,data,body,footer=""){
  const order=data.order;
  host.innerHTML=`<div class="modal-overlay shipping-process-overlay"><section class="modal shipping-process-modal wide">
    <header class="modal-head shipping-process-head"><div><span class="wizard-kicker">Despachos y entregas</span><h3>${fmt.escape(order.order_number)}</h3><p>${fmt.escape(order.client_name)} · ${fmt.escape(fmt.route(order.delivery_route_code))}</p></div><button class="icon-btn" data-close aria-label="Cerrar">×</button></header>
    <div class="modal-body shipping-process-body">${body}</div>${footer||parallelWorkFooter(order.current_step_code)}
  </section></div>`;
  host.querySelectorAll("[data-close]").forEach(button=>button.onclick=()=>host.replaceChildren());
}

function renderDispatch(host,data,{reload,refreshLists}){
  const task=activeTask(data),delivery=latestDelivery(data),place=destination(delivery,data.order);
  const started=task?.status==="IN_PROGRESS";
  const guideReady=Boolean(delivery?.tracking_number);
  if(!started){
    shell(host,data,`<section class="shipping-take-card"><span class="shipping-route-chip">${fmt.escape(fmt.route(data.order.delivery_route_code))}</span><div class="shipping-take-icon">↗</div><h4>El pedido está listo para despacho</h4><p>Tómalo para registrar la guía y enviarlo directamente al cierre. La dirección ya fue registrada por Ventas.</p><button class="btn btn-primary btn-hero" data-take-shipping>Tomar pedido</button>${task?.status==="WAITING"||task?.status==="BLOCKED"?`<small>El pedido estaba en espera. Al tomarlo se retomará la gestión.</small>`:""}</section>${locationSummary(place)}<details class="simple-details"><summary>Ver información completa del pedido</summary>${shippingSummary(data)}</details>`);
    host.querySelector("[data-take-shipping]")?.addEventListener("click",async button=>{
      button.disabled=true;
      try{
        let current=data;let available=actionSet(current);
        if(available.has("CLAIM")){await api.executeAction(current.order.id,"CLAIM",{detail:"Pedido tomado para despacho"},current.order.version);current=await api.getOrder(current.order.id);available=actionSet(current)}
        if(available.has("START"))await api.executeAction(current.order.id,"START",{detail:"Gestión de despacho iniciada"},current.order.version);
        else if(available.has("RESUME"))await api.executeAction(current.order.id,"RESUME",{detail:"Gestión de despacho retomada"},current.order.version);
        toast("Pedido tomado. Ya puedes agregar la guía.","success");refreshLists?.();await reload?.();
      }catch(error){toast(error.message,"error",7000);button.disabled=false}
    });
    return;
  }

  shell(host,data,`<section class="shipping-progress shipping-progress-three" aria-label="Progreso del despacho">
      ${progressItem(1,"Tomar pedido",true)}${progressItem(2,"Agregar guía",guideReady,!guideReady)}${progressItem(3,"Pasar a cierre",false,guideReady)}
    </section>
    <section class="shipping-overview-grid"><article><small>Pedido</small><strong>${fmt.escape(data.order.order_number)}</strong></article><article><small>Cliente</small><strong>${fmt.escape(data.order.client_name)}</strong></article><article><small>Modalidad</small><strong>${fmt.escape(fmt.route(data.order.delivery_route_code))}</strong></article><article><small>Responsable</small><strong>${fmt.escape(task.assigned_name||"Usuario actual")}</strong></article></section>
    ${locationSummary(place)}
    <section class="shipping-action-stack single">
      <article class="shipping-step-card ${guideReady?"completed":"active"}"><header><span>2</span><div><h4>Agregar guía</h4><p>Registra el número de guía y la transportadora. El soporte es opcional.</p></div>${guideReady?'<b>Lista</b>':""}</header>${guideReady?guideSummary(delivery,guideFile(data)):`<button class="btn btn-primary btn-large" data-add-guide>Agregar guía</button>`}${guideReady?'<button class="btn btn-ghost btn-compact" data-add-guide>Editar guía</button>':""}</article>
    </section>
    <section class="shipping-closure-callout ${guideReady?"ready":"pending"}"><div><span>${guideReady?"Todo listo":"Falta la guía"}</span><h4>Pasar a cierre</h4><p>${guideReady?"El pedido quedará en tránsito y abrirá la etapa de cierre para registrar la foto final.":"Registra la guía antes de continuar."}</p></div><button class="btn btn-success btn-large" data-send-closure ${guideReady?"":"disabled"}>Pasar a cierre</button></section>
    <details class="simple-details"><summary>Ver información completa del pedido</summary>${shippingSummary(data)}</details>`);

  host.querySelectorAll("[data-add-guide]").forEach(button=>button.onclick=()=>openGuideDialog(data,delivery,{reload,refreshLists}));
  host.querySelector("[data-send-closure]")?.addEventListener("click",async button=>{
    button.disabled=true;
    try{await api.sendShippingToClosure(data.order.id,{detail:"Pedido despachado y enviado a cierre",expectedVersion:data.order.version});toast("Pedido enviado a cierre.","success",6000);host.replaceChildren();refreshLists?.();}
    catch(error){toast(error.message,"error",7000);button.disabled=false}
  });
}

function renderClosure(host,data,{reload,refreshLists}){
  const task=activeTask(data),actions=actionSet(data),delivery=latestDelivery(data),place=destination(delivery,data.order),evidence=deliveryEvidence(data,task?.id),started=task?.status==="IN_PROGRESS";
  if(!started){
    shell(host,data,`<section class="shipping-take-card closure"><span class="shipping-route-chip">Cierre de entrega</span><div class="shipping-take-icon">✓</div><h4>Confirma la llegada del pedido</h4><p>Cuando la mercancía haya llegado, toma el pedido para subir la foto y finalizarlo.</p><button class="btn btn-primary btn-hero" data-take-closure>Tomar pedido</button></section>${dispatchRecap(delivery,place)}`);
    host.querySelector("[data-take-closure]")?.addEventListener("click",async button=>{
      button.disabled=true;
      try{
        let current=data,available=actionSet(current);
        if(available.has("CLAIM")){await api.executeAction(current.order.id,"CLAIM",{detail:"Cierre de entrega tomado"},current.order.version);current=await api.getOrder(current.order.id);available=actionSet(current)}
        if(available.has("START"))await api.executeAction(current.order.id,"START",{detail:"Verificación final de entrega iniciada"},current.order.version);
        else if(available.has("RESUME"))await api.executeAction(current.order.id,"RESUME",{detail:"Cierre de entrega retomado"},current.order.version);
        toast("Cierre iniciado. Sube la foto de entrega.","success");refreshLists?.();await reload?.();
      }catch(error){toast(error.message,"error",7000);button.disabled=false}
    });
    return;
  }

  shell(host,data,`<section class="shipping-progress closure-progress">${progressItem(1,"Despacho",true)}${progressItem(2,"Llegada",true)}${progressItem(3,"Foto de entrega",Boolean(evidence),!evidence)}${progressItem(4,"Pedido finalizado",false,Boolean(evidence))}</section>
    ${dispatchRecap(delivery,place)}
    <section class="delivery-photo-panel ${evidence?"complete":""}"><div class="delivery-photo-copy"><span>${evidence?"Evidencia cargada":"Evidencia obligatoria"}</span><h4>Subir foto de la mercancía entregada</h4><p>La imagen debe permitir identificar que el pedido llegó a la dirección registrada por Ventas.</p></div>${evidence?`<article class="delivery-file-card"><div><strong>${fmt.escape(evidence.file_name)}</strong><small>${fmt.date(evidence.created_at)}</small></div>${evidence.web_view_link?`<a class="btn btn-ghost" href="${fmt.escape(evidence.web_view_link)}" target="_blank" rel="noopener">Ver foto</a>`:""}</article>`:`<button class="btn btn-primary btn-large" data-upload-delivery-photo>Subir foto</button>`}</section>
    <section class="shipping-finalize-panel ${evidence?"ready":"pending"}"><div><span>${evidence?"Entrega comprobada":"Pendiente de evidencia"}</span><h4>Pedido finalizado</h4><p>${evidence?"Al confirmar, el pedido se cerrará y quedarán calculados sus tiempos por proceso.":"Sube la foto antes de finalizar."}</p></div><button class="btn btn-success btn-hero" data-finish-delivery ${evidence?"":"disabled"}>Pedido finalizado</button></section>
    <details class="simple-details"><summary>Ver trazabilidad y tiempos</summary>${shippingSummary(data)}</details>`);

  host.querySelector("[data-upload-delivery-photo]")?.addEventListener("click",()=>openEvidenceDialog(data,{reload,refreshLists}));
  host.querySelector("[data-finish-delivery]")?.addEventListener("click",()=>openFinalizeDialog(data,{host,refreshLists}));
}

function openGuideDialog(data,delivery,{reload,refreshLists}){
  modal({title:"Agregar guía",confirmLabel:"Guardar guía",size:"wide",body:`<div class="shipping-dialog-intro"><strong>Información de transporte</strong><p>Registra los datos con los que se identificará el envío.</p></div><div class="form-grid"><div class="field"><label>Número de guía *</label><input class="control" name="trackingNumber" value="${fmt.escape(delivery?.tracking_number||"")}" required autofocus></div><div class="field"><label>Transportadora</label><input class="control" name="carrier" value="${fmt.escape(delivery?.carrier||"")}"></div><div class="field full"><label>Soporte de guía, opcional</label><input class="control" name="guideFile" type="file" accept="image/*,.pdf,application/pdf"></div></div>`,onConfirm:async dialog=>{
    const trackingNumber=dialog.querySelector('[name="trackingNumber"]').value.trim(),carrier=dialog.querySelector('[name="carrier"]').value.trim(),file=dialog.querySelector('[name="guideFile"]').files[0];
    let fileId=null;if(file){const uploaded=await uploadOrderFile(data.order.id,file,"SHIPPING_GUIDE",activeTask(data)?.id,data.order.order_number);fileId=uploaded?.file?.id||null}
    await api.saveShippingGuide(data.order.id,{trackingNumber,carrier:carrier||null,guideFileId:fileId});toast("Guía guardada.","success");refreshLists?.();setTimeout(()=>reload?.(),80);
  }});
}

function openEvidenceDialog(data,{reload,refreshLists}){
  modal({title:"Subir foto de entrega",confirmLabel:"Subir evidencia",body:`<div class="shipping-dialog-intro"><strong>Foto obligatoria</strong><p>Selecciona una imagen en la que se identifique la mercancía entregada.</p></div><div class="field"><label>Foto *</label><input class="control" name="file" type="file" accept="image/*" capture="environment" required></div>`,onConfirm:async dialog=>{
    const file=dialog.querySelector('[name="file"]').files[0];if(!file?.type?.startsWith("image/"))throw new Error("Debes seleccionar una imagen.");
    const task=activeTask(data),uploaded=await uploadOrderFile(data.order.id,file,"DELIVERY_EVIDENCE",task?.id,data.order.order_number);await api.registerShippingEvidence(data.order.id,{fileId:uploaded?.file?.id,taskId:task?.id});toast("Foto de entrega cargada.","success");refreshLists?.();setTimeout(()=>reload?.(),80);
  }});
}

function openFinalizeDialog(data,{host,refreshLists}){
  modal({title:"Finalizar pedido",confirmLabel:"Sí, finalizar pedido",body:`<div class="wizard-confirm-box"><strong>El pedido quedará cerrado</strong><p>La entrega, la evidencia y todos los tiempos del flujo permanecerán disponibles en la trazabilidad.</p></div><div class="field"><label>Recibido por, opcional</label><input class="control" name="receivedBy" placeholder="Nombre de quien recibió"></div>`,onConfirm:async dialog=>{
    const receivedBy=dialog.querySelector('[name="receivedBy"]').value.trim();await api.finalizeShipping(data.order.id,{receivedBy:receivedBy||null});toast("Pedido finalizado correctamente.","success",7000);document.querySelector("#modal-root")?.replaceChildren();host?.replaceChildren();refreshLists?.();
  }});
}

export function openNoDeliveryReport(order,{onSaved}={}){
  if(!canReportNoDelivery())return toast("Solo Ventas o Superadministración pueden registrar una no entrega.","error",7000);
  modal({title:"Reportar novedad de no entrega",confirmLabel:"Registrar novedad",size:"wide",body:`<div class="shipping-dialog-intro danger"><strong>${fmt.escape(order.orderNumber||order.order_number||"Pedido")}</strong><p>Esta novedad quedará en la trazabilidad y será visible para Logística.</p></div><div class="field"><label>Motivo de no entrega *</label><textarea class="control" name="reason" required autofocus placeholder="Explica por qué el cliente no recibió el pedido"></textarea></div><div class="field"><label>Acción solicitada</label><select class="control" name="requestedAction"><option value="CONTACT_CLIENT">Contactar al cliente</option><option value="REPROGRAM">Reprogramar entrega</option><option value="RETURN">Retornar mercancía</option><option value="REVIEW">Revisar con Logística</option></select></div>`,onConfirm:async dialog=>{
    const reason=dialog.querySelector('[name="reason"]').value.trim(),requestedAction=dialog.querySelector('[name="requestedAction"]').value;await api.reportShippingNoDelivery(order.id,{reason,requestedAction});toast("Novedad de no entrega registrada.","success",6500);onSaved?.();
  }});
}

export async function renderSentOrdersPanel(target,{search="",page=1,onOpen}={}){
  target.innerHTML=loading("Consultando pedidos enviados…");
  try{
    const data=await api.shippingSentOrders(search,page,30),rows=data.items||[];
    target.innerHTML=rows.length?`<div class="sent-orders-grid">${rows.map(row=>`<article class="sent-order-card ${row.hasNoDelivery?"novelty":""}"><header><div><span>${fmt.escape(row.orderNumber)}</span><h4>${fmt.escape(row.clientName)}</h4></div>${priorityBadge(row.priority)}</header><div class="sent-order-route"><strong>${fmt.escape(fmt.route(row.route))}</strong>${statusBadge(row.deliveryStatus||row.status)}</div><dl><div><dt>Guía</dt><dd>${fmt.escape(row.trackingNumber||"Sin guía")}</dd></div><div><dt>Municipio</dt><dd>${fmt.escape(row.municipality||"—")}</dd></div><div><dt>Enviado</dt><dd>${fmt.date(row.dispatchedAt)}</dd></div><div><dt>Responsable</dt><dd>${fmt.escape(row.assigneeName||"—")}</dd></div></dl><footer>${row.hasNoDelivery?'<span class="sent-order-alert">Novedad registrada</span>':row.canReportNoDelivery?`<button class="btn btn-danger btn-compact" data-no-delivery="${fmt.escape(row.id)}">Reportar no entrega</button>`:'<span class="sent-order-closed">Entrega finalizada</span>'}<button class="btn btn-ghost btn-compact" data-open-sent="${fmt.escape(row.id)}">Ver pedido</button></footer></article>`).join("")}</div>${paginationHtml(data.pagination)}`:empty("No hay pedidos enviados","Los pedidos aparecerán cuando Logística los pase a cierre.");
    target.querySelectorAll("[data-no-delivery]").forEach(button=>button.onclick=()=>{const row=rows.find(item=>item.id===button.dataset.noDelivery);if(row)openNoDeliveryReport(row,{onSaved:()=>renderSentOrdersPanel(target,{search,page,onOpen})})});
    target.querySelectorAll("[data-open-sent]").forEach(button=>button.onclick=()=>onOpen?.(button.dataset.openSent));
    target.querySelectorAll("[data-page]").forEach(button=>button.onclick=()=>renderSentOrdersPanel(target,{search,page:Number(button.dataset.page),onOpen}));
  }catch(error){target.innerHTML=`<div class="module-error"><strong>No fue posible consultar los pedidos enviados</strong><p>${fmt.escape(error.message)}</p></div>`;}
}

function progressItem(number,label,done=false,active=false){return `<div class="shipping-progress-item ${done?"done":active?"active":""}"><span>${done?"✓":number}</span><strong>${fmt.escape(label)}</strong></div>`}
function guideSummary(delivery,file){return `<div class="shipping-data-card"><div><small>Número de guía</small><strong>${fmt.escape(delivery.tracking_number)}</strong></div><div><small>Transportadora</small><strong>${fmt.escape(delivery.carrier||"No indicada")}</strong></div>${file?`<a href="${fmt.escape(file.web_view_link||"#")}" target="_blank" rel="noopener">Ver soporte</a>`:""}</div>`}
function locationSummary(place){return `<section class="shipping-sales-address"><header><span>Dirección registrada por Ventas</span><strong>${fmt.escape(place.municipality||"Municipio no registrado")}${place.department?`, ${fmt.escape(place.department)}`:""}</strong></header><p>${fmt.escape(place.address||"Dirección no registrada")}</p><small>En Despachos esta información es de consulta. Cualquier corrección debe realizarse desde Ventas antes del envío.</small></section>`}
function dispatchRecap(delivery,place){return `<section class="dispatch-recap"><header><div><span>Envío en cierre</span><h4>${fmt.escape(delivery?.tracking_number||"Guía registrada")}</h4></div>${statusBadge(delivery?.status||"IN_TRANSIT")}</header><div class="dispatch-recap-grid"><div><small>Transportadora</small><strong>${fmt.escape(delivery?.carrier||"—")}</strong></div><div><small>Municipio</small><strong>${fmt.escape(place.municipality||"—")}</strong></div><div><small>Dirección</small><strong>${fmt.escape(place.address||"—")}</strong></div><div><small>Salida</small><strong>${fmt.date(delivery?.dispatched_at)}</strong></div></div></section>`}
function shippingSummary(data){
  const delivery=latestDelivery(data),place=destination(delivery,data.order),trace=data.deliveryTimeTrace||{};
  const traceCards=[
    ["Gestión de despacho",trace.dispatchBusinessSeconds,"Tiempo productivo"],
    ["Espera y tránsito",trace.transitBusinessSeconds,"Desde salida hasta entrega"],
    ["Cierre de entrega",trace.closureBusinessSeconds,"Validación y evidencia"],
    ["Tiempo muerto",trace.deadBusinessSeconds??trace.deadTimeSeconds,"Tiempo laboral sin gestión"]
  ];
  return `<div class="simple-detail-sections"><section><h4>Información del envío</h4><div class="detail-grid"><div class="info-box"><label>Ruta</label><strong>${fmt.escape(fmt.route(data.order.delivery_route_code))}</strong></div><div class="info-box"><label>Guía</label><strong>${fmt.escape(delivery?.tracking_number||"—")}</strong></div><div class="info-box"><label>Transportadora</label><strong>${fmt.escape(delivery?.carrier||"—")}</strong></div><div class="info-box"><label>Estado</label><strong>${fmt.escape(fmt.label(delivery?.status||data.order.status))}</strong></div><div class="info-box"><label>Municipio</label><strong>${fmt.escape(place.municipality||"—")}</strong></div><div class="info-box"><label>Dirección</label><strong>${fmt.escape(place.address||"—")}</strong></div></div></section><section><h4>Resumen de tiempos laborales</h4><div class="shipping-trace-metrics">${traceCards.map(([label,value,caption])=>`<article><small>${fmt.escape(label)}</small><strong>${fmt.hours(Number(value||0))}</strong><span>${fmt.escape(caption)}</span></article>`).join("")}</div><div class="shipping-time-list">${(data.tasks||[]).map(task=>`<article><span>${fmt.escape(fmt.step(task.step_code))}</span><strong>${fmt.hours(task.business_seconds)}</strong><small>Transcurrido: ${fmt.hours(task.raw_seconds)}</small></article>`).join("")}</div></section></div>`
}
