import {api} from "./api.js";
import {fmt} from "../core/format.js";

const SHEETJS_URL="https://cdn.sheetjs.com/xlsx-0.20.3/package/dist/xlsx.full.min.js";
let sheetPromise=null;

function safeText(value){return String(value??"").trim()}
function numberValue(value){
  if(value===null||value===undefined||value==="")return null;
  const n=Number(String(value).replace(",","."));
  return Number.isFinite(n)?n:null;
}
function normalizeUnit(value){
  const unit=safeText(value).toUpperCase();
  return unit||"UND";
}
function normalize(value){return safeText(value).replace(/\s+/g," ").toUpperCase()}
function sourceKey(row){return [row.reference,row.warehouse,row.location,row.lot,row.ext1||"",row.ext2||""].join("|")}

async function loadSheetJs(){
  if(window.XLSX)return window.XLSX;
  if(sheetPromise)return sheetPromise;
  sheetPromise=new Promise((resolve,reject)=>{
    const script=document.createElement("script");
    script.src=SHEETJS_URL;
    script.async=true;
    script.onload=()=>window.XLSX?resolve(window.XLSX):reject(new Error("El lector de Excel no quedó disponible."));
    script.onerror=()=>reject(new Error("No fue posible cargar el lector de Excel. Revisa la conexión e inténtalo nuevamente."));
    document.head.append(script);
  });
  return sheetPromise;
}

export function materialPickerHtml(initial={}){
  const ref=safeText(initial.reference||initial.sku);
  const name=safeText(initial.name||initial.description);
  const unit=safeText(initial.unit||"UND");
  const id=safeText(initial.materialMasterId||initial.material_master_id);
  const variantId=safeText(initial.materialVariantId||initial.material_variant_id);
  const variantLabel=safeText(initial.variantLabel||initial.variant_label||initial.metadata?.variantLabel);
  const selected=id||ref;
  return `<div class="material-picker ${selected?"selected":""}" data-material-picker
    data-material-id="${fmt.escape(id)}" data-material-reference="${fmt.escape(ref)}"
    data-material-name="${fmt.escape(name)}" data-material-unit="${fmt.escape(unit)}"
    data-material-variant-id="${fmt.escape(variantId)}" data-material-variant-label="${fmt.escape(variantLabel)}">
    <label class="material-search-label"><span>Material oficial Siesa</span>
      <input class="control material-search-input" data-material-query autocomplete="off"
        placeholder="Referencia, nombre, familia o marca"
        value="${selected?fmt.escape(`${ref} · ${name}`):""}">
    </label>
    <div class="material-search-results" data-material-results hidden></div>
    <div class="material-selected-card" data-material-selected ${selected?"":"hidden"}>
      <div class="material-selected-identity"><span data-material-reference-label>${fmt.escape(ref||"—")}</span><strong data-material-name-label>${fmt.escape(name||"Material sin resolver")}</strong></div>
      <div class="material-selected-meta">
        <span data-material-unit-label>${fmt.escape(unit)}</span>
        <span class="stock-physical" data-material-physical-label>Físico: —</span>
        <span class="stock-reserved" data-material-reserved-label>Reservado ERP: —</span>
        <span class="stock-atp" data-material-stock-label>Disponible venta: —</span>
      </div>
    </div>
    <div class="material-variant-field" data-material-variant-wrap ${variantLabel?"":"hidden"}>
      <label>Color / variante<select class="control" data-material-variant><option value="${fmt.escape(variantId)}">${fmt.escape(variantLabel||"Selecciona")}</option></select></label>
    </div>
  </div>`;
}

function stockSnapshot(material,variantId=null){
  const variants=Array.isArray(material?.variants)?material.variants:[];
  const variant=variantId?variants.find(v=>v.id===variantId):null;
  return {
    physical:Number(variant?.physicalAvailable??material?.physicalAvailable??0),
    reserved:Number(variant?.erpReserved??material?.erpReserved??0),
    available:Number(variant?.availableToPromise??material?.availableToPromise??material?.available??0)
  };
}

