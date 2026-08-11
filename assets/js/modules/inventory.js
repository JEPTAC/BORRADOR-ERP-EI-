import {api} from "../services/api.js";
import {fmt} from "../core/format.js";
import {can} from "../core/state.js";
import {empty,loading,paginationHtml,wizard,toast,guide,modal} from "../core/ui.js";
import {choice} from "../core/guided.js";
import {syncSiesaFile} from "../services/materials.js";

let currentItems=[];
let currentPage=1;
let requestSequence=0;

const DEFAULT_FILTERS=Object.freeze({
  search:"",unit:"",warehouse:"",itemType:"",stock:"",variants:"ALL",sort:"reference_asc",pageSize:50
});

function unitLabel(unit){
  const code=String(unit||"UND").toUpperCase();
  const labels={M:"Metros",UND:"Unidades",UN:"Unidades",KG:"Kilogramos",GR:"Gramos",G:"Gramos",LT:"Litros",L:"Litros",M2:"Metros²",M3:"Metros³",PAR:"Pares",JGO:"Juegos",ROLLO:"Rollos"};
  return labels[code]?`${labels[code]} (${code})`:code;
}
function typeLabel(type){return String(type||"").toUpperCase()==="CUTTABLE"?"Cortable":"Estándar"}
function stockClass(value){return Number(value||0)>0?"is-positive":"is-zero"}
function criteriaText(item){
  const criteria=Array.isArray(item?.attributes?.criteria)?item.attributes.criteria:[];
  return criteria.map(row=>row?.name).filter(Boolean).slice(0,3);
}
function warehousesText(item){
  const values=Array.isArray(item?.warehouses)?item.warehouses.filter(Boolean):[];
  if(!values.length)return "Sin bodega informada";
  if(values.length<=3)return `Bodega ${values.join(" · ")}`;
  return `Bodegas ${values.slice(0,2).join(" · ")} +${values.length-2}`;
}

