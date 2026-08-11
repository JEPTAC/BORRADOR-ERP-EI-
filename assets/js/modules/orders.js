import {api} from "../services/api.js";
import {state,can} from "../core/state.js";
import {fmt,statusBadge,priorityBadge} from "../core/format.js";
import {wizard,modal,toast,serializeForm,paginationHtml,empty,loading,actionCards,guide} from "../core/ui.js";
import {workspaceIntro,summaryItem,choice,simpleStatus} from "../core/guided.js";
import {uploadOrderFile} from "../services/drive.js";
import {colombianDepartments,colombianMunicipalities} from "../services/location.js";
import {materialPickerHtml,bindMaterialPicker,readMaterialPicker} from "../services/materials.js";
import {isOrderReceptionStep,renderOrderReception} from "./receiving-order.js";
import {isFinancialFlowStep,renderFinancialFlow} from "./financial-flow.js";
import {isPickingFlow,renderPickingFlow} from "./picking-flow.js";
import {isCuttingFlow,renderCuttingOrder} from "./cutting-flow.js";
import {isShippingFlow,renderShippingFlow} from "./shipping-flow.js";
import {parallelWorkFooter} from "./active-work.js";
import {mountOrderCancellationAction} from "./order-cancellation.js";

let currentList={filters:{page:1,pageSize:50,assignment:"ALL",includeHistory:true},root:null,data:null};

