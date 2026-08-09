import {api} from "../services/api.js";
import {fmt,statusBadge,priorityBadge} from "../core/format.js";
import {loading,empty,toast,modal} from "../core/ui.js";
import {navigate} from "../core/router.js";
import {hasRole} from "../core/state.js";
import {openOrder} from "./orders.js";
import {moduleForStep} from "./active-work.js";

const SCENARIOS=[
  {code:"FLOW",label:"Flujo completo",step:"RECEPCION_PEDIDO",type:"PVC",description:"Pedido estándar para recorrer Recepción → Alistamiento → Facturación → Despacho."},
  {code:"CARTERA",label:"Cartera",step:"CARTERA",type:"PVC",description:"Pedido de crédito detenido en Cartera."},
  {code:"CAJA",label:"Caja",step:"CAJA",type:"PVN",description:"PVN retenido para probar la gestión financiera."},
  {code:"COMPRAS",label:"Compras PVE",step:"COMPRAS",type:"PVE",description:"Pedido especial listo para probar Compras y seguimiento de Recepción."},
  {code:"RECEPCION",label:"Recepción",step:"RECEPCION_PEDIDO",type:"PVC",description:"Pedido directamente en Recepción de pedidos."},
  {code:"ALISTAMIENTO",label:"Alistamiento",step:"ALISTAMIENTO",type:"PVC",description:"Materiales ficticios sin Siesa, listos para verificar."},
  {code:"CORTE",label:"Corte",step:"ALISTAMIENTO",type:"PVC",cut:true,description:"Incluye material métrico ficticio para probar Corte sin inventario real."},
  {code:"FACTURACION",label:"Facturación",step:"FACTURACION",type:"PVC",description:"Permite probar factura con archivo simulado, sin Drive."},
  {code:"CAJA_FACTURACION",label:"Caja · factura PVN",step:"CAJA_FACTURACION",type:"PVN",description:"Factura de contado en Caja, completamente aislada."},
  {code:"DESPACHO",label:"Despacho",step:"LOCAL_DISPATCH",type:"PVC",description:"Guía, cierre y evidencia sin tocar Drive productivo."},
  {code:"CIERRE",label:"Cierre",step:"CLOSURE",type:"PVC",description:"Prueba directa de la foto final y cierre del pedido."}
];
const STEPS=["CARTERA","CAJA","COMPRAS","RECEPCION_MERCANCIA","RECEPCION_PEDIDO","ALISTAMIENTO","FACTURACION","CAJA_FACTURACION","CLIENT_POINT","CLIENT_PICKUP","LOCAL_DISPATCH","NATIONAL_DISPATCH","CLOSURE"];

export async function renderSandbox(root){
  if(!hasRole("super_admin")){root.innerHTML=`<section class="card card-pad"><h3>Acceso restringido</h3><p>El Bot de pruebas solo está disponible para Superadministración.</p></section>`;return}
  root.innerHTML=`
    <section class="sandbox-hero"><div><span>ENTORNO AISLADO</span><h2>Bot de pedidos de prueba</h2><p>Crea pedidos ficticios, muévelos entre módulos y elimínalos sin tocar Siesa, inventario, reservas, Drive, SLA, VSM ni indicadores productivos.</p></div><div class="sandbox-shield"><strong>SUPER ADMIN</strong><small>Producción protegida</small></div></section>
    <section class="sandbox-layout">
      <article class="card card-pad sandbox-builder"><header><div><span class="sandbox-eyebrow">Nuevo escenario</span><h3>¿Qué quieres probar?</h3><p>El pedido usará materiales sintéticos TEST y quedará visible únicamente dentro del Sandbox.</p></div></header>
        <div class="sandbox-scenario-grid">${SCENARIOS.map(s=>`<button type="button" class="sandbox-scenario ${s.code==="FLOW"?"selected":""}" data-scenario="${s.code}"><strong>${fmt.escape(s.label)}</strong><span>${fmt.escape(s.description)}</span><small>${fmt.escape(s.step==="ALISTAMIENTO"&&s.cut?"Corte paralelo":fmt.step(s.step))}</small></button>`).join("")}</div>
        <div class="sandbox-create-row"><label>Cantidad de pedidos<select class="control" id="sandbox-count">${[1,2,3,5,10].map(n=>`<option value="${n}">${n}</option>`).join("")}</select></label><label>Prioridad<select class="control" id="sandbox-priority"><option>MEDIUM</option><option>HIGH</option><option>URGENT</option><option>CRITICAL</option><option>LOW</option></select></label><button class="btn btn-primary btn-large" id="sandbox-create">Crear pedido(s) de prueba</button></div>
      </article>
      <article class="card card-pad sandbox-rules"><span class="sandbox-eyebrow">Garantías</span><h3>Nada productivo se modifica</h3><ul><li>No usa materiales del Excel Siesa.</li><li>No reserva ni descuenta existencias.</li><li>No sube archivos a Google Drive.</li><li>No aparece en colas, Dashboard, VSM, SLA, Reportes ni Auditoría productivos.</li><li>Solo Superadministración puede abrirlo o manipularlo.</li></ul></article>
    </section>
    <section class="card card-pad sandbox-orders"><header class="sandbox-list-head"><div><span class="sandbox-eyebrow">Laboratorio activo</span><h3>Pedidos de prueba</h3><p>Puedes abrir el popup real del módulo o mover el pedido instantáneamente a otra etapa.</p></div><div><button class="btn btn-ghost" id="sandbox-refresh">Actualizar</button><button class="btn btn-danger" id="sandbox-clear">Eliminar todas las pruebas</button></div></header><div class="sandbox-filter"><input class="control search-wide" id="sandbox-search" placeholder="Buscar TEST o cliente ficticio"><button class="btn btn-primary" id="sandbox-search-btn">Buscar</button></div><div id="sandbox-result">${loading("Consultando Sandbox…")}</div></section>`;
  let scenario="FLOW";
  root.querySelectorAll("[data-scenario]").forEach(btn=>btn.onclick=()=>{scenario=btn.dataset.scenario;root.querySelectorAll("[data-scenario]").forEach(x=>x.classList.toggle("selected",x===btn))});
  root.querySelector("#sandbox-create").onclick=async()=>{const button=root.querySelector("#sandbox-create");button.disabled=true;try{const item=SCENARIOS.find(x=>x.code===scenario);const result=await api.sandboxCreate({scenario,count:Number(root.querySelector("#sandbox-count").value),priority:root.querySelector("#sandbox-priority").value,stepCode:item.step,orderType:item.type,requiresCut:Boolean(item.cut)});toast(`${result.created} pedido(s) de prueba creados.`,"success",6000);await load(root)}catch(e){toast(e.message,"error",8000)}finally{button.disabled=false}};
  root.querySelector("#sandbox-refresh").onclick=()=>load(root);
  root.querySelector("#sandbox-search-btn").onclick=()=>load(root);
  root.querySelector("#sandbox-search").onkeydown=e=>{if(e.key==="Enter")load(root)};
  root.querySelector("#sandbox-clear").onclick=()=>confirmClear(root);
  await load(root);
}