function updateStockLabels(container){
  const material=container.__material;
  if(!material)return;
  const stock=stockSnapshot(material,container.dataset.materialVariantId||null);
  const unit=material.unit||"UND";
  const fmtStock=value=>Number(value||0).toLocaleString("es-CO",{maximumFractionDigits:3});
  const physical=container.querySelector("[data-material-physical-label]");
  const reserved=container.querySelector("[data-material-reserved-label]");
  const atp=container.querySelector("[data-material-stock-label]");
  if(physical)physical.textContent=`Físico: ${fmtStock(stock.physical)} ${unit}`;
  if(reserved)reserved.textContent=`Reservado ERP: ${fmtStock(stock.reserved)} ${unit}`;
  if(atp){atp.textContent=`Disponible venta: ${fmtStock(stock.available)} ${unit}`;atp.classList.toggle("is-empty",stock.available<=0)}
  container.dataset.materialPhysical=String(stock.physical);
  container.dataset.materialReserved=String(stock.reserved);
  container.dataset.materialAtp=String(stock.available);
}

function displayMaterial(container,material,preferredVariantId=null){
  container.__material=material;
  container.dataset.materialId=material.id||"";
  container.dataset.materialReference=material.reference||"";
  container.dataset.materialName=material.name||"";
  container.dataset.materialUnit=material.unit||"UND";
  const query=container.querySelector("[data-material-query]");
  if(query)query.value=`${material.reference} · ${material.name}`;
  const selected=container.querySelector("[data-material-selected]");
  if(selected)selected.hidden=false;
  container.classList.add("selected");
  container.querySelector("[data-material-reference-label]").textContent=material.reference||"—";
  container.querySelector("[data-material-name-label]").textContent=material.name||"—";
  container.querySelector("[data-material-unit-label]").textContent=material.unit||"UND";
  const variants=Array.isArray(material.variants)?material.variants:[];
  const wrap=container.querySelector("[data-material-variant-wrap]");
  const select=container.querySelector("[data-material-variant]");
  container.dataset.variantRequired=variants.length>1?"true":"false";
  if(!variants.length){
    wrap.hidden=true;
    select.innerHTML='<option value="">Sin variante</option>';
    container.dataset.materialVariantId="";
    container.dataset.materialVariantLabel="";
  }else{
    wrap.hidden=false;
    select.innerHTML=`<option value="">${variants.length>1?"Selecciona color / variante":"Variante"}</option>${variants.map(v=>`<option value="${fmt.escape(v.id)}" data-label="${fmt.escape(v.label)}">${fmt.escape(v.label)} · disp. ${Number(v.availableToPromise??v.available??0).toLocaleString("es-CO",{maximumFractionDigits:3})}</option>`).join("")}`;
    let target=preferredVariantId||container.dataset.materialVariantId||"";
    if(!target&&variants.length===1)target=variants[0].id;
    if(target&&variants.some(v=>v.id===target))select.value=target;
    else select.value="";
    const option=select.selectedOptions[0];
    container.dataset.materialVariantId=select.value||"";
    container.dataset.materialVariantLabel=select.value?(option?.dataset.label||option?.textContent?.split(" · ")[0]||""):"";
  }
  updateStockLabels(container);
  container.dispatchEvent(new CustomEvent("material:selected",{bubbles:true,detail:readMaterialPicker(container,false)}));
}

async function hydrateInitial(container){
  const id=container.dataset.materialId;
  const reference=container.dataset.materialReference;
  if(!id&&!reference)return;
  try{
    const results=await api.materialSearch(reference||"",20);
    const match=(results||[]).find(item=>item.id===id)||(results||[]).find(item=>item.reference===reference);
    if(match)displayMaterial(container,match,container.dataset.materialVariantId||null);
  }catch(error){console.warn("No fue posible hidratar material oficial",error)}
}

