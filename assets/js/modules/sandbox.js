import {api} from "../services/api.js";
import {fmt,statusBadge,priorityBadge} from "../core/format.js";
import {loading,empty,toast,modal} from "../core/ui.js";
import {navigate} from "../core/router.js";
import {hasRole} from "../core/state.js";
import {openOrder} from "./orders.js";
import {moduleForStep} from "./active-work.js";

const SCENARIOS=[
  {code:"FLOW",label:"Flujo completo",step:"RECEPCION_PEDIDO",type:"PVC",description:"Pedido estándar para recorrer Recepción, Alistamiento, Facturación y Despacho.",tag:"Flujo integral"},
  {code:"CARTERA",label:"Cartera",step:"CARTERA",type:"PVC",description:"Pedido de crédito detenido en Cartera.",tag:"Financiero"},
  {code:"CAJA",label:"Caja",step:"CAJA",type:"PVN",description:"PVN retenido para probar la gestión financiera.",tag:"Financiero"},
  {code:"COMPRAS",label:"Compras PVE",step:"COMPRAS",type:"PVE",description:"Pedido especial listo para probar Compras y seguimiento de Recepción.",tag:"Abastecimiento"},
  {code:"RECEPCION",label:"Recepción",step:"RECEPCION_PEDIDO",type:"PVC",description:"Pedido directamente en Recepción de pedidos.",tag:"Recepción"},
  {code:"ALISTAMIENTO",label:"Alistamiento",step:"ALISTAMIENTO",type:"PVC",description:"Materiales ficticios sin Siesa, listos para verificar.",tag:"Logística"},
  {code:"CORTE",label:"Corte + Alistamiento",step:"ALISTAMIENTO",type:"PVC",cut:true,description:"Incluye material métrico ficticio para probar corte en paralelo con alistamiento.",tag:"Paralelo"},
  {code:"FACTURACION",label:"Facturación",step:"FACTURACION",type:"PVC",description:"Permite probar factura con archivo simulado, sin Drive.",tag:"Facturación"},
  {code:"CAJA_FACTURACION",label:"Caja · factura PVN",step:"CAJA_FACTURACION",type:"PVN",description:"Factura de contado en Caja, completamente aislada.",tag:"Financiero"},
  {code:"DESPACHO",label:"Despacho",step:"LOCAL_DISPATCH",type:"PVC",description:"Guía, cierre y evidencia sin tocar Drive productivo.",tag:"Despacho"},
  {code:"CIERRE",label:"Cierre",step:"CLOSURE",type:"PVC",description:"Prueba directa de la foto final y cierre del pedido.",tag:"Cierre"}
];

const STEPS=["CARTERA","CAJA","COMPRAS","RECEPCION_MERCANCIA","RECEPCION_PEDIDO","ALISTAMIENTO","FACTURACION","CAJA_FACTURACION","CLIENT_POINT","CLIENT_PICKUP","LOCAL_DISPATCH","NATIONAL_DISPATCH","CLOSURE"];

