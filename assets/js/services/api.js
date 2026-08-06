import {getSupabase} from "./supabase.js";
import {CONFIG} from "../config.js";

function friendly(message=""){
  const raw=String(message||"");
  const rules=[
    [/permission denied|not authorized|unauthorized|42501/i,"No tienes permiso para realizar esta acción."],
    [/not found|no existe|no encontrado/i,"No se encontró la información solicitada."],
    [/duplicate|already exists|unique constraint/i,"Ya existe un registro con esa información."],
    [/version|concurrent|simult/i,"El pedido fue actualizado por otra persona. Actualiza la información antes de continuar."],
    [/jwt expired|token.*expired/i,"Tu sesión venció. Ingresa nuevamente."],
    [/failed to fetch|networkerror|load failed/i,"No fue posible conectar con el ERP. Revisa la conexión e inténtalo nuevamente."]
  ];
  return rules.find(([re])=>re.test(raw))?.[1]||raw||"No fue posible completar la operación.";
}
async function rpc(name,params={}){
  const {data,error}=await getSupabase().rpc(name,params);
  if(error){
    const technical=[error.message,error.details,error.hint].filter(Boolean).join(" · ");
    console.error(`[ERP RPC] ${name}`,{params,error});
    const e=new Error(friendly(technical||error.message));
    Object.assign(e,error,{rpc:name,params,technicalMessage:technical});
    e.message=friendly(technical||error.message);
    throw e;
  }
  return data;
}

async function mutationRpc(name,params={}){
  const data=await rpc(name,params);
  if(typeof window!=="undefined")window.dispatchEvent(new CustomEvent("erp:work-changed",{detail:{rpc:name}}));
  return data;
}

