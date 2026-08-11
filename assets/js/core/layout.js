import {NAV_GROUPS,CONFIG} from "../config.js";
import {state,setState} from "./state.js";
import {fmt} from "./format.js";
import {icon} from "./icons.js";
import {navigate} from "./router.js";
import {signOut} from "../services/supabase.js";

const MOBILE_NAV_QUERY="(max-width: 960px)";
let previousFocus=null;

export function renderLogin(error=""){
  document.documentElement.classList.remove("nav-drawer-open");
  document.body?.classList.remove("nav-drawer-open");
  document.querySelector("#app").innerHTML=`
    <main class="login-page">
      <section class="login-hero">
        <div class="login-brand"><img src="./assets/img/logo-electroingenieria.png" alt="Electroingeniería"></div>
        <div class="login-message">
          <span class="eyebrow">Gestión integral de suministros</span>
          <h1>La operación completa, clara y bajo control.</h1>
          <p>Administra pedidos, cartera, compras, recepción, alistamiento, corte, facturación, inventario, despachos y tiempos desde un solo lugar.</p>
          <div class="login-features">
            <div><span class="login-feature-icon">${icon("dashboard")}</span><strong>Operación guiada</strong><span>Cada persona encuentra sus tareas, prioridades y próximos pasos.</span></div>
            <div><span class="login-feature-icon">${icon("audit")}</span><strong>Trazabilidad completa</strong><span>Decisiones, tiempos, novedades y evidencias quedan organizadas.</span></div>
            <div><span class="login-feature-icon">${icon("reports")}</span><strong>Control en tiempo real</strong><span>Consulta responsables, avances y cargas de trabajo desde un solo lugar.</span></div>
          </div>
        </div>
        <div class="login-note">Electroingeniería S.A.S. · Trabajando con buena energía</div>
      </section>
      <section class="login-panel">
        <div class="login-card">
          <div class="login-card-icon"><img src="./assets/img/iso-electroingenieria.png" alt=""></div>
          <span class="eyebrow">Acceso corporativo</span>
          <h2>Bienvenido al ERP</h2>
          <p class="sub">Ingresa con tu correo y contraseña de trabajo.</p>
          ${error?`<div class="login-error" role="alert"><strong>No fue posible ingresar</strong><span>${fmt.escape(error)}</span></div>`:""}
          <form id="login-form">
            <div class="field"><label for="email">Correo corporativo</label><div class="input-shell">${icon("credit")}<input class="control" id="email" name="email" type="email" autocomplete="username" placeholder="nombre@ei.com.co" required></div></div>
            <div class="field"><label for="password">Contraseña</label><div class="input-shell">${icon("admin")}<input class="control" id="password" name="password" type="password" autocomplete="current-password" placeholder="Escribe tu contraseña" required></div></div>
            <button class="btn btn-primary btn-block" type="submit">Ingresar al ERP ${icon("chevron")}</button>
          </form>
          <p class="login-help">¿Tienes problemas para ingresar? Comunícate con el administrador del sistema.</p>
          <p class="version-note">Versión ${CONFIG.version}</p>
        </div>
      </section>
    </main>`;
}

function allowed(moduleCode){return state.modules.some(m=>m.code===moduleCode&&m.canRead)}
function navHtml(){return NAV_GROUPS.map(group=>{
  const items=group.items.filter(i=>allowed(i.id));if(!items.length)return"";
  return `<div class="nav-group"><div class="nav-group-title">${fmt.escape(group.label)}</div>${items.map(i=>`<button class="nav-item ${state.currentModule===i.id?"active":""}" data-nav="${i.id}"><span class="nav-icon">${icon(i.icon)}</span><span class="nav-label">${fmt.escape(i.label)}</span>${icon("chevron","nav-arrow")}</button>`).join("")}</div>`;
}).join("")}