export async function renderSandbox(root){
  if(!hasRole("super_admin")){
    root.innerHTML=`<section class="card card-pad"><h3>Acceso restringido</h3><p>El Bot de pruebas solo está disponible para Superadministración.</p></section>`;
    return;
  }
  root.innerHTML=`
    <section class="lab-page">
      <header class="lab-head card">
        <div class="lab-head-main">
          <span class="lab-eyebrow">SANDBOX EXCLUSIVO · SUPER ADMIN</span>
          <h2>Laboratorio de pedidos de prueba</h2>
          <p>Genera pedidos ficticios, muévelos entre módulos y prueba los popups reales sin tocar Siesa, inventario, reservas, Drive, SLA ni reportes productivos.</p>
        </div>
        <div class="lab-head-badge">
          <strong>Entorno aislado</strong>
          <small>Producción protegida</small>
        </div>
      </header>

      <section class="lab-overview">
        <article class="lab-panel card">
          <div class="lab-panel-title">
            <span class="lab-eyebrow">CREADOR DE ESCENARIOS</span>
            <h3>¿Qué necesitas probar?</h3>
            <p>El pedido se crea con materiales sintéticos TEST y queda visible únicamente dentro del Sandbox.</p>
          </div>
          <div class="lab-scenario-list" id="lab-scenario-list">
            ${SCENARIOS.map((s,index)=>`
              <button type="button" class="lab-scenario-item ${index===0?"selected":""}" data-scenario="${s.code}">
                <div>
                  <strong>${fmt.escape(s.label)}</strong>
                  <p>${fmt.escape(s.description)}</p>
                </div>
                <span>${fmt.escape(s.tag)}</span>
              </button>
            `).join("")}
          </div>
          <div class="lab-builder-actions">
            <label>
              <span>Cantidad de pedidos</span>
              <select class="control" id="sandbox-count">${[1,2,3,5,10].map(n=>`<option value="${n}">${n}</option>`).join("")}</select>
            </label>
            <label>
              <span>Prioridad</span>
              <select class="control" id="sandbox-priority"><option>MEDIUM</option><option>HIGH</option><option>URGENT</option><option>CRITICAL</option><option>LOW</option></select>
            </label>
            <button class="btn btn-primary btn-large" id="sandbox-create">Crear pedido(s) de prueba</button>
          </div>
        </article>

        <aside class="lab-side">
          <article class="lab-panel card">
            <div class="lab-panel-title">
              <span class="lab-eyebrow">GARANTÍAS</span>
              <h3>Qué protege este entorno</h3>
            </div>
            <ul class="lab-protection-list">
              <li>No usa materiales del Excel Siesa.</li>
              <li>No reserva ni descuenta existencias reales.</li>
              <li>No sube archivos al Drive institucional.</li>
              <li>No aparece en colas, Dashboard, VSM, SLA ni Auditoría productiva.</li>
              <li>Solo Superadministración puede verlo y operarlo.</li>
            </ul>
          </article>
          <article class="lab-panel card lab-stats" id="sandbox-stats">
            <div class="lab-stat"><small>Pedidos activos</small><strong>0</strong></div>
            <div class="lab-stat"><small>En curso</small><strong>0</strong></div>
            <div class="lab-stat"><small>Flujos paralelos</small><strong>0</strong></div>
            <div class="lab-stat"><small>Cerrados</small><strong>0</strong></div>
          </article>
        </aside>
      </section>

      <section class="lab-panel card lab-orders">
        <div class="lab-orders-head">
          <div>
            <span class="lab-eyebrow">LABORATORIO ACTIVO</span>
            <h3>Pedidos de prueba</h3>
            <p>Trabaja desde una lista compacta: busca el pedido y pulsa la acción que corresponda.</p>
          </div>
          <div class="lab-toolbar-actions">
            <button class="btn btn-ghost" id="sandbox-refresh">Actualizar</button>
            <button class="btn btn-danger" id="sandbox-clear">Eliminar todas las pruebas</button>
          </div>
        </div>
        <div class="lab-searchbar">
          <input class="control search-wide" id="sandbox-search" placeholder="Buscar TEST o cliente ficticio">
          <button class="btn btn-primary" id="sandbox-search-btn">Buscar</button>
        </div>
        <div id="sandbox-result">${loading("Consultando pedidos de prueba…")}</div>
      </section>
    </section>`;

  let scenario="FLOW";
  root.querySelectorAll("[data-scenario]").forEach(btn=>btn.onclick=()=>{
    scenario=btn.dataset.scenario;
    root.querySelectorAll("[data-scenario]").forEach(item=>item.classList.toggle("selected",item===btn));
  });
  root.querySelector("#sandbox-create").onclick=async()=>{
    const button=root.querySelector("#sandbox-create");
    button.disabled=true;
    try{
      const item=SCENARIOS.find(x=>x.code===scenario);
      const result=await api.sandboxCreate({
        scenario,
        count:Number(root.querySelector("#sandbox-count").value),
        priority:root.querySelector("#sandbox-priority").value,
        stepCode:item.step,
        orderType:item.type,
        requiresCut:Boolean(item.cut)
      });
      toast(`${result.created} pedido(s) de prueba creados.`,"success",6000);
      await load(root);
    }catch(e){toast(e.message,"error",8000)}
    finally{button.disabled=false}
  };
  root.querySelector("#sandbox-refresh").onclick=()=>load(root);
  root.querySelector("#sandbox-search-btn").onclick=()=>load(root);
  root.querySelector("#sandbox-search").onkeydown=e=>{if(e.key==="Enter")load(root)};
  root.querySelector("#sandbox-clear").onclick=()=>confirmClear(root);
  await load(root);
}

