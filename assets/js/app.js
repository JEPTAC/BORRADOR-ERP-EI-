import { CONFIG, MODULES } from "./config.js";
import { supabase, requireSession, signIn, signOut } from "./supabase.js";
import { API } from "./api.js";
import { connectDrive } from "./drive.js";
import { $, $$, esc, toast, setLoading, setError } from "./ui.js";
import { renderDashboard } from "./modules/dashboard.js";
import { renderCasesPage } from "./modules/cases.js";
import { renderSales } from "./modules/sales.js";
import { renderWorkflows } from "./modules/workflows.js";
import { renderCredit } from "./modules/credit.js";
import { renderDomain, newNoveltyModal, newInventoryModal } from "./modules/domains.js";
import { renderAdmin } from "./modules/admin.js";
import { renderVsm } from "./modules/vsm.js";
import { renderAudit } from "./modules/audit.js";
import { renderGoods } from "./modules/goods.js";

const state={session:null,context:null,catalog:null,currentModule:"dashboard",renderer:null};
const boot=$("#boot-screen"),authView=$("#auth-view"),appView=$("#app-view"),content=$("#page-content"),nav=$("#main-nav");

function allowed(module,role){return module.roles?.includes("*")||module.roles?.includes(role)}
function setPage(module){$("#page-title").textContent=module.label;$("#page-kicker").textContent="EI ERP Nova V9";$$('.nav-item').forEach(x=>x.classList.toggle("active",x.dataset.module===module.id));}
function renderNav(){const role=state.context.role;nav.innerHTML=MODULES.filter(m=>allowed(m,role)).map(m=>`<a href="#${m.id}" class="nav-item" data-module="${m.id}"><span>${m.icon}</span><span>${esc(m.label)}</span></a>`).join("");$$('.nav-item',nav).forEach(x=>x.onclick=()=>{$("#sidebar").classList.remove("open")});}
function renderUser(){const c=state.context;$("#user-card").innerHTML=`<strong>${esc(c.name)}</strong><span>${esc(c.email)}</span><span>${esc(c.role)}</span>`}

async function startAuthenticated(){
  try{
    const [context,catalog]=await Promise.all([API.session(),API.catalog()]);
    state.context={uid:context.viewer?.uid||context.uid||state.session.user.id,email:context.viewer?.email||context.email||state.session.user.email,name:context.viewer?.name||context.name||state.session.user.email,role:context.viewer?.role||context.role,raw:context};state.catalog=catalog;
    if(!state.context.role)throw new Error("Supabase no devolvió un rol operativo.");
    authView.classList.add("hidden");appView.classList.remove("hidden");renderNav();renderUser();boot.classList.add("hidden");route();
  }catch(error){boot.classList.add("hidden");authView.classList.remove("hidden");appView.classList.add("hidden");$("#login-error").textContent=error.message;}
}

async function route(){
  const id=(location.hash||"#dashboard").slice(1);let module=MODULES.find(m=>m.id===id&&allowed(m,state.context.role));if(!module)module=MODULES.find(m=>m.id==="dashboard");state.currentModule=module.id;setPage(module);setLoading(content,"Abriendo módulo…");
  try{
    if(module.id==="dashboard")state.renderer=await renderDashboard(content);
    else if(module.id==="sales")state.renderer=await renderSales(content,state.context);
    else if(module.id==="projects")state.renderer=await renderCasesPage(content,{label:"Pedidos PVP / Proyectos",processes:null,orderKind:"PVP"});
    else if(module.id==="orders")state.renderer=await renderCasesPage(content,{label:"Todos los pedidos",processes:null});
    else if(["cartera","caja","compras","recepcion","alistamiento","corte","facturacion","despachos"].includes(module.id))state.renderer=await renderCasesPage(content,{label:module.label,processes:module.processes});
    else if(module.id==="goods")state.renderer=await renderGoods(content,state.context);
    else if(module.id==="approvals")state.renderer=await renderWorkflows(content);
    else if(module.id==="credit")state.renderer=await renderCredit(content,state.context);
    else if(module.id==="novelties")state.renderer=await renderDomain(content,"novelties",{label:"Novedades",description:"Novedades operativas y de calidad.",create:refresh=>newNoveltyModal(refresh,state.context),columns:[{key:"title",label:"Título"},{key:"category",label:"Categoría"},{key:"severity",label:"Severidad",type:"badge"},{key:"status",label:"Estado",type:"badge"},{key:"processCode",label:"Proceso"},{key:"createdAt",label:"Fecha",type:"date"}]});
    else if(module.id==="inventory")state.renderer=await renderDomain(content,"inventory",{label:"Inventario y chipas",description:"Saldos derivados de corte y registros de inventario.",create:refresh=>newInventoryModal(refresh,state.context),columns:[{key:"reference",label:"Referencia"},{key:"description",label:"Descripción"},{key:"warehouse",label:"Bodega"},{key:"remaining",label:"Disponible",type:"number"},{key:"unit",label:"Unidad"},{key:"status",label:"Estado",type:"badge"},{key:"updatedAt",label:"Actualización",type:"date"}]});
    else if(module.id==="vsm")state.renderer=await renderVsm(content);
    else if(module.id==="audit")state.renderer=await renderAudit(content);
    else if(module.id==="admin")state.renderer=await renderAdmin(content);
  }catch(error){setError(content,error)}
}

$("#login-form").onsubmit=async e=>{e.preventDefault();const email=$("#login-email").value.trim(),password=$("#login-password").value;$("#login-error").textContent="";const btn=e.currentTarget.querySelector("button");btn.disabled=true;try{const data=await signIn(email,password);state.session=data.session;await startAuthenticated()}catch(error){$("#login-error").textContent=error.message}finally{btn.disabled=false}};
$("#logout-btn").onclick=async()=>{await signOut();state.session=null;state.context=null;appView.classList.add("hidden");authView.classList.remove("hidden");location.hash=""};
$("#refresh-btn").onclick=()=>route();
$("#drive-btn").onclick=async()=>{try{await connectDrive(true);toast("Google Drive conectado")}catch(e){toast("No fue posible conectar Drive","error",e.message)}};
$("#menu-btn").onclick=()=>$("#sidebar").classList.toggle("open");window.addEventListener("hashchange",()=>state.context&&route());

supabase.auth.onAuthStateChange((_event,session)=>{state.session=session;if(!session){appView.classList.add("hidden");authView.classList.remove("hidden");boot.classList.add("hidden")}});

(async()=>{try{if("serviceWorker" in navigator)navigator.serviceWorker.register("./service-worker.js").catch(()=>{});state.session=await requireSession();if(state.session)await startAuthenticated();else{boot.classList.add("hidden");authView.classList.remove("hidden")}}catch(error){boot.classList.add("hidden");authView.classList.remove("hidden");$("#login-error").textContent=error.message}})();