export function bindMaterialPicker(container,{onChange}={}){
  if(!container||container.dataset.materialBound==="1")return;
  container.dataset.materialBound="1";
  const query=container.querySelector("[data-material-query]");
  const results=container.querySelector("[data-material-results]");
  const variant=container.querySelector("[data-material-variant]");
  let timer=null,seq=0;
  const hide=()=>{results.hidden=true;results.innerHTML=""};
  const search=async()=>{
    const text=query.value.trim();
    if(text.length<2){hide();return}
    const request=++seq;
    results.hidden=false;
    results.innerHTML='<div class="material-search-loading">Buscando en el maestro oficial…</div>';
    try{
      const items=await api.materialSearch(text,15);
      if(request!==seq)return;
      results.innerHTML=items.length?items.map(item=>`<button type="button" class="material-result" data-material-result="${fmt.escape(item.id)}">
        <span class="material-result-ref">${fmt.escape(item.reference)}</span>
        <strong>${fmt.escape(item.name)}</strong>
        <small>${fmt.escape(item.unit)}${item.variants?.length?` · ${item.variants.length} variante(s)`:""}</small>
        <div class="material-result-stock"><b>Disponible venta ${Number(item.availableToPromise??item.available??0).toLocaleString("es-CO",{maximumFractionDigits:3})}</b><em>Físico ${Number(item.physicalAvailable||0).toLocaleString("es-CO",{maximumFractionDigits:3})}</em><em>Reservado ERP ${Number(item.erpReserved||0).toLocaleString("es-CO",{maximumFractionDigits:3})}</em></div>
      </button>`).join(""):'<div class="material-search-empty">No existe una coincidencia oficial. Revisa la referencia o el nombre.</div>';
      results.querySelectorAll("[data-material-result]").forEach(button=>button.addEventListener("click",()=>{
        const item=items.find(x=>x.id===button.dataset.materialResult);
        if(!item)return;
        displayMaterial(container,item,null);hide();onChange?.(readMaterialPicker(container,false));
      }));
    }catch(error){results.innerHTML=`<div class="material-search-empty">${fmt.escape(error.message)}</div>`}
  };
  query.addEventListener("input",()=>{
    // Editar el texto después de una selección obliga a volver a escoger el material.
    if(container.__material&&query.value!==`${container.__material.reference} · ${container.__material.name}`){
      container.__material=null;
      container.dataset.materialId="";
      container.dataset.materialReference="";
      container.dataset.materialName="";
      container.dataset.materialVariantId="";
      container.dataset.materialVariantLabel="";
      container.querySelector("[data-material-selected]").hidden=true;
      container.querySelector("[data-material-variant-wrap]").hidden=true;
      container.classList.remove("selected");
      onChange?.(readMaterialPicker(container,false));
    }
    clearTimeout(timer);timer=setTimeout(search,220);
  });
  query.addEventListener("focus",()=>{if(query.value.trim().length>=2&&!container.__material){clearTimeout(timer);timer=setTimeout(search,80)}});
  query.addEventListener("keydown",event=>{if(event.key==="Escape")hide()});
  variant.addEventListener("change",()=>{
    const option=variant.selectedOptions[0];
    container.dataset.materialVariantId=variant.value||"";
    container.dataset.materialVariantLabel=variant.value?(option?.dataset.label||option?.textContent?.split(" · ")[0]||""):"";
    updateStockLabels(container);
    onChange?.(readMaterialPicker(container,false));
  });
  container.addEventListener("focusout",()=>setTimeout(()=>{if(!container.contains(document.activeElement))hide()},0));
  hydrateInitial(container);
}

export function readMaterialPicker(container,strict=true){
  const result={
    materialMasterId:container?.dataset.materialId||null,
    materialVariantId:container?.dataset.materialVariantId||null,
    variantLabel:container?.dataset.materialVariantLabel||null,
    reference:container?.dataset.materialReference||null,
    sku:container?.dataset.materialReference||null,
    description:container?.dataset.materialName||null,
    unit:container?.dataset.materialUnit||"UND",
    physicalAvailable:Number(container?.dataset.materialPhysical||0),
    erpReserved:Number(container?.dataset.materialReserved||0),
    availableToPromise:Number(container?.dataset.materialAtp||0)
  };
  if(strict&&!result.materialMasterId)throw new Error("Selecciona el material desde el maestro oficial Siesa.");
  if(strict&&container?.dataset.variantRequired==="true"&&!result.materialVariantId)throw new Error(`Selecciona el color o variante de ${result.reference||"la referencia"}.`);
  return result;
}

