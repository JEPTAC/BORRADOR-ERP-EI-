export const CONFIG = Object.freeze({
  version: "10.0.0-enterprise-release",
  build: "2026-08-05.2",
  appName: "EI ERP Supply Enterprise",
  company: "Electroingeniería S.A.S.",
  supabase: {
    url: "https://hezjxcxxcjlpmyalftam.supabase.co",
    publishableKey: "sb_publishable_yxgyHILzQVDHrS2MYYkBkA_UfN77JtT"
  },
  drive: {
    clientId: "125993982318-gn2177d3muf2iip0co9pf9mii7d12cre.apps.googleusercontent.com",
    scope: "https://www.googleapis.com/auth/drive.file",
    rootFolderName: "ERP_SUPPLY_ENTERPRISE"
  },
  ui: { pageSize: 50, maxPageSize: 250 },
  timezone: "America/Bogota"
});

export const NAV_GROUPS = [
  {label:"Operación",items:[
    {id:"dashboard",label:"Centro de operación",icon:"◫"},
    {id:"orders",label:"Control de pedidos",icon:"▤"},
    {id:"sales",label:"Registro de ventas",icon:"＋"},
    {id:"credit",label:"Crédito",icon:"◇"}
  ]},
  {label:"Flujo de suministro",items:[
    {id:"cartera",label:"Cartera",icon:"₵",step:"CARTERA"},
    {id:"caja",label:"Caja",icon:"$",step:"CAJA"},
    {id:"purchasing",label:"Compras",icon:"⌑",step:"COMPRAS"},
    {id:"receiving",label:"Recepción",icon:"⇩",steps:["RECEPCION_MERCANCIA","RECEPCION_PEDIDO"]},
    {id:"picking",label:"Alistamiento",icon:"✓",step:"ALISTAMIENTO"},
    {id:"cutting",label:"Corte",icon:"✂",step:"CORTE"},
    {id:"billing",label:"Facturación",icon:"▧",step:"FACTURACION"},
    {id:"shipping",label:"Despachos y entrega",icon:"▰",steps:["CLIENT_POINT","CLIENT_PICKUP","LOCAL_DISPATCH","NATIONAL_DISPATCH","CLOSURE"]}
  ]},
  {label:"Control",items:[
    {id:"inventory",label:"Inventario",icon:"▦"},
    {id:"approvals",label:"Aprobaciones",icon:"⚑"},
    {id:"vsm",label:"VSM y tiempos",icon:"↝"},
    {id:"reports",label:"Reportes",icon:"▥"},
    {id:"imports",label:"Importar histórico",icon:"⇧"},
    {id:"qa",label:"Bot QA E2E",icon:"◎"},
    {id:"audit",label:"Auditoría",icon:"⌕"},
    {id:"admin",label:"Administración",icon:"⚙"}
  ]}
];
