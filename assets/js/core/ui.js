import {fmt} from "./format.js";

const FOCUSABLE='button:not([disabled]),a[href],input:not([disabled]),select:not([disabled]),textarea:not([disabled]),[tabindex]:not([tabindex="-1"])';
let dialogSystemInstalled=false;
let dialogPreviousFocus=null;
let dialogMutation=null;

export function loading(message="Cargando información operativa…"){
  return `<div class="loading" role="status" aria-live="polite"><span class="spinner" aria-hidden="true"></span>${fmt.escape(message)}</div>`;
}

export function empty(title="Sin registros",detail="No hay información para los filtros seleccionados."){
  return `<div class="empty"><strong>${fmt.escape(title)}</strong><div>${fmt.escape(detail)}</div></div>`;
}

export function toast(message,type="success",duration=4200){
  const root=document.querySelector("#toast-root");
  if(!root)return;
  const node=document.createElement("div");
  node.className=`toast ${type}`;
  node.setAttribute("role",type==="error"?"alert":"status");
  node.setAttribute("aria-live",type==="error"?"assertive":"polite");
  node.textContent=message;
  root.append(node);
  setTimeout(()=>node.remove(),duration);
}

function visibleFocusable(container){
  return [...container.querySelectorAll(FOCUSABLE)].filter(el=>el.offsetParent!==null&&!el.closest('[aria-hidden="true"]')&&!el.closest('[inert]'));
}

function activeDialog(root){
  const dialogs=[...root.querySelectorAll('.modal,[role="dialog"]')].filter(el=>el.offsetParent!==null);
  return dialogs.at(-1)||null;
}

function prepareDialog(dialog){
  if(!dialog)return;
  dialog.setAttribute("role","dialog");
  dialog.setAttribute("aria-modal","true");
  if(!dialog.hasAttribute("tabindex"))dialog.setAttribute("tabindex","-1");
  const title=dialog.querySelector('.modal-head h3,.modal-head h2,header h3,header h4');
  if(title){
    if(!title.id)title.id=`erp-dialog-title-${crypto.randomUUID?.()||Math.random().toString(36).slice(2)}`;
    dialog.setAttribute("aria-labelledby",title.id);
  }else if(!dialog.hasAttribute("aria-label"))dialog.setAttribute("aria-label","Ventana de operación");
}

function syncDialogState(root){
  const dialog=activeDialog(root);
  const app=document.querySelector("#app");
  const open=Boolean(dialog);
  document.documentElement.classList.toggle("dialog-open",open);
  document.body?.classList.toggle("dialog-open",open);
  if(open){
    if(!dialogPreviousFocus||!document.contains(dialogPreviousFocus))dialogPreviousFocus=document.activeElement;
    [...root.querySelectorAll('.modal,[role="dialog"]')].forEach(prepareDialog);
    if(app){
      if("inert" in app)app.inert=true;
      else app.setAttribute("aria-hidden","true");
    }
    requestAnimationFrame(()=>{
      if(!root.contains(document.activeElement)){
        const focusable=visibleFocusable(dialog);
        (dialog.querySelector('[autofocus]')||focusable[0]||dialog).focus?.({preventScroll:true});
      }
    });
  }else{
    if(app){
      if("inert" in app)app.inert=false;
      app.removeAttribute("aria-hidden");
    }
    const target=dialogPreviousFocus;
    dialogPreviousFocus=null;
    if(target instanceof HTMLElement&&document.contains(target))requestAnimationFrame(()=>target.focus?.({preventScroll:true}));
  }
}

export function closeDialog(){
  document.querySelector("#modal-root")?.replaceChildren();
}

