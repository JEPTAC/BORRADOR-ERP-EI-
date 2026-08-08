import {api} from "../services/api.js";
import {fmt} from "../core/format.js";
import {toast} from "../core/ui.js";

let installed=false;

export function installSupportFlow(){
  if(installed)return;
  installed=true;
  const root=document.querySelector("#modal-root");
  if(!root)return;
  const observer=new MutationObserver(()=>enhance(root));
  observer.observe(root,{childList:true,subtree:true});
  root.addEventListener("click",event=>{
    const action=event.target.closest("[data-support-action]");
    if(action)handleAction(action).catch(error=>toast(error.message,"error",7000));
    const resolve=event.target.closest("[data-resolve-issue]");
    if(resolve)openResolveIssue(resolve.dataset.orderId,resolve.dataset.resolveIssue);
  });
  enhance(root);
}

function enhance(root){
  root.querySelectorAll("section.modal[data-order-id]").forEach(dialog=>{
    if(dialog.closest("[data-support-subdialog]"))return;
    if(dialog.querySelector("[data-order-support]"))return;
    const body=dialog.querySelector(".modal-body");
    if(!body)return;
    const orderId=dialog.dataset.orderId;
    if(!orderId)return;
    const node=document.createElement("section");
    node.className="order-support-zone";
    node.dataset.orderSupport=orderId;
    node.innerHTML=toolbar(orderId)+`<div class="order-support-issues" data-support-issues><span class="support-loading">Revisando novedades y reportes…</span></div>`;
    body.prepend(node);
    loadIssues(node,orderId);
  });
}

function toolbar(orderId){
  return `<div class="order-support-toolbar">
    <div class="order-support-title"><span>TRAZABILIDAD OPERATIVA</span><strong>Registrar situación</strong></div>
    <div class="order-support-actions">
      <button type="button" class="support-btn note" data-support-action="NOTE" data-order-id="${fmt.escape(orderId)}"><span>+</span> Nota</button>
      <button type="button" class="support-btn novelty" data-support-action="NOVELTY" data-order-id="${fmt.escape(orderId)}"><span>!</span> Novedad</button>
      <button type="button" class="support-btn report" data-support-action="REPORT" data-order-id="${fmt.escape(orderId)}"><span>■</span> Reporte</button>
      <button type="button" class="support-btn approval" data-support-action="APPROVAL" data-order-id="${fmt.escape(orderId)}"><span>✓</span> Enviar aprobación</button>
    </div>
  </div>`;
}

async function loadIssues(zone,orderId){
  const target=zone.querySelector("[data-support-issues]");
  if(!target)return;
  try{
    const data=await api.orderIssues(orderId);
    const open=(data?.items||[]).filter(item=>item.status==="OPEN");
    const dialog=zone.closest("section.modal");
    if(!open.length){target.innerHTML="";dialog?.classList.remove("order-blocked-by-issue");return;}
    dialog?.classList.add("order-blocked-by-issue");
    dialog?.querySelectorAll("button").forEach(button=>{if(!button.closest("[data-order-support]")&&!button.matches("[data-close],[data-sub-close]"))button.disabled=true;});
    target.innerHTML=open.map(issue=>{const level=Number(issue.slaLevel||0),hours=Number(issue.ageBusinessSeconds||0)/3600;return `<article class="support-open-issue ${String(issue.type||"").toLowerCase()} sla-${level}">
      <div><span>${issue.type==="NOVELTY"?"ESPERA CON NOVEDAD":"REPORTE"}${level>=2?` · ${level>=3?"SLA CRÍTICO":"ESCALADO"}`:level===1?" · SLA EN ALERTA":""}</span><strong>${fmt.escape(issue.title||issue.type)}</strong><p>${fmt.escape(issue.detail||"")}</p><small>${fmt.escape(issue.createdBy||"Usuario")} · ${fmt.date(issue.createdAt)} · ${hours<1?Math.round(Number(issue.ageBusinessSeconds||0)/60)+" min":fmt.number(hours,1)+" h"} laborales</small></div>
      <button type="button" class="btn btn-primary btn-compact" data-resolve-issue="${fmt.escape(issue.id)}" data-order-id="${fmt.escape(orderId)}">Abrir y solucionar</button>
    </article>`}).join("");
  }catch(error){
    target.innerHTML=`<span class="support-error">${fmt.escape(error.message)}</span>`;
  }
}

async function handleAction(button){
  const orderId=button.dataset.orderId;
  const action=button.dataset.supportAction;
  if(action==="APPROVAL")return openApproval(orderId);
  const isNote=action==="NOTE";
  const isNovelty=action==="NOVELTY";
  supportModal({
    title:isNote?"Agregar nota":isNovelty?"Registrar novedad":"Registrar reporte",
    confirmLabel:isNote?"Guardar nota":isNovelty?"Registrar y poner en espera":"Registrar y detener flujo",
    body:`<div class="support-dialog-intro ${action.toLowerCase()}"><strong>${isNote?"La nota no detiene el pedido":isNovelty?"El pedido pasará a Espera con novedad":"El pedido quedará en estado Reporte"}</strong><p>${isNote?"Úsala para dejar trazabilidad de inconsistencias menores que permiten continuar.":"El flujo no podrá avanzar hasta que esta situación sea solucionada y cerrada."}</p></div>
      <div class="field"><label>Título *</label><input class="control" name="title" required maxlength="120" placeholder="Resumen corto de la situación"></div>
      <div class="field"><label>Detalle *</label><textarea class="control" name="detail" required rows="4" placeholder="Describe qué ocurrió y qué debe quedar trazado"></textarea></div>`,
    onConfirm:async dialog=>{
      const title=dialog.querySelector('[name="title"]').value.trim();
      const detail=dialog.querySelector('[name="detail"]').value.trim();
      await api.createOrderIssue(orderId,{type:action,title,detail});
      toast(isNote?"Nota registrada. Puedes continuar.":isNovelty?"Novedad registrada. El pedido quedó en espera.":"Reporte registrado. El pedido quedó detenido.","success",6500);
      window.__erpQueueRefresh?.();
      window.dispatchEvent(new CustomEvent("erp:work-changed"));
      return {closeOrder:!isNote};
    }
  });
}

