export const CONFIG = Object.freeze({
  version: "9.0.0",
  build: "2026-08-05.1",
  supabase: {
    url: "https://hezjxcxxcjlpmyalftam.supabase.co",
    publishableKey: "sb_publishable_yxgyHILzQVDHrS2MYYkBkA_UfN77JtT"
  },
  drive: {
    googleClientId: "125993982318-gn2177d3muf2iip0co9pf9mii7d12cre.apps.googleusercontent.com",
    rootFolderName: "EVIDENCIAS_LOGISTICA_ELECTROINGENIERIA",
    scope: "https://www.googleapis.com/auth/drive.file"
  },
  pagination: { pageSize: 50 },
  appName: "EI ERP Nova V9"
});

export const MODULES = [
  {id:"dashboard",label:"Inicio",icon:"⌂",roles:["*"]},
  {id:"sales",label:"Registro de ventas",icon:"＋",roles:["super_admin","ventas"]},
  {id:"projects",label:"Pedidos PVP / Proyectos",icon:"◆",orderKind:"PVP",roles:["super_admin","gerencia","jefe_logistica","ventas","coordinador_logistico","auditoria"]},
  {id:"orders",label:"Todos los pedidos",icon:"▤",roles:["super_admin","gerencia","jefe_logistica","auditoria","ventas","compras","aux_logistica","auxiliar_corte","despacho_nacional","coordinador_logistico","caja","cartera","recepcion_mercancia"]},
  {id:"cartera",label:"Cartera",icon:"₵",processes:["cartera"],roles:["super_admin","gerencia","cartera","auditoria"]},
  {id:"caja",label:"Caja",icon:"$",processes:["caja"],roles:["super_admin","gerencia","caja","auditoria"]},
  {id:"compras",label:"Compras",icon:"⌑",processes:["compras"],roles:["super_admin","gerencia","compras","jefe_logistica","auditoria"]},
  {id:"goods",label:"Mercancía y stickers",icon:"▣",roles:["super_admin","gerencia","compras","recepcion_mercancia","jefe_logistica","auditoria"]},
  {id:"recepcion",label:"Recepción de pedidos",icon:"⇩",processes:["recepcion_pedidos","recepcion_mercancia","reception_goods"],roles:["super_admin","gerencia","recepcion_mercancia","jefe_logistica","coordinador_logistico","auditoria"]},
  {id:"alistamiento",label:"Alistamiento",icon:"✓",processes:["alistamiento"],roles:["super_admin","gerencia","jefe_logistica","aux_logistica","coordinador_logistico","auditoria"]},
  {id:"corte",label:"Corte",icon:"✂",processes:["prealistamiento","corte","corte_cable"],roles:["super_admin","gerencia","jefe_logistica","auxiliar_corte","auditoria"]},
  {id:"facturacion",label:"Facturación",icon:"▧",processes:["facturacion"],roles:["super_admin","gerencia","coordinador_logistico","despacho_nacional","jefe_logistica","auditoria"]},
  {id:"despachos",label:"Despachos",icon:"▰",processes:["cliente_punto","cliente_recoge","despacho_local","despacho_nacional","cierre_caso","cierre_despacho_nacional"],roles:["super_admin","gerencia","coordinador_logistico","despacho_nacional","jefe_logistica","auditoria"]},
  {id:"approvals",label:"Solicitudes y aprobaciones",icon:"⚑",roles:["super_admin","gerencia","jefe_logistica","auditoria","ventas","compras","coordinador_logistico","despacho_nacional","caja","cartera","recepcion_mercancia"]},
  {id:"credit",label:"Solicitudes de crédito",icon:"◇",roles:["super_admin","gerencia","ventas","cartera","auditoria"]},
  {id:"novelties",label:"Novedades",icon:"!",roles:["*"]},
  {id:"inventory",label:"Inventario y chipas",icon:"▦",roles:["super_admin","gerencia","jefe_logistica","auxiliar_corte","recepcion_mercancia","auditoria"]},
  {id:"vsm",label:"VSM y tiempos",icon:"↝",roles:["super_admin","gerencia","jefe_logistica","auditoria"]},
  {id:"audit",label:"Auditoría",icon:"◎",roles:["super_admin","gerencia","auditoria"]},
  {id:"admin",label:"Usuarios y roles",icon:"⚙",roles:["super_admin"]}
];
