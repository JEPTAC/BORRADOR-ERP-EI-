import {api} from "../services/api.js";
import {fmt} from "../core/format.js";
import {taskPanel,toast} from "../core/ui.js";

function requestType(row){return String(row?.request_type||row?.requestType||"").toUpperCase()}
function requestStatus(row){return String(row?.status||"").toUpperCase()}

export function pendingCancellation(data){
  return (data?.approvals||[]).find(row=>requestType(row)==="CANCELLATION"&&requestStatus(row)==="PENDING")||null;
}

export function mountOrderCancellationAction(host,data,{reload=null,refresh=null}={}){
  const order=data?.order;
  if(!host||!order||order.is_test)return;
  const status=String(order.status||"").toUpperCase();
  if(["CLOSED","CANCELLED"].includes(status))return;

  const footer=host.querySelector(":scope > .modal-overlay > .modal > .modal-foot")||host.querySelector(".modal-foot");
  if(!footer||footer.querySelector("[data-request-order-cancellation]"))return;

  const pending=pendingCancellation(data);
  const actions=footer.querySelector(".parallel-work-actions")||footer;
  const button=document.createElement("button");
  button.type="button";
  button.className=pending?"btn btn-ghost":"btn btn-danger";
  button.dataset.requestOrderCancellation=order.id;
  button.textContent=pending?"Cancelación solicitada":"Solicitar cancelación";
  button.disabled=Boolean(pending);
  if(pending)button.title="Jefatura Logística tiene una solicitud pendiente para este pedido.";
  actions.prepend(button);

  if(pending)return;
  button.addEventListener("click",()=>openCancellationPanel(host,data,{button,reload,refresh}));
}

function openCancellationPanel(host,data,{button,reload,refresh}){
  const order=data.order;
  taskPanel(host,{
    title:"Solicitar cancelación del pedido",
    kicker:"Permiso de Jefatura Logística",
    tone:"danger",
    confirmLabel:"Enviar solicitud",
    cancelLabel:"Volver",
    body:`
      <section class="wizard-confirm-box">
        <strong>${fmt.escape(order.order_number)} · ${fmt.escape(order.client_name)}</strong>
        <p>La solicitud será enviada exclusivamente a Jefatura Logística. El pedido no se cancela hasta que la jefatura la apruebe.</p>
      </section>
      <div class="field">
        <label>Nota de cancelación *</label>
        <textarea class="control" name="cancellationNote" rows="5" required autofocus maxlength="1000" placeholder="Explica brevemente por qué debe cancelarse este pedido"></textarea>
        <small class="field-help">Esta nota quedará en la trazabilidad y será visible para Jefatura Logística.</small>
      </div>`,
    onConfirm:async panel=>{
      const note=panel.querySelector('[name="cancellationNote"]')?.value.trim()||"";
      if(!note)throw new Error("Escribe la nota de cancelación.");
      await api.requestOrderCancellation(order.id,note);
      if(button?.isConnected){button.disabled=true;button.className="btn btn-ghost";button.textContent="Cancelación solicitada";}
      toast("Solicitud de cancelación enviada a Jefatura Logística.","success",6500);
      window.dispatchEvent(new CustomEvent("erp:work-changed"));
      refresh?.();
      if(reload)setTimeout(()=>reload(),80);
    }
  });
}