async function load(root){
  const target=root.querySelector("#sandbox-result");
  if(!target)return;
  target.innerHTML=loading("Consultando pedidos de prueba…");
  try{
    const data=await api.sandboxOrders({search:root.querySelector("#sandbox-search")?.value.trim()||"",page:1,pageSize:100});
    const rows=data.items||[];
    renderStats(root,rows);
    target.innerHTML=rows.length?`
      <div class="lab-order-table">
        <div class="lab-order-head">
          <span>Pedido</span>
          <span>Etapa</span>
          <span>Estado</span>
          <span>Tipo y prioridad</span>
          <span>Escenario</span>
          <span>Acciones</span>
        </div>
        <div class="lab-order-body">${rows.map(orderRow).join("")}</div>
      </div>`:empty("Sandbox vacío","Crea un escenario para comenzar a probar los módulos.");

    target.querySelectorAll("[data-sb-open]").forEach(b=>b.onclick=()=>openOrder(b.dataset.sbOpen));
    target.querySelectorAll("[data-sb-module]").forEach(b=>b.onclick=()=>{
      const row=rows.find(r=>r.id===b.dataset.sbModule);
      if(row)navigate(moduleForStep(row.currentStep),{sandbox:"1",step:row.currentStep});
    });
    target.querySelectorAll("[data-sb-cutting]").forEach(b=>b.onclick=()=>navigate("cutting",{sandbox:"1"}));
    target.querySelectorAll("[data-sb-picking]").forEach(b=>b.onclick=()=>openOrder(b.dataset.sbPicking));
    target.querySelectorAll("[data-sb-move]").forEach(b=>b.onclick=()=>moveDialog(rows.find(r=>r.id===b.dataset.sbMove),()=>load(root)));
    target.querySelectorAll("[data-sb-delete]").forEach(b=>b.onclick=()=>deleteOne(rows.find(r=>r.id===b.dataset.sbDelete),()=>load(root)));
  }catch(e){
    target.innerHTML=`<div class="module-error"><strong>No fue posible cargar el Sandbox</strong><p>${fmt.escape(e.message)}</p></div>`;
  }
}

function renderStats(root,rows){
  const active=rows.filter(r=>String(r.status||"").toUpperCase()!=="CLOSED").length;
  const inProgress=rows.filter(r=>String(r.status||"").toUpperCase()==="IN_PROGRESS").length;
  const parallel=rows.filter(r=>Boolean(r.requiresCut)&&String(r.currentStep||"").toUpperCase()==="ALISTAMIENTO").length;
  const closed=rows.filter(r=>String(r.currentStep||"").toUpperCase()==="CLOSED"||String(r.status||"").toUpperCase()==="CLOSED").length;
  const box=root.querySelector("#sandbox-stats");
  if(!box)return;
  box.innerHTML=`
    <div class="lab-stat"><small>Pedidos activos</small><strong>${active}</strong></div>
    <div class="lab-stat"><small>En curso</small><strong>${inProgress}</strong></div>
    <div class="lab-stat"><small>Flujos paralelos</small><strong>${parallel}</strong></div>
    <div class="lab-stat"><small>Cerrados</small><strong>${closed}</strong></div>`;
}