export async function renderInventory(root){
  const canUpdate=can("inventory","canUpdate");
  const filters={...DEFAULT_FILTERS};
  let facets={units:[],warehouses:[]};
  let searchTimer=null;

  root.innerHTML=`
    <section class="page-head inventory-page-head">
      <div><h2>Inventario</h2><p>Lista operacional del maestro oficial Siesa. Busca, filtra y abre únicamente el material que necesitas.</p></div>
      <div class="page-actions">${canUpdate?'<button class="btn btn-primary" id="sync-siesa">Actualizar maestro Siesa</button>':""}<button class="btn btn-ghost" id="inventory-help">Ver guía</button></div>
    </section>
    <section class="material-master-strip inventory-master-strip" id="material-master-strip">${loading("Consultando estado del maestro…")}</section>
    <section class="card inventory-browser">
      <div class="inventory-browser-head">
        <label class="inventory-search-field" for="inv-search"><span>Buscar material</span><div><input class="control" id="inv-search" autocomplete="off" placeholder="Referencia, nombre, familia, marca o código"><button class="inventory-search-clear" type="button" id="inv-clear-search" aria-label="Limpiar búsqueda" hidden>×</button></div></label>
        <button class="btn btn-ghost inventory-filter-toggle" id="inv-filter-toggle" type="button" aria-expanded="false">Filtros <span id="inv-filter-count" hidden>0</span></button>
      </div>
      <div class="inventory-filter-panel" id="inv-filter-panel">
        <label><span>Unidad de medida</span><select class="control" id="inv-unit"><option value="">Todas las unidades</option></select></label>
        <label><span>Bodega</span><select class="control" id="inv-warehouse"><option value="">Todas las bodegas</option></select></label>
        <label><span>Disponibilidad</span><select class="control" id="inv-stock"><option value="">Todos</option><option value="AVAILABLE">Disponible para venta</option><option value="OUT">Sin disponible para venta</option><option value="PHYSICAL">Con existencia física</option><option value="RESERVED">Con reserva ERP</option><option value="BLOCKED">Con cantidad bloqueada</option></select></label>
        <label><span>Tipo de material</span><select class="control" id="inv-type"><option value="">Todos los tipos</option><option value="STANDARD">Estándar</option><option value="CUTTABLE">Cortable</option></select></label>
        <label><span>Variantes</span><select class="control" id="inv-variants"><option value="ALL">Todos</option><option value="YES">Con variantes</option><option value="NO">Sin variantes</option></select></label>
        <label><span>Ordenar por</span><select class="control" id="inv-sort"><option value="reference_asc">Referencia A–Z</option><option value="name_asc">Nombre A–Z</option><option value="atp_desc">Mayor disponible</option><option value="atp_asc">Menor disponible</option><option value="physical_desc">Mayor existencia física</option><option value="reserved_desc">Mayor reserva ERP</option><option value="lots_desc">Mayor número de registros</option></select></label>
        <label><span>Filas por página</span><select class="control" id="inv-page-size"><option value="25">25</option><option value="50" selected>50</option><option value="100">100</option></select></label>
        <button class="btn btn-ghost inventory-clear-filters" type="button" id="inv-clear-filters">Limpiar filtros</button>
      </div>
      <div class="inventory-active-filters" id="inv-active-filters" hidden></div>
      <div class="inventory-summary" id="inv-summary" aria-live="polite"></div>
      <div id="inv-result">${loading("Consultando inventario oficial…")}</div>
    </section>`;

  const result=root.querySelector("#inv-result");
  const filterPanel=root.querySelector("#inv-filter-panel");
  const filterToggle=root.querySelector("#inv-filter-toggle");
  const searchInput=root.querySelector("#inv-search");
  const searchClear=root.querySelector("#inv-clear-search");

  function payload(page=1){return {...filters,page,pageSize:Number(filters.pageSize||50)}}
  function activeCount(){return [filters.unit,filters.warehouse,filters.itemType,filters.stock,filters.variants!=="ALL"?filters.variants:""].filter(Boolean).length}
  function syncFilterCount(){
    const count=activeCount();
    const badge=root.querySelector("#inv-filter-count");
    badge.textContent=String(count);badge.hidden=!count;
  }
  function facetOptions(select,rows,selected,allLabel,labeler=value=>value){
    const values=new Set((rows||[]).map(row=>String(row.value)));
    const preserved=selected&&!values.has(String(selected))?[{value:selected,count:0}]:[];
    const options=[`<option value="">${fmt.escape(allLabel)}</option>`,...[...preserved,...(rows||[])].map(row=>`<option value="${fmt.escape(row.value)}">${fmt.escape(labeler(row.value))}${Number(row.count)>0?` · ${fmt.number(row.count)}`:""}</option>`)].join("");
    select.innerHTML=options;
    select.value=selected||"";
  }
  function renderActiveFilters(){
    const target=root.querySelector("#inv-active-filters");
    const chips=[];
    if(filters.unit)chips.push(["unit",unitLabel(filters.unit)]);
    if(filters.warehouse)chips.push(["warehouse",`Bodega ${filters.warehouse}`]);
    if(filters.stock)chips.push(["stock",({AVAILABLE:"Disponible",OUT:"Sin disponible",PHYSICAL:"Con existencia física",RESERVED:"Con reserva ERP",BLOCKED:"Con bloqueado"})[filters.stock]||filters.stock]);
    if(filters.itemType)chips.push(["itemType",typeLabel(filters.itemType)]);
    if(filters.variants!=="ALL")chips.push(["variants",filters.variants==="YES"?"Con variantes":"Sin variantes"]);
    target.hidden=!chips.length;
    target.innerHTML=chips.map(([key,label])=>`<button type="button" data-clear-filter="${key}">${fmt.escape(label)} <span aria-hidden="true">×</span></button>`).join("");
    target.querySelectorAll("[data-clear-filter]").forEach(button=>button.onclick=()=>{
      const key=button.dataset.clearFilter;
      filters[key]=key==="variants"?"ALL":"";
      const map={unit:"#inv-unit",warehouse:"#inv-warehouse",stock:"#inv-stock",itemType:"#inv-type",variants:"#inv-variants"};
      const control=root.querySelector(map[key]);if(control)control.value=filters[key];
      load(1);
    });
  }
  function renderSummary(summary={},pagination={}){
    root.querySelector("#inv-summary").innerHTML=`
      <div class="inventory-result-count"><strong>${fmt.number(pagination.totalItems??summary.materials??0)}</strong><span>materiales encontrados</span></div>
      <div class="inventory-summary-stats">
        <span><b>${fmt.number(summary.availableMaterials||0)}</b> disponibles</span>
        <span><b>${fmt.number(summary.outMaterials||0)}</b> sin disponible</span>
        <span><b>${fmt.number(summary.reservedMaterials||0)}</b> con reserva ERP</span>
        <span><b>${fmt.number(summary.blockedMaterials||0)}</b> con bloqueo</span>
      </div>`;
  }
  function syncFacetControls(){
    facetOptions(root.querySelector("#inv-unit"),facets.units,filters.unit,"Todas las unidades",unitLabel);
    facetOptions(root.querySelector("#inv-warehouse"),facets.warehouses,filters.warehouse,"Todas las bodegas",value=>`Bodega ${value}`);
  }

  async function load(page=1,{quiet=false}={}){
    currentPage=page;
    const seq=++requestSequence;
    if(!quiet)result.innerHTML=loading("Consultando inventario oficial…");
    try{
      const data=await api.inventoryFiltered(payload(page));
      if(seq!==requestSequence)return;
      currentItems=data.items||[];
      facets=data.facets||facets;
      syncFacetControls();syncFilterCount();renderActiveFilters();renderSummary(data.summary,data.pagination);
      result.innerHTML=currentItems.length?`${inventoryList(currentItems)}${paginationHtml(data.pagination)}`:empty("No hay materiales con estos filtros","Prueba otra unidad, bodega, disponibilidad o limpia los filtros.");
      result.querySelectorAll("[data-inventory-item]").forEach(button=>button.onclick=()=>movementWizard(load,button.dataset.inventoryItem));
      result.querySelectorAll("[data-page]").forEach(button=>button.onclick=()=>load(Number(button.dataset.page)));
    }catch(error){
      if(seq!==requestSequence)return;
      result.innerHTML=empty("No fue posible consultar el inventario",error.message);
    }
  }

  async function loadSyncStatus(){
    const strip=root.querySelector("#material-master-strip");
    try{
      const history=await api.materialSyncHistory(5);
      const last=(history||[]).find(row=>row.status==="COMPLETED")||(history||[])[0];
      if(!last){strip.innerHTML='<div><strong>Maestro aún no sincronizado</strong><span>Ejecuta la migración V10.14 o carga el Excel oficial.</span></div>';return}
      const s=last.summary||{};
      strip.innerHTML=`<div><span>Materiales oficiales</span><strong>${fmt.number(s.materials||0)}</strong></div><div><span>Registros físicos</span><strong>${fmt.number(s.stockRows||0)}</strong></div><div><span>Variantes</span><strong>${fmt.number(s.variants||0)}</strong></div><div><span>Última sincronización</span><strong>${fmt.date(last.completedAt||last.createdAt)}</strong><small>${fmt.escape(last.fileName||"Siesa")}</small></div>`;
    }catch(error){strip.innerHTML=`<div><strong>Estado no disponible</strong><span>${fmt.escape(error.message)}</span></div>`}
  }

  function bindSelect(id,key){root.querySelector(id).addEventListener("change",event=>{filters[key]=event.currentTarget.value;load(1)})}
  bindSelect("#inv-unit","unit");bindSelect("#inv-warehouse","warehouse");bindSelect("#inv-stock","stock");bindSelect("#inv-type","itemType");bindSelect("#inv-variants","variants");bindSelect("#inv-sort","sort");
  root.querySelector("#inv-page-size").addEventListener("change",event=>{filters.pageSize=Number(event.currentTarget.value)||50;load(1)});
  searchInput.addEventListener("input",()=>{
    filters.search=searchInput.value.trim();searchClear.hidden=!filters.search;
    clearTimeout(searchTimer);searchTimer=setTimeout(()=>load(1,{quiet:true}),320);
  });
  searchInput.addEventListener("keydown",event=>{if(event.key==="Enter"){clearTimeout(searchTimer);load(1)}});
  searchClear.onclick=()=>{clearTimeout(searchTimer);searchInput.value="";filters.search="";searchClear.hidden=true;searchInput.focus();load(1)};
  filterToggle.onclick=()=>{const open=filterPanel.classList.toggle("is-open");filterToggle.setAttribute("aria-expanded",String(open))};
  root.querySelector("#inv-clear-filters").onclick=()=>{
    Object.assign(filters,{...DEFAULT_FILTERS,search:filters.search});
    root.querySelector("#inv-stock").value="";root.querySelector("#inv-type").value="";root.querySelector("#inv-variants").value="ALL";root.querySelector("#inv-sort").value="reference_asc";root.querySelector("#inv-page-size").value="50";
    load(1);
  };
  root.querySelector("#sync-siesa")?.addEventListener("click",()=>openSiesaSync(async()=>{await loadSyncStatus();await load(1)}));
  root.querySelector("#inventory-help").onclick=()=>guide({title:"Cómo navegar el inventario",description:"La lista usa exclusivamente materiales oficiales Siesa y todos los filtros se aplican en Supabase sobre el inventario completo.",items:[
    {title:"Busca por identidad o clasificación",detail:"Puedes escribir referencia, nombre, familia, marca o información contenida en los criterios Siesa."},
    {title:"Combina filtros",detail:"Unidad de medida, bodega, disponibilidad, tipo de material y presencia de variantes pueden utilizarse al mismo tiempo."},
    {title:"Disponible para venta",detail:"Es el disponible Siesa menos las reservas activas del ERP; por eso puede ser menor que la existencia física."},
    {title:"Abre solo lo necesario",detail:"Ver lotes / ajustar muestra los registros físicos de la referencia seleccionada sin perder la posición de la lista."}
  ]});

  await Promise.all([load(),loadSyncStatus()]);
}

