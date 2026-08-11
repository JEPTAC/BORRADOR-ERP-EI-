export const CONFIG = Object.freeze({
  version: "10.22.2-operatividad-movil",
  build: "2026-08-11.09",
  appName: "ERP Electroingeniería",
  company: "Electroingeniería S.A.S.",
  supabase: {
    url: "https://hezjxcxxcjlpmyalftam.supabase.co",
    publishableKey: "sb_publishable_yxgyHILzQVDHrS2MYYkBkA_UfN77JtT"
  },
  drive: {
    clientId: "125993982318-gn2177d3muf2iip0co9pf9mii7d12cre.apps.googleusercontent.com",
    scope: "https://www.googleapis.com/auth/drive.file",
    rootFolderName: "ERP_SUPPLY_ENTERPRISE",
    bridgeUrl: "https://script.google.com/macros/s/AKfycbygBt_yd5vQXIIZKZux_YCqhm37VSR3tKG109e_ED8NvmZzrUp179jkKSA6DnHNf2N3/exec",
    maxFileBytes: 15728640,
    uploadMode: "INSTITUTIONAL_APPS_SCRIPT"
  },
  ui: { pageSize: 50, maxPageSize: 250 },
  timezone: "America/Bogota"
});

export const NAV_GROUPS = [
  {label:"Inicio y gestión comercial",items:[
    {id:"dashboard",label:"Centro de operación",icon:"dashboard"},
    {id:"orders",label:"Control de pedidos",icon:"orders"},
    {id:"sales",label:"Registro de ventas",icon:"sales"},
    {id:"credit",label:"Solicitudes de crédito",icon:"credit"}
  ]},
  {label:"Operación de suministros",items:[
    {id:"cartera",label:"Cartera",icon:"wallet",step:"CARTERA"},
    {id:"caja",label:"Caja",icon:"cash",steps:["CAJA","CAJA_FACTURACION"]},
    {id:"purchasing",label:"Compras",icon:"purchasing",step:"COMPRAS"},
    {id:"receiving",label:"Recepción",icon:"receiving",steps:["RECEPCION_MERCANCIA","RECEPCION_PEDIDO"]},
    {id:"picking",label:"Alistamiento",icon:"picking",step:"ALISTAMIENTO"},
    {id:"cutting",label:"Corte",icon:"cutting",step:"CORTE"},
    {id:"billing",label:"Facturación",icon:"billing",step:"FACTURACION"},
    {id:"shipping",label:"Despachos y entregas",icon:"shipping",steps:["CLIENT_POINT","CLIENT_PICKUP","LOCAL_DISPATCH","NATIONAL_DISPATCH","CLOSURE"]}
  ]},
  {label:"Control y análisis",items:[
    {id:"inventory",label:"Inventario",icon:"inventory"},
    {id:"approvals",label:"Centro de excepciones",icon:"approvals"},
    {id:"vsm",label:"Flujo y tiempos",icon:"vsm"},
    {id:"reports",label:"Reportes",icon:"reports"},
    {id:"imports",label:"Importar historial",icon:"imports"},
    {id:"sandbox",label:"Bot de pruebas",icon:"qa"},
    {id:"qa",label:"Pruebas automáticas",icon:"qa"},
    {id:"audit",label:"Auditoría",icon:"audit"},
    {id:"admin",label:"Administración",icon:"admin"}
  ]}
];