export function applyResolvedMaterial(line,resolution){
  if(!resolution||resolution.status==="NOT_FOUND")return {...line,materialResolution:"NOT_FOUND"};
  const material=resolution.material||{};
  return {...line,
    materialMasterId:material.id||null,materialVariantId:resolution.materialVariantId||null,
    variantLabel:resolution.variantLabel||null,variantOptions:resolution.variants||[],
    reference:material.reference||line.reference,sku:material.reference||line.sku,
    description:material.name||line.description,unit:material.unit||line.unit||"UND",
    materialResolution:resolution.status
  };
}

export async function resolveMaterialLines(lines){
  const resolutions=await api.materialResolve((lines||[]).map(line=>({
    materialMasterId:line.materialMasterId||line.material_master_id||null,
    materialVariantId:line.materialVariantId||line.material_variant_id||null,
    variantLabel:line.variantLabel||line.variant_label||line.color||null,
    reference:line.reference||null,sku:line.sku||null,description:line.description||null
  })));
  return (lines||[]).map((line,index)=>applyResolvedMaterial(line,(resolutions||[]).find(item=>Number(item.index)===index)));
}

function findHeaders(rows){
  const required=["Referencia Item","Nombre Item","Unidad_inventario Item","Bodega","Ubicacion","Lote","Cantidad_existencia_1","Cantidad_comprometida_1","Cantidad_disponible_1"];
  const index=rows.findIndex(row=>required.every(header=>row.map(safeText).includes(header)));
  if(index<0)throw new Error("No encontré la fila de encabezados de Siesa. Deben existir Referencia Item, Nombre Item, Unidad_inventario Item, Bodega, Ubicacion, Lote y cantidades.");
  const map=new Map(rows[index].map((value,i)=>[safeText(value),i]));
  return {index,map,required};
}

function cell(row,map,name){const i=map.get(name);return i===undefined?null:row[i]}
function dateText(value){
  if(value===null||value===undefined||value==="")return null;
  if(value instanceof Date)return value.toISOString().slice(0,10);
  if(typeof value==="number"&&value>20000&&value<80000){
    const date=new Date(Date.UTC(1899,11,30)+Math.round(value)*86400000);
    return Number.isNaN(date.getTime())?safeText(value):date.toISOString().slice(0,10);
  }
  const text=safeText(value);
  if(/^\d{8}$/.test(text))return `${text.slice(0,4)}-${text.slice(4,6)}-${text.slice(6,8)}`;
  return text||null;
}

