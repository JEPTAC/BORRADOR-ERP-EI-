export const fmt = {
  date(value){if(!value)return "—";return new Intl.DateTimeFormat("es-CO",{dateStyle:"medium",timeStyle:"short",timeZone:"America/Bogota"}).format(new Date(value))},
  day(value){if(!value)return "—";return new Intl.DateTimeFormat("es-CO",{dateStyle:"medium",timeZone:"America/Bogota"}).format(new Date(value))},
  number(value,dec=0){return new Intl.NumberFormat("es-CO",{maximumFractionDigits:dec}).format(Number(value||0))},
  money(value){return new Intl.NumberFormat("es-CO",{style:"currency",currency:"COP",maximumFractionDigits:0}).format(Number(value||0))},
  hours(seconds){const n=Number(seconds||0)/3600;return `${new Intl.NumberFormat("es-CO",{maximumFractionDigits:1}).format(n)} h`},
  initials(name=""){return name.split(/\s+/).filter(Boolean).slice(0,2).map(x=>x[0]).join("").toUpperCase()||"U"},
  escape(value=""){return String(value).replace(/[&<>'"]/g,ch=>({"&":"&amp;","<":"&lt;",">":"&gt;","'":"&#39;",'"':"&quot;"}[ch]))}
};

export function statusBadge(status){
  const s=String(status||"").toUpperCase();
  const cls=s.includes("CLOSED")||s.includes("COMPLETED")||s.includes("APPROVED")?"badge-green":s.includes("BLOCK")||s.includes("REJECT")||s.includes("CANCEL")?"badge-red":s.includes("WAIT")||s.includes("PENDING")?"badge-yellow":s.includes("PROGRESS")||s.includes("ASSIGNED")?"badge-blue":"badge-gray";
  const label={QUEUED:"En cola",ASSIGNED:"Asignado",IN_PROGRESS:"En proceso",WAITING:"En espera",BLOCKED:"Bloqueado",CLOSED:"Cerrado",CANCELLED:"Cancelado",PENDING:"Pendiente",APPROVED:"Aprobado",REJECTED:"Rechazado",EXECUTED:"Ejecutado"}[s]||s.replaceAll("_"," ");
  return `<span class="badge ${cls}">${fmt.escape(label)}</span>`;
}

export function priorityBadge(priority){
  const p=String(priority||"MEDIUM").toUpperCase();
  const cls={CRITICAL:"badge-red",URGENT:"badge-red",HIGH:"badge-yellow",MEDIUM:"badge-blue",LOW:"badge-gray"}[p]||"badge-gray";
  return `<span class="badge ${cls}">${p}</span>`;
}
