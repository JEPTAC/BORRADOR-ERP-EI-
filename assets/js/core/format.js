const LABELS={
  QUEUED:"En cola",ASSIGNED:"Asignado",IN_PROGRESS:"En proceso",WAITING:"En espera",BLOCKED:"Bloqueado",CLOSED:"Cerrado",CANCELLED:"Cancelado",CANCELED:"Cancelado",PENDING:"Pendiente",APPROVED:"Aprobado",REJECTED:"Rechazado",EXECUTED:"Ejecutado",RUNNING:"En ejecución",PASSED:"Aprobado",FAILED:"Fallido",OPEN:"Abierto",ACTIVE:"Activo",INACTIVE:"Inactivo",COMPLETED:"Completado",WAITING_EVIDENCE:"Pendiente de evidencia",RETURNED:"Devuelto",READY:"Listo",PAUSED:"Pausado",CREATED:"Creado",SUBMITTED:"Radicada",UNDER_REVIEW:"En estudio",
  LOW:"Baja",MEDIUM:"Media",HIGH:"Alta",URGENT:"Urgente",CRITICAL:"Crítica",
  ALL:"Todos",MINE:"Asignados a mí",UNASSIGNED:"Sin asignar",
  CARTERA:"Cartera",CAJA:"Caja",CAJA_FACTURACION:"Facturación en Caja",COMPRAS:"Compras",RECEPCION_MERCANCIA:"Recepción de mercancía",RECEPCION_PEDIDO:"Recepción del pedido",ALISTAMIENTO:"Alistamiento",CORTE:"Corte",FACTURACION:"Facturación",CLIENT_POINT:"Entrega en punto",CLIENT_PICKUP:"Cliente recoge",LOCAL_DISPATCH:"Despacho local",NATIONAL_DISPATCH:"Despacho nacional",CLOSURE:"Cierre",
  CREDIT:"Crédito",CASH:"Contado",MIXED:"Mixto",CREDITO:"Crédito",CONTADO:"Contado",MIXTO:"Mixto",
  CANCELLATION:"Cancelación",PRIORITY:"Cambio de prioridad",ROUTE_CHANGE:"Cambio de ruta",REOPEN:"Reapertura",STOCK_EXCEPTION:"Excepción de inventario",FLOW_EXCEPTION:"Excepción del flujo",PAYMENT_EXCEPTION:"Excepción financiera",DATA_CORRECTION:"Corrección de datos",NO_DELIVERY:"No entrega",
  SUPER_ADMIN:"Superadministrador",GERENCIA:"Gerencia",JEFE_LOGISTICA:"Jefatura de logística",VENTAS:"Ventas",CARTERA_ROLE:"Cartera",CAJA_ROLE:"Caja",COMPRAS_ROLE:"Compras",RECEPCION_MERCANCIA_ROLE:"Recepción de mercancía",COORDINADOR_LOGISTICO:"Coordinación logística",AUX_LOGISTICA:"Auxiliar de logística",AUXILIAR_CORTE:"Auxiliar de corte",DESPACHO_NACIONAL:"Despacho nacional",AUDITORIA:"Auditoría",
  ACCEPTED:"Aceptado",CONDITIONAL:"Aceptado con condición",NONCONFORMING:"No conforme",CONFORMING:"Conforme",PARTIAL:"Parcial",RECEIVED:"Recibida",ISSUED:"Emitida",CONFIRMED:"Confirmada",
  PLANNED:"Programado",DISPATCHED:"Despachado",IN_TRANSIT:"En tránsito",DELIVERED:"Entregado",NOT_DELIVERED:"No entregado",
  ADJUSTMENT_IN:"Ajuste de entrada",ADJUSTMENT_OUT:"Ajuste de salida",ISSUE:"Salida a operación",RETURN:"Devolución",SCRAP:"Desperdicio",TRANSFER:"Traslado",
  EVIDENCE:"Evidencia",INVOICE:"Factura",PAYMENT:"Soporte de pago",PURCHASE_ORDER:"Orden de compra",RECEIPT:"Recepción",DELIVERY:"Entrega",QUALITY:"Calidad",
  ORDER_CREATED:"Pedido creado",WORKFLOW_ACTION:"Acción del flujo",APPROVAL_DECISION:"Decisión de aprobación",MATRIX:"Matriz comercial",CONTROLS:"Controles empresariales",ENTERPRISE_CONTROLS:"Controles empresariales",
  CLAIM:"Tomar pedido",START:"Iniciar etapa",RESUME:"Reanudar etapa",COMPLETE:"Finalizar etapa",WAIT:"Poner en espera",BLOCK:"Bloquear pedido",COMMENT:"Agregar comentario",REQUEST_APPROVAL:"Solicitar aprobación",ASSIGN:"Asignar responsable",REPROGRAM:"Reprogramar entrega",APPROVE:"Aprobar",REJECT:"Rechazar",CANCEL:"Cancelar",CREATE:"Crear",UPDATE:"Actualizar",DELETE:"Eliminar",IMPORT:"Importar",
  CREDIT_STATUS:"Estado de crédito",PAYMENT_REFERENCE:"Referencia de pago",PAYMENT_SUPPORT:"Soporte de pago",DELIVERY_EVIDENCE:"Evidencia de entrega",DOCUMENTS_COMPLETE:"Documentación completa",CLIENT_DATA:"Información del cliente",QUANTITIES:"Cantidades",MEASUREMENTS:"Medidas",PACKAGING:"Empaque",IDENTIFICATION:"Identificación",COMMERCIAL_MATCH:"Coincidencia comercial",CUT_CONSUMPTION:"Consumo de corte",
  LOGISTICS:"Operación logística",COMMERCIAL:"Comercial",FINANCE:"Financiera",PURCHASING:"Compras",MANAGEMENT:"Gestión",GENERAL:"General",IMPROVEMENT:"Mejora continua",FINAL_PHOTO:"Foto final",BEFORE_AFTER:"Antes y después",ERP_REFERENCE:"Referencia ERP",INTERNAL:"Interno",PUBLIC:"General",COMMENT:"Comentario",SUPERVISION:"Supervisión",NOVELTY:"Novedad"
};
const ROLE_LABELS={super_admin:"Superadministrador",gerencia:"Gerencia",jefe_logistica:"Jefatura de logística",lider_logistica:"Líder logístico",ventas:"Ventas",cartera:"Cartera",caja:"Caja",compras:"Compras",recepcion_mercancia:"Recepción de mercancía",coordinador_logistico:"Coordinación logística",aux_logistica:"Auxiliar de logística",auxiliar_corte:"Auxiliar de corte",despacho_nacional:"Despacho nacional",auditoria:"Auditoría"};
function normalize(value){return String(value??"").trim().replace(/[\s-]+/g,"_").toUpperCase()}
function humanize(value){const raw=String(value??"").trim();if(!raw)return "—";return raw.replaceAll("_"," ").toLowerCase().replace(/(^|\s)\S/g,c=>c.toUpperCase())}