export function renderShell(){
  const p=state.profile||{};
  const quickOrder=allowed("sales")?`<button class="btn btn-accent top-new-order" id="quick-order">${icon("plus")}<span>Nuevo pedido</span></button>`:"";
  document.querySelector("#app").innerHTML=`<div class="shell">
    <aside class="sidebar" id="sidebar" aria-label="Menú principal" aria-hidden="true">
      <header class="sidebar-head">
        <div class="sidebar-brand-row">
          <img class="sidebar-logo" src="./assets/img/logo-electroingenieria.png" alt="Electroingeniería">
          <button class="sidebar-close" id="sidebar-close" type="button" aria-label="Cerrar menú"><span aria-hidden="true"></span></button>
        </div>
        <div class="sidebar-product"><strong>ERP Operativo</strong><small>Gestión de suministros</small></div>
      </header>
      <nav class="nav-scroll" id="sidebar-nav" aria-label="Navegación principal">${navHtml()}</nav>
      <footer class="sidebar-foot"><div class="user-chip"><div class="avatar">${fmt.initials(p.name)}</div><div class="user-data"><strong>${fmt.escape(p.name||"Usuario")}</strong><small>${fmt.escape(fmt.roles(p.roles||[]))}</small></div><button class="icon-btn logout-btn" id="logout" title="Cerrar sesión" aria-label="Cerrar sesión">${icon("logout")}</button></div></footer>
    </aside>
    <button class="sidebar-backdrop" id="sidebar-backdrop" type="button" tabindex="-1" aria-label="Cerrar menú"></button>
    <main class="main" id="main-content">
      <header class="topbar">
        <div class="topbar-left"><button class="icon-btn mobile-menu" id="menu-toggle" type="button" aria-label="Abrir menú" aria-controls="sidebar" aria-expanded="false">${icon("menu")}</button><div class="top-title"><div class="breadcrumb"><span>ERP</span><b>›</b><span id="top-section">Operación</span></div><h1 id="top-title">Centro de operación</h1><p id="top-subtitle">Visibilidad y control de la operación</p></div></div>
        <div class="top-actions"><div id="work-clock-slot" class="work-clock-slot"></div><div id="active-work-slot" class="active-work-slot"></div><label class="global-search-shell">${icon("search")}<input id="global-search" class="control global-search" placeholder="Buscar pedido, cliente o referencia…" aria-label="Búsqueda global"></label>${quickOrder}<button class="icon-btn mobile-search-toggle" id="mobile-search-toggle" type="button" aria-label="Abrir búsqueda" aria-controls="mobile-search-panel" aria-expanded="false">${icon("search")}</button><button class="icon-btn refresh-btn" id="refresh-page" title="Actualizar información" aria-label="Actualizar información">${icon("refresh")}</button></div>
      </header>
      <div class="mobile-search-panel" id="mobile-search-panel" hidden><label>${icon("search")}<input id="mobile-global-search" class="control" placeholder="Buscar pedido, cliente o referencia…" aria-label="Búsqueda global móvil"></label></div>
      <div class="content" id="page-content"></div>
    </main>
  </div>`;
  bindShell();
  syncSidebar(false,{restoreFocus:false});
}

function isMobileNavigation(){return window.matchMedia(MOBILE_NAV_QUERY).matches}

function syncSidebar(open,{restoreFocus=true}={}){
  const mobile=isMobileNavigation();
  const shouldOpen=Boolean(open&&mobile);
  const sidebar=document.querySelector("#sidebar");
  const toggle=document.querySelector("#menu-toggle");
  const main=document.querySelector("#main-content");
  if(!sidebar)return;

  setState({sidebarOpen:shouldOpen});
  sidebar.classList.toggle("open",shouldOpen);
  sidebar.setAttribute("aria-hidden",String(mobile&&!shouldOpen));
  toggle?.setAttribute("aria-expanded",String(shouldOpen));
  toggle?.setAttribute("aria-label",shouldOpen?"Cerrar menú":"Abrir menú");
  document.documentElement.classList.toggle("nav-drawer-open",shouldOpen);
  document.body?.classList.toggle("nav-drawer-open",shouldOpen);
  if(main){
    if("inert" in main)main.inert=shouldOpen;
    else if(shouldOpen)main.setAttribute("aria-hidden","true");
    else main.removeAttribute("aria-hidden");
  }

  if(shouldOpen){
    previousFocus=document.activeElement;
    requestAnimationFrame(()=>document.querySelector("#sidebar-close")?.focus());
  }else if(restoreFocus&&previousFocus instanceof HTMLElement){
    requestAnimationFrame(()=>previousFocus?.focus?.());
    previousFocus=null;
  }
}

function closeMobileSidebar(options){if(isMobileNavigation())syncSidebar(false,options)}

