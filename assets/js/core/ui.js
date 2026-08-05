import {fmt} from "./format.js";

export function loading(message="Cargando información operativa…"){
  return `<div class="loading"><span class="spinner"></span>${fmt.escape(message)}</div>`;
}

export function empty(title="Sin registros",detail="No hay información para los filtros seleccionados."){
  return `<div class="empty"><strong>${fmt.escape(title)}</strong><div>${fmt.escape(detail)}</div></div>`;
}

export function toast(message,type="success",duration=4200){
  const root=document.querySelector("#toast-root");
  if(!root)return;
  const node=document.createElement("div");
  node.className=`toast ${type}`;
  node.textContent=message;
  root.append(node);
  setTimeout(()=>node.remove(),duration);
}

export function modal({title,body,confirmLabel="Guardar",cancelLabel="Cancelar",size="",onConfirm}){
  const root=document.querySelector("#modal-root");
  root.innerHTML=`<div class="modal-overlay"><section class="modal ${size}"><header class="modal-head"><h3>${fmt.escape(title)}</h3><button class="icon-btn" data-close aria-label="Cerrar">×</button></header><div class="modal-body">${body}</div><footer class="modal-foot"><button class="btn btn-ghost" data-close>${fmt.escape(cancelLabel)}</button>${confirmLabel?`<button class="btn btn-primary" data-confirm>${fmt.escape(confirmLabel)}</button>`:""}</footer></section></div>`;
  const close=()=>root.replaceChildren();
  root.querySelectorAll("[data-close]").forEach(b=>b.onclick=close);
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
  const root=document.querySelector("#modal-root");
  root.innerHTML=`
    <div class="modal-overlay wizard-overlay">
      <section class="modal wizard-modal ${size}">
        <header class="modal-head wizard-head">
          <div><span class="wizard-kicker">Asistente guiado</span><h3>${fmt.escape(title)}</h3><p>${fmt.escape(subtitle)}</p></div>
          <button class="icon-btn" data-close aria-label="Cerrar">×</button>
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
  const close=()=>root.replaceChildren();
  const prev=root.querySelector("[data-prev]");
  const next=root.querySelector("[data-next]");
  let index=0;

  async function show(newIndex){
    index=Math.max(0,Math.min(steps.length-1,newIndex));
    root.querySelectorAll("[data-wizard-panel]").forEach((panel,panelIndex)=>panel.classList.toggle("active",panelIndex===index));
    root.querySelectorAll("[data-wizard-jump]").forEach((button,buttonIndex)=>{
      button.classList.toggle("active",buttonIndex===index);
      button.classList.toggle("done",buttonIndex<index);
    });
    prev.disabled=index===0;
    next.textContent=index===steps.length-1?finishLabel:"Continuar";
    const panel=root.querySelector(`[data-wizard-panel="${index}"]`);
    await steps[index].onEnter?.({root,form,panel,data:serializeForm(form),index});
  }

  root.querySelectorAll("[data-close]").forEach(button=>button.onclick=close);
  prev.onclick=()=>show(index-1);
  next.onclick=async()=>{
    const panel=root.querySelector(`[data-wizard-panel="${index}"]`);
    try{
      if(!validatePanel(panel))return;
      const data=serializeForm(form);
      const valid=await steps[index].validate?.({root,form,panel,data,index});
      if(valid===false)return;
      if(index<steps.length-1){
        await show(index+1);
        return;
      }
      next.disabled=true;
      prev.disabled=true;
      await onFinish?.({root,form,data,index});
      close();
    }catch(error){
      toast(error.message||String(error),"error",6500);
      next.disabled=false;
      prev.disabled=index===0;
    }
  };
  root.querySelectorAll("[data-wizard-jump]").forEach(button=>button.onclick=()=>{
    const target=Number(button.dataset.wizardJump);
    if(target<=index)show(target);
  });
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
