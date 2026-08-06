import {api} from "../services/api.js";
import {fmt,statusBadge,priorityBadge} from "../core/format.js";
import {modal,toast,loading,empty,paginationHtml} from "../core/ui.js";
import {uploadOrderFile} from "../services/drive.js";
import {buildColombianAddress,colombianDepartments,colombianMunicipalities,createLocationMap,elevationFor,findDepartmentByName,findMunicipalityByName,geocodeAddress,locateCurrentPlace,reverseGeocode} from "../services/location.js";
import {hasRole} from "../core/state.js";
import {parallelWorkFooter} from "./active-work.js";

const ROUTE_STEPS=new Set(["CLIENT_POINT","CLIENT_PICKUP","LOCAL_DISPATCH","NATIONAL_DISPATCH"]);
export function isShippingFlow(data){return ROUTE_STEPS.has(data?.order?.current_step_code)||data?.order?.current_step_code==="CLOSURE"}

function activeTask(data){return (data.tasks||[]).find(task=>["QUEUED","ASSIGNED","IN_PROGRESS","WAITING","BLOCKED"].includes(task.status))||null}
function actionSet(data){return new Set((data.actions?.actions||[]).map(action=>action.code))}
function latestDelivery(data){return [...(data.deliveries||[])].sort((a,b)=>new Date(b.updated_at||b.created_at)-new Date(a.updated_at||a.created_at))[0]||null}
function destination(delivery){return delivery?.metadata?.destination||{}}
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
  const delivery=latestDelivery(data),place=destination(delivery),hasException=Boolean(data.order?.metadata?.deliveryExceptionOpen)||delivery?.status==="NOT_DELIVERED";
  shell(host,data,`<section class="shipping-commercial-view"><header><div><span>Seguimiento comercial</span><h4>Pedido enviado</h4><p>Consulta la guía, el destino y el estado. Ventas no puede modificar el despacho.</p></div>${statusBadge(delivery?.status||data.order.status)}</header>${dispatchRecap(delivery,place)}<div class="commercial-shipping-actions">${canReportNoDelivery()&&!hasException&&delivery?.dispatched_at?'<button class="btn btn-danger btn-large" data-commercial-no-delivery>Reportar no entrega</button>':hasException?'<span class="sent-order-alert">Novedad de no entrega registrada</span>':''}</div><details class="simple-details" open><summary>Ver trazabilidad y tiempos</summary>${shippingSummary(data)}</details></section>`,``);
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
  const task=activeTask(data),actions=actionSet(data),delivery=latestDelivery(data),place=destination(delivery);
  const started=task?.status==="IN_PROGRESS";
  const guideReady=Boolean(delivery?.tracking_number);
  const locationReady=Number.isFinite(Number(place.latitude))&&Number.isFinite(Number(place.longitude))&&Boolean(place.municipality||place.address);
  if(!started){
    shell(host,data,`<section class="shipping-take-card"><span class="shipping-route-chip">${fmt.escape(fmt.route(data.order.delivery_route_code))}</span><div class="shipping-take-icon">↗</div><h4>El pedido está listo para despacho</h4><p>Tómalo para registrar la guía, confirmar el lugar y enviarlo al cierre.</p><button class="btn btn-primary btn-hero" data-take-shipping>Tomar pedido</button>${task?.status==="WAITING"||task?.status==="BLOCKED"?`<small>El pedido estaba en espera. Al tomarlo se retomará la gestión.</small>`:""}</section><details class="simple-details"><summary>Ver información completa del pedido</summary>${shippingSummary(data)}</details>`);
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

  shell(host,data,`<section class="shipping-progress" aria-label="Progreso del despacho">
      ${progressItem(1,"Tomar pedido",true)}${progressItem(2,"Agregar guía",guideReady,!guideReady)}${progressItem(3,"Especificar lugar",locationReady,guideReady&&!locationReady)}${progressItem(4,"Pasar a cierre",false,guideReady&&locationReady)}
    </section>
    <section class="shipping-overview-grid"><article><small>Pedido</small><strong>${fmt.escape(data.order.order_number)}</strong></article><article><small>Cliente</small><strong>${fmt.escape(data.order.client_name)}</strong></article><article><small>Modalidad</small><strong>${fmt.escape(fmt.route(data.order.delivery_route_code))}</strong></article><article><small>Responsable</small><strong>${fmt.escape(task.assigned_name||"Usuario actual")}</strong></article></section>
    <section class="shipping-action-stack">
      <article class="shipping-step-card ${guideReady?"completed":"active"}"><header><span>2</span><div><h4>Agregar guía</h4><p>Registra el número de guía y la transportadora. El soporte es opcional.</p></div>${guideReady?'<b>Lista</b>':""}</header>${guideReady?guideSummary(delivery,guideFile(data)):`<button class="btn btn-primary btn-large" data-add-guide>Agregar guía</button>`}${guideReady?'<button class="btn btn-ghost btn-compact" data-add-guide>Editar guía</button>':""}</article>
      <article class="shipping-step-card ${locationReady?"completed":guideReady?"active":"locked"}"><header><span>3</span><div><h4>Especificar lugar</h4><p>Obtén la ubicación del dispositivo y confirma municipio, dirección, coordenadas y altitud.</p></div>${locationReady?'<b>Ubicado</b>':""}</header>${locationReady?locationSummary(place):`<button class="btn btn-primary btn-large" data-set-location ${guideReady?"":"disabled"}>Ubicar lugar de entrega</button>`}${locationReady?'<button class="btn btn-ghost btn-compact" data-set-location>Actualizar ubicación</button>':""}</article>
    </section>
    <section class="shipping-closure-callout ${guideReady&&locationReady?"ready":"pending"}"><div><span>${guideReady&&locationReady?"Todo listo":"Faltan datos"}</span><h4>Pasar a cierre</h4><p>${guideReady&&locationReady?"El pedido quedará en tránsito y abrirá la etapa de cierre para registrar la evidencia final.":"Completa la guía y el lugar antes de continuar."}</p></div><button class="btn btn-success btn-large" data-send-closure ${guideReady&&locationReady?"":"disabled"}>Pasar a cierre</button></section>
    <details class="simple-details"><summary>Ver información completa del pedido</summary>${shippingSummary(data)}</details>`);

  host.querySelectorAll("[data-add-guide]").forEach(button=>button.onclick=()=>openGuideDialog(data,delivery,{reload,refreshLists}));
  host.querySelectorAll("[data-set-location]").forEach(button=>button.onclick=()=>openLocationDialog(data,place,{reload,refreshLists}));
  host.querySelector("[data-send-closure]")?.addEventListener("click",async button=>{
    button.disabled=true;
    try{await api.sendShippingToClosure(data.order.id,{detail:"Pedido despachado y enviado a cierre",expectedVersion:data.order.version});toast("Pedido enviado a cierre.","success",6000);host.replaceChildren();refreshLists?.();}
    catch(error){toast(error.message,"error",7000);button.disabled=false}
  });
}