export function installDialogSystem(){
  if(dialogSystemInstalled)return;
  const root=document.querySelector("#modal-root");
  if(!root)return;
  dialogSystemInstalled=true;

  root.addEventListener("keydown",event=>{
    const dialog=activeDialog(root);if(!dialog)return;
    if(event.key==="Escape"){
      const taskPanel=root.querySelector('[data-modal-task-panel]');
      if(taskPanel){event.preventDefault();taskPanel.querySelector('[data-task-panel-close]')?.click();return}
      event.preventDefault();closeDialog();return;
    }
    if(event.key!=="Tab")return;
    const focusable=visibleFocusable(dialog);if(!focusable.length){event.preventDefault();dialog.focus();return}
    const first=focusable[0],last=focusable.at(-1);
    if(event.shiftKey&&document.activeElement===first){event.preventDefault();last.focus()}
    else if(!event.shiftKey&&document.activeElement===last){event.preventDefault();first.focus()}
  });

  root.addEventListener("click",event=>{
    const close=event.target.closest?.('[data-close]');
    if(close){event.preventDefault();closeDialog();return}
    const overlay=event.target.closest?.('.modal-overlay');
    if(overlay===event.target&&overlay.dataset.dismissable==="true")closeDialog();
  });

  dialogMutation=new MutationObserver(()=>syncDialogState(root));
  dialogMutation.observe(root,{childList:true,subtree:true});
  syncDialogState(root);
}

function renderDialogShell(root,{title,body,footer="",size="",className="",subtitle="",kicker=""}){
  const titleId=`erp-dialog-title-${crypto.randomUUID?.()||Math.random().toString(36).slice(2)}`;
  root.innerHTML=`<div class="modal-overlay"><section class="modal ${size} ${className}" role="dialog" aria-modal="true" aria-labelledby="${titleId}" tabindex="-1"><header class="modal-head"><div class="modal-title-group">${kicker?`<span class="modal-kicker">${fmt.escape(kicker)}</span>`:""}<h3 id="${titleId}">${fmt.escape(title)}</h3>${subtitle?`<p>${fmt.escape(subtitle)}</p>`:""}</div><button type="button" class="icon-btn" data-close aria-label="Cerrar ventana">×</button></header><div class="modal-body">${body}</div>${footer?`<footer class="modal-foot">${footer}</footer>`:""}</section></div>`;
}

export function taskPanel(host,{title,body,confirmLabel="Confirmar",cancelLabel="Cancelar",kicker="Acción de la operación",tone="",onConfirm,onClose}={}){
  const parent=host?.querySelector?.(':scope > .modal-overlay > .modal')||host?.querySelector?.('.modal');
  if(!parent)throw new Error("No hay una ventana operativa activa para abrir la acción.");
  parent.querySelector('[data-modal-task-panel]')?.remove();
  const previous=document.activeElement;
  const titleId=`erp-task-panel-${crypto.randomUUID?.()||Math.random().toString(36).slice(2)}`;
  const wrapper=document.createElement("div");
  wrapper.className="modal-task-panel-shell";
  wrapper.dataset.modalTaskPanel="1";
  wrapper.innerHTML=`<div class="modal-task-panel-scrim" aria-hidden="true"></div><section class="modal-task-panel ${fmt.escape(tone)}" role="region" aria-labelledby="${titleId}" tabindex="-1"><header><div><span>${fmt.escape(kicker)}</span><h4 id="${titleId}">${fmt.escape(title||"Acción")}</h4></div><button type="button" class="icon-btn" data-task-panel-close aria-label="Cerrar acción">×</button></header><div class="modal-task-panel-body">${body||""}</div><footer><button type="button" class="btn btn-ghost" data-task-panel-close>${fmt.escape(cancelLabel)}</button>${confirmLabel?`<button type="button" class="btn btn-primary" data-task-panel-confirm>${fmt.escape(confirmLabel)}</button>`:""}</footer></section>`;
  parent.append(wrapper);
  parent.classList.add("has-task-panel");
  const contextState=[...parent.children].filter(node=>node!==wrapper).map(node=>({node,inert:node.hasAttribute("inert"),ariaHidden:node.getAttribute("aria-hidden")}));
  contextState.forEach(({node})=>{node.setAttribute("inert","");node.setAttribute("aria-hidden","true")});
  const panel=wrapper.querySelector('.modal-task-panel');
  const close=()=>{
    contextState.forEach(({node,inert,ariaHidden})=>{
      if(!inert)node.removeAttribute("inert");
      if(ariaHidden===null)node.removeAttribute("aria-hidden");else node.setAttribute("aria-hidden",ariaHidden);
    });
    wrapper.remove();
    parent.classList.remove("has-task-panel");
    onClose?.();
    if(previous instanceof HTMLElement&&document.contains(previous))requestAnimationFrame(()=>previous.focus?.({preventScroll:true}));
  };
  wrapper.querySelectorAll('[data-task-panel-close]').forEach(button=>button.addEventListener("click",close));
  wrapper.querySelector('.modal-task-panel-scrim')?.addEventListener("click",close);
  const confirm=wrapper.querySelector('[data-task-panel-confirm]');
  if(confirm)confirm.addEventListener("click",async event=>{
    const button=event.currentTarget;
    if(!validatePanel(panel))return;
    button.disabled=true;
    try{
      const outcome=await onConfirm?.(panel,button);
      if(outcome!==false&&wrapper.isConnected)close();
    }catch(error){toast(error.message||String(error),"error",7000);button.disabled=false}
  });
  requestAnimationFrame(()=>{const first=visibleFocusable(panel)[0];(first||panel).focus?.({preventScroll:true});});
  return {panel,close};
}