function inventoryList(rows){
  return `<div class="inventory-list" role="table" aria-label="Materiales del inventario">
    <div class="inventory-list-head" role="row"><span>Material</span><span>Unidad</span><span>Existencia física</span><span>Reservado ERP</span><span>Disponible venta</span><span>Registros</span><span></span></div>
    <div class="inventory-list-body">${rows.map(item=>inventoryRow(item)).join("")}</div>
  </div>`;
}

function inventoryRow(item){
  const criteria=criteriaText(item);
  const atp=Number(item.availableToPromise??item.available??0);
  const physical=Number(item.physicalExistence??0);
  const reserved=Number(item.erpReserved||0);
  const lots=Number(item.lots||0);
  return `<article class="inventory-list-row" role="row">
    <div class="inventory-material-cell" role="cell">
      <div class="inventory-reference-line"><strong>${fmt.escape(item.reference||item.sku||"—")}</strong><span class="official-source-badge">SIESA</span>${Number(item.variantCount||0)>0?`<span class="inventory-mini-badge">${fmt.number(item.variantCount)} variante${Number(item.variantCount)===1?"":"s"}</span>`:""}</div>
      <h3>${fmt.escape(item.description||"Material sin nombre")}</h3>
      <div class="inventory-material-meta"><span>${fmt.escape(typeLabel(item.itemType))}</span><span>${fmt.escape(warehousesText(item))}</span>${criteria.map(text=>`<span>${fmt.escape(text)}</span>`).join("")}</div>
    </div>
    <div class="inventory-value-cell" role="cell"><small>Unidad</small><strong>${fmt.escape(item.unit||"UND")}</strong><span>${fmt.escape(unitLabel(item.unit).replace(/\s*\([^)]*\)$/,""))}</span></div>
    <div class="inventory-value-cell" role="cell"><small>Existencia física</small><strong>${fmt.number(physical,3)}</strong><span>${fmt.escape(item.unit||"UND")}</span></div>
    <div class="inventory-value-cell inventory-reserved-cell" role="cell"><small>Reservado ERP</small><strong>${fmt.number(reserved,3)}</strong><span>${reserved>0?"Reserva activa":"Sin reserva"}</span></div>
    <div class="inventory-value-cell inventory-atp-cell ${stockClass(atp)}" role="cell"><small>Disponible venta</small><strong>${fmt.number(atp,3)}</strong><span>${atp>0?"Disponible":"Sin disponible"}</span></div>
    <div class="inventory-value-cell" role="cell"><small>Registros</small><strong>${fmt.number(lots)}</strong><span>${Number(item.blocked||0)>0?`${fmt.number(item.blocked,3)} bloqueado`:Number(item.siesaCommitted||0)>0?`${fmt.number(item.siesaCommitted,3)} comprometido`:"Lotes / ubicaciones"}</span></div>
    <div class="inventory-row-action" role="cell"><button class="btn btn-primary" data-inventory-item="${item.id}">Ver lotes / ajustar</button></div>
  </article>`;
}