function renderClosure(host,data,{reload,refreshLists}){
  const task=activeTask(data),actions=actionSet(data),delivery=latestDelivery(data),place=destination(delivery),evidence=deliveryEvidence(data,task?.id),started=task?.status==="IN_PROGRESS";
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
    <section class="delivery-photo-panel ${evidence?"complete":""}"><div class="delivery-photo-copy"><span>${evidence?"Evidencia cargada":"Evidencia obligatoria"}</span><h4>Subir foto de la mercancía entregada</h4><p>La imagen debe permitir identificar que el pedido llegó al lugar registrado.</p></div>${evidence?`<article class="delivery-file-card"><div><strong>${fmt.escape(evidence.file_name)}</strong><small>${fmt.date(evidence.created_at)}</small></div>${evidence.web_view_link?`<a class="btn btn-ghost" href="${fmt.escape(evidence.web_view_link)}" target="_blank" rel="noopener">Ver foto</a>`:""}</article>`:`<button class="btn btn-primary btn-large" data-upload-delivery-photo>Subir foto</button>`}</section>
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

function openLocationDialog(data,current={},{reload,refreshLists}){
  let mapController=null;
  let municipalities=[];
  let lastSelectedPlace=Number.isFinite(Number(current?.latitude))&&Number.isFinite(Number(current?.longitude))?current:null;
  let selectedSource=current?.source||"DIVIPOLA_STRUCTURED_ADDRESS";
  let addressManuallyEdited=Boolean(current?.address);
  const departments=colombianDepartments();
  const ref=modal({title:"Ubicar lugar de entrega",confirmLabel:"Guardar ubicación",size:"wide",body:`
    <div class="shipping-dialog-intro location-intro"><strong>Dirección guiada y verificada</strong><p>Selecciona primero el departamento y el municipio. Después completa la nomenclatura; el ERP construirá la dirección, buscará el punto y lo marcará en el mapa.</p></div>
    <section class="address-wizard-card">
      <header class="address-wizard-head"><span>1</span><div><strong>Selecciona el territorio</strong><p>Las listas usan la codificación DIVIPOLA de Colombia para evitar municipios escritos de forma incorrecta.</p></div></header>
      <div class="maps-address-grid territory-grid">
        <div class="field"><label>País</label><input class="control" value="Colombia" readonly></div>
        <div class="field"><label>Departamento *</label><select class="control" name="department" required><option value="">Selecciona un departamento</option></select></div>
        <div class="field full"><label>Municipio, distrito o ciudad *</label><select class="control" name="municipality" required disabled><option value="">Primero selecciona el departamento</option></select><small class="field-help" data-municipality-help>La lista se habilitará al escoger el departamento.</small></div>
      </div>
    </section>
    <section class="address-wizard-card">
      <header class="address-wizard-head"><span>2</span><div><strong>Completa el tipo de dirección</strong><p>Escoge la forma que mejor describa el destino. Solo aparecerán los campos necesarios.</p></div></header>
      <div class="field address-mode-field"><label>Tipo de ubicación *</label><select class="control" name="addressMode"><option value="URBAN">Dirección urbana</option><option value="RURAL">Vereda, corregimiento o zona rural</option><option value="LANDMARK">Empresa, sede o lugar conocido</option></select></div>
      <div class="address-mode-panel" data-address-panel="URBAN">
        <div class="maps-address-grid address-components-grid">
          <div class="field"><label>Tipo de vía *</label><select class="control" name="roadType"><option>Calle</option><option>Carrera</option><option>Avenida</option><option>Avenida Calle</option><option>Avenida Carrera</option><option>Diagonal</option><option>Transversal</option><option>Circular</option><option>Autopista</option><option>Vía</option><option>Kilómetro</option><option>Otro</option></select></div>
          <div class="field"><label>Número o nombre de vía *</label><input class="control" name="mainRoad" placeholder="Ejemplo: 40, 5A o Panamericana"></div>
          <div class="field"><label>Vía que cruza / primer número</label><input class="control" name="crossRoad" placeholder="Ejemplo: 28"></div>
          <div class="field"><label>Placa / segundo número</label><input class="control" name="propertyNumber" placeholder="Ejemplo: 15"></div>
          <div class="field"><label>Barrio o urbanización</label><input class="control" name="neighborhood" placeholder="Ejemplo: El Centro"></div>
          <div class="field"><label>Complemento</label><input class="control" name="complement" placeholder="Bodega 3, local 201, entrada norte..."></div>
        </div>
      </div>
      <div class="address-mode-panel" data-address-panel="RURAL" hidden>
        <div class="maps-address-grid address-components-grid">
          <div class="field"><label>Tipo de zona *</label><select class="control" name="ruralType"><option>Vereda</option><option>Corregimiento</option><option>Inspección</option><option>Sector</option><option>Vía</option><option>Kilómetro</option></select></div>
          <div class="field"><label>Nombre de la zona *</label><input class="control" name="ruralName" placeholder="Ejemplo: Vereda La Esperanza"></div>
          <div class="field"><label>Finca, predio o establecimiento</label><input class="control" name="propertyName" placeholder="Ejemplo: Finca El Porvenir"></div>
          <div class="field"><label>Referencia para llegar</label><input class="control" name="ruralReference" placeholder="Ejemplo: 500 m después del puente"></div>
        </div>
      </div>
      <div class="address-mode-panel" data-address-panel="LANDMARK" hidden>
        <div class="maps-address-grid address-components-grid">
          <div class="field full"><label>Nombre de empresa, sede o lugar *</label><input class="control" name="landmarkName" placeholder="Ejemplo: Parque Industrial Tuluá"></div>
          <div class="field full"><label>Detalle adicional</label><input class="control" name="landmarkDetail" placeholder="Portería, bloque, local, entrada o punto de referencia"></div>
        </div>
      </div>
      <div class="address-built-box">
        <div><label for="shipping-built-address">Dirección que se buscará *</label><small>Se construye automáticamente. Puedes corregir letras, BIS, norte, sur o cualquier detalle antes de buscar.</small></div>
        <textarea id="shipping-built-address" class="control" name="address" rows="2" required placeholder="La dirección aparecerá aquí">${fmt.escape(current.address||"")}</textarea>
        <button type="button" class="btn btn-ghost btn-compact" data-rebuild-address>Reconstruir desde los campos</button>
      </div>
      <div class="maps-search-actions">
        <button type="button" class="btn btn-primary btn-large" data-search-address>Buscar y ubicar en el mapa</button>
        <button type="button" class="btn btn-ghost btn-large" data-capture-location>Usar ubicación actual</button>
      </div>
    </section>
    <div class="location-status" data-location-status aria-live="polite">Selecciona el departamento y el municipio para comenzar.</div>
    <div class="maps-search-results" data-location-results hidden></div>
    <section class="maps-workspace">
      <div class="erp-location-map" data-location-map aria-label="Mapa de ubicación del pedido"><div class="map-loading">Preparando mapa…</div></div>
      <aside class="maps-location-summary">
        <span class="maps-summary-kicker">Punto seleccionado</span>
        <strong data-selected-place>${fmt.escape(current.placeLabel||current.address||"Aún no ubicado")}</strong>
        <p data-selected-address>${fmt.escape(current.address||"Busca la dirección para marcarla en el mapa.")}</p>
        <dl>
          <div><dt>Latitud</dt><dd data-map-lat>${fmt.escape(current.latitude??"—")}</dd></div>
          <div><dt>Longitud</dt><dd data-map-lon>${fmt.escape(current.longitude??"—")}</dd></div>
          <div><dt>Altitud</dt><dd data-map-alt>${current.altitude==null?"—":`${fmt.number(current.altitude,1)} m`}</dd></div>
        </dl>
        <small>Confirma el marcador. Puedes tocar el mapa o arrastrarlo hasta la entrada exacta.</small>
      </aside>
    </section>
    <div class="form-grid location-form maps-final-fields">
      <div class="field full"><label>Lugar o punto de entrega *</label><input class="control" name="placeLabel" value="${fmt.escape(current.placeLabel||"")}" placeholder="Ejemplo: portería principal, bodega 4 o recepción" required></div>
      <div class="field"><label>Latitud</label><input class="control coordinates-control" name="latitude" type="number" step="any" value="${fmt.escape(current.latitude??"")}" readonly required></div>
      <div class="field"><label>Longitud</label><input class="control coordinates-control" name="longitude" type="number" step="any" value="${fmt.escape(current.longitude??"")}" readonly required></div>
      <div class="field"><label>Altitud estimada (m)</label><input class="control coordinates-control" name="altitude" type="number" step="any" value="${fmt.escape(current.altitude??"")}" readonly></div>
      <div class="field"><label>Precisión GPS (m)</label><input class="control coordinates-control" name="accuracy" type="number" step="any" value="${fmt.escape(current.accuracy??"")}" readonly></div>
    </div>
    <p class="location-attribution">Municipios basados en DIVIPOLA. Mapa y geocodificación basados en OpenStreetMap. Verifica siempre el punto antes de guardar.</p>`,onConfirm:async dialog=>{
      const value=name=>dialog.querySelector(`[name="${name}"]`)?.value.trim()||"";
      const latitude=Number(value("latitude")),longitude=Number(value("longitude"));
      if(!value("department"))throw new Error("Selecciona el departamento.");
      if(!value("municipality"))throw new Error("Selecciona el municipio, distrito o ciudad.");
      if(!value("address"))throw new Error("Completa la dirección que se buscará.");
      if(!Number.isFinite(latitude)||!Number.isFinite(longitude))throw new Error("Primero debes ubicar el destino en el mapa.");
      await api.saveShippingLocation(data.order.id,{placeLabel:value("placeLabel"),municipality:value("municipality"),department:value("department"),address:value("address"),latitude,longitude,altitude:value("altitude")===""?null:Number(value("altitude")),accuracy:value("accuracy")===""?null:Number(value("accuracy")),source:selectedSource});
      mapController?.destroy();
      toast("Ubicación guardada.","success");refreshLists?.();setTimeout(()=>reload?.(),80);
    }});

  const root=ref.root;
  const status=root.querySelector("[data-location-status]");
  const resultsHost=root.querySelector("[data-location-results]");
  const mapHost=root.querySelector("[data-location-map]");
  const control=name=>root.querySelector(`[name="${name}"]`);
  const text=name=>control(name)?.value.trim()||"";
  const departmentSelect=control("department");
  const municipalitySelect=control("municipality");
  const modeSelect=control("addressMode");
  const addressField=control("address");
  const municipalityHelp=root.querySelector("[data-municipality-help]");

  const setSummary=place=>{
    root.querySelector("[data-selected-place]").textContent=place.placeLabel||text("placeLabel")||text("municipality")||"Punto seleccionado";
    root.querySelector("[data-selected-address]").textContent=place.address||text("address")||"Dirección seleccionada";
    root.querySelector("[data-map-lat]").textContent=Number.isFinite(Number(place.latitude))?Number(place.latitude).toFixed(6):"—";
    root.querySelector("[data-map-lon]").textContent=Number.isFinite(Number(place.longitude))?Number(place.longitude).toFixed(6):"—";
    root.querySelector("[data-map-alt]").textContent=place.altitude==null?"—":`${fmt.number(place.altitude,1)} m`;
  };

  const generatedAddress=()=>buildColombianAddress({
    mode:text("addressMode"),roadType:text("roadType"),mainRoad:text("mainRoad"),crossRoad:text("crossRoad"),propertyNumber:text("propertyNumber"),neighborhood:text("neighborhood"),complement:text("complement"),ruralType:text("ruralType"),ruralName:text("ruralName"),propertyName:text("propertyName"),ruralReference:text("ruralReference"),landmarkName:text("landmarkName"),landmarkDetail:text("landmarkDetail")
  });
  const syncAddress=(force=false)=>{
    if(addressManuallyEdited&&!force)return;
    const generated=generatedAddress();
    if(generated)addressField.value=generated;
    addressManuallyEdited=false;
  };
  const showAddressMode=()=>{
    const mode=text("addressMode")||"URBAN";
    root.querySelectorAll("[data-address-panel]").forEach(panel=>panel.hidden=panel.dataset.addressPanel!==mode);
    syncAddress();
  };

  const populateDepartments=()=>{
    departmentSelect.innerHTML=`<option value="">Selecciona un departamento</option>${departments.map(item=>`<option value="${fmt.escape(item.name)}" data-code="${item.code}">${fmt.escape(item.name)}</option>`).join("")}`;
    const currentDepartment=findDepartmentByName(current.department);
    if(currentDepartment)departmentSelect.value=currentDepartment.name;
  };

  const selectedDepartmentCode=()=>departmentSelect.selectedOptions[0]?.dataset.code||"";
  const selectedMunicipality=()=>municipalities.find(item=>item.code===municipalitySelect.selectedOptions[0]?.dataset.code)||null;

  const loadMunicipalities=async(preferredName="")=>{
    const departmentCode=selectedDepartmentCode();
    municipalities=[];
    municipalitySelect.disabled=true;
    municipalitySelect.innerHTML='<option value="">Cargando municipios…</option>';
    municipalityHelp.textContent="Consultando la lista oficial del departamento seleccionado…";
    if(!departmentCode){municipalitySelect.innerHTML='<option value="">Primero selecciona el departamento</option>';municipalityHelp.textContent="La lista se habilitará al escoger el departamento.";return null;}
    try{
      municipalities=await colombianMunicipalities(departmentCode);
      municipalitySelect.innerHTML=`<option value="">Selecciona municipio, distrito o ciudad</option>${municipalities.map(item=>`<option value="${fmt.escape(item.name)}" data-code="${fmt.escape(item.code)}" data-lat="${item.latitude??""}" data-lon="${item.longitude??""}">${fmt.escape(item.name)}${item.type&&item.type!=="Municipio"?` · ${fmt.escape(item.type)}`:""}</option>`).join("")}`;
      municipalitySelect.disabled=false;
      const match=findMunicipalityByName(municipalities,preferredName);
      if(match)municipalitySelect.value=match.name;
      municipalityHelp.textContent=`${municipalities.length} territorios disponibles. Selecciona el que aparece en el pedido.`;
      return match;
    }catch(error){
      municipalitySelect.innerHTML='<option value="">No fue posible cargar la lista</option>';
      municipalityHelp.innerHTML=`${fmt.escape(error.message)} <button type="button" class="location-inline-link" data-retry-municipalities>Reintentar</button>`;
      municipalityHelp.querySelector("[data-retry-municipalities]")?.addEventListener("click",()=>loadMunicipalities(preferredName));
      throw error;
    }
  };

  const selectTerritoryFromPlace=async place=>{
    const department=findDepartmentByName(place.department);
    if(!department)return false;
    departmentSelect.value=department.name;
    const municipality=await loadMunicipalities(place.municipality);
    if(municipality){municipalitySelect.value=municipality.name;return true;}
    return false;
  };

  const applyPlace=(place,{moveMap=true,source="DIVIPOLA_STRUCTURED_ADDRESS",preserveTypedAddress=false}={})=>{
    selectedSource=source;
    lastSelectedPlace=place;
    for(const key of ["latitude","longitude","altitude","accuracy"]){const field=control(key);if(field&&place[key]!=null)field.value=place[key];}
    if(!preserveTypedAddress&&place.address){addressField.value=place.address;addressManuallyEdited=true;}
    if(!text("placeLabel"))control("placeLabel").value=text("addressMode")==="LANDMARK"?(text("landmarkName")||`Entrega en ${text("municipality")}`):`Entrega en ${text("municipality")}`;
    setSummary({...place,placeLabel:text("placeLabel"),address:text("address")});
    if(moveMap&&mapController)mapController.setPoint(place.latitude,place.longitude,{zoom:17});
  };

  const selectResult=async(place,index)=>{
    status.innerHTML=loading("Ubicando dirección en el mapa…");
    if(place.altitude==null)place.altitude=await elevationFor(place.latitude,place.longitude);
    applyPlace(place,{source:"DIVIPOLA_STRUCTURED_ADDRESS"});
    resultsHost.querySelectorAll("[data-location-result]").forEach((button,buttonIndex)=>button.classList.toggle("selected",buttonIndex===index));
    status.textContent="Dirección localizada. Verifica la entrada exacta y ajusta el marcador si es necesario.";
  };

  const renderResults=results=>{
    resultsHost.hidden=false;
    resultsHost.innerHTML=`<div class="maps-results-head"><strong>${results.length===1?"Dirección encontrada":"Selecciona la coincidencia correcta"}</strong><span>${results.length} resultado${results.length===1?"":"s"}</span></div>${results.map((place,index)=>`<button type="button" class="maps-result-option ${index===0?"selected":""}" data-location-result="${index}"><span>${index+1}</span><div><strong>${fmt.escape(text("municipality"))}</strong><small>${fmt.escape(place.displayName||place.address)}</small></div></button>`).join("")}`;
    resultsHost.querySelectorAll("[data-location-result]").forEach(button=>button.addEventListener("click",()=>selectResult(results[Number(button.dataset.locationResult)],Number(button.dataset.locationResult))));
  };

  const resolveMapPoint=async({latitude,longitude,reason})=>{
    status.innerHTML=loading(reason==="MARKER_DRAG"?"Ajustando marcador…":"Consultando el punto seleccionado…");
    try{
      const [addressInfo,altitude]=await Promise.all([reverseGeocode(latitude,longitude),elevationFor(latitude,longitude)]);
      applyPlace({...addressInfo,latitude,longitude,altitude,accuracy:null},{moveMap:false,source:reason});
      resultsHost.hidden=true;
      status.textContent="Punto ajustado manualmente. Confirma la dirección y el lugar de entrega.";
    }catch(error){
      applyPlace({latitude,longitude,altitude:null,accuracy:null},{moveMap:false,source:reason,preserveTypedAddress:true});
      status.textContent="El punto quedó marcado, pero no se pudo normalizar la dirección. Conservamos la dirección construida.";
    }
  };

  populateDepartments();
  modeSelect.value=current.addressMode||"URBAN";
  showAddressMode();
  if(current.department)loadMunicipalities(current.municipality).catch(()=>{});

  createLocationMap(mapHost,{latitude:current.latitude,longitude:current.longitude,onPointChange:resolveMapPoint})
    .then(controller=>{mapController=controller;mapHost.querySelector(".map-loading")?.remove();if(lastSelectedPlace&&Number.isFinite(Number(lastSelectedPlace.latitude))&&Number.isFinite(Number(lastSelectedPlace.longitude))){controller.setPoint(lastSelectedPlace.latitude,lastSelectedPlace.longitude,{zoom:17});setSummary(lastSelectedPlace);}})
    .catch(error=>{mapHost.innerHTML=`<div class="map-unavailable"><strong>Mapa no disponible</strong><p>${fmt.escape(error.message)}</p></div>`;});

  departmentSelect.addEventListener("change",async()=>{
    control("latitude").value="";control("longitude").value="";resultsHost.hidden=true;
    status.textContent=departmentSelect.value?"Cargando municipios del departamento…":"Selecciona el departamento.";
    try{await loadMunicipalities();status.textContent="Ahora selecciona el municipio, distrito o ciudad.";}catch(error){status.textContent=error.message;}
  });
  municipalitySelect.addEventListener("change",()=>{
    const municipality=selectedMunicipality();
    if(municipality&&mapController&&Number.isFinite(municipality.latitude)&&Number.isFinite(municipality.longitude))mapController.setView(municipality.latitude,municipality.longitude,13);
    status.textContent=municipality?"Municipio seleccionado. Completa la nomenclatura o el lugar de entrega.":"Selecciona el municipio, distrito o ciudad.";
  });
  modeSelect.addEventListener("change",()=>{addressManuallyEdited=false;showAddressMode();});
  root.querySelectorAll("[data-address-panel] input,[data-address-panel] select").forEach(field=>field.addEventListener("input",()=>{addressManuallyEdited=false;syncAddress();}));
  addressField.addEventListener("input",()=>{addressManuallyEdited=true;});
  root.querySelector("[data-rebuild-address]")?.addEventListener("click",()=>{addressManuallyEdited=false;syncAddress(true);addressField.focus();});

  root.querySelector("[data-search-address]")?.addEventListener("click",async button=>{
    button.disabled=true;resultsHost.hidden=true;syncAddress();status.innerHTML=loading("Buscando la dirección dentro del municipio seleccionado…");
    try{
      if(!text("department"))throw new Error("Selecciona el departamento.");
      if(!text("municipality"))throw new Error("Selecciona el municipio, distrito o ciudad.");
      if(!text("address"))throw new Error("Completa los datos de la dirección.");
      const results=await geocodeAddress({department:text("department"),municipality:text("municipality"),address:text("address"),mode:text("addressMode")});
      renderResults(results);await selectResult(results[0],0);
    }catch(error){
      const municipality=selectedMunicipality();
      if(municipality&&mapController&&Number.isFinite(municipality.latitude)&&Number.isFinite(municipality.longitude)){
        mapController.setView(municipality.latitude,municipality.longitude,14);
        status.textContent=`${error.message} El mapa quedó centrado en ${municipality.name}; toca el punto exacto para marcarlo.`;
      }else status.textContent=error.message;
      toast(error.message,"error",7000);
    }finally{button.disabled=false;}
  });

  root.querySelector("[data-capture-location]")?.addEventListener("click",async button=>{
    button.disabled=true;resultsHost.hidden=true;status.innerHTML=loading("Obteniendo ubicación actual…");
    try{
      const place=await locateCurrentPlace();
      try{await selectTerritoryFromPlace(place);}catch{}
      applyPlace(place,{source:"DEVICE_GPS"});
      status.textContent=place.geocodingWarning?`${place.geocodingWarning} Verifica las listas y la dirección.`:`Ubicación actual obtenida con precisión aproximada de ${Math.round(place.accuracy||0)} m.`;
    }catch(error){status.textContent=error.message;toast(error.message,"error",7000);}finally{button.disabled=false;}
  });

  root.querySelectorAll("[data-close]").forEach(button=>button.addEventListener("click",()=>mapController?.destroy(),{once:true}));
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
function locationSummary(place){return `<div class="shipping-location-card"><div><small>Lugar</small><strong>${fmt.escape(place.placeLabel||place.municipality||"Lugar de entrega")}</strong><p>${fmt.escape(place.address||"Dirección registrada")}</p></div><dl><div><dt>Municipio</dt><dd>${fmt.escape(place.municipality||"—")}</dd></div><div><dt>Latitud</dt><dd>${fmt.escape(place.latitude??"—")}</dd></div><div><dt>Longitud</dt><dd>${fmt.escape(place.longitude??"—")}</dd></div><div><dt>Altitud</dt><dd>${place.altitude==null?"No disponible":`${fmt.number(place.altitude,1)} m`}</dd></div></dl></div>`}
function dispatchRecap(delivery,place){return `<section class="dispatch-recap"><header><div><span>Envío en cierre</span><h4>${fmt.escape(delivery?.tracking_number||"Guía registrada")}</h4></div>${statusBadge(delivery?.status||"IN_TRANSIT")}</header><div class="dispatch-recap-grid"><div><small>Transportadora</small><strong>${fmt.escape(delivery?.carrier||"—")}</strong></div><div><small>Municipio</small><strong>${fmt.escape(place.municipality||"—")}</strong></div><div><small>Dirección</small><strong>${fmt.escape(place.address||"—")}</strong></div><div><small>Salida</small><strong>${fmt.date(delivery?.dispatched_at)}</strong></div></div></section>`}
function shippingSummary(data){
  const delivery=latestDelivery(data),place=destination(delivery),trace=data.deliveryTimeTrace||{};
  const traceCards=[
    ["Gestión de despacho",trace.dispatchBusinessSeconds,"Tiempo productivo"],
    ["Espera y tránsito",trace.transitBusinessSeconds,"Desde salida hasta entrega"],
    ["Cierre de entrega",trace.closureBusinessSeconds,"Validación y evidencia"],
    ["Tiempo muerto",trace.deadBusinessSeconds??trace.deadTimeSeconds,"Tiempo laboral sin gestión"]
  ];
  return `<div class="simple-detail-sections"><section><h4>Información del envío</h4><div class="detail-grid"><div class="info-box"><label>Ruta</label><strong>${fmt.escape(fmt.route(data.order.delivery_route_code))}</strong></div><div class="info-box"><label>Guía</label><strong>${fmt.escape(delivery?.tracking_number||"—")}</strong></div><div class="info-box"><label>Transportadora</label><strong>${fmt.escape(delivery?.carrier||"—")}</strong></div><div class="info-box"><label>Estado</label><strong>${fmt.escape(fmt.label(delivery?.status||data.order.status))}</strong></div><div class="info-box"><label>Municipio</label><strong>${fmt.escape(place.municipality||"—")}</strong></div><div class="info-box"><label>Dirección</label><strong>${fmt.escape(place.address||"—")}</strong></div></div></section><section><h4>Resumen de tiempos laborales</h4><div class="shipping-trace-metrics">${traceCards.map(([label,value,caption])=>`<article><small>${fmt.escape(label)}</small><strong>${fmt.hours(Number(value||0))}</strong><span>${fmt.escape(caption)}</span></article>`).join("")}</div><div class="shipping-time-list">${(data.tasks||[]).map(task=>`<article><span>${fmt.escape(fmt.step(task.step_code))}</span><strong>${fmt.hours(task.business_seconds)}</strong><small>Transcurrido: ${fmt.hours(task.raw_seconds)}</small></article>`).join("")}</div></section></div>`
}
