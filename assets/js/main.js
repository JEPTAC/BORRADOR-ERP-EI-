import {state,setState} from "./core/state.js";
import {renderLogin,renderShell,updateShell} from "./core/layout.js";
import {initRouter,navigate} from "./core/router.js";
import {signIn,getSession,onAuthChange} from "./services/supabase.js";
import {api} from "./services/api.js";
import {toast,loading,installDialogSystem} from "./core/ui.js";
import {renderDashboard} from "./modules/dashboard.js";
import {renderOrders,openOrder} from "./modules/orders.js";
import {renderQueue} from "./modules/queue.js";
import {renderInventory} from "./modules/inventory.js";
import {renderApprovals} from "./modules/approvals.js";
import {renderVsm} from "./modules/vsm.js";
import {renderImports} from "./modules/imports.js";
import {renderQa} from "./modules/qa.js";
import {renderSandbox} from "./modules/sandbox.js";
import {renderAudit} from "./modules/audit.js";
import {renderAdmin} from "./modules/admin.js";
import {renderCredit} from "./modules/credit.js";
import {renderReports} from "./modules/reports.js";
import {renderCutting} from "./modules/cutting-flow.js";
import {initActiveWork,moduleForStep} from "./modules/active-work.js";
import {installSupportFlow} from "./modules/support-flow.js";
import {renderWorkforce} from "./modules/workforce.js";
import {initWorkClock} from "./modules/work-clock.js";

const routes={dashboard:renderDashboard,orders:renderOrders,sales:renderOrders,credit:renderCredit,inventory:renderInventory,approvals:renderApprovals,vsm:renderVsm,imports:renderImports,sandbox:renderSandbox,qa:renderQa,audit:renderAudit,admin:renderAdmin,reports:renderReports,cutting:renderCutting,workforce:renderWorkforce};
const queueModules={cartera:["CARTERA"],caja:["CAJA","CAJA_FACTURACION"],purchasing:["COMPRAS"],receiving:["RECEPCION_MERCANCIA","RECEPCION_PEDIDO"],picking:["ALISTAMIENTO"],billing:["FACTURACION"],shipping:["CLIENT_POINT","CLIENT_PICKUP","LOCAL_DISPATCH","NATIONAL_DISPATCH","CLOSURE"]};
const titles={dashboard:["Centro de operación","Visibilidad ejecutiva, cargas y cuellos de botella"],orders:["Control de pedidos","Consulta, trazabilidad y operación integral"],sales:["Registro de ventas","Creación de pedidos y control comercial"],credit:["Solicitudes de crédito","Radicación, estudio y decisión"],cartera:["Cartera","Validación de riesgo y liberación"],caja:["Caja","Retenidos y facturación de pedidos PVN"],purchasing:["Compras","Abastecimiento y órdenes PVE"],receiving:["Recepción","Ingreso documental, físico, calidad y etiquetas"],picking:["Alistamiento","Preparación, controles y novedades"],cutting:["Centro de corte","Referencias agrupadas, control de carretos y entrega a Alistamiento"],billing:["Facturación","Factura, soporte y liberación"],shipping:["Despachos y entregas","Rutas locales, nacionales, recogidas y cierre"],inventory:["Inventario","Existencias, lotes, ubicaciones y movimientos"],workforce:["Mi jornada y actividades","Tiempo, planificación, evidencias y capacidad del equipo"],approvals:["Centro de excepciones","Novedades, reportes, aprobaciones, SLA y escalamiento"],vsm:["Flujo y tiempos","Tiempo total, trabajo productivo, espera y productividad"],reports:["Reportes y analítica","Pareto de causas, indicadores y exportaciones"],imports:["Importar histórico","Carga controlada de pedidos cerrados por CSV"],sandbox:["Bot de pruebas","Entorno aislado exclusivo para Superadministración"],qa:["Pruebas automáticas","Validación integral de rutas y controles operativos"],audit:["Auditoría","Registro inmutable de decisiones y movimientos"],admin:["Administración","Usuarios, roles, calendarios y reglas"]};

async function bootAuthenticated(){
  document.querySelector("#app").innerHTML=loading("Preparando tu espacio de trabajo…");
  try{
    const context=await api.session();setState({profile:context.profile,organization:context.organization,modules:context.modules,catalogs:context.catalogs});renderShell();initActiveWork();initWorkClock();installSupportFlow();
    initRouter(async route=>{
      if(route.segments[0]==="order"&&route.segments[1]){navigate("orders");setTimeout(()=>openOrder(route.segments[1]),0);return}
      const moduleId=route.module;const [title,sub]=titles[moduleId]||["ERP Electroingeniería",""];updateShell(moduleId,title,sub);
      const root=document.querySelector("#page-content");root.innerHTML=loading();
      try{
        if(queueModules[moduleId])await renderQueue(root,{moduleId,steps:queueModules[moduleId],params:route.params});
        else await (routes[moduleId]||renderDashboard)(root,{moduleId,params:route.params});
      }catch(e){console.error("[ERP MODULE]",moduleId,e);root.innerHTML=`<div class="card card-pad module-error"><h3>No fue posible cargar el módulo</h3><p class="danger">${e.message}</p><button class="btn btn-primary" id="retry-module">Reintentar</button></div>`;root.querySelector("#retry-module")?.addEventListener("click",()=>location.reload());toast(e.message,"error",8000)}
    });
  }catch(e){renderLogin(e.message);bindLogin()}
}

function bindLogin(){
  const form=document.querySelector("#login-form");if(!form)return;
  form.onsubmit=async e=>{e.preventDefault();const btn=form.querySelector("button");btn.disabled=true;try{await signIn(form.email.value.trim(),form.password.value)}catch(err){renderLogin(err.message);bindLogin()}finally{btn.disabled=false}};
}

installDialogSystem();

async function start(){
  const session=await getSession();setState({session});if(session)await bootAuthenticated();else{renderLogin();bindLogin()}
  onAuthChange(async session=>{setState({session});if(session&&!state.profile)await bootAuthenticated();if(!session){setState({profile:null,modules:[],catalogs:{}});renderLogin();bindLogin()}});
}
window.addEventListener("erp:open-order",e=>openOrder(e.detail));
document.addEventListener("click",event=>{
  const button=event.target.closest?.("[data-take-another]");
  if(!button)return;
  const step=button.dataset.takeAnother||"";
  document.querySelector("#modal-root")?.replaceChildren();
  navigate(moduleForStep(step),{step,assignment:"ALL"});
  toast("El pedido anterior continúa en Mis pedidos activos. Puedes tomar otro sin perder el avance.","success",6000);
});
start().catch(e=>{renderLogin(e.message);bindLogin()});
if("serviceWorker" in navigator){window.addEventListener("load",()=>navigator.serviceWorker.register("./service-worker.js").catch(()=>{}))}
