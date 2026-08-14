import {state,setState} from "./core/state.js";
import {renderLogin,renderShell,updateShell} from "./core/layout.js";
import {initRouter,navigate} from "./core/router.js";
import {signIn,getSession,onAuthChange,clearLocalSession} from "./services/supabase.js";
import {api} from "./services/api.js";
import {toast,loading,installDialogSystem} from "./core/ui.js";
import {renderDashboard} from "./modules/dashboard.js";
import {renderOrders,openOrder} from "./modules/orders.js";
import {renderQueue} from "./modules/queue.js";
import {renderInventory} from "./modules/inventory.js";
import {renderApprovals} from "./modules/approvals.js";
import {renderVsm} from "./modules/vsm.js";
import {renderImports} from "./modules/imports.js";
import {renderAudit} from "./modules/audit.js";
import {renderAdmin} from "./modules/admin.js";
import {renderCredit} from "./modules/credit.js";
import {renderReports} from "./modules/reports.js";
import {renderCutting} from "./modules/cutting-flow.js";
import {initActiveWork,moduleForStep} from "./modules/active-work.js";
import {installSupportFlow} from "./modules/support-flow.js";
import {renderWorkforce} from "./modules/workforce.js";
import {initWorkClock} from "./modules/work-clock.js";

const routes={dashboard:renderDashboard,orders:renderOrders,sales:renderOrders,credit:renderCredit,inventory:renderInventory,approvals:renderApprovals,vsm:renderVsm,imports:renderImports,audit:renderAudit,admin:renderAdmin,reports:renderReports,cutting:renderCutting,workforce:renderWorkforce};
const queueModules={cartera:["CARTERA"],caja:["CAJA","CAJA_FACTURACION"],purchasing:["COMPRAS"],receiving:["RECEPCION_MERCANCIA","RECEPCION_PEDIDO"],picking:["ALISTAMIENTO"],billing:["FACTURACION"],shipping:["CLIENT_POINT","CLIENT_PICKUP","LOCAL_DISPATCH","NATIONAL_DISPATCH","CLOSURE"]};
let authBootPromise=null;
const SESSION_PROFILE_ERROR=/usuario sin perfil operativo activo|perfil operativo activo|jwt expired|token.*expired/i;

const titles={dashboard:["Centro de operaciones","Indicadores, cargas y prioridades de la operación"],orders:["Pedidos","Consulta, trazabilidad y gestión integral"],sales:["Ventas y pedidos","Creación y seguimiento comercial"],credit:["Crédito","Radicación, estudio y decisión"],cartera:["Cartera","Validación financiera y liberación"],caja:["Caja","Retenidos y facturación de pedidos PVN"],purchasing:["Compras","Abastecimiento y órdenes PVE"],receiving:["Recepción","Ingreso documental, físico, calidad y etiquetas"],picking:["Alistamiento","Preparación, controles y novedades"],cutting:["Centro de corte","Referencias agrupadas, carretos y entrega a Alistamiento"],billing:["Facturación","Factura, soporte y liberación"],shipping:["Despachos y entregas","Rutas, recogidas, evidencias y cierre"],inventory:["Inventario","Existencias, lotes, ubicaciones y movimientos"],workforce:["Jornada y actividades","Planeación, tiempo, evidencias y capacidad"],approvals:["Excepciones y aprobaciones","Novedades, reportes, decisiones y SLA"],vsm:["Flujo y tiempos","Tiempo total, trabajo productivo, espera y productividad"],reports:["Analítica y reportes","Indicadores, causas y exportaciones"],imports:["Histórico de pedidos","Carga controlada de pedidos cerrados por CSV"],audit:["Auditoría","Registro de decisiones y movimientos"],admin:["Administración del ERP","Usuarios, roles, calendarios y configuración"]};

async function bootAuthenticated(){
  if(authBootPromise)return authBootPromise;
  authBootPromise=(async()=>{
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
    }catch(e){
      const technical=String(e?.technicalMessage||e?.message||"");
      if(e?.rpc==="erp_x_session"&&SESSION_PROFILE_ERROR.test(technical)){
        await clearLocalSession();
        setState({session:null,profile:null,organization:null,modules:[],catalogs:{}});
        renderLogin("La sesión anterior ya no es válida. Inicia sesión nuevamente.");
      }else renderLogin(e.message);
      bindLogin();
    }
  })();
  try{return await authBootPromise}finally{authBootPromise=null}
}

function bindLogin(){
  const form=document.querySelector("#login-form");if(!form)return;
  form.onsubmit=async e=>{
    e.preventDefault();
    const btn=form.querySelector("button");
    const email=form.email.value.trim();
    const password=form.password.value;
    btn.disabled=true;
    try{
      await clearLocalSession();
      setState({session:null,profile:null,organization:null,modules:[],catalogs:{}});
      const auth=await signIn(email,password);
      setState({session:auth.session||null});
      await bootAuthenticated();
    }catch(err){
      setState({session:null,profile:null,organization:null,modules:[],catalogs:{}});
      renderLogin(err.message||"No fue posible iniciar sesión.");
      bindLogin();
    }finally{btn.disabled=false}
  };
}

installDialogSystem();

async function start(){
  const session=await getSession();
  setState({session});
  if(session)await bootAuthenticated();else{renderLogin();bindLogin()}
  onAuthChange(async(session,event)=>{
    setState({session});
    if(session&&!state.profile&&event!=="INITIAL_SESSION")await bootAuthenticated();
    if(!session){setState({profile:null,organization:null,modules:[],catalogs:{}});renderLogin();bindLogin()}
  });
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