async function movementWizard(reload,preselectedId){
  const item=currentItems.find(x=>x.id===preselectedId);
  if(!item)return toast("Busca el material y abre su fila para registrar un movimiento.","error");
  const lots=await api.inventoryLots(item.id,"");
  if(!lots.length)return toast("Este material no tiene registros físicos activos.","error");

  const assistant=wizard({
    title:`Movimiento · ${item.reference}`,
    subtitle:`${item.description}. Solo se afectan lotes vinculados a esta identidad oficial.`,
    finishLabel:"Registrar movimiento",
    steps:[
      {title:"Seleccionar lote",description:"Elige la ubicación, lote, carreto o variante exacta.",content:`<div class="inventory-choice-grid official-lot-grid">${lots.map((lot,index)=>`<label class="inventory-choice official-lot-choice"><input type="radio" name="lotId" value="${lot.id}" ${index===0?"checked":""} required><span><strong>${fmt.escape(lot.variantLabel?`${lot.variantLabel} · ${lot.lotNumber||"Lote"}`:(lot.lotNumber||lot.serialNumber||"Lote"))}</strong><small>${fmt.escape([lot.warehouseCode,lot.location,lot.locationName,lot.serialNumber].filter(Boolean).join(" · ")||"Sin ubicación")}</small><b>Disponible: ${fmt.number(lot.available,3)} ${fmt.escape(lot.unit)}</b><em>${fmt.escape(lot.sourceSystem||"ERP")}</em></span></label>`).join("")}</div>`},
      {title:"Tipo y cantidad",description:"Registra el movimiento sin cambiar la identidad del material.",content:`<div class="wizard-choice-grid">${choice("movementType","ADJUSTMENT_IN","Ajuste de entrada","Aumenta la existencia por corrección.",true)}${choice("movementType","ADJUSTMENT_OUT","Ajuste de salida","Disminuye la existencia por corrección.")}${choice("movementType","ISSUE","Salida a operación","Entrega material a un proceso.")}${choice("movementType","RETURN","Devolución","Devuelve material disponible.")}${choice("movementType","SCRAP","Desperdicio","Registra pérdida o descarte.")}${choice("movementType","TRANSFER","Traslado","Mueve material entre ubicaciones.")}</div><div class="form-grid"><div class="field"><label>Cantidad *</label><input class="control" name="quantity" type="number" min="0.0001" step="any" required></div><div class="field"><label>Ubicación de origen</label><input class="control" name="fromLocation"></div><div class="field"><label>Ubicación de destino</label><input class="control" name="toLocation"></div><div class="field full"><label>Motivo / referencia *</label><input class="control" name="reference" required></div></div>`},
      {title:"Confirmar identidad",description:"El ERP volverá a validar referencia y nombre en Supabase antes de afectar la existencia.",content:`<section class="inventory-official-confirm"><span>SIESA</span><div><strong>${fmt.escape(item.reference)}</strong><h4>${fmt.escape(item.description)}</h4><p>${fmt.escape(item.unit)} · No se puede sustituir por un registro de prueba.</p></div></section><div class="wizard-summary"><div class="wizard-summary-item"><label>Lote</label><strong data-move-lot>—</strong></div><div class="wizard-summary-item"><label>Movimiento</label><strong data-move-type>—</strong></div><div class="wizard-summary-item"><label>Cantidad</label><strong data-move-quantity>—</strong></div></div>`,onEnter:({root,data})=>{const lot=lots.find(x=>x.id===data.lotId);root.querySelector("[data-move-lot]").textContent=lot?[lot.variantLabel,lot.lotNumber,lot.location].filter(Boolean).join(" · "):"—";root.querySelector("[data-move-type]").textContent=fmt.label(data.movementType);root.querySelector("[data-move-quantity]").textContent=`${data.quantity||"—"} ${item.unit}`}}
    ],
    onFinish:async({data})=>{await api.inventoryAdjust({...data,itemId:item.id});toast("Movimiento registrado sobre el material oficial.","success");await reload(currentPage)}
  });
  return assistant;
}

