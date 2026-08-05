import { supabase } from "./supabase.js";

function unwrap(result, label){
  if(result.error){
    const err = new Error(result.error.message || `Error en ${label}`);
    err.code = result.error.code;
    err.details = result.error.details;
    err.hint = result.error.hint;
    throw err;
  }
  return result.data;
}

export const API = {
  async session(){ return unwrap(await supabase.rpc("erp_v9_session"), "sesión"); },
  async catalog(){ return unwrap(await supabase.rpc("erp_v9_catalog"), "catálogo"); },
  async dashboard(){ return unwrap(await supabase.rpc("erp_v9_dashboard"), "panel"); },
  async cases(filters={}){
    return unwrap(await supabase.rpc("erp_v9_cases", {
      p_search: filters.search || null,
      p_processes: filters.processes?.length ? filters.processes : null,
      p_status: filters.status || null,
      p_route: filters.route || null,
      p_order_kind: filters.orderKind || null,
      p_assignment: filters.assignment || "all",
      p_lifecycle: filters.lifecycle || "active",
      p_page: filters.page || 1,
      p_page_size: filters.pageSize || 50
    }), "pedidos");
  },
  async caseDetail(caseId){ return unwrap(await supabase.rpc("erp_v9_case_detail", {p_case_id:caseId}), "detalle"); },
  async caseActions(caseId){ return unwrap(await supabase.rpc("erp_v9_case_actions", {p_case_id:caseId}), "acciones"); },
  async execute(caseId, actionCode, payload={}){
    return unwrap(await supabase.rpc("erp_v9_execute", {p_case_id:caseId,p_action_code:actionCode,p_payload:payload}), "acción");
  },
  async createCase(caseId,payload){ return this.execute(caseId,"create_case",payload); },
  async addComment(caseId,payload){ return this.execute(caseId,"add_comment",payload); },
  async workflows(filters={}){
    return unwrap(await supabase.rpc("erp_v9_workflows", {
      p_view: filters.view || "available",
      p_request_type: filters.type || null,
      p_status: filters.status || null,
      p_search: filters.search || null,
      p_page: filters.page || 1,
      p_page_size: filters.pageSize || 50
    }), "solicitudes");
  },
  async creditList(filters={}){
    return unwrap(await supabase.rpc("erp_v9_credit_list", {
      p_status: filters.status || null,
      p_search: filters.search || null,
      p_page: filters.page || 1,
      p_page_size: filters.pageSize || 50
    }), "crédito");
  },
  async creditSave(requestId,payload){ return unwrap(await supabase.rpc("erp_v9_credit_save", {p_request_id:requestId,p_payload:payload}), "guardar crédito"); },
  async creditTransition(requestId,action,payload={}){ return unwrap(await supabase.rpc("erp_v9_credit_transition", {p_request_id:requestId,p_action:action,p_payload:payload}), "transición de crédito"); },
  async profiles(){ return unwrap(await supabase.rpc("erp_v9_profiles"), "perfiles"); },
  async updateProfile(uid,payload){ return unwrap(await supabase.rpc("erp_v9_update_profile", {p_user_key:uid,p_payload:payload}), "actualizar perfil"); },
  async domainList(domain,filters={}){
    return unwrap(await supabase.rpc("erp_v9_domain_list", {
      p_domain:domain,p_search:filters.search||null,p_page:filters.page||1,p_page_size:filters.pageSize||50
    }), domain);
  },
  async noveltySave(reportId,payload){ return unwrap(await supabase.rpc("erp_v9_novelty_save", {p_report_id:reportId,p_payload:payload}), "novedad"); },
  async inventorySave(chipId,payload){ return unwrap(await supabase.rpc("erp_v9_inventory_save", {p_chip_id:chipId,p_payload:payload}), "inventario"); },
  async goodsList(filters={}){ return unwrap(await supabase.rpc("erp_v9_goods_list", {p_kind:filters.kind||"receipts",p_search:filters.search||null,p_page:filters.page||1,p_page_size:filters.pageSize||50}), "recepción de mercancía"); },
  async goodsSave(kind,id,payload){ return unwrap(await supabase.rpc("erp_v9_goods_save", {p_kind:kind,p_document_id:id,p_payload:payload}), "guardar recepción"); },
  async vsm(filters={}){ return unwrap(await supabase.rpc("erp_v9_vsm", {p_search:filters.search||null,p_page:filters.page||1,p_page_size:filters.pageSize||50}), "VSM"); },
  async audit(filters={}){ return unwrap(await supabase.rpc("erp_v9_audit", {p_search:filters.search||null,p_page:filters.page||1,p_page_size:filters.pageSize||50}), "auditoría"); },
  async health(){ return unwrap(await supabase.rpc("erp_v9_health"), "salud del sistema"); }
};
