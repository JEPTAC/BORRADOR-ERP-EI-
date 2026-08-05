import {NAV_GROUPS,CONFIG} from "../config.js";
import {state,setState} from "./state.js";
import {fmt} from "./format.js";
import {navigate} from "./router.js";
import {signOut} from "../services/supabase.js";

export function renderLogin(error=""){
  document.querySelector("#app").innerHTML=`
    <main class="login-page">
      <section class="login-hero">
        <div><div class="brand-mark">EI</div><h1>Control total de suministros.</h1><p>Pedidos, cartera, caja, compras, recepción, alistamiento, corte, facturación, despachos, inventario, tiempos y auditoría en una sola operación.</p></div>
        <div class="login-badges"><span>Supabase nativo</span><span>Google Drive</span><span>Flujo transaccional</span><span>QA matricial</span></div>
      </section>
      <section class="login-panel"><div class="login-card">
        <div class="brand-mark">EI</div><h2>ERP Supply Enterprise</h2><p class="sub">Acceso seguro a la operación logística.</p>
        ${error?`<div class="card card-pad danger" style="margin-bottom:16px">${fmt.escape(error)}</div>`:""}
        <form id="login-form">
          <div class="field"><label for="email">Correo corporativo</label><input class="control" id="email" name="email" type="email" autocomplete="username" required></div>
          <div class="field"><label for="password">Contraseña</label><input class="control" id="password" name="password" type="password" autocomplete="current-password" required></div>
          <button class="btn btn-primary btn-block" type="submit">Ingresar al ERP</button>
        </form>
        <p class="faint" style="margin-top:18px;font-size:11px">Versión ${CONFIG.version} · Arquitectura Supabase + Drive</p>
      </div></section>
    </main>`;
}

function allowed(moduleCode){return state.modules.some(m=>m.code===moduleCode&&m.canRead)}
function navHtml(){return NAV_GROUPS.map(group=>{
  const items=group.items.filter(i=>allowed(i.id));if(!items.length)return"";
  return `<div class="nav-group"><div class="nav-group-title">${fmt.escape(group.label)}</div>${items.map(i=>`<button class="nav-item ${state.currentModule===i.id?"active":""}" data-nav="${i.id}"><span class="nav-icon">${i.icon}</span><span>${fmt.escape(i.label)}</span></button>`).join("")}</div>`
}).join("")}

export function renderShell(){
  const p=state.profile||{};
  document.querySelector("#app").innerHTML=`<div class="shell">
    <aside class="sidebar ${state.sidebarOpen?"open":""}" id="sidebar">
      <header class="sidebar-head"><div class="brand-mark">EI</div><div class="brand-copy"><strong>Supply Enterprise</strong><small>${fmt.escape(state.organization?.name||"")}</small></div></header>
      <nav class="nav-scroll" id="sidebar-nav">${navHtml()}</nav>
      <footer class="sidebar-foot"><div class="user-chip"><div class="avatar">${fmt.initials(p.name)}</div><div style="min-width:0;flex:1"><strong>${fmt.escape(p.name||"Usuario")}</strong><small>${fmt.escape((p.roles||[]).join(" · "))}</small></div><button class="icon-btn" id="logout" title="Cerrar sesión">↪</button></div></footer>
    </aside>
    <main class="main">
      <header class="topbar"><div style="display:flex;align-items:center;gap:12px"><button class="btn btn-ghost mobile-menu" id="menu-toggle">☰</button><div class="top-title"><h1 id="top-title">Centro de operación</h1><p id="top-subtitle">Visibilidad y control en tiempo real</p></div></div>
        <div class="top-actions"><input id="global-search" class="control global-search" placeholder="Buscar pedido, cliente o referencia…"><button class="btn btn-ghost" id="refresh-page">Actualizar</button></div>
      </header>
      <div class="content" id="page-content"></div>
    </main>
  </div>`;
  bindShell();
}

function bindShell(){
  document.querySelectorAll("[data-nav]").forEach(b=>b.onclick=()=>{setState({sidebarOpen:false});navigate(b.dataset.nav)});
  document.querySelector("#logout").onclick=()=>signOut();
  document.querySelector("#menu-toggle")?.addEventListener("click",()=>{setState({sidebarOpen:!state.sidebarOpen});document.querySelector("#sidebar").classList.toggle("open")});
  document.querySelector("#refresh-page").onclick=()=>window.dispatchEvent(new CustomEvent("erp:refresh"));
  const search=document.querySelector("#global-search");search.onkeydown=e=>{if(e.key==="Enter")navigate("orders",{search:search.value})};
}

export function updateShell(moduleId,title,subtitle=""){
  state.currentModule=moduleId;
  document.querySelectorAll("[data-nav]").forEach(b=>b.classList.toggle("active",b.dataset.nav===moduleId));
  const h=document.querySelector("#top-title"),s=document.querySelector("#top-subtitle");if(h)h.textContent=title;if(s)s.textContent=subtitle;
}