export function modal({title,body,confirmLabel="Guardar",cancelLabel="Cancelar",size="",onConfirm}){
  installDialogSystem();
  const root=document.querySelector("#modal-root");
  renderDialogShell(root,{title,body,size,footer:`<button class="btn btn-ghost" type="button" data-close>${fmt.escape(cancelLabel)}</button>${confirmLabel?`<button class="btn btn-primary" type="button" data-confirm>${fmt.escape(confirmLabel)}</button>`:""}`});
  const close=closeDialog;
  const confirm=root.querySelector("[data-confirm]");
  if(confirm)confirm.onclick=async()=>{
    try{
      confirm.disabled=true;
      const dialog=root.querySelector(".modal");
      if(!validatePanel(dialog)){confirm.disabled=false;return;}
      await onConfirm?.(dialog);
      close();
    }catch(error){
      toast(error.message||String(error),"error",6500);
      confirm.disabled=false;
    }
  };
  return {root,close};
}

function validatePanel(panel){
  const controls=[...panel.querySelectorAll("input,select,textarea")].filter(control=>!control.disabled&&control.type!=="hidden");
  for(const control of controls){
    if(!control.checkValidity()){
      control.reportValidity();
      control.focus();
      return false;
    }
  }
  return true;
}

export function wizard({
  title,
  subtitle="Te acompañaremos paso a paso para completar la operación.",
  steps=[],
  finishLabel="Confirmar y guardar",
  cancelLabel="Cancelar",
  size="wide",
  onFinish
}){
  if(!steps.length)throw new Error("El asistente necesita al menos un paso.");
  installDialogSystem();
  const root=document.querySelector("#modal-root");
  const titleId=`erp-dialog-title-${crypto.randomUUID?.()||Math.random().toString(36).slice(2)}`;
  root.innerHTML=`
    <div class="modal-overlay wizard-overlay">
      <section class="modal wizard-modal ${size}" role="dialog" aria-modal="true" aria-labelledby="${titleId}" tabindex="-1">
        <header class="modal-head wizard-head">
          <div><span class="wizard-kicker">Asistente guiado</span><h3 id="${titleId}">${fmt.escape(title)}</h3><p>${fmt.escape(subtitle)}</p></div>
          <button type="button" class="icon-btn" data-close aria-label="Cerrar ventana">×</button>
        </header>
        <div class="wizard-progress" role="list">
          ${steps.map((step,index)=>`<button type="button" class="wizard-progress-item ${index===0?"active":""}" data-wizard-jump="${index}" role="listitem"><span>${index+1}</span><strong>${fmt.escape(step.title)}</strong></button>`).join("")}
        </div>
        <form class="wizard-form" novalidate>
          <div class="modal-body wizard-body">
            ${steps.map((step,index)=>`<section class="wizard-panel ${index===0?"active":""}" data-wizard-panel="${index}"><div class="wizard-step-intro"><span>Paso ${index+1} de ${steps.length}</span><h4>${fmt.escape(step.title)}</h4>${step.description?`<p>${fmt.escape(step.description)}</p>`:""}</div><div class="wizard-step-content">${step.content||""}</div></section>`).join("")}
          </div>
          <footer class="modal-foot wizard-foot">
            <button class="btn btn-ghost" type="button" data-close>${fmt.escape(cancelLabel)}</button>
            <div class="wizard-foot-actions">
              <button class="btn btn-ghost" type="button" data-prev disabled>Anterior</button>
              <button class="btn btn-primary" type="button" data-next>Continuar</button>
            </div>
          </footer>
        </form>
      </section>
    </div>`;

  const form=root.querySelector(".wizard-form");
  const close=closeDialog;
  const prev=root.querySelector("[data-prev]");
  const next=root.querySelector("[data-next]");
  let index=0;

  async function show(newIndex){
    index=Math.max(0,Math.min(steps.length-1,newIndex));
    root.querySelectorAll("[data-wizard-panel]").forEach((panel,panelIndex)=>panel.classList.toggle("active",panelIndex===index));
    root.querySelectorAll("[data-wizard-jump]").forEach((button,buttonIndex)=>{
      button.classList.toggle("active",buttonIndex===index);
      button.classList.toggle("done",buttonIndex<index);
      button.setAttribute("aria-current",buttonIndex===index?"step":"false");
    });
    prev.disabled=index===0;
    next.textContent=index===steps.length-1?finishLabel:"Continuar";
    const panel=root.querySelector(`[data-wizard-panel="${index}"]`);
    await steps[index].onEnter?.({root,form,panel,data:serializeForm(form),index});
    requestAnimationFrame(()=>panel.querySelector(FOCUSABLE)?.focus?.({preventScroll:true}));
  }

  prev.onclick=()=>show(index-1);
  next.onclick=async()=>{
    const panel=root.querySelector(`[data-wizard-panel="${index}"]`);
    try{
      if(!validatePanel(panel))return;
      const data=serializeForm(form);
      const valid=await steps[index].validate?.({root,form,panel,data,index});
      if(valid===false)return;
      if(index<steps.length-1){await show(index+1);return;}
      next.disabled=true;prev.disabled=true;
      await onFinish?.({root,form,data,index});
      close();
    }catch(error){
      toast(error.message||String(error),"error",6500);
      next.disabled=false;prev.disabled=index===0;
    }
  };
  root.querySelectorAll("[data-wizard-jump]").forEach(button=>button.onclick=()=>{const target=Number(button.dataset.wizardJump);if(target<=index)show(target)});
  show(0);
  return {root,form,close,goTo:show,get index(){return index}};
}

