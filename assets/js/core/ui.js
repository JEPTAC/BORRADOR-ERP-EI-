import {fmt} from "./format.js";
export function loading(message="Cargando información operativa…"){return `<div class="loading"><span class="spinner"></span>${fmt.escape(message)}</div>`}
export function empty(title="Sin registros",detail="No hay información para los filtros seleccionados."){return `<div class="empty"><strong>${fmt.escape(title)}</strong><div>${fmt.escape(detail)}</div></div>`}
export function toast(message,type="success",duration=4200){const root=document.querySelector("#toast-root");const node=document.createElement("div");node.className=`toast ${type}`;node.textContent=message;root.append(node);setTimeout(()=>node.remove(),duration)}
export function modal({title,body,confirmLabel="Guardar",cancelLabel="Cancelar",size="",onConfirm}){
  const root=document.querySelector("#modal-root");root.innerHTML=`<div class="modal-overlay"><section class="modal ${size}"><header class="modal-head"><h3>${fmt.escape(title)}</h3><button class="icon-btn" data-close>×</button></header><div class="modal-body">${body}</div><footer class="modal-foot"><button class="btn btn-ghost" data-close>${fmt.escape(cancelLabel)}</button>${confirmLabel?`<button class="btn btn-primary" data-confirm>${fmt.escape(confirmLabel)}</button>`:""}</footer></section></div>`;
  const close=()=>root.replaceChildren();root.querySelectorAll("[data-close]").forEach(b=>b.onclick=close);
  const confirm=root.querySelector("[data-confirm]");if(confirm)confirm.onclick=async()=>{try{confirm.disabled=true;await onConfirm?.(root.querySelector(".modal"));close()}catch(e){toast(e.message||String(e),"error");confirm.disabled=false}};
  return {root,close};
}
export function serializeForm(form){const data=Object.fromEntries(new FormData(form).entries());form.querySelectorAll('input[type="checkbox"]').forEach(x=>data[x.name]=x.checked);return data}
export function paginationHtml(p){if(!p)return"";return `<div class="pagination"><span>Página ${p.page} de ${Math.max(p.totalPages,1)} · ${fmt.number(p.totalItems)} registros</span><div class="pagination-actions"><button class="btn btn-ghost" data-page="${p.page-1}" ${p.page<=1?"disabled":""}>Anterior</button><button class="btn btn-ghost" data-page="${p.page+1}" ${p.page>=p.totalPages?"disabled":""}>Siguiente</button></div></div>`}