export async function parseSiesaFile(file){
  if(!file)throw new Error("Selecciona el archivo de Siesa.");
  const buffer=await file.arrayBuffer();
  const digest=await crypto.subtle.digest("SHA-256",buffer);
  const sha256=[...new Uint8Array(digest)].map(b=>b.toString(16).padStart(2,"0")).join("");
  const XLSX=await loadSheetJs();
  const book=XLSX.read(buffer,{type:"array",cellDates:false});
  const first=book.Sheets[book.SheetNames[0]];
  if(!first)throw new Error("El archivo no contiene hojas legibles.");
  const rows=XLSX.utils.sheet_to_json(first,{header:1,raw:true,defval:null,blankrows:false});
  const {index,map}=findHeaders(rows);
  const result=[];
  const refs=new Map();
  const sourceKeys=new Set();
  for(let i=index+1;i<rows.length;i++){
    const row=rows[i];
    const reference=safeText(cell(row,map,"Referencia Item"));
    const name=safeText(cell(row,map,"Nombre Item"));
    if(!reference&&!name)continue;
    const unit=normalizeUnit(cell(row,map,"Unidad_inventario Item"));
    const warehouse=safeText(cell(row,map,"Bodega"));
    const location=safeText(cell(row,map,"Ubicacion"));
    const lot=safeText(cell(row,map,"Lote"));
    if(!reference||!name||!unit||!warehouse||!location)throw new Error(`Fila ${i+1}: faltan referencia, nombre, unidad, bodega o ubicación.`);
    const criteria=[];
    for(let n=1;n<=5;n++){
      const code=safeText(cell(row,map,`Criterio_Item${n} Item`))||null;
      const cname=safeText(cell(row,map,`Desc_Item${n} Item`))||null;
      if(code||cname)criteria.push({code,name:cname});
    }
    const normalized={name:normalize(name),unit};
    if(refs.has(reference)){
      const prev=refs.get(reference);
      if(prev.name!==normalized.name||prev.unit!==normalized.unit)throw new Error(`Referencia ${reference}: el archivo trae nombres o unidades diferentes para la misma referencia.`);
    }else refs.set(reference,normalized);
    const item={
      sourceRow:i+1,reference,name,unit,weight:numberValue(cell(row,map,"Peso Item")),
      ext1:safeText(cell(row,map,"Desc_ext1 Item"))||null,ext2:safeText(cell(row,map,"Desc_ext2 Item"))||null,criteria,
      warehouse,location,locationName:safeText(cell(row,map,"Nombre Ubicacion"))||null,lot,
      abcCost:safeText(cell(row,map,"ABC_rotacion_costo"))||null,abcTurns:safeText(cell(row,map,"ABC_rotacion_veces"))||null,
      dates:{
        lastCount:dateText(cell(row,map,"Fecha_ult_conteo")),lastPurchase:dateText(cell(row,map,"Fecha_ult_compra")),
        lastSale:dateText(cell(row,map,"Fecha_ult_venta")),lastEntry:dateText(cell(row,map,"Fecha_ult_entrada")),
        lastExit:dateText(cell(row,map,"Fecha_ult_salida")),lastConsumption:dateText(cell(row,map,"Fecha_ult_consumo_prom"))
      },
      avgCostUnit:numberValue(cell(row,map,"Costo_prom_uni")),avgCostTotal:numberValue(cell(row,map,"Costo_prom_tot")),
      lastCostUnit:numberValue(cell(row,map,"Ultimo_costo_uni")),lastCostTotal:numberValue(cell(row,map,"Ultimo_costo_tot")),
      existence:numberValue(cell(row,map,"Cantidad_existencia_1"))||0,committed:numberValue(cell(row,map,"Cantidad_comprometida_1"))||0,
      available:numberValue(cell(row,map,"Cantidad_disponible_1"))||0,avgConsumption:numberValue(cell(row,map,"Consumo_promedio"))||0
    };
    item.sourceKey=sourceKey(item);
    if(sourceKeys.has(item.sourceKey))throw new Error(`Fila ${i+1}: existe una fila física duplicada para ${reference}.`);
    sourceKeys.add(item.sourceKey);
    result.push(item);
  }
  if(!result.length)throw new Error("El archivo no contiene materiales.");
  return {rows:result,materials:refs.size,sha256,sheetName:book.SheetNames[0],headerRow:index+1};
}

export async function syncSiesaFile(file,onProgress=()=>{}){
  const parsed=await parseSiesaFile(file);
  onProgress({phase:"validated",progress:8,...parsed});
  const start=await api.materialSyncBegin(file.name,parsed.sha256,parsed.rows.length);
  const batchId=start.batchId;
  const chunk=150;
  for(let offset=0;offset<parsed.rows.length;offset+=chunk){
    const slice=parsed.rows.slice(offset,offset+chunk);
    await api.materialSyncAppend(batchId,slice);
    onProgress({phase:"upload",progress:8+Math.round(((offset+slice.length)/parsed.rows.length)*82),sent:offset+slice.length,total:parsed.rows.length});
  }
  onProgress({phase:"apply",progress:94});
  const result=await api.materialSyncFinish(batchId);
  onProgress({phase:"done",progress:100,result});
  return {...result,parsed};
}