export async function renderOrders(root,{moduleId="orders",params={}}={}){
  currentList.root=root;
  currentList.filters={...currentList.filters,...params,page:Number(params.page||1)};
  if(params.history==="0")currentList.filters.includeHistory=false;
  const canCreate=can("orders","canCreate")||can("sales","canCreate");
  const cards=[
    ...(canCreate?[{id:"create-order",title:"Crear pedido",description:"Registra la información esencial y los materiales en tres pasos.",icon:"＋",tone:"accent"}]:[]),
    {id:"show-all-orders",title:"Buscar pedidos",description:"Encuentra operación activa o historial en una sola vista.",icon:"⌕",tone:"primary"},
    {id:"show-my-orders",title:"Mis pedidos",description:"Muestra lo que requiere tu atención.",icon:"✓",tone:"success"},
    {id:"orders-help",title:"Ayuda rápida",description:"Aprende a gestionar un pedido desde una sola ventana.",icon:"?"}
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
      </div>
      <div class="selection-hint"><strong>Lista de pedidos</strong><span>Usa los filtros y abre el pedido desde la acción de la derecha. La lista está pensada para operar alto volumen sin perder contexto.</span></div>
      <div id="orders-result">${loading("Cargando pedidos…")}</div>
    </section>`;

  root.querySelector("#create-order")?.addEventListener("click",openCreateOrder);
  root.querySelector("#show-all-orders").onclick=()=>{setFilters({assignment:"ALL",status:"",includeHistory:true});loadOrders(1)};
  root.querySelector("#show-my-orders").onclick=()=>{setFilters({assignment:"MINE",status:"",includeHistory:false});loadOrders(1)};
    root.querySelector("#orders-help").onclick=()=>guide({title:"Cómo gestionar pedidos",description:"Todo el trabajo se realiza desde una lista y una sola ventana guiada.",items:[{title:"Busca el pedido",detail:"Usa el número, cliente o filtros de la operación."},{title:"Usa Abrir / Continuar",detail:"La acción está siempre a la derecha de la fila."},{title:"Sigue el paso activo",detail:"El popup muestra únicamente la decisión actual y oculta lo que todavía no corresponde."},{title:"Confirma y continúa",detail:"El siguiente paso se habilita cuando la información necesaria está completa."}]});
  root.querySelector("#apply-filters").onclick=()=>loadOrders(1);
  root.querySelector("#f-search").onkeydown=event=>{if(event.key==="Enter")loadOrders(1)};
  root.querySelector("#export-list").onclick=exportCurrent;
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
  window.__erpOrderListRefresh=()=>loadOrders(currentList.filters.page||1);
  renderOrderResults();
}

function renderOrderResults(){
  const root=currentList.root;
  const result=root?.querySelector("#orders-result");
  const data=currentList.data;
  if(!result||!data)return;
  const content=data.items.length?ordersTable(data.items):empty("No se encontraron pedidos","Ajusta los filtros o crea un pedido nuevo.");
  result.innerHTML=`${content}${data.items.length?paginationHtml(data.pagination):""}`;
  result.querySelectorAll("[data-order]").forEach(element=>element.onclick=()=>openOrder(element.dataset.order));
  result.querySelectorAll("[data-page]").forEach(element=>element.onclick=()=>loadOrders(Number(element.dataset.page)));
}

function ordersTable(rows){
  return `<div class="erp-work-list orders-master-list">${rows.map(order=>{
    const status=String(order.status||"").toUpperCase();
    const action=status==="IN_PROGRESS"?"Continuar":status==="ASSIGNED"||status==="QUEUED"?"Abrir / iniciar":"Abrir";
    return `<article class="erp-work-row orders-master-row"><div class="erp-work-main"><span class="erp-work-eyebrow">${fmt.escape(fmt.step(order.stepName||order.currentStep))}</span><strong>${fmt.escape(order.orderNumber)}</strong><small>${fmt.escape(order.clientName)} · ${fmt.escape(fmt.label(order.orderType))} · ${fmt.escape(fmt.payment(order.paymentCondition))}</small>${order.fulfillmentStatus==="PARTIAL"||order.partialLabel?`<em class="order-partial-tag">Pedido parcial · ${fmt.number(order.pendingItemCount||0)} pendiente(s)</em>`:""}</div><div class="erp-work-meta"><span><small>Estado</small><b>${statusBadge(order.status)}</b></span><span><small>Responsable</small><b>${fmt.escape(order.assigneeName||"En cola")}</b></span><span><small>Tiempo</small><b>${fmt.hours(order.ageBusinessSeconds)}</b></span><span><small>Ruta</small><b>${fmt.escape(fmt.route(order.route))}</b></span><span><small>Actualizado</small><b>${fmt.date(order.updatedAt)}</b></span></div><div class="erp-work-status">${priorityBadge(order.priority)}${order.slaExceeded?'<small class="danger">Plazo excedido</small>':""}</div><button type="button" class="btn btn-primary erp-work-action" data-order="${fmt.escape(order.id)}">${action}</button></article>`;
  }).join("")}</div>`;
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
  const types=[{code:"PVE",name:"PVE"},{code:"PVC",name:"PVC"},{code:"PVN",name:"PVN"},{code:"PVP",name:"PVP"}],payments=state.catalogs.paymentConditions||[],routes=state.catalogs.deliveryRoutes||[];
  const departments=colombianDepartments();
  const departmentOptions=`<option value="">Selecciona el departamento</option>${departments.map(item=>`<option value="${fmt.escape(item.code)}">${fmt.escape(item.name)}</option>`).join("")}`;
  const assistant=wizard({
    title:"Crear pedido",
    subtitle:"Registra el pedido, la dirección obligatoria y los materiales en tres pasos.",
    finishLabel:"Crear pedido",
    steps:[
      {title:"Pedido, cliente y entrega",description:"La dirección se registra aquí y Logística solo agregará la guía.",content:`
        <div class="form-grid">
          <div class="field"><label>Número de pedido *</label><input class="control" name="orderNumber" placeholder="Ejemplo: PVC-5001" required autofocus></div>
          <div class="field"><label>Cliente *</label><input class="control" name="clientName" required></div>
          <div class="field"><label>Tipo *</label>${formSelect("orderType",types,"code","name",types[0]?.code)}</div>
          <div class="field"><label>Condición de pago *</label>${formSelect("paymentCondition",payments,"code","name",payments[0]?.code)}</div>
          <div class="field full order-routing-conditions" data-routing-conditions>
            <div class="conditional-routing-card" data-credit-arrears hidden><label><input type="checkbox" name="hasCreditArrears"> <span><strong>Cliente con mora en crédito</strong><small>Solo al marcarlo, los pedidos PVC o PVP pasarán primero por Cartera.</small></span></label></div>
            <div class="conditional-routing-card" data-cash-hold hidden><label><input type="checkbox" name="heldByCashier"> <span><strong>Pedido retenido por Caja</strong><small>Solo al marcarlo, el pedido PVN pasará primero por Caja.</small></span></label></div>
            <div class="conditional-routing-direct" data-direct-reception><strong>Ruta inicial: Recepción de pedidos</strong><small>Si no existe una condición excepcional, el pedido no pasa por Cartera ni Caja.</small></div>
          </div>
          <div class="field"><label>Modalidad de entrega *</label>${formSelect("deliveryRoute",routes,"code","name",routes[0]?.code)}</div>
          <div class="field"><label>Prioridad *</label>${formSelect("priority",["LOW","MEDIUM","HIGH","URGENT","CRITICAL"])}</div>
        </div>
        <section class="sales-address-card">
          <header class="sales-address-head"><span>Dirección</span><div><strong>Lugar de entrega obligatorio</strong><p>Selecciona el departamento y el municipio. Después escribe la dirección exactamente como debe verla Logística.</p></div></header>
          <div class="sales-address-grid">
            <div class="field"><label>País</label><input class="control" value="Colombia" readonly aria-readonly="true"><input type="hidden" name="clientCountry" value="Colombia"></div>
            <div class="field"><label>Departamento *</label><select class="control" name="clientDepartmentCode" required>${departmentOptions}</select><input type="hidden" name="clientDepartment"></div>
            <div class="field"><label>Municipio o ciudad *</label><select class="control" name="clientCity" required disabled><option value="">Primero selecciona el departamento</option></select><small class="field-help" data-municipality-help>La lista se cargará según el departamento.</small></div>
            <div class="field full"><label>Dirección completa *</label><input class="control" name="clientAddress" placeholder="Ejemplo: Carrera 40 # 28-15, Bodega 3" required autocomplete="street-address"><small class="field-help">Incluye vía, número, barrio, vereda, bodega, local o referencia cuando aplique.</small></div>
          </div>
        </section>
        <details class="simple-details"><summary>Datos adicionales del cliente</summary><div class="form-grid" style="padding:14px"><div class="field"><label>NIT o documento</label><input class="control" name="clientDocument"></div><div class="field"><label>Teléfono</label><input class="control" name="clientPhone"></div><div class="field"><label>Referencia externa</label><input class="control" name="externalReference"></div><div class="field"><label>Fecha solicitada</label><input class="control" name="requestedDeliveryDate" type="date"></div></div></details>`,validate:({root})=>{
            const department=root.querySelector('[name="clientDepartment"]')?.value.trim();
            const city=root.querySelector('[name="clientCity"]')?.value.trim();
            const address=root.querySelector('[name="clientAddress"]')?.value.trim();
            if(!department)throw new Error("Selecciona el departamento de entrega.");
            if(!city)throw new Error("Selecciona el municipio o ciudad de entrega.");
            if(!address||address.length<5)throw new Error("Escribe una dirección de entrega completa.");
            return true;
          }},
      {title:"Materiales",description:"Ventas define qué se vendió y cuánto. Logística decidirá después de qué lote, ubicación o carreto sale.",content:`
        <section class="sales-materials-intro">
          <div class="sales-materials-intro-main"><span class="official-material-mark">SIESA</span><div><strong>Busca, selecciona y registra la necesidad</strong><p>No escribas referencias, nombres, lotes ni ubicaciones. El ERP usa el maestro oficial y reserva lógicamente la cantidad al crear el pedido.</p></div></div>
          <label class="sales-purchase-toggle"><input type="checkbox" name="requiresPurchase"><span><strong>Requiere compra</strong><small>Úsalo cuando comercialmente el pedido dependa de abastecimiento. PVE conserva su ruta por Compras.</small></span></label>
        </section>
        <div class="items-wizard-head"><div><strong>Materiales vendidos</strong><p>Para materiales en metros puedes registrar entrega directa o varias medidas de corte. El total se calcula automáticamente.</p></div><button class="btn btn-primary" type="button" id="add-item">＋ Agregar material</button></div>
        <div class="sales-material-list" id="items-editor"></div>`,validate:({root})=>{
          const cards=[...root.querySelectorAll("[data-sales-material]")];
          if(!cards.length)throw new Error("Agrega al menos un material.");
          cards.forEach((card,index)=>validateSalesMaterialCard(card,index));
          return true;
        }},
      {title:"Confirmar",description:"Revisa el destino, el total de materiales y si existen cortes antes de crear.",content:`<div id="order-review" class="wizard-summary"></div><section class="sales-reservation-confirm"><span>RESERVA ERP</span><div><strong>Ventas no asigna lotes</strong><p>Al crear el pedido, el ERP reservará la necesidad contra la disponibilidad comercial. Alistamiento y Corte definirán el origen físico real y lo dejarán trazado.</p></div></section>`,onEnter:({root,form})=>{
        const d=serializeForm(form),items=collectSalesItems(root),cards=[...root.querySelectorAll("[data-sales-material]")];
        const cutLines=items.filter(item=>item.requiresCut).length;
        const shortageCards=cards.filter(card=>Number(card.dataset.shortage||0)>0).length;
        root.querySelector("#order-review").innerHTML=[summaryItem("Pedido",d.orderNumber),summaryItem("Cliente",d.clientName),summaryItem("Tipo",fmt.label(d.orderType)),summaryItem("Pago",fmt.payment(d.paymentCondition)),summaryItem("Entrega",fmt.route(d.deliveryRoute)),summaryItem("Destino",`${d.clientCity}, ${d.clientDepartment}`),summaryItem("Dirección",d.clientAddress),summaryItem("Materiales",String(cards.length)),summaryItem("Líneas operativas",String(items.length)),summaryItem("Cortes",cutLines?`${cutLines} línea(s) de corte`:"Sin cortes"),summaryItem("Disponibilidad",shortageCards?`${shortageCards} material(es) con faltante proyectado`:"Disponible según maestro actual"),summaryItem("Ruta inicial",initialRouteLabel(d))].join("");
      }}
    ],
    onFinish:async({root,data})=>{
      const items=collectSalesItems(root);
      const result=await api.createOrder({...data,requiresCut:items.some(item=>item.requiresCut),items});
      toast(`Pedido ${result.orderNumber} creado. Las cantidades quedaron reservadas lógicamente y el pedido fue enviado a ${fmt.step(result.currentStep)}.`,"success",7500);
      await loadOrders(1);setTimeout(()=>openOrder(result.orderId),180);
    }
  });
  const typeControl=assistant.root.querySelector('[name="orderType"]');
  const syncRoutingConditions=()=>{
    const type=typeControl?.value;
    const arrears=assistant.root.querySelector('[data-credit-arrears]');
    const cashHold=assistant.root.querySelector('[data-cash-hold]');
    const arrearsInput=assistant.root.querySelector('[name="hasCreditArrears"]');
    const cashInput=assistant.root.querySelector('[name="heldByCashier"]');
    const isCreditType=["PVC","PVP"].includes(type);
    const isPvn=type==="PVN";
    if(arrears)arrears.hidden=!isCreditType;
    if(cashHold)cashHold.hidden=!isPvn;
    if(!isCreditType&&arrearsInput)arrearsInput.checked=false;
    if(!isPvn&&cashInput)cashInput.checked=false;
    const direct=assistant.root.querySelector('[data-direct-reception]');
    const routing=initialRouteLabel({orderType:type,hasCreditArrears:Boolean(arrearsInput?.checked),heldByCashier:Boolean(cashInput?.checked)});
    if(direct){direct.querySelector("strong").textContent=`Ruta inicial: ${routing}`;direct.querySelector("small").textContent=routing==="Recepción de pedidos"?"El pedido no pasará por Cartera ni Caja.":"Esta condición excepcional define la primera cola del pedido.";}
  };
  typeControl?.addEventListener("change",syncRoutingConditions);
  assistant.root.querySelector('[name="hasCreditArrears"]')?.addEventListener("change",syncRoutingConditions);
  assistant.root.querySelector('[name="heldByCashier"]')?.addEventListener("change",syncRoutingConditions);
  syncRoutingConditions();

  const departmentSelect=assistant.root.querySelector('[name="clientDepartmentCode"]');
  const departmentName=assistant.root.querySelector('[name="clientDepartment"]');
  const municipalitySelect=assistant.root.querySelector('[name="clientCity"]');
  const municipalityHelp=assistant.root.querySelector('[data-municipality-help]');
  const loadMunicipalities=async()=>{
    const code=departmentSelect?.value||"";
    const selected=departments.find(item=>item.code===code);
    if(departmentName)departmentName.value=selected?.name||"";
    if(!municipalitySelect)return;
    municipalitySelect.disabled=true;
    municipalitySelect.innerHTML='<option value="">Cargando municipios…</option>';
    if(municipalityHelp)municipalityHelp.textContent="Consultando la lista oficial…";
    if(!code){municipalitySelect.innerHTML='<option value="">Primero selecciona el departamento</option>';if(municipalityHelp)municipalityHelp.textContent="La lista se cargará según el departamento.";return;}
    try{
      const rows=await colombianMunicipalities(code);
      municipalitySelect.innerHTML=`<option value="">Selecciona el municipio o ciudad</option>${rows.map(item=>`<option value="${fmt.escape(item.name)}">${fmt.escape(item.name)}${item.type&&item.type!=="Municipio"?` · ${fmt.escape(item.type)}`:""}</option>`).join("")}`;
      municipalitySelect.disabled=false;
      if(municipalityHelp)municipalityHelp.textContent=`${rows.length} municipios y distritos disponibles.`;
    }catch(error){
      municipalitySelect.innerHTML='<option value="">No fue posible cargar la lista</option>';
      if(municipalityHelp)municipalityHelp.innerHTML=`${fmt.escape(error.message)} <button type="button" class="location-inline-link" data-retry-municipalities>Reintentar</button>`;
      municipalityHelp?.querySelector('[data-retry-municipalities]')?.addEventListener("click",loadMunicipalities,{once:true});
    }
  };
  departmentSelect?.addEventListener("change",loadMunicipalities);

  const editor=assistant.root.querySelector("#items-editor");
  const add=()=>{
    const card=document.createElement("article");
    card.className="sales-material-card";
    card.dataset.salesMaterial="";
    card.dataset.mode="DIRECT";
    card.innerHTML=salesMaterialCardHtml();
    editor.append(card);
    bindSalesMaterialCard(card);
    renumberItems(editor);
  };
  assistant.root.querySelector("#add-item").onclick=add;
  add();
}

function salesMaterialCardHtml(){
  return `<div class="sales-material-index item-row-number"></div>
    <div class="sales-material-main">
      <div class="official-item-picker">${materialPickerHtml()}</div>
      <section class="sales-demand-builder" data-sales-demand hidden>
        <div class="sales-demand-mode" data-sales-mode-wrap hidden>
          <button type="button" class="sales-mode active" data-sales-mode="DIRECT"><span>Entrega directa</span><small>Empacar / enviar la cantidad solicitada</small></button>
          <button type="button" class="sales-mode" data-sales-mode="CUTS"><span>Cortes por medida</span><small>Define tramos y el ERP calcula el total</small></button>
        </div>
        <div class="sales-direct-demand" data-direct-demand>
          <label class="field"><span>Cantidad solicitada *</span><div class="sales-quantity-control"><input class="control" data-sales-quantity type="number" min="0.0001" step="any" placeholder="0"><b data-sales-unit>UND</b></div></label>
        </div>
        <div class="sales-cuts-demand" data-cuts-demand hidden>
          <div class="sales-cut-head"><div><strong>Plan de cortes</strong><p>Agrega una fila por medida. Puedes pedir varias piezas de la misma longitud.</p></div><button type="button" class="btn btn-ghost" data-add-cut>＋ Agregar medida</button></div>
          <div class="sales-cut-list" data-cut-list></div>
        </div>
        <div class="sales-demand-summary" data-demand-summary><div><small>Total solicitado</small><strong>0</strong></div><div><small>Disponible para venta</small><strong>—</strong></div><div><small>Después de reservar</small><strong>—</strong></div></div>
        <div class="sales-demand-status" data-demand-status></div>
      </section>
    </div>
    <button type="button" class="icon-btn sales-material-remove" data-remove-material title="Eliminar material">×</button>`;
}

function bindSalesMaterialCard(card){
  const picker=card.querySelector("[data-material-picker]");
  const demand=card.querySelector("[data-sales-demand]");
  const modeWrap=card.querySelector("[data-sales-mode-wrap]");
  const quantity=card.querySelector("[data-sales-quantity]");
  const unitLabel=card.querySelector("[data-sales-unit]");
  const cutList=card.querySelector("[data-cut-list]");
  const addCut=()=>{
    const row=document.createElement("div");row.className="sales-cut-row";
    row.innerHTML=`<label><span>Piezas</span><input class="control" data-cut-pieces type="number" min="1" step="1" value="1"></label><span class="sales-cut-x">×</span><label><span>Longitud</span><div class="sales-quantity-control"><input class="control" data-cut-length type="number" min="0.0001" step="any" placeholder="0"><b>m</b></div></label><strong data-cut-total>0 m</strong><button type="button" class="icon-btn" data-remove-cut aria-label="Eliminar medida">×</button>`;
    cutList.append(row);
    row.querySelector("[data-remove-cut]").onclick=()=>{row.remove();syncSalesMaterialDemand(card)};
    row.querySelectorAll("input").forEach(input=>input.addEventListener("input",()=>syncSalesMaterialDemand(card)));
    syncSalesMaterialDemand(card);
  };
  bindMaterialPicker(picker,{onChange:()=>{
    const material=readMaterialPicker(picker,false);
    if(!material.materialMasterId){demand.hidden=true;return}
    demand.hidden=false;unitLabel.textContent=material.unit||"UND";
    const metric=String(material.unit||"").toUpperCase()==="M";
    modeWrap.hidden=!metric;
    if(!metric){card.dataset.mode="DIRECT";card.querySelectorAll("[data-sales-mode]").forEach(button=>button.classList.toggle("active",button.dataset.salesMode==="DIRECT"));}
    syncSalesMaterialMode(card);
    syncSalesMaterialDemand(card);
  }});
  card.querySelectorAll("[data-sales-mode]").forEach(button=>button.addEventListener("click",()=>{
    card.dataset.mode=button.dataset.salesMode;
    card.querySelectorAll("[data-sales-mode]").forEach(item=>item.classList.toggle("active",item===button));
    if(card.dataset.mode==="CUTS"&&!cutList.children.length)addCut();
    syncSalesMaterialMode(card);syncSalesMaterialDemand(card);
  }));
  card.querySelector("[data-add-cut]").onclick=addCut;
  quantity.addEventListener("input",()=>syncSalesMaterialDemand(card));
  card.querySelector("[data-remove-material]").onclick=()=>{const editor=card.parentElement;card.remove();renumberItems(editor)};
}

function syncSalesMaterialMode(card){
  const mode=card.dataset.mode||"DIRECT";
  card.querySelector("[data-direct-demand]").hidden=mode!=="DIRECT";
  card.querySelector("[data-cuts-demand]").hidden=mode!=="CUTS";
}

function salesMaterialDemand(card){
  const picker=card.querySelector("[data-material-picker]");
  const material=readMaterialPicker(picker,false);
  const mode=card.dataset.mode||"DIRECT";
  if(mode==="CUTS"){
    return [...card.querySelectorAll(".sales-cut-row")].reduce((sum,row)=>sum+(Number(row.querySelector("[data-cut-pieces]").value)||0)*(Number(row.querySelector("[data-cut-length]").value)||0),0);
  }
  return Number(card.querySelector("[data-sales-quantity]").value)||0;
}

function syncSalesMaterialDemand(card){
  const picker=card.querySelector("[data-material-picker]");
  const material=readMaterialPicker(picker,false);
  const mode=card.dataset.mode||"DIRECT";
  card.querySelectorAll(".sales-cut-row").forEach(row=>{const pieces=Number(row.querySelector("[data-cut-pieces]").value)||0,length=Number(row.querySelector("[data-cut-length]").value)||0;row.querySelector("[data-cut-total]").textContent=`${fmt.number(pieces*length,3)} m`;});
  const total=salesMaterialDemand(card);
  const atp=Number(material.availableToPromise||0);
  const projected=atp-total;
  card.dataset.shortage=String(Math.max(-projected,0));
  const cells=card.querySelectorAll("[data-demand-summary] strong");
  if(cells[0])cells[0].textContent=`${fmt.number(total,3)} ${fmt.escape(material.unit||"UND")}`;
  if(cells[1])cells[1].textContent=`${fmt.number(atp,3)} ${fmt.escape(material.unit||"UND")}`;
  if(cells[2]){cells[2].textContent=`${fmt.number(Math.max(projected,0),3)} ${fmt.escape(material.unit||"UND")}`;cells[2].classList.toggle("warning",projected<0);}
  const status=card.querySelector("[data-demand-status]");
  if(!material.materialMasterId){status.innerHTML="";return}
  if(total<=0){status.className="sales-demand-status neutral";status.innerHTML='<strong>Define la cantidad.</strong><span>La reserva se calculará cuando completes este material.</span>';return}
  if(projected>=0){status.className="sales-demand-status success";status.innerHTML=`<strong>Disponibilidad suficiente</strong><span>Al crear el pedido quedarán reservados ${fmt.number(total,3)} ${fmt.escape(material.unit)} de forma lógica. Logística escogerá el origen físico.</span>`;}
  else{status.className="sales-demand-status warning";status.innerHTML=`<strong>Faltante proyectado: ${fmt.number(Math.abs(projected),3)} ${fmt.escape(material.unit)}</strong><span>El pedido puede registrarse, pero quedará trazada la necesidad por encima de la disponibilidad comercial actual.</span>`;}
}

function validateSalesMaterialCard(card,index){
  let material;try{material=readMaterialPicker(card.querySelector("[data-material-picker]"),true)}catch(error){throw new Error(`Material ${index+1}: ${error.message}`)}
  const mode=card.dataset.mode||"DIRECT";
  if(mode==="CUTS"){
    if(String(material.unit).toUpperCase()!=="M")throw new Error(`Material ${index+1}: solo los materiales en metros pueden usar plan de cortes.`);
    const rows=[...card.querySelectorAll(".sales-cut-row")];if(!rows.length)throw new Error(`Material ${index+1}: agrega al menos una medida de corte.`);
    rows.forEach((row,cutIndex)=>{const pieces=Number(row.querySelector("[data-cut-pieces]").value),length=Number(row.querySelector("[data-cut-length]").value);if(!Number.isInteger(pieces)||pieces<=0)throw new Error(`Material ${index+1}, corte ${cutIndex+1}: indica cuántas piezas necesitas.`);if(!Number.isFinite(length)||length<=0)throw new Error(`Material ${index+1}, corte ${cutIndex+1}: indica una longitud válida.`);});
  }else{
    const quantity=Number(card.querySelector("[data-sales-quantity]").value);if(!Number.isFinite(quantity)||quantity<=0)throw new Error(`Material ${index+1}: registra una cantidad válida.`);
  }
  return material;
}

function collectSalesItems(root){
  const output=[];let line=0;
  [...root.querySelectorAll("[data-sales-material]")].forEach((card,index)=>{
    const material=validateSalesMaterialCard(card,index);const mode=card.dataset.mode||"DIRECT";const groupId=crypto.randomUUID();
    const baseMeta={materialMasterId:material.materialMasterId,materialVariantId:material.materialVariantId,variantLabel:material.variantLabel,source:"SALES_SIESA_MASTER_V10_15",salesMaterialGroupId:groupId};
    if(mode==="CUTS"){
      [...card.querySelectorAll(".sales-cut-row")].forEach((row,cutIndex)=>{line+=1;const pieces=Number(row.querySelector("[data-cut-pieces]").value),length=Number(row.querySelector("[data-cut-length]").value);output.push({lineNumber:line,sku:material.reference,reference:material.reference,description:material.description,quantity:pieces,unit:material.unit,warehouseLocation:null,requiresCut:true,requestedCutLength:length,metadata:{...baseMeta,salesDemandMode:"CUTS",salesCutIndex:cutIndex+1,totalRequested:pieces*length}});});
    }else{
      line+=1;const quantity=Number(card.querySelector("[data-sales-quantity]").value);output.push({lineNumber:line,sku:material.reference,reference:material.reference,description:material.description,quantity,unit:material.unit,warehouseLocation:null,requiresCut:false,requestedCutLength:null,metadata:{...baseMeta,salesDemandMode:"DIRECT",totalRequested:quantity}});
    }
  });
  return output;
}

function renumberItems(editor){[...editor.querySelectorAll(".item-row-number")].forEach((element,index)=>element.textContent=String(index+1))}
function initialRouteLabel(data){
  if(["PVC","PVP"].includes(data.orderType)&&data.hasCreditArrears)return "Cartera · cliente con mora";
  if(data.orderType==="PVN"&&data.heldByCashier)return "Caja · pedido retenido";
  if(data.orderType==="PVE")return "Compras";
  return "Recepción de pedidos";
}


export async function openOrder(orderId){
  const host=document.querySelector("#modal-root");
  host.innerHTML=`<div class="modal-overlay simple-process-overlay"><section class="modal simple-process-modal wide"><div class="modal-body">${loading("Abriendo gestión del pedido…")}</div></section></div>`;
  try{
    const data=await api.getOrder(orderId);
    renderSimpleOrder(host,data);
    mountOrderCancellationAction(host,data,{reload:()=>openOrder(orderId),refresh:refreshLists});
  }catch(error){
    host.innerHTML=`<div class="modal-overlay"><section class="modal"><header class="modal-head"><h3>No fue posible abrir el pedido</h3><button class="icon-btn" data-close>×</button></header><div class="modal-body"><p class="danger">${fmt.escape(error.message)}</p></div><footer class="modal-foot"><button class="btn btn-primary" data-close>Cerrar</button></footer></section></div>`;
    host.querySelectorAll("[data-close]").forEach(button=>button.onclick=()=>host.replaceChildren());
  }
}

function renderSimpleOrder(host,data){
  if(isOrderReceptionStep(data)){renderOrderReception(host,data,{reload:()=>openOrder(data.order.id),refreshLists});return;}
  if(isFinancialFlowStep(data)){renderFinancialFlow(host,data,{reload:()=>openOrder(data.order.id),refreshLists});return;}
  if(isCuttingFlow(data)){renderCuttingOrder(host,data);return;}
  if(isPickingFlow(data)){renderPickingFlow(host,data,{reload:()=>openOrder(data.order.id),refreshLists});return;}
  if(isShippingFlow(data)){renderShippingFlow(host,data,{reload:()=>openOrder(data.order.id),refreshLists});return;}
  const order=data.order;
  const task=activeTask(data);
  const status=simpleStatus(task?.status||order.status);
  const requirement=stageRequirement(data);
  const actions=actionCodes(data);
  const next=recommendedAction(data,requirement);
  host.innerHTML=`
    <div class="modal-overlay simple-process-overlay">
      <section class="modal simple-process-modal wide" data-order-id="${fmt.escape(order.id)}">
        <header class="modal-head simple-process-head">
          <div><span class="wizard-kicker">Gestión rápida</span><h3>${fmt.escape(order.order_number)}</h3><p>${fmt.escape(order.client_name)} · ${fmt.escape(fmt.step(order.current_step_code))}</p></div>
          <button class="icon-btn" data-close aria-label="Cerrar">×</button>
        </header>
        <div class="modal-body simple-process-body">
          <section class="simple-order-summary">
            <div><small>Situación actual</small><strong class="simple-status-title ${status.tone}">${fmt.escape(status.label)}</strong></div>
            <div><small>Responsable</small><strong>${fmt.escape(currentAssignee(data))}</strong></div>
            <div><small>Condición</small><strong>${fmt.escape(fmt.payment(order.payment_condition_code))}</strong></div>
            <div><small>Entrega</small><strong>${fmt.escape(fmt.route(order.delivery_route_code))}</strong></div>
          </section>

          ${workflowMini(data.tasks,order.current_step_code)}

          <section class="simple-next-action ${next.tone}">
            <div><span>Siguiente paso recomendado</span><h4>${fmt.escape(next.title)}</h4><p>${fmt.escape(next.detail)}</p></div>
            ${next.button?`<button class="btn btn-primary btn-large" data-next-action="${next.button}">${fmt.escape(next.buttonLabel)}</button>`:""}
          </section>

          <section class="simple-status-actions">
            <header><div><h4>Marca la situación del pedido</h4><p>Usa solo el estado que realmente describe el trabajo.</p></div></header>
            <div class="simple-status-grid">
              ${statusOption("PENDING","Pendiente","Aún no se ha iniciado.",status.tone==="pending",actions.has("CLAIM")||actions.has("START"))}
              ${statusOption("WORKING","En gestión","El responsable está trabajando.",status.tone==="working",actions.has("CLAIM")||actions.has("START")||actions.has("RESUME"))}
              ${statusOption("WAITING","En espera","Falta información o una respuesta.",status.tone==="waiting",actions.has("WAIT"))}
              ${statusOption("NOVELTY","Con novedad","Hay un impedimento que debe resolverse.",status.tone==="blocked",actions.has("WAIT"))}
              ${statusOption("DONE","Gestionado","La etapa quedó resuelta.",status.tone==="done",actions.has("COMPLETE"))}
            </div>
          </section>

          <section class="simple-secondary-actions">
            ${actions.has("COMMENT")?'<button class="btn btn-ghost" data-secondary="COMMENT">Agregar nota</button>':""}
            ${actions.has("ASSIGN")?'<button class="btn btn-ghost" data-secondary="ASSIGN">Asignar responsable</button>':""}
            ${actions.has("REQUEST_APPROVAL")?'<button class="btn btn-ghost" data-secondary="REQUEST_APPROVAL">Solicitar aprobación</button>':""}
            ${(data.actions?.domainActions||[]).some(item=>item.code==="FILE")?'<button class="btn btn-ghost" data-secondary="FILE">Adjuntar soporte</button>':""}
            ${(data.actions?.domainActions||[]).some(item=>item.code==="STICKERS")?'<button class="btn btn-ghost" data-secondary="STICKERS">Imprimir etiquetas</button>':""}
          </section>

          <details class="simple-details">
            <summary>Ver información completa del pedido</summary>
            ${simpleDetails(data)}
          </details>
        </div>
        ${parallelWorkFooter(order.current_step_code)}
      </section>
    </div>`;

  host.querySelectorAll("[data-close]").forEach(button=>button.onclick=()=>host.replaceChildren());
  host.querySelector("[data-next-action]")?.addEventListener("click",()=>runSimpleIntent(data,next.button));
  host.querySelectorAll("[data-status-choice]").forEach(button=>button.onclick=()=>runSimpleIntent(data,button.dataset.statusChoice));
  host.querySelectorAll("[data-secondary]").forEach(button=>button.onclick=()=>runSecondary(data,button.dataset.secondary));
}

function activeTask(data){return (data.tasks||[]).find(task=>["QUEUED","ASSIGNED","IN_PROGRESS","WAITING","BLOCKED"].includes(task.status))||null}
function actionCodes(data){return new Set((data.actions?.actions||[]).map(action=>action.code))}
function currentAssignee(data){const task=activeTask(data);return task?.assigned_profile_id?task.assigned_name||fmt.role(task.assigned_role_code||data.order.current_role_code):data.order.current_role_code?fmt.role(data.order.current_role_code):"Sin asignar"}
function statusOption(code,title,detail,current,enabled){return `<button type="button" class="simple-status-option ${current?"current":""}" data-status-choice="${code}" ${enabled||current?"":"disabled"}><span></span><strong>${fmt.escape(title)}</strong><small>${fmt.escape(detail)}</small>${current?'<b>Estado actual</b>':""}</button>`}
function workflowMini(tasks,current){return `<section class="simple-flow-line">${(tasks||[]).map(task=>`<div class="${task.step_code===current?"current":""} ${task.status==="COMPLETED"?"done":""}"><span></span><small>${fmt.escape(fmt.step(task.step_code))}</small></div>`).join("")}</section>`}

function recommendedAction(data,requirement){
  const actions=actionCodes(data),task=activeTask(data);
  if(!task)return {title:"Pedido sin tarea activa",detail:"Consulta a la jefatura logística para revisar el flujo.",tone:"warning"};
  if(actions.has("CLAIM")||actions.has("START"))return {title:"Iniciar la gestión",detail:"Toma el pedido y comienza a trabajar. No debes llenar ningún formulario para iniciar.",button:"WORKING",buttonLabel:"Iniciar gestión",tone:"primary"};
  if(actions.has("RESUME"))return {title:"Retomar la gestión",detail:"El pedido estaba en espera. Retómalo para continuar donde quedó.",button:"WORKING",buttonLabel:"Retomar",tone:"primary"};
  if(task.status==="IN_PROGRESS"&&requirement)return {title:requirement.title,detail:requirement.detail,button:"RESOLVE",buttonLabel:requirement.buttonLabel,tone:"warning"};
  if(actions.has("COMPLETE"))return {title:"La etapa puede finalizar",detail:"Si ya terminaste el trabajo, marca el pedido como gestionado.",button:"DONE",buttonLabel:"Marcar gestionado",tone:"success"};
  return {title:"Pedido actualizado",detail:"No hay una acción pendiente para tu rol en este momento.",tone:"neutral"};
}

function stageRequirement(data){
  const order=data.order,step=order.current_step_code;
  const task=activeTask(data);
  const required=(data.checklist||[]).filter(item=>item.task_id===task?.id&&item.required&&!item.completed);
  const hasApproved=(data.financialValidations||[]).some(row=>row.validation_type===step&&row.decision==="APPROVED");
  const validPo=(data.purchaseOrders||[]).some(row=>["ISSUED","CONFIRMED","PARTIAL","RECEIVED"].includes(row.status));
  const validReceipt=(data.receipts||[]).some(row=>["CONFORMING","CLOSED"].includes(row.status));
  const validInvoice=(data.invoices||[]).some(row=>row.status==="REGISTERED");
  const delivered=(data.deliveries||[]).some(row=>row.status==="DELIVERED");
  const domain=(data.actions?.domainActions||[]).map(item=>item.code);
  if(["CARTERA","CAJA"].includes(step)&&!hasApproved&&domain.includes("FINANCIAL"))return {code:"FINANCIAL",title:`Resolver validación de ${fmt.step(step)}`,detail:"Registra la decisión. Si queda aprobada, el ERP finalizará la etapa.",buttonLabel:"Resolver validación"};
  if(step==="COMPRAS"&&!validPo&&domain.includes("PURCHASE"))return {code:"PURCHASE",title:"Registrar la orden de compra",detail:"Solo se solicitará número de orden, proveedor y estado.",buttonLabel:"Registrar orden"};
  if(step==="RECEPCION_MERCANCIA"&&!validReceipt&&domain.includes("RECEIPT"))return {code:"RECEIPT",title:"Confirmar la mercancía recibida",detail:"Verifica cantidades, ubicación y resultado de calidad.",buttonLabel:"Registrar recepción"};
  if(step==="FACTURACION"&&!validInvoice&&domain.includes("INVOICE"))return {code:"INVOICE",title:"Registrar la factura",detail:"Ingresa número, fecha y valor. El pedido continuará automáticamente.",buttonLabel:"Registrar factura"};
  if(["CLIENT_POINT","CLIENT_PICKUP","LOCAL_DISPATCH","NATIONAL_DISPATCH"].includes(step)&&!delivered&&domain.includes("DELIVERY"))return {code:"DELIVERY",title:"Confirmar el despacho o la entrega",detail:"Marca si fue entregado o si debe reprogramarse.",buttonLabel:"Registrar resultado"};
  if(step==="CLOSURE"&&(!validInvoice||!delivered))return {code:"EXTERNAL",title:"Faltan soportes previos",detail:`${!validInvoice?"No hay factura registrada. ":""}${!delivered?"No hay entrega confirmada.":""}`.trim(),buttonLabel:"Revisar"};
  if(required.length)return {code:"CHECKLIST",title:"Confirmar controles de la etapa",detail:`Quedan ${required.length} verificación(es) obligatoria(s). Confírmalas en una sola ventana.`,buttonLabel:"Confirmar controles"};
  return null;
}

async function runSimpleIntent(data,intent){
  if(intent==="PENDING")return;
  if(intent==="WORKING")return beginManagement(data);
  if(intent==="WAITING")return markWaiting(data,false);
  if(intent==="NOVELTY")return markWaiting(data,true);
  if(intent==="DONE")return finishStage(data);
  if(intent==="RESOLVE")return resolveRequirement(data,stageRequirement(data));
}

async function beginManagement(data){
  try{
    let latest=data;
    let actions=actionCodes(latest);
    if(actions.has("CLAIM")){
      await api.executeAction(latest.order.id,"CLAIM",{detail:"Pedido tomado"},latest.order.version);
      latest=await api.getOrder(latest.order.id);actions=actionCodes(latest);
    }
    if(actions.has("START"))await api.executeAction(latest.order.id,"START",{detail:"Gestión iniciada"},latest.order.version);
    else if(actions.has("RESUME"))await api.executeAction(latest.order.id,"RESUME",{detail:"Gestión retomada"},latest.order.version);
    toast("El pedido quedó en gestión.","success");
    refreshLists();
    await openOrder(data.order.id);
  }catch(error){toast(error.message,"error",7000)}
}

function markWaiting(data,novelty=false){
  modal({
    title:novelty?"Registrar novedad":"Dejar pedido en espera",
    confirmLabel:novelty?"Guardar novedad":"Dejar en espera",
    body:`<div class="simple-form-intro"><strong>${novelty?"¿Qué impide continuar?":"¿Qué información o respuesta falta?"}</strong><p>Escribe una frase clara. El pedido seguirá visible para retomarlo después.</p></div><div class="field"><label>Motivo *</label><textarea class="control" name="reason" required autofocus></textarea></div>`,
    onConfirm:async dialog=>{
      const reason=dialog.querySelector('[name="reason"]').value.trim();if(!reason)throw new Error("Escribe el motivo.");
      let latest=await api.getOrder(data.order.id);const actions=actionCodes(latest);
      if(novelty&&actions.has("COMMENT")){
        await api.executeAction(latest.order.id,"COMMENT",{body:reason,commentType:"NOVELTY",visibility:"INTERNAL"},latest.order.version);
        latest=await api.getOrder(data.order.id);
      }
      if(actionCodes(latest).has("WAIT"))await api.executeAction(latest.order.id,"WAIT",{reason},latest.order.version);
      toast(novelty?"Novedad registrada.":"Pedido en espera.","success");refreshLists();setTimeout(()=>openOrder(data.order.id),100);
    }
  });
}

async function finishStage(data){
  const latest=await api.getOrder(data.order.id);
  const requirement=stageRequirement(latest);
  if(requirement)return resolveRequirement(latest,requirement);
  return confirmComplete(latest);
}

function confirmComplete(data){
  modal({title:"Marcar etapa como gestionada",confirmLabel:"Sí, finalizar etapa",body:`<div class="wizard-confirm-box"><strong>${fmt.escape(fmt.step(data.order.current_step_code))} completada</strong><p>El pedido avanzará automáticamente a la siguiente etapa.</p></div><div class="field"><label>Observación opcional</label><textarea class="control" name="detail" placeholder="Solo si necesitas dejar una aclaración"></textarea></div>`,onConfirm:async dialog=>{const detail=dialog.querySelector('[name="detail"]').value.trim()||"Etapa gestionada";await api.executeAction(data.order.id,"COMPLETE",{detail},data.order.version);toast("Etapa finalizada y pedido enviado al siguiente proceso.","success",6000);refreshLists();}});
}

function resolveRequirement(data,requirement){
  if(!requirement)return confirmComplete(data);
  if(requirement.code==="FINANCIAL")return quickFinancial(data);
  if(requirement.code==="PURCHASE")return quickPurchase(data);
  if(requirement.code==="RECEIPT")return quickReceipt(data);
  if(requirement.code==="INVOICE")return quickInvoice(data);
  if(requirement.code==="DELIVERY")return quickDelivery(data);
  if(requirement.code==="CHECKLIST")return quickChecklist(data);
  toast(requirement.detail,"error",7000);
}

function checklistConfirmation(data){
  const task=activeTask(data);const rows=(data.checklist||[]).filter(item=>item.task_id===task?.id&&item.required&&!item.completed);
  if(!rows.length)return "";
  return `<div class="simple-check-confirm"><strong>Controles obligatorios</strong><ul>${rows.map(item=>`<li>${fmt.escape(item.label)}</li>`).join("")}</ul><label><input type="checkbox" name="confirmChecklist" required> Confirmo que realicé estos controles.</label></div>`;
}
async function completeChecklist(data,note="Verificado desde gestión rápida"){
  const task=activeTask(data);const rows=(data.checklist||[]).filter(item=>item.task_id===task?.id&&item.required&&!item.completed);
  for(const item of rows)await api.updateChecklist(task.id,item.item_code,true,note);
}
async function finalizeAfterDomain(orderId,message){
  let latest=await api.getOrder(orderId);
  await completeChecklist(latest);
  latest=await api.getOrder(orderId);
  if(actionCodes(latest).has("COMPLETE"))await api.executeAction(orderId,"COMPLETE",{detail:message},latest.order.version);
  toast(message,"success",6000);refreshLists();setTimeout(()=>openOrder(orderId),100);
}

function quickFinancial(data){
  const step=data.order.current_step_code;
  modal({title:`Gestión de ${fmt.step(step)}`,confirmLabel:"Guardar resultado",size:"wide",body:`<div class="simple-choice-row">${choice("decision","APPROVED","Aprobado","Puede continuar al siguiente proceso.",true)}${choice("decision","PENDING","Pendiente","Falta información o confirmación.")}${choice("decision","REJECTED","Con novedad","No puede continuar hasta resolverla.")}</div><div class="form-grid"><div class="field"><label>Referencia o comprobante</label><input class="control" name="reference"></div><div class="field"><label>Valor</label><input class="control" name="amount" type="number" step="any"></div><div class="field full"><label>Observación *</label><textarea class="control" name="notes" required placeholder="Ejemplo: cupo aprobado, pago confirmado o documento pendiente"></textarea></div></div>${checklistConfirmation(data)}`,onConfirm:async dialog=>{
    const form=dialogData(dialog);const payload={validationType:step,decision:form.decision,reference:form.reference,notes:form.notes};if(form.amount)payload.amount=form.amount;
    await api.saveFinancialValidation(data.order.id,payload);
    if(form.decision==="APPROVED")return finalizeAfterDomain(data.order.id,`${fmt.step(step)} gestionada`);
    const latest=await api.getOrder(data.order.id);
    if(form.decision==="PENDING"&&actionCodes(latest).has("WAIT"))await api.executeAction(data.order.id,"WAIT",{reason:form.notes},latest.order.version);
    if(form.decision==="REJECTED"){
      let current=latest;if(actionCodes(current).has("COMMENT")){await api.executeAction(data.order.id,"COMMENT",{body:form.notes,commentType:"NOVELTY",visibility:"INTERNAL"},current.order.version);current=await api.getOrder(data.order.id)}
      if(actionCodes(current).has("WAIT"))await api.executeAction(data.order.id,"WAIT",{reason:form.notes},current.order.version);
    }
    toast("Resultado guardado. El pedido queda visible para continuar después.","success");refreshLists();setTimeout(()=>openOrder(data.order.id),100);
  }});
}

function quickPurchase(data){
  modal({title:"Registrar orden de compra",confirmLabel:"Guardar y continuar",body:`<div class="form-grid"><div class="field"><label>Número de orden *</label><input class="control" name="poNumber" required autofocus></div><div class="field"><label>Proveedor *</label><input class="control" name="supplierName" required></div><div class="field"><label>Estado *</label><select class="control" name="status"><option value="ISSUED">Emitida</option><option value="CONFIRMED" selected>Confirmada</option><option value="PARTIAL">Recepción parcial</option></select></div><div class="field"><label>Fecha esperada</label><input class="control" name="expectedAt" type="datetime-local"></div><div class="field"><label>Valor total</label><input class="control" name="totalAmount" type="number" step="any"></div></div>${checklistConfirmation(data)}`,onConfirm:async dialog=>{const f=dialogData(dialog);const payload={poNumber:f.poNumber,supplierName:f.supplierName,status:f.status,currency:"COP"};if(f.expectedAt)payload.expectedAt=new Date(f.expectedAt).toISOString();if(f.totalAmount)payload.totalAmount=f.totalAmount;await api.savePurchaseOrder(data.order.id,payload);await finalizeAfterDomain(data.order.id,"Compra gestionada y pedido liberado")}});
}

function quickChecklist(data){
  modal({title:"Confirmar controles",confirmLabel:"Confirmar y finalizar",body:`<div class="simple-form-intro"><strong>Una sola confirmación</strong><p>Revisa la lista y confirma únicamente cuando todos los controles estén realizados.</p></div>${checklistConfirmation(data)}<div class="field"><label>Observación opcional</label><textarea class="control" name="note"></textarea></div>`,onConfirm:async dialog=>{const note=dialog.querySelector('[name="note"]').value.trim()||"Controles verificados";await completeChecklist(data,note);const latest=await api.getOrder(data.order.id);if(actionCodes(latest).has("COMPLETE"))await api.executeAction(data.order.id,"COMPLETE",{detail:note},latest.order.version);toast("Controles confirmados y etapa finalizada.","success");refreshLists()}});
}

async function quickReceipt(data){
  const progress=await api.receiptProgress(data.order.id);
  const previous=new Map((progress?.items||[]).map(item=>[String(item.orderItemId),item]));
  const items=(data.items||[]).map(item=>{
    const p=previous.get(String(item.id));
    const remaining=Math.max(0,Number(p?.remainingQuantity??item.quantity??0));
    return {...item,_receivedBefore:Number(p?.acceptedQuantity||0),_remaining:remaining};
  }).filter(item=>item._remaining>0.0001);
  if(!items.length){
    toast("Las cantidades aceptadas ya cubren el pedido. Actualiza el pedido para continuar con el cierre de Recepción.","success",6500);
    return;
  }
  const requestId=crypto.randomUUID?.()||`receipt-${Date.now()}-${Math.random().toString(36).slice(2)}`;
  const rows=items.map(item=>`<div class="simple-receipt-line" data-item="${item.id}"><div><strong>${fmt.escape(item.sku||item.description)}</strong><small>Pendiente: ${fmt.number(item._remaining,3)} de ${fmt.number(item.quantity,3)} ${fmt.escape(item.unit)}${item._receivedBefore?` · ya aceptado ${fmt.number(item._receivedBefore,3)}`:""}</small></div><label>Aceptado<input class="control" name="accepted" type="number" min="0" max="${Number(item._remaining)}" step="any" value="${Number(item._remaining)}"></label></div>`).join("");
  modal({title:"Confirmar recepción de mercancía",confirmLabel:"Guardar recepción",size:"wide",body:`<div class="simple-choice-row">${choice("status","CONFORMING","Conforme","Con esta llegada se completan todas las cantidades pendientes.",true)}${choice("status","PARTIAL","Parcial","Todavía quedarán cantidades pendientes por recibir.")}${choice("status","NONCONFORMING","Con novedad","Hay cantidad rechazada o una diferencia que debe resolverse.")}</div><div class="form-grid"><div class="field"><label>Orden de compra</label><input class="control" name="purchaseOrder"></div><div class="field"><label>Proveedor</label><input class="control" name="supplierName"></div><div class="field"><label>Ubicación *</label><input class="control" name="location" value="RECEPCION" required></div><div class="field"><label>Lote común</label><input class="control" name="lotNumber"></div></div><div class="simple-receipt-list">${rows}</div><div class="field"><label>Observación</label><textarea class="control" name="note"></textarea></div>${checklistConfirmation(data)}`,onConfirm:async dialog=>{
    const f=dialogData(dialog);
    const captured=[...dialog.querySelectorAll("[data-item]")].map(row=>{
      const item=items.find(x=>x.id===row.dataset.item);
      const accepted=Number(row.querySelector('[name="accepted"]').value||0);
      const pending=Number(item._remaining||0);
      if(!Number.isFinite(accepted)||accepted<0||accepted>pending)throw new Error(`Cantidad aceptada inválida para ${item.sku||item.description}`);
      if(f.status==="CONFORMING"&&Math.abs(accepted-pending)>0.0001)throw new Error("Una recepción Conforme debe cubrir toda la cantidad pendiente. Usa Parcial o Con novedad si aún faltará mercancía.");
      const received=f.status==="NONCONFORMING"?pending:accepted;
      const rejected=f.status==="NONCONFORMING"?Math.max(0,pending-accepted):0;
      return {orderItemId:item.id,sku:item.sku||null,reference:item.reference||null,description:item.description,expectedQuantity:Number(item.quantity||0),receivedQuantity:received,acceptedQuantity:accepted,rejectedQuantity:rejected,unit:item.unit||"UND",location:f.location,lotNumber:f.lotNumber||null,qualityStatus:f.status==="NONCONFORMING"?"REJECTED":f.status==="PARTIAL"?"CONDITIONAL":"ACCEPTED",metadata:{lotNumber:f.lotNumber||null,materialMasterId:item.material_master_id||item.metadata?.materialMasterId||null,materialVariantId:item.material_variant_id||item.metadata?.materialVariantId||null}};
    });
    const lines=f.status==="PARTIAL"?captured.filter(line=>line.receivedQuantity>0):captured;
    if(!lines.length)throw new Error("Debes registrar al menos una cantidad recibida mayor que cero.");
    await api.saveReceipt(data.order.id,{requestId,purchaseOrder:f.purchaseOrder||null,supplierName:f.supplierName||null,status:f.status,lines});
    if(f.status==="CONFORMING")return finalizeAfterDomain(data.order.id,"Recepción confirmada y etapa finalizada");
    const latest=await api.getOrder(data.order.id);const reason=f.note||"Recepción pendiente de resolución";if(actionCodes(latest).has("WAIT"))await api.executeAction(data.order.id,"WAIT",{reason},latest.order.version);toast("Recepción registrada. El pedido queda pendiente de resolución.","success");refreshLists();
  }});
}


function quickInvoice(data){
  modal({title:"Registrar factura",confirmLabel:"Guardar factura y continuar",body:`<div class="form-grid"><div class="field"><label>Número de factura *</label><input class="control" name="invoiceNumber" required autofocus></div><div class="field"><label>Fecha *</label><input class="control" name="invoiceDate" type="date" value="${new Date().toISOString().slice(0,10)}" required></div><div class="field"><label>Valor</label><input class="control" name="amount" type="number" step="any"></div></div>${checklistConfirmation(data)}`,onConfirm:async dialog=>{const f=dialogData(dialog);const payload={invoiceNumber:f.invoiceNumber,invoiceDate:f.invoiceDate,currency:"COP"};if(f.amount)payload.amount=f.amount;await api.saveInvoice(data.order.id,payload);await finalizeAfterDomain(data.order.id,"Factura registrada y pedido liberado")}});
}

function quickDelivery(data){
  modal({title:"Registrar entrega",confirmLabel:"Guardar resultado",size:"wide",body:`<div class="simple-choice-row">${choice("status","DELIVERED","Entregado","El cliente recibió el pedido.",true)}${choice("status","NOT_DELIVERED","No entregado","Debe reprogramarse o revisarse.")}${choice("status","IN_TRANSIT","En tránsito","La transportadora aún tiene el pedido.")}</div><div class="form-grid"><div class="field"><label>Transportadora</label><input class="control" name="carrier"></div><div class="field"><label>Número de guía</label><input class="control" name="trackingNumber"></div><div class="field"><label>Recibido por</label><input class="control" name="receivedBy"></div><div class="field"><label>Nueva fecha, si aplica</label><input class="control" name="scheduledAt" type="datetime-local"></div><div class="field full"><label>Observación o motivo</label><textarea class="control" name="noDeliveryReason"></textarea></div></div>${checklistConfirmation(data)}`,onConfirm:async dialog=>{
    const f=dialogData(dialog);if(f.status==="DELIVERED"&&!f.receivedBy)throw new Error("Indica quién recibió el pedido.");if(f.status==="NOT_DELIVERED"&&!f.noDeliveryReason)throw new Error("Indica el motivo de la no entrega.");
    const payload={status:f.status};for(const key of ["carrier","trackingNumber","receivedBy","noDeliveryReason"])if(f[key])payload[key]=f[key];if(f.scheduledAt)payload.scheduledAt=new Date(f.scheduledAt).toISOString();if(f.status==="DELIVERED")payload.deliveredAt=new Date().toISOString();if(f.status==="IN_TRANSIT")payload.dispatchedAt=new Date().toISOString();
    await api.saveDelivery(data.order.id,payload);
    if(f.status==="DELIVERED")return finalizeAfterDomain(data.order.id,"Entrega confirmada y etapa finalizada");
    const latest=await api.getOrder(data.order.id);if(f.status==="NOT_DELIVERED"&&actionCodes(latest).has("NO_DELIVERY"))await api.executeAction(data.order.id,"NO_DELIVERY",{reason:f.noDeliveryReason},latest.order.version);else if(actionCodes(latest).has("WAIT"))await api.executeAction(data.order.id,"WAIT",{reason:f.noDeliveryReason||"Entrega en tránsito"},latest.order.version);toast("Estado de entrega actualizado.","success");refreshLists();
  }});
}

function runSecondary(data,code){
  if(code==="COMMENT")return quickComment(data);
  if(code==="ASSIGN")return quickAssign(data);
  if(code==="REQUEST_APPROVAL")return quickApproval(data);
  if(code==="FILE")return quickFile(data);
  if(code==="STICKERS")return printStickers(data.order.id);
}
function quickComment(data){modal({title:"Agregar nota",confirmLabel:"Guardar nota",body:`<div class="field"><label>Nota *</label><textarea class="control" name="body" required autofocus placeholder="Escribe una observación breve"></textarea></div>`,onConfirm:async dialog=>{const body=dialog.querySelector('[name="body"]').value.trim();await api.executeAction(data.order.id,"COMMENT",{body,commentType:"COMMENT",visibility:"INTERNAL"},data.order.version);toast("Nota guardada.","success");refreshLists()}})}
async function quickAssign(data){const pool=await api.assignmentPool(data.order.current_step_code);if(!pool.length)return toast("No hay responsables habilitados.","error");modal({title:"Asignar responsable",confirmLabel:"Asignar",body:`<div class="field"><label>Responsable *</label><select class="control" name="profileId" required>${pool.map(person=>`<option value="${person.id}">${fmt.escape(person.name)} · ${fmt.escape((person.roles||[]).map(role=>fmt.role(role)).join(" / "))}</option>`).join("")}</select></div>`,onConfirm:async dialog=>{const id=dialog.querySelector('[name="profileId"]').value;await api.executeAction(data.order.id,"ASSIGN",{profileId:id},data.order.version);toast("Responsable asignado.","success");refreshLists();setTimeout(()=>openOrder(data.order.id),100)}})}
function quickApproval(data){modal({title:"Solicitar aprobación",confirmLabel:"Enviar solicitud",body:`<div class="field"><label>Tipo *</label><select class="control" name="requestType"><option value="PRIORITY">Cambio de prioridad</option><option value="ROUTE_CHANGE">Cambio de ruta</option><option value="STOCK_EXCEPTION">Excepción de inventario</option><option value="FLOW_EXCEPTION">Excepción del flujo</option><option value="PAYMENT_EXCEPTION">Excepción financiera</option><option value="DATA_CORRECTION">Corrección de datos</option></select></div><div class="field"><label>Motivo *</label><textarea class="control" name="reason" required></textarea></div>`,onConfirm:async dialog=>{const f=dialogData(dialog);const payload={requestType:f.requestType,reason:f.reason};if(f.requestType==="PRIORITY")payload.priority="HIGH";if(f.requestType==="ROUTE_CHANGE")payload.route=data.order.delivery_route_code;await api.executeAction(data.order.id,"REQUEST_APPROVAL",payload,data.order.version);toast("Solicitud enviada.","success");refreshLists()}})}
function quickFile(data){modal({title:"Adjuntar soporte",confirmLabel:"Subir archivo",body:`<div class="field"><label>Tipo de documento</label><select class="control" name="category"><option value="EVIDENCE">Evidencia</option><option value="PAYMENT">Soporte de pago</option><option value="PURCHASE_ORDER">Orden de compra</option><option value="INVOICE">Factura</option><option value="DELIVERY">Entrega</option><option value="QUALITY">Calidad</option></select></div><div class="field"><label>Archivo *</label><input class="control" name="file" type="file" required></div>`,onConfirm:async dialog=>{const file=dialog.querySelector('[name="file"]').files[0];const category=dialog.querySelector('[name="category"]').value;await uploadOrderFile(data.order.id,file,category,activeTask(data)?.id,data.order.order_number);toast("Archivo cargado.","success")}})}

function simpleDetails(data){
  const o=data.order;
  return `<div class="simple-detail-sections"><section><h4>Información principal</h4><div class="detail-grid">${info("Cliente",o.client_name)}${info("Tipo",fmt.label(o.order_type_code))}${info("Pago",fmt.payment(o.payment_condition_code))}${info("Ruta",fmt.route(o.delivery_route_code))}${info("Prioridad",fmt.label(o.priority))}${info("Creado",fmt.date(o.created_at))}</div></section><section><h4>Materiales</h4>${itemsTable(data.items||[])}</section><section><h4>Últimos movimientos</h4>${eventsMini(data.events||[])}</section><section><h4>Comentarios</h4>${commentsMini(data.comments||[])}</section></div>`;
}
function info(label,value){return `<div class="info-box"><label>${fmt.escape(label)}</label><strong>${fmt.escape(value??"—")}</strong></div>`}
function itemsTable(items){return items.length?`<div class="table-wrap mobile-card-table"><table><thead><tr><th>Material</th><th>Cantidad</th><th>Corte</th></tr></thead><tbody>${items.map(item=>`<tr><td data-label="Material"><strong>${fmt.escape(item.sku||item.description)}</strong><div class="cell-sub">${fmt.escape(item.description)}</div></td><td data-label="Cantidad">${fmt.number(item.quantity,3)} ${fmt.escape(item.unit)}</td><td data-label="Corte">${item.requires_cut?"Sí":"No"}</td></tr>`).join("")}</tbody></table></div>`:empty("Sin materiales")}
function eventsMini(events){return events.length?`<div class="timeline">${events.slice(-8).reverse().map(event=>`<div class="timeline-item"><h4>${fmt.escape(fmt.action(event.actionCode||event.eventType))}</h4><p>${fmt.escape(event.actorName||"Sistema")}</p><time>${fmt.date(event.createdAt)}</time></div>`).join("")}</div>`:empty("Sin movimientos")}
function commentsMini(rows){return rows.length?`<div class="timeline">${rows.slice(-6).reverse().map(row=>`<div class="timeline-item"><h4>${fmt.escape(row.author)}</h4><p>${fmt.escape(row.body)}</p><time>${fmt.date(row.createdAt)}</time></div>`).join("")}</div>`:empty("Sin comentarios")}

function dialogData(dialog){
  const data={};
  dialog.querySelectorAll("input,select,textarea").forEach(control=>{
    if(!control.name||control.disabled)return;
    if(control.type==="radio"){if(control.checked)data[control.name]=control.value;return;}
    if(control.type==="checkbox"){data[control.name]=control.checked;return;}
    if(control.type!=="file")data[control.name]=control.value;
  });
  return data;
}

function refreshLists(){window.__erpQueueRefresh?.();window.__erpOrderListRefresh?.()}

function exportCurrent(){
  const rows=currentList.data?.items||[];
  if(!rows.length)return toast("No hay registros para exportar.","error");
  const headers=Object.keys(rows[0]);
  const csv=[headers.join(","),...rows.map(row=>headers.map(header=>`"${String(row[header]??"").replaceAll('"','""')}"`).join(","))].join("\n");
  const link=document.createElement("a");link.href=URL.createObjectURL(new Blob([csv],{type:"text/csv;charset=utf-8"}));link.download=`pedidos_${new Date().toISOString().slice(0,10)}.csv`;link.click();URL.revokeObjectURL(link.href);
}

async function printStickers(orderId){
  const rows=await api.stickers(orderId);if(!rows.length)return toast("No hay líneas recibidas para imprimir.","error");
  const win=window.open("","_blank","width=1000,height=800");win.document.write(`<!doctype html><meta charset="utf-8"><title>Etiquetas de recepción</title><style>body{font-family:Arial;margin:12mm}.grid{display:grid;grid-template-columns:repeat(2,1fr);gap:7mm}.s{border:2px solid #111;border-radius:8px;padding:7mm;min-height:62mm;page-break-inside:avoid}.h{display:flex;justify-content:space-between;border-bottom:1px solid #333;padding-bottom:4mm;margin-bottom:4mm}.big{font-size:20px;font-weight:900}.r{display:grid;grid-template-columns:110px 1fr;margin:2mm 0}.l{font-size:10px;text-transform:uppercase;color:#555}.v{font-weight:700}@media print{body{margin:5mm}.s{min-height:55mm}}</style><div class="grid">${rows.map(row=>`<article class="s"><div class="h"><div><div class="l">Recepción</div><div class="big">${fmt.escape(row.receiptNumber||"")}</div></div><div><div class="l">OC</div><strong>${fmt.escape(row.purchaseOrder||"—")}</strong></div></div><div class="r"><span class="l">Material</span><span class="v">${fmt.escape(row.description)}</span></div><div class="r"><span class="l">SKU</span><span class="v">${fmt.escape(row.sku||"—")}</span></div><div class="r"><span class="l">Cantidad</span><span class="v">${fmt.number(row.quantity,3)} ${fmt.escape(row.unit)}</span></div><div class="r"><span class="l">Ubicación</span><span class="v">${fmt.escape(row.location||"—")}</span></div></article>`).join("")}</div><script>onload=()=>print()<\/script>`);win.document.close();
}
