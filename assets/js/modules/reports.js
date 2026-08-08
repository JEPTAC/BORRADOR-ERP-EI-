import {api} from "../services/api.js";
import {fmt} from "../core/format.js";
import {loading,toast,actionCards,guide} from "../core/ui.js";
import {workspaceIntro} from "../core/guided.js";

export async function renderReports(root){
  const options=[
    {code:"causes",title:"Analítica de causas",description:"Pareto de causas, referencias, asesores, proveedores y procesos que generan reprocesos.",icon:"◎",tone:"accent",interactive:true},
    {code:"orders",title:"Pedidos completos",description:"Exporta pedidos activos e históricos con sus datos principales.",icon:"▤",tone:"accent"},
    {code:"vsm",title:"Flujo y tiempos",description:"Exporta tiempos productivos, duración total y percentiles.",icon:"↗",tone:"primary"},
    {code:"audit",title:"Auditoría reciente",description:"Exporta actores, eventos y transiciones registradas.",icon:"⌕"},
    {code:"inventory",title:"Inventario",description:"Exporta existencias, reservas, bloqueos y lotes.",icon:"▦",tone:"success"},
    {code:"approvals",title:"Aprobaciones",description:"Exporta solicitudes pendientes y decisiones históricas.",icon:"✓",tone:"warning"},
    {code:"health",title:"Estado del sistema",description:"Exporta controles de configuración y funcionamiento.",icon:"!"}
  ];
  root.innerHTML=`<section class="page-head"><div><h2>Reportes y analítica operacional</h2><p>Identifica causas recurrentes o descarga información consolidada para análisis externo.</p></div><div class="page-actions"><button class="btn btn-ghost" id="reports-help">Ver guía</button></div></section>${workspaceIntro({title:"¿Qué información deseas analizar?",description:"La analítica causal se consulta dentro del ERP; los demás reportes se descargan en CSV.",cards:actionCards(options.map(option=>({id:`report-${option.code}`,...option})))})}<div id="report-progress"></div>`;
  options.forEach(option=>root.querySelector(`#report-${option.code}`).onclick=()=>option.interactive?renderCauseAnalytics(root.querySelector("#report-progress")):download(option.code,root.querySelector("#report-progress")));
  root.querySelector("#reports-help").onclick=()=>guide({title:"Cómo usar la analítica",description:"El objetivo es encontrar patrones repetitivos y actuar sobre la causa, no solo contar incidentes.",items:[{title:"Empieza por causas",detail:"El Pareto muestra qué motivos concentran la mayor parte de las excepciones."},{title:"Cruza por referencia",detail:"Detecta materiales o productos que generan faltantes, correcciones o reprocesos."},{title:"Revisa actores externos e internos",detail:"Asesores y proveedores ayudan a identificar dónde se origina la variación."},{title:"Valida por proceso",detail:"Compara Recepción, Corte, Alistamiento y demás etapas para priorizar mejoras."}]});
}

async function renderCauseAnalytics(target){
  const today=new Date();
  const to=today.toISOString().slice(0,10);
  const from=new Date(Date.now()-30*864e5).toISOString().slice(0,10);
  target.innerHTML=`<section class="card card-pad cause-analytics"><header class="cause-analytics-head"><div><span class="exception-kicker">Mejora continua</span><h3>Analítica de causas y reprocesos</h3><p>Consolidación de Novedades, Reportes, mercancía no encontrada, correcciones de Corte y rechazos de Recepción.</p></div><button class="btn btn-ghost" data-close-causes>Cerrar</button></header><div class="cause-date-bar"><label>Desde<input class="control" type="date" name="from" value="${from}"></label><label>Hasta<input class="control" type="date" name="to" value="${to}"></label><button class="btn btn-primary" data-run-causes>Actualizar análisis</button><button class="btn btn-ghost" data-export-causes>Exportar resumen</button></div><div data-cause-result>${loading("Construyendo Pareto…")}</div></section>`;
  target.querySelector("[data-close-causes]")?.addEventListener("click",()=>target.replaceChildren());
  let lastData=null;
  const run=async()=>{
    const fromValue=target.querySelector('[name="from"]').value;
    const toValue=target.querySelector('[name="to"]').value;
    const result=target.querySelector("[data-cause-result]");
    result.innerHTML=loading("Analizando eventos operativos…");
    try{lastData=await api.causeAnalytics(fromValue,toValue);result.innerHTML=causeDashboard(lastData);}catch(error){result.innerHTML=`<div class="module-error"><strong>No fue posible construir la analítica</strong><p>${fmt.escape(error.message)}</p></div>`}
  };
  target.querySelector("[data-run-causes]")?.addEventListener("click",run);
  target.querySelector("[data-export-causes]")?.addEventListener("click",()=>{if(!lastData)return toast("Primero actualiza el análisis.","error");exportCauseSummary(lastData)});
  await run();
}

