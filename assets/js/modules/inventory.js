import {api} from "../services/api.js";
import {fmt} from "../core/format.js";
import {can} from "../core/state.js";
import {empty,loading,paginationHtml,wizard,toast,actionCards,guide,modal} from "../core/ui.js";
import {workspaceIntro,choice} from "../core/guided.js";
import {syncSiesaFile} from "../services/materials.js";

let currentItems=[];
let currentPage=1;

export async function renderInventory(root){
  const canUpdate=can("inventory","canUpdate");
  root.innerHTML=`
    <section class="page-head"><div><h2>Maestro de materiales e inventario</h2><p>Una sola fuente de verdad para Ventas, Recepción, Inventario y Corte. Solo se muestran materiales oficiales vinculados a Siesa.</p></div><div class="page-actions">${canUpdate?'<button class="btn btn-primary" id="sync-siesa">Actualizar maestro Siesa</button>':""}<button class="btn btn-ghost" id="inventory-help">Ver guía</button></div></section>
    ${workspaceIntro({title:"Inventario oficial",description:"Referencia y nombre se protegen con el maestro Siesa. Los registros de prueba quedan fuera de esta operación sin borrar su historial.",cards:actionCards([
      {id:"search-inventory",title:"Buscar material oficial",description:"Busca por referencia, nombre, familia o marca.",icon:"⌕",tone:"primary"},
      {id:"inventory-source",title:"Fuente Siesa",description:"Consulta la última actualización y el número de materiales cargados.",icon:"✓",tone:"success"},
      {id:"low-stock",title:"Menor disponibilidad",description:"Ordena los resultados visibles por existencia disponible.",icon:"!",tone:"warning"}
    ])})}
    <section class="material-master-strip" id="material-master-strip">${loading("Consultando estado del maestro…")}</section>
    <section class="card card-pad">
      <div class="toolbar"><input class="control search-wide" id="inv-search" placeholder="Referencia, material, familia o marca"><button class="btn btn-primary" id="inv-filter">Buscar</button></div>
      <div class="selection-hint"><strong>Catálogo operacional</strong><span>Los movimientos manuales solo se permiten cuando la referencia y el nombre corresponden al maestro oficial.</span></div>
      <div id="inv-result">${loading()}</div>
    </section>`;

  async function load(page=1){
    currentPage=page;
    const target=root.querySelector("#inv-result");
    target.innerHTML=loading("Consultando inventario oficial…");
    const data=await api.inventory(root.querySelector("#inv-search").value,page,50);
    currentItems=data.items||[];
    target.innerHTML=currentItems.length?`${cards(currentItems)}${paginationHtml(data.pagination)}`:empty("Sin coincidencias oficiales","Ajusta la búsqueda o actualiza el maestro Siesa.");
    target.querySelectorAll("[data-inventory-item]").forEach(button=>button.onclick=()=>movementWizard(load,button.dataset.inventoryItem));
    target.querySelectorAll("[data-page]").forEach(button=>button.onclick=()=>load(Number(button.dataset.page)));
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

  root.querySelector("#inv-filter").onclick=()=>load(1);
  root.querySelector("#inv-search").onkeydown=event=>{if(event.key==="Enter")load(1)};
  root.querySelector("#search-inventory").onclick=()=>root.querySelector("#inv-search").focus();
  root.querySelector("#inventory-source").onclick=loadSyncStatus;
  root.querySelector("#low-stock").onclick=()=>{currentItems.sort((a,b)=>Number(a.available)-Number(b.available));root.querySelector("#inv-result").innerHTML=cards(currentItems)};
  root.querySelector("#sync-siesa")?.addEventListener("click",()=>openSiesaSync(async()=>{await loadSyncStatus();await load(1)}));
  root.querySelector("#inventory-help").onclick=()=>guide({title:"Maestro Siesa e inventario",description:"La referencia y el nombre son la identidad oficial del material.",items:[
    {title:"Ventas selecciona, no escribe",detail:"Los asesores buscan materiales en este mismo maestro."},
    {title:"Inventario conserva ubicación y lote",detail:"Cada fila física de Siesa se mantiene separada por bodega, ubicación, lote y variante."},
    {title:"Pruebas fuera de operación",detail:"Los registros no vinculados al maestro no aparecen en el inventario normal."},
    {title:"Corte usa material y variante exactos",detail:"Un carreto solo se ofrece si pertenece a la misma referencia y, cuando aplique, al mismo color o variante."}
  ]});
  await Promise.all([load(),loadSyncStatus()]);
}

function cards(rows){
  return `<div class="inventory-grid official-inventory-grid">${rows.map(item=>`<article class="inventory-card official-inventory-card">
    <header><div><strong>${fmt.escape(item.reference)}</strong><span class="official-source-badge">SIESA</span></div><span class="badge badge-blue">${fmt.escape(item.unit)}</span></header>
    <div class="inventory-card-body"><h3>${fmt.escape(item.description)}</h3>
      <div class="inventory-numbers"><div><label>Disponible</label><strong class="success">${fmt.number(item.available,3)}</strong></div><div><label>Comprometido</label><strong>${fmt.number(item.reserved,3)}</strong></div><div><label>Bloqueado</label><strong class="warning">${fmt.number(item.blocked,3)}</strong></div><div><label>Registros físicos</label><strong>${fmt.number(item.lots)}</strong></div></div>
      ${Number(item.variantCount||0)>0?`<p class="inventory-variant-note">${fmt.number(item.variantCount)} variante(s) con existencia física separada.</p>`:""}
    </div>
    <footer><span>Referencia y nombre validados</span><button class="btn btn-primary" data-inventory-item="${item.id}">Ver lotes / ajustar</button></footer>
  </article>`).join("")}</div>`;
}

async function movementWizard(reload,preselectedId){
  const item=currentItems.find(x=>x.id===preselectedId);
  if(!item)return toast("Busca el material y abre su tarjeta para registrar un movimiento.","error");
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