export const api={
  session:()=>rpc("erp_x_session"),
  health:()=>rpc("erp_x_health_check"),
  dashboard:()=>rpc("erp_x_dashboard"),
  listOrders:(filters={})=>rpc("erp_x_list_orders",{
    p_search:filters.search||null,p_step:filters.step||null,p_status:filters.status||null,
    p_order_type:filters.orderType||null,p_route:filters.route||null,p_assignment:filters.assignment||"ALL",
    p_page:filters.page||1,p_page_size:filters.pageSize||CONFIG.ui.pageSize,p_include_history:filters.includeHistory!==false
  }),
  getOrder:id=>rpc("erp_x_get_order",{p_order_id:id}),
  getActions:id=>rpc("erp_x_get_actions",{p_order_id:id}),
  createOrder:(payload,key=crypto.randomUUID())=>mutationRpc("erp_x_create_order",{p_payload:payload,p_idempotency_key:key}),
  executeAction:(orderId,action,payload={},version=null,key=crypto.randomUUID())=>mutationRpc("erp_x_execute_action",{p_order_id:orderId,p_action_code:action,p_payload:payload,p_expected_version:version,p_idempotency_key:key}),
  approvals:(status="PENDING",page=1,pageSize=50)=>rpc("erp_x_list_approvals",{p_status:status,p_page:page,p_page_size:pageSize}),
  decideApproval:(id,decision,reason)=>mutationRpc("erp_x_decide_approval",{p_request_id:id,p_decision:decision,p_reason:reason}),
  registerDriveFile:payload=>mutationRpc("erp_x_register_drive_file",{p_payload:payload}),
  inventory:(search="",page=1,pageSize=50)=>rpc("erp_x_inventory",{p_search:search||null,p_page:page,p_page_size:pageSize}),
  inventoryAdjust:payload=>mutationRpc("erp_x_inventory_adjust",{p_payload:payload}),
  inventoryLots:(itemId=null,search="")=>rpc("erp_x_inventory_lots",{p_item_id:itemId,p_search:search||null}),
  vsm:(from,to)=>rpc("erp_x_vsm",{p_date_from:from,p_date_to:to}),
  importHistory:(fileName,rows,batchId=null)=>mutationRpc("erp_x_import_history",{p_file_name:fileName,p_rows:rows,p_batch_id:batchId}),
  users:()=>rpc("erp_x_users"),
  assignmentPool:step=>rpc("erp_x_assignment_pool",{p_step_code:step}),
  updateChecklist:(taskId,itemCode,completed,note=null)=>mutationRpc("erp_x_update_checklist",{p_task_id:taskId,p_item_code:itemCode,p_completed:completed,p_note:note}),
  saveFinancialValidation:(orderId,payload)=>mutationRpc("erp_x_save_financial_validation",{p_order_id:orderId,p_payload:payload}),
  savePurchaseOrder:(orderId,payload)=>mutationRpc("erp_x_save_purchase_order",{p_order_id:orderId,p_payload:payload}),
  saveProfile:payload=>mutationRpc("erp_x_admin_save_profile",{p_payload:payload}),
  syncAuth:()=>mutationRpc("erp_x_admin_sync_auth"),
  calendar:()=>rpc("erp_x_calendar"),
  qaRuns:(limit=20)=>rpc("erp_x_qa_runs",{p_limit:limit}),
  runQa:(cleanup=true)=>rpc("erp_x_run_qa_matrix",{p_cleanup:cleanup}),
  runQaControls:(cleanup=true)=>rpc("erp_x_run_qa_control_suite",{p_cleanup:cleanup}),
  qaDetail:id=>rpc("erp_x_qa_run_detail",{p_run_id:id}),
  queueIntegrity:(apply=false)=>rpc("erp_x_queue_integrity",{p_apply:apply}),
  runtimeDiagnostics:()=>rpc("erp_x_runtime_diagnostics"),
  creditList:(status=null,search="",page=1,pageSize=50)=>rpc("erp_x_credit_list",{p_status:status,p_search:search||null,p_page:page,p_page_size:pageSize}),
  creditCreate:payload=>mutationRpc("erp_x_credit_create",{p_payload:payload}),
  creditTransition:(id,action,reason=null)=>mutationRpc("erp_x_credit_transition",{p_request_id:id,p_action:action,p_reason:reason}),
  saveReceipt:(orderId,payload)=>mutationRpc("erp_x_save_receipt",{p_order_id:orderId,p_payload:payload}),
  confirmOrderReception:(orderId,payload)=>mutationRpc("erp_x_confirm_order_reception",{p_order_id:orderId,p_payload:payload}),
  confirmPickingRound:(orderId,payload)=>mutationRpc("erp_x_confirm_picking_round",{p_order_id:orderId,p_payload:payload}),
  resumePartialPicking:orderId=>mutationRpc("erp_x_resume_partial_picking",{p_order_id:orderId}),
  pickingPending:(search="",page=1,pageSize=50)=>rpc("erp_x_picking_pending",{p_search:search||null,p_page:page,p_page_size:pageSize}),
  partialFulfillmentMetrics:(from,to)=>rpc("erp_x_partial_fulfillment_metrics",{p_date_from:from,p_date_to:to}),
  stickers:orderId=>rpc("erp_x_stickers",{p_order_id:orderId}),
  saveCutJob:(orderId,payload)=>mutationRpc("erp_x_save_cut_job",{p_order_id:orderId,p_payload:payload}),
  saveInvoice:(orderId,payload)=>mutationRpc("erp_x_save_invoice",{p_order_id:orderId,p_payload:payload}),
  routeBillingToCash:(orderId,reason=null)=>mutationRpc("erp_x_route_billing_to_cash",{p_order_id:orderId,p_reason:reason}),
  saveDelivery:(orderId,payload)=>mutationRpc("erp_x_save_delivery",{p_order_id:orderId,p_payload:payload}),
  audit:(entityType=null,search="",page=1,pageSize=100)=>rpc("erp_x_audit",{p_entity_type:entityType,p_search:search||null,p_page:page,p_page_size:pageSize})
};