function openSiesaSync(onDone){
  const instance=modal({
    title:"Actualizar maestro oficial Siesa",
    size:"wide",
    confirmLabel:"Validar y actualizar",
    body:`<section class="siesa-sync-intro"><span>SIESA</span><div><strong>Actualización completa y transaccional</strong><p>Selecciona el Excel exportado desde Siesa. El catálogo actual no cambia hasta que todas las filas hayan sido validadas y aplicadas correctamente.</p></div></section>
      <label class="siesa-file-drop"><input type="file" accept=".xls,.xlsx,.csv,application/vnd.ms-excel,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" data-siesa-file required><span>Seleccionar archivo</span><strong data-siesa-file-name>Ningún archivo seleccionado</strong><small>Debe contener Referencia Item, Nombre Item, Unidad, Bodega, Ubicación, Lote y cantidades.</small></label>
      <section class="siesa-progress" data-siesa-progress hidden><div><span data-siesa-progress-label>Validando…</span><strong data-siesa-progress-value>0%</strong></div><progress max="100" value="0"></progress><p data-siesa-progress-detail></p></section>
      <div class="siesa-rules"><strong>Reglas de seguridad</strong><ul><li>Una referencia no puede tener dos nombres o unidades diferentes.</li><li>Cada fila física debe ser única por referencia, bodega, ubicación, lote y variante.</li><li>Los materiales ausentes del nuevo snapshot se desactivan, no se borran.</li><li>Los registros de prueba no vinculados al maestro quedan fuera del inventario operativo.</li></ul></div>`,
    onConfirm:async dialog=>{
      const file=dialog.querySelector("[data-siesa-file]").files?.[0];
      if(!file)throw new Error("Selecciona el archivo exportado de Siesa.");
      const progress=dialog.querySelector("[data-siesa-progress]");
      const bar=progress.querySelector("progress");
      const label=progress.querySelector("[data-siesa-progress-label]");
      const value=progress.querySelector("[data-siesa-progress-value]");
      const detail=progress.querySelector("[data-siesa-progress-detail]");
      progress.hidden=false;
      const result=await syncSiesaFile(file,state=>{
        const pct=Number(state.progress||0);bar.value=pct;value.textContent=`${pct}%`;
        label.textContent=state.phase==="validated"?"Archivo validado":state.phase==="upload"?"Enviando filas a Supabase":state.phase==="apply"?"Aplicando snapshot oficial":"Actualización terminada";
        detail.textContent=state.phase==="validated"?`${state.materials} materiales únicos · ${state.rows.length} registros físicos`:state.phase==="upload"?`${state.sent} de ${state.total} filas`:state.phase==="apply"?"Validando identidades, variantes, lotes y existencias…":"Maestro actualizado correctamente.";
      });
      const s=result.summary||result.result?.summary||{};
      toast(`Maestro Siesa actualizado: ${s.materials||result.parsed.materials} materiales y ${s.stockRows||result.parsed.rows.length} registros físicos.`,"success",8000);
      await onDone?.();
    }
  });
  const fileInput=instance.root.querySelector("[data-siesa-file]");
  fileInput.addEventListener("change",()=>{instance.root.querySelector("[data-siesa-file-name]").textContent=fileInput.files?.[0]?.name||"Ningún archivo seleccionado"});
}