const DATA_KEYS={
  orderId:"Pedido",orderNumber:"Número de pedido",clientName:"Cliente",actionCode:"Acción",eventType:"Tipo de evento",fromStep:"Etapa anterior",toStep:"Etapa nueva",fromStatus:"Estado anterior",toStatus:"Estado nuevo",status:"Estado",priority:"Prioridad",route:"Modalidad de entrega",deliveryRoute:"Modalidad de entrega",paymentCondition:"Condición de pago",orderType:"Tipo de pedido",reason:"Motivo",detail:"Detalle",notes:"Observaciones",amount:"Valor",reference:"Referencia",requestedBy:"Solicitado por",assignedRole:"Rol responsable",createdAt:"Fecha de creación",updatedAt:"Fecha de actualización",completedAt:"Fecha de finalización",expectedPath:"Ruta esperada",actualPath:"Ruta obtenida",metadata:"Información adicional",payload:"Información registrada",result:"Resultado",error:"Error",message:"Mensaje"
};
function readableData(value){
  if(value==null)return "—";
  if(Array.isArray(value))return value.map(readableData).join(" → ");
  if(typeof value==="object")return Object.entries(value).map(([key,item])=>`${DATA_KEYS[key]||humanize(key)}: ${readableData(item)}`).join("\n");
  if(typeof value==="boolean")return value?"Sí":"No";
  if(typeof value==="string")return LABELS[normalize(value)]||value;
  return String(value);
}
export const fmt = {
  date(value){if(!value)return "—";return new Intl.DateTimeFormat("es-CO",{dateStyle:"medium",timeStyle:"short",timeZone:"America/Bogota"}).format(new Date(value))},
  day(value){if(!value)return "—";return new Intl.DateTimeFormat("es-CO",{dateStyle:"medium",timeZone:"America/Bogota"}).format(new Date(value))},
  number(value,dec=0){return new Intl.NumberFormat("es-CO",{maximumFractionDigits:dec}).format(Number(value||0))},
  money(value){return new Intl.NumberFormat("es-CO",{style:"currency",currency:"COP",maximumFractionDigits:0}).format(Number(value||0))},
  hours(seconds){const n=Number(seconds||0)/3600;return `${new Intl.NumberFormat("es-CO",{maximumFractionDigits:1}).format(n)} h`},
  initials(name=""){return name.split(/\s+/).filter(Boolean).slice(0,2).map(x=>x[0]).join("").toUpperCase()||"U"},
  escape(value=""){return String(value).replace(/[&<>'"]/g,ch=>({"&":"&amp;","<":"&lt;",">":"&gt;","'":"&#39;",'"':"&quot;"}[ch]))},
  label(value){const key=normalize(value);return LABELS[key]||humanize(value)},
  role(value){return ROLE_LABELS[String(value||"").toLowerCase()]||this.label(value)},
  roles(values=[]){return (values||[]).map(v=>this.role(v)).join(" · ")},
  step(value){return this.label(value)},route(value){return this.label(value)},payment(value){return this.label(value)},request(value){return this.label(value)},action(value){return this.label(value)},suite(value){return this.label(value)},
  weekday(value){return ({1:"Lunes",2:"Martes",3:"Miércoles",4:"Jueves",5:"Viernes",6:"Sábado",7:"Domingo"})[Number(value)]||String(value||"—")},
  data(value){return readableData(value)}
};

export function statusBadge(status){
  const s=normalize(status);
  const cls=["CLOSED","COMPLETED","APPROVED","EXECUTED","PASSED","DELIVERED","CONFORMING","RECEIVED"].some(x=>s.includes(x))?"badge-green":["BLOCK","REJECT","CANCEL","FAILED","NONCONFORMING","NOT_DELIVERED"].some(x=>s.includes(x))?"badge-red":["WAIT","PENDING","UNDER_REVIEW","PARTIAL","CONDITIONAL"].some(x=>s.includes(x))?"badge-yellow":["PROGRESS","ASSIGNED","RUNNING","SUBMITTED","DISPATCHED","IN_TRANSIT"].some(x=>s.includes(x))?"badge-blue":"badge-gray";
  return `<span class="badge ${cls}"><span class="badge-dot"></span>${fmt.escape(fmt.label(s))}</span>`;
}
export function priorityBadge(priority){
  const p=normalize(priority||"MEDIUM");
  const cls={CRITICAL:"badge-red",URGENT:"badge-red",HIGH:"badge-yellow",MEDIUM:"badge-blue",LOW:"badge-gray"}[p]||"badge-gray";
  return `<span class="badge ${cls}"><span class="badge-dot"></span>${fmt.escape(fmt.label(p))}</span>`;
}