export function guide({title,description,items=[],confirmLabel="Entendido"}){
  return modal({
    title,
    confirmLabel,
    cancelLabel:"Cerrar",
    body:`<div class="guide-intro">${fmt.escape(description||"")}</div><div class="guide-list">${items.map((item,index)=>`<article class="guide-list-item"><span>${index+1}</span><div><strong>${fmt.escape(item.title||item)}</strong>${item.detail?`<p>${fmt.escape(item.detail)}</p>`:""}</div></article>`).join("")}</div>`,
    onConfirm:async()=>{}
  });
}

export function actionCards(cards=[]){
  return `<section class="guided-action-grid">${cards.map(card=>`
    <button type="button" class="guided-action-card ${card.tone||""}" ${card.disabled?"disabled":""} ${card.id?`id="${fmt.escape(card.id)}"`:""} ${card.data?Object.entries(card.data).map(([key,value])=>`data-${fmt.escape(key)}="${fmt.escape(value)}"`).join(" "):""}>
      <span class="guided-action-icon">${card.icon||"→"}</span>
      <span class="guided-action-copy"><strong>${fmt.escape(card.title)}</strong><small>${fmt.escape(card.description||"")}</small></span>
      <span class="guided-action-arrow">›</span>
    </button>`).join("")}</section>`;
}

export function serializeForm(form){
  const data=Object.fromEntries(new FormData(form).entries());
  form.querySelectorAll('input[type="checkbox"]').forEach(input=>{if(input.name)data[input.name]=input.checked});
  return data;
}

export function paginationHtml(pagination){
  if(!pagination)return"";
  return `<div class="pagination"><span>Página ${pagination.page} de ${Math.max(pagination.totalPages,1)} · ${fmt.number(pagination.totalItems)} registros</span><div class="pagination-actions"><button class="btn btn-ghost" data-page="${pagination.page-1}" ${pagination.page<=1?"disabled":""}>Anterior</button><button class="btn btn-ghost" data-page="${pagination.page+1}" ${pagination.page>=pagination.totalPages?"disabled":""}>Siguiente</button></div></div>`;
}