async function load(root){const target=root.querySelector("#sandbox-result");if(!target)return;target.innerHTML=loading("Consultando pedidos de prueba…");try{const data=await api.sandboxOrders({search:root.querySelector("#sandbox-search")?.value.trim()||"",page:1,pageSize:100});const rows=data.items||[];target.innerHTML=rows.length?`<div class="sandbox-order-grid">${rows.map(orderCard).join("")}</div>`:empty("Sandbox vacío","Crea un escenario para comenzar a probar los módulos.");target.querySelectorAll("[data-sb-open]").forEach(b=>b.onclick=()=>openOrder(b.dataset.sbOpen));target.querySelectorAll("[data-sb-module]").forEach(b=>{b.onclick=()=>{const row=rows.find(r=>r.id===b.dataset.sbModule);if(row)navigate(moduleForStep(row.currentStep),{sandbox:"1",step:row.currentStep})}});target.querySelectorAll("[data-sb-move]").forEach(b=>b.onclick=()=>moveDialog(rows.find(r=>r.id===b.dataset.sbMove),()=>load(root)));target.querySelectorAll("[data-sb-delete]").forEach(b=>b.onclick=()=>deleteOne(rows.find(r=>r.id===b.dataset.sbDelete),()=>load(root)))}catch(e){target.innerHTML=`<div class="module-error"><strong>No fue posible cargar el Sandbox</strong><p>${fmt.escape(e.message)}</p></div>`}}
function orderCard(o){return `<article class="sandbox-order-card"><header><div><span>PRUEBA AISLADA</span><strong>${fmt.escape(o.orderNumber)}</strong></div>${priorityBadge(o.priority)}</header><h4>${fmt.escape(o.clientName)}</h4><div class="sandbox-order-state"><div><small>Escenario</small><strong>${fmt.escape(o.scenario||"Manual")}</strong></div><div><small>Etapa</small><strong>${fmt.escape(fmt.step(o.currentStep))}</strong></div><div><small>Estado</small>${statusBadge(o.status)}</div></div><footer><button class="btn btn-primary btn-compact" data-sb-open="${o.id}">Abrir popup</button><button class="btn btn-ghost btn-compact" data-sb-module="${o.id}">Abrir módulo</button><button class="btn btn-ghost btn-compact" data-sb-move="${o.id}">Mover etapa</button><button class="btn btn-danger btn-compact" data-sb-delete="${o.id}">Eliminar</button></footer></article>`}
function moveDialog(order,onDone){if(!order)return;modal({title:`Mover ${order.orderNumber}`,confirmLabel:"Mover pedido",size:"wide",body:`<div class="sandbox-modal-warning"><strong>Solo afecta este pedido TEST</strong><p>La etapa anterior se cierra técnicamente y se crea una nueva tarea asignada a Superadministración.</p></div><div class="field"><label>Nueva etapa</label><select class="control" name="step">${STEPS.map(s=>`<option value="${s}" ${s===order.currentStep?"selected":""}>${fmt.escape(fmt.step(s))}</option>`).join("")}</select></div>`,onConfirm:async d=>{await api.sandboxMove(order.id,d.querySelector('[name="step"]').value);toast("Pedido de prueba movido.","success");onDone?.()}})}
function deleteOne(order,onDone){if(!order)return;modal({title:"Eliminar pedido de prueba",confirmLabel:"Eliminar definitivamente",cancelLabel:"Cancelar",body:`<div class="sandbox-modal-warning danger"><strong>${fmt.escape(order.orderNumber)}</strong><p>Se eliminará únicamente este pedido sandbox y todos sus registros dependientes. Producción no se toca.</p></div>`,onConfirm:async()=>{await api.sandboxDelete(order.id);toast("Pedido de prueba eliminado.","success");onDone?.()}})}
function confirmClear(root){modal({title:"Vaciar Sandbox",confirmLabel:"Eliminar todas las pruebas",cancelLabel:"Cancelar",body:`<div class="sandbox-modal-warning danger"><strong>Esta limpieza solo busca pedidos manuales de Sandbox</strong><p>No elimina pedidos QA automáticos ni pedidos productivos.</p></div>`,onConfirm:async()=>{const result=await api.sandboxClear();toast(`${result.deleted} pedido(s) sandbox eliminados.`,"success");await load(root)}})}
