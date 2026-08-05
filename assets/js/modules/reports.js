import {api} from "../services/api.js";
import {fmt} from "../core/format.js";
import {loading,toast} from "../core/ui.js";

export async function renderReports(root){
  root.innerHTML=`<section class="page-head"><div><h2>Reportes operativos</h2><p>Exportaciones de pedidos, VSM, auditoría e inventario con los filtros actuales.</p></div></section><section class="grid grid-3">
  ${card("Pedidos completos","Descarga hasta 250 registros por página y permite recorrer todo el histórico.","orders")}
  ${card("VSM últimos 30 días","Tiempos laborales, calendario, mediana y percentil 90.","vsm")}
  ${card("Auditoría reciente","Últimos eventos, actores y transiciones.","audit")}
  ${card("Inventario","Existencias agregadas por artículo y lotes.","inventory")}
  ${card("Aprobaciones","Solicitudes pendientes o decididas.","approvals")}
  ${card("Diagnóstico de salud","Controles de configuración, permisos y API.","health")}
  </section><div id="report-progress" style="margin-top:16px"></div>`;
  root.querySelectorAll("[data-report]").forEach(b=>b.onclick=()=>download(b.dataset.report,root.querySelector("#report-progress")));
}
function card(title,text,code){return `<article class="card card-pad"><h3>${title}</h3><p class="muted">${text}</p><button class="btn btn-primary" data-report="${code}">Generar CSV</button></article>`}
async function download(type,target){target.innerHTML=loading("Generando reporte…");let rows=[];
  if(type==="orders")rows=(await api.listOrders({page:1,pageSize:250,includeHistory:true})).items;
  if(type==="vsm")rows=(await api.vsm(new Date(Date.now()-30*864e5).toISOString().slice(0,10),new Date().toISOString().slice(0,10))).steps;
  if(type==="audit")rows=(await api.audit(null,"",1,250)).items;
  if(type==="inventory")rows=(await api.inventory("",1,250)).items;
  if(type==="approvals")rows=(await api.approvals(null,1,250)).items;
  if(type==="health")rows=await api.health();
  target.innerHTML="";if(!rows.length)return toast("El reporte no contiene registros.","error");const headers=[...new Set(rows.flatMap(Object.keys))];const csv=[headers.join(","),...rows.map(r=>headers.map(h=>`"${String(typeof r[h]==="object"?JSON.stringify(r[h]):r[h]??"").replaceAll('"','""')}"`).join(","))].join("\n");const a=document.createElement("a");a.href=URL.createObjectURL(new Blob([csv],{type:"text/csv;charset=utf-8"}));a.download=`erp_${type}_${new Date().toISOString().slice(0,10)}.csv`;a.click();URL.revokeObjectURL(a.href);toast("Reporte generado.")}