function orderRow(o){
  const parallel=Boolean(o.requiresCut)&&String(o.currentStep||"").toUpperCase()==="ALISTAMIENTO";
  const action=String(o.status||"").toUpperCase()==="IN_PROGRESS"?"Continuar":"Abrir";
  return `
    <article class="lab-order-row ${parallel?"parallel":""}">
      <div class="lab-col lab-col-main">
        <span class="lab-row-kicker">${parallel?"CORTE + ALISTAMIENTO":"PRUEBA AISLADA"}</span>
        <strong>${fmt.escape(o.orderNumber)}</strong>
        <small>${fmt.escape(o.clientName)}</small>
      </div>
      <div class="lab-col">
        <small>Etapa</small>
        <strong>${fmt.escape(fmt.step(o.currentStep))}</strong>
      </div>
      <div class="lab-col">
        <small>Estado</small>
        <div>${statusBadge(o.status)}</div>
      </div>
      <div class="lab-col">
        <small>Tipo y prioridad</small>
        <div class="lab-stacked-meta"><b>${fmt.escape(o.orderType||"TEST")}</b>${priorityBadge(o.priority)}</div>
      </div>
      <div class="lab-col">
        <small>Escenario</small>
        <div class="lab-scenario-meta"><b>${fmt.escape(o.scenario||"Manual")}</b>${parallel?'<span class="lab-inline-badge">Paralelo</span>':''}</div>
      </div>
      <div class="lab-col lab-col-actions">
        <button class="btn btn-primary btn-compact" data-sb-open="${o.id}">${action}</button>
        ${parallel
          ? `<button class="btn btn-ghost btn-compact" data-sb-picking="${o.id}">Alistamiento</button><button class="btn btn-warning btn-compact" data-sb-cutting="${o.id}">Corte</button>`
          : `<button class="btn btn-ghost btn-compact" data-sb-module="${o.id}">Abrir módulo</button>`}
        <button class="btn btn-ghost btn-compact" data-sb-move="${o.id}">Mover</button>
        <button class="btn btn-danger btn-compact" data-sb-delete="${o.id}">Eliminar</button>
      </div>
    </article>`;
}

function moveDialog(order,onDone){
  if(!order)return;
  modal({
    title:`Mover ${order.orderNumber}`,
    confirmLabel:"Mover pedido",
    size:"wide",
    body:`<div class="sandbox-modal-warning"><strong>Solo afecta este pedido TEST</strong><p>La etapa anterior se cierra técnicamente y se crea una nueva tarea asignada a Superadministración.</p></div><div class="field"><label>Nueva etapa</label><select class="control" name="step">${STEPS.map(s=>`<option value="${s}" ${s===order.currentStep?"selected":""}>${fmt.escape(fmt.step(s))}</option>`).join("")}</select></div>`,
    onConfirm:async d=>{await api.sandboxMove(order.id,d.querySelector('[name="step"]').value);toast("Pedido de prueba movido.","success");onDone?.()}
  });
}

function deleteOne(order,onDone){
  if(!order)return;
  modal({
    title:"Eliminar pedido de prueba",
    confirmLabel:"Eliminar definitivamente",
    cancelLabel:"Cancelar",
    body:`<div class="sandbox-modal-warning danger"><strong>${fmt.escape(order.orderNumber)}</strong><p>Se eliminará únicamente este pedido sandbox y todos sus registros dependientes. Producción no se toca.</p></div>`,
    onConfirm:async()=>{await api.sandboxDelete(order.id);toast("Pedido de prueba eliminado.","success");onDone?.()}
  });
}

function confirmClear(root){
  modal({
    title:"Vaciar Sandbox",
    confirmLabel:"Eliminar todas las pruebas",
    cancelLabel:"Cancelar",
    body:`<div class="sandbox-modal-warning danger"><strong>Esta limpieza solo busca pedidos manuales de Sandbox</strong><p>No elimina pedidos QA automáticos ni pedidos productivos.</p></div>`,
    onConfirm:async()=>{const result=await api.sandboxClear();toast(`${result.deleted} pedido(s) sandbox eliminados.`,"success");await load(root)}
  });
}