function openResolveIssue(orderId,issueId){
  supportModal({
    title:"Solucionar y cerrar",
    confirmLabel:"Marcar solucionado",
    body:`<div class="support-dialog-intro resolved"><strong>El flujo continuará cuando se cierre el último bloqueo.</strong><p>Registra qué se hizo para resolver la situación.</p></div>
      <div class="field"><label>Solución aplicada *</label><textarea class="control" name="resolution" required rows="4" placeholder="Describe la solución"></textarea></div>
      <div class="field"><label>Resultado</label><select class="control" name="resolutionCode"><option value="RESOLVED">Solucionado</option><option value="REPROGRAM">Reprogramado</option><option value="RETURN">Retorno / cancelación</option></select></div>`,
    onConfirm:async dialog=>{
      await api.resolveOrderIssue(issueId,{resolution:dialog.querySelector('[name="resolution"]').value.trim(),resolutionCode:dialog.querySelector('[name="resolutionCode"]').value});
      toast("Situación solucionada y cerrada.","success",6500);
      window.__erpQueueRefresh?.();
      window.dispatchEvent(new CustomEvent("erp:work-changed"));
      return {closeOrder:true};
    }
  });
}

function openApproval(orderId){
  supportModal({
    title:"Enviar solicitud de aprobación",
    confirmLabel:"Enviar aprobación",
    body:`<div class="support-dialog-intro approval"><strong>La solicitud no detiene por sí sola el trabajo normal.</strong><p>La excepción que dependa de esta autorización no podrá ejecutarse hasta ser aprobada.</p></div>
      <div class="field"><label>¿Qué necesita aprobación? *</label><select class="control" name="approvalKind" required>
        <option value="PRIORITY_RELEASE">Continuar pedido prioritario</option>
        <option value="NO_INVOICE">Salida excepcional sin factura</option>
        <option value="STOCK_EXCEPTION">Excepción de inventario</option>
        <option value="FLOW_EXCEPTION">Excepción operativa / de flujo</option>
        <option value="DATA_CORRECTION">Corrección de datos</option>
      </select></div>
      <div class="field"><label>Enviar a *</label><select class="control" name="assignedRole" required><option value="jefe_logistica">Jefatura Logística</option><option value="auditoria">Auditoría</option><option value="gerencia">Gerencia</option></select></div>
      <div class="field"><label>Justificación *</label><textarea class="control" name="reason" required rows="4" placeholder="Explica por qué la excepción debe ser aprobada"></textarea></div>`,
    onConfirm:async dialog=>{
      const kind=dialog.querySelector('[name="approvalKind"]').value;
      const assignedRole=dialog.querySelector('[name="assignedRole"]').value;
      const reason=dialog.querySelector('[name="reason"]').value.trim();
      const payload={reason,assignedRole};
      if(kind==="PRIORITY_RELEASE")Object.assign(payload,{requestType:"FLOW_EXCEPTION",exceptionCode:"PRIORITY_RELEASE"});
      else if(kind==="NO_INVOICE")Object.assign(payload,{requestType:"PAYMENT_EXCEPTION",exceptionCode:"NO_INVOICE"});
      else Object.assign(payload,{requestType:kind,exceptionCode:kind});
      await api.executeAction(orderId,"REQUEST_APPROVAL",payload,null);
      toast("Solicitud enviada a aprobación. Puedes continuar con las tareas que no dependan de ella.","success",6000);
      window.dispatchEvent(new CustomEvent("erp:work-changed"));
      return {closeOrder:false};
    }
  });
}

function supportModal({title,body,confirmLabel,onConfirm}){
  const root=document.querySelector("#modal-root");
  if(!root)return;
  root.querySelector("[data-support-subdialog]")?.remove();
  const layer=document.createElement("div");
  layer.className="modal-overlay support-sub-overlay";
  layer.dataset.supportSubdialog="1";
  layer.innerHTML=`<section class="modal wide support-sub-modal"><header class="modal-head"><h3>${fmt.escape(title)}</h3><button type="button" class="icon-btn" data-sub-close aria-label="Cerrar">×</button></header><div class="modal-body">${body}</div><footer class="modal-foot"><button type="button" class="btn btn-ghost" data-sub-close>Cancelar</button><button type="button" class="btn btn-primary" data-sub-confirm>${fmt.escape(confirmLabel)}</button></footer></section>`;
  root.append(layer);
  const close=()=>layer.remove();
  layer.querySelectorAll("[data-sub-close]").forEach(button=>button.addEventListener("click",close));
  layer.addEventListener("click",event=>{if(event.target===layer)close()});
  layer.querySelector("[data-sub-confirm]")?.addEventListener("click",async event=>{
    const button=event.currentTarget;
    const dialog=layer.querySelector(".support-sub-modal");
    const controls=[...dialog.querySelectorAll("input,select,textarea")].filter(control=>!control.disabled&&control.type!=="hidden");
    const invalid=controls.find(control=>!control.checkValidity());
    if(invalid){invalid.reportValidity();invalid.focus();return;}
    button.disabled=true;
    try{
      const outcome=await onConfirm(dialog)||{};
      close();
      if(outcome.closeOrder)root.replaceChildren();
    }catch(error){toast(error.message||String(error),"error",7000);button.disabled=false;}
  });
}