function causeDashboard(data){
  return `<div class="cause-summary-row"><article><small>Eventos analizados</small><strong>${fmt.number(data.totalEvents||0)}</strong><span>${fmt.escape(data.from)} → ${fmt.escape(data.to)}</span></article><article><small>Causa principal</small><strong>${fmt.escape(data.causes?.[0]?.label||"Sin datos")}</strong><span>${fmt.number(data.causes?.[0]?.count||0)} evento(s)</span></article><article><small>Referencia principal</small><strong>${fmt.escape(data.references?.[0]?.label||"Sin datos")}</strong><span>${fmt.number(data.references?.[0]?.count||0)} evento(s)</span></article></div><div class="cause-grid">${paretoPanel("Causas",data.causes,"Motivos que concentran los problemas")}${paretoPanel("Referencias",data.references,"Materiales con mayor recurrencia")}${paretoPanel("Asesores",data.sellers,"Pedidos asociados a eventos")}${paretoPanel("Proveedores",data.suppliers,"Incidencias vinculadas a abastecimiento")}${paretoPanel("Procesos",data.processes,"Etapas donde se manifiestan los reprocesos")}</div>`;
}

function paretoPanel(title,rows=[],subtitle=""){
  const max=Math.max(1,...rows.map(row=>Number(row.count||0)));
  let cumulative=0;
  const total=rows.reduce((sum,row)=>sum+Number(row.count||0),0)||1;
  return `<article class="cause-panel"><header><div><h4>${fmt.escape(title)}</h4><p>${fmt.escape(subtitle)}</p></div><span>${rows.length} categoría(s)</span></header><div class="cause-bars">${rows.length?rows.map((row,index)=>{const count=Number(row.count||0);cumulative+=count;const cumulativePct=cumulative/total*100;return `<div class="cause-row"><div class="cause-row-label"><strong>${index+1}. ${fmt.escape(pretty(row.label))}</strong><span>${fmt.number(count)} · ${fmt.number(cumulativePct,1)}% acumulado</span></div><div class="cause-track"><span style="width:${Math.max(3,count/max*100)}%"></span></div></div>`}).join(""):`<p class="muted">Sin eventos para este criterio.</p>`}</div></article>`;
}

function pretty(value){return String(value||"").replaceAll("_"," ").replace(/\b\w/g,m=>m.toUpperCase())}

function exportCauseSummary(data){
  const sections=[["causes","Causa"],["references","Referencia"],["sellers","Asesor"],["suppliers","Proveedor"],["processes","Proceso"]];
  const rows=[["Dimension","Elemento","Cantidad"]];
  sections.forEach(([key,label])=>(data[key]||[]).forEach(row=>rows.push([label,row.label,row.count])));
  const csv=rows.map(row=>row.map(value=>`"${String(value??"").replaceAll('"','""')}"`).join(",")).join("\n");
  const link=document.createElement("a");link.href=URL.createObjectURL(new Blob([csv],{type:"text/csv;charset=utf-8"}));link.download=`erp_analitica_causas_${data.from}_${data.to}.csv`;link.click();URL.revokeObjectURL(link.href);toast("Resumen causal exportado.");
}

async function download(type,target){target.innerHTML=`<section class="card card-pad">${loading("Generando reporte…")}</section>`;let rows=[];if(type==="orders")rows=(await api.listOrders({page:1,pageSize:250,includeHistory:true})).items;if(type==="vsm")rows=(await api.vsm(new Date(Date.now()-30*864e5).toISOString().slice(0,10),new Date().toISOString().slice(0,10))).steps;if(type==="audit")rows=(await api.audit(null,"",1,250)).items;if(type==="inventory")rows=(await api.inventory("",1,250)).items;if(type==="approvals")rows=(await api.approvals(null,1,250)).items;if(type==="health")rows=await api.health();target.innerHTML="";if(!rows.length)return toast("El reporte no contiene registros.","error");const headers=[...new Set(rows.flatMap(Object.keys))],csv=[headers.join(","),...rows.map(row=>headers.map(header=>`"${String(typeof row[header]==="object"?JSON.stringify(row[header]):row[header]??"").replaceAll('"','""')}"`).join(","))].join("\n"),link=document.createElement("a");link.href=URL.createObjectURL(new Blob([csv],{type:"text/csv;charset=utf-8"}));link.download=`erp_${type}_${new Date().toISOString().slice(0,10)}.csv`;link.click();URL.revokeObjectURL(link.href);toast("Reporte generado.")}
