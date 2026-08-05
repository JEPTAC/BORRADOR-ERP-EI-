export const $=(s,r=document)=>r.querySelector(s);
export const $$=(s,r=document)=>[...r.querySelectorAll(s)];
export const esc=value=>String(value??"").replace(/[&<>'"]/g,ch=>({"&":"&amp;","<":"&lt;",">":"&gt;","'":"&#39;",'"':"&quot;"}[ch]));
export const fmtDate=value=>{if(!value)return "—";const d=new Date(value);return Number.isNaN(d.getTime())?esc(value):new Intl.DateTimeFormat("es-CO",{dateStyle:"medium",timeStyle:"short"}).format(d)};
export const fmtNumber=value=>new Intl.NumberFormat("es-CO").format(Number(value||0));
export const normalize=value=>String(value||"").trim().toLowerCase().normalize("NFD").replace(/[\u0300-\u036f]/g,"").replace(/[\s/-]+/g,"_");
export const title=value=>String(value||"").replace(/_/g," ").replace(/\b\w/g,x=>x.toUpperCase());

export function toast(message,type="ok",detail=""){
  const region=$("#toast-region");
  const node=document.createElement("div");node.className=`toast ${type}`;
  node.innerHTML=`<strong>${esc(message)}</strong>${detail?`<p>${esc(detail)}</p>`:""}`;
  region.appendChild(node);setTimeout(()=>node.remove(),5200);
}

export function setLoading(container,message="Cargando información…"){
  container.innerHTML=`<div class="loading-state"><div class="spinner" style="margin:auto"></div><p>${esc(message)}</p></div>`;
}
export function setError(container,error){
  container.innerHTML=`<div class="empty-state"><h3>No fue posible cargar</h3><p>${esc(error?.message||error)}</p>${error?.hint?`<p>${esc(error.hint)}</p>`:""}</div>`;
}
export function badge(value){
  const n=normalize(value);let cls="info";
  if(["cerrado","completado","approved","aprobado","activo","completed"].some(x=>n.includes(x)))cls="ok";
  if(["espera","pending","pendiente","review","asignado"].some(x=>n.includes(x)))cls="warn";
  if(["cancel","rechaz","error","vencido","failed"].some(x=>n.includes(x)))cls="danger";
  return `<span class="badge ${cls}">${esc(title(value||"Sin estado"))}</span>`;
}

export function openModal({titleText,body,confirmText="Guardar",onConfirm,wide=false}){
  const backdrop=$("#modal-backdrop"),modal=$("#modal");
  modal.style.width=wide?"min(900px,94vw)":"";
  modal.innerHTML=`<header class="modal-header"><h3>${esc(titleText)}</h3><button type="button" class="icon-btn" data-close>×</button></header><div class="modal-body">${body}</div><footer class="modal-footer"><button type="button" class="btn btn-secondary" data-close>Cancelar</button>${onConfirm?`<button type="button" class="btn btn-primary" data-confirm>${esc(confirmText)}</button>`:""}</footer>`;
  backdrop.classList.remove("hidden");modal.classList.remove("hidden");
  const close=()=>{backdrop.classList.add("hidden");modal.classList.add("hidden");modal.innerHTML="";modal.style.width=""};
  $$('[data-close]',modal).forEach(x=>x.onclick=close);backdrop.onclick=close;
  if(onConfirm){$('[data-confirm]',modal).onclick=async e=>{const btn=e.currentTarget;btn.disabled=true;try{const done=await onConfirm(modal);if(done!==false)close();}catch(err){toast("La operación no se completó","error",err.message);}finally{btn.disabled=false;}};}
  return {modal,close};
}

export function formDataObject(form){
  const out={};new FormData(form).forEach((value,key)=>{
    if(key.endsWith("[]")){const k=key.slice(0,-2);(out[k]||(out[k]=[])).push(value);}else out[key]=value;
  });
  $$('input[type="checkbox"]',form).forEach(x=>out[x.name]=x.checked);
  return out;
}

export function arrayFrom(value){
  if(Array.isArray(value))return value;
  if(value?.items&&Array.isArray(value.items))return value.items;
  if(value?.data&&Array.isArray(value.data))return value.data;
  return [];
}

export function renderKeyValue(obj,keys){
  return `<div class="detail-grid">${keys.map(([key,label])=>`<div class="detail-item"><span>${esc(label)}</span><strong>${esc(obj?.[key]??"—")}</strong></div>`).join("")}</div>`;
}