function keepFocusInsideSidebar(event){
  if(event.key!=="Tab"||!state.sidebarOpen||!isMobileNavigation())return;
  const sidebar=document.querySelector("#sidebar");
  if(!sidebar)return;
  const focusable=[...sidebar.querySelectorAll('button:not([disabled]),a[href],input:not([disabled]),select:not([disabled]),textarea:not([disabled]),[tabindex]:not([tabindex="-1"])')].filter(el=>el.offsetParent!==null);
  if(!focusable.length)return;
  const first=focusable[0],last=focusable[focusable.length-1];
  if(event.shiftKey&&document.activeElement===first){event.preventDefault();last.focus()}
  else if(!event.shiftKey&&document.activeElement===last){event.preventDefault();first.focus()}
}

function bindShell(){
  shellAbortController?.abort();
  shellAbortController=new AbortController();
  const shellSignal=shellAbortController.signal;
  document.querySelectorAll("[data-nav]").forEach(b=>b.onclick=()=>{
    closeMobileSidebar({restoreFocus:false});
    navigate(b.dataset.nav);
  });
  document.querySelector("#logout").onclick=()=>signOut();
  document.querySelector("#menu-toggle")?.addEventListener("click",()=>syncSidebar(!state.sidebarOpen));
  document.querySelector("#sidebar-close")?.addEventListener("click",()=>syncSidebar(false));
  document.querySelector("#sidebar-backdrop")?.addEventListener("click",()=>syncSidebar(false));
  document.querySelector("#refresh-page").onclick=()=>window.dispatchEvent(new CustomEvent("erp:refresh"));
  document.querySelector("#quick-order")?.addEventListener("click",()=>{closeMobileSidebar({restoreFocus:false});navigate("sales",{create:"1"})});
  const runSearch=input=>{const value=input?.value?.trim();if(value)navigate("orders",{search:value})};
  const search=document.querySelector("#global-search");if(search)search.onkeydown=e=>{if(e.key==="Enter")runSearch(search)};
  const mobileSearch=document.querySelector("#mobile-global-search");if(mobileSearch)mobileSearch.onkeydown=e=>{if(e.key==="Enter"){runSearch(mobileSearch);toggleMobileSearch(false)}};
  const mobileSearchPanel=document.querySelector("#mobile-search-panel");
  const mobileSearchToggle=document.querySelector("#mobile-search-toggle");
  const toggleMobileSearch=open=>{
    if(!mobileSearchPanel||!mobileSearchToggle)return;
    mobileSearchPanel.hidden=!open;
    mobileSearchToggle.setAttribute("aria-expanded",String(open));
    mobileSearchToggle.setAttribute("aria-label",open?"Cerrar búsqueda":"Abrir búsqueda");
    if(open)requestAnimationFrame(()=>mobileSearch?.focus());
  };
  mobileSearchToggle?.addEventListener("click",()=>toggleMobileSearch(mobileSearchPanel?.hidden!==true?false:true));

  document.addEventListener("keydown",event=>{
    if(event.key==="Escape"&&state.sidebarOpen&&isMobileNavigation()){event.preventDefault();syncSidebar(false);return}
    if(event.key==="Escape"&&mobileSearchPanel&&!mobileSearchPanel.hidden){event.preventDefault();toggleMobileSearch(false);mobileSearchToggle?.focus();return}
    keepFocusInsideSidebar(event);
  },{signal:shellSignal});

  const media=window.matchMedia(MOBILE_NAV_QUERY);
  const onViewportChange=()=>{
    if(!media.matches)syncSidebar(false,{restoreFocus:false});
    else syncSidebar(false,{restoreFocus:false});
  };
  if(media.addEventListener)media.addEventListener("change",onViewportChange,{signal:shellSignal});
  else media.addListener?.(onViewportChange);
}

let shellAbortController=null;

export function updateShell(moduleId,title,subtitle=""){
  state.currentModule=moduleId;
  closeMobileSidebar({restoreFocus:false});
  document.querySelectorAll("[data-nav]").forEach(b=>b.classList.toggle("active",b.dataset.nav===moduleId));
  const h=document.querySelector("#top-title"),s=document.querySelector("#top-subtitle"),section=document.querySelector("#top-section");
  if(h)h.textContent=title;if(s)s.textContent=subtitle;
  if(section){const group=NAV_GROUPS.find(g=>g.items.some(i=>i.id===moduleId));section.textContent=group?.label||"Operación"}
}
