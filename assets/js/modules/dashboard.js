import { API } from "../api.js";
import { esc,fmtNumber,setLoading,setError,badge } from "../ui.js";

export async function renderDashboard(container){
  setLoading(container,"Consolidando el estado del ERP…");
  try{
    const data=await API.dashboard();
    const s=data.summary||data.counts||{};
    const byProcess=data.byProcess||data.by_process||[];
    const recent=data.recentCases||data.recent_cases||[];
    container.innerHTML=`
      <div class="grid grid-kpi">
        ${[
          ["Pedidos visibles",s.visible??s.total??0,"Cobertura según rol"],
          ["Pedidos activos",s.active??0,"En operación"],
          ["Asignados a mí",s.assignedToMe??s.assigned_to_me??0,"Trabajo personal"],
          ["Aprobaciones",s.availableApprovals??s.available_approvals??0,"Pendientes por decidir"]
        ].map(x=>`<article class="kpi-card"><span>${esc(x[0])}</span><strong>${fmtNumber(x[1])}</strong><small>${esc(x[2])}</small></article>`).join("")}
      </div>
      <div class="split" style="margin-top:16px">
        <section class="panel"><div class="panel-header"><div><h3>Pedidos por proceso</h3><p>Distribución operativa actual.</p></div></div>
          <div class="metric-list">${byProcess.length?byProcess.map(x=>`<div class="metric-row"><span>${esc(x.label||x.process||x.code||"Sin proceso")}</span><strong>${fmtNumber(x.quantity??x.count??0)}</strong></div>`).join(""):'<div class="empty-state">Sin datos agrupados.</div>'}</div>
        </section>
        <section class="panel"><div class="panel-header"><div><h3>Actividad reciente</h3><p>Últimos pedidos actualizados.</p></div></div>
          <div class="metric-list">${recent.length?recent.slice(0,10).map(x=>`<div class="metric-row"><span><strong>${esc(x.reference||x.caseId||x.case_id)}</strong><br><small>${esc(x.client||"")}</small></span>${badge(x.status)}</div>`).join(""):'<div class="empty-state">Sin actividad reciente.</div>'}</div>
        </section>
      </div>`;
  }catch(error){setError(container,error)}
}
