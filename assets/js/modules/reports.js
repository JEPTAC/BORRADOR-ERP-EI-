import {api} from "../services/api.js";
import {fmt} from "../core/format.js";
import {loading,toast,actionCards,guide} from "../core/ui.js";
import {workspaceIntro} from "../core/guided.js";

export async function renderReports(root){
  const options=[
    {code:"orders",title:"Pedidos completos",description:"Exporta pedidos activos e históricos con sus datos principales.",icon:"▤",tone:"accent"},
    {code:"vsm",title:"Flujo y tiempos",description:"Exporta tiempos productivos, duración total y percentiles.",icon:"↗",tone:"primary"},
    {code:"audit",title:"Auditoría reciente",description:"Exporta actores, eventos y transiciones registradas.",icon:"⌕"},
    {code:"inventory",title:"Inventario",description:"Exporta existencias, reservas, bloqueos y lotes.",icon:"▦",tone:"success"},
    {code:"approvals",title:"Aprobaciones",description:"Exporta solicitudes pendientes y decisiones históricas.",icon:"✓",tone:"warning"},
    {code:"health",title:"Estado del sistema",description:"Exporta controles de configuración y funcionamiento.",icon:"!"}
  ];
  root.innerHTML=`<section class="page-head"><div><h2>Reportes operativos</h2><p>Selecciona el reporte que necesitas. El ERP lo preparará y descargará en formato CSV.</p></div><div class="page-actions"><button class="btn btn-ghost" id="reports-help">Ver guía</button></div></section>${workspaceIntro({title:"¿Qué información deseas descargar?",description:"Cada tarjeta explica el contenido del archivo antes de generarlo.",cards:actionCards(options.map(option=>({id:`report-${option.code}`,...option})))})}<div id="report-progress"></div>`;
  options.forEach(option=>root.querySelector(`#report-${option.code}`).onclick=()=>download(option.code,root.querySelector("#report-progress")));
  root.querySelector("#reports-help").onclick=()=>guide({title:"Cómo usar los reportes",description:"Los archivos se generan con la información visible para tu usuario.",items:[{title:"Selecciona un reporte",detail:"Cada tarjeta describe los datos incluidos."},{title:"Espera la preparación",detail:"El ERP consultará la información y creará el CSV."},{title:"Abre el archivo",detail:"Puedes analizarlo en Excel sin modificar la información del ERP."}]});
}
async function download(type,target){target.innerHTML=`<section class="card card-pad">${loading("Generando reporte…")}</section>`;let rows=[];if(type==="orders")rows=(await api.listOrders({page:1,pageSize:250,includeHistory:true})).items;if(type==="vsm")rows=(await api.vsm(new Date(Date.now()-30*864e5).toISOString().slice(0,10),new Date().toISOString().slice(0,10))).steps;if(type==="audit")rows=(await api.audit(null,"",1,250)).items;if(type==="inventory")rows=(await api.inventory("",1,250)).items;if(type==="approvals")rows=(await api.approvals(null,1,250)).items;if(type==="health")rows=await api.health();target.innerHTML="";if(!rows.length)return toast("El reporte no contiene registros.","error");const headers=[...new Set(rows.flatMap(Object.keys))],csv=[headers.join(","),...rows.map(row=>headers.map(header=>`"${String(typeof row[header]==="object"?JSON.stringify(row[header]):row[header]??"").replaceAll('"','""')}"`).join(","))].join("\n"),link=document.createElement("a");link.href=URL.createObjectURL(new Blob([csv],{type:"text/csv;charset=utf-8"}));link.download=`erp_${type}_${new Date().toISOString().slice(0,10)}.csv`;link.click();URL.revokeObjectURL(link.href);toast("Reporte generado.")}
