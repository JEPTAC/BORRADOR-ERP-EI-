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
    if(typeof window!=="undefined")window.dispatchEvent(new CustomEvent("erp:rpc-error",{detail:{rpc:name,message:technical||error.message,status:error.status||null,code:error.code||null}}));
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
  exceptionSummary:()=>rpc("erp_x_exception_summary"),
  exceptionCenter:(kind=null,state="OPEN",page=1,pageSize=100)=>rpc("erp_x_exception_center",{p_kind:kind,p_state:state,p_page:page,p_page_size:pageSize}),
  refreshOperationalSla:()=>mutationRpc("erp_x_refresh_operational_sla"),
  causeAnalytics:(from,to)=>rpc("erp_x_cause_analytics",{p_date_from:from,p_date_to:to}),
  decideApproval:(id,decision,reason)=>mutationRpc("erp_x_decide_approval",{p_request_id:id,p_decision:decision,p_reason:reason}),
  requestOrderCancellation:(orderId,note)=>mutationRpc("erp_x_request_order_cancellation",{p_order_id:orderId,p_note:note}),
  decideOrderCancellation:(requestId,decision="APPROVED",reason=null)=>mutationRpc("erp_x_decide_order_cancellation",{p_request_id:requestId,p_decision:decision,p_reason:reason}),
  registerDriveFile:payload=>mutationRpc("erp_x_register_drive_file",{p_payload:payload}),
  materialSearch:(query="",limit=20)=>rpc("erp_x_material_search",{p_query:query||null,p_limit:limit}),
  materialResolve:lines=>rpc("erp_x_material_resolve",{p_lines:lines||[]}),
  materialSyncBegin:(fileName,fileSha256,expectedRows)=>mutationRpc("erp_x_material_sync_begin",{p_file_name:fileName,p_file_sha256:fileSha256,p_expected_rows:expectedRows}),
  materialSyncAppend:(batchId,rows)=>mutationRpc("erp_x_material_sync_append",{p_batch_id:batchId,p_rows:rows}),
  materialSyncFinish:batchId=>mutationRpc("erp_x_material_sync_finish",{p_batch_id:batchId}),
  materialSyncHistory:(limit=10)=>rpc("erp_x_material_sync_history",{p_limit:limit}),
  materialReservationHealth:()=>rpc("erp_x_material_reservation_health"),
  inventory:(search="",page=1,pageSize=50)=>rpc("erp_x_inventory",{p_search:search||null,p_page:page,p_page_size:pageSize}),
  inventoryFiltered:(filters={})=>rpc("erp_x_inventory_filtered",{p_payload:filters||{}}),
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
  workCatalog:()=>rpc("erp_x_work_catalog"),
  workCreateCatalogItem:payload=>mutationRpc("erp_x_work_create_catalog_item",{p_payload:payload||{}}),
  workMyDay:(day=null)=>rpc("erp_x_work_my_day",{p_day:day||null}),
  workProposeAssignment:payload=>mutationRpc("erp_x_work_propose_assignment",{p_payload:payload||{}}),
  workPendingApprovals:()=>rpc("erp_x_work_pending_approvals"),
  workDecideAssignment:(assignmentId,decision,note=null,force=false)=>mutationRpc("erp_x_work_decide_assignment",{p_assignment_id:assignmentId,p_decision:decision,p_note:note,p_force:force}),
  workStart:(catalogId,assignmentId=null,payload={})=>mutationRpc("erp_x_work_start",{p_catalog_id:catalogId,p_assignment_id:assignmentId,p_payload:payload||{}}),
  workPause:(executionId,reasonCode="OTHER",note=null)=>mutationRpc("erp_x_work_pause",{p_execution_id:executionId,p_reason_code:reasonCode,p_note:note}),
  workResume:executionId=>mutationRpc("erp_x_work_resume",{p_execution_id:executionId}),
  workFinish:(executionId,payload={})=>mutationRpc("erp_x_work_finish",{p_execution_id:executionId,p_payload:payload||{}}),
  workRegisterEvidence:(executionId,payload)=>mutationRpc("erp_x_work_register_evidence",{p_execution_id:executionId,p_payload:payload||{}}),
  workPeople:(kind=null)=>rpc("erp_x_work_people",{p_assignment_kind:kind||null}),
  workPlanner:(from,to)=>rpc("erp_x_work_planner",{p_from:from,p_to:to}),
  workSaveAssignment:payload=>mutationRpc("erp_x_work_save_assignment",{p_payload:payload||{}}),
  workCancelAssignment:(assignmentId,note=null)=>mutationRpc("erp_x_work_cancel_assignment",{p_assignment_id:assignmentId,p_note:note}),
  workReviewDelivery:(executionId,decision,note=null)=>mutationRpc("erp_x_work_review_delivery",{p_execution_id:executionId,p_decision:decision,p_note:note}),
  workLedger:(from,to,profileId=null)=>rpc("erp_x_work_ledger",{p_from:from,p_to:to,p_profile_id:profileId||null}),
  workAnalytics:(from,to,profileId=null)=>rpc("erp_x_work_analytics",{p_from:from,p_to:to,p_profile_id:profileId||null}),
  workOccupation:(from,to,profileId=null)=>rpc("erp_x_work_occupation",{p_from:from,p_to:to,p_profile_id:profileId||null}),
  workHealth:()=>rpc("erp_x_work_health"),
  qaRuns:(limit=20)=>rpc("erp_x_qa_runs",{p_limit:limit}),
  runQa:(cleanup=true)=>rpc("erp_x_run_qa_matrix",{p_cleanup:cleanup}),
  runQaControls:(cleanup=true)=>rpc("erp_x_run_qa_control_suite",{p_cleanup:cleanup}),
  runQaV1022:(cleanup=true)=>rpc("erp_x_run_qa_v10_22",{p_cleanup:cleanup}),
  qaDetail:id=>rpc("erp_x_qa_run_detail",{p_run_id:id}),
  qaRobotPlan:()=>rpc("erp_x_qa_robot_plan"),
  qaRobotCreateRun:(options={})=>mutationRpc("erp_x_qa_robot_create_run",{p_options:options||{}}),
  qaRobotRecordCheck:(runId,check)=>mutationRpc("erp_x_qa_robot_record_check",{p_run_id:runId,p_check:check||{}}),
  qaRobotFinishRun:(runId,cleanup=true)=>mutationRpc("erp_x_qa_robot_finish_run",{p_run_id:runId,p_cleanup:cleanup}),
  qaRobotDetail:runId=>rpc("erp_x_qa_robot_detail",{p_run_id:runId}),
  qaRobotSystemContract:()=>rpc("erp_x_qa_robot_system_contract"),
  qaRobotBranchSuite:runId=>mutationRpc("erp_x_qa_robot_branch_suite",{p_run_id:runId}),
  qaRobotSeedOrder:(runId,payload={})=>mutationRpc("erp_x_qa_robot_seed_order",{p_run_id:runId,p_payload:payload||{}}),
  qaRobotCleanup:runId=>mutationRpc("erp_x_qa_robot_cleanup",{p_run_id:runId}),
  queueIntegrity:(apply=false)=>rpc("erp_x_queue_integrity",{p_apply:apply}),
  runtimeDiagnostics:()=>rpc("erp_x_runtime_diagnostics"),
  creditList:(status=null,search="",page=1,pageSize=50)=>rpc("erp_x_credit_list",{p_status:status,p_search:search||null,p_page:page,p_page_size:pageSize}),
  creditCreate:payload=>mutationRpc("erp_x_credit_create",{p_payload:payload}),
  creditTransition:(id,action,reason=null)=>mutationRpc("erp_x_credit_transition",{p_request_id:id,p_action:action,p_reason:reason}),
  receiptProgress:orderId=>rpc("erp_x_receipt_progress",{p_order_id:orderId}),
  saveReceipt:(orderId,payload)=>mutationRpc("erp_x_save_receipt",{p_order_id:orderId,p_payload:payload}),
  confirmOrderReception:(orderId,payload)=>mutationRpc("erp_x_confirm_order_reception",{p_order_id:orderId,p_payload:payload}),
  createOrderIssue:(orderId,payload)=>mutationRpc("erp_x_create_order_issue",{p_order_id:orderId,p_payload:payload}),
  orderIssues:orderId=>rpc("erp_x_order_issues",{p_order_id:orderId}),
  resolveOrderIssue:(issueId,payload)=>mutationRpc("erp_x_resolve_order_issue",{p_issue_id:issueId,p_payload:payload}),
  setPurchaseArrival:(orderId,status)=>mutationRpc("erp_x_set_purchase_arrival",{p_order_id:orderId,p_status:status}),
  pickingPrecheck:orderId=>rpc("erp_x_picking_precheck",{p_order_id:orderId}),
  pickingOriginPlan:orderItemId=>rpc("erp_x_picking_origin_plan",{p_order_item_id:orderItemId}),
  savePickingPrecheck:(orderId,items)=>mutationRpc("erp_x_save_picking_precheck",{p_order_id:orderId,p_items:items}),
  requestCutRemainderApproval:(groupKey,payload)=>mutationRpc("erp_x_request_cut_remainder_approval",{p_group_key:groupKey,p_payload:payload}),
  confirmPickingRound:(orderId,payload)=>mutationRpc("erp_x_confirm_picking_round",{p_order_id:orderId,p_payload:payload}),
  resumePartialPicking:orderId=>mutationRpc("erp_x_resume_partial_picking",{p_order_id:orderId}),
  pickingPending:(search="",page=1,pageSize=50)=>rpc("erp_x_picking_pending",{p_search:search||null,p_page:page,p_page_size:pageSize}),
  partialFulfillmentMetrics:(from,to)=>rpc("erp_x_partial_fulfillment_metrics",{p_date_from:from,p_date_to:to}),
  stickers:orderId=>rpc("erp_x_stickers",{p_order_id:orderId}),
  cuttingGroups:(search="",page=1,pageSize=50)=>rpc("erp_x_cutting_groups",{p_search:search||null,p_page:page,p_page_size:pageSize}),
  cuttingWork:(search="",page=1,pageSize=50)=>rpc("erp_x_cutting_work",{p_search:search||null,p_page:page,p_page_size:pageSize}),
  cuttingStart:groupKey=>mutationRpc("erp_x_cutting_start",{p_group_key:groupKey}),
  cuttingActiveExecution:groupKey=>rpc("erp_x_cutting_active_execution",{p_group_key:groupKey}),
  cuttingExecution:executionId=>rpc("erp_x_cutting_execution",{p_execution_id:executionId}),
  cuttingPause:(executionId,reason)=>mutationRpc("erp_x_cutting_pause",{p_execution_id:executionId,p_reason:reason}),
  cuttingResume:executionId=>mutationRpc("erp_x_cutting_resume",{p_execution_id:executionId}),
  cuttingExecutionPlan:(executionId,lotId,reelLength,scrapLength=0)=>rpc("erp_x_cutting_execution_plan",{p_execution_id:executionId,p_inventory_lot_id:lotId,p_reel_length:reelLength,p_scrap_length:scrapLength}),
  cuttingRegisterEvidence:(executionId,fileId)=>mutationRpc("erp_x_cutting_register_evidence",{p_execution_id:executionId,p_file_id:fileId}),
  cuttingFinalize:executionId=>mutationRpc("erp_x_cutting_finalize",{p_execution_id:executionId}),
  cuttingGroup:groupKey=>rpc("erp_x_cutting_group",{p_group_key:groupKey}),
  cuttingOptimizer:groupKey=>rpc("erp_x_cutting_optimizer",{p_group_key:groupKey}),
  cuttingOriginSearch:(groupKey,search="",limit=50)=>rpc("erp_x_cutting_origin_search",{p_group_key:groupKey,p_search:search||null,p_limit:limit}),
  cuttingBatchPlan:(groupKey,lotId,reelLength,scrapLength=0)=>rpc("erp_x_cutting_batch_plan",{p_group_key:groupKey,p_inventory_lot_id:lotId,p_reel_length:reelLength,p_scrap_length:scrapLength}),
  executeCutGroup:(groupKey,payload)=>mutationRpc("erp_x_execute_cut_group",{p_group_key:groupKey,p_payload:payload}),
  resolveCutRequirement:(requirementId,resolution,payload={})=>mutationRpc("erp_x_resolve_cut_requirement",{p_requirement_id:requirementId,p_resolution:resolution,p_payload:payload}),
  cutPickupsPending:(search="",page=1,pageSize=50)=>rpc("erp_x_cut_pickups_pending",{p_search:search||null,p_page:page,p_page_size:pageSize}),
  cutPickupDetail:orderId=>rpc("erp_x_cut_pickup_detail",{p_order_id:orderId}),
  confirmCutPickup:(orderId,requirementIds)=>mutationRpc("erp_x_confirm_cut_pickup",{p_order_id:orderId,p_requirement_ids:requirementIds}),
  saveInvoice:(orderId,payload)=>mutationRpc("erp_x_save_invoice",{p_order_id:orderId,p_payload:payload}),
  routeBillingToCash:(orderId,reason=null)=>mutationRpc("erp_x_route_billing_to_cash",{p_order_id:orderId,p_reason:reason}),
  saveDelivery:(orderId,payload)=>mutationRpc("erp_x_save_delivery",{p_order_id:orderId,p_payload:payload}),
  saveShippingGuide:(orderId,payload)=>mutationRpc("erp_x_shipping_save_guide",{p_order_id:orderId,p_payload:payload}),
  saveShippingLocation:(orderId,payload)=>mutationRpc("erp_x_shipping_save_location",{p_order_id:orderId,p_payload:payload}),
  sendShippingToClosure:(orderId,payload={})=>mutationRpc("erp_x_shipping_send_to_closure",{p_order_id:orderId,p_payload:payload}),
  registerShippingEvidence:(orderId,payload)=>mutationRpc("erp_x_shipping_register_evidence",{p_order_id:orderId,p_payload:payload}),
  finalizeShipping:(orderId,payload={})=>mutationRpc("erp_x_shipping_finalize",{p_order_id:orderId,p_payload:payload}),
  shippingSentOrders:(search="",page=1,pageSize=30)=>rpc("erp_x_shipping_sent_orders",{p_search:search||null,p_page:page,p_page_size:pageSize}),
  reportShippingNoDelivery:(orderId,payload)=>mutationRpc("erp_x_shipping_report_no_delivery",{p_order_id:orderId,p_payload:payload}),
  sandboxCreate:payload=>mutationRpc("erp_x_sandbox_create",{p_payload:payload}),
  sandboxOrders:(filters={})=>rpc("erp_x_sandbox_list_orders",{p_search:filters.search||null,p_step:filters.step||null,p_status:filters.status||null,p_page:filters.page||1,p_page_size:filters.pageSize||50}),
  sandboxMove:(orderId,step)=>mutationRpc("erp_x_sandbox_move",{p_order_id:orderId,p_step_code:step}),
  sandboxDelete:orderId=>mutationRpc("erp_x_sandbox_delete",{p_order_id:orderId}),
  sandboxClear:()=>mutationRpc("erp_x_sandbox_clear"),
  sandboxCuttingGroups:(search="",page=1,pageSize=50)=>rpc("erp_x_sandbox_cutting_groups",{p_search:search||null,p_page:page,p_page_size:pageSize}),
  sandboxCuttingWork:(search="",page=1,pageSize=50)=>rpc("erp_x_sandbox_cutting_work",{p_search:search||null,p_page:page,p_page_size:pageSize}),
  sandboxCuttingGroup:groupKey=>rpc("erp_x_sandbox_cutting_group",{p_group_key:groupKey}),
  sandboxCuttingOptimizer:groupKey=>rpc("erp_x_sandbox_cutting_optimizer",{p_group_key:groupKey}),
  sandboxExecuteCutGroup:(groupKey,payload)=>mutationRpc("erp_x_sandbox_execute_cut_group",{p_group_key:groupKey,p_payload:payload}),
  sandboxResolveCutRequirement:(requirementId,resolution,payload={})=>mutationRpc("erp_x_sandbox_resolve_cut_requirement",{p_requirement_id:requirementId,p_resolution:resolution,p_payload:payload}),
  sandboxCuttingEvidence:(executionId,payload={})=>mutationRpc("erp_x_sandbox_cutting_evidence",{p_execution_id:executionId,p_payload:payload}),
  audit:(entityType=null,search="",page=1,pageSize=100)=>rpc("erp_x_audit",{p_entity_type:entityType,p_search:search||null,p_page:page,p_page_size:pageSize})
};
